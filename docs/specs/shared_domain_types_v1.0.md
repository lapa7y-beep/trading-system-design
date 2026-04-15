# Shared Domain Types — Canonical Definitions

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | shared_domain_types_v1.0 |
| 선행 문서 | port_interface_path1~6, system_manifest_v1.0, architecture_review |
| 작성일 | 2026-04-15 |
| 상태 | Draft |
| 동기 | Architecture Review I1 — 86 Domain Types 중 다수가 Path별로 중복 정의됨 |

---

## 1. 문제 정의

### 1.1 현황

86개 Domain Type이 6개 Path의 Port Interface 문서에 분산 정의되어 있다. 동일 개념이 Path마다 약간 다른 이름, 필드 세트, 타입으로 존재.

### 1.2 중복 매트릭스

| Concept | Path 1 | Path 3 | Path 4 | 불일치 내용 |
|---------|--------|--------|--------|-----------|
| 봉 데이터 | `OHLCV` (amount: int\|None) | `OHLCV` (date vs trade_date) | — | 필드명 불일치 |
| 시세 스냅샷 | `Quote` | — | — | Path 3 BacktestEngine이 직접 참조 없이 재정의 |
| 주문 요청 | `OrderRequest` | `SignalOutput` 내 중복 필드 | `SizingResult` → OrderRequest 변환 | 변환 규칙 미정의 |
| 주문 결과 | `OrderResult` | `TradeRecord` (필드 다름) | — | trade_id vs order_id 혼재 |
| 포지션 | `Position` (BrokerPort) | — | `PositionEntry` (필드 확장) | 같은 개념, 다른 클래스명 |
| 매매 신호 | — | `SignalOutput` | `ResolvedAction` 내 중복 | 생성지≠소비지 |
| 매매 기록 | `TradeRecord` (StoragePort) | `TradeRecord` (BacktestResult 내) | — | 필드 세트 차이 |

### 1.3 위험

- 구현 시 `from path1.types import OHLCV` vs `from path3.types import OHLCV` 혼용 → 런타임 타입 에러
- Shared Store DDL의 컬럼과 Domain Type 필드 불일치 시 silent data loss
- Edge contract의 payload type이 어느 정의를 가리키는지 모호

---

## 2. 해결: Canonical Type 계층

### 2.1 구조

```
core/
├── domain/
│   ├── __init__.py              ← 전체 re-export
│   ├── market.py                ← 시세, 봉, 시장 상태
│   ├── order.py                 ← 주문, 체결, 주문 상태
│   ├── position.py              ← 포지션, 손익
│   ├── strategy.py              ← 전략 메타, 신호, 백테스트
│   ├── knowledge.py             ← 온톨로지, 인과관계
│   ├── intelligence.py          ← MarketContext, 수급, 호가
│   ├── watchlist.py             ← 관심종목, 스크리닝
│   ├── audit.py                 ← 감사 이벤트, 알림, 명령
│   └── common.py                ← 공통 Enum, 기본 타입
```

### 2.2 규칙

```
규칙 1: 2개 이상 Path에서 사용되는 타입은 반드시 core/domain/에 정의.
규칙 2: 1개 Path 내부에서만 사용되는 타입은 해당 Path 내부에 정의 가능.
         단, Shared Store에 영속화되는 타입은 무조건 core/domain/.
규칙 3: Port Interface의 메서드 시그니처는 core/domain/ 타입만 참조.
규칙 4: 모든 Domain Type은 pydantic.BaseModel 또는 @dataclass(frozen=True).
규칙 5: Enum은 core/domain/common.py에 통합. Path별 Enum 재정의 금지.
```

---

## 3. Canonical Type 정의

### 3.1 common.py — 공통 Enum (통합)

```python
"""core/domain/common.py — 전체 시스템 공용 Enum"""
from enum import Enum


# --- 시장 ---
class MarketStatus(Enum):
    PRE_MARKET = "pre_market"
    OPEN = "open"
    CLOSING = "closing"
    CLOSED = "closed"
    HOLIDAY = "holiday"

class MarketType(Enum):
    KOSPI = "kospi"
    KOSDAQ = "kosdaq"
    ALL = "all"

class MarketRegime(Enum):
    NORMAL = "normal"
    VOLATILE = "volatile"
    CIRCUIT_BREAKER_1 = "cb_1"
    CIRCUIT_BREAKER_2 = "cb_2"
    CIRCUIT_BREAKER_3 = "cb_3"
    SIDECAR = "sidecar"
    PRE_MARKET = "pre_market"
    POST_MARKET = "post_market"
    CLOSED = "closed"


# --- 주문 ---
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

class OrderLifecycleState(Enum):
    DRAFT = "draft"
    VALIDATING = "validating"
    SUBMITTING = "submitting"
    SUBMITTED = "submitted"
    ACCEPTED = "accepted"
    REJECTED = "rejected"
    PARTIALLY_FILLED = "partially_filled"
    FILLED = "filled"
    MODIFYING = "modifying"
    CANCELLING = "cancelling"
    CANCELLED = "cancelled"
    UNKNOWN = "unknown"

class OrderDivision(Enum):
    LIMIT = "00"
    MARKET = "01"
    CONDITIONAL = "02"
    BEST_LIMIT = "03"
    BEST_FIRST = "04"
    PRE_MARKET = "05"
    POST_MARKET = "06"
    AFTER_HOURS_SINGLE = "07"
    IOC_LIMIT = "11"
    FOK_LIMIT = "12"
    IOC_MARKET = "13"
    FOK_MARKET = "14"
    IOC_BEST = "15"
    FOK_BEST = "16"
    MID_PRICE = "21"
    STOP_LIMIT = "22"
    MID_PRICE_IOC = "23"
    MID_PRICE_FOK = "24"

class ExchangeType(Enum):
    KRX = "KRX"
    NXT = "NXT"
    SOR = "SOR"


# --- 포지션/청산 ---
class PositionSide(Enum):
    LONG = "long"
    SHORT = "short"
    FLAT = "flat"

class ExitType(Enum):
    STOP_LOSS = "stop_loss"
    TAKE_PROFIT = "take_profit"
    TRAILING_STOP = "trailing_stop"
    TIME_LIMIT = "time_limit"
    STRATEGY_EXIT = "strategy_exit"
    FORCE_CLOSE = "force_close"


# --- 관심종목 ---
class WatchlistStatus(Enum):
    CANDIDATE = "candidate"
    WATCHING = "watching"
    ENTRY_TRIGGERED = "entry_triggered"
    IN_POSITION = "in_position"
    EXIT_TRIGGERED = "exit_triggered"
    CLOSED = "closed"
    BLACKLISTED = "blacklisted"
    REMOVED = "removed"

class ScreenerTimeframe(Enum):
    PRE_MARKET = "pre_market"
    INTRADAY = "intraday"
    POST_MARKET = "post_market"


# --- 전략 ---
class StrategyStatus(Enum):
    DRAFT = "draft"
    BACKTESTED = "backtested"
    OPTIMIZED = "optimized"
    APPROVED = "approved"
    DEPLOYED = "deployed"
    RETIRED = "retired"

class StrategyType(Enum):
    MOMENTUM = "momentum"
    MEAN_REVERSION = "mean_reversion"
    BREAKOUT = "breakout"
    STATISTICAL_ARB = "statistical_arb"
    EVENT_DRIVEN = "event_driven"
    COMPOSITE = "composite"

class OptimizationMethod(Enum):
    GRID_SEARCH = "grid_search"
    RANDOM_SEARCH = "random_search"
    BAYESIAN = "bayesian"
    WALK_FORWARD = "walk_forward"


# --- 지식 ---
class SourceType(Enum):
    DART_FILING = "dart_filing"
    NEWS_ARTICLE = "news_article"
    EARNINGS_CALL = "earnings_call"
    SUPPLY_CHAIN = "supply_chain"
    MACRO_INDICATOR = "macro_indicator"
    SEC_FILING = "sec_filing"

class OntologyNodeType(Enum):
    COMPANY = "company"
    PERSON = "person"
    PRODUCT = "product"
    METRIC = "metric"
    EVENT = "event"
    SECTOR = "sector"
    SUPPLY_CHAIN = "supply_chain"

class LLMRole(Enum):
    EXTRACTOR = "extractor"
    SUMMARIZER = "summarizer"
    CAUSAL_REASONER = "causal_reasoner"
    CLASSIFIER = "classifier"


# --- 수급/종목 ---
class InvestorType(Enum):
    FOREIGN = "foreign"
    INSTITUTION = "institution"
    INDIVIDUAL = "individual"
    PROGRAM = "program"
    FOREIGN_MEMBER = "foreign_member"

class StockWarningLevel(Enum):
    NONE = "none"
    CAUTION = "caution"
    WARNING = "warning"
    DANGER = "danger"

class StockTradingStatus(Enum):
    TRADABLE = "tradable"
    HALTED = "halted"
    SUSPENDED = "suspended"
    ADMIN_ISSUE = "admin_issue"
    DELISTING = "delisting"


# --- 리스크 ---
class RiskVerdict(Enum):
    APPROVED = "approved"
    REDUCED = "reduced"
    REJECTED = "rejected"
    HALTED = "halted"

class ResolutionMethod(Enum):
    PRIORITY = "priority"
    STRENGTH = "strength"
    CONSENSUS = "consensus"
    CANCEL = "cancel"
    WEIGHTED = "weighted"


# --- Watchdog ---
class ComponentStatus(Enum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"
    UNKNOWN = "unknown"

class AuditSeverity(Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    CRITICAL = "critical"

class AlertPriority(Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"

class AlertChannel(Enum):
    TELEGRAM = "telegram"
    DISCORD = "discord"
    SLACK = "slack"
    EMAIL = "email"
    CONSOLE = "console"

class CommandRiskLevel(Enum):
    READ_ONLY = "read_only"
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"
```

### 3.2 market.py — 시세/봉 (통합)

```python
"""core/domain/market.py — 시세, 봉 데이터"""
from dataclasses import dataclass, field
from datetime import datetime


@dataclass(frozen=True)
class Quote:
    """현재가 스냅샷 — KIS inquire_price 응답 기반.
    
    Canonical. Path 1, 3, 4, 6 에서 동일 타입 사용.
    """
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
    """봉 데이터.
    
    Canonical. Path 1, 3에서 동일 타입 사용.
    NOTE: 'date' 필드 통일 (이전 Path 3에서 trade_date로 쓰던 것 폐기)
    """
    symbol: str
    date: str                     # "2026-04-15" (ISO 8601 date)
    open: int
    high: int
    low: int
    close: int
    volume: int
    amount: int | None = None
    adjusted: bool = True         # 수정주가 여부
```

### 3.3 order.py — 주문/체결 (통합)

```python
"""core/domain/order.py — 주문 요청, 결과, 체결 기록"""
from dataclasses import dataclass, field
from datetime import datetime
from .common import OrderSide, OrderType, OrderStatus


@dataclass(frozen=True)
class OrderRequest:
    """주문 요청.
    
    Canonical. Path 1 RiskGuard, Path 4 AllocationEngine에서 생성.
    Path 1 OrderExecutor에서 소비.
    """
    symbol: str
    side: OrderSide
    quantity: int
    order_type: OrderType
    price: int | None = None
    strategy_id: str = ""
    stop_loss: float | None = None
    take_profit: float | None = None
    correlation_id: str = ""      # 진입-청산 연결 ID


@dataclass
class OrderResult:
    """주문 결과.
    
    Canonical. BrokerPort가 반환, OrderExecutor → TradingFSM으로 전달.
    """
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
class TradeRecord:
    """체결 기록.
    
    Canonical. Path 1 OrderExecutor가 생성, PortfolioStore에 영속화.
    Path 3 BacktestEngine도 이 타입으로 시뮬레이션 거래 기록.
    NOTE: trade_id는 UUID, order_id는 KIS 주문번호.
    """
    trade_id: str                 # UUID (시스템 생성)
    order_id: str                 # KIS 주문번호 (실전) 또는 시뮬레이션 ID (백테스트)
    symbol: str
    side: OrderSide
    quantity: int
    price: float
    commission: float
    securities_tax: float = 0.0   # 매도 시만
    strategy_id: str = ""
    slippage_bps: float = 0.0
    traded_at: datetime = field(default_factory=datetime.now)
    is_backtest: bool = False     # 실전 vs 백테스트 구분
```

### 3.4 position.py — 포지션 (통합)

```python
"""core/domain/position.py — 포지션 관련 타입"""
from dataclasses import dataclass, field
from datetime import datetime
from .common import PositionSide, ExitType


@dataclass(frozen=True)
class Position:
    """보유 종목 (브로커 잔고 기준).
    
    Canonical. BrokerPort.get_account()가 반환.
    이전 Path 1의 Position과 Path 4의 PositionEntry 통합.
    """
    symbol: str
    name: str
    quantity: int
    avg_price: float
    current_price: float
    unrealized_pnl: float
    unrealized_pnl_pct: float
    side: PositionSide = PositionSide.LONG
    strategy_id: str = ""
    entry_date: str = ""
    holding_days: int = 0
    market_value: float = 0.0     # 시가평가 (현재가 × 수량)
    weight: float = 0.0           # 포트폴리오 내 비중 (%)


@dataclass
class LivePosition:
    """실시간 포지션 (틱마다 갱신).
    
    Canonical. Path 1C PositionMonitor가 관리.
    """
    symbol: str
    name: str
    strategy_id: str
    quantity: int
    avg_entry_price: float
    current_price: float
    unrealized_pnl: float
    unrealized_pnl_pct: float
    highest_price: float
    lowest_price: float
    drawdown_from_high_pct: float
    entry_time: datetime
    holding_seconds: int
    last_tick_at: datetime
    volume_since_entry: int = 0
    tick_count: int = 0


@dataclass(frozen=True)
class ExitSignal:
    """청산 신호.
    
    Canonical. ExitConditionGuard → ExitExecutor로 전달.
    """
    symbol: str
    exit_type: ExitType
    trigger_price: float
    current_pnl_pct: float
    reason: str
    urgency: str                  # "normal" | "urgent" | "immediate"
    suggested_order_type: str     # "market" | "limit"
    suggested_price: float | None = None
    timestamp: datetime = field(default_factory=datetime.now)


@dataclass(frozen=True)
class ExitResult:
    """청산 실행 결과.
    
    Canonical. ExitExecutor → WatchlistManager로 전달.
    """
    symbol: str
    exit_type: ExitType
    success: bool
    order_id: str | None = None
    message: str = ""
    actual_pnl_pct: float | None = None
    post_action: str = ""         # "return_to_watchlist" | "blacklist" | "remove"
```

### 3.5 strategy.py — 전략/신호 (통합)

```python
"""core/domain/strategy.py — 전략 메타, 매매 신호"""
from dataclasses import dataclass, field
from datetime import datetime
from .common import StrategyStatus, StrategyType


@dataclass(frozen=True)
class SignalOutput:
    """매매 신호.
    
    Canonical. Path 1 StrategyEngine이 생성,
    Path 4 ConflictResolver와 Path 1 RiskGuard가 소비.
    정의 위치: core/domain (이전 Path 3에서 정의 → 이동)
    """
    symbol: str
    side: str                     # "buy" | "sell" | "hold"
    strength: float               # 0.0 ~ 1.0
    reason: str
    strategy_id: str = ""
    suggested_quantity: int | None = None
    suggested_price: float | None = None
    stop_loss: float | None = None
    take_profit: float | None = None
    metadata: dict = field(default_factory=dict)


@dataclass(frozen=True)
class AccountSummary:
    """계좌 요약.
    
    Canonical. BrokerPort.get_account()가 반환.
    """
    total_equity: float
    cash: float
    invested: float
    total_pnl: float
    total_pnl_pct: float
    positions: list = field(default_factory=list)  # list[Position]
```

---

## 4. Cross-Path Type 의존 맵

각 Path가 core/domain의 어떤 타입을 참조하는지 명시.

### 4.1 의존 매트릭스

| core/domain/ module | Path 1 | Path 2 | Path 3 | Path 4 | Path 5 | Path 6 |
|---------------------|--------|--------|--------|--------|--------|--------|
| common.py (Enums) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| market.py | ✅ Quote, OHLCV | — | ✅ OHLCV | ✅ Quote | — | ✅ Quote |
| order.py | ✅ 전체 | — | ✅ TradeRecord | — | ✅ AuditEvent 내 | — |
| position.py | ✅ 전체 | — | — | ✅ Position, LivePosition | — | — |
| strategy.py | ✅ SignalOutput | — | ✅ 전체 | ✅ SignalOutput | — | — |
| knowledge.py | — | ✅ 전체 | ✅ CausalLink | — | — | — |
| intelligence.py | ✅ MarketContext | — | ✅ MarketContext | — | — | ✅ 전체 |
| watchlist.py | ✅ 전체 | — | — | — | — | — |
| audit.py | — | — | — | — | ✅ 전체 | — |

### 4.2 Path 전용 타입 (core/domain에 넣지 않는 것)

| Path | 전용 타입 | 이유 |
|------|----------|------|
| Path 1 | IndicatorResult | 1B 내부 IndicatorCalculator → StrategyEngine 전용 |
| Path 2 | RawDocument, ParsedEntity, ParsedRelation, ParsedDocument | 수집→파싱 파이프라인 내부 전용 |
| Path 3 | StrategyCode, StrategyParam, OptimizationConfig, BacktestConfig | 전략 개발 파이프라인 내부 전용 |
| Path 3 | BacktestResult (TradeRecord 참조하되 결과 구조는 전용) | 백테스트 전용 집계 |
| Path 4 | AllocationPlan, SizingRequest, SizingResult | 배분 엔진 내부 전용 |
| Path 5 | HealthStatus, SystemHealth, Anomaly, ApprovalRequest | 감시 내부 전용 |
| Path 6 | OrderBookSnapshot, OrderBookAnalysis, PriceDistribution | 호가 분석 내부 전용 |

---

## 5. 구현 규칙

### 5.1 Import 규칙

```python
# ✅ 올바른 import
from core.domain.market import Quote, OHLCV
from core.domain.order import OrderRequest, OrderResult, TradeRecord
from core.domain.common import OrderSide, OrderType

# ❌ 금지 — Path별 재정의
from path1.types import Quote        # NEVER
from path3.types import TradeRecord  # NEVER
```

### 5.2 Port Interface 수정 규칙

기존 6개 Path의 Port Interface 문서에서 정의된 Domain Type 중 core/domain에 이동된 것들은, Port 메서드 시그니처에서 `schema_ref`를 `core/domain/<module>#<Type>`으로 변경.

```yaml
# 변경 전
payload:
  type: Quote
  schema_ref: "port_interface_path1_v1.0#Quote"

# 변경 후
payload:
  type: Quote
  schema_ref: "core/domain/market#Quote"
```

### 5.3 Shared Store DDL 정합성

core/domain 타입의 필드와 DDL 컬럼이 1:1 대응하지 않아도 된다 (DB에는 추가 컬럼이 있을 수 있음). 단, **core/domain 타입의 필수 필드는 DDL에 NOT NULL 컬럼으로 존재해야 한다.**

---

## 6. 통계 업데이트

| 항목 | 이전 | 이후 | 비고 |
|------|------|------|------|
| 전체 Domain Types | 86 | 86 (변경 없음) | 타입 수 동일, 위치만 재배치 |
| core/domain 공용 | 0 | 25 | Enum 30종 + DataClass 25종 |
| Path 전용 | 86 | 61 | 25개가 core/domain으로 이동 |
| Enum 정의 위치 | 6개 문서에 분산 | common.py 1곳 | 통합 |

---

*End of Document — Shared Domain Types v1.0*
*25 Canonical Types | 30 Enum Classes | 6 Modules*
*모든 Port Interface 문서의 schema_ref가 이 문서를 가리킴*
