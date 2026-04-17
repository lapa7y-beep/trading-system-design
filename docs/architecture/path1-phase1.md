# Path 1 — Phase 1 Detailed Design

> **구현 여정**: Step 00(전체), 03(MarketData), 05(Strategy), 07(OrderExecutor), 08a/b(FSM)에서 참조. ADR-012 참조.
> **상태**: stable
> **버전**: Phase 1 — v1.0
> **선행 문서**: `docs/decisions/011-phase1-scope.md`
> **폐기**: 기존 `port_interface_path1_v2.0.md`, `node_blueprint_path1_v1.0.md`는 Phase 1 범위 밖 7개 노드를 포함. Phase 1에서는 본 문서가 우선한다.

---

## 1. Scope 재확인

Path 1 원래 설계는 13노드였으나, Phase 1에서는 **6노드로 축소**한다.

| Phase 1 포함 (6개) | Phase 2+ 연기 (7개) |
|---|---|
| MarketDataReceiver | Screener |
| IndicatorCalculator | WatchlistManager |
| StrategyEngine | SubscriptionRouter |
| RiskGuard | PositionMonitor |
| OrderExecutor | ExitConditionGuard |
| TradingFSM | ExitExecutor |
| | (예비 노드 1개) |

**종목 소스**: Screener 대신 `config/watchlist.yaml`에 수동 지정 3~5 종목.
**청산**: ExitExecutor 대신 전략 자체가 매도 Signal을 직접 생성.

---

## 2. 6노드 설계

### 2.1 MarketDataReceiver

**Role**: KIS WebSocket에서 실시간 시세 수신, 끊기면 REST polling으로 fallback.

| 속성 | 값 |
|------|----|
| runMode | `stream` (primary) + `poll` (fallback) |
| 입력 Port | MarketDataPort (subscribe/unsubscribe) |
| 출력 Edge | `quote_stream` → IndicatorCalculator (DataFlow) |
| 상태 | WebSocket 연결 상태 (CONNECTED/RECONNECTING/FALLBACK_POLL) |
| 수집 종목 | `config/watchlist.yaml`의 3~5개 고정 |
| Fallback 조건 | WebSocket 3회 연속 재연결 실패 시 10초 poll 모드 |

**Adapter**:
- Primary: `KISWebSocketAdapter` — `H0STCNT0` (주식 체결), `H0STASP0` (호가)
- Fallback: `KISRestAdapter.get_current_price()`
- Mock: `CSVReplayAdapter` — 과거 OHLCV를 시간 순으로 재생

---

### 2.2 IndicatorCalculator

**Role**: 수신된 시세를 종목별 버퍼에 쌓고, 전략이 요청한 지표를 pandas-ta로 계산.

| 속성 | 값 |
|------|----|
| runMode | `event` (시세 도착 시 계산) |
| 입력 Edge | `quote_stream` ← MarketDataReceiver |
| 출력 Edge | `indicator_bundle` → StrategyEngine |
| 내부 상태 | 종목별 Ring Buffer (최근 200봉) |
| 계산 지표 | 전략 선언에 따라 동적 — Phase 1 지원: SMA, EMA, RSI, MACD, Bollinger, ATR |

**핵심**:
- 지표 계산은 deterministic (같은 입력 → 같은 출력)
- 백테스트 시 ClockPort의 시간에 맞춰 계산, 실시간이면 wall clock

---

### 2.3 StrategyEngine

**Role**: 지표와 포지션을 보고 매수/매도/홀드 Signal을 생성.

| 속성 | 값 |
|------|----|
| runMode | `event` (지표 번들 도착 시 evaluate) |
| 입력 Edge | `indicator_bundle` ← IndicatorCalculator, `position_snapshot` ← (PortfolioStore 조회) |
| 출력 Edge | `signal_output` → RiskGuard |
| 전략 로드 | `strategies/*.py` 파일을 StrategyLoader가 import |
| 전략 수 | Phase 1은 **동시 1개만 활성** |
| Hot Reload | 없음 (재시작 필요) |

**전략 파일 인터페이스**:
```python
from core.domain import IndicatorBundle, PositionSnapshot, SignalOutput

class BaseStrategy:
    name: str
    version: str
    symbols: list[str]

    def evaluate(
        self,
        indicators: IndicatorBundle,
        position: PositionSnapshot,
    ) -> SignalOutput:
        ...
```

**Phase 1 제공 전략**:
- `strategies/ma_crossover.py` — 5일/20일 이동평균 교차
- `strategies/rsi_reversion.py` — RSI < 30 매수, RSI > 70 매도

**LLM 없음**. MarketContext 없음. Regime Detector 없음.

---

### 2.4 RiskGuard (Phase 1 축소판)

**Role**: StrategyEngine이 만든 Signal을 실제 주문으로 변환하기 전 **Pre-Order 7항목 체크**.

| 체크 # | 항목 | 기준 | 차단 시 |
|---|---|---|---|
| 1 | 자본금 충분성 | 주문가 × 수량 ≤ 가용 현금 × 95% | 경고 + 차단 |
| 2 | 종목당 최대 비중 | 단일 종목 ≤ 총자본의 20% | 경고 + 차단 |
| 3 | 일일 최대 손실 | 오늘 누적 손실 ≥ 총자본 2% | 신규 진입 차단 (청산은 허용) |
| 4 | 일일 거래 횟수 | 1일 체결 40회 초과 | 차단 |
| 5 | 거래 시간대 | 09:00~15:20 외 | 차단 |
| 6 | 장 상태 | VI/CB 발동 중 | 차단 |
| 7 | Circuit Breaker (시스템) | OrderExecutor가 최근 5분간 3회 실패 | 차단 + SafeMode 전환 |

**Phase 2로 연기**: 섹터 집중도, 상관관계 체크, 레버리지 비율, 시장 체제 감지, VaR 계산 — 총 12항목 중 5개 연기.

**결정 출력**:
```python
class RiskDecision(BaseModel):
    approved: bool
    reason: str | None
    modified_signal: SignalOutput | None  # 수량 조정된 경우
```

---

### 2.5 OrderExecutor

**Role**: 승인된 Signal을 실제 브로커 주문으로 전환, 체결까지 추적.

| 속성 | 값 |
|------|----|
| runMode | `stateful-service` |
| 입력 Edge | `approved_signal` ← RiskGuard |
| 출력 Edge | `execution_event` → TradingFSM, AuditLogger |
| Port | BrokerPort (주문/취소/조회) |
| OrderTracker | 메모리 dict + `order_tracker` 테이블 이중화 |
| 체결 통보 | KIS `H0STCNI0` WebSocket 구독 |

**Idempotency**:
- 각 주문에 `order_uuid` 생성 (Phase 1도 필수 — Four Critical Safeguards)
- 동일 `order_uuid`로 재요청 시 기존 결과 반환

**Order 유형** (Phase 1):
- 지정가 매수 (`limit_buy`)
- 지정가 매도 (`limit_sell`)
- 시장가 매수 (`market_buy`)
- 시장가 매도 (`market_sell`)

**Phase 2로 연기**: 정정주문, IOC/FOK, 조건부주문, 분할주문, 예약주문 — 총 24 주문유형 중 20개 연기.

**Circuit Breaker**:
- 최근 60초 내 3회 연속 브로커 오류 시 OrderExecutor 차단
- TradingFSM에 `BROKER_FAILURE` 이벤트 발송 → SafeMode 전환

---

### 2.6 TradingFSM

**Role**: Path 1 전체의 생명주기 상태를 관리. transitions 라이브러리 사용.

**6개 상태**:

| 상태 | 의미 | 가능한 전이 |
|------|------|------------|
| `IDLE` | 신호 대기 | → `ENTRY_PENDING` |
| `ENTRY_PENDING` | 매수 주문 대기 | → `IN_POSITION`, `IDLE`(취소), `ERROR` |
| `IN_POSITION` | 포지션 보유 | → `EXIT_PENDING` |
| `EXIT_PENDING` | 매도 주문 대기 | → `IDLE`(청산완료), `IN_POSITION`(취소), `ERROR` |
| `ERROR` | 복구 가능한 오류 | → `IDLE`(복구), `SAFE_MODE` |
| `SAFE_MODE` | 신규 주문 차단 | → `IDLE` (관리자 resume 시) |

**중요**: Phase 1은 **종목당 1개 FSM 인스턴스**. 종목군(Tier) FSM, 실행군 FSM은 Phase 2.

**영속화**: 상태 전이마다 `audit_events` + `positions` 테이블에 기록. crash 후 재시작 시 DB에서 복원.

---

## 3. Path 1 Phase 1 엣지 (14개)

```
MarketDataPort ──[quote_stream]──> IndicatorCalculator
IndicatorCalculator ──[indicator_bundle]──> StrategyEngine
PortfolioStore ──[position_snapshot]──> StrategyEngine (ConfigRef)
StrategyEngine ──[signal_output]──> RiskGuard
RiskGuard ──[approved_signal]──> OrderExecutor
RiskGuard ──[rejection_event]──> AuditLogger (AuditTrace)
OrderExecutor ──[order_request]──> BrokerPort
BrokerPort ──[order_result]──> OrderExecutor
OrderExecutor ──[execution_event]──> TradingFSM
OrderExecutor ──[execution_event]──> AuditLogger (AuditTrace)
TradingFSM ──[state_transition]──> PortfolioStore
TradingFSM ──[state_transition]──> AuditLogger (AuditTrace)
```

**Cross-Path 엣지 없음**. Shared Store는 PortfolioStore 1개만.

---

## 4. Shared Stores (3개)

| Store | 테이블 | 역할 |
|-------|--------|------|
| MarketDataStore | `market_ohlcv` | OHLCV 영속화 |
| PortfolioStore | `positions`, `trades`, `daily_pnl` | 포지션·체결·손익 |
| AuditStore | `audit_events`, `order_tracker` | 감사·주문 추적 |

**ConfigStore 없음** — `config/*.yaml` 파일로 대체.
**KnowledgeStore, StrategyStore, EventBus 등 5개 연기**.

---

## 5. Pre-Order Check 상세 (RiskGuard 7항목 구현 메모)

```python
# core/nodes/risk_guard.py (골격)
class RiskGuard:
    def evaluate(self, signal: SignalOutput, snapshot: PortfolioSnapshot) -> RiskDecision:
        # Check 1: 자본금
        required = signal.price * signal.quantity
        if required > snapshot.cash * 0.95:
            return RiskDecision(approved=False, reason="insufficient_cash")

        # Check 2: 종목 집중도
        new_exposure = (snapshot.exposure_of(signal.symbol) + required) / snapshot.total_equity
        if new_exposure > 0.20:
            return RiskDecision(approved=False, reason="concentration_limit")

        # Check 3: 일일 손실
        if snapshot.daily_pnl / snapshot.total_equity <= -0.02 and signal.is_entry:
            return RiskDecision(approved=False, reason="daily_loss_limit")

        # Check 4: 거래 횟수
        if snapshot.today_trade_count >= 40:
            return RiskDecision(approved=False, reason="trade_count_limit")

        # Check 5: 거래 시간
        now = self.clock.now_kst()
        if not (time(9,0) <= now.time() <= time(15,20)):
            return RiskDecision(approved=False, reason="outside_trading_hours")

        # Check 6: 장 상태
        if self.market_state.is_vi_triggered(signal.symbol):
            return RiskDecision(approved=False, reason="vi_triggered")

        # Check 7: Circuit Breaker
        if self.circuit_breaker.is_tripped():
            return RiskDecision(approved=False, reason="circuit_breaker_open")

        return RiskDecision(approved=True)
```

---

## 6. 합격 증명 시나리오

Phase 1 합격 기준 5개를 Path 1이 실제로 충족하는 시나리오:

### 기준 1: 샤프 > 1.0
- `strategies/ma_crossover.py` 로드
- `CSVReplayAdapter`로 2024-01-01 ~ 2025-12-31 OHLCV 주입
- `MockBrokerAdapter`로 체결 시뮬레이션
- 일별 return 계산 → 샤프 비율 산출

### 기준 2: 5거래일 무사고
- `broker: kis_paper`로 전환
- `atlas start` → 5거래일 관찰
- `audit_events` WHERE severity >= 'error' 조회 → 0건

### 기준 3: 일일 손익 자동 기록
- 15:30 장 마감 Hook에서 `daily_pnl` 집계
- `positions` → `trades` JOIN → MTM 계산
- 5거래일 × 1행 = 5행 자동 생성

### 기준 4: halt 30초 차단
- `atlas start` 실행 중
- `atlas halt` 실행
- SIGUSR1 → TradingFSM 전체 SAFE_MODE 전이
- 이후 `approved_signal`이 와도 OrderExecutor가 차단
- halt 시각 vs 마지막 주문 체결 시각 diff 측정

### 기준 5: Crash 복원
- `atlas start` 상태에서 `kill -9 <pid>`
- 재시작 시 부트 시퀀스가 `positions` 테이블 조회
- 각 종목별 TradingFSM을 `IN_POSITION`으로 초기화
- 미체결 주문이 있으면 `order_tracker`에서 복원

---

## 7. Phase 2 진입 시 확장 포인트

Phase 2에서 Path 1을 확장할 때 **이 설계를 깨지 않고 끼워넣을 수 있는 지점**:

| 확장 | 끼우는 위치 | 방법 |
|------|-----------|------|
| Screener 도입 | MarketDataReceiver 앞 | `watchlist.yaml`을 Screener가 주기적으로 재생성 |
| ExitConditionGuard 분리 | StrategyEngine과 병렬 | 청산 전용 Signal Stream 추가 |
| MarketContext 주입 | StrategyEngine 입력 | Path 6가 MarketContext 발행, `evaluate()`에 추가 |
| Portfolio 체크 강화 | RiskGuard 체크 7→12 | Path 4가 PortfolioStore 확장 후 체크 추가 |

**핵심**: Phase 1의 엣지 계약(Edge Contract)을 유지하는 한, 위 확장은 기존 코드 변경 없이 가능.

---

*End of Document — Path 1 Phase 1 Design*
