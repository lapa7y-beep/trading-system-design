# HR-DAG Trading System — Design Documents Index

## Document Registry

| # | Document | Version | Status | Description |
|---|----------|---------|--------|-------------|
| 1 | `docs/boundary_definition_v1.0.docx` | 1.0 | **Confirmed** | 경계 정의서 + LLM 역할 매트릭스 |
| 2 | `docs/boundary_definition_v1.0.md` | 1.0 | **Confirmed** | 위 문서의 Markdown 버전 |
| 3 | `docs/port_interface_path1_v1.0.docx` | 1.0 | **Confirmed** | Path 1 Port Interface 설계서 |
| 4 | `docs/port_interface_path1_v1.0.md` | 1.0 | **Confirmed** | 위 문서의 Markdown 버전 |

## Design Progression

```
[Confirmed] 1. 경계 정의서 (Boundary Definition)
     ↓
[Confirmed] 2. Port Interface 설계 — Path 1: Realtime Trading
     ↓
[Next] 3. KIS Adapter 구현 (MarketDataPort + BrokerPort)
     ↓
[Planned] 4. Port Interface 설계 — Path 2~5 전파
     ↓
[Planned] 5. Shared Store Schema 확장 (Knowledge DB, Report DB)
     ↓
[Planned] 6. Node Blueprint 상세
```

## Key Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-15 | Internal LLM = Constrained Agent | 런타임에서 시스템 변경 금지, 구조적 권한 제한 |
| 2026-04-15 | LLM Engagement Level 3등급 (L0/L1/L2) | Port Interface 설계의 입력값으로 사용 |
| 2026-04-15 | Watchdog 3-Channel Architecture | 대화/보고서/외부LLM 소비 분리 |
| 2026-04-15 | Ontology Lifecycle → Shared Store 간접 루프 | DAG 원칙 유지하면서 순환 구조 해결 |
| 2026-04-15 | Path 1 Port: 4개 (MarketData/Broker/Account/Storage) | KIS API 필드 기반 Domain Type 확정 |
| 2026-04-15 | Config Store는 외부 LLM만 Write 가능 | Constrained Agent 원칙의 구체적 구현 |
| 2026-04-15 | Safeguard 순서: Strategy→RiskGuard→DedupGuard→Broker | 구조적으로 우회 불가능한 체인 |
