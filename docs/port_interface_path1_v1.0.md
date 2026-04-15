# Port Interface Design — Path 1: Realtime Trading

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | port_interface_path1_v1.0 |
| Path | Path 1: Realtime Trading |
| 선행 문서 | boundary_definition_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |

---

## 1. Path 1 개요

### 1.1 책임 범위

Realtime Trading Path는 시세 수신 → 기술지표 계산 → 전략 판단 → 리스크 검증 → 주문 실행 → 체결 확인의 전체 매매 루프를 담당한다.

5개 Path 중 유일하게 **실제 돈이 오가는 경로**. boundary_definition에서 확정한 대로 **전체 노드가 L0(No LLM)** — deterministic only. LLM이 죽어도 매매는 계속된다.

### 1.2 노드 구성 (7개)

| 노드 ID | 역할 | runMode | LLM Level |
|---------|------|---------|-----------|
| MarketDataReceiver | KIS 실시간 시세 수신 | stream | L0 |
| IndicatorCalculator | 기술지표 계산 (MA, RSI, MACD 등) | event | L0 |
| StrategyEngine | 전략 판단 → SignalOutput 생성 | event | L0 |
| RiskGuard | 주문 전 리스크 검증 | event | L0 |
| DedupGuard | 중복 주문 방지 | event | L0 |
| OrderExecutor | KIS API 주문 실행 | event | L0 |
| TradingFSM | 포지션 상태 관리 (Idle→Entry→InPosition→Exit) | stateful-service | L0 |

### 1.3 핵심 원칙

```
규칙 1: 이 Path의 어떤 노드도 LLM을 호출하지 않는다.
규칙 2: 모든 판단은 사전 정의된 수치 규칙으로만 이루어진다.
규칙 3: 주문은 반드시 Strategy → RiskGuard → DedupGuard → Broker 순서를 거친다.
규칙 4: 장애 시 안전 모드 — 신규 주문 차단, 기존 포지션 손절선만 유지.
```

### 1.4 접촉하는 Shared Store (3개)

| Store | 용도 | 접근 방식 |
|-------|------|----------|
| MarketDataStore | 시세 저장, 과거 데이터 참조 | Read/Write |
| PortfolioStore | 포지션/잔고 동기화 | Read/Write |
| ConfigStore | 전략 파라미터, 종목 목록, 한도 | Read Only |

---

## 2. Port Interface 정의 (4개 Port)

### 2.1 MarketDataPort — 시세 수신 규격

실시간 시세 데이터를 수신한다. WebSocket push든, REST polling이든, 파일 리플레이든 이 포트 규격만 맞추면 교체 가능.

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Callable, AsyncIterator


class MarketStatus(Enum):
    PRE_MARKET = "pre_market"
    OPEN = "open"
    CLOSING = "closing"           # 장 마감 동시호가
    CLOSED = "closed"
    HOLIDAY = "holiday"


@dataclass(frozen=True)
class Quote:
    """현재가 스냅샷 — KIS inquire_price 응답 기반"""
    symbol: str                   # 종목코드 "005930"
    name: str                     # "삼성전자"
    price: int                    # 현재가
    change: int                   # 전일 대비 변동
    change_pct: float             # 등락률 (%)
    volume: int                   # 누적 거래량
    amount: int                   # 누적 거래대금
    open: int                     # 시가
    high: int                     # 고가
    low: int                      # 저가
    prev_close: int               # 전일 종가
    ask_price: int                # 매도1호가
    bid_price: int                # 매수1호가
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

    Core는 이 클래스만 import.
    """

    @abstractmethod
    async def subscribe(self, symbols: list[str]) -> None:
        """
        종목 실시간 시세 구독 시작.
        WebSocket 어댑터: 실제 구독
        Polling 어댑터: 폴링 대상 등록
        Replay 어댑터: 재생 대상 등록
        """
        ...

    @abstractmethod
    async def unsubscribe(self, symbols: list[str]) -> None:
        """시세 구독 해제."""
        ...

    @abstractmethod
    async def on_tick(self, callback: Callable[[Quote], None]) -> None:
        """
        틱 수신 콜백 등록.
        새로운 시세가 도착할 때마다 callback(quote) 호출.
        """
        ...

    @abstractmethod
    async def get_quote(self, symbol: str) -> Quote:
        """단일 종목 현재가 조회 (REST)."""
        ...

    @abstractmethod
    async def get_ohlcv(
        self, symbol: str, timeframe: str = "1d", count: int = 60
    ) -> list[OHLCV]:
        """
        과거 봉 데이터 조회.
        timeframe: "1m" | "5m" | "15m" | "1d" | "1w"
        """
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

### 2.2 BrokerPort — 주문 실행 규격

주문 실행과 계좌 조회를 추상화한다. Core engine은 KIS인지, eBest인지 모른다.

```python
class OrderSide(Enum):
    BUY = "buy"
    SELL = "sell"


class OrderType(Enum):
    LIMIT = "limit"               # 지정가
    MARKET = "market"             # 시장가
    CONDITIONAL = "conditional"   # 조건부지정가
    BEST = "best"                 # 최유리지정가


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
    price: int | None = None      # None for MARKET orders
    strategy_id: str = ""         # 어떤 전략이 요청했는지
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
    avg_price: float              # 평균 매입단가
    current_price: float
    unrealized_pnl: float         # 미실현 손익
    unrealized_pnl_pct: float     # 미실현 손익률 (%)


@dataclass(frozen=True)
class AccountSummary:
    """계좌 요약"""
    total_equity: float           # 총 자산
    cash: float                   # 가용 현금
    invested: float               # 투자 금액
    total_pnl: float              # 총 손익
    total_pnl_pct: float          # 총 손익률
    positions: list[Position]


class BrokerPort(ABC):
    """
    주문 실행 / 계좌 조회 인터페이스.

    KIS MCP든, KIS REST든, eBest든, Mock이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def submit_order(self, order: OrderRequest) -> OrderResult:
        """
        주문 제출.
        Returns: order_id + 초기 상태
        """
        ...

    @abstractmethod
    async def cancel_order(self, order_id: str) -> bool:
        """주문 취소. Returns: 성공 여부."""
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
        """인증 및 연결 초기화 (토큰 발급 등)."""
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
- MockBrokerAdapter — 테스트용 (고정 체결)
- EBestAdapter — eBest (미래)

---

### 2.3 StoragePort — 데이터 영속화 규격

시세 스냅샷, 주문 기록, 이벤트 로그를 영속 저장한다.

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
    cycle: int                    # 몇 번째 수집인지


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
        """이벤트 로그 저장 (상태 전이, 시그널 등)."""
        ...

    @abstractmethod
    async def get_trades(
        self, start_date: str, end_date: str,
        symbol: str | None = None
    ) -> list[TradeRecord]:
        """기간별 체결 기록 조회."""
        ...

    @abstractmethod
    async def get_snapshots(
        self, date: str
    ) -> list[MarketSnapshot]:
        """특정일 시세 스냅샷 조회."""
        ...

    @abstractmethod
    async def get_last_state(self) -> dict | None:
        """
        마지막 저장된 시스템 상태.
        엔진 재시작 시 상태 복원용.
        """
        ...

    @abstractmethod
    async def save_state(self, state: dict) -> None:
        """현재 시스템 상태 저장 (주기적)."""
        ...
```

**Adapters:**
- PostgresStorageAdapter — PostgreSQL (운영)
- SQLiteStorageAdapter — SQLite (로컬 개발)
- JSONFileStorageAdapter — JSON 파일 (PRD 호환)
- MockStorageAdapter — 테스트용

---

### 2.4 ClockPort — 시장 시간 규격

장 운영 시간, 영업일 여부, 스케줄링을 추상화한다.

```python
class ClockPort(ABC):
    """
    시장 시간 판단 인터페이스.

    KRX(한국)든, NYSE(미국)든, 테스트용(항상 장중)이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def get_status(self) -> MarketStatus:
        """현재 장 상태 (PRE_MARKET/OPEN/CLOSING/CLOSED/HOLIDAY)."""
        ...

    @abstractmethod
    async def is_trading_day(self, date: str | None = None) -> bool:
        """영업일 여부 (공휴일/주말 체크). None이면 오늘."""
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

## 3. Domain Types 정의 (Path 1 전용)

### 3.1 Enum 정의

```python
class MarketStatus(Enum):
    PRE_MARKET = "pre_market"
    OPEN = "open"
    CLOSING = "closing"
    CLOSED = "closed"
    HOLIDAY = "holiday"

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
```

### 3.2 Core Data Types (6종)

| Type | 용도 | 주요 필드 |
|------|------|----------|
| Quote | 현재가 스냅샷 | symbol, price, change_pct, volume, ask/bid |
| OHLCV | 봉 데이터 | open, high, low, close, volume |
| OrderRequest | 주문 요청 | symbol, side, quantity, order_type, strategy_id |
| OrderResult | 주문 결과 | order_id, status, filled_qty, filled_price |
| Position | 보유 종목 | symbol, quantity, avg_price, unrealized_pnl |
| AccountSummary | 계좌 요약 | total_equity, cash, positions |

---

## 4. 데이터 흐름 (Edge 정의, 9개)

### 4.1 내부 Edge (Path 1 내부)

| # | Source → Target | Edge Type | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 1 | MarketDataReceiver → IndicatorCalculator | DataFlow | Quote | 틱 전달 |
| 2 | IndicatorCalculator → StrategyEngine | DataFlow | 지표 계산 결과 | MA, RSI 등 |
| 3 | StrategyEngine → RiskGuard | DataFlow | SignalOutput | 매매 신호 |
| 4 | RiskGuard → DedupGuard | DataFlow | OrderRequest | 검증된 주문 |
| 5 | DedupGuard → OrderExecutor | DataFlow | OrderRequest | 중복 제거된 주문 |
| 6 | OrderExecutor → TradingFSM | Event | OrderResult | 체결 결과 |

### 4.2 Shared Store Edge

| # | Source → Target | Edge Type | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 7 | MarketDataReceiver → MarketDataStore | DataPipe | Quote/OHLCV | 시세 영속화 |
| 8 | OrderExecutor → PortfolioStore | DataPipe | TradeRecord | 체결 기록 |
| 9 | TradingFSM ← ConfigStore | ConfigRef | 전략 파라미터 | 설정 참조 |

---

## 5. Safeguard 적용

### 5.1 Path 1 Safeguard Chain (주문 흐름)

```
StrategyEngine (SignalOutput 생성)
    → [RiskGuard]           손절/일일한도/포지션한도/섹터한도 검증
    → [DedupGuard]          동일 종목 동일 방향 중복 주문 차단
    → [RateLimiter]         API 호출 속도 제한
    → BrokerPort.submit_order()
```

### 5.2 4대 취약점 방어 (Path 1 적용분)

| 취약점 | 방어 | 구현 노드 |
|--------|------|----------|
| 중복 주문 | DedupGuard: 종목+방향+시간윈도우 기반 중복 감지 | DedupGuard |
| 상태-계좌 불일치 | TradingFSM 상태와 브로커 실계좌 주기적 대조 | TradingFSM + BrokerPort |
| 이벤트 유실 | WAL 패턴: 주문 전 이벤트 로그 선기록 | StoragePort |
| 장애 전파 | Circuit Breaker: 연속 실패 시 안전 모드 전환 | OrderExecutor |

---

## 6. Adapter Mapping 요약

| Port | 운영 Adapter | 개발 Adapter | 테스트 Adapter |
|------|-------------|-------------|---------------|
| MarketDataPort | KISWebSocketAdapter | KISRestPollingAdapter | MockMarketDataAdapter |
| BrokerPort | KISMCPAdapter | KISRestAdapter | MockBrokerAdapter |
| StoragePort | PostgresStorageAdapter | SQLiteStorageAdapter | MockStorageAdapter |
| ClockPort | KRXClockAdapter | AlwaysOpenClockAdapter | MockClockAdapter |

**YAML 설정 예시:**

```yaml
path1_realtime:
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
      env: "demo"                      # "demo" | "live"
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
```

---

## 7. 다음 단계

- Port Interface Path 2 (Knowledge Building) 설계
- Edge Contract Definition (전체 Path 간 엣지 스키마)
- KIS Adapter 구현 (MarketDataPort + BrokerPort)
