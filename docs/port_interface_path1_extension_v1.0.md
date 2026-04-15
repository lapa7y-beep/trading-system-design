# Port Interface Design — Path 1 Extension: Universe & Position Tracking

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | port_interface_path1_extension_v1.0 |
| Path | Path 1: Realtime Trading (SubPath 1A, 1C 추가) |
| 선행 문서 | port_interface_path1_v1.0, edge_contract_definition_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |

---

## 0. 설계 동기

> **"어떤 종목의 시세를 받을 것인가"가 없으면 트레이딩이 아니다.**

기존 Path 1은 "시세가 들어오면 전략이 판단한다"로 시작했다. 하지만 실전에서는:
- 전 종목 중 **조건에 맞는 종목을 스크리닝**해서 관심종목으로 등록하고
- 관심종목의 시세를 **집중 감시**하다가
- 진입 조건 충족 시 **매수**하고
- 보유 중인 종목의 **실시간 손익을 추적**하면서
- 손절/익절 조건 충족 시 **청산**하고
- 청산 후 **재감시 또는 폐기**하는

이 전체 생명주기가 하나의 연속된 흐름이다.

---

## 1. Path 1 SubPath 구조

### 1.1 기존 → 확장

```
[기존]  Path 1: 7개 노드 (시세수신 → 주문실행)
    ↓
[확장]  Path 1: 3개 SubPath, 13개 노드

  SubPath 1A: Universe Management (종목 유니버스)  — 3개 노드
  SubPath 1B: Trade Execution (매매 실행)          — 7개 노드 (기존 그대로)
  SubPath 1C: Position Tracking (포지션 추적)      — 3개 노드
```

### 1.2 전체 노드 구성 (13개)

| SubPath | 노드 ID | 역할 | runMode | LLM Level |
|---------|---------|------|---------|-----------|
| **1A** | Screener | 전 종목 조건 필터링 | batch | L0 |
| **1A** | WatchlistManager | 관심종목 등록/제거/상태 관리 | stateful-service | L0 |
| **1A** | SubscriptionRouter | 시세 구독 대상 동적 관리 | event | L0 |
| **1B** | MarketDataReceiver | 실시간 시세 수신 | stream | L0 |
| **1B** | IndicatorCalculator | 기술지표 계산 | event | L0 |
| **1B** | StrategyEngine | 전략 판단 → SignalOutput | event | L0 |
| **1B** | RiskGuard | 주문 전 리스크 검증 | event | L0 |
| **1B** | DedupGuard | 중복 주문 방지 | event | L0 |
| **1B** | OrderExecutor | KIS API 주문 실행 | event | L0 |
| **1B** | TradingFSM | 포지션 상태 관리 | stateful-service | L0 |
| **1C** | PositionMonitor | 보유종목 실시간 손익 갱신 | stream | L0 |
| **1C** | ExitConditionGuard | 손절/익절/시간제한 감시 | event | L0 |
| **1C** | ExitExecutor | 청산 주문 생성 → 1B 재진입 | event | L0 |

### 1.3 L0 원칙 확인

```
규칙: Path 1 전체(1A + 1B + 1C)에서 LLM 호출 0건.
      모든 판단은 수치 조건으로만.
      Knowledge 데이터가 필요하면 ConfigRef로 Shared Store에서 읽기만.
```

### 1.4 종목 상태 전이 (생명주기)

```
[CANDIDATE]  Screener가 조건에 맞는 종목 발견
     ↓
[WATCHING]   WatchlistManager에 등록, SubscriptionRouter가 시세 구독 시작
     ↓
[ENTRY]      StrategyEngine이 진입 조건 충족 판단 → 매수 주문
     ↓
[IN_POSITION] PositionMonitor가 실시간 추적, ExitConditionGuard가 감시
     ↓
[EXITING]    청산 조건 충족 → ExitExecutor가 청산 주문 생성
     ↓
[CLOSED]     청산 완료
     ↓ 분기
[WATCHING]   재감시 (조건부) — 재진입 가능
[BLACKLISTED] 폐기 (연속 손절 등) — 일정 기간 제외
[REMOVED]    워치리스트에서 완전 제거
```

### 1.5 접촉하는 Shared Store (확장)

| Store | 기존 | 1A 추가 | 1C 추가 |
|-------|------|---------|---------|
| MarketDataStore | Read/Write | Read (스크리닝용 과거 데이터) | — |
| PortfolioStore | Read/Write | — | Read/Write (포지션 상태) |
| ConfigStore | Read Only | Read (스크리닝 조건, 워치리스트 제한) | Read (손절/익절 파라미터) |
| KnowledgeStore | — | Read Only (섹터/테마 정보 참조) | — |
| **WatchlistStore** (신규) | — | Read/Write | Read |

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
    """스크리닝 실행 시점"""
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
    max_results: int = 30         # 최대 후보 수
    min_score: float = 0.0        # 최소 종합 점수
    timeframe: ScreenerTimeframe = ScreenerTimeframe.PRE_MARKET
    exclude_symbols: list[str] = field(default_factory=list)  # 블랙리스트


@dataclass(frozen=True)
class ScreenerResult:
    """스크리닝 결과 단건"""
    symbol: str
    name: str
    score: float                  # 종합 점수 (0.0 ~ 1.0)
    matched_conditions: list[str] # 충족한 조건 필드명
    snapshot: dict                # 스크리닝 시점의 주요 수치
    # snapshot 예시:
    # {"price": 72000, "volume": 15000000, "change_pct": 3.5,
    #  "market_cap": 430000000000000, "rsi_14": 62, "sector": "반도체"}


@dataclass(frozen=True)
class ScreenerOutput:
    """스크리닝 실행 결과"""
    profile_id: str
    candidates: list[ScreenerResult]
    total_scanned: int            # 전체 스캔 종목 수
    total_passed: int             # 조건 통과 수
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
        current_quotes: 현재 시세 스냅샷 (MarketDataReceiver에서 수신 중인 것)
        장중에는 전 종목 API 호출 대신 기존 시세 + 등락률 순위 API 활용.
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
    """종목 상태 — 생명주기"""
    CANDIDATE = "candidate"       # 스크리너가 발견, 아직 감시 시작 전
    WATCHING = "watching"         # 시세 구독 중, 진입 조건 감시 중
    ENTRY_TRIGGERED = "entry_triggered"  # 진입 조건 충족, 주문 생성 중
    IN_POSITION = "in_position"   # 매수 체결 완료, 포지션 보유 중
    EXIT_TRIGGERED = "exit_triggered"    # 청산 조건 충족, 청산 주문 중
    CLOSED = "closed"             # 청산 완료
    BLACKLISTED = "blacklisted"   # 일정 기간 제외 (연속 손절 등)
    REMOVED = "removed"           # 워치리스트에서 완전 제거


@dataclass
class WatchlistEntry:
    """워치리스트 항목"""
    symbol: str
    name: str
    status: WatchlistStatus
    priority: int                 # 1 = 최고 우선순위
    added_at: datetime
    source: str                   # "screener:momentum_daily" | "manual" | "knowledge"
    screener_score: float         # 스크리닝 점수 (0.0 ~ 1.0)
    entry_conditions: dict        # 진입 조건 (전략별)
    # entry_conditions 예시:
    # {"strategy_id": "ma_cross", "trigger": "ma5_cross_above_ma20",
    #  "confirm": "volume > ma_volume_20 * 1.5"}
    current_price: float = 0.0
    price_at_add: float = 0.0     # 등록 시점 가격
    change_since_add_pct: float = 0.0
    last_signal_at: datetime | None = None
    consecutive_losses: int = 0   # 연속 손절 횟수 (블랙리스트 판단용)
    metadata: dict = field(default_factory=dict)
    updated_at: datetime = field(default_factory=datetime.now)


@dataclass(frozen=True)
class WatchlistSummary:
    """워치리스트 요약"""
    total: int
    by_status: dict               # {"watching": 15, "in_position": 5, "candidate": 8}
    max_capacity: int             # 최대 감시 가능 종목 수
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
        종목 상태 전이.
        유효한 전이만 허용:
          CANDIDATE → WATCHING → ENTRY_TRIGGERED → IN_POSITION
          IN_POSITION → EXIT_TRIGGERED → CLOSED
          CLOSED → WATCHING (재감시) | BLACKLISTED | REMOVED
        """
        ...

    @abstractmethod
    async def get(self, symbol: str) -> WatchlistEntry | None:
        """단일 종목 조회."""
        ...

    @abstractmethod
    async def get_by_status(
        self, status: WatchlistStatus
    ) -> list[WatchlistEntry]:
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
        """
        블랙리스트 등록.
        duration_days 후 자동 해제.
        """
        ...

    @abstractmethod
    async def promote(
        self, candidates: list[ScreenerResult], max_add: int = 10
    ) -> list[WatchlistEntry]:
        """
        스크리닝 결과에서 상위 후보를 WATCHING으로 승격.
        기존 WATCHING 종목과 중복 제거.
        max_add: 한 번에 추가할 최대 수.
        """
        ...

    @abstractmethod
    async def cleanup_stale(
        self, max_watching_days: int = 5
    ) -> list[str]:
        """
        오래된 WATCHING 종목 정리.
        max_watching_days 이상 WATCHING 상태이면 REMOVED.
        Returns: 제거된 종목 코드 목록.
        """
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
    reason: str                   # "screener_add" | "position_closed" | "capacity_full" | "blacklisted"
    priority: int
    timestamp: datetime = field(default_factory=datetime.now)


@dataclass(frozen=True)
class SubscriptionState:
    """현재 구독 상태"""
    active_symbols: list[str]     # 현재 시세 수신 중인 종목
    watching_count: int
    position_count: int
    max_subscriptions: int        # WebSocket 구독 상한
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
        """
        구독 변경 적용.
        subscribe: MarketDataReceiver에 종목 추가
        unsubscribe: MarketDataReceiver에서 종목 제거
        Returns: 변경 후 구독 상태
        """
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
        WATCHING + IN_POSITION 종목은 반드시 구독.
        그 외는 해제.
        Returns: 적용된 변경 목록
        """
        ...

    @abstractmethod
    async def enforce_capacity(
        self, max_subscriptions: int
    ) -> list[SubscriptionChange]:
        """
        구독 수 상한 강제.
        초과 시 priority 낮은 WATCHING 종목부터 해제.
        IN_POSITION 종목은 절대 해제 불가.
        Returns: 해제된 종목의 변경 목록
        """
        ...
```

**Adapters:**
- WebSocketSubscriptionAdapter — KIS WebSocket 구독 관리 (운영)
- PollingSubscriptionAdapter — REST 폴링 대상 관리 (fallback)
- MockSubscriptionAdapter — 테스트용

---

## 3. SubPath 1C: Position Tracking — Port Interface (3개 Port)

### 3.1 PositionMonitorPort — 실시간 포지션 감시 규격

보유 종목의 실시간 손익을 틱마다 갱신하고, 현재 포지션 상태를 제공한다.

```python
@dataclass
class LivePosition:
    """실시간 포지션 (틱마다 갱신)"""
    symbol: str
    name: str
    strategy_id: str
    quantity: int
    avg_entry_price: float        # 평균 매수단가
    current_price: float          # 현재가 (최신 틱)
    unrealized_pnl: float         # 미실현 손익 (원)
    unrealized_pnl_pct: float     # 미실현 손익률 (%)
    highest_price: float          # 보유 기간 최고가 (trailing stop용)
    lowest_price: float           # 보유 기간 최저가
    drawdown_from_high_pct: float # 고점 대비 하락률
    entry_time: datetime
    holding_seconds: int          # 보유 시간 (초)
    last_tick_at: datetime
    # 추가 컨텍스트
    volume_since_entry: int       # 진입 이후 누적 거래량
    tick_count: int               # 수신 틱 수


@dataclass(frozen=True)
class PositionAlert:
    """포지션 알림 이벤트"""
    symbol: str
    alert_type: str               # "approaching_stop_loss" | "new_high" |
                                  # "time_limit_warning" | "spread_widening"
    message: str
    current_values: dict
    threshold_values: dict
    severity: str                 # "info" | "warning" | "critical"
    timestamp: datetime = field(default_factory=datetime.now)


class PositionMonitorPort(ABC):
    """
    실시간 포지션 감시 인터페이스.

    틱 기반이든, 폴링 기반이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def update_tick(
        self, symbol: str, quote: dict
    ) -> LivePosition:
        """
        틱 수신 시 포지션 갱신.
        최고가/최저가, 손익, drawdown 재계산.
        Returns: 갱신된 포지션
        """
        ...

    @abstractmethod
    async def register_position(
        self, symbol: str, strategy_id: str,
        quantity: int, avg_price: float,
        entry_time: datetime
    ) -> LivePosition:
        """
        신규 포지션 등록 (매수 체결 시).
        PositionMonitor 추적 시작.
        """
        ...

    @abstractmethod
    async def unregister_position(
        self, symbol: str
    ) -> dict:
        """
        포지션 제거 (청산 완료 시).
        Returns: 최종 포지션 요약 (보유기간, 최종 손익 등)
        """
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

### 3.2 ExitConditionPort — 청산 조건 감시 규격

보유 종목에 대해 손절/익절/시간제한/트레일링스탑 등 청산 조건을 실시간으로 감시한다.

```python
class ExitType(Enum):
    STOP_LOSS = "stop_loss"               # 손절
    TAKE_PROFIT = "take_profit"           # 익절
    TRAILING_STOP = "trailing_stop"       # 추적 손절
    TIME_LIMIT = "time_limit"             # 보유 시간 제한
    STRATEGY_EXIT = "strategy_exit"       # 전략 청산 신호
    FORCE_CLOSE = "force_close"           # 강제 청산 (마감 임박 등)


@dataclass(frozen=True)
class ExitRule:
    """청산 규칙"""
    exit_type: ExitType
    params: dict
    # params 예시:
    # STOP_LOSS:      {"threshold_pct": -3.0}
    # TAKE_PROFIT:    {"threshold_pct": 5.0}
    # TRAILING_STOP:  {"trail_pct": 2.0, "activation_pct": 1.5}
    # TIME_LIMIT:     {"max_holding_minutes": 180}
    # FORCE_CLOSE:    {"minutes_before_close": 3}
    priority: int = 1             # 복수 조건 동시 충족 시 우선순위


@dataclass(frozen=True)
class ExitSignal:
    """청산 신호"""
    symbol: str
    exit_type: ExitType
    trigger_price: float          # 조건 충족 시점 가격
    current_pnl_pct: float
    reason: str                   # "손절 -3.0% 도달" | "익절 +5.0% 도달"
    urgency: str                  # "normal" | "urgent" (시장가) | "immediate" (마감 임박)
    suggested_order_type: str     # "market" | "limit"
    suggested_price: float | None # limit인 경우
    rule: ExitRule
    timestamp: datetime = field(default_factory=datetime.now)


class ExitConditionPort(ABC):
    """
    청산 조건 감시 인터페이스.

    규칙 기반이든, 전략 연동이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def evaluate(
        self, position: LivePosition
    ) -> ExitSignal | None:
        """
        포지션에 대한 청산 조건 평가.
        조건 충족 시 ExitSignal 반환, 미충족 시 None.
        복수 조건 동시 충족 시 priority 최고 것만 반환.
        """
        ...

    @abstractmethod
    async def set_rules(
        self, symbol: str, rules: list[ExitRule]
    ) -> bool:
        """
        종목별 청산 규칙 설정.
        전략이 매수할 때 함께 설정.
        """
        ...

    @abstractmethod
    async def get_rules(self, symbol: str) -> list[ExitRule]:
        """종목의 현재 청산 규칙 조회."""
        ...

    @abstractmethod
    async def update_trailing_stop(
        self, symbol: str, new_high: float
    ) -> ExitRule | None:
        """
        트레일링 스탑 갱신.
        new_high가 기존 최고가보다 높으면 스탑 가격 상향.
        Returns: 갱신된 규칙 또는 None (변경 없음)
        """
        ...

    @abstractmethod
    async def add_force_close(
        self, symbols: list[str], reason: str
    ) -> int:
        """
        강제 청산 규칙 추가 (마감 임박, 긴급 등).
        기존 규칙에 FORCE_CLOSE를 최고 우선순위로 추가.
        Returns: 적용된 종목 수
        """
        ...
```

**Adapters:**
- RuleBasedExitAdapter — 규칙 기반 (운영)
- StrategyLinkedExitAdapter — 전략 연동 (전략이 청산 조건 자체 관리)
- MockExitAdapter — 테스트용

---

### 3.3 ExitExecutorPort — 청산 실행 규격

ExitSignal을 받아 청산 주문을 생성하고 SubPath 1B의 주문 파이프라인에 재진입시킨다.

```python
@dataclass(frozen=True)
class ExitOrderRequest:
    """청산 주문 요청"""
    symbol: str
    quantity: int                 # 전량 or 일부 청산
    exit_type: ExitType
    order_type: str               # "market" | "limit"
    price: float | None           # limit인 경우
    urgency: str                  # "normal" | "urgent" | "immediate"
    reason: str
    original_entry_price: float   # 원래 매수가 (로깅용)
    expected_pnl_pct: float       # 예상 손익률
    correlation_id: str           # 진입 주문과 연결


@dataclass(frozen=True)
class ExitResult:
    """청산 실행 결과"""
    symbol: str
    exit_type: ExitType
    success: bool
    order_id: str | None
    message: str
    actual_pnl_pct: float | None  # 실현 손익률
    post_action: str              # "return_to_watchlist" | "blacklist" | "remove"


class ExitExecutorPort(ABC):
    """
    청산 실행 인터페이스.

    직접 주문이든, SubPath 1B 재진입이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def execute_exit(
        self, request: ExitOrderRequest
    ) -> ExitResult:
        """
        청산 실행.
        OrderRequest로 변환하여 SubPath 1B의 RiskGuard → OrderExecutor 경로로 주입.
        """
        ...

    @abstractmethod
    async def determine_post_action(
        self, symbol: str, exit_result: ExitResult,
        consecutive_losses: int
    ) -> str:
        """
        청산 후 행동 결정.
        - 익절 or 첫 손절: "return_to_watchlist" (재감시)
        - 연속 2회 손절: "return_to_watchlist" (우선순위 하향)
        - 연속 3회 이상 손절: "blacklist" (7일 제외)
        Returns: post_action 값
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

## 4. Domain Types 정의 (1A + 1C 추가분)

### 4.1 추가 Enum (4종)

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

class ExitType(Enum):
    STOP_LOSS = "stop_loss"
    TAKE_PROFIT = "take_profit"
    TRAILING_STOP = "trailing_stop"
    TIME_LIMIT = "time_limit"
    STRATEGY_EXIT = "strategy_exit"
    FORCE_CLOSE = "force_close"

class ScreenerTimeframe(Enum):
    PRE_MARKET = "pre_market"
    INTRADAY = "intraday"
    POST_MARKET = "post_market"

class MarketType(Enum):
    KOSPI = "kospi"
    KOSDAQ = "kosdaq"
    ALL = "all"
```

### 4.2 추가 Core Data Types (12종)

| Type | SubPath | 주요 필드 |
|------|---------|----------|
| ScreenerCondition | 1A | field, operator, value, weight |
| ScreenerProfile | 1A | conditions, market, max_results, timeframe |
| ScreenerResult | 1A | symbol, score, matched_conditions, snapshot |
| ScreenerOutput | 1A | candidates, total_scanned, total_passed |
| WatchlistEntry | 1A | symbol, status, priority, entry_conditions, consecutive_losses |
| SubscriptionChange | 1A | action, symbol, reason, priority |
| LivePosition | 1C | symbol, qty, current_price, unrealized_pnl, highest_price, drawdown |
| PositionAlert | 1C | symbol, alert_type, severity, threshold_values |
| ExitRule | 1C | exit_type, params, priority |
| ExitSignal | 1C | symbol, exit_type, trigger_price, urgency, suggested_order_type |
| ExitOrderRequest | 1C | symbol, quantity, exit_type, urgency, expected_pnl_pct |
| ExitResult | 1C | symbol, success, actual_pnl_pct, post_action |

---

## 5. Edge Contract (1A + 1C 추가분, 14 Edges)

### 5.1 SubPath 1A 내부 + 1A→1B 연결 (5 Edges)

```yaml
# E-P1A-01: 스크리너 → 워치리스트
edge_id: e_screener_to_watchlist
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: Screener, port_name: candidates_out, path: path1.1a }
target: { node_id: WatchlistManager, port_name: candidates_in, path: path1.1a }
payload:
  type: ScreenerOutput
  schema_ref: "port_interface_path1_ext#ScreenerOutput"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: async
  ordering: best-effort
  retry: { max_attempts: 1, backoff: null, dead_letter: false }
  timeout_ms: 5000
  idempotency: true           # profile_id + executed_at 기반

# E-P1A-02: 워치리스트 → 구독 라우터
edge_id: e_watchlist_to_subscription
edge_type: Event
edge_role: EventNotify
source: { node_id: WatchlistManager, port_name: status_change_out, path: path1.1a }
target: { node_id: SubscriptionRouter, port_name: change_in, path: path1.1a }
payload:
  type: "list[SubscriptionChange]"
  schema_ref: "port_interface_path1_ext#SubscriptionChange"
  cardinality: "1:N"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict            # 구독/해제 순서 보장
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 2000
  idempotency: true

# E-P1A-03: 구독 라우터 → MarketDataReceiver (구독 적용)
edge_id: e_subscription_to_market_data
edge_type: Event
edge_role: Command
source: { node_id: SubscriptionRouter, port_name: subscribe_cmd, path: path1.1a }
target: { node_id: MarketDataReceiver, port_name: subscription_in, path: path1.1b }
payload:
  type: "list[SubscriptionChange]"
  schema_ref: "port_interface_path1_ext#SubscriptionChange"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: sync              # 구독 완료 확인 필요
  ordering: strict
  retry: { max_attempts: 3, backoff: exponential, dead_letter: false }
  timeout_ms: 5000
  idempotency: true

# E-P1A-04: 워치리스트 → WatchlistStore (영속화)
edge_id: e_watchlist_to_store
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: WatchlistManager, port_name: persist_out, path: path1.1a }
target: { node_id: WatchlistStore, port_name: write_in, path: shared }
payload:
  type: WatchlistEntry
  schema_ref: "port_interface_path1_ext#WatchlistEntry"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict
  retry: { max_attempts: 3, backoff: exponential, dead_letter: true }
  timeout_ms: 2000
  idempotency: true

# E-P1A-05: 스크리너 ← MarketDataStore (과거 데이터 참조)
edge_id: e_market_store_to_screener
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: MarketDataStore, port_name: history_out, path: shared }
target: { node_id: Screener, port_name: data_in, path: path1.1a }
payload:
  type: "dict[str, list[OHLCV]]"
  schema_ref: "port_interface_path1_v1.0#OHLCV"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: sync
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 10000
  idempotency: true
```

### 5.2 SubPath 1B→1C 연결 (3 Edges)

```yaml
# E-P1BC-01: OrderExecutor → PositionMonitor (매수 체결 → 추적 시작)
edge_id: e_executor_to_position_monitor
edge_type: Event
edge_role: EventNotify
source: { node_id: OrderExecutor, port_name: fill_out, path: path1.1b }
target: { node_id: PositionMonitor, port_name: new_position_in, path: path1.1c }
payload:
  type: OrderResult
  schema_ref: "port_interface_path1_v1.0#OrderResult"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict
  retry: { max_attempts: 3, backoff: exponential, dead_letter: true }
  timeout_ms: 2000
  idempotency: true           # order_id 기반

# E-P1BC-02: MarketDataReceiver → PositionMonitor (보유종목 틱)
edge_id: e_market_to_position_monitor
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: MarketDataReceiver, port_name: tick_out, path: path1.1b }
target: { node_id: PositionMonitor, port_name: tick_in, path: path1.1c }
payload:
  type: Quote
  schema_ref: "port_interface_path1_v1.0#Quote"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict
  retry: { max_attempts: 0, backoff: null, dead_letter: false }
  timeout_ms: 100
  idempotency: true

# E-P1BC-03: PositionMonitor → WatchlistManager (상태 동기화)
edge_id: e_position_monitor_to_watchlist
edge_type: Event
edge_role: EventNotify
source: { node_id: PositionMonitor, port_name: status_out, path: path1.1c }
target: { node_id: WatchlistManager, port_name: position_update_in, path: path1.1a }
payload:
  type: "WatchlistStatus update"
  schema_ref: "port_interface_path1_ext#WatchlistEntry"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 1000
  idempotency: true
```

### 5.3 SubPath 1C 내부 + 1C→1B 재진입 (4 Edges)

```yaml
# E-P1C-01: PositionMonitor → ExitConditionGuard
edge_id: e_monitor_to_exit_guard
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: PositionMonitor, port_name: live_position_out, path: path1.1c }
target: { node_id: ExitConditionGuard, port_name: position_in, path: path1.1c }
payload:
  type: LivePosition
  schema_ref: "port_interface_path1_ext#LivePosition"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict
  retry: { max_attempts: 0, backoff: null, dead_letter: false }
  timeout_ms: 50              # 틱마다 평가 — 빠르게
  idempotency: true

# E-P1C-02: ExitConditionGuard → ExitExecutor (청산 신호)
edge_id: e_exit_guard_to_executor
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: ExitConditionGuard, port_name: exit_signal_out, path: path1.1c }
target: { node_id: ExitExecutor, port_name: signal_in, path: path1.1c }
payload:
  type: ExitSignal
  schema_ref: "port_interface_path1_ext#ExitSignal"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: sync              # 청산은 즉시 처리
  ordering: strict
  retry: { max_attempts: 1, backoff: null, dead_letter: false }
  timeout_ms: 200
  idempotency: false          # 같은 신호라도 매번 실행

# E-P1C-03: ExitExecutor → RiskGuard (SubPath 1B 재진입)
edge_id: e_exit_executor_to_riskguard
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: ExitExecutor, port_name: order_out, path: path1.1c }
target: { node_id: RiskGuard, port_name: signal_in, path: path1.1b }
payload:
  type: OrderRequest          # side=SELL로 설정된 청산 주문
  schema_ref: "port_interface_path1_v1.0#OrderRequest"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: sync
  ordering: strict
  retry: { max_attempts: 2, backoff: fixed, dead_letter: true }
  timeout_ms: 500
  idempotency: true           # correlation_id 기반

# E-P1C-04: ExitExecutor → WatchlistManager (청산 후 상태 전이)
edge_id: e_exit_result_to_watchlist
edge_type: Event
edge_role: EventNotify
source: { node_id: ExitExecutor, port_name: result_out, path: path1.1c }
target: { node_id: WatchlistManager, port_name: exit_result_in, path: path1.1a }
payload:
  type: ExitResult
  schema_ref: "port_interface_path1_ext#ExitResult"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict
  retry: { max_attempts: 3, backoff: exponential, dead_letter: true }
  timeout_ms: 2000
  idempotency: true

# E-P1C-05: ExitExecutor ← ConfigStore (청산 파라미터)
edge_id: e_config_to_exit_guard
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: ConfigStore, port_name: exit_params_out, path: shared }
target: { node_id: ExitConditionGuard, port_name: config_in, path: path1.1c }
payload:
  type: ExitRuleSet            # {default_stop_loss, default_take_profit, trailing_params}
  schema_ref: "shared_store#ExitRuleSet"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: sync
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 500
  idempotency: true
```

### 5.4 장중 동적 스크리닝 Edge (2 Edges)

```yaml
# E-P1A-06: MarketDataReceiver → Screener (장중 실시간 스크리닝)
edge_id: e_market_to_screener_realtime
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: MarketDataReceiver, port_name: batch_quote_out, path: path1.1b }
target: { node_id: Screener, port_name: realtime_in, path: path1.1a }
payload:
  type: "dict[str, Quote]"
  schema_ref: "port_interface_path1_v1.0#Quote"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: fire-and-forget   # 스크리닝은 매매 흐름 차단 안 함
  ordering: best-effort
  retry: { max_attempts: 0, backoff: null, dead_letter: false }
  timeout_ms: 5000
  idempotency: true

# E-P1A-07: Screener ← KnowledgeStore (섹터/테마 참조)
edge_id: e_knowledge_to_screener
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: KnowledgeStore, port_name: sector_out, path: shared }
target: { node_id: Screener, port_name: knowledge_in, path: path1.1a }
payload:
  type: "dict[str, dict]"     # 종목별 섹터/테마/인과관계 요약
  schema_ref: "shared_store#SectorInfo"
  cardinality: batch
  serialization: json
contract:
  delivery: sync
  ordering: best-effort
  retry: { max_attempts: 1, backoff: null, dead_letter: false }
  timeout_ms: 3000
  idempotency: true
```

---

## 6. Shared Store 스키마 (신규: WatchlistStore)

```sql
-- 워치리스트 테이블
CREATE TABLE watchlist (
    symbol          TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'candidate',
    priority        INT NOT NULL DEFAULT 50,
    source          TEXT NOT NULL,          -- "screener:momentum_daily" | "manual"
    screener_score  FLOAT DEFAULT 0.0,
    entry_conditions JSONB,
    price_at_add    FLOAT,
    consecutive_losses INT DEFAULT 0,
    blacklisted_until TIMESTAMPTZ,          -- 블랙리스트 해제 시점
    metadata        JSONB DEFAULT '{}',
    added_at        TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 워치리스트 이력 (상태 전이 추적)
CREATE TABLE watchlist_history (
    id              BIGSERIAL PRIMARY KEY,
    symbol          TEXT NOT NULL,
    old_status      TEXT,
    new_status      TEXT NOT NULL,
    reason          TEXT,
    metadata        JSONB,
    changed_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 청산 이력
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
    post_action     TEXT,                  -- "return_to_watchlist" | "blacklist" | "remove"
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);

-- 스크리닝 프로파일
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

-- 인덱스
CREATE INDEX idx_watchlist_status ON watchlist(status);
CREATE INDEX idx_watchlist_priority ON watchlist(priority);
CREATE INDEX idx_watchlist_history_symbol ON watchlist_history(symbol, changed_at);
CREATE INDEX idx_exit_history_symbol ON exit_history(symbol, executed_at);
```

---

## 7. Safeguard 적용 (1A + 1C)

### 7.1 SubPath 1A Safeguard

```
Screener 실행
    → [CapacityGuard]       max_watching 초과 시 최저 priority 제거 후 추가
    → [DuplicateGuard]      이미 WATCHING/IN_POSITION인 종목 중복 추가 방지
    → [BlacklistGuard]      블랙리스트 기간 내 종목 필터링
    → WatchlistManager
    → [SubscriptionCapGuard] WebSocket 구독 상한(보통 40~100종목) 강제
    → SubscriptionRouter
```

### 7.2 SubPath 1C Safeguard

```
ExitConditionGuard 청산 조건 충족
    → [ExitDedupGuard]      동일 종목 청산 주문 중복 방지 (이미 EXIT_TRIGGERED면 차단)
    → [MarketPhaseGuard]    마감 동시호가 중 시장가 주문 차단
    → ExitExecutor
    → SubPath 1B 재진입 (RiskGuard → DedupGuard → OrderExecutor)
```

### 7.3 종목 상태 전이 규칙 (강제)

| 현재 상태 | 허용 전이 | 금지 전이 |
|-----------|----------|----------|
| CANDIDATE | → WATCHING, REMOVED | → IN_POSITION (감시 없이 직접 진입 금지) |
| WATCHING | → ENTRY_TRIGGERED, REMOVED, BLACKLISTED | → CLOSED (포지션 없이 청산 불가) |
| ENTRY_TRIGGERED | → IN_POSITION, WATCHING (주문 실패 시 복귀) | → REMOVED (주문 중 제거 금지) |
| IN_POSITION | → EXIT_TRIGGERED | → REMOVED, WATCHING (포지션 보유 중 상태 역행 금지) |
| EXIT_TRIGGERED | → CLOSED | → WATCHING, IN_POSITION |
| CLOSED | → WATCHING (재감시), BLACKLISTED, REMOVED | → IN_POSITION |
| BLACKLISTED | → CANDIDATE (기간 만료 시), REMOVED | → WATCHING (기간 내 재감시 금지) |

---

## 8. Adapter Mapping 요약 (1A + 1C)

| Port | 운영 Adapter | 개발 Adapter | 테스트 Adapter |
|------|-------------|-------------|---------------|
| ScreenerPort | KISScreenerAdapter | DBScreenerAdapter | MockScreenerAdapter |
| WatchlistPort | PostgresWatchlistAdapter | InMemoryWatchlistAdapter | MockWatchlistAdapter |
| SubscriptionPort | WebSocketSubscriptionAdapter | PollingSubscriptionAdapter | MockSubscriptionAdapter |
| PositionMonitorPort | InMemoryPositionMonitorAdapter | InMemoryPositionMonitorAdapter | MockPositionMonitorAdapter |
| ExitConditionPort | RuleBasedExitAdapter | RuleBasedExitAdapter | MockExitAdapter |
| ExitExecutorPort | PipelineExitAdapter | PipelineExitAdapter | MockExitAdapter |

**YAML 설정 예시:**

```yaml
path1_extension:
  # SubPath 1A: Universe Management
  screener:
    implementation: KISScreenerAdapter
    params:
      rank_api: true                     # KIS 등락률/거래량 순위 API 사용
      scan_interval_minutes: 30          # 장중 재스크리닝 주기
      pre_market_scan_time: "08:30"      # 장 시작 전 스캔

  watchlist:
    implementation: PostgresWatchlistAdapter
    params:
      dsn: ${POSTGRES_DSN}
      max_watching: 30                   # 최대 감시 종목 수
      max_in_position: 10                # 최대 동시 보유 종목 수
      stale_watching_days: 5             # WATCHING 유지 최대 일수
      blacklist_default_days: 7          # 기본 블랙리스트 기간

  subscription:
    implementation: WebSocketSubscriptionAdapter
    params:
      max_subscriptions: 50              # WebSocket 구독 상한
      priority_protect_in_position: true # IN_POSITION은 절대 해제 불가

  # SubPath 1C: Position Tracking
  position_monitor:
    implementation: InMemoryPositionMonitorAdapter
    params:
      tick_buffer_size: 100              # 종목당 최근 틱 버퍼

  exit_condition:
    implementation: RuleBasedExitAdapter
    params:
      default_stop_loss_pct: -3.0
      default_take_profit_pct: 5.0
      trailing_stop_pct: 2.0
      trailing_activation_pct: 1.5
      max_holding_minutes: 360           # 6시간 (장중)
      force_close_before_market_close_minutes: 3

  exit_executor:
    implementation: PipelineExitAdapter
    params:
      reentry_point: RiskGuard           # SubPath 1B 재진입 지점
      consecutive_loss_blacklist: 3      # 연속 n회 손절 시 블랙리스트
      default_exit_order_type: market    # 기본 청산 주문: 시장가
```

---

## 9. Edge 통계 업데이트

### 기존 → 확장 후

| 항목 | 기존 | 추가 | 확장 후 |
|------|------|------|---------|
| Path 1 노드 | 7 | +6 | 13 |
| Path 1 Edge | 9 | +14 | 23 |
| Path 1 Port | 4 | +6 | 10 |
| Path 1 Domain Type | 6 | +12 | 18 |
| 전체 Edge | 54 | +14 | 68 |
| 전체 Port | 25 | +6 | 31 |
| 전체 Domain Type | 50 | +12 | 62 |
| 전체 노드 | ~32 | +6 | ~38 |

### Cross-SubPath Edge 요약

```
1A → 1B: 1 Edge  (구독 라우터 → MarketDataReceiver)
1B → 1C: 2 Edges (체결 결과 → PositionMonitor, 시세 → PositionMonitor)
1C → 1B: 1 Edge  (청산 주문 → RiskGuard 재진입)
1C → 1A: 1 Edge  (청산 결과 → WatchlistManager 상태 갱신)
1A → 1C: 0       (직접 연결 없음 — WatchlistStore 경유)
```

---

## 10. 연쇄 변경 목록

이 문서가 확정되면 아래 문서에 반영 필요.

| Document | Change |
|----------|--------|
| port_interface_path1_v1.0 | SubPath 구조 참조 추가, 1B로 재명명 |
| edge_contract_definition_v1.0 | Section 3 확장 (9 → 23 Edges), 통계 갱신 |
| INDEX.md | 이 문서 등록 |
| boundary_definition_v1.0 | Path 1 노드 테이블 확장 (7 → 13), L0 유지 확인 |
| System Manifest (미작성) | 6개 신규 노드 등록 |
| WatchlistStore | Shared Store 목록에 추가 (6 → 7개) |

---

*End of Document — Port Interface Path 1 Extension v1.0*
*+6 Nodes | +6 Ports | +12 Domain Types | +14 Edges | 1 New Shared Store*
*전체 L0 유지 — 트레이딩 핵심 경로에 LLM 0건*
