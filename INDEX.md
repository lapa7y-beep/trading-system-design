# HR-DAG Trading System — Design Documents Index

## Document Registry

| # | Document | Version | Status | Description |
|---|----------|---------|--------|-------------|
| 1 | `docs/boundary_definition_v1.0.md` | 1.0 | **Confirmed** | 경계 정의서 + LLM 역할 매트릭스 |
| 2 | `docs/specs/graph_ir_agent_extension_v1.0.md` | 1.0 | **Confirmed** | Graph IR: runMode:agent + LLMPort |
| 3 | `docs/port_interface_path1_v2.0.md` | 2.0 | **Confirmed** | Path 1: 1A+1B+1C, 10 Ports |
| 4 | `docs/port_interface_path2_v1.0.md` | 1.0 | **Confirmed** | Path 2: Knowledge, 5 Ports |
| 5 | `docs/port_interface_path3_v1.0.md` | 1.0 | **Confirmed** | Path 3: Strategy, 5 Ports |
| 6 | `docs/port_interface_path4_v1.0.md` | 1.0 | **Confirmed** | Path 4: Portfolio, 5 Ports |
| 7 | `docs/port_interface_path5_v1.0.md` | 1.0 | **Confirmed** | Path 5: Watchdog, 5 Ports |
| 8 | `docs/port_interface_path6_v1.0.md` | 1.0 | **Confirmed** | Path 6: Market Intel, 5 Ports |
| 9 | `docs/specs/edge_contract_definition_v1.0.md` | 1.0 | **Confirmed** | 84 Edges + Trading Safety Contract |
| 10 | `docs/specs/order_lifecycle_spec_v1.0.md` | 1.0 | **Confirmed** | OrderFSM + BrokerPort 확장 |
| 11 | `docs/specs/system_manifest_v1.0.md` | 1.0 | **Confirmed** | 43노드 통합 레지스트리 |
| 12 | `docs/blueprints/node_blueprint_path1_v1.0.md` | 1.0 | **Confirmed** | Path 1: 13노드 내부 상세 |
| 13 | `docs/blueprints/node_blueprint_path2to6_v1.0.md` | 1.0 | **Confirmed** | Path 2~6: 30노드 내부 상세 |
| 14 | `docs/specs/shared_store_ddl_v1.0.md` | 1.0 | **Confirmed** | 8 Stores, 34 Tables DDL |
| 15 | `graph_ir_v1.0.yaml` | 1.0 | **Confirmed** | **Single Source of Truth** |
| 16 | `docs/specs/shared_domain_types_v1.0.md` | 1.0 | **Draft** | 공용 도메인 타입 canonical 정의 |
| 17 | `docs/specs/architecture_review_patch_v1.0.md` | 1.0 | **Draft** | W1/W2/W3 해결 패치 |
| 18 | `docs/specs/path_reinforcement_v1.0.md` | 1.0 | **Draft** | 경로 분석 보강 (R1~R6) |

## Design Progression

```
[Confirmed] 경계 정의서 + Graph IR Agent Extension
     ↓
[Confirmed] Port Interface × 6 Paths (36 Ports)
     ↓
[Confirmed] Edge Contract (84 Edges) + Order Lifecycle Spec
     ↓
[Confirmed] System Manifest + Node Blueprint (43 nodes)
     ↓
[Confirmed] Shared Store DDL (8 Stores, 34 Tables)
     ↓
[Confirmed] Graph IR YAML (Single Source of Truth)
     ↓
[Draft] Architecture Review Patch (W1/W2/W3 + I1)
     ↓
[Draft] Path Reinforcement (R1~R6 보강)              ← NEW
     ↓
[Next] 구현 시작 (Claude Code) — core/domain/ → Ports → Adapters
```

## Architecture Summary (Post-Reinforcement)

```
6 Paths | 43 Nodes | 36 Ports | 192 Methods | 91 Domain Types
89 Edges | 8 Shared Stores + 1 Redis Cache | 34 Tables | 34 Adapters
39 Validation Rules | 7 Contract Patterns
5 Agent Nodes (LangGraph) | 31 L0 Nodes (72% deterministic)
13 Cross-Path Sync Edges | TradingContext E2E chain enforcement
```

## Architecture Review 결과 요약

| 점검 항목 | 결과 | 해결 |
|----------|------|------|
| Node↔Port 커버리지 | ✅ Pass | — |
| Edge contract 완성도 | ✅ Pass | — |
| Agent 경계 enforcement | ✅ Pass | — |
| Cross-path 동기 의존 (W1) | ⚠️ → ✅ | Redis cache 기반 비동기 분리 |
| WAL 패턴 적용 (W2) | ⚠️ → ✅ | e_preorder_wal_write edge 추가 |
| PortfolioStore 동시 쓰기 (W3) | ⚠️ → ✅ | per-symbol advisory lock |
| Domain Type 중복 (I1) | 🔴 → ✅ | shared_domain_types_v1.0 문서 |

## 설계 문서 → 구현 전환

설계 단계의 모든 문서가 완성되었습니다. Architecture Review 패치까지 적용 완료.

구현 순서 권장 (리뷰 반영):
1. **core/domain/** 공용 타입 모듈 (shared_domain_types 기반)
2. **core/ports/** ABC 클래스 (36 Port, Graph IR에서 생성)
3. **Path 6** StockStateMonitor (가장 단순한 L0 poll — 패턴 검증)
4. **Path 1B** MarketDataReceiver + IndicatorCalculator (실시간 시세)
5. **Path 1B** OrderExecutor + BrokerPort KIS Adapter (주문 실행)
6. **CausalReasoner** LangGraph 프로토타입 (Path 2 agent 노드)
7. 나머지 Path 순차 구현
