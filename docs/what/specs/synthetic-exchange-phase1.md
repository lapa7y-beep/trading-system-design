# synthetic-exchange-phase1 — 가상거래소 설계

> **상태**: draft (2026-04-17)
> **위치**: `docs/what/specs/synthetic-exchange-phase1.md`
> **목적**: 실제 시세 데이터 없이도 Phase 1 합격 기준 전체를 검증할 수 있는 **자기완결적 가상거래소**를 설계한다.
> **선행 문서**: `docs/what/specs/quant-spec-phase1.md`, `docs/what/specs/adapter-spec-phase1.md`, `docs/what/specs/port-signatures-phase1.md`
> **핵심 원칙**: 기존 6노드·14엣지·6포트 **무변경**. Adapter 2개 추가만으로 실현.

---

## 0. 왜 가상거래소인가

| 문제 | CSVReplayAdapter | SyntheticExchange |
|------|-----------------|-------------------|
| 데이터 확보 | 2년치 1m bar 100만 레코드 필요 (K3) | 파라미터 3개로 무한 생성 |
| 검증 강도 | "이 종목 이 기간에 됐다" | "이 전략 구조가 N회 시뮬에서 통계적으로 유효하다" |
| 재현성 | 데이터 파일 해시 고정 | random_seed 고정 → 동일 시계열 |
| 엣지 케이스 | 과거에 발생한 것만 | 상한가·VI·급락·빈봉 주입 가능 |
| 실행 속도 | I/O 바운드 (파일 읽기) | CPU 바운드 (생성 즉시 소비) |
| KIS 의존 | 데이터 수집 시 KIS API 필요 | **완전 독립** |

가상거래소는 CSVReplay를 **대체하는 것이 아니라 보완**한다. 실제 데이터로 최종 검증하기 전에 전략의 구조적 유효성을 먼저 증명하는 도구다.

---

## 1. 아키텍처 — 기존 시스템과의 관계

### 1.1 Plug & Play: Adapter 2개 추가

```
기존 12 Adapter (무변경)
  ├── MarketDataPort: KISWebSocket, KISRest, CSVReplay
  ├── BrokerPort:     MockBroker, KISPaper, (KISLive Phase 2)
  └── ...

신규 2 Adapter (추가)
  ├── MarketDataPort: SyntheticMarketAdapter    ← 시세 생성
  └── BrokerPort:     SyntheticBrokerAdapter    ← 체결 시뮬레이션
```

왜 2개인가 — **가상거래소는 시세와 체결이 연동**되어야 한다. MockBrokerAdapter는 "마지막 Quote의 가격으로 체결"하지만, SyntheticBrokerAdapter는 **호가창 시뮬레이션 기반 체결**을 한다. 시세 생성 엔진이 호가창 상태를 알아야 체결 가능성을 판단할 수 있으므로, 두 Adapter가 내부적으로 하나의 `ExchangeEngine`을 공유한다.

### 1.2 config.yaml 모드 추가

```yaml
# config/config.yaml
broker:
  mode: synthetic          # mock | paper | synthetic (신규)
market_data:
  mode: synthetic          # ws | poll | csv_replay | synthetic (신규)
```

Adapter Factory 선택 규칙 추가:

| broker.mode | market_data.mode | 어댑터 세트 |
|-------------|-----------------|------------|
| synthetic | synthetic | SyntheticBroker + SyntheticMarket + InMemory + HistoricalClock + StdoutAudit |

**반드시 쌍으로 사용**. `broker: synthetic + market_data: ws` 같은 혼합은 금지.

### 1.3 내부 구조

```
┌─────────────────────────────────────────────────┐
│                  ExchangeEngine                  │
│                  (공유 코어)                      │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
│  │ PriceGen │  │ OrderBook│  │ MarketRules   │  │
│  │ (시세생성)│  │ (호가창) │  │ (한국시장규칙)│  │
│  └────┬─────┘  └────┬─────┘  └───────┬───────┘  │
│       │              │                │          │
│       └──────────────┴────────────────┘          │
│                      │                           │
│           ┌──────────┴──────────┐                │
│           │                     │                │
│  ┌────────▼────────┐  ┌────────▼────────┐       │
│  │SyntheticMarket  │  │SyntheticBroker  │       │
│  │Adapter          │  │Adapter          │       │
│  │(MarketDataPort) │  │(BrokerPort)     │       │
│  └─────────────────┘  └─────────────────┘       │
└─────────────────────────────────────────────────┘
         │                       │
         ▼                       ▼
   MarketDataReceiver      OrderExecutor
   (기존 노드 무변경)     (기존 노드 무변경)
```

---

## 2. ExchangeEngine — 핵심 코어

### 2.1 책임

1. **시세 생성** (PriceGenerator): 확률 모델로 tick/bar 시계열 생성
2. **호가창 관리** (OrderBook): 미체결 주문 관리, 체결 매칭
3. **시장 규칙 적용** (MarketRules): 한국시장 제약 (호가단위, 상하한가, VI, 거래시간)
4. **시간 진행** (ClockPort 연동): HistoricalClockAdapter의 시간에 동기화

### 2.2 클래스 설계

```python
class ExchangeEngine:
    """가상거래소 핵심 엔진. SyntheticMarket + SyntheticBroker가 공유."""

    def __init__(self, config: SyntheticExchangeConfig, seed: int):
        self._rng = np.random.default_rng(seed)
        self._price_gen = PriceGenerator(config.price_model, self._rng)
        self._order_book = OrderBook()
        self._rules = MarketRules(config.market_rules)
        self._current_time: datetime | None = None
        self._state: dict[Symbol, SymbolState] = {}

    def initialize(self, symbols: list[Symbol], start_date: date) -> None:
        """거래소 초기화. 종목별 초기 가격·상태 설정."""
        for sym in symbols:
            initial_price = self._price_gen.sample_initial_price(sym)
            self._state[sym] = SymbolState(
                symbol=sym,
                last_price=initial_price,
                prev_close=initial_price,
                upper_limit=self._rules.upper_limit(initial_price),
                lower_limit=self._rules.lower_limit(initial_price),
                is_vi=False,
                vi_cooldown_until=None,
            )

    def advance_to(self, ts: datetime) -> list[Quote]:
        """시간을 ts로 진행. 해당 시점의 tick(들)을 생성하여 반환."""
        self._current_time = ts

        # 장중 아닌 시간 → 빈 리스트
        if not self._rules.is_trading_hours(ts):
            return []

        # 일 전환 시 prev_close 갱신 + 상하한가 재계산
        for sym, state in self._state.items():
            if self._is_new_trading_day(ts, state):
                state.prev_close = state.last_price
                state.upper_limit = self._rules.upper_limit(state.prev_close)
                state.lower_limit = self._rules.lower_limit(state.prev_close)
                state.is_vi = False

        quotes = []
        for sym, state in self._state.items():
            quote = self._price_gen.next_tick(sym, state, ts)

            # 상하한가 클램핑
            quote = self._rules.clamp_price(quote, state)

            # VI 감지
            if self._rules.detect_vi(quote, state):
                state.is_vi = True
                state.vi_cooldown_until = ts + timedelta(seconds=120)
            elif state.vi_cooldown_until and ts >= state.vi_cooldown_until:
                state.is_vi = False

            state.last_price = quote.price
            quotes.append(quote)

        # 호가창 매칭 (대기 주문이 있으면 체결 시도)
        self._order_book.match(self._state, self._current_time)

        return quotes

    def submit_order(self, order: OrderRequest) -> OrderResult:
        """주문 제출. 호가창에 등록 후 즉시 매칭 시도."""
        sym_state = self._state.get(order.symbol)
        if not sym_state:
            return OrderResult(order_uuid=order.order_uuid, status=OrderStatus.REJECTED,
                               broker_order_id=None, message="Unknown symbol")

        # 시장 규칙 검증
        violation = self._rules.validate_order(order, sym_state)
        if violation:
            return OrderResult(order_uuid=order.order_uuid, status=OrderStatus.REJECTED,
                               broker_order_id=None, message=violation)

        # 호가단위 보정
        corrected_price = self._rules.round_to_tick(order.price, order.side)

        # 호가창 등록
        book_order = self._order_book.add(order, corrected_price, self._current_time)

        # 즉시 매칭 시도
        fill = self._order_book.try_match(book_order, sym_state)
        if fill:
            return fill

        return OrderResult(order_uuid=order.order_uuid, status=OrderStatus.ACCEPTED,
                           broker_order_id=book_order.book_id)
```

---

## 3. PriceGenerator — 시세 생성 모델

### 3.1 3단계 모델 (Level 1→2→3 점진 구현)

#### Level 1: GBM (기하 브라운 운동) — Phase 1 기본

```python
class GBMPriceGenerator:
    """dS = μ·S·dt + σ·S·dW"""

    def __init__(self, config: GBMConfig, rng: np.random.Generator):
        self._mu = config.drift_annual       # 연간 기대수익률 (기본 0.08 = 8%)
        self._sigma = config.vol_annual      # 연간 변동성 (기본 0.25 = 25%)
        self._rng = rng
        self._dt = 1.0 / (252 * 390)         # 1분 = 1/(영업일 × 장중분수)

    def next_tick(self, symbol: Symbol, state: SymbolState, ts: datetime) -> Quote:
        S = float(state.last_price)
        dW = self._rng.standard_normal()
        dS = self._mu * S * self._dt + self._sigma * S * (self._dt ** 0.5) * dW
        new_price = max(1, int(round(S + dS)))  # 최소 1원

        volume = self._generate_volume(ts)

        return Quote(
            ts=ts, symbol=symbol,
            price=Price(Decimal(new_price)),
            volume=Quantity(volume),
            source='synthetic'
        )

    def _generate_volume(self, ts: datetime) -> int:
        """U자형 거래량 분포: 장 시작/마감에 집중"""
        minutes_from_open = (ts.hour - 9) * 60 + ts.minute
        total_minutes = 380  # 09:00~15:20
        # U자형: cos(π * t/T) → 양 끝 높고 중앙 낮음
        u_factor = 0.5 + 0.5 * abs(math.cos(math.pi * minutes_from_open / total_minutes))
        base = self._rng.poisson(lam=50)
        return max(1, int(base * u_factor * 3))
```

**파라미터 기본값 (한국시장 대형주 기준)**:

```yaml
synthetic:
  seed: 42
  price_model:
    type: "gbm"
    drift_annual: 0.08           # KOSPI 장기 평균 ~8%
    vol_annual: 0.25             # 대형주 연간 변동성 ~25%

  initial_prices:                # 종목별 시작가 (watchlist 5종목)
    "005930": 72000              # 삼성전자
    "000660": 180000             # SK하이닉스
    "373220": 380000             # LG에너지솔루션
    "207940": 750000             # 삼성바이오로직스
    "005380": 210000             # 현대차
```

#### Level 2: GBM + 한국시장 현실성 주입

Level 1에 다음 4가지 보강:

```python
class RealisticPriceGenerator(GBMPriceGenerator):
    """GBM + 한국시장 미시구조"""

    def next_tick(self, symbol, state, ts):
        quote = super().next_tick(symbol, state, ts)

        # (A) 호가단위 이산화: 연속가격 → 호가단위 격자
        quote.price = self._discretize_to_tick(quote.price)

        # (B) 장중 변동성 스마일: 09:00~09:30 변동성 1.5배, 14:50~15:20 1.3배
        quote = self._apply_intraday_vol_smile(quote, ts)

        # (C) 점프 확산 (Merton): 하루 평균 0.3회, 점프 크기 ±3%
        if self._rng.random() < 0.3 / 390:  # 분당 확률
            jump = self._rng.normal(0, 0.03)
            quote.price *= (1 + jump)

        # (D) 호가 스프레드: bid = price - 1tick, ask = price + 1tick
        ts_val = tick_size(int(quote.price))
        quote.bid_price = quote.price - ts_val
        quote.ask_price = quote.price + ts_val

        return quote
```

#### Level 3: 레짐 전환 (Phase 2 대상)

```python
class RegimeSwitchingGenerator(RealisticPriceGenerator):
    """Hidden Markov Model — 3개 레짐"""

    REGIMES = {
        'bull':     {'mu': 0.15, 'sigma': 0.18, 'duration_days': (20, 60)},
        'sideways': {'mu': 0.02, 'sigma': 0.12, 'duration_days': (30, 90)},
        'bear':     {'mu': -0.10, 'sigma': 0.35, 'duration_days': (10, 40)},
    }
    TRANSITION = {
        'bull':     {'bull': 0.6, 'sideways': 0.3, 'bear': 0.1},
        'sideways': {'bull': 0.3, 'sideways': 0.5, 'bear': 0.2},
        'bear':     {'bull': 0.2, 'sideways': 0.4, 'bear': 0.4},
    }
```

### 3.2 Phase 1 선택: Level 2

Level 1은 너무 단순(MA cross가 GBM에서 항상 손실), Level 3은 과도. **Level 2가 Phase 1 적정 수준**.

---

## 4. OrderBook — 호가창 시뮬레이션

### 4.1 간소화된 호가창

실제 거래소의 10호가 전체를 시뮬레이션할 필요 없음. **1호가 최우선매수/매도만** 관리.

```python
@dataclass
class BookEntry:
    order: OrderRequest
    corrected_price: int
    submitted_at: datetime
    book_id: str                   # "SYN-{uuid[:8]}"

class OrderBook:
    def __init__(self):
        self._pending: dict[UUID, BookEntry] = {}

    def add(self, order: OrderRequest, corrected_price: int, ts: datetime) -> BookEntry:
        entry = BookEntry(order=order, corrected_price=corrected_price,
                         submitted_at=ts, book_id=f"SYN-{str(order.order_uuid)[:8]}")
        self._pending[order.order_uuid] = entry
        return entry

    def try_match(self, entry: BookEntry, state: SymbolState) -> OrderResult | None:
        """체결 조건: 매수 지정가 ≥ 현재가 or 매도 지정가 ≤ 현재가"""
        current = int(state.last_price)

        if entry.order.side == OrderSide.BUY and entry.corrected_price >= current:
            return self._fill(entry, current)
        elif entry.order.side == OrderSide.SELL and entry.corrected_price <= current:
            return self._fill(entry, current)
        return None

    def match(self, states: dict[Symbol, SymbolState], ts: datetime) -> list[OrderResult]:
        """시간 진행 시 대기 주문 전체 매칭 시도"""
        fills = []
        to_remove = []
        for uuid, entry in self._pending.items():
            state = states.get(entry.order.symbol)
            if not state: continue

            # 타임아웃 체크 (10초)
            if (ts - entry.submitted_at).total_seconds() > 10:
                fills.append(OrderResult(
                    order_uuid=uuid, status=OrderStatus.EXPIRED,
                    broker_order_id=entry.book_id))
                to_remove.append(uuid)
                continue

            fill = self.try_match(entry, state)
            if fill:
                fills.append(fill)
                to_remove.append(uuid)

        for uuid in to_remove:
            del self._pending[uuid]

        return fills

    def _fill(self, entry: BookEntry, fill_price: int) -> OrderResult:
        """체결 처리. 슬리피지 1틱 적용."""
        ts_val = tick_size(fill_price)
        if entry.order.side == OrderSide.BUY:
            actual_price = fill_price + ts_val   # 1틱 불리
        else:
            actual_price = fill_price - ts_val

        return OrderResult(
            order_uuid=entry.order.order_uuid,
            broker_order_id=entry.book_id,
            status=OrderStatus.FILLED,
            filled_price=Price(Decimal(actual_price)),
            filled_quantity=entry.order.quantity,
            filled_at=self._current_time,
        )
```

---

## 5. MarketRules — 한국시장 제약

quant-spec §5에서 정의한 규칙을 `MarketRules` 클래스로 캡슐화:

```python
class MarketRules:
    """한국 유가증권시장 규칙 엔진"""

    def tick_size(self, price: int) -> int:
        # quant-spec §5.1 호가단위 테이블 그대로
        if price < 2_000:    return 1
        if price < 5_000:    return 5
        if price < 20_000:   return 10
        if price < 50_000:   return 50
        if price < 200_000:  return 100
        if price < 500_000:  return 500
        return 1_000

    def round_to_tick(self, price: float, side: OrderSide) -> int:
        # quant-spec §5.2

    def upper_limit(self, prev_close: int) -> int:
        return self.round_to_tick(prev_close * 1.3, OrderSide.SELL)

    def lower_limit(self, prev_close: int) -> int:
        return self.round_to_tick(prev_close * 0.7, OrderSide.BUY)

    def clamp_price(self, quote: Quote, state: SymbolState) -> Quote:
        clamped = max(state.lower_limit, min(state.upper_limit, int(quote.price)))
        return quote.model_copy(update={'price': Price(Decimal(clamped))})

    def is_trading_hours(self, ts: datetime) -> bool:
        t = ts.time()
        return time(9, 0) <= t < time(15, 20)

    def detect_vi(self, quote: Quote, state: SymbolState) -> bool:
        """정적 VI: 기준가 대비 ±10% 이상 변동"""
        change_pct = abs(float(quote.price) / float(state.prev_close) - 1.0)
        return change_pct >= 0.10

    def validate_order(self, order: OrderRequest, state: SymbolState) -> str | None:
        # 상하한가 위반
        if order.price and int(order.price) > state.upper_limit:
            return "PRICE_ABOVE_UPPER_LIMIT"
        if order.price and int(order.price) < state.lower_limit:
            return "PRICE_BELOW_LOWER_LIMIT"
        # VI 중 주문 거부
        if state.is_vi:
            return "VI_TRIGGERED"
        # 거래시간 외
        if not self.is_trading_hours(self._current_time):
            return "OUTSIDE_TRADING_HOURS"
        return None
```

---

## 6. SyntheticMarketAdapter — MarketDataPort 구현

```python
class SyntheticMarketAdapter(MarketDataPort):
    """가상거래소에서 시세를 스트리밍"""

    def __init__(self, engine: ExchangeEngine, clock: ClockPort):
        self._engine = engine
        self._clock = clock
        self._subscribed: list[Symbol] = []
        self._queue: asyncio.Queue[Quote] = asyncio.Queue()

    async def subscribe(self, symbols: list[Symbol]) -> None:
        self._subscribed = symbols
        self._engine.initialize(symbols, self._clock.now().date())

    async def unsubscribe(self, symbols: list[Symbol]) -> None:
        self._subscribed = [s for s in self._subscribed if s not in symbols]

    async def stream(self) -> AsyncIterator[Quote]:
        """HistoricalClockAdapter가 시간을 진행할 때마다 tick 생성"""
        async for ts in self._clock.tick_stream():  # 1분 간격 (백테스트 모드)
            quotes = self._engine.advance_to(ts)
            for q in quotes:
                if q.symbol in self._subscribed:
                    yield q

    async def get_current_price(self, symbol: Symbol) -> Quote:
        state = self._engine._state.get(symbol)
        if not state:
            raise DataError(f"Unknown symbol: {symbol}")
        return Quote(ts=self._clock.now(), symbol=symbol,
                     price=state.last_price, volume=Quantity(0),
                     source='synthetic')

    async def get_historical(self, symbol, start, end, interval) -> list[OHLCV]:
        """가상거래소는 과거 데이터 없음. 빈 리스트 반환."""
        return []
```

---

## 7. SyntheticBrokerAdapter — BrokerPort 구현

```python
class SyntheticBrokerAdapter(BrokerPort):
    """가상거래소에서 주문 체결"""

    def __init__(self, engine: ExchangeEngine, config: SyntheticExchangeConfig):
        self._engine = engine
        self._cash = Money(Decimal(config.initial_cash))
        self._positions: dict[Symbol, Quantity] = defaultdict(int)
        self._fills: dict[UUID, OrderResult] = {}

    async def submit(self, order: OrderRequest) -> OrderResult:
        # 멱등성
        if order.order_uuid in self._fills:
            return self._fills[order.order_uuid]

        # 잔고 체크 (매수 시)
        if order.side == OrderSide.BUY:
            cost = int(order.price) * int(order.quantity)
            if cost > int(self._cash):
                return OrderResult(order_uuid=order.order_uuid,
                    status=OrderStatus.REJECTED, message="INSUFFICIENT_CASH")

        result = self._engine.submit_order(order)

        # 체결 시 잔고/포지션 갱신
        if result.status == OrderStatus.FILLED:
            self._apply_fill(order, result)

        self._fills[order.order_uuid] = result
        return result

    async def cancel(self, order_uuid: UUID) -> OrderResult:
        return self._engine._order_book.cancel(order_uuid)

    async def get_order_status(self, order_uuid: UUID) -> OrderResult:
        if order_uuid in self._fills:
            return self._fills[order_uuid]
        raise DataError(f"Order not found: {order_uuid}")

    async def get_account_balance(self) -> Money:
        return self._cash

    def _apply_fill(self, order: OrderRequest, result: OrderResult):
        price = int(result.filled_price)
        qty = int(result.filled_quantity)
        fee = round(price * qty * 0.00015)  # 수수료

        if order.side == OrderSide.BUY:
            self._cash -= Money(Decimal(price * qty + fee))
            self._positions[order.symbol] += qty
        else:  # SELL
            tax = round(price * qty * (0.0018 + 0.0015))  # 거래세 + 농특세
            self._cash += Money(Decimal(price * qty - fee - tax))
            self._positions[order.symbol] -= qty
```

---

## 8. 이벤트 주입 (Scenario Injection)

가상거래소의 진짜 가치 — **엣지 케이스를 의도적으로 발생**시킬 수 있다.

```yaml
synthetic:
  scenarios:
    - type: "flash_crash"
      symbol: "005930"
      at_minute: 180          # 장 시작 후 180분 (12:00)
      magnitude: -0.08        # -8% 급락
      recovery_minutes: 15

    - type: "vi_trigger"
      symbol: "000660"
      at_minute: 60           # 10:00
      duration_seconds: 120

    - type: "upper_limit_hit"
      symbol: "373220"
      at_minute: 30           # 09:30
      # 가격을 +30% 상한가까지 끌어올림

    - type: "zero_volume"
      symbol: "207940"
      from_minute: 200
      to_minute: 220          # 20분간 거래 없음 → 빈 봉

    - type: "gap_up"
      symbol: "005380"
      day: 3                  # 시뮬 3일차
      gap_pct: 0.05           # 전일 종가 대비 +5% 갭 상승 시초가
```

```python
class ScenarioInjector:
    """시나리오 이벤트를 ExchangeEngine에 주입"""

    def __init__(self, scenarios: list[ScenarioConfig]):
        self._scenarios = scenarios
        self._triggered: set[int] = set()

    def apply(self, engine: ExchangeEngine, ts: datetime, day_index: int):
        minutes_from_open = (ts.hour - 9) * 60 + ts.minute
        for i, sc in enumerate(self._scenarios):
            if i in self._triggered: continue

            if sc.type == "flash_crash" and sc.at_minute == minutes_from_open:
                state = engine._state[Symbol(sc.symbol)]
                state.last_price = Price(Decimal(
                    int(float(state.last_price) * (1 + sc.magnitude))))
                self._triggered.add(i)

            elif sc.type == "vi_trigger" and sc.at_minute == minutes_from_open:
                state = engine._state[Symbol(sc.symbol)]
                state.is_vi = True
                state.vi_cooldown_until = ts + timedelta(seconds=sc.duration_seconds)
                self._triggered.add(i)

            # ... 기타 시나리오
```

---

## 9. 통계적 검증 — Monte Carlo

### 9.1 N회 시뮬레이션

```python
async def monte_carlo_backtest(
    strategy_name: str,
    n_runs: int = 1000,
    base_seed: int = 42,
) -> MonteCarloResult:
    sharpe_dist = []
    mdd_dist = []

    for i in range(n_runs):
        config = load_config()
        config.synthetic.seed = base_seed + i  # 시드만 변경

        result = await run_backtest(config)
        sharpe_dist.append(result.sharpe)
        mdd_dist.append(result.max_drawdown)

    return MonteCarloResult(
        n_runs=n_runs,
        sharpe_mean=np.mean(sharpe_dist),
        sharpe_median=np.median(sharpe_dist),
        sharpe_std=np.std(sharpe_dist),
        sharpe_p5=np.percentile(sharpe_dist, 5),
        sharpe_p95=np.percentile(sharpe_dist, 95),
        pct_above_1_0=sum(1 for s in sharpe_dist if s > 1.0) / n_runs,
        mdd_mean=np.mean(mdd_dist),
        mdd_p95=np.percentile(mdd_dist, 95),
    )
```

### 9.2 합격 기준 1번 강화안

quant-spec의 합격 기준 1번을 **두 단계로 분리**:

| 단계 | 조건 | 의미 |
|------|------|------|
| 1-A | SyntheticExchange 1,000회 → Sharpe 중앙값 > 0.8 | 전략 구조가 통계적으로 유효 |
| 1-B | CSVReplay 실제 데이터 → Sharpe > 1.0 | 실제 시장에서도 유효 |

1-A는 **데이터 없이 즉시 검증 가능**. 1-B는 데이터 축적 후 검증.

### 9.3 산출물

```json
// monte_carlo_result.json
{
  "strategy": "ma_crossover",
  "n_runs": 1000,
  "price_model": "gbm_realistic",
  "base_seed": 42,
  "sharpe": {
    "mean": 1.12,
    "median": 1.05,
    "std": 0.43,
    "p5": 0.38,
    "p95": 1.87,
    "pct_above_1_0": 0.58
  },
  "mdd": {
    "mean": 0.12,
    "p95": 0.22
  },
  "scenarios_injected": ["flash_crash", "vi_trigger", "zero_volume"],
  "acceptance_1a_passed": true
}
```

---

## 10. config.yaml 추가 스키마

```yaml
synthetic:
  seed: 42
  simulation_days: 504           # 2년 영업일
  initial_cash: 100000000        # 1억

  price_model:
    type: "gbm_realistic"        # gbm | gbm_realistic | regime_switching
    drift_annual: 0.08
    vol_annual: 0.25
    jump_intensity: 0.3          # 일 평균 점프 횟수 (Level 2)
    jump_std: 0.03               # 점프 크기 표준편차

  initial_prices:
    "005930": 72000
    "000660": 180000
    "373220": 380000
    "207940": 750000
    "005380": 210000

  market_rules:
    tick_size_table: "kospi"      # kospi | kosdaq
    limit_pct: 0.30
    vi_threshold_pct: 0.10
    vi_cooldown_seconds: 120
    trading_hours_start: "09:00"
    trading_hours_end: "15:20"

  scenarios: []                   # 이벤트 주입 (§8)

  monte_carlo:
    n_runs: 1000
    acceptance_sharpe_median: 0.8
```

---

## 11. graph_ir 변경 사항

```yaml
# MarketDataPort.adapters에 추가
MarketDataPort:
  adapters:
    primary: KISWebSocketAdapter
    fallback: KISRestAdapter
    mock: CSVReplayAdapter
    synthetic: SyntheticMarketAdapter    # 신규

# BrokerPort.adapters에 추가
BrokerPort:
  adapters:
    mock: MockBrokerAdapter
    kis_paper: KISPaperBrokerAdapter
    kis_live: KISLiveBrokerAdapter
    synthetic: SyntheticBrokerAdapter    # 신규

# Adapter 선택 규칙 추가
# | synthetic | synthetic | SyntheticBroker + SyntheticMarket + InMemory + HistoricalClock + StdoutAudit |

# expected_counts 변경
# adapters_primary: 6 → 8 (Synthetic 2개 추가)
```

---

## 12. 구현 순서

| Step | 내용 | 소요 |
|------|------|------|
| S1 | `ExchangeEngine` + `GBMPriceGenerator` (Level 1) | 0.5일 |
| S2 | `MarketRules` (quant-spec §5 코드화) | 0.5일 |
| S3 | `SyntheticMarketAdapter` (MarketDataPort 구현) | 0.5일 |
| S4 | `OrderBook` + `SyntheticBrokerAdapter` | 0.5일 |
| S5 | Level 2 보강 (점프확산, 호가스프레드, 장중변동성) | 0.5일 |
| S6 | `ScenarioInjector` (이벤트 주입) | 0.5일 |
| S7 | Monte Carlo 러너 + 산출물 | 0.5일 |
| S8 | 기존 Step 08(E2E) 연동 테스트 | 0.5일 |

**총 4일.** Walking Skeleton Step 03 이후, Step 08 이전에 끼워넣을 수 있다.

---

## 13. 미해결 / 검토 필요

| # | 항목 | 기본 가정 | 대안 |
|---|------|---------|------|
| X1 | GBM에서 MA cross가 수익을 내는가? | Level 2(점프확산)에서 추세 구간이 생겨 가능 | Monte Carlo로 실증 |
| X2 | Sharpe 중앙값 0.8 기준의 적정성 | 보수적 기준 (실 데이터 1.0보다 낮음) | 100회 pilot 후 조정 |
| X3 | HistoricalClockAdapter와의 연동 | tick_stream()이 1분 간격 emit | 기존 백테스트 시계 재사용 |
| X4 | 부분 체결 시뮬레이션 | Phase 1 전량 체결 | Phase 2에서 거래량 기반 |

---

## 14. 변경 이력

| 날짜 | 변경 |
|------|------|
| 2026-04-17 | 초안 작성. Level 1~3 모델, OrderBook, ScenarioInjector, Monte Carlo. |

---

*End of Document — synthetic-exchange-phase1.md*
*이 문서가 확정되면 실제 시세 데이터 없이도 Phase 1 E2E 검증이 가능해진다.*
