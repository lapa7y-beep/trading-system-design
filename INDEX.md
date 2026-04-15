# HR-DAG Trading System — Design Documents Index

## Document Registry

| # | Document | Version | Status | Description |
|---|----------|---------|--------|-------------|
| 1 | `docs/boundary_definition_v1.0.md` | 1.0 | **Confirmed** | 경계 정의서 + LLM 역할 매트릭스 |
| 2 | `docs/specs/graph_ir_agent_extension_v1.0.md` | 1.0 | **Confirmed** | Graph IR 확장: runMode:agent + LLMPort |
| 3 | `docs/port_interface_path1_v2.0.md` | 2.0 | **Draft** | Path 1: 1A(종목선정)+1B(매매)+1C(포지션추적), 10 Ports |
| 4 | `docs/port_interface_path2_v1.0.md` | 1.0 | **Confirmed** | Path 2(Knowledge) 5 Ports |
| 5 | `docs/port_interface_path3_v1.0.md` | 1.0 | **Confirmed** | Path 3(Strategy) 5 Ports |
| 6 | `docs/port_interface_path4_v1.0.md` | 1.0 | **Confirmed** | Path 4(Portfolio) 5 Ports |
| 7 | `docs/port_interface_path5_v1.0.md` | 1.0 | **Confirmed** | Path 5(Watchdog) 5 Ports |
| 8 | `docs/port_interface_path6_v1.0.md` | 1.0 | **Draft** | Path 6(Market Intel) 5 Ports |
| 9 | `docs/specs/edge_contract_definition_v1.0.md` | 1.0 | **Draft** | 84개 Edge + Trading Safety Contract |
| 10 | `docs/specs/order_lifecycle_spec_v1.0.md` | 1.0 | **Draft** | 주문 상태 머신 + BrokerPort 확장 + 에러 처리 |

## Design Progression

```
[Confirmed] 경계 정의서 + Graph IR Agent Extension
     ↓
[Draft] Port Interface × 6 Paths (36 Ports, 86 Domain Types)
     ↓
[Draft] Edge Contract (84 Edges) + Order Lifecycle Spec
     ↓
[Next] System Manifest — 43노드 + 36포트 + 84엣지 통합 레지스트리
     ↓
[Planned] Node Blueprint Catalog → Pipeline 상세 → Shared Store 통합 (8개)
     ↓
[Planned] Graph IR YAML (Single Source of Truth)
     ↓
[Planned] 구현 시작 (Claude Code)
```

## Architecture Summary

```
6 Isolated Paths
├── Path 1: Realtime Trading      (13 nodes, 3 SubPaths, ALL L0)
├── Path 2: Knowledge Building    (6 nodes, L0~L2)
├── Path 3: Strategy Development  (7 nodes, L0~L2)
├── Path 4: Portfolio Management  (6 nodes, L0~L1)
├── Path 5: Watchdog & Operations (6 nodes, L0~L1)
└── Path 6: Market Intelligence   (5 nodes, ALL L0)

8 Shared Stores
├── MarketDataStore, PortfolioStore, ConfigStore, KnowledgeStore
├── StrategyStore, AuditStore, WatchlistStore, MarketIntelStore

43 Nodes | 36 Ports | 86 Domain Types | 84 Edges
BrokerPort: 16 Methods | OrderFSM: 11 States | 24 Order Divisions
```

## Key Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-15 | Internal LLM = Constrained Agent | 런타임에서 시스템 변경 금지 |
| 2026-04-15 | LLM 3등급 (L0/L1/L2) | Port Interface 설계 입력값 |
| 2026-04-15 | runMode: agent + LLMPort + Task Router | LangGraph 캡슐화 |
| 2026-04-15 | Path 1 SubPath (1A/1B/1C) | 종목 8단계 생명주기 완결 |
| 2026-04-15 | Path 6: Market Intelligence 신설 | 수급/호가/시장환경/종목상태 = 시장의 눈 |
| 2026-04-15 | MarketContext = Path 6 핵심 출력 | entry_safe/exit_urgent 판단 보조 |
| 2026-04-15 | Order Lifecycle Spec | OrderFSM 11상태, 24주문유형, KRX/NXT/SOR 3거래소 |
| 2026-04-15 | BrokerPort 확장 (8→16 메서드) | 정정/취소/가능수량/체결통보/예약주문 |
| 2026-04-15 | Pre-Order 18항목 검증 | 종목상태+자금+주문유형 3단계 검증 |
| 2026-04-15 | KIS WebSocket H0STCNI0 체결통보 파싱 | 접수/정정/취소/거부/체결 실시간 수신 |
| 2026-04-15 | UNKNOWN 상태 복구 프로세스 | 5초 타임아웃 → 3회 재조회 → REJECTED |
| 2026-04-15 | KRX 호가단위 테이블 + 자동 보정 | 7단계 가격대별 틱사이즈 |
