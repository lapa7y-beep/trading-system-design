# Edge Contract Definition — All Paths

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | edge_contract_definition_v1.0 |
| 선행 문서 | port_interface_path1~5_v1.0, graph_ir_agent_extension_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |

---

## 0. Trading Safety Contract (최우선)

> **이 시스템은 실제 돈이 오가는 트레이딩 시스템이다.**
> Edge Contract의 1차 목적은 데이터 전달이 아니라 **자본 보호**다.
> 아래 Safety Contract는 모든 Edge 정의보다 우선한다.

### 0.1 주문 흐름 E2E Latency Budget

시세 수신부터 주문 제출까지의 전체 Edge 체인에 대한 시간 예산. 개별 Edge timeout의 합이 아니라 **체인 전체의 hard ceiling**.

```
MarketDataReceiver → IndicatorCalculator → StrategyEngine → RiskGuard
    → DedupGuard → [Path4 RiskBudget] → OrderExecutor → KIS API
    
총 E2E budget: 500ms (지정가) / 200ms (시장가)
```

| 구간 | Budget | 초과 시 |
|------|--------|---------|
| 시세 수신 → 지표 계산 | 50ms | 해당 틱 drop |
| 지표 → 전략 판단 | 30ms | 해당 틱 drop |
| 전략 → 리스크 검증 (Path 1 + Path 4) | 100ms | 주문 보류 (다음 틱에 재평가) |
| 리스크 → 주문 제출 | 50ms | 주문 보류 |
| KIS API 응답 대기 | 270ms (지정가) / 70ms (시장가) | Circuit Breaker |
| **총합** | **500ms / 200ms** | |

**규칙: E2E 시작 시점의 timestamp가 Edge 체인을 따라 전파되어야 한다.** 중간 어디서든 현재 시각 - 시작 시각 > budget이면 해당 주문은 즉시 폐기.

```yaml
# 모든 주문 흐름 payload에 필수 포함
trading_context:
  chain_started_at: datetime    # E2E 시작 시각
  price_observed_at: datetime   # 시세 관측 시각
  e2e_budget_ms: int            # 500 or 200
  chain_id: str                 # 전체 체인 추적 ID (correlation_id)
```

### 0.2 Stale Price Guard (시세 신선도)

전략이 판단에 사용하는 시세가 오래된 데이터일 수 있다. Edge 수준에서 강제.

| 규칙 | 임계값 | 위반 시 |
|------|--------|---------|
| Quote age | price_observed_at으로부터 3초 초과 | 해당 Quote 기반 주문 전체 폐기 |
| OHLCV age | 마지막 봉 완성 후 60초 초과 | 지표 재계산 대기 |
| 호가 스프레드 | ask - bid > 종가의 2% | 시장가 주문 차단, 지정가만 허용 |

```yaml
# E-P1-01 ~ E-P1-03에 적용되는 추가 contract
stale_guard:
  max_quote_age_ms: 3000
  max_ohlcv_delay_ms: 60000
  max_spread_pct: 2.0
  violation_action: drop_and_log
```

### 0.3 Partial Fill & 미체결 처리

실전에서 주문은 한 번에 체결되지 않는다. OrderResult edge(E-P1-06)의 확장.

```
주문 100주 제출
  → 30주 체결 (PARTIALLY_FILLED) → TradingFSM 상태: InPosition(30)
  → 50주 추가 체결 (PARTIALLY_FILLED) → TradingFSM 상태: InPosition(80)
  → 잔량 20주 미체결 상태 유지
  → 장 마감 or 타임아웃 → 미체결 20주 자동 취소 → TradingFSM에 CancelEvent
```

```yaml
# E-P1-06 확장: 동일 order_id에 대해 복수 OrderResult 발생 가능
partial_fill_contract:
  multi_event: true             # 1 order → N개 OrderResult
  aggregation: by_order_id      # order_id 기준 집계
  terminal_states: [FILLED, CANCELLED, REJECTED]
  unfilled_timeout_minutes: 5   # 5분 미체결 시 자동 취소 시도
  unfilled_at_close: cancel     # 장 마감 시 미체결 처리: cancel | hold
```

### 0.4 장 시간대별 Edge 동작 (Market Phase Rules)

| 장 상태 | 주문 Edge (E-P1-03~05) | 시세 Edge (E-P1-01) | 리밸런싱 Edge (E-P4-05) |
|---------|----------------------|---------------------|----------------------|
| PRE_MARKET | 차단 | 수신 (폴링) | 차단 |
| OPEN | 정상 | 수신 (WebSocket) | 비활성 |
| CLOSING (마감 동시호가) | 신규 차단, 기존만 허용 | 수신 | 차단 |
| CLOSED | 전면 차단 | 차단 | 실행 가능 |
| HOLIDAY | 전면 차단 | 차단 | 차단 |

**마감 임박 규칙:**

```yaml
market_close_rules:
  new_order_cutoff_minutes: 3   # 마감 3분 전 신규 주문 Edge 차단
  exit_only_minutes: 10         # 마감 10분 전 매수 차단, 매도만 허용
  force_close_minutes: 1        # 마감 1분 전 미체결 전량 취소
```

### 0.5 Circuit Breaker — Edge 차단 규칙

개별 Edge가 아니라 **Edge 그룹 단위**로 Circuit Breaker 작동. 장애가 전파되지 않도록.

```yaml
circuit_breaker:
  # 주문 실행 회로 (E-P1-05: DedupGuard → OrderExecutor)
  order_execution:
    failure_threshold: 3         # 연속 3회 실패
    recovery_timeout_seconds: 30 # 30초 후 half-open
    half_open_max_orders: 1      # 복구 확인용 1건만 허용
    on_open:                     # 회로 열림 시 행동
      - halt_new_orders: true
      - protect_existing_positions: true   # 기존 포지션 손절선 유지
      - alert: CRITICAL
      - log_to_audit: true

  # 시세 수신 회로 (E-P1-01)
  market_data:
    failure_threshold: 5
    recovery_timeout_seconds: 10
    on_open:
      - switch_adapter: KISRestPollingAdapter  # WebSocket → REST fallback
      - alert: HIGH

  # KIS API 전체 회로
  kis_api:
    failure_threshold: 10
    recovery_timeout_seconds: 60
    on_open:
      - halt_all_trading: true
      - alert: CRITICAL
      - notify_operator: true
```

### 0.6 Kill Switch — 즉시 전면 차단

halt_trading 명령(E-P5-11)이 발동되면, **모든 주문 관련 Edge가 즉시 차단**된다.

```yaml
kill_switch:
  trigger_edges: [e_command_to_path1]
  affected_edges:
    - e_strategy_to_riskguard     # 신규 신호 차단
    - e_riskguard_to_dedup        # 검증된 주문도 차단
    - e_dedup_to_executor         # 실행 대기 주문도 차단
  preserved_edges:
    - e_executor_to_fsm           # 이미 제출된 주문의 체결 결과는 수신
    - e_executor_to_portfolio     # 체결 기록은 영속화 필수
    - e_watchlist_monitor         # 워치리스트 모니터링은 유지 (관찰만)

### 0.7 Trading Lifecycle — 관심종목 → 포지션 전체 흐름

> **이 섹션이 전체 Edge Contract의 근간이다.**
> 트레이딩 = 관심종목 선별 → 감시 → 진입 → 포지션 관리 → 탈출.
> 아래 라이프사이클이 Edge로 구현되지 않으면 트레이딩 시스템이 아니다.

#### Phase 1: 유니버스 → 관심종목 선별 (Screening)

전체 종목 중 전략이 감시할 대상을 추린다. 매일 장 시작 전 또는 장중 주기적으로.

```
[UniverseFilter]                       ← ConfigStore (종목 풀, 섹터 필터)
       ↓ 스크리닝 조건 충족 종목
[WatchlistManager]                     ← KnowledgeStore (인과 관계, 뉴스 감성)
       ↓ 확정된 관심종목 리스트
[MarketDataReceiver] subscribe()       ← 이 종목들만 실시간 구독
```

관련 Edge:
- `e_universe_to_watchlist`: UniverseFilter → WatchlistManager (DataFlow/DataPipe)
- `e_watchlist_to_subscribe`: WatchlistManager → MarketDataReceiver (Command)
- `e_config_to_universe`: ConfigStore → UniverseFilter (ConfigRef)
- `e_knowledge_to_watchlist`: KnowledgeStore → WatchlistManager (ConfigRef)

```yaml
# 관심종목 선별 contract
screening_contract:
  schedule: "pre_market | hourly"      # 장 시작 전 전수 스캔 + 장중 1시간 갱신
  max_watchlist_size: 30               # 동시 감시 종목 수 상한
  min_criteria:                        # 최소 스크리닝 조건
    min_market_cap: 500_000_000_000    # 시총 5000억 이상
    min_avg_volume_20d: 100_000        # 20일 평균 거래량 10만주 이상
    excluded_sectors: ["관리종목", "정리매매"]
  transition_rules:
    add_cooldown_minutes: 30           # 편입 후 30분 내 재편출 금지
    remove_with_position: false        # 포지션 보유 중인 종목은 관심종목 제거 불가
```

#### Phase 2: 관심종목 모니터링 (Monitoring)

관심종목의 실시간 시세를 감시하면서 진입 조건을 평가한다. 이 단계에서 **아직 주문은 발생하지 않는다** — 관찰만.

```
[MarketDataReceiver] tick 수신
       ↓ 관심종목만 필터링
[IndicatorCalculator] 지표 계산
       ↓ 종목별 지표 + 시세
[StrategyEngine] 진입 조건 평가
       ↓ 조건 충족 시 SignalOutput 생성
       ↓ 미충족 시 → 계속 모니터링 (Edge 없음, 내부 상태만 갱신)
```

관련 Edge:
- `e_market_data_to_indicator` (기존 E-P1-01, 관심종목 필터 추가)
- `e_indicator_to_strategy` (기존 E-P1-02)

```yaml
# 모니터링 contract
monitoring_contract:
  watchlist_filter: true               # MarketDataReceiver → Indicator 사이에서 관심종목만 통과
  indicator_cache:
    per_symbol: true                   # 종목별 지표 상태 유지
    warmup_bars: 60                    # 지표 안정화 최소 봉 수 (MA-60 기준)
    warmup_complete_required: true     # warmup 미완료 시 SignalOutput 생성 금지
  multi_timeframe:                     # 다중 타임프레임 지원
    primary: "1m"                      # 1차: 분봉 (실시간 진입)
    secondary: "1d"                    # 2차: 일봉 (추세 확인)
    alignment: "secondary confirms primary"  # 일봉 추세와 분봉 진입 정합
```

#### Phase 3: 진입 (Entry)

전략의 진입 조건이 충족되면 SignalOutput이 생성되고, 주문 흐름으로 진입한다.

```
[StrategyEngine] SignalOutput(side=BUY) 생성
       ↓
[Path 4: ConflictResolver] 다전략 충돌 해소
       ↓
[Path 4: AllocationEngine] 포지션 사이징 (몇 주 살 것인가)
       ↓
[Path 4: RiskBudgetManager] 포트폴리오 레벨 한도 검증
       ↓ APPROVED
[RiskGuard] 개별 주문 레벨 검증
       ↓
[DedupGuard] 중복 방지
       ↓
[OrderExecutor] 주문 실행
       ↓ OrderResult
[TradingFSM] IDLE → ENTRY_PENDING → IN_POSITION
```

관련 Edge: 기존 E-P1-03 ~ E-P1-06 + E-P4-07, E-P4-08

```yaml
# 진입 contract
entry_contract:
  pre_conditions:                      # 진입 전 필수 충족 조건
    - watchlist_member: true           # 관심종목에 포함된 종목만
    - warmup_complete: true            # 지표 안정화 완료
    - market_status: OPEN              # 장중만
    - not_halted: true                 # 거래 중단 상태 아님
    - no_existing_position: true       # 동일 종목 기존 포지션 없음 (중복 진입 방지)
  signal_requirements:
    min_strength: 0.6                  # 신호 강도 0.6 이상
    confirmation_ticks: 1              # 1틱 확인 (즉시) — 전략별 오버라이드 가능
  order_defaults:
    order_type: LIMIT                  # 기본 지정가
    limit_offset_ticks: 1              # 현재가 + 1틱 (슬리피지 허용)
    validity: "day"                    # 당일 유효
```

#### Phase 4: 포지션 추적 (Position Tracking)

매수 체결 후 보유 중인 종목의 실시간 손익과 탈출 조건을 추적한다. **관심종목 모니터링과 별개의 추적 루프.**

```
[MarketDataReceiver] 보유 종목 시세 계속 수신
       ↓
[IndicatorCalculator] 보유 종목 지표 갱신
       ↓
[PositionTracker] 실시간 손익 계산 + 탈출 조건 평가
       ├─ 손절선 도달 → ExitSignal(STOP_LOSS)
       ├─ 익절선 도달 → ExitSignal(TAKE_PROFIT)
       ├─ 트레일링 스탑 → ExitSignal(TRAILING_STOP)
       ├─ 시간 기반 탈출 → ExitSignal(TIME_EXIT)
       └─ 전략 탈출 → ExitSignal(STRATEGY_EXIT)
              ↓
       [StrategyEngine] → 매도 SignalOutput 생성
              ↓ 이후 주문 흐름 동일
```

관련 신규 Edge:
- `e_market_to_position_tracker`: MarketDataReceiver → PositionTracker (DataFlow)
- `e_indicator_to_position_tracker`: IndicatorCalculator → PositionTracker (DataFlow)
- `e_position_tracker_to_strategy`: PositionTracker → StrategyEngine (Event/ExitSignal)
- `e_fsm_to_position_tracker`: TradingFSM → PositionTracker (Event/포지션 상태)

```yaml
# 포지션 추적 contract
position_tracking_contract:
  update_frequency: "every_tick"       # 틱마다 손익 재계산
  exit_conditions:                     # 탈출 조건 (우선순위순)
    stop_loss:
      type: "fixed_pct | atr_multiple | trailing"
      default: { type: fixed_pct, value: -3.0 }
      edge: e_position_tracker_to_strategy
      priority: 1                      # 최우선 — 다른 조건보다 먼저 평가
    take_profit:
      type: "fixed_pct | atr_multiple | partial"
      default: { type: fixed_pct, value: 5.0 }
      priority: 2
    trailing_stop:
      type: "pct_from_high | atr_from_high"
      default: { type: pct_from_high, value: -2.0 }
      activate_after_pct: 2.0          # 2% 수익 이후 활성화
      priority: 3
    time_exit:
      max_holding_days: 20             # 최대 보유 기간
      intraday_exit_minutes: 10        # 장 마감 10분 전 당일 매매 포지션 청산
      priority: 4
    strategy_exit:
      description: "전략 자체 탈출 로직 (MA 역교차 등)"
      priority: 5

  # 포지션 상태와 관심종목의 관계
  position_watchlist_binding:
    in_position_symbol_protected: true  # 포지션 보유 종목은 관심종목에서 제거 불가
    exit_complete_then_evaluate: true   # 청산 완료 후 재진입 평가 가능
    re_entry_cooldown_minutes: 60       # 청산 후 60분 재진입 금지
```

#### Phase 5: 탈출 (Exit)

탈출 조건 충족 시 매도 → 청산 → 포지션 해제 → 관심종목 재평가.

```
[PositionTracker] ExitSignal 발생
       ↓
[StrategyEngine] SignalOutput(side=SELL) 생성
       ↓ 이후 Path 1 주문 흐름 동일 (RiskGuard → Dedup → Executor)
       ↓ OrderResult(FILLED)
[TradingFSM] IN_POSITION → EXIT_PENDING → IDLE
       ↓
[PositionTracker] 해당 종목 추적 해제
       ↓
[WatchlistManager] 종목 재평가 (관심종목 유지 or 제거)
```

관련 Edge:
- `e_exit_signal_to_strategy`: PositionTracker → StrategyEngine (Event)
- `e_fsm_exit_to_tracker`: TradingFSM(IDLE) → PositionTracker (Event/해제)
- `e_exit_to_watchlist`: TradingFSM(IDLE) → WatchlistManager (Event/재평가)

```yaml
# 탈출 contract
exit_contract:
  stop_loss_execution:
    order_type: MARKET                 # 손절은 시장가 — 체결 확실성 우선
    urgency: immediate                 # 다른 대기 주문보다 우선 실행
    e2e_budget_ms: 200                 # 손절 전용 긴급 budget
  take_profit_execution:
    order_type: LIMIT                  # 익절은 지정가
    limit_offset_ticks: 0              # 현재가 그대로
  partial_exit:
    enabled: true                      # 부분 청산 허용
    min_ratio: 0.5                     # 최소 50% 이상 청산
  post_exit:
    cooldown_minutes: 60               # 동일 종목 재진입 금지 기간
    watchlist_action: "re_evaluate"    # 관심종목 유지 여부 재평가
    pnl_record: mandatory              # 실현 손익 즉시 기록
```

#### Phase 전체 흐름 요약 (Trading Lifecycle)

```
┌─────────────────────────────────────────────────────────────┐
│ Phase 1: SCREENING (장 시작 전 / 주기적)                      │
│   UniverseFilter → WatchlistManager                         │
│   "이 종목들을 감시하겠다"                                     │
└──────────────────────┬──────────────────────────────────────┘
                       ↓ 관심종목 리스트 (max 30)
┌──────────────────────┴──────────────────────────────────────┐
│ Phase 2: MONITORING (장중 실시간)                              │
│   MarketDataReceiver → Indicator → StrategyEngine            │
│   "진입 조건을 지켜보고 있다"                                   │
└──────────────────────┬──────────────────────────────────────┘
                       ↓ SignalOutput(BUY)
┌──────────────────────┴──────────────────────────────────────┐
│ Phase 3: ENTRY (조건 충족 시)                                  │
│   ConflictResolver → Allocation → RiskBudget → Order         │
│   "매수한다"                                                   │
└──────────────────────┬──────────────────────────────────────┘
                       ↓ 체결 → IN_POSITION
┌──────────────────────┴──────────────────────────────────────┐
│ Phase 4: POSITION TRACKING (보유 중 실시간)                    │
│   MarketData → Indicator → PositionTracker                   │
│   "손익 추적 + 탈출 조건 감시"                                  │
└──────────────────────┬──────────────────────────────────────┘
                       ↓ ExitSignal (손절/익절/트레일링/시간/전략)
┌──────────────────────┴──────────────────────────────────────┐
│ Phase 5: EXIT (탈출 조건 충족 시)                               │
│   StrategyEngine(SELL) → RiskGuard → Executor → FSM(IDLE)    │
│   "매도 → 청산 → 재평가"                                       │
└─────────────────────────────────────────────────────────────┘
```

#### Trading Lifecycle 신규 노드 (Path 1 확장)

| 노드 ID | 역할 | runMode | LLM Level | 신규/기존 |
|---------|------|---------|-----------|----------|
| UniverseFilter | 전체 종목 → 후보 필터링 | batch | L0 | **신규** |
| WatchlistManager | 관심종목 관리 (편입/편출/상태) | stateful-service | L0 | **신규** |
| PositionTracker | 보유 종목 실시간 손익 + 탈출 조건 | stream | L0 | **신규** |
| MarketDataReceiver | 시세 수신 | stream | L0 | 기존 |
| IndicatorCalculator | 지표 계산 | event | L0 | 기존 |
| StrategyEngine | 진입/탈출 판단 | event | L0 | 기존 |
| RiskGuard | 주문 검증 | event | L0 | 기존 |
| DedupGuard | 중복 방지 | event | L0 | 기존 |
| OrderExecutor | 주문 실행 | event | L0 | 기존 |
| TradingFSM | 상태 관리 | stateful-service | L0 | 기존 |

#### Trading Lifecycle 신규 Edge (8개)

| Edge ID | Source → Target | Type/Role | Payload |
|---------|----------------|-----------|---------|
| e_universe_to_watchlist | UniverseFilter → WatchlistManager | DataFlow/DataPipe | list[ScreenedSymbol] |
| e_watchlist_to_subscribe | WatchlistManager → MarketDataReceiver | Event/Command | list[str] (종목코드) |
| e_config_to_universe | ConfigStore → UniverseFilter | Dep/ConfigRef | UniverseConfig |
| e_knowledge_to_watchlist | KnowledgeStore → WatchlistManager | Dep/ConfigRef | list[CausalLink] |
| e_market_to_position_tracker | MarketDataReceiver → PositionTracker | DataFlow/DataPipe | Quote |
| e_indicator_to_position_tracker | IndicatorCalculator → PositionTracker | DataFlow/DataPipe | IndicatorResult |
| e_position_tracker_to_strategy | PositionTracker → StrategyEngine | Event/EventNotify | ExitSignal |
| e_exit_to_watchlist | TradingFSM → WatchlistManager | Event/EventNotify | PositionClosed |

이 8개 Edge가 추가되면 Path 1은 **9 → 17 Edge**, 시스템 전체는 **54 → 62 Edge**가 된다.

---

### 1.1 Edge Type (4종) — 토폴로지 분류

| Type | 방향 | DAG 참여 | 설명 |
|------|------|---------|------|
| Dependency | uni (단방향) | Yes | 컴포넌트 간 의존 관계. Core → Port → Adapter |
| DataFlow | uni | Yes | 데이터 변환 파이프라인. A가 B에 데이터 전달 |
| Event | uni/multi | Yes | 발행-구독. 1:N 비동기 전달 |
| StateTransition | uni | Yes | FSM 상태 전이. 조건부 |

### 1.2 Edge Role (5종) — 의미 분류

| Role | DAG 참여 | 설명 | 대표 예시 |
|------|---------|------|----------|
| DataPipe | Yes | 데이터 흐름의 주 경로 | Quote → IndicatorCalculator |
| EventNotify | No | 비동기 알림 (Side effect) | OrderFilled → AuditLogger |
| Command | No | 명령/제어 신호 | CommandController → halt_trading |
| ConfigRef | No | 설정/참조 데이터 읽기 | ConfigStore → RiskLimits |
| AuditTrace | No | 감사 추적 로그 | 모든 Path → AuditLogger |

### 1.3 Edge Type × Edge Role 허용 매트릭스

| | DataPipe | EventNotify | Command | ConfigRef | AuditTrace |
|--|---------|-------------|---------|-----------|------------|
| Dependency | ✅ | — | — | ✅ | — |
| DataFlow | ✅ | — | — | — | — |
| Event | — | ✅ | ✅ | — | ✅ |
| StateTransition | — | — | — | — | — |

---

## 2. Edge Contract Schema (Graph IR 형식)

모든 Edge는 아래 스키마를 따른다.

```yaml
edge_id: "e_<source>_to_<target>"
edge_type: Dependency | DataFlow | Event | StateTransition
edge_role: DataPipe | EventNotify | Command | ConfigRef | AuditTrace

source:
  node_id: str
  port_name: str              # 출력 포트명
  path: str                   # path1 | path2 | ... | shared

target:
  node_id: str
  port_name: str              # 입력 포트명
  path: str

payload:
  type: str                   # Domain Type 이름 (e.g., "Quote", "OrderRequest")
  schema_ref: str             # 정의 위치 (e.g., "port_interface_path1_v1.0#Quote")
  cardinality: "1:1" | "1:N" | "N:1" | "batch"
  serialization: "pydantic" | "json" | "protobuf"

contract:
  delivery: "sync" | "async" | "fire-and-forget"
  ordering: "strict" | "best-effort"
  retry:
    max_attempts: int
    backoff: "fixed" | "exponential"
    dead_letter: bool         # 실패 시 DLQ 사용 여부
  timeout_ms: int | null      # null = 무제한
  idempotency: bool           # 중복 수신 안전 여부

validation:
  - rule_id: str
    description: str
    severity: "error" | "warning"
```

---

## 3. Path 1: Realtime Trading (9 Edges)

### 3.1 내부 DataFlow (6)

```yaml
# E-P1-01: 시세 → 지표 계산
edge_id: e_market_data_to_indicator
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: MarketDataReceiver, port_name: tick_out, path: path1 }
target: { node_id: IndicatorCalculator, port_name: tick_in, path: path1 }
payload:
  type: Quote
  schema_ref: "port_interface_path1_v1.0#Quote"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict            # 시세 순서 보장 필수
  retry: { max_attempts: 0, backoff: null, dead_letter: false }
  timeout_ms: 100             # 100ms 초과 시 drop
  idempotency: true           # 동일 timestamp 중복 무시
```

```yaml
# E-P1-02: 지표 → 전략 엔진
edge_id: e_indicator_to_strategy
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: IndicatorCalculator, port_name: indicators_out, path: path1 }
target: { node_id: StrategyEngine, port_name: indicators_in, path: path1 }
payload:
  type: IndicatorResult       # {symbol, timestamp, ma_5, ma_20, rsi_14, macd, ...}
  schema_ref: "path1_internal#IndicatorResult"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict
  retry: { max_attempts: 0, backoff: null, dead_letter: false }
  timeout_ms: 50
  idempotency: true
```

```yaml
# E-P1-03: 전략 → 리스크가드
edge_id: e_strategy_to_riskguard
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: StrategyEngine, port_name: signal_out, path: path1 }
target: { node_id: RiskGuard, port_name: signal_in, path: path1 }
payload:
  type: SignalOutput
  schema_ref: "port_interface_path3_v1.0#SignalOutput"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: sync              # 리스크 검증은 동기 — 결과 받아야 진행
  ordering: strict
  retry: { max_attempts: 1, backoff: fixed, dead_letter: false }
  timeout_ms: 200
  idempotency: false          # 동일 신호도 매번 검증 필요
```

```yaml
# E-P1-04: 리스크가드 → 중복방지
edge_id: e_riskguard_to_dedup
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: RiskGuard, port_name: approved_out, path: path1 }
target: { node_id: DedupGuard, port_name: order_in, path: path1 }
payload:
  type: OrderRequest
  schema_ref: "port_interface_path1_v1.0#OrderRequest"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: sync
  ordering: strict
  retry: { max_attempts: 0, backoff: null, dead_letter: false }
  timeout_ms: 50
  idempotency: false
```

```yaml
# E-P1-05: 중복방지 → 주문 실행
edge_id: e_dedup_to_executor
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: DedupGuard, port_name: unique_order_out, path: path1 }
target: { node_id: OrderExecutor, port_name: order_in, path: path1 }
payload:
  type: OrderRequest
  schema_ref: "port_interface_path1_v1.0#OrderRequest"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: sync
  ordering: strict
  retry: { max_attempts: 3, backoff: exponential, dead_letter: true }
  timeout_ms: 5000            # 주문 API 타임아웃
  idempotency: true           # 주문 ID 기반 멱등성
```

```yaml
# E-P1-06: 주문 실행 → 상태 머신
edge_id: e_executor_to_fsm
edge_type: Event
edge_role: EventNotify
source: { node_id: OrderExecutor, port_name: result_out, path: path1 }
target: { node_id: TradingFSM, port_name: fill_event_in, path: path1 }
payload:
  type: OrderResult
  schema_ref: "port_interface_path1_v1.0#OrderResult"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict            # 체결 순서 보장
  retry: { max_attempts: 3, backoff: exponential, dead_letter: true }
  timeout_ms: null
  idempotency: true           # order_id 기반
```

### 3.2 Shared Store Edge (3)

```yaml
# E-P1-07: 시세 → MarketDataStore
edge_id: e_market_to_store
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: MarketDataReceiver, port_name: persist_out, path: path1 }
target: { node_id: MarketDataStore, port_name: write_in, path: shared }
payload:
  type: "Quote | OHLCV"
  schema_ref: "port_interface_path1_v1.0#Quote"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: fire-and-forget   # 시세 저장 실패가 매매를 막으면 안 됨
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: true }
  timeout_ms: 1000
  idempotency: true
```

```yaml
# E-P1-08: 주문 실행 → PortfolioStore
edge_id: e_executor_to_portfolio
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: OrderExecutor, port_name: trade_out, path: path1 }
target: { node_id: PortfolioStore, port_name: trade_in, path: shared }
payload:
  type: TradeRecord
  schema_ref: "port_interface_path1_v1.0#TradeRecord"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict            # 체결 기록 순서 보장 필수 (WAL)
  retry: { max_attempts: 5, backoff: exponential, dead_letter: true }
  timeout_ms: 3000
  idempotency: true           # trade_id 기반
```

```yaml
# E-P1-09: TradingFSM ← ConfigStore
edge_id: e_config_to_fsm
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: ConfigStore, port_name: config_out, path: shared }
target: { node_id: TradingFSM, port_name: config_in, path: path1 }
payload:
  type: StrategyConfig
  schema_ref: "shared_store#StrategyConfig"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: sync              # 설정 읽기는 동기
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 500
  idempotency: true
```

### 3.3 Trading Lifecycle Edge (8개 — 신규)

```yaml
# E-P1-10: 유니버스 필터 → 관심종목 관리
edge_id: e_universe_to_watchlist
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: UniverseFilter, port_name: screened_out, path: path1 }
target: { node_id: WatchlistManager, port_name: candidates_in, path: path1 }
payload:
  type: "list[ScreenedSymbol]"
  schema_ref: "path1_lifecycle#ScreenedSymbol"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: async
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 10000
  idempotency: true

# E-P1-11: 관심종목 관리 → 시세 구독 변경
edge_id: e_watchlist_to_subscribe
edge_type: Event
edge_role: Command
source: { node_id: WatchlistManager, port_name: subscribe_cmd, path: path1 }
target: { node_id: MarketDataReceiver, port_name: subscribe_in, path: path1 }
payload:
  type: WatchlistUpdate
  schema_ref: "path1_lifecycle#WatchlistUpdate"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: sync
  ordering: strict
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 5000
  idempotency: true

# E-P1-12: ConfigStore → 유니버스 필터
edge_id: e_config_to_universe
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: ConfigStore, port_name: screening_config, path: shared }
target: { node_id: UniverseFilter, port_name: config_in, path: path1 }
payload: { type: UniverseConfig, cardinality: "1:1", serialization: pydantic }
contract: { delivery: sync, ordering: best-effort, timeout_ms: 500, idempotency: true }

# E-P1-13: KnowledgeStore → 관심종목 (지식 기반 편입)
edge_id: e_knowledge_to_watchlist
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: KnowledgeStore, port_name: insight_out, path: shared }
target: { node_id: WatchlistManager, port_name: knowledge_in, path: path1 }
payload: { type: "list[CausalLink]", cardinality: batch, serialization: pydantic }
contract: { delivery: sync, ordering: best-effort, timeout_ms: 3000, idempotency: true }

# E-P1-14: 시세 → 포지션 추적기
edge_id: e_market_to_position_tracker
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: MarketDataReceiver, port_name: position_tick_out, path: path1 }
target: { node_id: PositionTracker, port_name: tick_in, path: path1 }
payload: { type: Quote, cardinality: "1:1", serialization: pydantic }
contract:
  delivery: async
  ordering: strict
  retry: { max_attempts: 0, backoff: null, dead_letter: false }
  timeout_ms: 100
  idempotency: true

# E-P1-15: 지표 → 포지션 추적기 (탈출 조건 판단용)
edge_id: e_indicator_to_position_tracker
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: IndicatorCalculator, port_name: position_ind_out, path: path1 }
target: { node_id: PositionTracker, port_name: indicators_in, path: path1 }
payload: { type: IndicatorResult, cardinality: "1:1", serialization: pydantic }
contract: { delivery: async, ordering: strict, timeout_ms: 50, idempotency: true }

# E-P1-16: 포지션 추적기 → 전략 (탈출 신호)
edge_id: e_position_tracker_to_strategy
edge_type: Event
edge_role: EventNotify
source: { node_id: PositionTracker, port_name: exit_signal_out, path: path1 }
target: { node_id: StrategyEngine, port_name: exit_in, path: path1 }
payload:
  type: ExitSignal
  schema_ref: "path1_lifecycle#ExitSignal"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: sync              # 탈출 신호는 즉시 처리
  ordering: strict
  retry: { max_attempts: 1, backoff: null, dead_letter: false }
  timeout_ms: 100             # 손절은 100ms 내 전략 도달 필수
  idempotency: false

# E-P1-17: TradingFSM → 관심종목 (청산 후 재평가)
edge_id: e_exit_to_watchlist
edge_type: Event
edge_role: EventNotify
source: { node_id: TradingFSM, port_name: position_closed_out, path: path1 }
target: { node_id: WatchlistManager, port_name: exit_event_in, path: path1 }
payload:
  type: PositionClosed
  schema_ref: "path1_lifecycle#PositionClosed"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 2000
  idempotency: true
```

---

## 4. Path 2: Knowledge Building (9 Edges)

### 4.1 내부 DataFlow (6)

```yaml
# E-P2-01: 수집 → 파싱
edge_id: e_collector_to_parser
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: ExternalCollector, port_name: docs_out, path: path2 }
target: { node_id: DocumentParser, port_name: docs_in, path: path2 }
payload:
  type: "list[RawDocument]"
  schema_ref: "port_interface_path2_v1.0#RawDocument"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: async
  ordering: best-effort       # 문서 순서 무관
  retry: { max_attempts: 2, backoff: fixed, dead_letter: true }
  timeout_ms: 30000           # LLM 파싱 시 긴 타임아웃
  idempotency: true           # source_id 기반
```

```yaml
# E-P2-02: 파싱 → 온톨로지 매핑
edge_id: e_parser_to_ontology
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: DocumentParser, port_name: parsed_out, path: path2 }
target: { node_id: OntologyMapper, port_name: parsed_in, path: path2 }
payload:
  type: "list[ParsedDocument]"
  schema_ref: "port_interface_path2_v1.0#ParsedDocument"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: async
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: true }
  timeout_ms: 60000
  idempotency: true
```

```yaml
# E-P2-03: 온톨로지 → 인과추론
edge_id: e_ontology_to_causal
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: OntologyMapper, port_name: triples_out, path: path2 }
target: { node_id: CausalReasoner, port_name: triples_in, path: path2 }
payload:
  type: "list[OntologyTriple]"
  schema_ref: "port_interface_path2_v1.0#OntologyTriple"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: async
  ordering: best-effort
  retry: { max_attempts: 3, backoff: exponential, dead_letter: true }
  timeout_ms: 120000          # agent 노드 — 다중 iteration 가능
  idempotency: true           # triple_id 기반
```

```yaml
# E-P2-04: 인과추론 → 검색 인덱스
edge_id: e_causal_to_index
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: CausalReasoner, port_name: causal_out, path: path2 }
target: { node_id: KnowledgeIndex, port_name: causal_in, path: path2 }
payload:
  type: "list[CausalLink]"
  schema_ref: "port_interface_path2_v1.0#CausalLink"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: async
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: true }
  timeout_ms: 10000
  idempotency: true
```

```yaml
# E-P2-05: 온톨로지 → 검색 인덱스 (문서 직접)
edge_id: e_ontology_to_index
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: OntologyMapper, port_name: parsed_forward, path: path2 }
target: { node_id: KnowledgeIndex, port_name: doc_in, path: path2 }
payload:
  type: "list[ParsedDocument]"
  schema_ref: "port_interface_path2_v1.0#ParsedDocument"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: async
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: true }
  timeout_ms: 10000
  idempotency: true
```

```yaml
# E-P2-06: 스케줄러 → 수집기 (명령)
edge_id: e_scheduler_to_collector
edge_type: Event
edge_role: Command
source: { node_id: KnowledgeScheduler, port_name: trigger_out, path: path2 }
target: { node_id: ExternalCollector, port_name: trigger_in, path: path2 }
payload:
  type: CollectionConfig
  schema_ref: "path2_internal#CollectionConfig"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: async
  ordering: strict
  retry: { max_attempts: 1, backoff: null, dead_letter: false }
  timeout_ms: 5000
  idempotency: false          # 매번 새 수집 트리거
```

### 4.2 Shared Store Edge (3)

```yaml
# E-P2-07: 온톨로지 → KnowledgeStore
edge_id: e_ontology_to_knowledge_store
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: OntologyMapper, port_name: persist_out, path: path2 }
target: { node_id: KnowledgeStore, port_name: triple_in, path: shared }
payload:
  type: "list[OntologyTriple]"
  schema_ref: "port_interface_path2_v1.0#OntologyTriple"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: async
  ordering: best-effort
  retry: { max_attempts: 3, backoff: exponential, dead_letter: true }
  timeout_ms: 5000
  idempotency: true           # UPSERT on (subject, predicate, object, source_id)
```

```yaml
# E-P2-08: 인과추론 → KnowledgeStore
edge_id: e_causal_to_knowledge_store
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: CausalReasoner, port_name: persist_out, path: path2 }
target: { node_id: KnowledgeStore, port_name: causal_in, path: shared }
payload:
  type: "list[CausalLink]"
  schema_ref: "port_interface_path2_v1.0#CausalLink"
  cardinality: batch
  serialization: pydantic
contract:
  delivery: async
  ordering: best-effort
  retry: { max_attempts: 3, backoff: exponential, dead_letter: true }
  timeout_ms: 5000
  idempotency: true
```

```yaml
# E-P2-09: 수집기 ← MarketDataStore (종목 코드 참조)
edge_id: e_market_store_to_collector
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: MarketDataStore, port_name: symbols_out, path: shared }
target: { node_id: ExternalCollector, port_name: symbols_in, path: path2 }
payload:
  type: "list[str]"
  schema_ref: "shared_store#SymbolList"
  cardinality: "1:1"
  serialization: json
contract:
  delivery: sync
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 1000
  idempotency: true
```

---

## 5. Path 3: Strategy Development (12 Edges)

### 5.1 내부 DataFlow (8)

```yaml
# E-P3-01: 아이디어 수집 → 전략 생성
edge_id: e_collector_to_generator
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: StrategyCollector, port_name: idea_out, path: path3 }
target: { node_id: StrategyGenerator, port_name: idea_in, path: path3 }
payload:
  type: StrategyIdea           # {description, type, target_symbols, inspiration_source}
  schema_ref: "path3_internal#StrategyIdea"
  cardinality: "1:1"
  serialization: pydantic
contract: { delivery: async, ordering: best-effort, retry: { max_attempts: 1, backoff: null, dead_letter: false }, timeout_ms: 120000, idempotency: false }

# E-P3-02: 전략 생성 → 레지스트리
edge_id: e_generator_to_registry
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: StrategyGenerator, port_name: strategy_out, path: path3 }
target: { node_id: StrategyRegistry, port_name: register_in, path: path3 }
payload:
  type: "tuple[StrategyMeta, StrategyCode]"
  schema_ref: "port_interface_path3_v1.0#StrategyMeta"
  cardinality: "1:1"
  serialization: pydantic
contract: { delivery: sync, ordering: strict, retry: { max_attempts: 2, backoff: fixed, dead_letter: false }, timeout_ms: 5000, idempotency: true }

# E-P3-03: 레지스트리 → 백테스트
edge_id: e_registry_to_backtest
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: StrategyRegistry, port_name: backtest_request_out, path: path3 }
target: { node_id: BacktestEngine, port_name: config_in, path: path3 }
payload:
  type: BacktestConfig
  schema_ref: "port_interface_path3_v1.0#BacktestConfig"
  cardinality: "1:1"
  serialization: pydantic
contract: { delivery: async, ordering: best-effort, retry: { max_attempts: 1, backoff: null, dead_letter: false }, timeout_ms: 300000, idempotency: true }

# E-P3-04: 백테스트 → 평가
edge_id: e_backtest_to_evaluator
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: BacktestEngine, port_name: result_out, path: path3 }
target: { node_id: StrategyEvaluator, port_name: result_in, path: path3 }
payload:
  type: BacktestResult
  schema_ref: "port_interface_path3_v1.0#BacktestResult"
  cardinality: "1:1"
  serialization: pydantic
contract: { delivery: async, ordering: best-effort, retry: { max_attempts: 1, backoff: null, dead_letter: false }, timeout_ms: 30000, idempotency: true }

# E-P3-05: 평가 → 레지스트리 (상태 업데이트)
edge_id: e_evaluator_to_registry
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: StrategyEvaluator, port_name: verdict_out, path: path3 }
target: { node_id: StrategyRegistry, port_name: status_update_in, path: path3 }
payload:
  type: StatusUpdate           # {strategy_id, new_status, reasoning}
  schema_ref: "path3_internal#StatusUpdate"
  cardinality: "1:1"
  serialization: pydantic
contract: { delivery: sync, ordering: strict, retry: { max_attempts: 2, backoff: fixed, dead_letter: false }, timeout_ms: 2000, idempotency: true }

# E-P3-06: 레지스트리 → 옵티마이저
edge_id: e_registry_to_optimizer
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: StrategyRegistry, port_name: optimize_request_out, path: path3 }
target: { node_id: Optimizer, port_name: config_in, path: path3 }
payload:
  type: OptimizationConfig
  schema_ref: "port_interface_path3_v1.0#OptimizationConfig"
  cardinality: "1:1"
  serialization: pydantic
contract: { delivery: async, ordering: best-effort, retry: { max_attempts: 1, backoff: null, dead_letter: false }, timeout_ms: 600000, idempotency: true }

# E-P3-07: 옵티마이저 → 백테스트 (배치)
edge_id: e_optimizer_to_backtest
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: Optimizer, port_name: batch_config_out, path: path3 }
target: { node_id: BacktestEngine, port_name: batch_in, path: path3 }
payload:
  type: "list[BacktestConfig]"
  schema_ref: "port_interface_path3_v1.0#BacktestConfig"
  cardinality: batch
  serialization: pydantic
contract: { delivery: async, ordering: best-effort, retry: { max_attempts: 1, backoff: null, dead_letter: false }, timeout_ms: 600000, idempotency: true }

# E-P3-08: 옵티마이저 → 레지스트리 (최적 결과)
edge_id: e_optimizer_to_registry
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: Optimizer, port_name: result_out, path: path3 }
target: { node_id: StrategyRegistry, port_name: optimized_in, path: path3 }
payload:
  type: OptimizationResult
  schema_ref: "port_interface_path3_v1.0#OptimizationResult"
  cardinality: "1:1"
  serialization: pydantic
contract: { delivery: sync, ordering: strict, retry: { max_attempts: 2, backoff: fixed, dead_letter: false }, timeout_ms: 5000, idempotency: true }
```

### 5.2 Shared Store / Cross-Path Edge (4)

```yaml
# E-P3-09: 레지스트리 → StrategyStore
edge_id: e_registry_to_strategy_store
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: StrategyRegistry, port_name: persist_out, path: path3 }
target: { node_id: StrategyStore, port_name: write_in, path: shared }
payload:
  type: "StrategyMeta + StrategyCode"
  schema_ref: "port_interface_path3_v1.0#StrategyMeta"
  cardinality: "1:1"
  serialization: pydantic
contract: { delivery: async, ordering: strict, retry: { max_attempts: 3, backoff: exponential, dead_letter: true }, timeout_ms: 5000, idempotency: true }

# E-P3-10: 백테스트 ← MarketDataStore
edge_id: e_market_store_to_backtest
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: MarketDataStore, port_name: ohlcv_out, path: shared }
target: { node_id: BacktestEngine, port_name: data_in, path: path3 }
payload:
  type: "dict[str, list[OHLCV]]"
  schema_ref: "port_interface_path1_v1.0#OHLCV"
  cardinality: batch
  serialization: pydantic
contract: { delivery: sync, ordering: strict, retry: { max_attempts: 2, backoff: fixed, dead_letter: false }, timeout_ms: 10000, idempotency: true }

# E-P3-11: 아이디어 수집 ← KnowledgeStore
edge_id: e_knowledge_to_collector
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: KnowledgeStore, port_name: causal_out, path: shared }
target: { node_id: StrategyCollector, port_name: knowledge_in, path: path3 }
payload:
  type: "list[CausalLink]"
  schema_ref: "port_interface_path2_v1.0#CausalLink"
  cardinality: batch
  serialization: pydantic
contract: { delivery: sync, ordering: best-effort, retry: { max_attempts: 2, backoff: fixed, dead_letter: false }, timeout_ms: 5000, idempotency: true }

# E-P3-12: 전략 로더 → Path 1 (배포)
edge_id: e_loader_to_path1
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: StrategyLoader, port_name: instance_out, path: path3 }
target: { node_id: StrategyEngine, port_name: strategy_in, path: path1 }
payload:
  type: StrategyInstance       # 로딩된 전략 인스턴스 핸들
  schema_ref: "path3_internal#StrategyInstance"
  cardinality: "1:1"
  serialization: pydantic
contract: { delivery: sync, ordering: strict, retry: { max_attempts: 1, backoff: null, dead_letter: false }, timeout_ms: 10000, idempotency: false }
```

---

## 6. Path 4: Portfolio Management (11 Edges)

### 6.1 내부 DataFlow (6)

```yaml
# E-P4-01 ~ E-P4-06 (간결 표기)

# E-P4-01: 포지션 집계 → 리스크 관리
edge_id: e_aggregator_to_risk
payload: { type: PortfolioSnapshot }
contract: { delivery: async, ordering: strict, timeout_ms: 1000 }

# E-P4-02: 포지션 집계 → 배분 엔진
edge_id: e_aggregator_to_allocation
payload: { type: PortfolioSnapshot }
contract: { delivery: async, ordering: strict, timeout_ms: 1000 }

# E-P4-03: 충돌 해소 → 배분 엔진
edge_id: e_conflict_to_allocation
payload: { type: ResolvedAction }
contract: { delivery: sync, ordering: strict, timeout_ms: 500 }

# E-P4-04: 배분 엔진 → 리스크 관리 (검증 요청)
edge_id: e_allocation_to_risk
payload: { type: SizingRequest → RiskCheckResult }
contract: { delivery: sync, ordering: strict, timeout_ms: 500 }

# E-P4-05: 리밸런서 → 배분 엔진 (트리거)
edge_id: e_rebalancer_to_allocation
edge_role: Command
payload: { type: RebalanceTrigger }
contract: { delivery: async, ordering: strict, timeout_ms: 1000 }

# E-P4-06: 포지션 집계 → 성과 분석
edge_id: e_aggregator_to_performance
payload: { type: PnLRecord }
contract: { delivery: async, ordering: best-effort, timeout_ms: 5000 }
```

### 6.2 Cross-Path / Shared Store Edge (5)

```yaml
# E-P4-07: Path 1 → 충돌 해소 (신호 수신)
edge_id: e_path1_signals_to_conflict
edge_type: Event
edge_role: EventNotify
source: { node_id: StrategyEngine, port_name: signal_broadcast, path: path1 }
target: { node_id: ConflictResolver, port_name: signals_in, path: path4 }
payload:
  type: "list[SignalOutput]"
  schema_ref: "port_interface_path3_v1.0#SignalOutput"
  cardinality: "N:1"          # 여러 전략에서 하나의 충돌해소기로
  serialization: pydantic
contract: { delivery: async, ordering: strict, retry: { max_attempts: 1, backoff: null, dead_letter: false }, timeout_ms: 500, idempotency: true }

# E-P4-08: 리스크 관리 → Path 1 (승인/거부)
edge_id: e_risk_to_path1
edge_type: Event
edge_role: EventNotify
source: { node_id: RiskBudgetManager, port_name: verdict_out, path: path4 }
target: { node_id: RiskGuard, port_name: portfolio_verdict_in, path: path1 }
payload:
  type: RiskCheckResult
  schema_ref: "port_interface_path4_v1.0#RiskCheckResult"
  cardinality: "1:1"
  serialization: pydantic
contract: { delivery: sync, ordering: strict, retry: { max_attempts: 1, backoff: null, dead_letter: false }, timeout_ms: 200, idempotency: false }

# E-P4-09: 포지션 집계 → PortfolioStore
edge_id: e_aggregator_to_portfolio_store
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: PositionAggregator, port_name: persist_out, path: path4 }
target: { node_id: PortfolioStore, port_name: snapshot_in, path: shared }
payload: { type: PortfolioSnapshot }
contract: { delivery: async, ordering: strict, retry: { max_attempts: 3, backoff: exponential, dead_letter: true }, timeout_ms: 3000, idempotency: true }

# E-P4-10: 포지션 집계 ← MarketDataStore (현재가)
edge_id: e_market_store_to_aggregator
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: MarketDataStore, port_name: prices_out, path: shared }
target: { node_id: PositionAggregator, port_name: prices_in, path: path4 }
payload: { type: "dict[str, float]" }
contract: { delivery: sync, ordering: best-effort, timeout_ms: 500, idempotency: true }

# E-P4-11: 성과 분석 → PortfolioStore
edge_id: e_performance_to_portfolio_store
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: PerformanceAnalyzer, port_name: report_out, path: path4 }
target: { node_id: PortfolioStore, port_name: report_in, path: shared }
payload: { type: PerformanceReport }
contract: { delivery: async, ordering: best-effort, retry: { max_attempts: 2, backoff: fixed, dead_letter: true }, timeout_ms: 5000, idempotency: true }
```

---

## 7. Path 5: Watchdog & Operations (13 Edges)

### 7.1 내부 Edge (6)

```yaml
# E-P5-01: 헬스모니터 → 알림
edge_id: e_health_to_alert
edge_type: Event
edge_role: EventNotify
source: { node_id: HealthMonitor, port_name: unhealthy_out, path: path5 }
target: { node_id: AlertDispatcher, port_name: alert_in, path: path5 }
payload: { type: HealthStatus, schema_ref: "port_interface_path5_v1.0#HealthStatus" }
contract: { delivery: async, ordering: strict, retry: { max_attempts: 3, backoff: exponential, dead_letter: true }, timeout_ms: 5000, idempotency: true }

# E-P5-02: 감사 로거 → 이상 감지
edge_id: e_audit_to_anomaly
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: AuditLogger, port_name: stream_out, path: path5 }
target: { node_id: AnomalyDetector, port_name: events_in, path: path5 }
payload: { type: AuditEvent, schema_ref: "port_interface_path5_v1.0#AuditEvent" }
contract: { delivery: async, ordering: strict, retry: { max_attempts: 1, backoff: null, dead_letter: false }, timeout_ms: 1000, idempotency: true }

# E-P5-03: 이상 감지 → 알림
edge_id: e_anomaly_to_alert
edge_type: Event
edge_role: EventNotify
source: { node_id: AnomalyDetector, port_name: anomaly_out, path: path5 }
target: { node_id: AlertDispatcher, port_name: alert_in, path: path5 }
payload: { type: Anomaly, schema_ref: "port_interface_path5_v1.0#Anomaly" }
contract: { delivery: async, ordering: strict, retry: { max_attempts: 3, backoff: exponential, dead_letter: true }, timeout_ms: 5000, idempotency: true }

# E-P5-04: 명령 컨트롤러 → 감사 로거
edge_id: e_command_to_audit
edge_type: DataFlow
edge_role: AuditTrace
source: { node_id: CommandController, port_name: audit_out, path: path5 }
target: { node_id: AuditLogger, port_name: event_in, path: path5 }
payload: { type: AuditEvent }
contract: { delivery: async, ordering: strict, retry: { max_attempts: 3, backoff: exponential, dead_letter: true }, timeout_ms: 2000, idempotency: true }

# E-P5-05: 감사 로거 → 일일 리포터
edge_id: e_audit_to_reporter
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: AuditLogger, port_name: daily_out, path: path5 }
target: { node_id: DailyReporter, port_name: events_in, path: path5 }
payload: { type: "list[AuditEvent]" }
contract: { delivery: async, ordering: best-effort, timeout_ms: 30000, idempotency: true }

# E-P5-06: 일일 리포터 → 알림 (발송)
edge_id: e_reporter_to_alert
edge_type: Event
edge_role: Command
source: { node_id: DailyReporter, port_name: report_out, path: path5 }
target: { node_id: AlertDispatcher, port_name: summary_in, path: path5 }
payload: { type: DailySummary }
contract: { delivery: async, ordering: strict, timeout_ms: 10000, idempotency: true }
```

### 7.2 Cross-Path Edge (7)

```yaml
# E-P5-07 ~ E-P5-10: 전 Path → AuditLogger (감사 수신)
# 4개 Edge — 동일 패턴

edge_id: e_path1_to_audit  # / e_path2_to_audit / e_path3_to_audit / e_path4_to_audit
edge_type: Event
edge_role: AuditTrace
source: { node_id: "*", port_name: audit_out, path: path1|path2|path3|path4 }
target: { node_id: AuditLogger, port_name: event_in, path: path5 }
payload:
  type: AuditEvent
  schema_ref: "port_interface_path5_v1.0#AuditEvent"
  cardinality: "N:1"
  serialization: pydantic
contract:
  delivery: fire-and-forget   # 감사 로깅이 비즈니스 흐름을 차단하면 안 됨
  ordering: best-effort       # 타임스탬프로 사후 정렬
  retry: { max_attempts: 2, backoff: fixed, dead_letter: true }
  timeout_ms: 1000
  idempotency: true           # event_id 기반
```

```yaml
# E-P5-11: 명령 → Path 1 (거래 제어)
edge_id: e_command_to_path1
edge_type: Event
edge_role: Command
source: { node_id: CommandController, port_name: trade_cmd_out, path: path5 }
target: { node_id: TradingFSM, port_name: command_in, path: path1 }
payload:
  type: Command
  schema_ref: "port_interface_path5_v1.0#Command"
  cardinality: "1:1"
  serialization: pydantic
contract:
  delivery: sync              # 명령은 실행 확인 필요
  ordering: strict
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 5000
  idempotency: true           # command_id 기반

# E-P5-12: 명령 → Path 3 (전략 제어)
edge_id: e_command_to_path3
edge_type: Event
edge_role: Command
source: { node_id: CommandController, port_name: strategy_cmd_out, path: path5 }
target: { node_id: StrategyRegistry, port_name: command_in, path: path3 }
payload: { type: Command }
contract: { delivery: sync, ordering: strict, timeout_ms: 10000, idempotency: true }

# E-P5-13: 명령 → Path 4 (리스크 제어)
edge_id: e_command_to_path4
edge_type: Event
edge_role: Command
source: { node_id: CommandController, port_name: risk_cmd_out, path: path5 }
target: { node_id: RiskBudgetManager, port_name: command_in, path: path4 }
payload: { type: Command }
contract: { delivery: sync, ordering: strict, timeout_ms: 5000, idempotency: true }
```

---

## 8. Edge 통계 요약

### 8.1 Path별 Edge 수

| Path | DataFlow | Event | Dependency | 합계 |
|------|----------|-------|------------|------|
| Path 1: Realtime Trading | 11 | 4 | 2 | **17** |
| Path 2: Knowledge Building | 7 | 1 | 1 | 9 |
| Path 3: Strategy Development | 10 | 0 | 2 | 12 |
| Path 4: Portfolio Management | 6 | 2 | 3 | 11 |
| Path 5: Watchdog & Operations | 4 | 9 | 0 | 13 |
| **합계** | **38** | **16** | **8** | **62** |

> Path 1이 9 → 17로 증가. Trading Lifecycle(관심종목 선별/모니터링/포지션 추적) 8개 Edge 추가.

### 8.2 Edge Role 분포

| Role | 수 | 비율 | 설명 |
|------|----|------|------|
| DataPipe | 34 | 55% | 주 데이터 흐름 |
| EventNotify | 10 | 16% | 비동기 알림 |
| Command | 8 | 13% | 제어 명령 |
| ConfigRef | 6 | 10% | 설정 참조 |
| AuditTrace | 4 | 6% | 감사 추적 |

### 8.3 Path 1 노드 확장 현황

| 구분 | 이전 | 이후 | 변경 |
|------|------|------|------|
| 노드 수 | 7 | 10 | +3 (UniverseFilter, WatchlistManager, PositionTracker) |
| Edge 수 | 9 | 17 | +8 (Trading Lifecycle) |
| Domain Type | 6 | 10 | +4 (ScreenedSymbol, WatchlistUpdate, ExitSignal, PositionClosed) |

### 8.4 Cross-Path Edge 매트릭스

| Source ↓ / Target → | Path 1 | Path 2 | Path 3 | Path 4 | Path 5 | Shared |
|---------------------|--------|--------|--------|--------|--------|--------|
| Path 1 | 12 | — | — | 1 | 1 | 2 |
| Path 2 | — | 6 | — | — | 1 | 2 |
| Path 3 | 1 | — | 8 | — | 1 | 1 |
| Path 4 | 1 | — | — | 6 | 1 | 2 |
| Path 5 | 1 | — | 1 | 1 | 6 | — |
| Shared | 2 | 1 | 2 | 1 | — | — |

핵심 관찰: Path 간 직접 Edge는 10개. Path 1 내부가 12개로 가장 크지만, 이는 **트레이딩 라이프사이클(관심종목→모니터링→진입→추적→탈출)이 본질적으로 복잡**하기 때문이다. Isolated Path 원칙은 유지.

---

## 9. Contract 패턴 사전

반복적으로 등장하는 contract 조합을 패턴으로 정리.

### Pattern A: Critical Sync (주문 흐름)
```yaml
contract:
  delivery: sync
  ordering: strict
  retry: { max_attempts: 3, backoff: exponential, dead_letter: true }
  timeout_ms: 5000
  idempotency: true
```
적용: E-P1-05, E-P1-08, E-P4-08

### Pattern B: Fast Async (실시간 시세)
```yaml
contract:
  delivery: async
  ordering: strict
  retry: { max_attempts: 0, backoff: null, dead_letter: false }
  timeout_ms: 100
  idempotency: true
```
적용: E-P1-01, E-P1-02

### Pattern C: Batch Async (지식 파이프라인)
```yaml
contract:
  delivery: async
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: true }
  timeout_ms: 60000
  idempotency: true
```
적용: E-P2-01 ~ E-P2-05

### Pattern D: Fire-and-Forget (감사/로깅)
```yaml
contract:
  delivery: fire-and-forget
  ordering: best-effort
  retry: { max_attempts: 2, backoff: fixed, dead_letter: true }
  timeout_ms: 1000
  idempotency: true
```
적용: E-P5-07 ~ E-P5-10, E-P1-07

### Pattern E: Command Sync (운영 명령)
```yaml
contract:
  delivery: sync
  ordering: strict
  retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
  timeout_ms: 5000
  idempotency: true
```
적용: E-P5-11 ~ E-P5-13

---

## 10. Validation Rules (Edge 전용)

| Rule ID | Description | Severity |
|---------|-------------|----------|
| V-EDGE-001 | Cross-Path Edge는 Shared Store 경유 또는 허용된 직접 연결만 | error |
| V-EDGE-002 | DataPipe edge는 payload.type 필수 | error |
| V-EDGE-003 | delivery: sync인 edge는 timeout_ms 필수 | error |
| V-EDGE-004 | dead_letter: true인 edge는 DLQ consumer 노드 존재 필수 | warning |
| V-EDGE-005 | idempotency: true인 edge는 payload에 unique ID 필드 존재 | warning |
| V-EDGE-006 | ordering: strict인 edge의 source/target은 동일 asyncio event loop | warning |
| V-EDGE-007 | Path 1 내부 edge는 timeout_ms ≤ 5000ms | error |
| V-EDGE-008 | AuditTrace edge의 delivery는 fire-and-forget만 허용 | error |
| V-EDGE-009 | ConfigRef edge의 delivery는 sync만 허용 | warning |
| V-EDGE-010 | Cross-Path Command edge의 source는 Path 5(Watchdog)만 허용 | error |
| V-EDGE-011 | 주문 흐름 Edge(E-P1-03~05)는 trading_context.chain_started_at 필수 | error |
| V-EDGE-012 | ExitSignal(STOP_LOSS) edge의 timeout_ms ≤ 100ms | error |
| V-EDGE-013 | WatchlistUpdate로 removed된 종목이 active position이면 거부 | error |
| V-EDGE-014 | ScreenedSymbol.warmup_complete=false인 종목은 SignalOutput 생성 불가 | error |

---

## 11. 다음 단계

- **port_interface_path1_v1.0 업데이트** — 3개 신규 노드(UniverseFilter, WatchlistManager, PositionTracker) + 4개 신규 Domain Type 추가
- **5번: System Manifest** — 전체 노드(~34개) + Port(25개) + Edge(62개) 통합 레지스트리
- **6번: Node Blueprint Catalog** — 각 노드 상세 전개
- **INDEX.md 업데이트** — 이 문서 추가

---

*End of Document — Edge Contract Definition v1.0*
*62 Edges | 4 Edge Types | 5 Edge Roles | 5 Contract Patterns | 14 Validation Rules*
*Trading Lifecycle: 5 Phases (Screening → Monitoring → Entry → Tracking → Exit)*
