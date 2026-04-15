# HR-DAG Trading System — Design Documents Index

## Document Registry

| # | Document | Version | Status | Description |
|---|----------|---------|--------|-------------|
| 1 | `docs/boundary_definition_v1.0.docx` | 1.0 | **Confirmed** | 경계 정의서 + LLM 역할 매트릭스 |
| 2 | `docs/boundary_definition_v1.0.md` | 1.0 | **Confirmed** | 위 문서의 Markdown 버전 |
| 3 | `docs/specs/graph_ir_agent_extension_v1.0.md` | 1.0 | **Confirmed** | Graph IR 확장: runMode:agent + agent_spec + LLMPort |
| 4 | `docs/port_interface_path1_v1.0.md` | 1.0 | **Confirmed** | Path 1B(매매실행) 4 Ports, 6 Domain Types |
| 5 | `docs/port_interface_path2_v1.0.md` | 1.0 | **Confirmed** | Path 2(Knowledge) 5 Ports, 8 Domain Types |
| 6 | `docs/port_interface_path3_v1.0.md` | 1.0 | **Confirmed** | Path 3(Strategy) 5 Ports, 10 Domain Types |
| 7 | `docs/port_interface_path4_v1.0.md` | 1.0 | **Confirmed** | Path 4(Portfolio) 5 Ports, 12 Domain Types |
| 8 | `docs/port_interface_path5_v1.0.md` | 1.0 | **Confirmed** | Path 5(Watchdog) 5 Ports, 14 Domain Types |
| 9 | `docs/specs/edge_contract_definition_v1.0.md` | 1.0 | **Draft** | 68개 Edge 통합 스키마 + Trading Safety Contract |
| 10 | `docs/port_interface_path1_extension_v1.0.md` | 1.0 | **Draft** | Path 1 확장: 종목선정(1A) + 포지션추적(1C) |

## Design Progression

```
[Confirmed] 경계 정의서 (Boundary Definition)
     ↓
[Confirmed] Graph IR Agent Extension (runMode:agent, LLMPort, Task Router)
     ↓
[Confirmed] Port Interface × 5 Paths (31 Ports, 62 Domain Types)
     ↓
[Draft] Edge Contract Definition (68 Edges, 5 Contract Patterns)
     ↓
[Draft] Path 1 Extension: Universe & Position Tracking (+6 Nodes, +14 Edges)
     ↓
[Next] System Manifest — 전체 노드(~38개) + Port(31개) + Edge(68개) 통합
     ↓
[Planned] Node Blueprint Catalog
     ↓
[Planned] Pipeline 상세 (Numerical / Knowledge / Strategy)
     ↓
[Planned] Shared Store 스키마 통합 (7개 Store)
     ↓
[Planned] Graph IR YAML (Single Source of Truth)
     ↓
[Planned] CausalReasoner LangGraph 프로토타입 (Claude Code)
```

## Architecture Summary (Current)

```
5 Isolated Paths
├── Path 1: Realtime Trading     (13 nodes, 3 SubPaths: 1A/1B/1C, ALL L0)
├── Path 2: Knowledge Building   (6 nodes, L0~L2)
├── Path 3: Strategy Development (7 nodes, L0~L2)
├── Path 4: Portfolio Management (6 nodes, L0~L1)
└── Path 5: Watchdog & Operations(6 nodes, L0~L1)

7 Shared Stores
├── MarketDataStore, PortfolioStore, ConfigStore
├── KnowledgeStore, StrategyStore, AuditStore
└── WatchlistStore (NEW)

31 Ports | 62 Domain Types | 68 Edges | 38 Nodes
```

## Key Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-15 | Internal LLM = Constrained Agent | 런타임에서 시스템 변경 금지, 구조적 권한 제한 |
| 2026-04-15 | LLM Engagement Level 3등급 (L0/L1/L2) | Port Interface 설계의 입력값으로 사용 |
| 2026-04-15 | Watchdog 3-Channel Architecture | 대화/보고서/외부LLM 소비 분리 |
| 2026-04-15 | Ontology Lifecycle → Shared Store 간접 루프 | DAG 원칙 유지하면서 순환 구조 해결 |
| 2026-04-15 | runMode: agent 추가 (6종) | LangGraph 도입에 따른 Graph IR 스키마 확장 |
| 2026-04-15 | LangGraph 단독 선정 + LlamaIndex 보조 | State 영속화/conditional branching/실패 복구 네이티브 |
| 2026-04-15 | LLMPort 신설 (7번째 포트) | Plug & Play LLM 통합. provider 교체 시 core 변경 0줄 |
| 2026-04-15 | Task Router — 노드별 모델 분기 | 비용/품질/속도 균형 |
| 2026-04-15 | Agent 노드 6개 확정 | Path 1,5는 deterministic 고정 (immutable) |
| 2026-04-15 | Validation 규칙 9개 추가 (V-AGENT-*) | agent 노드 설계 오류 조기 감지 |
| 2026-04-15 | **Path 1 SubPath 분할 (1A/1B/1C)** | **종목선정→매매→포지션추적 생명주기 완결** |
| 2026-04-15 | **WatchlistStore 신설 (7번째 Store)** | **종목 상태 전이 영속화** |
| 2026-04-15 | **종목 상태 8단계 생명주기** | **CANDIDATE→WATCHING→ENTRY→IN_POSITION→EXIT→CLOSED→재감시/블랙리스트** |
| 2026-04-15 | **Trading Safety Contract 최우선** | **E2E latency budget, stale price guard, circuit breaker, kill switch** |
