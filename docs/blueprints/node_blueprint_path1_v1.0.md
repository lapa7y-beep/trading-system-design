# Node Blueprint Catalog — Path 1: Realtime Trading

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | node_blueprint_path1_v1.0 |
| 선행 문서 | system_manifest_v1.0, port_interface_path1_v2.0, order_lifecycle_spec_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |
| 대상 | Path 1 전체 13개 노드 (SubPath 1A: 3, 1B: 7, 1C: 3) |

---

## SubPath 1A: Universe Management

---

### Node 01: Screener

```yaml
node_id: screener
path: path1.1a
runMode: batch
llm_level: L0
category: Core

description: |
  전 종목 중 조건에 맞는 후보를 필터링하여 WatchlistManager에 전달.
  장 시작 전(08:30) 일봉 기반 + 장중(30분 주기) 실시간 기반 2가지 모드.

lifecycle:
  startup: |
    1. ConfigStore에서 ScreenerProfile 로드
    2. MarketDataStore에서 전 종목 OHLCV 캐시
    3. KnowledgeStore에서 섹터/테마 정보 캐시 (선택)
  execution:
    pre_market:
      trigger: ClockPort.get_status() == PRE_MARKET, 시각 == 08:30
      flow: |
        1. MarketDataStore에서 전일 OHLCV 조회 (전 종목)
        2. ScreenerProfile.conditions 순회하며 필터링
        3. 조건별 점수 계산 → 가중 합산 → 종합 score
        4. score 내림차순 정렬, max_results 잘라내기
        5. ScreenerOutput 생성 → WatchlistManager.promote()
    intraday:
      trigger: 30분 주기 (ConfigStore.scan_interval_minutes)
      flow: |
        1. MarketDataReceiver에서 현재 시세 스냅샷 수신 (fire-and-forget)
        2. KIS 등락률/거래량 순위 API 호출 (상위 100종목)
        3. 기존 조건 + 실시간 데이터로 재필터링
        4. 기존 WATCHING 종목과 중복 제거
        5. 신규 후보만 WatchlistManager.promote()
  shutdown: 당일 스크리닝 이력 저장

ports_used:
  - ScreenerPort.scan (pre_market)
  - ScreenerPort.scan_realtime (intraday)
  - ScreenerPort.get_profiles
  - ScreenerPort.save_profile

input:
  - MarketDataStore: OHLCV (전 종목, Read)
  - KnowledgeStore: 섹터/테마 정보 (Read, 선택)
  - ConfigStore: ScreenerProfile, scan_interval_minutes

output:
  - ScreenerOutput → WatchlistManager

config_params:
  scan_interval_minutes: 30       # 장중 재스크리닝 주기
  pre_market_scan_time: "08:30"   # 장전 스크리닝 시각
  max_profiles: 5                 # 동시 활성 프로파일 수
  rank_api_top_n: 100             # KIS 순위 API 조회 건수

error_handling:
  - KIS API 장애: 이전 스크리닝 결과 유지, 알림
  - MarketDataStore 조회 실패: 장전 스크리닝 건너뜀, 장중에 재시도
  - 조건 평가 오류: 해당 종목 건너뜀, 에러 로깅
```

---

### Node 02: WatchlistManager

```yaml
node_id: watchlist_manager
path: path1.1a
runMode: stateful-service
llm_level: L0
category: Core

description: |
  관심종목의 전체 생명주기를 관리하는 중심 허브.
  종목 상태 전이(CANDIDATE→WATCHING→...→CLOSED)를 강제하고,
  상태 변경 시 SubscriptionRouter에 구독 변경 통보.

state:
  watchlist: dict[str, WatchlistEntry]   # symbol → entry
  status_counts: dict[str, int]          # status → count
  blacklist_expiry: dict[str, datetime]  # symbol → 해제 시각

lifecycle:
  startup: |
    1. WatchlistStore에서 기존 워치리스트 복원
    2. 블랙리스트 만료 확인 → 만료된 종목 CANDIDATE로 복원
    3. 상태 카운트 재계산
  execution: |
    이벤트 기반 — 4개 소스에서 이벤트 수신:
    a. Screener → promote() 호출 → CANDIDATE → WATCHING
    b. OrderExecutor → 체결 통보 → ENTRY_TRIGGERED → IN_POSITION
    c. PositionMonitor → 포지션 상태 동기화
    d. ExitExecutor → 청산 결과 → CLOSED → 재감시/블랙리스트
  shutdown: WatchlistStore에 전체 상태 영속화

internal_logic:
  state_transition_engine: |
    모든 상태 전이는 _validate_transition()을 거침.
    유효하지 않은 전이 시도 → TransitionError 발생 + AuditLog.
    
    def _validate_transition(symbol, current, target):
        ALLOWED = {
            "candidate": ["watching", "removed"],
            "watching": ["entry_triggered", "removed", "blacklisted"],
            "entry_triggered": ["in_position", "watching"],
            "in_position": ["exit_triggered"],
            "exit_triggered": ["closed"],
            "closed": ["watching", "blacklisted", "removed"],
            "blacklisted": ["candidate", "removed"],
        }
        if target not in ALLOWED.get(current, []):
            raise TransitionError(f"{current} → {target} forbidden")
  
  capacity_management: |
    max_watching = ConfigStore.max_watching (기본 30)
    max_in_position = ConfigStore.max_in_position (기본 10)
    
    WATCHING 초과 시:
    1. priority 최저 WATCHING 종목 자동 REMOVED
    2. 제거 시 SubscriptionRouter에 unsubscribe 통보
    
    IN_POSITION 초과 시:
    1. 신규 매수 신호 차단 (RiskGuard에서 거부)
  
  stale_cleanup: |
    cleanup_stale() — 매일 장 마감 후 실행
    max_watching_days 이상 WATCHING 상태인 종목 → REMOVED
    
  blacklist_management: |
    blacklist(symbol, duration_days, reason)
    1. 상태 → BLACKLISTED
    2. blacklist_expiry[symbol] = now + duration_days
    3. SubscriptionRouter에 unsubscribe
    4. 만료 시 자동 CANDIDATE 복원 (startup에서 확인)

  post_exit_logic: |
    ExitResult 수신 시:
    - 익절 or 첫 손절: → WATCHING (재감시, priority 유지)
    - 연속 2회 손절: → WATCHING (priority 하향 -20)
    - 연속 3회+ 손절: → BLACKLISTED (7일)
    - consecutive_losses는 WatchlistEntry에서 추적

ports_used:
  - WatchlistPort 전체 (11 메서드)

config_params:
  max_watching: 30
  max_in_position: 10
  stale_watching_days: 5
  blacklist_default_days: 7
  consecutive_loss_blacklist_threshold: 3

error_handling:
  - WatchlistStore 쓰기 실패: 메모리 상태 유지, 재시도 (3회), 알림
  - 잘못된 상태 전이 시도: TransitionError → AuditLog, 무시
  - 용량 초과: 최저 priority 자동 정리
```

---

### Node 03: SubscriptionRouter

```yaml
node_id: subscription_router
path: path1.1a
runMode: event
llm_level: L0
category: Core

description: |
  WatchlistManager의 상태 변경에 따라 MarketDataReceiver의
  실시간 시세 구독 목록을 동적으로 조정.
  IN_POSITION 종목은 절대 구독 해제 불가.

internal_logic:
  subscription_priority: |
    구독 우선순위:
    1. IN_POSITION (절대 보호)
    2. EXIT_TRIGGERED (청산 진행 중)
    3. ENTRY_TRIGGERED (매수 진행 중)
    4. WATCHING (높은 priority 먼저)
    
    max_subscriptions 초과 시 WATCHING의 lowest priority부터 해제.
  
  sync_logic: |
    sync_with_watchlist() — 5분 주기 또는 상태 변경 시 호출
    1. WATCHING + IN_POSITION + ENTRY_TRIGGERED + EXIT_TRIGGERED 종목 수집
    2. 현재 구독 목록과 diff
    3. 추가 필요: subscribe 이벤트 생성
    4. 제거 필요: unsubscribe 이벤트 생성
    5. 용량 초과: enforce_capacity() 호출

ports_used:
  - SubscriptionPort.apply_changes
  - SubscriptionPort.sync_with_watchlist
  - SubscriptionPort.enforce_capacity

config_params:
  max_subscriptions: 50
  sync_interval_seconds: 300
  priority_protect_in_position: true

error_handling:
  - WebSocket 구독 실패: 3회 재시도 → 실패 시 해당 종목 폴링 모드 전환
  - 구독 해제 실패: 무시 (다음 sync에서 재시도)
```

---

## SubPath 1B: Trade Execution

---

### Node 04: MarketDataReceiver

```yaml
node_id: market_data_receiver
path: path1.1b
runMode: stream
llm_level: L0
category: Infrastructure

description: |
  KIS WebSocket/REST로 실시간 시세를 수신하여 하위 노드에 분배.
  구독 목록은 SubscriptionRouter가 동적으로 관리.

internal_logic:
  tick_routing: |
    틱 수신 시 3개 대상에 동시 분배:
    1. IndicatorCalculator — 지표 계산 (모든 틱)
    2. PositionMonitor — 보유종목만 필터링
    3. Screener — 장중 실시간 스크리닝용 (배치, 30분 주기)
  
  adapter_fallback: |
    WebSocket 끊김 감지 (5회 연속):
    1. KISRestPollingAdapter로 자동 전환
    2. 폴링 간격: ConfigStore.poll_interval_seconds (기본 3초)
    3. WebSocket 복구 시도: 30초마다
    4. 복구 성공 시 WebSocket으로 자동 복귀
  
  data_quality: |
    - 동일 timestamp 중복 틱 제거
    - 전일 종가 대비 ±31% 이상 변동 → 이상 데이터 의심 → 경고 로깅
    - 3초 이상 틱 미수신 종목 → stale 경고

ports_used:
  - MarketDataPort 전체 (9 메서드)

config_params:
  poll_interval_seconds: 3
  stale_tick_threshold_seconds: 3
  max_price_deviation_pct: 31
  websocket_reconnect_interval_seconds: 30

error_handling:
  - WebSocket 끊김: 자동 fallback + 알림
  - REST 폴링 실패: 지수 백오프 재시도
  - 비정상 시세: 경고 로깅, 해당 틱은 전달하되 플래그 표시
```

---

### Node 05: IndicatorCalculator

```yaml
node_id: indicator_calculator
path: path1.1b
runMode: event
llm_level: L0
category: Core

description: |
  수신된 틱에 대해 기술지표를 계산하여 StrategyEngine에 전달.
  pandas-ta 기반. 종목별 지표 버퍼 유지.

internal_logic:
  indicator_pipeline: |
    틱 수신 → 종목별 OHLCV 버퍼에 append → 지표 계산 → IndicatorResult 생성
    
    기본 지표 세트 (ConfigStore에서 추가/제거 가능):
    - MA: 5, 10, 20, 60, 120
    - RSI: 14
    - MACD: 12, 26, 9
    - Bollinger Bands: 20, 2
    - ATR: 14
    - Volume MA: 20
    - 체결강도: 매수체결량 / 매도체결량
  
  buffer_management: |
    종목별 최근 200봉 유지 (메모리).
    장 시작 시 MarketDataStore에서 과거 200봉 프리로드.
    장 마감 후 버퍼 초기화.

output_type: |
  @dataclass(frozen=True)
  class IndicatorResult:
      symbol: str
      timestamp: datetime
      price: int
      indicators: dict
      # {"ma_5": 71500, "ma_20": 70200, "rsi_14": 62.3,
      #  "macd": 350, "macd_signal": 280, "macd_hist": 70,
      #  "bb_upper": 73000, "bb_lower": 67400,
      #  "atr_14": 1200, "volume_ma_20": 5000000,
      #  "volume_ratio": 1.8}

config_params:
  buffer_size: 200
  indicator_set: ["ma", "rsi", "macd", "bbands", "atr", "volume_ma"]
  ma_periods: [5, 10, 20, 60, 120]

error_handling:
  - 버퍼 부족 (200봉 미만): 계산 가능한 지표만 전달, 나머지 null
  - pandas-ta 계산 오류: 해당 지표 null 처리, 에러 로깅
```

---

### Node 06: StrategyEngine

```yaml
node_id: strategy_engine
path: path1.1b
runMode: event
llm_level: L0
category: Core

description: |
  지표와 시장 컨텍스트를 종합하여 매매 신호(SignalOutput)를 생성.
  여러 전략이 동시에 로딩되어 각각 독립적으로 판단.
  StrategyLoader(Path 3)에서 로딩된 전략 인스턴스 사용.

internal_logic:
  strategy_execution: |
    IndicatorResult 수신 시:
    1. 로딩된 전략 인스턴스 목록 순회
    2. 각 전략에 (IndicatorResult + MarketContext) 전달
    3. 전략이 SignalOutput 반환 (buy/sell/hold)
    4. hold 아닌 신호만 필터링
    5. 복수 전략 신호 → Path 4 ConflictResolver로 전달
       단일 전략 신호 → 직접 RiskGuard로 전달
  
  market_context_integration: |
    MarketIntelStore에서 MarketContext 조회 (ConfigRef):
    - entry_safe == false면 매수 신호 억제 (매도는 통과)
    - exit_urgent == true면 긴급 청산 플래그 추가
    - vi_active == true면 해당 종목 신호 보류
  
  strategy_hot_reload: |
    StrategyLoader가 새 전략 배포 시 instance_id로 교체.
    실행 중인 전략은 현재 틱 처리 완료 후 교체.

config_params:
  max_concurrent_strategies: 5
  signal_cooldown_seconds: 60     # 동일 종목 연속 신호 억제
  market_context_cache_seconds: 5 # MarketContext 캐시

error_handling:
  - 전략 실행 오류: 해당 전략 무시, 에러 로깅, 다른 전략 계속
  - 전략 타임아웃 (>50ms): 해당 틱 결과 폐기, 다음 틱에 재시도
  - MarketContext 조회 실패: 최근 캐시 사용, 없으면 entry_safe=true 가정
```

---

### Node 07: RiskGuard

```yaml
node_id: risk_guard
path: path1.1b
runMode: event
llm_level: L0
category: Core

description: |
  매매 신호를 주문으로 변환하기 전 다단계 검증.
  Pre-Order 18항목 체크리스트 (order_lifecycle_spec 참조).
  Path 4 RiskBudgetManager와 협력.

internal_logic:
  validation_chain: |
    SignalOutput 수신 → 순차 검증:
    
    Step 1: 종목 검증 (Path 6 StockState)
      - is_tradable, vi_active, warning_level
      - 상한가/하한가 도달 여부
      - 호가단위 검증 + 자동 보정
      - 가격제한폭 범위 확인
    
    Step 2: 시장 환경 (Path 6 MarketContext)
      - 서킷브레이커/사이드카 확인
      - 업종 동향 확인
    
    Step 3: 자금 검증 (BrokerPort)
      - 매수: get_buyable_quantity() → 가능 수량 확인
      - 매도: get_sellable_quantity() → D+2 고려
      - 증거금률 확인
    
    Step 4: 포트폴리오 검증 (Path 4)
      - RiskBudgetManager.check_order() → 승인/축소/거부
      - 일일 손실 한도, 단일 종목 비중, 섹터 비중
    
    Step 5: 주문 유형 결정
      - 장중: LIMIT or MARKET (전략 지정)
      - 동시호가: CONDITIONAL (시장가 차단)
      - VI 발동 중: LIMIT only
    
    모든 Step 통과 → OrderRequest 생성 → DedupGuard로 전달
    어느 Step에서든 실패 → REJECTED + 사유 로깅

config_params:
  allow_margin_trading: false     # 미수 사용 여부
  max_single_order_amount: 50000000  # 단일 주문 최대 5천만원
  force_limit_on_vi: true         # VI 발동 시 지정가 강제

error_handling:
  - BrokerPort 가능수량 조회 실패: 안전 모드 (주문 보류, 다음 틱에 재시도)
  - Path 4 응답 타임아웃: 주문 보류 (안전 방향)
  - StockState 조회 실패: 최근 캐시, 없으면 주문 보류
```

---

### Node 08: DedupGuard

```yaml
node_id: dedup_guard
path: path1.1b
runMode: event
llm_level: L0
category: Core

description: |
  동일 종목 동일 방향의 중복 주문 방지.
  시간 윈도우 내 동일 주문 감지 시 차단.

internal_logic:
  dedup_logic: |
    키 생성: f"{symbol}_{side}_{strategy_id}"
    시간 윈도우: dedup_window_seconds (기본 60초)
    
    1. 키가 dedup_cache에 존재하고, 마지막 주문 시각 + window > 현재 → 차단
    2. 존재하지 않거나 윈도우 초과 → 통과, 캐시 갱신
    3. 차단 시 로깅 (중복 주문 시도 기록)

config_params:
  dedup_window_seconds: 60
  cache_max_entries: 1000
```

---

### Node 09: OrderExecutor

```yaml
node_id: order_executor
path: path1.1b
runMode: event
llm_level: L0
category: Core

description: |
  BrokerPort를 통해 KIS API 주문 실행.
  OrderTracker로 주문 상태 추적.
  WebSocket 체결통보 수신.

internal_logic:
  order_flow: |
    OrderRequest 수신:
    1. OrderTracker 생성 (state: DRAFT)
    2. state → VALIDATING (이미 RiskGuard에서 검증 완료이나 최종 확인)
    3. state → SUBMITTING
    4. BrokerPort.submit_order() 호출
    5. 응답 수신 → state → SUBMITTED (order_id 기록)
    6. WebSocket 체결통보 대기
    
    체결통보(H0STCNI0) 수신:
    - CNTG_YN=1 (접수): state → ACCEPTED
    - CNTG_YN=2 (체결): filled_qty 갱신, PARTIALLY_FILLED or FILLED
    - RFUS_YN=1 (거부): state → REJECTED
    - RCTF_CLS=1 (정정): 정정 결과 처리
    - RCTF_CLS=2 (취소): state → CANCELLED
  
  unknown_recovery: |
    5초 내 응답 없음 → UNKNOWN
    1. get_pending_orders() 호출
    2. order_id 존재 → SUBMITTED 복원
    3. 미존재 → 5초 후 재조회 (3회)
    4. 3회 실패 → REJECTED
  
  partial_fill_management: |
    부분 체결 시:
    - avg_fill_price 가중평균 재계산
    - remaining_qty 갱신
    - configurable 타임아웃 후 잔량 자동 취소
  
  circuit_breaker: |
    연속 3회 주문 실패 → Circuit Breaker OPEN
    - 신규 주문 차단
    - 기존 포지션 손절선 유지
    - 30초 후 half-open (1건 테스트)
    - 성공 시 CLOSED (정상 복귀)

config_params:
  submit_timeout_ms: 5000
  unknown_retry_count: 3
  unknown_retry_interval_ms: 5000
  partial_fill_timeout_minutes: 5
  circuit_breaker_threshold: 3
  circuit_breaker_recovery_seconds: 30

error_handling:
  - API 타임아웃: UNKNOWN 복구 프로세스
  - 인증 만료: 토큰 갱신 → 재시도
  - Rate limit: 지수 백오프
  - 서버 오류(5xx): 3회 재시도 → CB
```

---

### Node 10: TradingFSM

```yaml
node_id: trading_fsm
path: path1.1b
runMode: stateful-service
llm_level: L0
category: Core

description: |
  포지션 상태 관리. transitions 라이브러리 기반.
  Path 5 CommandController의 제어 명령도 수신.

states: [Idle, EntryPending, InPosition, ExitPending, Error, SafeMode]

transitions:
  - trigger: on_signal, source: Idle, dest: EntryPending
  - trigger: on_fill, source: EntryPending, dest: InPosition
  - trigger: on_reject, source: EntryPending, dest: Idle
  - trigger: on_exit_signal, source: InPosition, dest: ExitPending
  - trigger: on_exit_fill, source: ExitPending, dest: Idle
  - trigger: on_error, source: "*", dest: Error
  - trigger: on_halt, source: "*", dest: SafeMode
  - trigger: on_resume, source: SafeMode, dest: Idle
  - trigger: on_recover, source: Error, dest: Idle

config_params:
  state_persist_interval_seconds: 10  # 주기적 상태 저장
```

---

### Node 11–13: PositionMonitor, ExitConditionGuard, ExitExecutor

```yaml
# Node 11: PositionMonitor
node_id: position_monitor
path: path1.1c
runMode: stream
llm_level: L0

description: |
  보유종목의 실시간 손익을 틱마다 갱신.
  highest_price (trailing stop용), drawdown 추적.
  OrderExecutor에서 체결 통보 수신 시 신규 포지션 등록.

internal_logic:
  tick_update: |
    틱 수신 시 (MarketDataReceiver → 보유종목 필터링됨):
    1. current_price 갱신
    2. unrealized_pnl = (current_price - avg_entry_price) * quantity
    3. unrealized_pnl_pct = (current_price / avg_entry_price - 1) * 100
    4. highest_price = max(highest_price, current_price)
    5. drawdown_from_high_pct = (current_price / highest_price - 1) * 100
    6. holding_seconds 갱신
    7. LivePosition → ExitConditionGuard에 전달

---

# Node 12: ExitConditionGuard
node_id: exit_condition_guard
path: path1.1c
runMode: event
llm_level: L0

description: |
  보유종목에 대한 청산 조건 실시간 감시.
  손절/익절/트레일링/시간/VI/강제 6가지 조건.

internal_logic:
  evaluation_order: |
    LivePosition 수신 시 — 우선순위 순으로 조건 평가:
    1. FORCE_CLOSE (마감 임박, 거래정지 예고) → 즉시
    2. STOP_LOSS (손절) → urgent
    3. TRAILING_STOP (추적 손절) → urgent
    4. TAKE_PROFIT (익절) → normal
    5. TIME_LIMIT (보유 시간 초과) → normal
    6. STRATEGY_EXIT (전략 자체 청산 신호) → normal
    
    MarketIntelStore 참조:
    - vi_active → 시장가 청산 보류, VI 해제 후 재평가
    - is_ex_dividend → 손절 기준가를 배당락 조정가로 보정
    - sector_trend == "down" → 손절 기준 강화 (선택)

---

# Node 13: ExitExecutor
node_id: exit_executor
path: path1.1c
runMode: event
llm_level: L0

description: |
  ExitSignal을 OrderRequest(side=SELL)로 변환하여
  SubPath 1B의 RiskGuard에 재진입.
  청산 후 WatchlistManager에 결과 통보.

internal_logic:
  exit_order_creation: |
    ExitSignal 수신:
    1. urgency 판단:
       - "immediate": MARKET 주문 (마감 임박, 거래정지 예고)
       - "urgent": MARKET 주문 (손절)
       - "normal": LIMIT 주문 (익절, suggested_price 사용)
    2. OrderRequest(side=SELL) 생성
    3. RiskGuard로 전달 (SubPath 1B 재진입)
    4. 체결 결과 대기
    5. ExitResult 생성 → WatchlistManager에 통보
  
  post_action: |
    determine_post_action():
    - exit_type == TAKE_PROFIT: "return_to_watchlist"
    - consecutive_losses < 3: "return_to_watchlist"
    - consecutive_losses >= 3: "blacklist"
```

---

## Path 1 Blueprint 요약

| 노드 | 핵심 내부 로직 | 주요 의존 |
|------|-------------|----------|
| Screener | 조건 필터링 + 실시간 순위 | MarketDataStore, KIS 순위 API |
| WatchlistManager | 8단계 상태 전이 + 용량 관리 | WatchlistStore |
| SubscriptionRouter | 구독 동적 관리 + 우선순위 보호 | MarketDataReceiver |
| MarketDataReceiver | WebSocket→REST fallback + 틱 라우팅 | KIS WebSocket/REST |
| IndicatorCalculator | pandas-ta 파이프라인 + 200봉 버퍼 | — |
| StrategyEngine | 멀티 전략 실행 + MarketContext 통합 | Path 3 StrategyLoader, MarketIntelStore |
| RiskGuard | Pre-Order 18항목 + Path 4 협력 | Path 4, Path 6, BrokerPort |
| DedupGuard | 시간 윈도우 중복 감지 | — |
| OrderExecutor | OrderTracker + H0STCNI0 파싱 + CB | BrokerPort (WebSocket) |
| TradingFSM | transitions 기반 6상태 FSM | — |
| PositionMonitor | 틱별 손익/drawdown 갱신 | MarketDataReceiver |
| ExitConditionGuard | 6종 청산 조건 우선순위 평가 | MarketIntelStore |
| ExitExecutor | 청산→주문 변환 + 1B 재진입 | RiskGuard |

---

*End of Document — Node Blueprint Path 1 v1.0*
*13 Nodes | 각 노드별 lifecycle, internal_logic, config_params, error_handling 정의*
