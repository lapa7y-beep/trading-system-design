# Node Blueprint Catalog — Path 2~6

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | node_blueprint_path2to6_v1.0 |
| 선행 문서 | system_manifest_v1.0, node_blueprint_path1_v1.0, port_interface_path2~6 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |
| 대상 | Path 2(6) + Path 3(7) + Path 4(6) + Path 5(6) + Path 6(5) = 30개 노드 |

---

## Path 2: Knowledge Building (6 nodes)

### Node 14: ExternalCollector

```yaml
node_id: external_collector
runMode: batch
llm_level: L0
trigger: KnowledgeScheduler 명령 또는 ConfigStore 스케줄
flow: |
  1. ConfigStore에서 수집 대상 (소스 타입, 종목 코드, since 시점) 로드
  2. DataSourcePort.collect() 호출 — DART 공시, 뉴스 등
  3. 중복 문서 필터링 (source_id 기반)
  4. RawDocument 리스트 → DocumentParser로 전달
adapters: DARTAdapter, NaverNewsAdapter, RSSFeedAdapter
error: API 장애 시 건너뜀 + 다음 주기에 재시도, rate limit 준수 (DART 분당 100건)
```

### Node 15: DocumentParser

```yaml
node_id: document_parser
runMode: batch
llm_level: L1
flow: |
  1. RawDocument 수신
  2. source_type별 파서 선택:
     - DART_FILING: RegexParser (정규식 1차) → LLM 2차 보정
     - NEWS_ARTICLE: LLM 기반 엔티티/관계 추출
  3. ParsedDocument 생성 (entities, relations, summary, sentiment)
  4. SchemaValidator로 결과 검증
  5. OntologyMapper로 전달
adapters: HybridParserAdapter (정규식 + LLM)
fallback: LLM 장애 시 정규식 결과만 전달 (confidence 낮음 표시)
config: llm_concurrency=5, max_tokens_per_doc=2000
```

### Node 16: OntologyMapper

```yaml
node_id: ontology_mapper
runMode: batch (agent 내부)
llm_level: L1
agent_spec: true (LangGraph)
flow: |
  1. ParsedDocument의 entities/relations 수신
  2. 기존 온톨로지와 매칭 (중복 엔티티 병합)
  3. LLM으로 관계 정제 (synonyms 해소, 타입 추론)
  4. OntologyTriple 생성
  5. ConsistencyGuard: 순환 참조/모순 감지
  6. OntologyPort.upsert_triples() → KnowledgeStore
  7. ParsedDocument + Triples → KnowledgeIndex로 전달
llm_task: ontology_mapping (Local Gemma4)
max_iterations: 5
terminal: confidence >= 0.7 or iterations >= 5
```

### Node 17: CausalReasoner

```yaml
node_id: causal_reasoner
runMode: agent
llm_level: L2
agent_spec: true (LangGraph — 핵심)
flow: |
  1. 신규 OntologyTriple 수신
  2. 관련 기존 트리플 조회 (get_neighbors, depth=2)
  3. LLM에게 인과관계 추론 요청:
     "삼성전자의 HBM 매출 증가 → SK하이닉스 경쟁 심화 → 가격 인하 가능성?"
  4. CausalLink 생성 (cause, effect, mechanism, strength, temporal_lag)
  5. confidence 평가 → 0.8 이상이면 종료, 미만이면 추가 소스 탐색
  6. KnowledgeStore에 CausalLink 저장
  7. KnowledgeIndex에 인과관계 인덱싱
llm_task: causal_reasoning (Claude Sonnet)
max_iterations: 5
checkpointer: postgresql
state_schema: {sources_collected, reasoning_chain, confidence, iteration_count}
```

### Node 18: KnowledgeIndex

```yaml
node_id: knowledge_index
runMode: stateful-service
llm_level: L0
flow: |
  1. ParsedDocument + OntologyTriple + CausalLink 수신
  2. SearchIndexPort.index_document() — FTS + 임베딩 인덱싱
  3. 다른 Path에서 SearchIndexPort.search() 호출 시 결과 반환
  4. 주기적 reindex_all() — 온톨로지 스키마 변경 시
adapters: PostgresFTSAdapter (pgvector)
```

### Node 19: KnowledgeScheduler

```yaml
node_id: knowledge_scheduler
runMode: event
llm_level: L0
flow: |
  1. ConfigStore에서 수집 스케줄 로드
  2. cron 표현식 기반 ExternalCollector 트리거
  3. 수집 → 파싱 → 매핑 → 추론 파이프라인 오케스트레이션
  4. 실패 단계 재시도 (단계별 독립)
config: schedule_cron="0 6 * * 1-5" (평일 06:00), retry_failed_steps=true
```

---

## Path 3: Strategy Development (7 nodes)

### Node 20: StrategyCollector

```yaml
node_id: strategy_collector
runMode: event
llm_level: L1
agent_spec: true
flow: |
  1. KnowledgeStore에서 인과관계 트리플 조회
  2. 시장 이벤트/뉴스에서 전략 아이디어 후보 추출
  3. LLM이 아이디어를 StrategyIdea 포맷으로 구조화
  4. StrategyGenerator에 전달
llm_task: idea_generation (Claude Sonnet)
max_iterations: 3
```

### Node 21: StrategyGenerator

```yaml
node_id: strategy_generator
runMode: batch
llm_level: L2
agent_spec: true
flow: |
  1. StrategyIdea 수신
  2. LLM이 Python 전략 코드 생성 (StrategyPort 규격 준수)
  3. CodeSandbox에서 구문 검증 (AST 파싱, 금지 패턴 차단)
  4. SyntaxValidator 통과 시 StrategyMeta + StrategyCode 생성
  5. StrategyRegistry에 등록 (status: DRAFT)
safety: |
  - import 제한: pandas, numpy, pandas_ta, talib만 허용
  - 네트워크/파일 접근 금지
  - 실행 시간 제한: 10초
```

### Node 22: StrategyRegistry

```yaml
node_id: strategy_registry
runMode: stateful-service
llm_level: L0
flow: |
  1. 전략 CRUD — StrategyRepositoryPort 사용
  2. 상태 전이 관리: DRAFT → BACKTESTED → OPTIMIZED → APPROVED → DEPLOYED → RETIRED
  3. VersionGuard: DEPLOYED 전략 덮어쓰기 방지
  4. 전략 배포 시 StrategyLoader에 통보
adapters: PostgresStrategyAdapter
```

### Node 23: StrategyLoader

```yaml
node_id: strategy_loader
runMode: poll
llm_level: L0
flow: |
  1. StrategyStore 폴링 — APPROVED/DEPLOYED 전략 목록 확인
  2. 신규/변경 전략 감지 시 StrategyRuntimePort.load()
  3. 로딩된 인스턴스를 Path 1 StrategyEngine에 전달
  4. 핫 리로드: 파라미터 변경 시 hot_reload() (코드 변경은 재배포)
config: poll_interval_seconds=30, max_loaded=5
safety: checksum 검증 실패 → 로딩 거부
```

### Node 24: BacktestEngine

```yaml
node_id: backtest_engine
runMode: batch
llm_level: L0
flow: |
  1. BacktestConfig 수신 (전략 ID, 기간, 종목, 초기 자본)
  2. MarketDataHistoryPort에서 OHLCV 데이터 로드
  3. 전략 코드를 이벤트 기반으로 시뮬레이션
  4. MockBroker + SimClock으로 체결 시뮬레이션
  5. BacktestResult 생성 (수익률, 샤프, MDD, 거래 목록, 자산 곡선)
  6. DataLeakageGuard: 미래 데이터 참조 차단
  7. ResourceLimiter: CPU/메모리/시간 상한
adapters: InternalBacktestAdapter (pandas + asyncio)
config: max_concurrent=4, timeout_seconds=300
```

### Node 25: Optimizer

```yaml
node_id: optimizer
runMode: batch
llm_level: L1
flow: |
  1. OptimizationConfig 수신 (파라미터 범위, 방법, 목표)
  2. Optuna Study 생성
  3. 각 trial → BacktestEngine.run_batch()
  4. 최적 파라미터 + 과적합 점수 계산
  5. OptimizationResult → StrategyRegistry에 저장
adapters: OptunaAdapter (TPESampler + MedianPruner)
config: max_trials=100, pruner=MedianPruner
```

### Node 26: StrategyEvaluator

```yaml
node_id: strategy_evaluator
runMode: batch
llm_level: L1
agent_spec: true
flow: |
  1. BacktestResult 수신
  2. 정량 평가: sharpe > 1.5, MDD < 20%, win_rate > 45%
  3. LLM 보조 해석: 과적합 위험, 시장 국면 편향, 개선 제안
  4. 평가 결과 → StrategyRegistry에 상태 업데이트
llm_task: result_interpretation (Local Gemma4)
```

---

## Path 4: Portfolio Management (6 nodes)

### Node 27: PositionAggregator

```yaml
node_id: position_aggregator
runMode: poll
llm_level: L0
flow: |
  1. PortfolioStore에서 전 전략 포지션 집계
  2. MarketDataStore에서 현재가 조회 → 시가 평가
  3. PortfolioSnapshot 생성 (total_equity, cash, positions, daily_pnl)
  4. 포지션 변동 시 RiskBudgetManager, AllocationEngine에 전달
  5. BrokerPort.get_account()와 주기적 대조 (Reconciliation)
config: poll_interval_seconds=10, reconcile_interval_minutes=5
```

### Node 28: RiskBudgetManager

```yaml
node_id: risk_budget_manager
runMode: stateful-service
llm_level: L0
flow: |
  1. PortfolioSnapshot 기반 현재 리스크 노출도 계산
  2. Path 1 RiskGuard에서 check_order() 요청 수신
  3. 한도 검증: 일일 손실, 단일 종목 비중, 섹터 비중, 전략 배분
  4. APPROVED / REDUCED / REJECTED / HALTED 반환
  5. 일일 손실 한도 도달 시 자동 halt_trading()
state: current_exposure, daily_loss_pct, trade_count_today
config: max_portfolio_loss_pct=-5, max_single_position_pct=20, max_daily_trades=50
```

### Node 29: ConflictResolver

```yaml
node_id: conflict_resolver
runMode: event
llm_level: L0
flow: |
  1. Path 1 StrategyEngine에서 복수 전략 신호 수신
  2. 동일 종목 상충 신호 감지 (전략A=매수, 전략B=매도)
  3. 해소 방법: WEIGHTED (가중 합산, 기본) or PRIORITY (우선순위)
  4. ResolvedAction 생성 → AllocationEngine에 전달
config: default_method=weighted, strategy_priorities={ma_cross:1, breakout:2}
```

### Node 30: Rebalancer

```yaml
node_id: rebalancer
runMode: batch
llm_level: L1
flow: |
  1. 주기적 (ConfigStore.rebalance_schedule) 또는 drift 임계값 초과 시 트리거
  2. 목표 배분 대비 현재 이탈도 계산
  3. 리밸런싱 주문 목록 생성
  4. AllocationEngine에 전달
config: rebalance_drift_pct=5, schedule="weekly"
```

### Node 31: PerformanceAnalyzer

```yaml
node_id: performance_analyzer
runMode: batch
llm_level: L1
agent_spec: true
flow: |
  1. PortfolioStore에서 PnL 이력, 체결 기록 조회
  2. 정량 분석: return, sharpe, MDD, win_rate, attribution (전략별/섹터별)
  3. LLM 보조: 개선 제안, 과적합 감지, 리스크 경고
  4. PerformanceReport 생성 → PortfolioStore 저장 + 알림
llm_task: composite_judgment (Claude Sonnet)
config: report_schedule=weekly
```

### Node 32: AllocationEngine

```yaml
node_id: allocation_engine
runMode: event
llm_level: L0
flow: |
  1. ConflictResolver에서 ResolvedAction 수신 (또는 Rebalancer에서 트리거)
  2. 전략별 목표 배분 비율 참조
  3. 포지션 사이징: VolatilityTarget or FixedPct or Kelly
  4. SizingResult → RiskBudgetManager에 검증 요청
  5. 승인 시 최종 수량 확정 → Path 1 RiskGuard로 전달
config: target_volatility_pct=15, min_cash_pct=10
```

---

## Path 5: Watchdog & Operations (6 nodes)

### Node 33: HealthMonitor

```yaml
node_id: health_monitor
runMode: poll
llm_level: L0
flow: |
  1. 등록된 모든 컴포넌트 병렬 헬스체크 (30초 주기)
  2. 응답 지연, 에러율, 메모리 사용량 추적
  3. UNHEALTHY 3회 연속 → AlertDispatcher에 통보 + Circuit Breaker 고려
config: check_interval_seconds=30, unhealthy_threshold=3, timeout_ms=5000
```

### Node 34: AuditLogger

```yaml
node_id: audit_logger
runMode: stream
llm_level: L0
flow: |
  1. 전 Path에서 AuditEvent 수신 (fire-and-forget)
  2. AuditPort.log() → PostgreSQL append-only 테이블
  3. AnomalyDetector에 실시간 스트리밍
  4. DailyReporter에 일일 집계 데이터 제공
safety: DELETE/UPDATE 트리거로 불변 보장
```

### Node 35: AnomalyDetector

```yaml
node_id: anomaly_detector
runMode: event
llm_level: L1
flow: |
  1. AuditLogger에서 이벤트 스트림 수신
  2. 시간 윈도우(5분) 기반 패턴 분석
  3. 이상 감지: 급속 주문, 연속 손실, 에러율 급증, 포지션 불일치
  4. Anomaly → AlertDispatcher에 통보
config: window_minutes=5, z_score_threshold=3
```

### Node 36: AlertDispatcher

```yaml
node_id: alert_dispatcher
runMode: event
llm_level: L0
flow: |
  1. HealthMonitor, AnomalyDetector, DailyReporter에서 알림 수신
  2. AlertPriority에 따라 채널 라우팅:
     - LOW: console
     - MEDIUM: telegram
     - HIGH: telegram + discord
     - CRITICAL: telegram + discord + 반복 (확인까지)
  3. 발송 이력 저장
adapters: TelegramAlertAdapter, DiscordAlertAdapter
```

### Node 37: CommandController

```yaml
node_id: command_controller
runMode: stateful-service
llm_level: L0
flow: |
  1. Telegram Bot에서 명령 수신
  2. AuthGuard: 허용된 사용자 (jdw) 확인
  3. RiskLevelGate: 명령 리스크 레벨 판단
     - READ_ONLY (status, positions): 즉시 실행
     - LOW (halt_trading, reload_config): 로깅 후 실행
     - MEDIUM (deploy_strategy, update_params): 확인 후 실행
     - HIGH (close_position): 승인 요청
     - CRITICAL (close_all): 이중 인증 + 승인
  4. 실행 결과 → AuditLogger + 응답
config: authorized_users=["jdw"], approval_timeout_minutes=30
```

### Node 38: DailyReporter

```yaml
node_id: daily_reporter
runMode: batch
llm_level: L1
flow: |
  1. 장 마감 후 (16:00) 자동 실행
  2. AuditStore에서 당일 이벤트 집계
  3. PortfolioStore에서 손익 요약
  4. MarketIntelStore에서 시장 환경 요약
  5. LLM으로 자연어 리포트 생성 (일일/주간)
  6. AlertDispatcher를 통해 발송
config: report_time="16:00", format=["daily", "weekly_on_friday"]
```

---

## Path 6: Market Intelligence (5 nodes)

### Node 39: SupplyDemandAnalyzer

```yaml
node_id: supply_demand_analyzer
runMode: poll
llm_level: L0
flow: |
  1. KIS 투자자매매동향 API 호출 (1분 주기)
  2. 외국인/기관/개인/프로그램매매 순매수 집계
  3. 공매도 비율, 신용잔고율 조회
  4. 체결강도 계산 (매수체결량/매도체결량)
  5. SupplyDemandSnapshot → MarketIntelStore
  6. 수급 반전 감지: 방향 전환, 대량 매매 → SupplyDemandSignal
kis_api: |
  - investor-trade-by-stock-daily (FHPTJ04160001)
  - program-trade-by-stock (FHPPG04650101)
  - daily-short-sale (FHPST04830000)
  - daily-credit-balance (FHPST04760000)
  - bulk-trans-num (FHKST190900C0)
config: poll_interval_seconds=60, bulk_threshold_volume=10000
```

### Node 40: OrderBookAnalyzer

```yaml
node_id: orderbook_analyzer
runMode: stream
llm_level: L0
flow: |
  1. KIS WebSocket H0STASP0 (실시간 호가) 수신
  2. 매수/매도 잔량 비율 계산
  3. 스프레드 분석 (bps, 정상 범위 판단)
  4. 대형 매도벽/매수벽 감지 (잔량 상위 호가 집중도)
  5. 유동성 점수 계산
  6. OrderBookAnalysis → MarketIntelStore
  7. KIS pbar-tratio API로 매물대 분포 조회 (5분 주기)
kis_api: |
  - WebSocket H0STASP0 (실시간 호가)
  - inquire-asking-price-exp-ccn (FHKST01010200)
  - pbar-tratio (FHPST01130000)
config: spread_alert_bps=50, wall_threshold_ratio=3.0
```

### Node 41: MarketRegimeDetector

```yaml
node_id: market_regime_detector
runMode: event
llm_level: L0
flow: |
  1. KIS WebSocket H0STMKO0 (장운영정보) 수신 — CB/VI/사이드카 실시간 감지
  2. 업종 지수 API 주기 폴링 (ConfigStore 지정 업종)
  3. MarketRegime 판단:
     - KOSPI 8% 하락 → CIRCUIT_BREAKER_1
     - VI 발동 → vi_stocks 목록 갱신
     - 사이드카 → SIDECAR
  4. MarketEnvironment → MarketIntelStore
  5. 긴급 변경(CB/VI) → Path 1에 Event Edge로 즉시 통보
kis_api: |
  - WebSocket H0STMKO0 (장운영정보)
  - inquire-vi-status (FHPST01390000)
  - inquire-index-price (FHPUP02100000)
  - inquire-index-category-price (FHPUP02140000)
config: sector_codes=["0001","1001","0028","0017","0024"], volatility_threshold=2.0
```

### Node 42: StockStateMonitor

```yaml
node_id: stock_state_monitor
runMode: poll
llm_level: L0
flow: |
  1. 워치리스트 + 보유 종목 대상으로 상태 조회 (5분 주기)
  2. KIS 종목정보 API → 거래정지, 투자경고/위험, 신용가능, 증거금률
  3. 호가단위 계산 (KRX 테이블 기반, 로컬)
  4. 상한가/하한가 계산 (전일 종가 ± 30%)
  5. KIS 예탁원 API → 기업 이벤트 조회 (배당, 증자, 분할 등)
  6. StockState → MarketIntelStore
  7. 상태 변경 시 (거래정지, VI) → 콜백 통보
kis_api: |
  - search-stock-info (CTPF1002R) — 종목 상태 종합
  - credit-by-company (FHPST04770000) — 신용 가능
  - 예탁원 API 7종 (dividend, bonus-issue 등)
config: check_interval_seconds=300, event_lookahead_days=5
```

### Node 43: ConditionSearchBridge

```yaml
node_id: condition_search_bridge
runMode: batch
llm_level: L0
flow: |
  1. KIS HTS 조건검색 API → 사전 등록 조건 목록 조회
  2. 각 조건 실행 → 종목 목록 수신 (최대 100건)
  3. KIS 순위 API 20종+ → 등락률, 거래량, 체결강도 등
  4. 관심종목 그룹 API → HTS 등록 관심종목 동기화
  5. ConditionResult → MarketIntelStore
  6. Path 1 Screener의 보조 데이터로 제공
  7. Path 3 StrategyCollector의 아이디어 소스로 제공
kis_api: |
  - psearch-title (HHKST03900300)
  - psearch-result (HHKST03900400)
  - volume-rank, fluctuation, volume-power, market-cap 등 20개 순위 API
  - intstock-grouplist (HHKCM113004C7)
  - intstock-stocklist-by-group (HHKCM113004C6)
  - intstock-multprice (FHKST11300006)
config: hts_user_id=${KIS_HTS_USER_ID}, scan_interval_minutes=30
```

---

## MarketContext 조합 로직

Path 6의 5개 노드가 각각 MarketIntelStore에 저장한 데이터를 종합하여 종목별 MarketContext를 생성하는 로직. 별도 노드가 아닌 **MarketIntelStore의 materialized view 또는 캐시 갱신 트리거**로 구현.

```python
async def build_market_context(symbol: str) -> MarketContext:
    sd = await supply_demand_store.get(symbol)       # Node 39
    ob = await orderbook_store.get(symbol)            # Node 40
    env = await market_regime_store.get_latest()       # Node 41
    state = await stock_state_store.get(symbol)        # Node 42
    sector = next(s for s in env.sectors if s.sector_code == state.sector_code)

    entry_safe = (
        state.is_tradable
        and not state.vi_active
        and state.warning_level == "none"
        and not state.at_upper_limit
        and env.regime == MarketRegime.NORMAL
        and ob.spread_normal
        and sd.volume_power > 80  # 체결강도 80% 이상
    )
    
    exit_urgent = (
        not state.is_tradable           # 거래정지
        or env.regime.startswith("cb")  # 서킷브레이커
        or state.warning_level == "danger"
    )
    
    caution_reasons = []
    if sd.foreign_net_buy < -100000: caution_reasons.append("외국인 대량 순매도")
    if ob.large_sell_wall: caution_reasons.append("대형 매도벽 존재")
    if sector.change_pct < -2.0: caution_reasons.append(f"업종 급락 {sector.change_pct}%")
    if state.is_ex_dividend: caution_reasons.append("배당락일")
    
    return MarketContext(
        symbol=symbol, timestamp=datetime.now(),
        foreign_net_buy=sd.foreign_net_buy,
        institution_net_buy=sd.institution_net_buy,
        program_net_buy=sd.program_net_buy,
        volume_power=sd.volume_power,
        short_sale_ratio=sd.short_sale_ratio,
        credit_balance_ratio=sd.credit_balance_ratio,
        bid_ask_ratio=ob.bid_ask_ratio,
        spread_bps=ob.spread_bps,
        spread_normal=ob.spread_normal,
        large_sell_wall=ob.large_sell_wall,
        is_tradable=state.is_tradable,
        vi_active=state.vi_active,
        warning_level=state.warning_level,
        is_ex_dividend=state.is_ex_dividend,
        at_upper_limit=state.at_upper_limit,
        at_lower_limit=state.at_lower_limit,
        sector_trend="down" if sector.change_pct < -1 else "up" if sector.change_pct > 1 else "flat",
        sector_change_pct=sector.change_pct,
        market_regime=env.regime.value,
        kospi_change_pct=env.kospi_change_pct,
        entry_safe=entry_safe,
        exit_urgent=exit_urgent,
        caution_reasons=caution_reasons,
    )
```

---

## 전체 43개 노드 요약 매트릭스

| # | Node | Path | runMode | LLM | 핵심 로직 |
|---|------|------|---------|-----|----------|
| 1 | Screener | 1A | batch | L0 | 조건 필터링 + KIS 순위 |
| 2 | WatchlistManager | 1A | stateful | L0 | 8단계 상태 전이 허브 |
| 3 | SubscriptionRouter | 1A | event | L0 | 구독 동적 관리 |
| 4 | MarketDataReceiver | 1B | stream | L0 | WS→REST fallback |
| 5 | IndicatorCalculator | 1B | event | L0 | pandas-ta 파이프라인 |
| 6 | StrategyEngine | 1B | event | L0 | 멀티 전략 + MarketContext |
| 7 | RiskGuard | 1B | event | L0 | Pre-Order 18항목 |
| 8 | DedupGuard | 1B | event | L0 | 시간 윈도우 중복 감지 |
| 9 | OrderExecutor | 1B | event | L0 | OrderTracker + CB |
| 10 | TradingFSM | 1B | stateful | L0 | transitions 6상태 |
| 11 | PositionMonitor | 1C | stream | L0 | 틱별 손익/drawdown |
| 12 | ExitConditionGuard | 1C | event | L0 | 6종 청산 조건 |
| 13 | ExitExecutor | 1C | event | L0 | 청산→1B 재진입 |
| 14 | ExternalCollector | 2 | batch | L0 | DART/뉴스 수집 |
| 15 | DocumentParser | 2 | batch | L1 | 정규식+LLM 파싱 |
| 16 | OntologyMapper | 2 | agent | L1 | 트리플 매핑 |
| 17 | CausalReasoner | 2 | agent | L2 | 인과 추론 |
| 18 | KnowledgeIndex | 2 | stateful | L0 | FTS+pgvector |
| 19 | KnowledgeScheduler | 2 | event | L0 | 파이프라인 오케스트레이션 |
| 20 | StrategyCollector | 3 | event | L1 | 아이디어 수집 |
| 21 | StrategyGenerator | 3 | batch | L2 | 코드 자동 생성 |
| 22 | StrategyRegistry | 3 | stateful | L0 | 전략 CRUD+버전 |
| 23 | StrategyLoader | 3 | poll | L0 | 런타임 동적 로딩 |
| 24 | BacktestEngine | 3 | batch | L0 | 이벤트 기반 시뮬 |
| 25 | Optimizer | 3 | batch | L1 | Optuna 최적화 |
| 26 | StrategyEvaluator | 3 | batch | L1 | 결과 해석 |
| 27 | PositionAggregator | 4 | poll | L0 | 포지션 집계 |
| 28 | RiskBudgetManager | 4 | stateful | L0 | 리스크 한도 |
| 29 | ConflictResolver | 4 | event | L0 | 충돌 해소 |
| 30 | Rebalancer | 4 | batch | L1 | 리밸런싱 |
| 31 | PerformanceAnalyzer | 4 | batch | L1 | 성과 귀인 |
| 32 | AllocationEngine | 4 | event | L0 | 포지션 사이징 |
| 33 | HealthMonitor | 5 | poll | L0 | 헬스체크 |
| 34 | AuditLogger | 5 | stream | L0 | 불변 로깅 |
| 35 | AnomalyDetector | 5 | event | L1 | 이상 감지 |
| 36 | AlertDispatcher | 5 | event | L0 | 다채널 알림 |
| 37 | CommandController | 5 | stateful | L0 | 운영 명령 |
| 38 | DailyReporter | 5 | batch | L1 | 일일 리포트 |
| 39 | SupplyDemandAnalyzer | 6 | poll | L0 | 수급 분석 |
| 40 | OrderBookAnalyzer | 6 | stream | L0 | 호가 분석 |
| 41 | MarketRegimeDetector | 6 | event | L0 | CB/VI/사이드카 |
| 42 | StockStateMonitor | 6 | poll | L0 | 종목 상태 |
| 43 | ConditionSearchBridge | 6 | batch | L0 | KIS 조건검색 |

---

*End of Document — Node Blueprint Path 2~6 v1.0*
*30 Nodes | 각 노드별 flow, internal_logic, KIS API 매핑, config, error handling*
*MarketContext 조합 로직 포함*
