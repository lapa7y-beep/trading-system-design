# Port Interface Design — Path 1: Realtime Trading (v2.0)

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | port_interface_path1_v2.0 |
| Path | Path 1: Realtime Trading |
| 선행 문서 | boundary_definition_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |
| 이력 | v1.0 매매실행만 → v2.0 종목선정+매매실행+포지션추적 통합 |
| 대체 | port_interface_path1_v1.0.md, port_interface_path1_extension_v1.0.md |

---

## 1. Path 1 개요

### 1.1 책임 범위

Realtime Trading Path는 트레이딩의 전체 생명주기를 담당한다:

```
종목 스크리닝 → 관심종목 등록 → 시세 구독 → 집중 감시
→ 진입 조건 충족 → 리스크 검증 → 매수 실행
→ 보유 중 실시간 손익 추적 → 손절/익절 감시
→ 청산 조건 충족 → 청산 실행
→ 재감시 또는 블랙리스트
```

5개 Path 중 유일하게 **실제 돈이 오가는 경로**. boundary_definition에서 확정한 대로 **전체 노드가 L0(No LLM)** — deterministic only. LLM이 죽어도 매매는 계속된다.

### 1.2 SubPath 구조 (3개 SubPath, 13개 노드)

| SubPath | 책임 | 노드 수 |
|---------|------|---------|
| **1A: Universe Management** | 종목 스크리닝, 관심종목 관리, 시세 구독 | 3 |
| **1B: Trade Execution** | 시세 수신, 지표 계산, 전략 판단, 주문 실행 | 7 |
| **1C: Position Tracking** | 보유종목 실시간 추적, 청산 감시, 청산 실행 | 3 |

### 1.3 전체 노드 구성 (13개)

| SubPath | 노드 ID | 역할 | runMode | LLM Level |
|---------|---------|------|---------|-----------|
| **1A** | Screener | 전 종목 조건 필터링 | batch | L0 |
| **1A** | WatchlistManager | 관심종목 등록/제거/상태 관리 | stateful-service | L0 |
| **1A** | SubscriptionRouter | 시세 구독 대상 동적 관리 | event | L0 |
| **1B** | MarketDataReceiver | KIS 실시간 시세 수신 | stream | L0 |
| **1B** | IndicatorCalculator | 기술지표 계산 (MA, RSI, MACD 등) | event | L0 |
| **1B** | StrategyEngine | 전략 판단 → SignalOutput 생성 | event | L0 |
| **1B** | RiskGuard | 주문 전 리스크 검증 | event | L0 |
| **1B** | DedupGuard | 중복 주문 방지 | event | L0 |
| **1B** | OrderExecutor | KIS API 주문 실행 | event | L0 |
| **1B** | TradingFSM | 포지션 상태 관리 (Idle→Entry→InPosition→Exit) | stateful-service | L0 |
| **1C** | PositionMonitor | 보유종목 실시간 손익 갱신 | stream | L0 |
| **1C** | ExitConditionGuard | 손절/익절/시간제한 조건 감시 | event | L0 |
| **1C** | ExitExecutor | 청산 주문 생성 → SubPath 1B 재진입 | event | L0 |

### 1.4 핵심 원칙

```
규칙 1: 이 Path의 어떤 노드도 LLM을 호출하지 않는다.
규칙 2: 모든 판단은 사전 정의된 수치 규칙으로만 이루어진다.
규칙 3: 주문은 반드시 Strategy → RiskGuard → DedupGuard → Broker 순서를 거친다.
규칙 4: 장애 시 안전 모드 — 신규 주문 차단, 기존 포지션 손절선만 유지.
규칙 5: 관심종목을 거치지 않고 직접 매수할 수 없다 (CANDIDATE → WATCHING 필수).
규칙 6: 포지션 보유 중 상태를 역행할 수 없다 (IN_POSITION → WATCHING 금지).
```

### 1.5 종목 상태 전이 (생명주기)

```
[CANDIDATE]    Screener가 조건에 맞는 종목 발견
     ↓
[WATCHING]     WatchlistManager에 등록, SubscriptionRouter가 시세 구독 시작
     ↓
[ENTRY_TRIGGERED] StrategyEngine이 진입 조건 충족 판단
     ↓
[IN_POSITION]  매수 체결 완료, PositionMonitor 추적 시작
     ↓
[EXIT_TRIGGERED] 청산 조건 충족, ExitExecutor가 청산 주문 생성
     ↓
[CLOSED]       청산 완료
     ↓ 분기
[WATCHING]     재감시 (조건부) — 재진입 가능
[BLACKLISTED]  폐기 (연속 손절 등) — 일정 기간 제외
[REMOVED]      워치리스트에서 완전 제거
```

**상태 전이 규칙 (강제):**

| 현재 상태 | 허용 전이 | 금지 전이 |
|-----------|----------|----------|
| CANDIDATE | → WATCHING, REMOVED | → IN_POSITION (감시 없이 직접 진입 금지) |
| WATCHING | → ENTRY_TRIGGERED, REMOVED, BLACKLISTED | → CLOSED (포지션 없이 청산 불가) |
| ENTRY_TRIGGERED | → IN_POSITION, WATCHING (주문 실패 시 복귀) | → REMOVED (주문 중 제거 금지) |
| IN_POSITION | → EXIT_TRIGGERED | → REMOVED, WATCHING (보유 중 역행 금지) |
| EXIT_TRIGGERED | → CLOSED | → WATCHING, IN_POSITION |
| CLOSED | → WATCHING (재감시), BLACKLISTED, REMOVED | → IN_POSITION |
| BLACKLISTED | → CANDIDATE (기간 만료 시), REMOVED | → WATCHING (기간 내 재감시 금지) |

### 1.6 접촉하는 Shared Store (5개)

| Store | 1A | 1B | 1C |
|-------|----|----|-----|
| MarketDataStore | Read (스크리닝용) | Read/Write (시세 저장) | — |
| PortfolioStore | — | Read/Write (체결 기록) | Read/Write (포지션 상태) |
| ConfigStore | Read (스크리닝 조건) | Read (전략 파라미터) | Read (손절/익절 파라미터) |
| KnowledgeStore | Read Only (섹터/테마) | — | — |
| **WatchlistStore** | **Read/Write** | — | **Read** |

---

## 2. SubPath 1A: Universe Management — Port Interface (3개 Port)

### 2.1 ScreenerPort — 종목 스크리닝 규격

전 종목 중 조건에 맞는 후보를 필터링한다.

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class ScreenerTimeframe(Enum):
    PRE_MARKET = "pre_market"     # 장 시작 전 (전일 데이터 기반)
    INTRADAY = "intraday"         # 장중 (실시간 데이터 기반)
    POST_MARKET = "post_market"   # 장 마감 후 (당일 데이터 기반)


class MarketType(Enum):
    KOSPI = "kospi"
    KOSDAQ = "kosdaq"
    ALL = "all"


@dataclass(frozen=True)
class ScreenerCondition:
    """스크리닝 조건 단건"""
    field: str                    # "volume", "market_cap", "change_pct", "price",
                                  # "rsi_14", "ma5_cross_ma20", "sector", "atr"
    operator: str                 # "gte", "lte", "eq", "between", "in", "cross_above", "cross_below"
    value: any                    # 1000000, [50, 200], ["반도체", "2차전지"]
    weight: float = 1.0           # 조건별 가중치 (종합 점수 계산용)


@dataclass(frozen=True)
class ScreenerProfile:
    """스크리닝 프로파일 (조건 묶음)"""
    profile_id: str               # "momentum_daily"
    name: str                     # "모멘텀 일봉 스크리너"
    market: MarketType
    conditions: list[ScreenerCondition]
    max_results: int = 30
    min_score: float = 0.0
    timeframe: ScreenerTimeframe = ScreenerTimeframe.PRE_MARKET
    exclude_symbols: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class ScreenerResult:
    """스크리닝 결과 단건"""
    symbol: str
    name: str
    score: float                  # 종합 점수 (0.0 ~ 1.0)
    matched_conditions: list[str]
    snapshot: dict                # 스크리닝 시점의 주요 수치
    # {"price": 72000, "volume": 15000000, "change_pct": 3.5,
    #  "market_cap": 430000000000000, "rsi_14": 62, "sector": "반도체"}


@dataclass(frozen=True)
class ScreenerOutput:
    """스크리닝 실행 결과"""
    profile_id: str
    candidates: list[ScreenerResult]
    total_scanned: int
    total_passed: int
    executed_at: datetime = field(default_factory=datetime.now)
    duration_ms: int = 0


class ScreenerPort(ABC):
    """
    종목 스크리닝 인터페이스.

    KIS 조건검색이든, 자체 DB 스캔이든, 외부 서비스든
    이 규격만 맞추면 교체 가능.

    L0: 모든 조건은 수치 기반. LLM 호출 없음.
    """

    @abstractmethod
    async def scan(self, profile: ScreenerProfile) -> ScreenerOutput:
        """
        스크리닝 실행.
        profile의 조건에 따라 전 종목 필터링.
        Returns: 조건 충족 후보 목록 (score 내림차순)
        """
        ...

    @abstractmethod
    async def scan_realtime(
        self, profile: ScreenerProfile, current_quotes: dict[str, dict]
    ) -> ScreenerOutput:
        """
        장중 실시간 스크리닝.
        current_quotes: 현재 시세 스냅샷.
        장중에는 전 종목 API 호출 대신 등락률/거래량 순위 API 활용.
        """
        ...

    @abstractmethod
    async def get_profiles(self) -> list[ScreenerProfile]:
        """등록된 스크리닝 프로파일 목록."""
        ...

    @abstractmethod
    async def save_profile(self, profile: ScreenerProfile) -> bool:
        """스크리닝 프로파일 저장/수정."""
        ...
```

**Adapters:**
- KISScreenerAdapter — KIS 조건검색 API + 등락률/거래량 순위 API (운영)
- DBScreenerAdapter — PostgreSQL 저장 시세 기반 자체 스캔 (보조)
- MockScreenerAdapter — 테스트용

---

### 2.2 WatchlistPort — 관심종목 관리 규격

관심종목의 등록, 제거, 상태 관리, 우선순위 조정을 담당한다. 종목 생명주기의 중심 허브.

```python
class WatchlistStatus(Enum):
    CANDIDATE = "candidate"
    WATCHING = "watching"
    ENTRY_TRIGGERED = "entry_triggered"
    IN_POSITION = "in_position"
    EXIT_TRIGGERED = "exit_triggered"
    CLOSED = "closed"
    BLACKLISTED = "blacklisted"
    REMOVED = "removed"


@dataclass
class WatchlistEntry:
    """워치리스트 항목"""
    symbol: str
    name: str
    status: WatchlistStatus
    priority: int                 # 1 = 최고 우선순위
    added_at: datetime
    source: str                   # "screener:momentum_daily" | "manual" | "knowledge"
    screener_score: float
    entry_conditions: dict        # 진입 조건 (전략별)
    # {"strategy_id": "ma_cross", "trigger": "ma5_cross_above_ma20",
    #  "confirm": "volume > ma_volume_20 * 1.5"}
    current_price: float = 0.0
    price_at_add: float = 0.0
    change_since_add_pct: float = 0.0
    last_signal_at: datetime | None = None
    consecutive_losses: int = 0   # 연속 손절 횟수 (블랙리스트 판단용)
    metadata: dict = field(default_factory=dict)
    updated_at: datetime = field(default_factory=datetime.now)


@dataclass(frozen=True)
class WatchlistSummary:
    """워치리스트 요약"""
    total: int
    by_status: dict               # {"watching": 15, "in_position": 5}
    max_capacity: int
    available_slots: int
    last_screening_at: datetime | None


class WatchlistPort(ABC):
    """
    관심종목 관리 인터페이스.

    메모리 기반이든, DB 기반이든, Redis 기반이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def add(
        self, symbol: str, name: str,
        source: str, score: float = 0.0,
        entry_conditions: dict | None = None,
        priority: int = 50
    ) -> WatchlistEntry:
        """
        관심종목 추가.
        이미 존재하면 score/priority만 갱신.
        max_capacity 초과 시 최저 priority 종목 자동 제거.
        """
        ...

    @abstractmethod
    async def remove(self, symbol: str, reason: str = "") -> bool:
        """관심종목 제거. 상태를 REMOVED로 전환."""
        ...

    @abstractmethod
    async def update_status(
        self, symbol: str, new_status: WatchlistStatus,
        metadata: dict | None = None
    ) -> WatchlistEntry:
        """
        종목 상태 전이. 유효한 전이만 허용 (Section 1.5 규칙 참조).
        """
        ...

    @abstractmethod
    async def get(self, symbol: str) -> WatchlistEntry | None:
        """단일 종목 조회."""
        ...

    @abstractmethod
    async def get_by_status(self, status: WatchlistStatus) -> list[WatchlistEntry]:
        """상태별 종목 목록."""
        ...

    @abstractmethod
    async def get_watching(self) -> list[WatchlistEntry]:
        """현재 감시 중인 종목 목록 (시세 구독 대상)."""
        ...

    @abstractmethod
    async def get_in_position(self) -> list[WatchlistEntry]:
        """현재 보유 중인 종목 목록."""
        ...

    @abstractmethod
    async def get_summary(self) -> WatchlistSummary:
        """워치리스트 요약 통계."""
        ...

    @abstractmethod
    async def blacklist(
        self, symbol: str, duration_days: int = 7, reason: str = ""
    ) -> bool:
        """블랙리스트 등록. duration_days 후 자동 해제."""
        ...

    @abstractmethod
    async def promote(
        self, candidates: list[ScreenerResult], max_add: int = 10
    ) -> list[WatchlistEntry]:
        """
        스크리닝 결과에서 상위 후보를 WATCHING으로 승격.
        기존 WATCHING 종목과 중복 제거.
        """
        ...

    @abstractmethod
    async def cleanup_stale(self, max_watching_days: int = 5) -> list[str]:
        """오래된 WATCHING 종목 정리. Returns: 제거된 종목 코드."""
        ...
```

**Adapters:**
- PostgresWatchlistAdapter — PostgreSQL 기반 (운영)
- RedisWatchlistAdapter — Redis 기반 (빠른 상태 전이, 대안)
- InMemoryWatchlistAdapter — 메모리 기반 (백테스트)
- MockWatchlistAdapter — 테스트용

---

### 2.3 SubscriptionPort — 시세 구독 동적 관리 규격

WatchlistManager의 상태 변경에 따라 MarketDataReceiver의 구독 목록을 동적으로 조정한다.

```python
@dataclass(frozen=True)
class SubscriptionChange:
    """구독 변경 이벤트"""
    action: str                   # "subscribe" | "unsubscribe"
    symbol: str
    reason: str                   # "screener_add" | "position_closed" | "capacity_full"
    priority: int
    timestamp: datetime = field(default_factory=datetime.now)


@dataclass(frozen=True)
class SubscriptionState:
    """현재 구독 상태"""
    active_symbols: list[str]
    watching_count: int
    position_count: int
    max_subscriptions: int
    available_slots: int


class SubscriptionPort(ABC):
    """
    시세 구독 동적 관리 인터페이스.

    WebSocket 구독 관리든, 폴링 대상 관리든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def apply_changes(
        self, changes: list[SubscriptionChange]
    ) -> SubscriptionState:
        """구독 변경 적용. Returns: 변경 후 구독 상태."""
        ...

    @abstractmethod
    async def get_state(self) -> SubscriptionState:
        """현재 구독 상태."""
        ...

    @abstractmethod
    async def sync_with_watchlist(
        self, watching: list[str], in_position: list[str]
    ) -> list[SubscriptionChange]:
        """
        워치리스트와 구독 상태 동기화.
        WATCHING + IN_POSITION 종목은 반드시 구독. 그 외는 해제.
        """
        ...

    @abstractmethod
    async def enforce_capacity(self, max_subscriptions: int) -> list[SubscriptionChange]:
        """
        구독 수 상한 강제.
        초과 시 priority 낮은 WATCHING 종목부터 해제.
        IN_POSITION 종목은 절대 해제 불가.
        """
        ...
```

**Adapters:**
- WebSocketSubscriptionAdapter — KIS WebSocket 구독 관리 (운영)
- PollingSubscriptionAdapter — REST 폴링 대상 관리 (fallback)
- MockSubscriptionAdapter — 테스트용

---

## 3. SubPath 1B: Trade Execution — Port Interface (4개 Port)

### 3.1 MarketDataPort — 시세 수신 규격

```python
class MarketStatus(Enum):
    PRE_MARKET = "pre_market"
    OPEN = "open"
    CLOSING = "closing"
    CLOSED = "closed"
    HOLIDAY = "holiday"


@dataclass(frozen=True)
class Quote:
    """현재가 스냅샷 — KIS inquire_price 응답 기반"""
    symbol: str
    name: str
    price: int
    change: int
    change_pct: float
    volume: int
    amount: int
    open: int
    high: int
    low: int
    prev_close: int
    ask_price: int
    bid_price: int
    timestamp: datetime = field(default_factory=datetime.now)


@dataclass(frozen=True)
class OHLCV:
    """봉 데이터"""
    symbol: str
    date: str
    open: int
    high: int
    low: int
    close: int
    volume: int
    amount: int | None = None


class MarketDataPort(ABC):
    """
    시세 수신 인터페이스.

    KIS WebSocket이든, REST polling이든, CSV replay든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def subscribe(self, symbols: list[str]) -> None:
        """종목 실시간 시세 구독 시작."""
        ...

    @abstractmethod
    async def unsubscribe(self, symbols: list[str]) -> None:
        """시세 구독 해제."""
        ...

    @abstractmethod
    async def on_tick(self, callback: callable) -> None:
        """틱 수신 콜백 등록. 새로운 시세가 도착할 때마다 callback(quote) 호출."""
        ...

    @abstractmethod
    async def get_quote(self, symbol: str) -> Quote:
        """단일 종목 현재가 조회 (REST)."""
        ...

    @abstractmethod
    async def get_ohlcv(
        self, symbol: str, timeframe: str = "1d", count: int = 60
    ) -> list[OHLCV]:
        """과거 봉 데이터 조회. timeframe: "1m"|"5m"|"15m"|"1d"|"1w" """
        ...

    @abstractmethod
    async def get_market_status(self) -> MarketStatus:
        """현재 장 상태."""
        ...

    @abstractmethod
    async def connect(self) -> None:
        """시세 연결 초기화."""
        ...

    @abstractmethod
    async def disconnect(self) -> None:
        """시세 연결 종료."""
        ...

    @abstractmethod
    async def health_check(self) -> bool:
        """연결 상태 확인."""
        ...
```

**Adapters:**
- KISWebSocketAdapter — KIS WebSocket 실시간 (운영)
- KISRestPollingAdapter — KIS REST API 폴링 (fallback)
- CSVReplayAdapter — CSV 파일 리플레이 (백테스트)
- MockMarketDataAdapter — 테스트용

---

### 3.2 BrokerPort — 주문 실행 규격

```python
class OrderSide(Enum):
    BUY = "buy"
    SELL = "sell"

class OrderType(Enum):
    LIMIT = "limit"
    MARKET = "market"
    CONDITIONAL = "conditional"
    BEST = "best"

class OrderStatus(Enum):
    CREATED = "created"
    SUBMITTED = "submitted"
    ACCEPTED = "accepted"
    PARTIALLY_FILLED = "partially_filled"
    FILLED = "filled"
    CANCELLED = "cancelled"
    REJECTED = "rejected"


@dataclass(frozen=True)
class OrderRequest:
    """주문 요청 — 전략 엔진이 생성"""
    symbol: str
    side: OrderSide
    quantity: int
    order_type: OrderType
    price: int | None = None
    strategy_id: str = ""
    stop_loss: float | None = None
    take_profit: float | None = None


@dataclass
class OrderResult:
    """주문 결과 — 브로커가 반환"""
    order_id: str
    symbol: str
    side: OrderSide
    status: OrderStatus
    requested_qty: int
    filled_qty: int = 0
    filled_price: float = 0.0
    commission: float = 0.0
    message: str = ""
    submitted_at: datetime = field(default_factory=datetime.now)
    filled_at: datetime | None = None


@dataclass(frozen=True)
class Position:
    """보유 종목"""
    symbol: str
    name: str
    quantity: int
    avg_price: float
    current_price: float
    unrealized_pnl: float
    unrealized_pnl_pct: float


@dataclass(frozen=True)
class AccountSummary:
    """계좌 요약"""
    total_equity: float
    cash: float
    invested: float
    total_pnl: float
    total_pnl_pct: float
    positions: list[Position]


class BrokerPort(ABC):
    """
    주문 실행 / 계좌 조회 인터페이스.

    KIS MCP든, KIS REST든, eBest든, Mock이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def submit_order(self, order: OrderRequest) -> OrderResult:
        """주문 제출."""
        ...

    @abstractmethod
    async def cancel_order(self, order_id: str) -> bool:
        """주문 취소."""
        ...

    @abstractmethod
    async def get_order_status(self, order_id: str) -> OrderResult:
        """주문 상태 조회."""
        ...

    @abstractmethod
    async def get_pending_orders(self) -> list[OrderResult]:
        """미체결 주문 목록."""
        ...

    @abstractmethod
    async def get_account(self) -> AccountSummary:
        """계좌 잔고 + 보유종목 조회."""
        ...

    @abstractmethod
    async def connect(self) -> None:
        """인증 및 연결 초기화."""
        ...

    @abstractmethod
    async def disconnect(self) -> None:
        """연결 종료."""
        ...

    @abstractmethod
    async def health_check(self) -> bool:
        """연결 상태 확인."""
        ...
```

**Adapters:**
- KISMCPAdapter — KIS MCP 서버 경유 (운영 기본)
- KISRestAdapter — KIS REST API 직접 호출 (fallback)
- MockBrokerAdapter — 테스트용
- EBestAdapter — eBest (미래)

---

### 3.3 StoragePort — 데이터 영속화 규격

```python
@dataclass(frozen=True)
class TradeRecord:
    """체결 기록"""
    trade_id: str
    order_id: str
    symbol: str
    side: OrderSide
    quantity: int
    price: float
    commission: float
    strategy_id: str
    traded_at: datetime


@dataclass(frozen=True)
class MarketSnapshot:
    """시세 스냅샷"""
    snapshot_id: str
    timestamp: datetime
    quotes: list[Quote]
    cycle: int


class StoragePort(ABC):
    """
    데이터 영속화 인터페이스.

    PostgreSQL이든, SQLite든, JSON 파일이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def save_snapshot(self, snapshot: MarketSnapshot) -> None:
        """시세 스냅샷 저장."""
        ...

    @abstractmethod
    async def save_trade(self, trade: TradeRecord) -> None:
        """체결 기록 저장."""
        ...

    @abstractmethod
    async def save_event(self, event: dict) -> None:
        """이벤트 로그 저장."""
        ...

    @abstractmethod
    async def get_trades(
        self, start_date: str, end_date: str, symbol: str | None = None
    ) -> list[TradeRecord]:
        """기간별 체결 기록 조회."""
        ...

    @abstractmethod
    async def get_snapshots(self, date: str) -> list[MarketSnapshot]:
        """특정일 시세 스냅샷 조회."""
        ...

    @abstractmethod
    async def get_last_state(self) -> dict | None:
        """마지막 저장된 시스템 상태. 엔진 재시작 시 복원용."""
        ...

    @abstractmethod
    async def save_state(self, state: dict) -> None:
        """현재 시스템 상태 저장."""
        ...
```

**Adapters:**
- PostgresStorageAdapter — PostgreSQL (운영)
- SQLiteStorageAdapter — SQLite (로컬 개발)
- JSONFileStorageAdapter — JSON 파일 (PRD 호환)
- MockStorageAdapter — 테스트용

---

### 3.4 ClockPort — 시장 시간 규격

```python
class ClockPort(ABC):
    """
    시장 시간 판단 인터페이스.

    KRX(한국)든, NYSE(미국)든, 테스트용(항상 장중)이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def get_status(self) -> MarketStatus:
        """현재 장 상태."""
        ...

    @abstractmethod
    async def is_trading_day(self, date: str | None = None) -> bool:
        """영업일 여부. None이면 오늘."""
        ...

    @abstractmethod
    async def next_open_time(self) -> datetime:
        """다음 장 시작 시각."""
        ...

    @abstractmethod
    async def time_until_close(self) -> int | None:
        """장 마감까지 남은 초. 장중 아니면 None."""
        ...
```

**Adapters:**
- KRXClockAdapter — KRX 영업일 + 공휴일 (운영)
- AlwaysOpenClockAdapter — 항상 장중 (테스트)
- HistoricalClockAdapter — 과거 시점 시뮬레이션 (백테스트)
- MockClockAdapter — 테스트용

---

## 4. SubPath 1C: Position Tracking — Port Interface (3개 Port)

### 4.1 PositionMonitorPort — 실시간 포지션 감시 규격

```python
@dataclass
class LivePosition:
    """실시간 포지션 (틱마다 갱신)"""
    symbol: str
    name: str
    strategy_id: str
    quantity: int
    avg_entry_price: float
    current_price: float
    unrealized_pnl: float
    unrealized_pnl_pct: float
    highest_price: float          # 보유 기간 최고가 (trailing stop용)
    lowest_price: float
    drawdown_from_high_pct: float
    entry_time: datetime
    holding_seconds: int
    last_tick_at: datetime
    volume_since_entry: int
    tick_count: int


@dataclass(frozen=True)
class PositionAlert:
    """포지션 알림 이벤트"""
    symbol: str
    alert_type: str               # "approaching_stop_loss" | "new_high" | "time_limit_warning"
    message: str
    current_values: dict
    threshold_values: dict
    severity: str                 # "info" | "warning" | "critical"
    timestamp: datetime = field(default_factory=datetime.now)


class PositionMonitorPort(ABC):
    """
    실시간 포지션 감시 인터페이스.
    """

    @abstractmethod
    async def update_tick(self, symbol: str, quote: dict) -> LivePosition:
        """틱 수신 시 포지션 갱신. 최고가/최저가, 손익, drawdown 재계산."""
        ...

    @abstractmethod
    async def register_position(
        self, symbol: str, strategy_id: str,
        quantity: int, avg_price: float, entry_time: datetime
    ) -> LivePosition:
        """신규 포지션 등록 (매수 체결 시). 추적 시작."""
        ...

    @abstractmethod
    async def unregister_position(self, symbol: str) -> dict:
        """포지션 제거 (청산 완료 시). Returns: 최종 포지션 요약."""
        ...

    @abstractmethod
    async def get_all_live(self) -> list[LivePosition]:
        """현재 추적 중인 모든 포지션."""
        ...

    @abstractmethod
    async def get_position(self, symbol: str) -> LivePosition | None:
        """단일 포지션 조회."""
        ...

    @abstractmethod
    async def get_alerts(self) -> list[PositionAlert]:
        """미확인 포지션 알림 목록."""
        ...
```

**Adapters:**
- InMemoryPositionMonitorAdapter — 메모리 기반 실시간 갱신 (운영)
- MockPositionMonitorAdapter — 테스트용

---

### 4.2 ExitConditionPort — 청산 조건 감시 규격

```python
class ExitType(Enum):
    STOP_LOSS = "stop_loss"
    TAKE_PROFIT = "take_profit"
    TRAILING_STOP = "trailing_stop"
    TIME_LIMIT = "time_limit"
    STRATEGY_EXIT = "strategy_exit"
    FORCE_CLOSE = "force_close"


@dataclass(frozen=True)
class ExitRule:
    """청산 규칙"""
    exit_type: ExitType
    params: dict
    # STOP_LOSS:      {"threshold_pct": -3.0}
    # TAKE_PROFIT:    {"threshold_pct": 5.0}
    # TRAILING_STOP:  {"trail_pct": 2.0, "activation_pct": 1.5}
    # TIME_LIMIT:     {"max_holding_minutes": 180}
    # FORCE_CLOSE:    {"minutes_before_close": 3}
    priority: int = 1


@dataclass(frozen=True)
class ExitSignal:
    """청산 신호"""
    symbol: str
    exit_type: ExitType
    trigger_price: float
    current_pnl_pct: float
    reason: str
    urgency: str                  # "normal" | "urgent" | "immediate"
    suggested_order_type: str     # "market" | "limit"
    suggested_price: float | None
    rule: ExitRule
    timestamp: datetime = field(default_factory=datetime.now)


class ExitConditionPort(ABC):
    """
    청산 조건 감시 인터페이스.
    """

    @abstractmethod
    async def evaluate(self, position: LivePosition) -> ExitSignal | None:
        """
        포지션에 대한 청산 조건 평가.
        조건 충족 시 ExitSignal 반환, 미충족 시 None.
        """
        ...

    @abstractmethod
    async def set_rules(self, symbol: str, rules: list[ExitRule]) -> bool:
        """종목별 청산 규칙 설정. 전략이 매수할 때 함께 설정."""
        ...

    @abstractmethod
    async def get_rules(self, symbol: str) -> list[ExitRule]:
        """종목의 현재 청산 규칙 조회."""
        ...

    @abstractmethod
    async def update_trailing_stop(self, symbol: str, new_high: float) -> ExitRule | None:
        """트레일링 스탑 갱신. Returns: 갱신된 규칙 또는 None."""
        ...

    @abstractmethod
    async def add_force_close(self, symbols: list[str], reason: str) -> int:
        """강제 청산 규칙 추가. Returns: 적용된 종목 수."""
        ...
```

**Adapters:**
- RuleBasedExitAdapter — 규칙 기반 (운영)
- StrategyLinkedExitAdapter — 전략 연동 (전략이 청산 조건 자체 관리)
- MockExitAdapter — 테스트용

---

### 4.3 ExitExecutorPort — 청산 실행 규격

```python
@dataclass(frozen=True)
class ExitOrderRequest:
    """청산 주문 요청"""
    symbol: str
    quantity: int
    exit_type: ExitType
    order_type: str               # "market" | "limit"
    price: float | None
    urgency: str
    reason: str
    original_entry_price: float
    expected_pnl_pct: float
    correlation_id: str


@dataclass(frozen=True)
class ExitResult:
    """청산 실행 결과"""
    symbol: str
    exit_type: ExitType
    success: bool
    order_id: str | None
    message: str
    actual_pnl_pct: float | None
    post_action: str              # "return_to_watchlist" | "blacklist" | "remove"


class ExitExecutorPort(ABC):
    """
    청산 실행 인터페이스.
    """

    @abstractmethod
    async def execute_exit(self, request: ExitOrderRequest) -> ExitResult:
        """
        청산 실행.
        OrderRequest(side=SELL)로 변환하여 SubPath 1B 재진입.
        """
        ...

    @abstractmethod
    async def determine_post_action(
        self, symbol: str, exit_result: ExitResult, consecutive_losses: int
    ) -> str:
        """
        청산 후 행동 결정.
        익절/첫 손절: "return_to_watchlist"
        연속 3회+ 손절: "blacklist"
        """
        ...

    @abstractmethod
    async def get_exit_history(
        self, symbol: str | None = None, limit: int = 50
    ) -> list[ExitResult]:
        """청산 이력 조회."""
        ...
```

**Adapters:**
- PipelineExitAdapter — SubPath 1B 파이프라인 재진입 (운영)
- DirectExitAdapter — BrokerPort 직접 청산 (긴급)
- MockExitAdapter — 테스트용

---

## 5. Domain Types 정의 (Path 1 전체)

### 5.1 Enum 정의 (8종)

```python
class MarketStatus(Enum):       # PRE_MARKET, OPEN, CLOSING, CLOSED, HOLIDAY
class MarketType(Enum):         # KOSPI, KOSDAQ, ALL
class ScreenerTimeframe(Enum):  # PRE_MARKET, INTRADAY, POST_MARKET
class WatchlistStatus(Enum):    # CANDIDATE~REMOVED (8종)
class OrderSide(Enum):          # BUY, SELL
class OrderType(Enum):          # LIMIT, MARKET, CONDITIONAL, BEST
class OrderStatus(Enum):        # CREATED~REJECTED (7종)
class ExitType(Enum):           # STOP_LOSS~FORCE_CLOSE (6종)
```

### 5.2 Core Data Types (18종)

| Type | SubPath | 주요 필드 |
|------|---------|----------|
| ScreenerCondition | 1A | field, operator, value, weight |
| ScreenerProfile | 1A | conditions, market, max_results, timeframe |
| ScreenerResult | 1A | symbol, score, matched_conditions, snapshot |
| ScreenerOutput | 1A | candidates, total_scanned, total_passed |
| WatchlistEntry | 1A | symbol, status, priority, entry_conditions, consecutive_losses |
| SubscriptionChange | 1A | action, symbol, reason, priority |
| Quote | 1B | symbol, price, change_pct, volume, ask/bid |
| OHLCV | 1B | open, high, low, close, volume |
| OrderRequest | 1B | symbol, side, quantity, order_type, strategy_id |
| OrderResult | 1B | order_id, status, filled_qty, filled_price |
| Position | 1B | symbol, quantity, avg_price, unrealized_pnl |
| AccountSummary | 1B | total_equity, cash, positions |
| LivePosition | 1C | symbol, qty, current_price, unrealized_pnl, highest_price, drawdown |
| PositionAlert | 1C | symbol, alert_type, severity, threshold_values |
| ExitRule | 1C | exit_type, params, priority |
| ExitSignal | 1C | symbol, exit_type, trigger_price, urgency |
| ExitOrderRequest | 1C | symbol, quantity, exit_type, urgency, expected_pnl_pct |
| ExitResult | 1C | symbol, success, actual_pnl_pct, post_action |

---

## 6. 데이터 흐름 (Edge 정의, 23개)

### 6.1 SubPath 1A 내부 + 1A↔External (7 Edges)

| # | Edge ID | Source → Target | Type/Role | 데이터 |
|---|---------|----------------|-----------|--------|
| 1 | e_screener_to_watchlist | Screener → WatchlistManager | DataFlow/DataPipe | ScreenerOutput |
| 2 | e_watchlist_to_subscription | WatchlistManager → SubscriptionRouter | Event/EventNotify | SubscriptionChange[] |
| 3 | e_subscription_to_market_data | SubscriptionRouter → MarketDataReceiver | Event/Command | SubscriptionChange[] |
| 4 | e_watchlist_to_store | WatchlistManager → WatchlistStore | DataFlow/DataPipe | WatchlistEntry |
| 5 | e_market_store_to_screener | MarketDataStore → Screener | Dependency/ConfigRef | OHLCV |
| 6 | e_market_to_screener_realtime | MarketDataReceiver → Screener | DataFlow/DataPipe | dict[str,Quote] |
| 7 | e_knowledge_to_screener | KnowledgeStore → Screener | Dependency/ConfigRef | 섹터/테마 정보 |

### 6.2 SubPath 1B 내부 + 1B↔External (9 Edges) — 기존 v1.0 그대로

| # | Edge ID | Source → Target | Type/Role | 데이터 |
|---|---------|----------------|-----------|--------|
| 8 | e_market_data_to_indicator | MarketDataReceiver → IndicatorCalculator | DataFlow/DataPipe | Quote |
| 9 | e_indicator_to_strategy | IndicatorCalculator → StrategyEngine | DataFlow/DataPipe | IndicatorResult |
| 10 | e_strategy_to_riskguard | StrategyEngine → RiskGuard | DataFlow/DataPipe | SignalOutput |
| 11 | e_riskguard_to_dedup | RiskGuard → DedupGuard | DataFlow/DataPipe | OrderRequest |
| 12 | e_dedup_to_executor | DedupGuard → OrderExecutor | DataFlow/DataPipe | OrderRequest |
| 13 | e_executor_to_fsm | OrderExecutor → TradingFSM | Event/EventNotify | OrderResult |
| 14 | e_market_to_store | MarketDataReceiver → MarketDataStore | DataFlow/DataPipe | Quote/OHLCV |
| 15 | e_executor_to_portfolio | OrderExecutor → PortfolioStore | DataFlow/DataPipe | TradeRecord |
| 16 | e_config_to_fsm | ConfigStore → TradingFSM | Dependency/ConfigRef | StrategyConfig |

### 6.3 SubPath 간 연결 (5 Edges)

| # | Edge ID | Source → Target | Type/Role | 데이터 |
|---|---------|----------------|-----------|--------|
| 17 | e_executor_to_position_monitor | OrderExecutor → PositionMonitor | Event/EventNotify | OrderResult (매수 체결) |
| 18 | e_market_to_position_monitor | MarketDataReceiver → PositionMonitor | DataFlow/DataPipe | Quote (보유종목 틱) |
| 19 | e_position_monitor_to_watchlist | PositionMonitor → WatchlistManager | Event/EventNotify | WatchlistStatus update |
| 20 | e_exit_executor_to_riskguard | ExitExecutor → RiskGuard | DataFlow/DataPipe | OrderRequest (side=SELL, 1B 재진입) |
| 21 | e_exit_result_to_watchlist | ExitExecutor → WatchlistManager | Event/EventNotify | ExitResult (청산 후 상태 전이) |

### 6.4 SubPath 1C 내부 (2 Edges)

| # | Edge ID | Source → Target | Type/Role | 데이터 |
|---|---------|----------------|-----------|--------|
| 22 | e_monitor_to_exit_guard | PositionMonitor → ExitConditionGuard | DataFlow/DataPipe | LivePosition |
| 23 | e_exit_guard_to_executor | ExitConditionGuard → ExitExecutor | DataFlow/DataPipe | ExitSignal |

---

## 7. Shared Store 스키마

### 7.1 WatchlistStore (신규)

```sql
CREATE TABLE watchlist (
    symbol          TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'candidate',
    priority        INT NOT NULL DEFAULT 50,
    source          TEXT NOT NULL,
    screener_score  FLOAT DEFAULT 0.0,
    entry_conditions JSONB,
    price_at_add    FLOAT,
    consecutive_losses INT DEFAULT 0,
    blacklisted_until TIMESTAMPTZ,
    metadata        JSONB DEFAULT '{}',
    added_at        TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE watchlist_history (
    id              BIGSERIAL PRIMARY KEY,
    symbol          TEXT NOT NULL,
    old_status      TEXT,
    new_status      TEXT NOT NULL,
    reason          TEXT,
    metadata        JSONB,
    changed_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE exit_history (
    exit_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol          TEXT NOT NULL,
    exit_type       TEXT NOT NULL,
    entry_price     FLOAT NOT NULL,
    exit_price      FLOAT NOT NULL,
    quantity        INT NOT NULL,
    pnl_pct         FLOAT NOT NULL,
    holding_seconds INT,
    reason          TEXT,
    post_action     TEXT,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE screener_profiles (
    profile_id      TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    market          TEXT NOT NULL DEFAULT 'all',
    conditions      JSONB NOT NULL,
    max_results     INT DEFAULT 30,
    timeframe       TEXT DEFAULT 'pre_market',
    exclude_symbols TEXT[],
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_watchlist_status ON watchlist(status);
CREATE INDEX idx_watchlist_priority ON watchlist(priority);
CREATE INDEX idx_watchlist_history_symbol ON watchlist_history(symbol, changed_at);
CREATE INDEX idx_exit_history_symbol ON exit_history(symbol, executed_at);
```

---

## 8. Safeguard 적용

### 8.1 SubPath 1A Safeguard

```
Screener 실행
    → [CapacityGuard]       max_watching 초과 시 최저 priority 제거 후 추가
    → [DuplicateGuard]      이미 WATCHING/IN_POSITION인 종목 중복 추가 방지
    → [BlacklistGuard]      블랙리스트 기간 내 종목 필터링
    → WatchlistManager
    → [SubscriptionCapGuard] WebSocket 구독 상한(40~100종목) 강제
    → SubscriptionRouter
```

### 8.2 SubPath 1B Safeguard (기존)

```
StrategyEngine (SignalOutput 생성)
    → [RiskGuard]           손절/일일한도/포지션한도/섹터한도 검증
    → [DedupGuard]          동일 종목 동일 방향 중복 주문 차단
    → [RateLimiter]         API 호출 속도 제한
    → BrokerPort.submit_order()
```

### 8.3 SubPath 1C Safeguard

```
ExitConditionGuard 청산 조건 충족
    → [ExitDedupGuard]      동일 종목 청산 주문 중복 방지 (이미 EXIT_TRIGGERED면 차단)
    → [MarketPhaseGuard]    마감 동시호가 중 시장가 주문 차단
    → ExitExecutor
    → SubPath 1B 재진입 (RiskGuard → DedupGuard → OrderExecutor)
```

### 8.4 4대 취약점 방어 (Path 1 적용분)

| 취약점 | 방어 | 구현 노드 |
|--------|------|----------|
| 중복 주문 | DedupGuard + ExitDedupGuard | DedupGuard, ExitConditionGuard |
| 상태-계좌 불일치 | TradingFSM 상태와 브로커 실계좌 주기적 대조 | TradingFSM + BrokerPort |
| 이벤트 유실 | WAL 패턴: 주문 전 이벤트 로그 선기록 | StoragePort |
| 장애 전파 | Circuit Breaker: 연속 실패 시 안전 모드 전환 | OrderExecutor |

---

## 9. Adapter Mapping 요약 (전체)

| SubPath | Port | 운영 | 개발 | 테스트 |
|---------|------|------|------|--------|
| 1A | ScreenerPort | KISScreenerAdapter | DBScreenerAdapter | MockScreenerAdapter |
| 1A | WatchlistPort | PostgresWatchlistAdapter | InMemoryWatchlistAdapter | MockWatchlistAdapter |
| 1A | SubscriptionPort | WebSocketSubscriptionAdapter | PollingSubscriptionAdapter | MockSubscriptionAdapter |
| 1B | MarketDataPort | KISWebSocketAdapter | KISRestPollingAdapter | MockMarketDataAdapter |
| 1B | BrokerPort | KISMCPAdapter | KISRestAdapter | MockBrokerAdapter |
| 1B | StoragePort | PostgresStorageAdapter | SQLiteStorageAdapter | MockStorageAdapter |
| 1B | ClockPort | KRXClockAdapter | AlwaysOpenClockAdapter | MockClockAdapter |
| 1C | PositionMonitorPort | InMemoryPositionMonitorAdapter | InMemoryPositionMonitorAdapter | MockPositionMonitorAdapter |
| 1C | ExitConditionPort | RuleBasedExitAdapter | RuleBasedExitAdapter | MockExitAdapter |
| 1C | ExitExecutorPort | PipelineExitAdapter | PipelineExitAdapter | MockExitAdapter |

**YAML 설정 예시:**

```yaml
path1_realtime:
  # SubPath 1A: Universe Management
  screener:
    implementation: KISScreenerAdapter
    params:
      rank_api: true
      scan_interval_minutes: 30
      pre_market_scan_time: "08:30"

  watchlist:
    implementation: PostgresWatchlistAdapter
    params:
      dsn: ${POSTGRES_DSN}
      max_watching: 30
      max_in_position: 10
      stale_watching_days: 5
      blacklist_default_days: 7

  subscription:
    implementation: WebSocketSubscriptionAdapter
    params:
      max_subscriptions: 50
      priority_protect_in_position: true

  # SubPath 1B: Trade Execution
  market_data:
    implementation: KISWebSocketAdapter
    params:
      app_key: ${KIS_APP_KEY}
      app_secret: ${KIS_APP_SECRET}
      subscription_type: "realtime"

  broker:
    implementation: KISMCPAdapter
    params:
      base_url: "http://localhost:3000"
      env: "demo"
      fallback: KISRestAdapter

  storage:
    implementation: PostgresStorageAdapter
    params:
      dsn: ${POSTGRES_DSN}

  clock:
    implementation: KRXClockAdapter
    params:
      timezone: "Asia/Seoul"
      holiday_source: "krx_api"

  # SubPath 1C: Position Tracking
  position_monitor:
    implementation: InMemoryPositionMonitorAdapter
    params:
      tick_buffer_size: 100

  exit_condition:
    implementation: RuleBasedExitAdapter
    params:
      default_stop_loss_pct: -3.0
      default_take_profit_pct: 5.0
      trailing_stop_pct: 2.0
      trailing_activation_pct: 1.5
      max_holding_minutes: 360
      force_close_before_market_close_minutes: 3

  exit_executor:
    implementation: PipelineExitAdapter
    params:
      reentry_point: RiskGuard
      consecutive_loss_blacklist: 3
      default_exit_order_type: market
```

---

## 10. 다음 단계

- Edge Contract Definition 갱신 (Path 1: 9 → 23 Edges)
- System Manifest — 전체 노드(~38개) + Port(31개) + Edge(68개) 통합
- KIS Adapter 구현 (MarketDataPort + BrokerPort + ScreenerPort)

---

*End of Document — Port Interface Path 1 v2.0*
*3 SubPaths | 13 Nodes | 10 Ports | 18 Domain Types | 23 Edges | 1 New Shared Store*
*전체 L0 — 트레이딩 핵심 경로에 LLM 0건*
*대체: port_interface_path1_v1.0.md + port_interface_path1_extension_v1.0.md*
