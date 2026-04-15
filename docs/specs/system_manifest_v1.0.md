# System Manifest — HR-DAG Trading System

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | system_manifest_v1.0 |
| 선행 문서 | port_interface_path1~6, edge_contract, order_lifecycle_spec, graph_ir_agent_extension |
| 작성일 | 2026-04-15 |
| 상태 | Draft |

---

## 1. 아키텍처 요약

```
6 Isolated Paths + 8 Shared Stores
43 Nodes | 36 Ports | 86 Domain Types | 84 Edges
```

### 1.1 Isolated Path 원칙

- Path 간 직접 Edge 최소화 (전체 84 Edge 중 Cross-Path 14개, 17%)
- Path 간 데이터 교환은 Shared Store 경유 우선
- 긴급 통보(CB/VI/거래정지)만 Event Edge로 직접 전달
- 각 Path가 독립적으로 장애/재시작 가능

### 1.2 LLM 경계 요약

| Path | L0 (No LLM) | L1 (Assist) | L2 (Core) | Agent 노드 |
|------|------------|------------|----------|-----------|
| Path 1: Realtime Trading | 13 | 0 | 0 | 0 |
| Path 2: Knowledge Building | 2 | 2 | 2 | 2 |
| Path 3: Strategy Development | 3 | 2 | 0 | 2 |
| Path 4: Portfolio Management | 4 | 2 | 0 | 1 |
| Path 5: Watchdog & Operations | 4 | 2 | 0 | 0 |
| Path 6: Market Intelligence | 5 | 0 | 0 | 0 |
| **Total** | **31** | **8** | **2** | **5** |

> 72% (31/43)가 L0. 돈이 오가는 Path 1과 시장 감시 Path 6은 100% L0.

---

## 2. 전체 노드 레지스트리 (43개)

### 2.1 Path 1: Realtime Trading (13 nodes)

| # | Node ID | SubPath | 역할 | runMode | LLM | Ports (Input) | Ports (Output) | Shared Store |
|---|---------|---------|------|---------|-----|--------------|----------------|-------------|
| 1 | Screener | 1A | 전 종목 조건 필터링 | batch | L0 | MarketDataStore(R), KnowledgeStore(R), ConfigStore(R) | ScreenerPort.scan → WatchlistManager | — |
| 2 | WatchlistManager | 1A | 관심종목 등록/상태관리 | stateful-service | L0 | ScreenerPort, PositionMonitor, ExitExecutor | WatchlistPort → SubscriptionRouter | WatchlistStore(RW) |
| 3 | SubscriptionRouter | 1A | 시세 구독 대상 동적 관리 | event | L0 | WatchlistPort | SubscriptionPort → MarketDataReceiver | — |
| 4 | MarketDataReceiver | 1B | KIS 실시간 시세 수신 | stream | L0 | SubscriptionRouter(구독 명령) | MarketDataPort → IndicatorCalculator, PositionMonitor, Screener | MarketDataStore(RW) |
| 5 | IndicatorCalculator | 1B | 기술지표 계산 (MA, RSI, MACD) | event | L0 | MarketDataPort | → StrategyEngine | — |
| 6 | StrategyEngine | 1B | 전략 판단 → SignalOutput | event | L0 | IndicatorCalculator, StrategyLoader(Path 3), MarketIntelStore(R) | → RiskGuard, Path 4 ConflictResolver | — |
| 7 | RiskGuard | 1B | 주문 전 리스크 + Pre-Order 검증 | event | L0 | StrategyEngine, ExitExecutor(1C), Path 4 RiskBudget, StockState(Path 6), BrokerPort(가능수량) | → DedupGuard | — |
| 8 | DedupGuard | 1B | 중복 주문 방지 | event | L0 | RiskGuard | → OrderExecutor | — |
| 9 | OrderExecutor | 1B | KIS API 주문 실행 + OrderTracker | event | L0 | DedupGuard, BrokerPort(체결통보) | BrokerPort → TradingFSM, PositionMonitor | PortfolioStore(RW) |
| 10 | TradingFSM | 1B | 포지션 상태 관리 | stateful-service | L0 | OrderExecutor, ConfigStore(R), Path 5 Command | — | — |
| 11 | PositionMonitor | 1C | 보유종목 실시간 손익 갱신 | stream | L0 | OrderExecutor(체결), MarketDataReceiver(틱) | → ExitConditionGuard, WatchlistManager | PortfolioStore(RW) |
| 12 | ExitConditionGuard | 1C | 손절/익절/트레일링/VI/시간 감시 | event | L0 | PositionMonitor, MarketIntelStore(R), ConfigStore(R) | → ExitExecutor | — |
| 13 | ExitExecutor | 1C | 청산 주문 생성 → 1B 재진입 | event | L0 | ExitConditionGuard | → RiskGuard(1B), WatchlistManager(1A) | — |

### 2.2 Path 2: Knowledge Building (6 nodes)

| # | Node ID | 역할 | runMode | LLM | Agent | Ports (Primary) | Shared Store |
|---|---------|------|---------|-----|-------|----------------|-------------|
| 14 | ExternalCollector | 외부 데이터 수집 (DART, 뉴스) | batch | L0 | — | DataSourcePort | MarketDataStore(R) |
| 15 | DocumentParser | 비정형 → 정형 변환 | batch | L1 | — | DocumentParserPort | — |
| 16 | OntologyMapper | 정형 → 온톨로지 트리플 | batch | L1 | ✅ | OntologyPort, LLMPort | KnowledgeStore(RW) |
| 17 | CausalReasoner | 인과관계 추론 (LangGraph) | agent | L2 | ✅ | LLMPort, OntologyPort | KnowledgeStore(RW) |
| 18 | KnowledgeIndex | 지식 검색 인덱스 관리 | stateful-service | L0 | — | SearchIndexPort | — |
| 19 | KnowledgeScheduler | 파이프라인 오케스트레이션 | event | L0 | — | — | ConfigStore(R) |

### 2.3 Path 3: Strategy Development (7 nodes)

| # | Node ID | 역할 | runMode | LLM | Agent | Ports (Primary) | Shared Store |
|---|---------|------|---------|-----|-------|----------------|-------------|
| 20 | StrategyCollector | 전략 아이디어 수집 | event | L1 | ✅ | LLMPort | KnowledgeStore(R) |
| 21 | StrategyGenerator | 전략 코드 자동 생성 | batch | L2 | ✅ | LLMPort | — |
| 22 | StrategyRegistry | 전략 메타/버전 저장 | stateful-service | L0 | — | StrategyRepositoryPort | StrategyStore(RW) |
| 23 | StrategyLoader | 런타임 전략 동적 로딩 | poll | L0 | — | StrategyRuntimePort | StrategyStore(R) |
| 24 | BacktestEngine | 과거 데이터 백테스트 | batch | L0 | — | BacktestPort, MarketDataHistoryPort | MarketDataStore(R) |
| 25 | Optimizer | 파라미터 최적화 | batch | L1 | — | OptimizerPort | — |
| 26 | StrategyEvaluator | 백테스트 결과 분석 | batch | L1 | ✅ | LLMPort | — |

### 2.4 Path 4: Portfolio Management (6 nodes)

| # | Node ID | 역할 | runMode | LLM | Agent | Ports (Primary) | Shared Store |
|---|---------|------|---------|-----|-------|----------------|-------------|
| 27 | PositionAggregator | 실시간 포지션/손익 통합 | poll | L0 | — | PositionPort | PortfolioStore(RW), MarketDataStore(R) |
| 28 | RiskBudgetManager | 리스크 예산 배분/한도 | stateful-service | L0 | — | RiskBudgetPort | ConfigStore(R) |
| 29 | ConflictResolver | 전략 간 매매 충돌 해소 | event | L0 | — | ConflictResolutionPort | — |
| 30 | Rebalancer | 주기적 리밸런싱 | batch | L1 | — | — | — |
| 31 | PerformanceAnalyzer | 성과 귀인/리포트 | batch | L1 | ✅ | PerformancePort, LLMPort | PortfolioStore(RW) |
| 32 | AllocationEngine | 자산 배분/포지션 사이징 | event | L0 | — | AllocationPort | — |

### 2.5 Path 5: Watchdog & Operations (6 nodes)

| # | Node ID | 역할 | runMode | LLM | Agent | Ports (Primary) | Shared Store |
|---|---------|------|---------|-----|-------|----------------|-------------|
| 33 | HealthMonitor | 시스템 헬스체크 | poll | L0 | — | HealthCheckPort | — |
| 34 | AuditLogger | 불변 감사 로깅 | stream | L0 | — | AuditPort | AuditStore(W) |
| 35 | AnomalyDetector | 이상 패턴 감지 | event | L1 | — | AnomalyDetectionPort | — |
| 36 | AlertDispatcher | 다채널 알림 발송 | event | L0 | — | AlertPort | — |
| 37 | CommandController | 외부 운영 명령 수신/실행 | stateful-service | L0 | — | CommandPort | — |
| 38 | DailyReporter | 일일/주간 리포트 생성 | batch | L1 | — | LLMPort | AuditStore(R) |

### 2.6 Path 6: Market Intelligence (5 nodes)

| # | Node ID | 역할 | runMode | LLM | Agent | Ports (Primary) | Shared Store |
|---|---------|------|---------|-----|-------|----------------|-------------|
| 39 | SupplyDemandAnalyzer | 수급 분석 (투자자별/프로그램/공매도) | poll | L0 | — | SupplyDemandPort | MarketIntelStore(W), MarketDataStore(R) |
| 40 | OrderBookAnalyzer | 호가 구조 분석 | stream | L0 | — | OrderBookPort | MarketIntelStore(W) |
| 41 | MarketRegimeDetector | 시장 환경 판단 (CB/VI/사이드카) | event | L0 | — | MarketRegimePort | MarketIntelStore(W) |
| 42 | StockStateMonitor | 종목 상태 감시 (거래정지/투자경고/배당락) | poll | L0 | — | StockStatePort | MarketIntelStore(W) |
| 43 | ConditionSearchBridge | KIS 조건검색/순위 API 연동 | batch | L0 | — | ConditionSearchPort | MarketIntelStore(W) |

---

## 3. 전체 Port 레지스트리 (36개)

### 3.1 Path별 Port 목록

| Path | Port | 메서드 수 | 역할 |
|------|------|---------|------|
| **1A** | ScreenerPort | 4 | 종목 스크리닝 |
| **1A** | WatchlistPort | 11 | 관심종목 관리 |
| **1A** | SubscriptionPort | 4 | 시세 구독 동적 관리 |
| **1B** | MarketDataPort | 9 | 시세 수신 |
| **1B** | BrokerPort (Extended) | 16 | 주문 실행 + 정정/취소 + 가능수량 + 체결통보 |
| **1B** | StoragePort | 7 | 데이터 영속화 |
| **1B** | ClockPort | 4 | 시장 시간 |
| **1C** | PositionMonitorPort | 6 | 실시간 포지션 감시 |
| **1C** | ExitConditionPort | 5 | 청산 조건 감시 |
| **1C** | ExitExecutorPort | 3 | 청산 실행 |
| **2** | DataSourcePort | 3 | 외부 데이터 수집 |
| **2** | DocumentParserPort | 3 | 문서 파싱 |
| **2** | OntologyPort | 7 | 온톨로지 그래프 |
| **2** | LLMPort | 4 | LLM 호출 (agent 전용) |
| **2** | SearchIndexPort | 5 | 지식 검색 인덱스 |
| **3** | StrategyRepositoryPort | 6 | 전략 저장소 |
| **3** | BacktestPort | 5 | 백테스트 엔진 |
| **3** | OptimizerPort | 3 | 파라미터 최적화 |
| **3** | StrategyRuntimePort | 5 | 전략 동적 로딩/실행 |
| **3** | MarketDataHistoryPort | 4 | 과거 시세 조회 |
| **4** | PositionPort | 6 | 포지션/손익 관리 |
| **4** | RiskBudgetPort | 7 | 리스크 예산 |
| **4** | ConflictResolutionPort | 3 | 전략 충돌 해소 |
| **4** | AllocationPort | 4 | 자산 배분/사이징 |
| **4** | PerformancePort | 4 | 성과 분석 |
| **5** | HealthCheckPort | 5 | 시스템 헬스체크 |
| **5** | AuditPort | 5 | 감사 로깅 |
| **5** | AlertPort | 5 | 알림 발송 |
| **5** | CommandPort | 5 | 운영 명령 |
| **5** | AnomalyDetectionPort | 5 | 이상 감지 |
| **6** | SupplyDemandPort | 5 | 수급 분석 |
| **6** | OrderBookPort | 5 | 호가 분석 |
| **6** | MarketRegimePort | 6 | 시장 환경 판단 |
| **6** | StockStatePort | 9 | 종목 상태 감시 |
| **6** | ConditionSearchPort | 6 | KIS 조건검색/순위 |
| | | **합계: 192** | |

---

## 4. Shared Store 레지스트리 (8개)

| # | Store | 주 Writer | Reader | 핵심 데이터 |
|---|-------|----------|--------|-----------|
| 1 | **MarketDataStore** | Path 1B MarketDataReceiver | Path 1A, 2, 3, 4, 6 | Quote, OHLCV, 과거 시세 |
| 2 | **PortfolioStore** | Path 1B OrderExecutor, 1C PositionMonitor, 4 PositionAggregator | Path 1, 4, 5 | 포지션, 손익, 체결기록, 리밸런싱 이력 |
| 3 | **ConfigStore** | 외부 (YAML/관리자) | 전 Path | 전략 파라미터, 종목 목록, 리스크 한도, 스크리닝 조건, 청산 파라미터 |
| 4 | **KnowledgeStore** | Path 2 OntologyMapper, CausalReasoner | Path 1A, 2, 3 | 온톨로지 트리플, 인과관계, 파싱 문서 |
| 5 | **StrategyStore** | Path 3 StrategyRegistry | Path 1B, 3 | 전략 코드, 메타데이터, 백테스트 결과, 최적화 결과 |
| 6 | **AuditStore** | Path 5 AuditLogger | Path 5 (read-only) | 감사 이벤트 (append-only), 헬스 이력, 알림 이력, 명령 이력, 이상 이력 |
| 7 | **WatchlistStore** | Path 1A WatchlistManager | Path 1C | 워치리스트, 상태 전이 이력, 청산 이력, 스크리닝 프로파일 |
| 8 | **MarketIntelStore** | Path 6 전체 | Path 1B, 1C, 3 | MarketContext, 수급 스냅샷, 호가 분석, 시장 환경, 종목 상태, 기업 이벤트 |

### 4.1 Store 간 의존 관계

```
ConfigStore ──────→ 전 Path (Read Only)
MarketDataStore ──→ Path 1A, 2, 3, 4, 6 (Read)
                ←── Path 1B (Write)
KnowledgeStore ──→ Path 1A, 3 (Read)
                ←── Path 2 (Write)
StrategyStore ───→ Path 1B (Read)
                ←── Path 3 (Write)
PortfolioStore ──→ Path 1, 4, 5 (Read)
                ←── Path 1B, 1C, 4 (Write)
WatchlistStore ──→ Path 1C (Read)
                ←── Path 1A (Write)
MarketIntelStore → Path 1B, 1C, 3 (Read)
                ←── Path 6 (Write)
AuditStore ──────→ Path 5 (Read Only)
                ←── Path 5 AuditLogger (Append Only)
                ←── 전 Path (EventNotify → AuditLogger)
```

---

## 5. Agent 노드 상세 (5개)

graph_ir_agent_extension_v1.0에서 정의한 agent 노드의 Manifest 반영.

| # | Node ID | Path | llm_task | Model | framework | max_iter | checkpointer |
|---|---------|------|----------|-------|-----------|----------|-------------|
| 1 | OntologyMapper | 2 | ontology_mapping | Local Gemma4 | langgraph | 5 | postgresql |
| 2 | CausalReasoner | 2 | causal_reasoning | Claude Sonnet | langgraph | 5 | postgresql |
| 3 | StrategyCollector | 3 | idea_generation | Claude Sonnet | langgraph | 3 | postgresql |
| 4 | StrategyEvaluator | 3 | result_interpretation | Local Gemma4 | langgraph | 3 | postgresql |
| 5 | PerformanceAnalyzer | 4 | composite_judgment | Claude Sonnet | langgraph | 3 | postgresql |

**Agent 금지 Path:** Path 1 (Realtime Trading), Path 5 (Watchdog), Path 6 (Market Intelligence) — immutable, deterministic only.

---

## 6. runMode 분포

| runMode | 노드 수 | 노드 목록 |
|---------|--------|----------|
| batch | 10 | Screener, ExternalCollector, DocumentParser, OntologyMapper, StrategyGenerator, BacktestEngine, Optimizer, StrategyEvaluator, Rebalancer, ConditionSearchBridge |
| poll | 5 | StrategyLoader, PositionAggregator, HealthMonitor, SupplyDemandAnalyzer, StockStateMonitor |
| stream | 4 | MarketDataReceiver, AuditLogger, PositionMonitor, OrderBookAnalyzer |
| event | 11 | SubscriptionRouter, IndicatorCalculator, StrategyEngine, RiskGuard, DedupGuard, OrderExecutor, ExitConditionGuard, ExitExecutor, ConflictResolver, AllocationEngine, AlertDispatcher, MarketRegimeDetector |
| stateful-service | 8 | WatchlistManager, TradingFSM, KnowledgeIndex, StrategyRegistry, RiskBudgetManager, CommandController, KnowledgeScheduler, DailyReporter |
| agent | 5 | OntologyMapper, CausalReasoner, StrategyCollector, StrategyEvaluator, PerformanceAnalyzer |
| **Total** | **43** | |

---

## 7. Edge 요약 (84개)

### 7.1 Path별 Edge 수

| Path | 내부 | Cross-Path | Shared Store | 합계 |
|------|------|-----------|-------------|------|
| Path 1 (1A+1B+1C) | 14 | 3 | 6 | 23 |
| Path 2 | 6 | 0 | 3 | 9 |
| Path 3 | 8 | 1 | 3 | 12 |
| Path 4 | 6 | 2 | 3 | 11 |
| Path 5 | 6 | 7 | 0 | 13 |
| Path 6 | 5 | 1 | 6 | 12 |
| Order Lifecycle | 2 | 0 | 2 | 4 |
| **Total** | **47** | **14** | **23** | **84** |

### 7.2 Edge Role 분포

| Role | 수 | 비율 |
|------|----|------|
| DataPipe | 38 | 45% |
| EventNotify | 12 | 14% |
| Command | 9 | 11% |
| ConfigRef | 17 | 20% |
| AuditTrace | 8 | 10% |

### 7.3 Cross-Path Edge 일람

| # | Source Path | Target Path | Edge | 목적 |
|---|-----------|------------|------|------|
| 1 | Path 1 → Path 4 | StrategyEngine → ConflictResolver | 매매 신호 수신 |
| 2 | Path 4 → Path 1 | RiskBudgetManager → RiskGuard | 리스크 승인/거부 |
| 3 | Path 3 → Path 1 | StrategyLoader → StrategyEngine | 검증된 전략 배포 |
| 4 | Path 6 → Path 1 | MarketRegimeDetector → Path 1 (긴급) | CB/VI 즉시 통보 |
| 5 | Path 5 → Path 1 | CommandController → TradingFSM | 거래 제어 명령 |
| 6 | Path 5 → Path 3 | CommandController → StrategyRegistry | 전략 제어 명령 |
| 7 | Path 5 → Path 4 | CommandController → RiskBudgetManager | 리스크 제어 명령 |
| 8~11 | Path 1~4 → Path 5 | 각 Path → AuditLogger | 감사 추적 (×4) |
| 12~14 | Shared → 다수 | ConfigRef 엣지 | 설정/데이터 참조 (×3) |

---

## 8. 기술 스택 매핑

| 계층 | 기술 | 용도 |
|------|------|------|
| **Language** | Python 3.11+ | 전체 |
| **Async** | asyncio | 비동기 이벤트 루프 |
| **FSM** | transitions | TradingFSM, OrderFSM |
| **지표** | pandas-ta | 기술지표 계산 |
| **Validation** | pydantic | Domain Type 검증 |
| **DB** | PostgreSQL + TimescaleDB | 시계열 데이터 + 관계형 |
| **Graph DB** | PostgreSQL + Apache AGE | 온톨로지 그래프 |
| **Cache** | Redis | 실시간 상태 캐시 |
| **Vector** | pgvector | 임베딩 검색 |
| **Agent** | LangGraph | agent 노드 내부 오케스트레이션 |
| **RAG** | LlamaIndex | Knowledge Pipeline 검색 도구 |
| **LLM** | Claude Sonnet / Gemma4 (Local) | Task Router 기반 분기 |
| **Container** | Docker Compose | 전체 서비스 오케스트레이션 |
| **Monitoring** | Grafana | 대시보드 |
| **Alert** | Telegram Bot | 운영 알림 + 명령 |
| **Broker** | KIS Open API (REST + WebSocket) | 시세/주문/계좌 |

---

## 9. Adapter 총 목록

### 9.1 운영 Adapter (Primary)

| Port | Adapter | 연결 대상 |
|------|---------|----------|
| MarketDataPort | KISWebSocketAdapter | KIS WebSocket (ws://ops.koreainvestment.com:21000) |
| BrokerPort | KISMCPAdapter | KIS MCP (localhost:3000) |
| StoragePort | PostgresStorageAdapter | PostgreSQL |
| ClockPort | KRXClockAdapter | KRX 영업일 API |
| ScreenerPort | KISScreenerAdapter | KIS 조건검색 + 순위 API |
| WatchlistPort | PostgresWatchlistAdapter | PostgreSQL |
| PositionMonitorPort | InMemoryPositionMonitorAdapter | 메모리 (틱 속도) |
| ExitConditionPort | RuleBasedExitAdapter | 규칙 엔진 |
| ExitExecutorPort | PipelineExitAdapter | SubPath 1B 재진입 |
| DataSourcePort | DARTAdapter + NaverNewsAdapter | DART API + 네이버 |
| DocumentParserPort | HybridParserAdapter | 정규식 + LLM |
| OntologyPort | PostgresAGEAdapter | PostgreSQL + AGE |
| LLMPort | ClaudeAdapter / GemmaLocalAdapter | Task Router |
| SearchIndexPort | PostgresFTSAdapter | PostgreSQL FTS + pgvector |
| StrategyRepositoryPort | PostgresStrategyAdapter | PostgreSQL |
| BacktestPort | InternalBacktestAdapter | pandas + asyncio |
| OptimizerPort | OptunaAdapter | Optuna |
| StrategyRuntimePort | ImportlibRuntimeAdapter | Python importlib |
| MarketDataHistoryPort | PostgresHistoryAdapter | PostgreSQL |
| PositionPort | PostgresPositionAdapter | PostgreSQL |
| RiskBudgetPort | VaRRiskAdapter | VaR 모델 |
| ConflictResolutionPort | WeightedConflictAdapter | 가중 합산 |
| AllocationPort | VolatilityTargetAdapter | 변동성 타겟 |
| PerformancePort | LLMEnhancedPerformanceAdapter | pandas + LLM 보조 |
| HealthCheckPort | InternalHealthAdapter | asyncio 내부 체크 |
| AuditPort | PostgresAuditAdapter | PostgreSQL (immutable) |
| AlertPort | TelegramAlertAdapter | Telegram Bot API |
| CommandPort | TelegramCommandAdapter | Telegram Bot |
| AnomalyDetectionPort | StatisticalAnomalyAdapter | Z-score / IQR |
| SupplyDemandPort | KISSupplyDemandAdapter | KIS 투자자매매 API |
| OrderBookPort | KISOrderBookAdapter | KIS WebSocket H0STASP0 |
| MarketRegimePort | KISMarketRegimeAdapter | KIS 업종 + VI + 장운영 API |
| StockStatePort | KISStockStateAdapter | KIS 종목정보 + 예탁원 API |
| ConditionSearchPort | KISConditionSearchAdapter | KIS 조건검색 + 순위 API |

### 9.2 테스트 Adapter (Mock)

모든 36개 Port에 대해 MockXxxAdapter 존재. 테스트 시 `settings.yaml`에서 `implementation: MockXxxAdapter`로 교체.

### 9.3 Fallback Adapter

| Primary | Fallback | 전환 조건 |
|---------|----------|----------|
| KISWebSocketAdapter | KISRestPollingAdapter | WebSocket 끊김 5회 연속 |
| KISMCPAdapter | KISRestAdapter | MCP Docker 장애 |
| ClaudeAdapter | GemmaLocalAdapter | Claude API 장애 |
| GemmaLocalAdapter | ClaudeAdapter | 로컬 모델 OOM |

---

## 10. Validation Rules 통합 (31개)

### 10.1 Agent 규칙 (V-AGENT, 9개)

| ID | Description | Severity |
|----|-------------|----------|
| V-AGENT-001 | runMode:agent → agent_spec 필수 | error |
| V-AGENT-002 | framework는 langgraph만 | error |
| V-AGENT-003 | terminal_conditions 비어있으면 무한루프 | error |
| V-AGENT-004 | max_iterations 미설정 | warning |
| V-AGENT-005 | Path 1 agent 금지 | error |
| V-AGENT-006 | Path 5 agent 금지 | error |
| V-AGENT-007 | llm_task가 task_routing에 미정의 | warning |
| V-AGENT-008 | calls_llm:true 노드 최소 1개 | warning |
| V-PORT-001 | LLMPort는 agent 노드에서만 | error |

### 10.2 Edge 규칙 (V-EDGE, 10개)

| ID | Description | Severity |
|----|-------------|----------|
| V-EDGE-001 | Cross-Path → Shared Store 경유 또는 허용 목록 | error |
| V-EDGE-002 | DataPipe → payload.type 필수 | error |
| V-EDGE-003 | sync → timeout_ms 필수 | error |
| V-EDGE-004 | dead_letter:true → DLQ consumer 존재 | warning |
| V-EDGE-005 | idempotency:true → unique ID 필드 존재 | warning |
| V-EDGE-006 | ordering:strict → 동일 event loop | warning |
| V-EDGE-007 | Path 1 timeout_ms ≤ 5000ms | error |
| V-EDGE-008 | AuditTrace → fire-and-forget만 | error |
| V-EDGE-009 | ConfigRef → sync만 | warning |
| V-EDGE-010 | Cross-Path Command → Path 5 origin만 | error |

### 10.3 Order 규칙 (V-ORDER, 10개)

| ID | Description | Severity |
|----|-------------|----------|
| V-ORDER-001 | DRAFT → VALIDATING → SUBMITTING 순서 필수 | error |
| V-ORDER-002 | PreOrderCheck 실패 → REJECTED | error |
| V-ORDER-003 | 5초 무응답 → UNKNOWN | error |
| V-ORDER-004 | UNKNOWN → 3회 재조회 실패 → REJECTED | warning |
| V-ORDER-005 | 정정 전 modifiable 조회 필수 | error |
| V-ORDER-006 | 시장가 ORD_UNPR = "0" | error |
| V-ORDER-007 | 호가단위 미준수 → 자동 보정 + 경고 | warning |
| V-ORDER-008 | IOC/FOK 잔량 자동 취소 | info |
| V-ORDER-009 | 부분 체결 잔량 타임아웃 configurable | warning |
| V-ORDER-010 | 체결통보 구독 없이 주문 금지 | error |

### 10.4 Manifest 규칙 (V-MANIFEST, 2개)

| ID | Description | Severity |
|----|-------------|----------|
| V-MANIFEST-001 | 모든 노드는 최소 1개 Port 연결 | error |
| V-MANIFEST-002 | Shared Store Writer는 Path 당 최대 2개 | warning |

---

## 11. 다음 단계

```
[Next] Node Blueprint Catalog — 43개 노드 각각의 내부 상세
[Next] Pipeline 상세 (Numerical / Knowledge / Strategy)
[Next] Shared Store 스키마 통합 (8개 Store DDL 통합)
[Next] Graph IR YAML — 전체 노드 + 엣지 + 스키마 = Single Source of Truth
[Then] 구현 시작 (Claude Code)
```

---

*End of Document — System Manifest v1.0*
*43 Nodes | 36 Ports | 192 Methods | 86 Domain Types | 84 Edges | 8 Stores*
*5 Agent Nodes | 34 Adapters (Primary) | 36 Mock Adapters | 4 Fallback Chains*
*31 Validation Rules*
