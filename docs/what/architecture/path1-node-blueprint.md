# Phase 1 6노드 내부 상세 (L3 Blueprint)

> **목적**: 6개 노드 각각의 내부 로직, 설정 키, 에러 핸들링, 테스트 시나리오를 L3 수준으로 기술한다.
> **층**: What
> **상태**: stable
> **선행 문서**: `docs/what/architecture/path1-design.md` (노드 개요), `graph_ir_phase1.yaml` (SSoT)

## 1. MarketDataReceiver

### 1.1 내부 흐름

```
startup:
  1. config/watchlist.yaml에서 symbols 로드 (3~5개)
  2. KISWebSocketAdapter.connect()
  3. 구독 시작 → H0STCNT0 (체결가)
  4. connection_state = CONNECTED

tick_loop:
  1. WS 메시지 수신 → Quote 파싱
  2. 이상값 필터 (전일 종가 대비 ±31% → warn 로그, 전달은 함)
  3. IndicatorCalculator로 emit (edge: quote_stream)
  4. MarketDataStore에 fire-and-forget 저장

fallback:
  WS 끊김 3회 연속 → connection_state = FALLBACK_POLL
  → KISRestAdapter.get_current_price() 10초 주기
  → WS 복구 시도 30초마다
  → 복구 성공 → connection_state = CONNECTED
```

### 1.2 설정 키 (`config/config.yaml`)

```yaml
market_data:
  ws_reconnect_max: 3
  ws_reconnect_interval_seconds: 5
  poll_interval_seconds: 10
  poll_reconnect_check_seconds: 30
  price_deviation_warn_pct: 31
  stale_tick_warn_seconds: 3
```

### 1.3 에러 매트릭스

| 에러 | 감지 | 행동 | audit severity |
|------|------|------|---------------|
| WS 끊김 | heartbeat 미수신 5초 | 재연결 시도 | warn |
| WS 재연결 3회 실패 | 카운터 | FALLBACK_POLL 전환 | error |
| REST 폴링 실패 | HTTP 에러/타임아웃 | 지수 백오프 재시도 | error |
| 이상 시세 (±31%) | 전일 종가 대비 | 경고 로그, 전달은 함 | warn |
| 틱 3초 미수신 | 타이머 | stale 경고 | warn |

### 1.4 테스트 시나리오

- [ ] CSVReplayAdapter로 200봉 정상 수신 확인
- [ ] WS 강제 끊김 → FALLBACK_POLL 전환 확인
- [ ] 이상값(+35%) 틱 → warn 로그 + 정상 전달 확인

---

## 2. IndicatorCalculator

### 2.1 내부 흐름

```
on_quote(quote):
  1. symbol별 ring_buffer[symbol].append(quote)
  2. buffer 길이 < warmup_bars → 계산 가능한 지표만
  3. pandas-ta로 지표 계산:
     - SMA(5, 20), EMA(12, 26), RSI(14)
     - MACD(12, 26, 9), Bollinger(20, 2), ATR(14)
  4. IndicatorBundle 생성 → StrategyEngine emit
```

### 2.2 설정 키

```yaml
indicators:
  buffer_size: 200
  warmup_bars: 60            # 이 수 미만이면 null 지표 포함
  sma_periods: [5, 20]
  ema_periods: [12, 26]
  rsi_period: 14
  macd: { fast: 12, slow: 26, signal: 9 }
  bbands: { period: 20, std: 2 }
  atr_period: 14
```

### 2.3 에러 매트릭스

| 에러 | 감지 | 행동 | audit severity |
|------|------|------|---------------|
| pandas-ta 계산 오류 | try/except | 해당 지표 null, 나머지 정상 전달 | warn |
| buffer 부족 (< warmup) | len 체크 | 계산 가능한 것만, 나머지 null | info |
| 메모리 초과 (buffer 누적) | ring buffer 구현 | 자동 trim (FIFO) | — |

### 2.4 테스트 시나리오

- [ ] 200봉 입력 후 SMA(5,20) 값 검증 (수동 계산 대조)
- [ ] 50봉만 입력 → RSI null, SMA(5) 정상 확인
- [ ] 동일 입력 → 동일 출력 (deterministic) 확인

---

## 3. StrategyEngine

### 3.1 내부 흐름

```
startup:
  1. strategies/ 디렉토리 스캔
  2. BaseStrategy 상속 클래스 import
  3. 첫 번째 전략 활성화 (Phase 1: 동시 1개)

on_indicator_bundle(bundle):
  1. PortfolioStore에서 해당 symbol position 조회
  2. PositionSnapshot 구성
  3. strategy.evaluate(bundle, snapshot) 호출
  4. 결과가 buy/sell → SignalOutput 생성 → RiskGuard emit
  5. 결과가 hold → 무시 (로그 없음)
  6. signal_cooldown 체크: 동일 종목 마지막 signal로부터 N초 미경과 → 억제
```

### 3.2 설정 키

```yaml
strategy:
  directory: "strategies/"
  active_count: 1
  signal_cooldown_seconds: 60
  hot_reload: false
```

### 3.3 전략 파일 규약

```python
# strategies/ma_crossover.py
from core.domain import IndicatorBundle, PositionSnapshot, SignalOutput

class MACrossoverStrategy:
    name = "ma_crossover"
    version = "1.0"

    def evaluate(self, indicators: IndicatorBundle,
                 position: PositionSnapshot) -> SignalOutput | None:
        sma5 = indicators.indicators.get("sma_5")
        sma20 = indicators.indicators.get("sma_20")
        if sma5 is None or sma20 is None:
            return None
        # ... 판단 로직
```

### 3.4 에러 매트릭스

| 에러 | 감지 | 행동 | audit severity |
|------|------|------|---------------|
| 전략 파일 import 실패 | ImportError | 시스템 시작 중단 | critical |
| evaluate() 예외 | try/except | 해당 틱 무시, 다음 틱에 재시도 | error |
| evaluate() 50ms 초과 | asyncio.timeout | 해당 틱 폐기 | warn |
| PortfolioStore 조회 실패 | DB 에러 | 빈 snapshot으로 진행 (신규 진입만 가능) | warn |

### 3.5 테스트 시나리오

- [ ] ma_crossover: golden cross 발생 시 BUY signal 생성
- [ ] ma_crossover: dead cross 발생 시 SELL signal 생성
- [ ] cooldown 60초 내 중복 signal 억제 확인
- [ ] 전략 파일 문법 오류 → 시작 시 에러 메시지 확인

---

## 4. RiskGuard

### 4.1 내부 흐름

```
on_signal(signal):
  snapshot = PortfolioStore.get_snapshot()

  for check in [check_1..check_7]:
      result = check(signal, snapshot)
      if not result.passed:
          audit_log(rejection_event)
          return  # 차단

  # 전부 통과
  emit approved_signal → OrderExecutor
```

### 4.2 7체크 상세 구현 메모

| # | 이름 | 로직 | 차단 조건 |
|---|------|------|----------|
| 1 | insufficient_cash | `signal.price × signal.quantity > snapshot.cash × 0.95` | 초과 시 |
| 2 | concentration_limit | `(기존 노출 + 신규) / total_equity > 0.20` | 초과 시 |
| 3 | daily_loss_limit | `snapshot.daily_pnl / total_equity ≤ -0.02` AND `signal.is_entry` | 진입만 차단 |
| 4 | trade_count_limit | `snapshot.today_trade_count ≥ 40` | 초과 시 |
| 5 | outside_trading_hours | `not (09:00 ≤ now_kst ≤ 15:20)` | 범위 밖 |
| 6 | vi_triggered | `market_state.is_vi(symbol)` | VI 중 |
| 7 | circuit_breaker_open | `OrderExecutor 최근 60초 3회 실패` | 트립 시 |

### 4.3 설정 키

```yaml
risk:
  max_cash_usage_ratio: 0.95
  max_single_position_pct: 20
  max_daily_loss_pct: 2
  max_daily_trades: 40
  trading_hours_start: "09:00"
  trading_hours_end: "15:20"
  circuit_breaker_window_seconds: 60
  circuit_breaker_max_failures: 3
```

### 4.4 테스트 시나리오

- [ ] 현금 부족 → 차단 + audit warn
- [ ] 20% 비중 초과 → 차단
- [ ] 일일 손실 -2% 도달 → 신규 진입만 차단, 청산은 통과
- [ ] 40회 거래 초과 → 차단
- [ ] 09:00 이전 signal → 차단
- [ ] 7개 모두 통과 → approved_signal 발행

---

## 5. OrderExecutor

> **ADR-013 변경**: 이전 OrderExecutor는 "요청 + 체결 수신 + 기록" 3역할 복합이었다.
> 이제 **요청만** 담당. 체결 통보 수신은 ExecutionReceiver(§5b)가 전담.

### 5.1 내부 흐름 (축소)

```
on_approved_signal(signal):
  1. OrderRequest 생성 (order_uuid = UUID4)
  2. order_tracker 테이블 INSERT (status=submitted)
  3. OrderPort.submit(order_request)
  4. 응답 수신 (ACK만, 체결 아님):
     - 성공 → broker_order_id 기록, status=accepted
            → TradingFSM에 order_ack event emit (PENDING 상태 전이용)
     - 실패 → status=rejected, last_error 기록
     - 타임아웃 5초 → status=failed, Circuit Breaker 카운터++
  5. audit_events에 기록

※ 체결 통보(FILLED)는 OrderExecutor가 받지 않는다. ExecutionReceiver가 받는다.

circuit_breaker:
  60초 내 3회 연속 실패 → tripped = True
  → 이후 approved_signal 수신 시 즉시 거부
  → TradingFSM에 BROKER_FAILURE event → SAFE_MODE 전이
  → 30초 후 half-open (1건 테스트)
  → 성공 → tripped = False
```

### 5.2 설정 키

```yaml
order_executor:
  submit_timeout_seconds: 5
  circuit_breaker:
    window_seconds: 60
    max_failures: 3
    recovery_seconds: 30
  idempotency_check: true
```

### 5.3 에러 매트릭스

| 에러 | 감지 | 행동 | audit severity |
|------|------|------|---------------|
| API 타임아웃 | asyncio.timeout | status=failed, CB 카운터++ | error |
| 인증 만료 (EGW00123) | 응답 코드 | 토큰 갱신 → 1회 재시도 | warn |
| Rate limit (EGW00201) | 응답 코드 | 1초 대기 → 재시도 | warn |
| 자금 부족 (APBK0919) | 응답 코드 | status=rejected | warn |
| 호가단위 불일치 (APBK0634) | 응답 코드 | 가격 보정 → 재시도 | warn |
| CB tripped | 내부 플래그 | 신규 주문 즉시 거부 | critical |

### 5.4 Idempotency

- `order_uuid`가 PK → 동일 UUID 재전송 시 INSERT 실패 → 기존 결과 반환
- 네트워크 장애로 응답 미수신 시 재전송해도 중복 주문 방지

### 5.5 테스트 시나리오

- [ ] MockOrder로 limit_buy 제출 → order_tracker status=accepted 확인
- [ ] MockOrder 3회 연속 실패 → CB trip → SAFE_MODE 전이
- [ ] 동일 order_uuid 재전송 → 중복 INSERT 없음 확인
- [ ] 타임아웃 5초 → status=failed 확인
- [ ] ExecutionReceiver 단독 테스트 시 OrderExecutor는 호출되지 않아야 함

---

## 5b. ExecutionReceiver (ADR-013 신설)

### 5b.1 역할

체결 통보 push 구독 전용. `ExecutionEventPort`로부터 이벤트 수신 → trades 기록 →
PortfolioStore 갱신 → TradingFSM에 execution_event emit.

### 5b.2 내부 흐름

```
startup:
  1. ExecutionEventPort.subscribe(self.on_execution_event)
  2. 구독 시작, 백그라운드 수신 루프 진입 (Adapter 내부)

on_execution_event(event):   # Adapter가 호출
  1. 멱등성 체크: execution_uuid 이미 처리된 경우 무시 (audit 기록)
  2. TradeRecord 생성:
       symbol, side, qty, price, fee, tax, exec_time
  3. trades 테이블 INSERT
  4. PortfolioStore 갱신:
       cash += (side == SELL) ? (price*qty - fee - tax) : -(price*qty + fee)
       positions[symbol].qty += (side == BUY) ? qty : -qty
       positions[symbol].avg_price 재계산
  5. daily_pnl 누적 업데이트 (PortfolioStore 내부 테이블)
  6. TradingFSM.emit("execution_event", event) → 상태 전이 트리거
       ENTRY_PENDING + fill → IN_POSITION
       EXIT_PENDING + fill → IDLE
  7. audit_events INSERT (severity=info)

shutdown:
  1. ExecutionEventPort.unsubscribe()
  2. 진행 중 핸들러 완료 대기
```

### 5b.3 설정 키

```yaml
execution_event:
  mode: "mock"          # mock | synthetic | paper | live
  reconnect_max_seconds: 60
  dedup_cache_size: 1000
  crash_replay: true    # 부팅 시 최근 5분 이벤트 재생 여부
```

### 5b.4 에러 매트릭스

| 에러 | 감지 | 행동 | audit severity |
|------|------|------|---------------|
| WebSocket 끊김 | 핑 타임아웃 10초 | 재연결 (지수 백오프 1→60초) | warn |
| 인증 실패 | 접속 401 | AuthError raise → SAFE_MODE | critical |
| 메시지 파싱 실패 | JSON 예외 | 해당 메시지 폐기, 다음 진행 | warn |
| 중복 execution_uuid | LRU 캐시 히트 | 무시 (audit만 기록) | info |
| PortfolioStore 갱신 실패 | DB 오류 | 재시도 3회, 계속 실패 시 SAFE_MODE | critical |
| TradingFSM 상태 전이 실패 | 잘못된 전이 | ERROR 상태 전이 | error |

### 5b.5 Crash Replay

부팅 시 `crash_replay: true`면:
- AuditStore에서 최근 5분의 execution_event 조회
- 각 event의 execution_uuid가 trades 테이블에 없으면 재처리
- 있으면 멱등성으로 스킵

### 5b.6 테스트 시나리오

- [ ] MockExecutionEvent 1회 emit → trades 1행 + positions 갱신 확인
- [ ] 동일 execution_uuid 2회 emit → trades 1행만 (중복 제거 확인)
- [ ] WebSocket 강제 끊기 → 자동 재연결 후 이벤트 수신 재개
- [ ] ExecutionReceiver가 처리 중 OrderExecutor가 새 주문 제출 → 둘 다 독립 동작
- [ ] Crash 직전 5개 이벤트 → 재부팅 후 replay → trades 5행 복원

---

## 6. TradingFSM

### 6.1 내부 흐름

```
6 States × 12 Transitions (transitions 라이브러리)

입력 경로 (ADR-013 이후):
  - OrderExecutor → order_ack event (주문 접수/거부, PENDING 전이용)
  - ExecutionReceiver → execution_event (체결, 완료 전이용)
  - cli_halt → halt_signal (SAFE_MODE 강제)

startup:
  1. positions 테이블 조회 → 미청산 포지션 복원
  2. 각 symbol별 FSM 인스턴스 생성
  3. 복원된 포지션 → IN_POSITION 상태로 초기화
  4. order_tracker WHERE status IN ('submitted','accepted') → 미체결 확인
  5. AccountPort.get_balance/get_positions() 호출 → 증권사 기준 PortfolioStore 덮어쓰기

on_order_ack(ack):    # OrderExecutor로부터
  - IDLE + accepted(buy)  → ENTRY_PENDING
  - IDLE + accepted(sell) → EXIT_PENDING
  - any  + rejected       → ERROR 또는 IDLE (재시도 정책)

on_execution_event(event):    # ExecutionReceiver로부터 (ADR-013)
  - ENTRY_PENDING + fill → IN_POSITION
  - EXIT_PENDING  + fill → IDLE (포지션 해소)
  - any + broker_error   → ERROR
  - ERROR + recovery     → IDLE
  - ERROR + unrecoverable → SAFE_MODE

on_halt_signal():
  현재 상태 무관 → SAFE_MODE 전이
  SAFE_MODE에서는 entry_signal 무시

on_resume():
  SAFE_MODE → IDLE (관리자 명시적 resume만)

모든 전이:
  1. positions 테이블 UPDATE (fsm_state 컬럼)
  2. audit_events INSERT (event_type=fsm_transition)
```

### 6.2 설정 키

```yaml
fsm:
  persist_on_every_transition: true
  crash_recovery_on_boot: true
```

### 6.3 에러 매트릭스

| 에러 | 감지 | 행동 | audit severity |
|------|------|------|---------------|
| 잘못된 전이 시도 | transitions MachineError | 무시 + 로그 | warn |
| positions UPDATE 실패 | DB 에러 | 재시도 3회, 실패 시 ERROR 전이 | critical |
| 복원 시 불일치 | boot 시 positions vs broker | 경고 로그 + 상태 강제 갱신 | error |

### 6.4 Crash Recovery 상세

```
boot_recovery():
  1. positions WHERE fsm_state NOT IN ('IDLE') 조회
  2. 각 포지션에 대해:
     a. order_tracker에서 미완료 주문 확인
     b. OrderPort.get_order_status(uuid) 로 미체결 주문 상태 대조
     c. AccountPort.reconcile() 로 내부 DB ↔ 브로커 잔고/포지션 일관성 검증
     d. 불일치 → 경고 + 브로커 기준으로 상태 강제 갱신
     e. 정상 → 기존 상태로 FSM 복원
  3. audit_events에 recovery 결과 기록
```

### 6.5 테스트 시나리오

- [ ] IDLE → entry_signal → ENTRY_PENDING 확인
- [ ] ENTRY_PENDING → fill → IN_POSITION + positions 테이블 확인
- [ ] IN_POSITION → exit_signal → EXIT_PENDING → fill → IDLE
- [ ] halt → SAFE_MODE → 이후 entry_signal 무시 확인
- [ ] resume → IDLE 복귀 확인
- [ ] kill -9 → 재시작 → positions 테이블에서 IN_POSITION 복원 확인
- [ ] 잘못된 전이 (IDLE → fill) → MachineError 로그 + 상태 유지

---

## 7. 노드 간 의존 관계 요약

```
MarketDataReceiver ←── MarketDataPort (DataFlow)
    ↓ quote_stream (DataFlow)
IndicatorCalculator
    ↓ indicator_bundle (DataFlow)
StrategyEngine ←── PortfolioStore (ConfigRef)
    ↓ signal_output (DataFlow)
RiskGuard ←── PortfolioStore (ConfigRef)
              AccountPort (잔고/포지션 조회)
    ↓ approved_signal (DataFlow)
    ↓ rejection_event → AuditStore (AuditTrace)
OrderExecutor ──→ OrderPort (주문 제출/취소/조회)
    ↓ execution_event (Event)
    ↓ order_audit → AuditStore (AuditTrace)
TradingFSM ←── cli_halt (Command)
              AccountPort (crash recovery 시 reconcile)
    ↓ state_transition → PortfolioStore (DataPipe)
    ↓ fsm_audit → AuditStore (AuditTrace)
```

> **Port 분리 원칙**: OrderExecutor는 주문 실행만 담당하므로 OrderPort만 사용.
> RiskGuard와 TradingFSM은 계좌 정보가 필요하므로 AccountPort 사용.
> 단일 책임 원칙으로 결합도 최소화.

---

*End of Document — Path 1 Phase 1 Blueprint*
*6 Nodes | 각 노드별 내부 흐름, 설정 키, 에러 매트릭스, 테스트 시나리오*
