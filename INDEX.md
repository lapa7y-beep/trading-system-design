# HR-DAG Trading System — Design Documents Index

## Document Registry

| # | Document | Version | Status | Description |
|---|----------|---------|--------|-------------|
| 1 | `docs/boundary_definition_v1.0.docx` | 1.0 | **Confirmed** | 경계 정의서 + LLM 역할 매트릭스 |
| 2 | `docs/boundary_definition_v1.0.md` | 1.0 | **Confirmed** | 위 문서의 Markdown 버전 |
| 3 | `docs/specs/graph_ir_agent_extension_v1.0.md` | 1.0 | **Confirmed** | Graph IR 확장: runMode:agent + agent_spec + LLMPort |
| 4 | `docs/port_interface_path1_v2.0.md` | 2.0 | **Draft** | Path 1 전체: 1A(종목선정)+1B(매매)+1C(포지션추적), 10 Ports |
| 5 | `docs/port_interface_path2_v1.0.md` | 1.0 | **Confirmed** | Path 2(Knowledge) 5 Ports, 8 Domain Types |
| 6 | `docs/port_interface_path3_v1.0.md` | 1.0 | **Confirmed** | Path 3(Strategy) 5 Ports, 10 Domain Types |
| 7 | `docs/port_interface_path4_v1.0.md` | 1.0 | **Confirmed** | Path 4(Portfolio) 5 Ports, 12 Domain Types |
| 8 | `docs/port_interface_path5_v1.0.md` | 1.0 | **Confirmed** | Path 5(Watchdog) 5 Ports, 14 Domain Types |
| 9 | `docs/port_interface_path6_v1.0.md` | 1.0 | **Draft** | Path 6(Market Intel) 5 Ports, 14 Domain Types |
| 10 | `docs/specs/edge_contract_definition_v1.0.md` | 1.0 | **Draft** | 80개 Edge 통합 스키마 + Trading Safety Contract |

## Deleted Documents

| Document | Replaced By | Reason |
|----------|-------------|--------|
| `docs/port_interface_path1_v1.0.md` | `docs/port_interface_path1_v2.0.md` | v2.0에 병합 |
| `docs/port_interface_path1_extension_v1.0.md` | `docs/port_interface_path1_v2.0.md` | v2.0에 병합 |

## Design Progression

```
[Confirmed] 경계 정의서 (Boundary Definition)
     ↓
[Confirmed] Graph IR Agent Extension (runMode:agent, LLMPort, Task Router)
     ↓
[Draft] Port Interface × 6 Paths (36 Ports, 76 Domain Types)
     ↓
[Draft] Edge Contract Definition (80 Edges, 5 Contract Patterns)
     ↓
[Next] Order Lifecycle Spec — 주문 상태 머신 + BrokerPort 확장
     ↓
[Next] System Manifest — 전체 노드(43개) + Port(36개) + Edge(80개) 통합
     ↓
[Planned] Node Blueprint Catalog
     ↓
[Planned] Pipeline 상세 (Numerical / Knowledge / Strategy)
     ↓
[Planned] Shared Store 스키마 통합 (8개 Store)
     ↓
[Planned] Graph IR YAML (Single Source of Truth)
     ↓
[Planned] CausalReasoner LangGraph 프로토타입 (Claude Code)
```

## Architecture Summary (Current)

```
6 Isolated Paths
├── Path 1: Realtime Trading      (13 nodes, 3 SubPaths: 1A/1B/1C, ALL L0)
├── Path 2: Knowledge Building    (6 nodes, L0~L2)
├── Path 3: Strategy Development  (7 nodes, L0~L2)
├── Path 4: Portfolio Management  (6 nodes, L0~L1)
├── Path 5: Watchdog & Operations (6 nodes, L0~L1)
└── Path 6: Market Intelligence   (5 nodes, ALL L0) ← NEW

8 Shared Stores
├── MarketDataStore, PortfolioStore, ConfigStore
├── KnowledgeStore, StrategyStore, AuditStore
├── WatchlistStore
└── MarketIntelStore ← NEW

36 Ports | 76 Domain Types | 80 Edges | 43 Nodes
```

## Key Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-15 | Internal LLM = Constrained Agent | 런타임에서 시스템 변경 금지 |
| 2026-04-15 | LLM Engagement Level 3등급 (L0/L1/L2) | Port Interface 설계 입력값 |
| 2026-04-15 | Watchdog 3-Channel Architecture | 대화/보고서/외부LLM 소비 분리 |
| 2026-04-15 | runMode: agent 추가 (6종) | LangGraph 도입 |
| 2026-04-15 | LLMPort 신설 (7번째 포트) | Plug & Play LLM 통합 |
| 2026-04-15 | Task Router — 노드별 모델 분기 | 비용/품질/속도 균형 |
| 2026-04-15 | Agent 노드 6개 확정 | Path 1,5,6은 deterministic 고정 |
| 2026-04-15 | Path 1 SubPath 분할 (1A/1B/1C) | 종목선정→매매→포지션추적 생명주기 |
| 2026-04-15 | WatchlistStore 신설 (7번째 Store) | 종목 상태 전이 영속화 |
| 2026-04-15 | 종목 상태 8단계 생명주기 | CANDIDATE→WATCHING→...→CLOSED |
| 2026-04-15 | Trading Safety Contract 최우선 | E2E latency, stale guard, circuit breaker |
| 2026-04-15 | Path 1 v1.0+extension → v2.0 병합 | 단일 문서에서 전체 생명주기 |
| 2026-04-15 | **Path 6: Market Intelligence 신설** | **수급/호가/시장환경/종목상태 = "시장을 읽는 눈"** |
| 2026-04-15 | **MarketIntelStore 신설 (8번째 Store)** | **MarketContext 종합 인텔리전스 저장** |
| 2026-04-15 | **MarketContext = Path 6 핵심 출력** | **entry_safe/exit_urgent 판단 보조** |
