# HR-DAG Trading System — Master Index

> **Single Entry Point.** 이 문서 하나로 전체 설계의 목표, 현황, 구조, 문서 관계를 파악한다.
> 새 대화를 시작할 때 이 파일만 첨부하면 된다.

---

## 0. 프로젝트 정의

### 0.1 한 줄 정의

> KIS Open API 기반 KOSPI/KOSDAQ 자동매매 시스템.
> 수동 → 반자동 → 풀자동 3모드 지원. 모의투자부터 시작하여 단계적으로 확장.

### 0.2 핵심 설계 원칙

| 원칙 | 설명 |
|------|------|
| **단계별 확장** | 완성형이 아닌 Phase 1→2→3 점진 구축. Phase 1이 독립 실행 가능해야 한다 |
| **Isolated Path** | 6개 경로가 Shared Store로만 연결. 한 경로 장애가 다른 경로에 전파되지 않음 |
| **L0 우선** | 돈이 오가는 Path 1은 100% deterministic(L0). LLM 없이 매매가 돌아감 |
| **Plug & Play** | 어댑터 1줄 교체로 브로커/LLM/DB 전환. core 코드 변경 0줄 |
| **3-Mode 매매** | 풀자동(신호→즉시 실행) / 반자동(신호→사람 확인→실행) / 수동(사람이 직접 주문) |

### 0.3 실행 모드 정의

```
┌─────────────────────────────────────────────────────────┐
│                   ExecutionMode                          │
├──────────┬──────────────┬───────────────────────────────┤
│  AUTO    │  SEMI_AUTO   │  MANUAL                       │
│          │              │                               │
│  신호 발생 │  신호 발생    │  대시보드에서 종목 선택         │
│  → 검증   │  → 검증      │  → 수량/가격 입력              │
│  → 즉시   │  → Telegram  │  → 즉시 실행                  │
│    실행   │    알림 전송  │                               │
│          │  → 사람 확인  │                               │
│          │  → 실행/거부  │                               │
├──────────┴──────────────┴───────────────────────────────┤
│  공통: RiskGuard + DedupGuard는 모든 모드에서 필수 통과    │
│  공통: 모의투자(demo) / 실전(live) 환경 분리               │
└─────────────────────────────────────────────────────────┘
```

---

## 1. Phase 로드맵

### Phase 1 — MVP: 매매 실행 + 시장 감시 + 운영 감시

> **목표:** 수동 작성 전략 1개로 모의투자 실행. 3-Mode 매매 동작 확인.

| 항목 | 범위 |
|------|------|
| **Path** | Path 1 (Realtime Trading) + Path 6 (Market Intelligence) + Path 5 (Watchdog, 최소) |
| **노드** | Path 1: 13개 전체 / Path 6: StockStateMonitor + MarketRegimeDetector (2개) / Path 5: AuditLogger + AlertDispatcher + CommandController (3개) |
| **전략** | 수동 작성 Python 전략 1~2개 (예: MA 교차), StrategyLoader로 로딩 |
| **브로커** | KIS MCP (모의투자 demo 환경) |
| **DB** | PostgreSQL (MarketDataStore + PortfolioStore + WatchlistStore + AuditStore + ConfigStore) |
| **알림** | Telegram Bot (매매 신호 + 체결 알림 + 상태 명령) |
| **매매 모드** | AUTO / SEMI_AUTO / MANUAL 3모드 전환 (ConfigStore 또는 Telegram 명령) |

**Phase 1 노드 목록 (20개):**

```
Path 1A: Screener, WatchlistManager, SubscriptionRouter          (3)
Path 1B: MarketDataReceiver, IndicatorCalculator, StrategyEngine,
         ApprovalGate, RiskGuard, DedupGuard, OrderExecutor,
         TradingFSM                                              (8)
Path 1C: PositionMonitor, ExitConditionGuard, ExitExecutor       (3)
Path 6A: StockStateMonitor, MarketRegimeDetector,
         MarketContextBuilder                                    (3)
Path 5:  AuditLogger, AlertDispatcher, CommandController         (3)
                                                          Total: 20
```

**Phase 1에서 사용하지 않는 것:**
- Path 2 (Knowledge) 전체 — 지식 자동 구축 없음
- Path 3 (Strategy) 대부분 — 수동 전략만 사용, BacktestEngine만 선택적
- Path 4 (Portfolio) 전체 — 단일 전략이므로 충돌 해소/리밸런싱 불필요
- Path 6 나머지 3개 — SupplyDemandAnalyzer, OrderBookAnalyzer, ConditionSearchBridge는 Phase 2+

**Phase 1 완료 기준:**
1. 모의투자 환경에서 MA 교차 전략이 자동으로 매수/매도 체결
2. Telegram으로 매매 알림 수신 + halt/resume 명령 동작
3. SEMI_AUTO 모드에서 사람 확인 후 실행 흐름 동작
4. 장 마감 시 미체결 자동 취소 + 일일 결산 로깅

---

### Phase 2 — 다전략 + 리스크 관리 + 백테스트

> **목표:** 복수 전략 동시 운용, 포트폴리오 수준 리스크 관리, 백테스트 검증 체계.

| 항목 | 추가 범위 |
|------|----------|
| **Path** | + Path 4 (Portfolio) 전체 + Path 3 (백테스트/최적화만) + Path 6 나머지 |
| **노드** | + PositionAggregator, RiskBudgetManager, ConflictResolver, AllocationEngine, Rebalancer, PerformanceAnalyzer (Path 4: 6개) + BacktestEngine, Optimizer, StrategyRegistry, StrategyLoader 강화 (Path 3: 4개) + SupplyDemandAnalyzer, OrderBookAnalyzer, ConditionSearchBridge (Path 6: 3개) |
| **전략** | 수동 작성 3~5개 동시 운용, 백테스트 검증 후 배포 |
| **리스크** | 일일 손실 한도, 단일 종목 비중, 섹터 비중 관리 |
| **환경** | 모의투자 검증 완료 후 → 실전 전환 가능 |

---

### Phase 3 — 지식 시스템 + LLM 자동 생성

> **목표:** DART/뉴스 자동 수집, 온톨로지 구축, LLM 기반 전략 자동 생성.

| 항목 | 추가 범위 |
|------|----------|
| **Path** | + Path 2 (Knowledge) 전체 + Path 3 (자동 생성) |
| **노드** | + ExternalCollector, DocumentParser, OntologyMapper, CausalReasoner, KnowledgeIndex, KnowledgeScheduler (Path 2: 6개) + StrategyCollector, StrategyGenerator, StrategyEvaluator (Path 3: 3개) |
| **LLM** | Claude Sonnet (인과추론, 전략 생성) + Local Gemma4 (온톨로지 매핑, 결과 해석) |

---

## 2. 아키텍처 요약

### 2.1 전체 구조 (최종 완성 시)

```
6 Paths | 43 Nodes | 36 Ports | 192 Methods
89 Edges | 8 Shared Stores + 1 Redis Cache | 34 Tables
```

### 2.2 Phase별 활성 범위

```
           Path 1   Path 2   Path 3   Path 4   Path 5   Path 6
           매매      지식     전략     포트폴리오  감시     시장정보
Phase 1    ■■■■■    ·····    ·····    ·····    ■■·      ■■···
Phase 2    ■■■■■    ·····    ■■··     ■■■■■    ■■■      ■■■■■
Phase 3    ■■■■■    ■■■■■    ■■■■■    ■■■■■    ■■■■■    ■■■■■

■ = 활성  · = 미구현/대기
```

### 2.3 3-Mode 매매 흐름 (Phase 1 핵심)

```
[StrategyEngine] → SignalOutput 생성
       ↓
[ApprovalGate] ─── ExecutionMode 확인 ───┐
       │                                  │
       ├─ AUTO ──→ 즉시 통과 → RiskGuard → Dedup → OrderExecutor
       │
       ├─ SEMI_AUTO ──→ Telegram 알림 (approve/reject 버튼)
       │                       ↓
       │               사람 확인 (최대 120초 대기)
       │                       ↓
       │               approve → RiskGuard → Dedup → OrderExecutor
       │               reject  → 폐기 + 로깅
       │               timeout → 자동 거부
       │
       └─ MANUAL ──→ 신호 무시 (로깅만)

[MANUAL 주문 경로 — 별도 체인]
  Telegram "/buy 005930 10 72000"
       ↓
  CommandController (인증 + 파싱 + 확인)
       ↓
  RiskGuard → DedupGuard → OrderExecutor
```

**ApprovalGate는 독립 노드** (stateful-service, L0). SEMI_AUTO의 비동기 대기가 StrategyEngine의 이벤트 루프를 블로킹하지 않도록 분리.

**인프라 레이어:** KISAPIGateway(전체 REST API 초당 18건 제한 관리) + TokenManager(24시간 토큰 자동 갱신)가 모든 KIS 어댑터 하위에서 동작.

### 2.4 Shared Store (8개)

| # | Store | Phase 1 | 핵심 역할 |
|---|-------|---------|----------|
| 1 | MarketDataStore | ✅ | 시세, OHLCV |
| 2 | PortfolioStore | ✅ | 포지션, 체결, 손익 |
| 3 | ConfigStore | ✅ | 설정, 종목, 매매 모드 |
| 4 | WatchlistStore | ✅ | 관심종목 생명주기 |
| 5 | AuditStore | ✅ | 감사 로그 (불변) |
| 6 | MarketIntelStore | ✅ (부분) | 종목 상태, 시장 환경 |
| 7 | StrategyStore | Phase 2 | 전략 코드, 백테스트 |
| 8 | KnowledgeStore | Phase 3 | 온톨로지, 인과관계 |

### 2.5 기술 스택

```
Python 3.11+ / asyncio / FastAPI / transitions / pandas-ta / pydantic
PostgreSQL 16 + TimescaleDB + pgvector / Redis
Docker Compose / Grafana / Telegram Bot
KIS Open API (REST + WebSocket + MCP)
LangGraph (Phase 3) / Claude Sonnet + Gemma4 (Phase 3)
```

---

## 3. 문서 레지스트리

### 3.1 문서 지도 — 읽는 순서

```
이 파일 (INDEX.md)
  ↓ 시스템 경계와 LLM 역할
① boundary_definition_v1.0
  ↓ 핵심 매매 경로 설계
② port_interface_path1_v2.0        ← Phase 1 핵심
③ port_interface_path6_v1.0        ← Phase 1 시장정보
④ port_interface_path5_v1.0        ← Phase 1 감시
  ↓ 주문 실행 상세
⑤ order_lifecycle_spec_v1.0
  ↓ 엣지 계약과 안전 규칙
⑥ edge_contract_definition_v1.0
  ↓ 전체 노드/포트 목록
⑦ system_manifest_v1.0
  ↓ 노드 내부 상세
⑧ node_blueprint_path1_v1.0       ← Phase 1 핵심
⑨ node_blueprint_path2to6_v1.0
  ↓ 데이터 스키마
⑩ shared_store_ddl_v1.0
⑪ shared_domain_types_v1.0
  ↓ Graph IR (Single Source of Truth)
⑫ graph_ir_v1.0.yaml
  ↓ 아키텍처 보강 (패치)
⑬ architecture_review_patch_v1.0
⑭ path_reinforcement_v1.0
  ↓ 나머지 Path 설계 (Phase 2~3)
⑮ port_interface_path2_v1.0
⑯ port_interface_path3_v1.0
⑰ port_interface_path4_v1.0
  ↓ LLM Agent 확장 (Phase 3)
⑱ graph_ir_agent_extension_v1.0
```

### 3.2 문서 상세 레지스트리

| # | 문서 경로 | Ver | 상태 | Phase | 핵심 내용 |
|---|----------|-----|------|-------|----------|
| 1 | `docs/boundary_definition_v1.0.md` | 1.0 | Confirmed | 전체 | LLM 경계(L0/L1/L2), Constrained Agent, Watchdog 3-Channel |
| 2 | `docs/port_interface_path1_v2.0.md` | 2.0 | Confirmed | **P1** | 13노드, 10포트, 23엣지. 종목선정→매매→청산 전체 |
| 3 | `docs/port_interface_path6_v1.0.md` | 1.0 | Confirmed | **P1** | MarketContext, 수급/호가/VI/종목상태, 5포트 |
| 4 | `docs/port_interface_path5_v1.0.md` | 1.0 | Confirmed | **P1** | Audit/Alert/Command/Health/Anomaly, 5포트 |
| 5 | `docs/specs/order_lifecycle_spec_v1.0.md` | 1.0 | Confirmed | **P1** | OrderFSM 11상태, KIS 체결통보 파싱, Pre-Order 18항목 |
| 6 | `docs/specs/edge_contract_definition_v1.0.md` | 1.0 | Confirmed | 전체 | 84엣지, Safety Contract, E2E Latency Budget, Kill Switch |
| 7 | `docs/specs/system_manifest_v1.0.md` | 1.0 | Confirmed | 전체 | 43노드×36포트 통합 레지스트리, Adapter 매핑 |
| 8 | `docs/blueprints/node_blueprint_path1_v1.0.md` | 1.0 | Confirmed | **P1** | Path 1 전 13노드 lifecycle/내부로직/에러처리 |
| 9 | `docs/blueprints/node_blueprint_path2to6_v1.0.md` | 1.0 | Confirmed | P2~3 | Path 2~6 전 30노드 상세 |
| 10 | `docs/specs/shared_store_ddl_v1.0.md` | 1.0 | Confirmed | 전체 | 8스토어, 34테이블, PostgreSQL DDL |
| 11 | `docs/specs/shared_domain_types_v1.0.md` | 1.0 | Draft | 전체 | core/domain/ 25 canonical 타입, 30 Enum |
| 12 | `graph_ir_v1.0.yaml` | 1.0 | Confirmed | 전체 | **Single Source of Truth** — 전체 노드/엣지/스토어 |
| 13 | `docs/specs/architecture_review_patch_v1.0.md` | 1.0 | Draft | 전체 | W1(Redis 캐시 분리), W2(WAL), W3(advisory lock) |
| 14 | `docs/specs/path_reinforcement_v1.0.md` | 1.0 | Draft | P1~2 | R1(TradingContext), R2(매도 fast-path), R5(부분체결 잠금), R6(장 전이) |
| 15 | `docs/port_interface_path2_v1.0.md` | 1.0 | Confirmed | P3 | Knowledge: 5포트 (DataSource/Parser/Ontology/LLM/Search) |
| 16 | `docs/port_interface_path3_v1.0.md` | 1.0 | Confirmed | P2 | Strategy: 5포트 (Repository/Backtest/Optimizer/Runtime/History) |
| 17 | `docs/port_interface_path4_v1.0.md` | 1.0 | Confirmed | P2 | Portfolio: 5포트 (Position/Risk/Conflict/Allocation/Performance) |
| 18 | `docs/specs/graph_ir_agent_extension_v1.0.md` | 1.0 | Confirmed | P3 | runMode:agent, LLMPort, Task Router, 5 Agent 노드 |
| 19 | `docs/specs/architecture_reinforcement_patch_v2.0.md` | 2.0 | **Draft** | **P1** | **P-01~P-17: KISAPIGateway, 2-Tier 구독, ApprovalGate, MANUAL 경로, Boot/Shutdown, 22항목 검증, EnvironmentProfile, TokenManager, MarketContextBuilder, Path 6A/6B** |

### 3.3 Phase별 필수 읽기 문서

| Phase 1 시작 시 | Phase 2 추가 시 | Phase 3 추가 시 |
|----------------|----------------|----------------|
| INDEX.md (이 문서) | port_interface_path4 | port_interface_path2 |
| boundary_definition | port_interface_path3 | graph_ir_agent_extension |
| **reinforcement_patch_v2.0** | node_blueprint_path2to6 (Path 3~4 부분) | node_blueprint_path2to6 (Path 2 부분) |
| port_interface_path1 | | |
| port_interface_path6 | | |
| port_interface_path5 | | |
| order_lifecycle_spec | | |
| node_blueprint_path1 | | |
| shared_domain_types | | |
| shared_store_ddl | | |
| graph_ir_v1.0.yaml | | |

---

## 4. Phase 1 구현 가이드

### 4.1 구현 순서 (권장)

```
Step 1: 기반 인프라
  ├─ core/domain/  공용 타입 모듈 (shared_domain_types 기반)
  ├─ core/ports/   ABC 클래스 (Phase 1에 필요한 포트만)
  ├─ Docker Compose: PostgreSQL + Redis + KIS MCP
  └─ ConfigStore 초기 데이터 (settings.yaml → DB)

Step 2: Path 6 최소 구현 (가장 단순한 L0 노드로 패턴 검증)
  ├─ StockStateMonitor (poll, KIS API 1개)
  └─ MarketRegimeDetector (event, WebSocket)

Step 3: Path 1B 시세 수신 체인
  ├─ MarketDataReceiver (WebSocket + REST fallback)
  ├─ IndicatorCalculator (pandas-ta)
  └─ MarketDataStore 저장

Step 4: Path 1A 종목 선정
  ├─ Screener (batch)
  ├─ WatchlistManager (stateful-service)
  └─ SubscriptionRouter (event)

Step 5: Path 1B 주문 실행 체인
  ├─ StrategyEngine (수동 전략 로딩)
  ├─ ApprovalGate (3-Mode 분기: AUTO 통과 / SEMI_AUTO 대기 / MANUAL 무시)
  ├─ RiskGuard (Pre-Order 22항목, Phase 1 포트폴리오 검증 내장)
  ├─ DedupGuard
  ├─ OrderExecutor (BrokerPort → KIS MCP, KISAPIGateway 경유)
  └─ TradingFSM (transitions FSM)

Step 6: Path 1C 포지션 추적
  ├─ PositionMonitor
  ├─ ExitConditionGuard (6종 청산 조건)
  └─ ExitExecutor (→ 1B 재진입)

Step 7: Path 5 최소 감시
  ├─ AuditLogger (PostgreSQL append-only)
  ├─ AlertDispatcher (Telegram)
  └─ CommandController (halt/resume/status/positions)

Step 8: 통합 + 3-Mode 테스트
  ├─ AUTO 모드 E2E 테스트 (시세→지표→신호→주문→체결)
  ├─ SEMI_AUTO 모드 (Telegram 확인 흐름)
  ├─ MANUAL 모드 (Telegram 직접 주문)
  └─ 장 마감 시나리오 (미체결 취소, 일일 결산)
```

### 4.2 Phase 1 기술 결정 사항

| 결정 | 선택 | 근거 |
|------|------|------|
| 전략 로딩 | StrategyLoader poll (Path 3 최소분) | 수동 전략 .py 파일을 감시하여 동적 로딩 |
| Path 4 부재 시 리스크 | RiskGuard 내 SimplifiedPortfolioCheck 내장 | 일일 손실/종목 비중/보유 수/거래 횟수 4항목 추가 (22항목) |
| 매매 모드 전환 | ConfigStore `execution_mode` 필드 | Telegram 명령 `/mode auto\|semi\|manual`로 런타임 변경 |
| SEMI_AUTO 확인 | ApprovalGate 노드 + Telegram inline keyboard | approve/reject 버튼 → CommandController → ApprovalGate, 120초 타임아웃 |
| MANUAL 주문 | CommandController 매매 명령 확장 | `/buy 005930 10 72000` → RiskGuard 경유 주문 |
| Path 6 축소 | StockState + MarketRegime + MarketContextBuilder | 수급/호가 분석은 Phase 2(Path 6B). MarketContext 기본 조건만 |
| API Rate Limit | KISAPIGateway 중앙 관리 | 전체 REST API 초당 18건 제한, 우선순위 큐잉 |
| WebSocket 구독 | 2-Tier: WS 20종목 + REST 폴링 30종목 | KIS 실제 상한 반영, Tier 자동 승격/강등 |
| 토큰 관리 | TokenManager (만료 30분 전 자동 갱신) | BrokerPort 어댑터 내부 컴포넌트 |
| 환경 분리 | EnvironmentProfile (demo/live) | settings.yaml active 1줄 변경으로 전환 |

### 4.3 Phase 1 ConfigStore 초기값

```yaml
execution_mode: "semi_auto"          # auto | semi_auto | manual
trading_env: "demo"                  # demo | live
risk_limits:
  max_portfolio_loss_pct: -3.0
  max_single_position_pct: 30.0
  max_daily_trades: 20
  max_single_order_amount: 10000000  # 1천만원 (모의투자)
watchlist_limits:
  max_watching: 20
  max_in_position: 5
exit_rules_default:
  stop_loss_pct: -3.0
  take_profit_pct: 5.0
  trailing_stop_pct: 2.0
  max_holding_minutes: 360
  force_close_before_close_minutes: 3
```

---

## 5. 아키텍처 수치 (Post-Patch v2.0, 전체 완성 시)

```
6 Paths (8 SubPaths) | 45 Nodes | 36 Ports | 192 Methods | 96 Domain Types
95 Edges | 8 Shared Stores + 1 Redis Cache | 34 Tables | 34 Adapters
46 Validation Rules | 7 Contract Patterns | 22 Pre-Order Checks
5 Agent Nodes (LangGraph) | 33 L0 Nodes (73% deterministic)
2 Infra Components (KISAPIGateway, TokenManager)
```

**Phase 1 활성 수치:**

```
3 Paths (3 SubPaths: 1A/1B/1C + 6A + 5부분) | 20 Nodes | ~22 Ports | ~110 Methods
~40 Edges | 6 Shared Stores | ~20 Tables | ~15 Adapters
0 Agent Nodes | 20 L0 Nodes (100% deterministic)
2 Infra Components | 22 Pre-Order Checks
```

---

## 6. Architecture Review 결과 요약

| 점검 항목 | 결과 | 해결 문서 |
|----------|------|----------|
| Node↔Port 커버리지 | ✅ Pass | — |
| Edge contract 완성도 | ✅ Pass | — |
| Agent 경계 enforcement | ✅ Pass | — |
| Cross-path 동기 의존 (W1) | ⚠️ → ✅ | architecture_review_patch (Redis 캐시 분리) |
| WAL 패턴 적용 (W2) | ⚠️ → ✅ | architecture_review_patch (WAL edge 추가) |
| PortfolioStore 동시 쓰기 (W3) | ⚠️ → ✅ | architecture_review_patch (advisory lock) |
| Domain Type 중복 (I1) | 🔴 → ✅ | shared_domain_types_v1.0 |
| E2E Latency 전파 (R1) | ⚠️ → ✅ | path_reinforcement (TradingContext) |
| 부분 체결 경합 (R5) | ⚠️ → ✅ | path_reinforcement (Order Lock) |
| 장 시간대 전이 (R6) | ⚠️ → ✅ | path_reinforcement (Phase Event) |
| **KIS API Rate Limit (P-01)** | **🔴 → ✅** | **reinforcement_patch_v2.0 (KISAPIGateway)** |
| **WebSocket 구독 상한 (P-02)** | **🔴 → ✅** | **reinforcement_patch_v2.0 (2-Tier 구독)** |
| **3-Mode 매매 흐름 (P-03/04)** | **🟡 → ✅** | **reinforcement_patch_v2.0 (ApprovalGate + MANUAL)** |
| **Boot/Shutdown 시퀀스 (P-05)** | **🟡 → ✅** | **reinforcement_patch_v2.0** |
| **Phase 1 포트폴리오 보호 (P-06)** | **🟡 → ✅** | **reinforcement_patch_v2.0 (22항목)** |
| **환경 분리 (P-07)** | **🟡 → ✅** | **reinforcement_patch_v2.0 (EnvironmentProfile)** |

---

## 7. 용어 사전 (Quick Reference)

| 용어 | 정의 |
|------|------|
| **HR-DAG** | Hierarchical Recursive DAG — 이 시스템의 아키텍처 명칭 |
| **Path** | 고립된 기능 경로. Shared Store로만 연결 |
| **L0/L1/L2** | LLM 비개입 / LLM 보조 / LLM 핵심 |
| **Graph IR** | 전체 노드/엣지/설정의 YAML 표현. Single Source of Truth |
| **Plug & Play** | settings.yaml 1줄로 어댑터 교체 가능 |
| **TradingContext** | 주문 체인 전체를 관통하는 컨텍스트 (E2E budget, 시세 신선도) |
| **MarketContext** | 종목별 시장 인텔리전스 종합 (진입 안전 여부, 긴급 청산 여부) |
| **OrderFSM** | 주문 상태 머신 (11 상태, DRAFT → FILLED/CANCELLED/REJECTED) |
| **TradingFSM** | 포지션 상태 머신 (6 상태, Idle → InPosition → Idle) |
| **Safety Contract** | E2E Latency, Stale Price Guard, Circuit Breaker, Kill Switch |
| **ExecutionMode** | AUTO / SEMI_AUTO / MANUAL 매매 실행 수준 |

---

## 8. 운영 규칙

1. **문서 상태는 Draft / Confirmed 2개만** — 직접 읽어보고 맞으면 Confirmed
2. **동기화는 의미 있는 변경만** — 구조적 결정이 바뀌었을 때만 commit
3. **연쇄 변경은 Claude가 추적** — "변경사항 정리해줘" 하면 영향받는 문서 전부 수정
4. **새 대화 시작법** — `INDEX.md` 첨부 + "이어서 하자"
5. **Phase 전환 시** — INDEX.md의 Phase별 필수 읽기 문서를 추가 첨부

---

## 9. 변경 이력

| 날짜 | 변경 내용 |
|------|----------|
| 2026-04-16 (2차) | Reinforcement Patch v2.0: +2노드(ApprovalGate, MarketContextBuilder), KISAPIGateway, 2-Tier 구독, Boot/Shutdown 시퀀스, 22항목 검증, EnvironmentProfile, MANUAL 경로 |
| 2026-04-16 (1차) | INDEX.md 전면 재작성: 목표 재정의 (완성형→단계별), 3-Mode 매매, Phase 로드맵, 구현 가이드 추가 |
| 2026-04-15 | 설계 문서 18개 완성, Architecture Review Patch + Path Reinforcement 적용 |

---

*End of Document — HR-DAG Master Index*
*Phase 1: 20 Nodes | 3-Mode 매매 | 모의투자 시작 | 22항목 검증 | KISAPIGateway*
*Phase 2: +12 Nodes | 다전략 + 백테스트 + 리스크 + Path 6B*
*Phase 3: +13 Nodes | Knowledge + LLM 자동 생성*
