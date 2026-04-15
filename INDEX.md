# HR-DAG Trading System — Design Documents Index

## Document Registry

| # | Document | Version | Status | Description |
|---|----------|---------|--------|-------------|
| 1 | `docs/boundary_definition_v1.0.md` | 1.0 | **Confirmed** | 경계 정의서 + LLM 역할 매트릭스 |
| 2 | `docs/specs/graph_ir_agent_extension_v1.0.md` | 1.0 | **Confirmed** | Graph IR: runMode:agent + LLMPort |
| 3 | `docs/port_interface_path1_v2.0.md` | 2.0 | **Draft** | Path 1: 1A+1B+1C, 10 Ports |
| 4 | `docs/port_interface_path2_v1.0.md` | 1.0 | **Confirmed** | Path 2: Knowledge, 5 Ports |
| 5 | `docs/port_interface_path3_v1.0.md` | 1.0 | **Confirmed** | Path 3: Strategy, 5 Ports |
| 6 | `docs/port_interface_path4_v1.0.md` | 1.0 | **Confirmed** | Path 4: Portfolio, 5 Ports |
| 7 | `docs/port_interface_path5_v1.0.md` | 1.0 | **Confirmed** | Path 5: Watchdog, 5 Ports |
| 8 | `docs/port_interface_path6_v1.0.md` | 1.0 | **Draft** | Path 6: Market Intel, 5 Ports |
| 9 | `docs/specs/edge_contract_definition_v1.0.md` | 1.0 | **Draft** | 84 Edges + Trading Safety Contract |
| 10 | `docs/specs/order_lifecycle_spec_v1.0.md` | 1.0 | **Draft** | OrderFSM + BrokerPort 확장 |
| 11 | `docs/specs/system_manifest_v1.0.md` | 1.0 | **Draft** | 43노드 통합 레지스트리 |
| 12 | `docs/blueprints/node_blueprint_path1_v1.0.md` | 1.0 | **Draft** | Path 1: 13노드 내부 상세 |
| 13 | `docs/blueprints/node_blueprint_path2to6_v1.0.md` | 1.0 | **Draft** | Path 2~6: 30노드 내부 상세 |

## Design Progression

```
[Confirmed] 경계 정의서 + Graph IR Agent Extension
     ↓
[Draft] Port Interface × 6 Paths (36 Ports)
     ↓
[Draft] Edge Contract (84 Edges) + Order Lifecycle Spec
     ↓
[Draft] System Manifest (43 nodes 통합) + Node Blueprint (43 nodes 상세)  ← CURRENT
     ↓
[Next] Shared Store DDL 통합 (8개 Store)
     ↓
[Next] Graph IR YAML (Single Source of Truth)
     ↓
[Then] 구현 시작 (Claude Code)
```

## Architecture Summary

```
6 Paths | 43 Nodes | 36 Ports | 192 Methods | 86 Domain Types
84 Edges | 8 Shared Stores | 34 Adapters | 31 Validation Rules
5 Agent Nodes (LangGraph) | 31 L0 Nodes (72% deterministic)
```
