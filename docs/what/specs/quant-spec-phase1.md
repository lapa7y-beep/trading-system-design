# quant-spec-phase1 — Phase 1 퀀트 명세

> **상태**: draft (2026-04-17 작성, 최초 검토 대상)
> **위치**: `docs/what/specs/quant-spec-phase1.md`
> **목적**: Phase 1의 **퀀트 도메인 로직**을 수식 수준으로 확정한다. 아키텍처 문서(graph_ir, path1-phase1, blueprint)는 시스템 구조를 정의하지만 전략/체결/백테스트의 숫자는 정의하지 않는다. 본 문서가 그 공백을 메운다.
> **선행 문서**: `graph_ir_phase1.yaml` (SSoT), `docs/what/architecture/path1-node-blueprint.md`, `docs/what/specs/domain-types-phase1.md`
> **이 문서가 없으면**: Walking Skeleton의 stub을 실제 구현으로 교체할 때 개발자가 즉흥 판단을 하게 되고, Phase 1 합격 기준 1번(Sharpe > 1.0)이 p-hacking으로 조작 가능하다.

---

## 0. 이 문서의 존재 이유

설계 문서 전수 점검 결과 발견된 공백:

| 공백 | 위치 | 영향 |
|------|------|------|
| 진입/청산 수식 비어있음 | blueprint §3.3 `# ... 판단 로직` | Strategy 구현 불가 |
| 수량 산정 주체 불분명 | SignalOutput.quantity 결정자 미정 | 책임 경계 충돌 |
| 종목 유니버스 미정 | watchlist "3~5개" 예시조차 없음 | 백테스트 재현 불가 |
| Bar 주기 미명시 | tick(H0STCNT0)을 어떻게 봉으로? | IndicatorCalculator 동작 불명 |
| 한국시장 규칙 공백 | 호가단위/VI/동시호가/상하한가 | 모의투자에서 주문 거부 연발 예상 |
| MockOrder 체결 로직 미정의 | 수수료/세금/슬리피지 숫자 없음 | 백테스트 결과 신뢰 불가 |
| Sharpe 계산 규칙 미정 | 연율화/RFR/NaN 처리 | 합격 기준 1번 조작 가능 |
| "무사고" 정량 정의 미흡 | 경제적 성과 기준 없음 | 합격 기준 2번 조작 가능 |

본 문서는 이 공백 8개 + 엣지 케이스 10여 개를 모두 메운다.

---

## 1. Bar / Tick 정의

### 1.1 원천 데이터

* **실시간**: KIS WebSocket `H0STCNT0` (주식 체결가). Tick 단위.
* **과거**: KIS REST `inquire-daily-itemchartprice` (일봉), `inquire-time-itemchartprice` (분봉).
* **백테스트**: 과거 CSV/Parquet (`data/ohlcv/<symbol>_<timeframe>.parquet`).

### 1.2 Phase 1 Bar 주기 확정

**1분봉(1m)**으로 고정한다.

이유:
1. Tick 그대로 쓰면 false signal 과다. MA cross 전략은 최소 1분봉이 현실적.
2. 일봉은 하루 1개 신호 → 백테스트 표본 부족.
3. 5분/10분은 Phase 2 A/B 테스트 대상.

### 1.3 Bar 집계 규칙 (Tick → 1m OHLCV)

```
Tick: (symbol, timestamp_ms, price, volume)

집계 키:
  bar_start_time = floor(timestamp_ms, 1min)
  symbol 별 현재 진행 중인 bar = (bar_start_time, O, H, L, C, V, tick_count)

Tick 도착 시:
  if tick.bar_start_time != current_bar.bar_start_time:
      emit current_bar  (closed bar, downstream으로 전달)
      current_bar = new Bar(bar_start_time=tick.bar_start_time,
                             O=tick.price, H=tick.price, L=tick.price,
                             C=tick.price, V=tick.volume, tick_count=1)
  else:
      current_bar.H = max(current_bar.H, tick.price)
      current_bar.L = min(current_bar.L, tick.price)
      current_bar.C = tick.price
      current_bar.V += tick.volume
      current_bar.tick_count += 1
```

**핵심 규칙**: `emit`은 *다음* tick이 도착해서 bar boundary를 넘을 때 일어난다. 즉 **봉 종가는 확정 후에만 하류로 전달**된다. Look-ahead bias 원천 차단.

### 1.4 빈 봉(거래 없는 1분) 처리

* **실시간**: 해당 1분 동안 tick 0 → bar emit 안 함. 다음 tick 도착 시 점프한 구간의 bar는 *생략*(forward-fill 금지).
* **백테스트/지표 계산**: 연속성 필요 시 직전 close로 forward-fill하되, volume=0으로 표기하여 Strategy가 식별 가능하게 한다.

### 1.5 Bar 필드 (최종)

```python
class Bar(BaseModel):
    symbol: Symbol
    bar_start: datetime      # KST tz-aware
    timeframe: Literal["1m"]
    open: Price
    high: Price
    low: Price
    close: Price
    volume: int              # 주수 (거래대금 아님)
    tick_count: int          # 집계된 tick 수 (데이터 품질 지표)
    is_synthetic: bool = False  # forward-fill된 가짜 봉이면 True
```

### 1.6 데이터 품질 게이트

Bar가 Indicator로 넘어가기 전 다음 조건 중 하나라도 위반 → `is_bad=True` 태그 후 **Strategy 건너뜀**:

| # | 조건 | 사유 |
|---|------|------|
| Q1 | `open <= 0 or high <= 0 or low <= 0 or close <= 0` | 음수/0 가격 |
| Q2 | `not (low <= open <= high and low <= close <= high)` | OHLC 정합성 위반 |
| Q3 | `volume < 0` | 음수 거래량 |
| Q4 | `abs(close - prev_close) / prev_close > 0.31` | 상하한가 30% + 여유. 순간 튀는 오데이터 |
| Q5 | `tick_count == 0 and not is_synthetic` | 실시간 빈봉인데 synthetic이 아니라는 모순 |

**Q4 주의**: 정상 상한가/하한가는 30.0%가 **이하**다. 31%를 초과하면 데이터 오류로 본다. 경계값(정확히 30.0%)은 정상 허용.

---

## 2. 종목 유니버스 (Watchlist)

### 2.1 Phase 1 고정 watchlist

`config/watchlist.yaml`:

```yaml
# Phase 1 fixed watchlist (2026-04 기준)
# 선정 기준: 시총 상위 + 유동성 상위 + 섹터 분산 + VI 희소
version: "1.0"
symbols:
  - { code: "005930", name: "삼성전자",       sector: "반도체" }
  - { code: "000660", name: "SK하이닉스",     sector: "반도체" }
  - { code: "373220", name: "LG에너지솔루션", sector: "2차전지" }
  - { code: "207940", name: "삼성바이오로직스", sector: "바이오" }
  - { code: "005380", name: "현대차",         sector: "자동차" }
```

### 2.2 선정 기준 (기록용)

1. **시총 상위 10위 내**: 유동성 확보, 호가 공백 최소.
2. **일평균 거래대금 500억 원 이상**: 체결 실패 최소화.
3. **섹터 분산**: 동일 섹터 중복 2개 이내 (반도체만 예외적으로 2개 허용 — 시장 대표성).
4. **VI 발동 이력**: 최근 60일간 5회 이하. (상한 초과 종목은 제외)
5. **관리종목·투자주의·투자경고 제외**: `get_stock_info()`로 확인, 해당 시 제외.

### 2.3 Watchlist 변경 정책

* Phase 1 기간 중 **변경 금지**. 변경 시 백테스트 재실행 + 합격기준 재검증.
* Phase 2에서 `WatchlistManager` 자동화 노드 도입.

---

## 3. MACrossoverStrategy 완전한 수식

### 3.1 기본 파라미터 (고정)

```yaml
strategy:
  active: "ma_crossover"
  params:
    fast: 5        # 단기 이동평균 기간
    slow: 20       # 장기 이동평균 기간
    warmup_bars: 25   # slow + 5 여유
  # Phase 1은 파라미터 튜닝 금지 (고정 값으로 합격 기준 1 검증)
```

### 3.2 지표 요구사항

매 bar close 시점에 다음 두 값을 **직전 25봉**으로 계산:

```
SMA_fast[t] = mean(close[t-4 .. t])        # 5개 close 평균
SMA_slow[t] = mean(close[t-19 .. t])       # 20개 close 평균
```

`pandas-ta`의 `sma` 함수를 사용하되, `min_periods=period` 강제 (`None` 허용 안 함).

### 3.3 진입 조건 (Golden Cross)

**정확한 정의**: 직전 봉에서 fast ≤ slow였고, 현재 봉에서 fast > slow로 전환된 순간.

```python
def is_golden_cross(t: int, sma_fast: Series, sma_slow: Series) -> bool:
    if t < 1: return False
    if sma_fast[t] is None or sma_slow[t] is None: return False
    if sma_fast[t-1] is None or sma_slow[t-1] is None: return False
    return (sma_fast[t-1] <= sma_slow[t-1]) and (sma_fast[t] > sma_slow[t])
```

**경계 주의**:
- 이전 봉에서 `sma_fast == sma_slow`(완전 일치)인 경우도 "이전에는 위가 아니었다"로 간주 → 다음 봉에서 `>` 되면 golden cross.
- `sma_fast[t-1] < sma_slow[t-1]`만 체크하면 완전 일치 다음 봉의 크로스를 놓친다. 반드시 `<=` 사용.

### 3.4 청산 조건 (Dead Cross + 손절 + 시간제한)

다음 **세 조건 중 하나라도** 만족하면 청산:

```python
# 1) Dead cross: golden과 대칭
def is_dead_cross(t, sma_fast, sma_slow):
    if sma_fast[t-1] is None or sma_slow[t-1] is None: return False
    return (sma_fast[t-1] >= sma_slow[t-1]) and (sma_fast[t] < sma_slow[t])

# 2) 고정 손절 (-2.5%)
def is_stop_loss(current_price, entry_price):
    return (current_price / entry_price - 1.0) <= -0.025

# 3) 시간 기반 강제 청산 (장 마감 10분 전)
def is_eod_exit(now_kst):
    return now_kst.time() >= time(15, 10)
```

**익절(take profit)은 Phase 1에서 사용하지 않는다** — MA cross의 수익 구간을 잘라버리기 때문. Trailing stop은 Phase 2 검토 대상.

### 3.5 엔트리/엑싯 가격

* **지정가만 사용**. 시장가 금지 (슬리피지 예측 불가).
* **진입 가격**: 봉 close 직후, 다음 tick의 **현재가(cur_price)** 그대로.
  - 호가단위 보정 후 제출.
  - 예: cur_price = 72,340 원, 호가단위 100원 → 72,300 원 (하향 보정, 매수)
* **청산 가격**: 동일 규칙. 매도 시 호가단위 **상향** 보정 (빨리 체결되도록).

**주의**: 이 전략은 체결 확률을 약간 낮추는 대신 슬리피지 통제를 선택한 것. 미체결 시 §3.7 정책 적용.

### 3.6 신호 쿨다운

동일 종목에 대해 **같은 방향(BUY/SELL) 신호는 60초 내 재발행 금지** (graph_ir `signal_cooldown_seconds: 60` 유지).

단, 반대 방향은 즉시 허용 (BUY 후 60초 내 SELL 가능 — 급락 시 손절 필요).

### 3.7 미체결 재주문 정책

* 주문 제출 후 **10초간 미체결** → 자동 취소.
* 취소 직후 동일 방향으로 **1회 재시도** (가격은 현재 호가로 갱신).
* 재시도도 실패 → 해당 bar 신호 폐기. 다음 크로스까지 대기.

### 3.8 재진입 금지 (Re-entry Guard)

청산 완료 후 **동일 종목 동일 방향 진입은 5분 대기**. 데드크로스 후 즉시 골든크로스(노이즈성 반전) 방지.

---

## 4. 수량 산정 (PositionSizer)

### 4.1 책임 귀속 결정

**Strategy가 결정**한다.

- Strategy는 "얼마만큼 진입할지"가 전략 로직의 일부다. Kelly/ATR/Fixed Fractional은 전략의 특성.
- RiskGuard는 그 값을 **검증**만 한다 (concentration_limit 초과 시 reject, 축소 금지).
- 즉 **Strategy가 over-size로 제안 → RiskGuard reject**가 정상 흐름.

### 4.2 Phase 1 산정 알고리즘: **Fixed Notional**

```python
def calculate_quantity(current_price: Price, cash: Money) -> Quantity:
    target_notional = min(
        cash * 0.15,          # 가용현금의 15%
        5_000_000             # 최대 500만원
    )
    quantity = target_notional // current_price  # 소수점 버림
    return max(1, quantity) if quantity >= 1 else 0
```

**설계 의도**:
- Phase 1은 **동시 1종목 보유 전제**. 500만원 캡이면 KOSPI 초대형주(삼성전자 7만원대) 기준 ~70주.
- 15% 규칙은 cash 소진 방지. 5종목 분산 시에도 여유 확보.
- `quantity = 0`이면 해당 신호 폐기.

### 4.3 SignalOutput에 포함

domain-types-phase1.md에 이미 정의된 `SignalOutput`을 SSoT로 사용한다.
Strategy가 생성하는 SignalOutput의 필드 매핑:

```python
# domain-types-phase1.md SSoT (변경 금지)
class SignalOutput(BaseModel):
    model_config = ConfigDict(frozen=True)

    ts: datetime                   # ← quant-spec에서 generated_at에 해당
    symbol: Symbol
    side: OrderSide
    price: Price                   # 호가단위 보정 전 희망가
    quantity: Quantity             # Strategy가 §4.2로 산정한 수량
    is_entry: bool                 # True=신규 진입, False=청산
    strategy_name: str             # "ma_crossover"
    strategy_version: str          # "1.0"
    confidence: float = 1.0        # Phase 1은 항상 1.0
    rationale: str = ''            # reason_code를 여기에 기록 ("golden_cross" 등)
    # --- Phase 1 추가 제안 (domain-types 반영 필요) ---
    # correlation_id: CorrelationId  # 신호-주문-체결 추적용 (§10 참조)
```

**rationale 필드로 reason_code 역할을 수행**한다 (예: `rationale="golden_cross|sma5=72400>sma20=71800"`).
`correlation_id`는 domain-types에 추가 제안 (§10 참조).

### 4.4 청산 수량

청산 신호는 **보유 수량 전량**. 부분 청산 없음 (Phase 1).

---

## 5. 한국시장 규칙

### 5.1 호가단위 테이블 (KRX 2023-01-25 개정 기준)

```python
def tick_size(price: int) -> int:
    """한국 유가증권시장(코스피) 호가단위"""
    if price < 2_000:      return 1
    if price < 5_000:      return 5
    if price < 20_000:     return 10
    if price < 50_000:     return 50
    if price < 200_000:    return 100
    if price < 500_000:    return 500
    return 1_000
```

코스닥은 20만원 이상 500원, 50만원 이상 1,000원 (사실상 동일하나 KIS 응답 확인 필요).

### 5.2 호가단위 보정

```python
def round_to_tick(price: float, side: OrderSide) -> int:
    ts = tick_size(int(price))
    if side == OrderSide.BUY:
        return (int(price) // ts) * ts         # 하향 (싸게 사기)
    else:
        return ((int(price) + ts - 1) // ts) * ts  # 상향 (비싸게 팔기)
```

### 5.3 상하한가

* **KOSPI/KOSDAQ 공통 ±30%** (전일 종가 대비).
* 계산: `upper_limit = round_to_tick(prev_close * 1.3, SELL)`, `lower_limit = round_to_tick(prev_close * 0.7, BUY)`.
* 주문가가 상하한가를 벗어나면 KIS가 거부(`APBK0632` 또는 유사). RiskGuard 체크에 추가:

```yaml
pre_order_checks:
  - id: 8  # 신규 추가
    name: "price_limit_violation"
    block: true
    logic: "price < lower_limit or price > upper_limit"
```

**graph_ir 변경 필요** — checks 7개 → 8개로 증가 (검토 대상).

### 5.4 거래시간 세부

| 구간 | 시간 (KST) | Phase 1 정책 |
|------|------------|-------------|
| 장 시작 동시호가 | 08:30~09:00 | **주문 금지** (체결가 예측 곤란) |
| 정규장 | 09:00~15:20 | 신호 허용 |
| 장 마감 동시호가 | 15:20~15:30 | 신규 진입 금지. 청산은 §3.4(3) EoD 이미 15:10에 처리 완료 |
| 시간외 종가 | 15:40~16:00 | 주문 금지 |
| 시간외 단일가 | 16:00~18:00 | 주문 금지 |

Blueprint의 `trading_hours_start: "09:00"`, `trading_hours_end: "15:20"` 유효. EoD 청산 규칙은 §3.4(3)과 일치.

**휴장일**: KIS API의 `get_trading_calendar()` 또는 `is_trading_day()` 응답 신뢰. 주말 + 법정공휴일 + 임시휴장.

### 5.5 VI (변동성 완화장치) 감지

KIS WebSocket 실시간 체결 메시지 `H0STCNT0`에 VI 플래그 없음. 다음 방법 사용:

1. **가격 기반 휴리스틱**: 최근 10분간 ±10% 이상 급등락 → VI 발동 추정.
2. **REST 조회**: `get_vi_status(symbol)` 5초 주기 폴링 (해당 API 명세는 `kis-api-notes.md`에서 확인 필요).
3. Phase 1에서는 1+2 OR 조건 사용. Phase 2에서 WebSocket `H0STCNI9` 채널(시세관리) 통합 검토.

VI 감지 시:
- 해당 종목 **2분간 모든 신호 폐기**.
- 기 보유 포지션은 §3.4 청산 조건만 유지 (강제 청산 없음).

### 5.6 동시호가 (추가 보호)

08:30~09:00 및 15:20~15:30에 **수신되는 tick은 bar 집계에서 제외**. 이 구간의 체결가는 단일가로 결정되어 연속 시계열에 왜곡 주입.

---

## 6. 체결 모델

### 6.1 KIS 수수료·세금 (2026년 기준, 모의투자 및 백테스트 동일 적용)

#### 6.1.1 수수료 (KIS "유관기관 수수료 포함" 일반)

| 채널 | 수수료율 | 비고 |
|------|---------|------|
| HTS/MTS | 0.015% | 기본 |
| API | 0.015% | Phase 1 기준 |

매수/매도 양방향 부과. 최소 수수료 없음(소액 거래 시에도 정률).

#### 6.1.2 세금 (매도 시만)

| 구분 | 세율 | 비고 |
|------|------|------|
| 증권거래세 | 0.18% | 2024년부터 유가증권시장 기준 (변동 가능, 매년 검증 필요) |
| 농어촌특별세 | 0.15% | 유가증권시장만. 코스닥은 거래세 0.18%로 통합되어 농특세 없음 |

**중요**: 세율은 정부 정책에 따라 변경된다. `config/market_rules.yaml`로 분리해 매년 점검.

```yaml
# config/market_rules.yaml
fees:
  commission_rate: 0.00015   # 0.015%
taxes:
  transaction_tax_kospi: 0.0018      # 0.18%
  special_tax_kospi: 0.0015          # 0.15%
  transaction_tax_kosdaq: 0.0018     # 0.18% (농특세 없음)
reference_date: "2026-01-01"
verified_source: "KRX 공시 URL (매년 갱신)"
```

#### 6.1.3 체결 금액 계산

```python
def gross_buy(price: int, qty: int) -> int:
    # 매수: 원금 + 수수료
    principal = price * qty
    commission = round(principal * 0.00015)
    return principal + commission

def gross_sell(price: int, qty: int, market: str) -> int:
    # 매도: 원금 - 수수료 - 세금
    principal = price * qty
    commission = round(principal * 0.00015)
    if market == "KOSPI":
        tax = round(principal * (0.0018 + 0.0015))
    else:  # KOSDAQ
        tax = round(principal * 0.0018)
    return principal - commission - tax

def realized_pnl(entry_price, exit_price, qty, market) -> int:
    cost = gross_buy(entry_price, qty)
    proceeds = gross_sell(exit_price, qty, market)
    return proceeds - cost
```

### 6.2 MockOrder 체결 로직

#### 6.2.1 기본 원칙

* **다음 봉 시가 체결(Next Bar Open)** — backtesting.md 이벤트 엔진과 통일.
  - 시점 t에 신호 발생 → 시점 t+1의 시가(open)로 체결.
  - 같은 봉에서 신호 발생 + 체결은 look-ahead bias이므로 **금지**.
* **즉시 전량 체결** 가정 (Phase 1). 부분 체결 시뮬레이션은 Phase 2.
* **슬리피지 모델**: 다음 봉 시가 대비 1틱 불리하게 체결.

```python
def mock_fill_price(next_bar_open: int, side: OrderSide) -> int:
    ts = tick_size(next_bar_open)
    if side == OrderSide.BUY:
        return next_bar_open + ts      # 1틱 비싸게 체결
    else:
        return next_bar_open - ts      # 1틱 싸게 체결
```

#### 6.2.2 체결 지연

* Mock: 0 ms (즉시).
* KIS Paper: 실제 API 응답 시간 (~100~500 ms 관찰됨).
* **TradingFSM의 `ENTRY_PENDING` 타임아웃은 5초** — Paper에서도 충분.

#### 6.2.3 MockOrder 내부 상태

```python
class MockOrderState:
    cash: int                    # 초기: config.mock_initial_cash (기본 1억)
    positions: dict[Symbol, int] # {symbol: qty}
    order_history: list[OrderResult]
```

백테스트 시작 시 `cash = config.backtest.initial_capital` (기본 10,000,000 원 = 1천만).

### 6.3 KIS Paper (모의투자) 체결 특성

* 실제 시장가로 체결됨 (슬리피지는 실제 발생, MockOrder의 1틱 가정보다 불리할 수도 유리할 수도 있음).
* 수수료·세금은 실제 KIS와 동일하게 부과 (모의투자에서도).
* **단점**: 휴장일 이후 계좌 리셋 가능성 (KIS 정책). 5거래일 연속 테스트 시 중간에 리셋되면 합격기준 2 재검증 필요.

---

## 7. 백테스트 명세

### 7.1 재현성 조건 (Determinism)

백테스트는 **동일 입력 → 동일 출력** 보장. 다음을 고정:

```yaml
backtest:
  # 데이터
  universe: "config/watchlist.yaml"     # §2.1 고정 5종목
  period_start: "2024-01-02"
  period_end:   "2025-12-30"
  data_source: "data/ohlcv/*.parquet"   # 사전 다운로드, SHA256 기록
  data_hash_file: "data/ohlcv/MANIFEST.sha256"
  
  # 초기 상태
  initial_capital: 100_000_000  # 1억 (config-schema 기준, 모의투자 동일)
  # 백테스트 전용 축소 자본 사용 시 별도 override 가능:
  # initial_capital_override: 10_000_000  # 백테스트 전략 검증용 1천만
  starting_positions: []        # 무포지션 시작
  
  # 난수 (Phase 1은 난수 미사용, Phase 2 대비 고정)
  random_seed: 42
  
  # 전략
  strategy: "ma_crossover"
  strategy_params:
    fast: 5
    slow: 20
    warmup_bars: 25
  
  # 체결 모델
  slippage_ticks: 1
  commission_rate: 0.00015
  transaction_tax_kospi: 0.0018
  special_tax_kospi: 0.0015
  transaction_tax_kosdaq: 0.0018
  
  # 시계열 규칙
  bar_timeframe: "1m"
  bar_close_only: true          # 봉 종가 후에만 신호 판단 (look-ahead 방지)
  weekend_skip: true
  holiday_calendar: "KRX"
```

### 7.2 Look-ahead Bias 방지 규칙

실행 엔진은 다음을 **강제**한다:

1. **시점 t의 신호는 close[0..t]만 사용** 가능. `close[t+1]` 참조 시 에러.
2. **주문 제출은 시점 t**, **체결은 시점 t+1의 open**으로 처리. "같은 봉 체결" 금지.
3. 지표 계산은 `min_periods` 강제. warmup 이전 봉에서는 신호 발행 자체 금지.

### 7.3 Sharpe Ratio 계산

```python
def sharpe_ratio(daily_returns: list[float], rf_annual: float = 0.0) -> float:
    """
    daily_returns: 영업일 기준 일별 수익률 (포지션 보유 여부 무관, 매일 1개)
    rf_annual: 무위험수익률 연율 (Phase 1은 0으로 고정)
    """
    if len(daily_returns) < 30:
        return float('nan')  # 30영업일 미만 → 계산 거부
    
    rf_daily = rf_annual / 252
    excess = [r - rf_daily for r in daily_returns]
    mean = statistics.mean(excess)
    stdev = statistics.stdev(excess)
    if stdev == 0:
        return float('nan')
    return (mean / stdev) * sqrt(252)
```

**규칙 고정**:
- 연율화 계수 **252** (영업일 기준).
- Risk-free rate **0%** (Phase 1 단순화).
- 무포지션 날도 수익률 0으로 포함 (포지션 있는 날만 계산 금지 — 샤프 과대평가).
- 30영업일 미만 NaN 반환 → 합격 기준 불충족 처리.

### 7.4 합격 기준 1번 재정의

**원문 (graph_ir)**: "백테스트 샤프 > 1.0"

**운영 정의 (본 문서)**:

```
다음 조건 전부 충족 시 합격 기준 1 통과:

a) 데이터: §2.1 watchlist 5종목 × 2024-01-02 ~ 2025-12-30 × 1m bar
b) 파라미터: fast=5, slow=20 (고정, 튜닝 금지)
c) 체결 모델: §6.1, §6.2 (수수료·세금·슬리피지 반영)
d) Sharpe 계산: §7.3 규칙
e) 결과: 포트폴리오 일별 수익률 기준 Sharpe > 1.0
f) 부가: 최대낙폭(MDD) < 25%, 총 거래 수 > 50회 (표본 충분성)
g) 산출물: result.json에 위 모든 수치와 random_seed, data_hash 기록
```

**부가 조건 f**는 p-hacking 방지: 거래가 5회뿐인데 샤프가 높은 경우는 무효.

### 7.5 백테스트 산출물

```json
// result.json
{
  "backtest_id": "uuid",
  "run_at": "2026-05-01T12:34:56+09:00",
  "git_sha": "a1b2c3d",
  "config_hash": "sha256:...",
  "data_hash": "sha256:...",
  "period": {"start": "2024-01-02", "end": "2025-12-30"},
  "universe": ["005930", "000660", "373220", "207940", "005380"],
  "strategy": {"name": "ma_crossover", "params": {"fast": 5, "slow": 20}},
  "metrics": {
    "sharpe": 1.23,
    "total_return_pct": 18.7,
    "max_drawdown_pct": 12.4,
    "trade_count": 87,
    "win_rate": 0.52,
    "avg_win_pct": 2.1,
    "avg_loss_pct": -1.4
  },
  "acceptance_1_passed": true,
  "trades": ["..."],
  "daily_equity": ["..."]
}
```

---

## 8. 합격 기준 "무사고" 정량 정의 (Acceptance Criterion 2 보강)

**원문**: "모의투자 5거래일 무사고"
**원문 검증 SQL**: `SELECT COUNT(*) FROM audit_events WHERE severity IN ('error','critical') → 0`

**보강 — 다음 전부 충족해야 "무사고"**:

| # | 조건 | SQL/검증 |
|---|------|---------|
| S1 | audit_events severity error/critical 0건 | 기존 |
| S2 | TradingFSM이 ERROR 또는 SAFE_MODE에 진입한 적 없음 | `fsm_audit`에서 해당 전이 0건 |
| S3 | Circuit Breaker trip 0회 | `audit_events.event_type = 'circuit_breaker_tripped'` 0건 |
| S4 | 주문 거부(broker) 전체 거래 수 대비 10% 이하 | `rejected / total ≤ 0.10` |
| S5 | 체결-FSM 상태 불일치 0건 | crash recovery 시 `broker vs positions` diff = 0 |
| S6 | 일일 실현 손실 총합 < 초기 자본의 10% | `SUM(daily_pnl.realized) > -0.10 * initial_capital` |

**S6 추가 이유**: 단순 "에러 없음"은 경제적 실패를 허용. 5일간 -10% 이상 손실은 전략 검토 트리거로 간주, 합격 불가.

---

## 9. config.yaml 추가 스키마

본 문서에서 도입된 설정 키를 config.yaml에 통합:

```yaml
# ---- 본 문서로 신규/확장 ----

market_data:
  bar_timeframe: "1m"
  skip_opening_auction: true      # 08:30~09:00
  skip_closing_auction: true      # 15:20~15:30

strategy:
  active: "ma_crossover"
  params:
    fast: 5
    slow: 20
    warmup_bars: 25
  signal_cooldown_seconds: 60
  reentry_cooldown_seconds: 300   # 신규: §3.8

position_sizing:
  algorithm: "fixed_notional"
  cash_usage_pct: 0.15
  max_notional_krw: 5_000_000

exit_rules:
  enable_ma_cross_exit: true
  enable_stop_loss: true
  stop_loss_pct: -0.025
  enable_eod_exit: true
  eod_exit_time: "15:10"

order_execution:
  price_mode: "limit"             # market 금지
  tick_round_buy: "floor"
  tick_round_sell: "ceil"
  unfill_timeout_seconds: 10      # §3.7
  unfill_retry_count: 1

vi_detection:
  enabled: true
  price_heuristic_window_min: 10
  price_heuristic_threshold_pct: 10
  poll_interval_seconds: 5
  cooldown_after_vi_seconds: 120

backtest:
  initial_capital: 10_000_000
  slippage_ticks: 1
  period_start: "2024-01-02"
  period_end: "2025-12-30"
  random_seed: 42
  data_dir: "data/ohlcv"
  data_hash_file: "data/ohlcv/MANIFEST.sha256"
  acceptance:
    min_sharpe: 1.0
    max_drawdown_pct: 25
    min_trades: 50

# 외부 파일로 분리
market_rules_file: "config/market_rules.yaml"  # §6.1.2
```

---

## 10. 도메인 타입 보완 (domain-types-phase1.md 반영 필요)

domain-types-phase1.md가 SSoT이므로 quant-spec은 이를 변경하지 않는다.
다만 다음 **1개 필드 추가**를 domain-types 검토 항목으로 제안한다:

| 타입 | 추가 필드 | 이유 |
|------|----------|------|
| `SignalOutput` | `correlation_id: CorrelationId` | 신호→주문→체결 전 과정 추적. audit 필수 |

기존 `rationale` 필드로 `reason_code` 역할을 수행하므로 별도 필드 불필요.
기존 `is_entry` 필드로 `intent` 역할을 수행하므로 별도 필드 불필요.
기존 `price` 필드로 `price_suggested` 역할을 수행하므로 별도 필드 불필요.

`Bar` 타입은 §1.5에서 정의했으나, domain-types의 `OHLCV`와 대응한다.
Phase 1에서는 OHLCV 타입에 `tick_count: int`와 `is_synthetic: bool` 필드 추가를 제안한다.

---

## 11. 아키텍처 영향

### 11.1 graph_ir 변경 필요 여부

| 항목 | 변경 | 이유 |
|------|------|------|
| Node 6개 | **변경 없음** | 6노드 그대로 |
| Edge 14개 | **변경 없음** | 흐름 구조 그대로 |
| Port 6개 | **변경 없음** | 시그니처 유지 |
| pre_order_checks | **7→8개 검토** | §5.3 price_limit_violation 추가 여부 |
| domain_types | **SignalOutput 필드 5개 추가** | §4.3 |
| config schema | **대폭 추가** | §9 |

### 11.2 Scaffold/Walking Skeleton 영향

Step 0 (pass-through)은 영향 없음. Step 2 "Strategy를 실제 구현으로 교체" 시점부터 본 문서가 **직접 코드로 번역된다**.

```
Step 2 구현 시:
  strategies/ma_crossover.py
    ← §3.3 진입, §3.4 청산, §4.2 수량 산정 정확히 옮김
  
Step 4 RiskGuard 구현 시:
  §5.3 price_limit 체크 포함 여부 결정
  
Step 5 MockOrder + MockAccount 구현 시:
  §6.2 체결 로직 정확히 구현
  
Step 8 E2E 백테스트:
  §7 전체 적용, result.json에 §7.5 필드 전부
```

---

## 12. 미해결/검토 필요 항목 (Known Unknowns)

본 문서 작성 중 **확정하지 못한 것들** — 구현 착수 전 결정 필요:

| # | 항목 | 기본 가정 | 대안 |
|---|------|---------|------|
| K1 | KIS Paper의 수수료 부과 정확성 | 실제 KIS와 동일 | 실측 테스트 필요 |
| K2 | VI API(`get_vi_status`) 존재 여부 | `kis-api-notes.md`에 명세 있을 것 | 없으면 §5.5 휴리스틱만 |
| K3 | 과거 1m bar 데이터 확보 경로 | KIS `inquire-time-itemchartprice` | 100일 제한 있을 경우 타사 데이터 |
| K4 | 모의투자 야간/주말 계좌 리셋 | 5일 연속 유지 가능 | KIS 고객센터 문의 |
| K5 | KOSPI200 편입/편출 중 watchlist 종목 | 무관 (Phase 1 고정) | Phase 2에서 자동 재편입 |
| K6 | 배당락·유상증자 등 권리락 | Phase 1 무시 | 해당 날짜 거래 skip 룰 추가 검토 |

**K3은 특히 중요**. 2년치 1m bar(영업일 ~500일 × 5종목 × 400봉/일 = 100만 레코드)를 어디서 어떻게 확보하는가가 백테스트 가능성을 좌우한다.

---

## 13. 변경 이력

| 날짜 | 변경 |
|------|------|
| 2026-04-17 | 초안 작성. Blueprint + graph_ir 공백 분석 기반. |

---

*End of Document — quant-spec-phase1.md*
*본 문서가 확정되면 `strategies/ma_crossover.py`의 첫 줄부터 마지막 줄까지 코드가 유일하게 결정된다.*
