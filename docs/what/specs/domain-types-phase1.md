# Phase 1 도메인 타입 정의 (20개·Pydantic v2)

> **목적**: Phase 1에서 사용하는 20개 도메인 타입의 Pydantic v2 정의, 사용 예시, 구현 체크리스트를 기술한다.
> **층**: What
> **상태**: stable
> **구현 여정**: Step 00에서 Bar/Signal/Order/Fill 4개, Step 02에서 나머지 타입 도입. ADR-012 §6 참조.
> **선행 문서**: `docs/what/decisions/011-phase1-scope.md`
> **구현 위치**: `core/domain/*.py`
> **라이브러리**: pydantic v2

## 1. 설계 원칙

1. **불변**: `model_config = ConfigDict(frozen=True)` — 모든 Domain Type은 immutable
2. **자체 완결적**: 외부 DB/ORM 의존 없음 — 순수 값 객체
3. **JSON serialize 가능**: `audit_events.payload`에 그대로 기록
4. **타입 수 최소화**: 기존 86개 → Phase 1은 **20개만**

---

## 2. 타입 목록 (20개)

| # | 타입 | 용도 | 위치 |
|---|------|------|------|
| 1 | `Symbol` | 종목 코드 NewType | `core/domain/primitives.py` |
| 2 | `Price` | 가격 Decimal NewType | 〃 |
| 3 | `Quantity` | 수량 int NewType | 〃 |
| 4 | `Money` | 원화 금액 NewType | 〃 |
| 5 | `CorrelationId` | UUID NewType | 〃 |
| 6 | `OrderSide` | Enum (buy/sell) | `core/domain/enums.py` |
| 7 | `OrderType` | Enum (limit/market) | 〃 |
| 8 | `OrderStatus` | Enum (8개 상태) | 〃 |
| 9 | `FSMState` | Enum (6개 상태) | 〃 |
| 10 | `BrokerMode` | Enum (mock/kis_paper/kis_live) | 〃 |
| 11 | `Quote` | 단일 틱 시세 | `core/domain/market.py` |
| 12 | `OHLCV` | 봉 데이터 | 〃 |
| 13 | `IndicatorBundle` | 지표 묶음 | 〃 |
| 14 | `SignalOutput` | 전략 출력 | `core/domain/signal.py` |
| 15 | `OrderRequest` | 주문 요청 | `core/domain/order.py` |
| 16 | `OrderResult` | 주문 결과 | 〃 |
| 17 | `TradeRecord` | 체결 기록 | `core/domain/order.py` |
| 18 | `Position` | 포지션 스냅샷 | `core/domain/portfolio.py` |
| 19 | `PortfolioSnapshot` | 전체 포트폴리오 상태 | 〃 |
| 20 | `RiskDecision` | Pre-Order 체크 결과 | `core/domain/risk.py` |

---

## 3. 타입 정의 (Pydantic v2)

### 3.1 Primitives

```python
# core/domain/primitives.py
from decimal import Decimal
from typing import NewType
from uuid import UUID

Symbol = NewType('Symbol', str)         # '005930' 같은 6자리 종목 코드
Price = NewType('Price', Decimal)       # 원 단위 가격
Quantity = NewType('Quantity', int)     # 주식 수량
Money = NewType('Money', Decimal)       # KRW 금액
CorrelationId = NewType('CorrelationId', UUID)
```

### 3.2 Enums

```python
# core/domain/enums.py
from enum import StrEnum

class OrderSide(StrEnum):
    BUY = 'buy'
    SELL = 'sell'

class OrderType(StrEnum):
    LIMIT = 'limit'
    MARKET = 'market'

class OrderStatus(StrEnum):
    SUBMITTED = 'submitted'
    ACCEPTED = 'accepted'
    PARTIALLY_FILLED = 'partially_filled'
    FILLED = 'filled'
    CANCELLED = 'cancelled'
    REJECTED = 'rejected'
    EXPIRED = 'expired'
    FAILED = 'failed'      # 네트워크 오류 등 (Phase 1 추가)

class FSMState(StrEnum):
    IDLE = 'IDLE'
    ENTRY_PENDING = 'ENTRY_PENDING'
    IN_POSITION = 'IN_POSITION'
    EXIT_PENDING = 'EXIT_PENDING'
    ERROR = 'ERROR'
    SAFE_MODE = 'SAFE_MODE'

class BrokerMode(StrEnum):
    MOCK = 'mock'
    KIS_PAPER = 'kis_paper'
    KIS_LIVE = 'kis_live'        # Phase 2 전환 시까지 사용 금지
```

### 3.3 Market Data

```python
# core/domain/market.py
from datetime import datetime
from pydantic import BaseModel, ConfigDict, Field
from .primitives import Symbol, Price, Quantity

class Quote(BaseModel):
    model_config = ConfigDict(frozen=True)

    ts: datetime
    symbol: Symbol
    price: Price
    volume: Quantity
    bid_price: Price | None = None
    ask_price: Price | None = None
    source: str                    # 'kis_ws', 'kis_rest', 'csv_replay'


class OHLCV(BaseModel):
    model_config = ConfigDict(frozen=True)

    ts: datetime
    symbol: Symbol
    interval: str                  # '1d', '1m', '5m'
    open: Price
    high: Price
    low: Price
    close: Price
    volume: Quantity
    trading_value: Price | None = None


class IndicatorBundle(BaseModel):
    model_config = ConfigDict(frozen=True)

    symbol: Symbol
    ts: datetime
    indicators: dict[str, float | None]
    # 예: {"sma_5": 72100.0, "sma_20": 71850.0, "rsi_14": 58.3}
```

### 3.4 Signal

```python
# core/domain/signal.py
from datetime import datetime
from pydantic import BaseModel, ConfigDict
from .primitives import Symbol, Price, Quantity
from .enums import OrderSide

class SignalOutput(BaseModel):
    model_config = ConfigDict(frozen=True)

    ts: datetime
    symbol: Symbol
    side: OrderSide
    price: Price                   # 지정가 (시장가면 마지막 종가로)
    quantity: Quantity
    is_entry: bool                 # True=신규 진입, False=청산
    strategy_name: str
    strategy_version: str
    confidence: float = 1.0        # 0.0 ~ 1.0 (Phase 1은 참고용)
    rationale: str = ''            # 감사용 설명
```

### 3.5 Order

```python
# core/domain/order.py
from datetime import datetime
from decimal import Decimal
from uuid import UUID, uuid4
from pydantic import BaseModel, ConfigDict, Field
from .primitives import Symbol, Price, Quantity, Money, CorrelationId
from .enums import OrderSide, OrderType, OrderStatus

class OrderRequest(BaseModel):
    model_config = ConfigDict(frozen=True)

    order_uuid: UUID = Field(default_factory=uuid4)
    correlation_id: CorrelationId
    symbol: Symbol
    side: OrderSide
    order_type: OrderType
    price: Price | None            # 시장가면 None
    quantity: Quantity
    strategy_name: str
    strategy_version: str
    submitted_at: datetime


class OrderResult(BaseModel):
    model_config = ConfigDict(frozen=True)

    order_uuid: UUID
    broker_order_id: str | None
    status: OrderStatus
    filled_quantity: Quantity = 0
    avg_fill_price: Price | None = None
    error_message: str | None = None
    received_at: datetime


class TradeRecord(BaseModel):
    model_config = ConfigDict(frozen=True)

    trade_id: UUID = Field(default_factory=uuid4)
    order_uuid: UUID
    correlation_id: CorrelationId
    symbol: Symbol
    side: OrderSide
    fill_price: Price
    fill_quantity: Quantity
    fee: Money                     # 증권사 수수료
    tax: Money                     # 증권거래세 (매도 시 0.23%)
    broker_trade_id: str | None
    executed_at: datetime
```

### 3.6 Portfolio

```python
# core/domain/portfolio.py
from datetime import datetime
from pydantic import BaseModel, ConfigDict
from .primitives import Symbol, Price, Quantity, Money
from .enums import FSMState

class Position(BaseModel):
    model_config = ConfigDict(frozen=True)

    symbol: Symbol
    quantity: Quantity
    avg_entry_price: Price
    entry_fee: Money
    opened_at: datetime
    fsm_state: FSMState
    strategy_name: str

    def market_value(self, current_price: Price) -> Money:
        return Money(current_price * self.quantity)

    def unrealized_pnl(self, current_price: Price) -> Money:
        return Money((current_price - self.avg_entry_price) * self.quantity - self.entry_fee)


class PortfolioSnapshot(BaseModel):
    model_config = ConfigDict(frozen=True)

    ts: datetime
    cash: Money                          # 가용 현금
    total_equity: Money                  # 총 자본 (cash + sum(positions.market_value))
    positions: dict[Symbol, Position]
    daily_pnl: Money = Money(0)
    today_trade_count: int = 0

    def exposure_of(self, symbol: Symbol) -> Money:
        pos = self.positions.get(symbol)
        return Money(0) if pos is None else Money(pos.avg_entry_price * pos.quantity)
```

### 3.7 Risk

```python
# core/domain/risk.py
from pydantic import BaseModel, ConfigDict
from .signal import SignalOutput

class RiskDecision(BaseModel):
    model_config = ConfigDict(frozen=True)

    approved: bool
    check_name: str | None = None        # 차단된 체크 이름 (예: 'daily_loss_limit')
    reason: str | None = None
    modified_signal: SignalOutput | None = None
    # 수량 축소 등 수정된 Signal (현재 Phase 1은 거부만, Phase 2에서 활성)
```

---

## 4. Phase 1에 **포함하지 않는** Domain Types

기존 86타입 중 다음은 Phase 2 이후로 연기:

| 연기 타입 | 이유 |
|---------|------|
| `MarketContext`, `VolumeProfile`, `HogaSnapshot` | Path 6 전체 연기 |
| `NewsItem`, `KnowledgeFragment`, `OntologyNode` | Path 2 전체 연기 |
| `StrategyTemplate`, `OptimizationResult` | Path 3 자동생성 연기 |
| `PortfolioTarget`, `RebalanceOrder` | Path 4 전체 연기 |
| `VIEvent`, `CBEvent`, `MarketRegime` | MarketIntelligence 연기 |
| `ApprovalRequest`, `ApprovalDecision` | SEMI_AUTO 연기 |
| `RegimeDetectorOutput`, `SectorExposure` | 고급 리스크 연기 |

---

## 5. 타입 사용 예시

```python
# 전략이 Signal 생성
signal = SignalOutput(
    ts=datetime.now(KST),
    symbol=Symbol('005930'),
    side=OrderSide.BUY,
    price=Price(Decimal('72100')),
    quantity=Quantity(10),
    is_entry=True,
    strategy_name='ma_crossover',
    strategy_version='1.0',
    confidence=0.8,
    rationale='SMA5(72300) crossed above SMA20(71850)',
)

# RiskGuard가 판단
decision = risk_guard.evaluate(signal, portfolio_snapshot)
if not decision.approved:
    await audit.log(event_type='risk_check_failed',
                    severity='warn',
                    payload=decision.model_dump(mode='json'))
    return

# OrderExecutor가 주문 실행
request = OrderRequest(
    correlation_id=CorrelationId(uuid4()),
    symbol=signal.symbol,
    side=signal.side,
    order_type=OrderType.LIMIT,
    price=signal.price,
    quantity=signal.quantity,
    strategy_name=signal.strategy_name,
    strategy_version=signal.strategy_version,
    submitted_at=datetime.now(KST),
)
result: OrderResult = await broker.submit(request)
```

---

## 6. 구현 체크리스트

- [ ] `core/domain/primitives.py` — NewType 5개
- [ ] `core/domain/enums.py` — Enum 5개
- [ ] `core/domain/market.py` — Quote, OHLCV, IndicatorBundle
- [ ] `core/domain/signal.py` — SignalOutput
- [ ] `core/domain/order.py` — OrderRequest, OrderResult, TradeRecord
- [ ] `core/domain/portfolio.py` — Position, PortfolioSnapshot
- [ ] `core/domain/risk.py` — RiskDecision
- [ ] `core/domain/__init__.py` — 재수출
- [ ] 단위 테스트 — frozen 검증, JSON round-trip

---

*End of Document — Domain Types Phase 1*
