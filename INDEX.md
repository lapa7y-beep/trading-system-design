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
| 14 | `docs/specs/shared_store_ddl_v1.0.md` | 1.0 | **Draft** | 8 Stores, 34 Tables DDL |
| 15 | `graph_ir_v1.0.yaml` | 1.0 | **Draft** | **Single Source of Truth** |

## Design Progression

```
[Confirmed] 경계 정의서 + Graph IR Agent Extension
     ↓
[Draft] Port Interface × 6 Paths (36 Ports)
     ↓
[Draft] Edge Contract (84 Edges) + Order Lifecycle Spec
     ↓
[Draft] System Manifest + Node Blueprint (43 nodes)
     ↓
[Draft] Shared Store DDL (8 Stores, 34 Tables)
     ↓
[Draft] Graph IR YAML (Single Source of Truth)  ← COMPLETE
     ↓
[Next] 구현 시작 (Claude Code) — CausalReasoner LangGraph 프로토타입
```

## Architecture Summary

```
6 Paths | 43 Nodes | 36 Ports | 192 Methods | 86 Domain Types
84 Edges | 8 Shared Stores | 34 Tables | 34 Adapters | 31 Validation Rules
5 Agent Nodes (LangGraph) | 31 L0 Nodes (72% deterministic)
```

## 설계 문서 → 구현 전환

설계 단계의 모든 문서가 완성되었습니다. `graph_ir_v1.0.yaml`이 전체 시스템의
Single Source of Truth로서, 이 파일에서 코드 생성기, 문서 생성기, 검증 엔진이
파생됩니다.

구현 순서 권장:
1. **CausalReasoner** LangGraph 프로토타입 (Path 2 agent 노드)
2. **Path 1B** MarketDataReceiver + IndicatorCalculator (실시간 시세)
3. **Path 1B** OrderExecutor + BrokerPort KIS Adapter (주문 실행)
4. **Path 1A** Screener + WatchlistManager (종목 선정)
5. **Path 6** Market Intelligence (수급/호가/VI)
6. 나머지 Path 순차 구현
