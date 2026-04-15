# HR-DAG Trading System — Design Documents Index

## Document Registry

| # | Document | Version | Status | Description |
|---|----------|---------|--------|-------------|
| 1 | `docs/boundary_definition_v1.0.docx` | 1.0 | **Confirmed** | 경계 정의서 + LLM 역할 매트릭스 |
| 2 | `docs/boundary_definition_v1.0.md` | 1.0 | **Confirmed** | 위 문서의 Markdown 버전 |

## Design Progression

```
[Confirmed] 경계 정의서 (Boundary Definition)
     ↓
[Next] Port Interface 설계
     ↓
[Planned] KIS Adapter 구현
     ↓
[Planned] Node Blueprint 상세
```

## Key Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-15 | Internal LLM = Constrained Agent | 런타임에서 시스템 변경 금지, 구조적 권한 제한 |
| 2026-04-15 | LLM Engagement Level 3등급 (L0/L1/L2) | Port Interface 설계의 입력값으로 사용 |
| 2026-04-15 | Watchdog 3-Channel Architecture | 대화/보고서/외부LLM 소비 분리 |
| 2026-04-15 | Ontology Lifecycle → Shared Store 간접 루프 | DAG 원칙 유지하면서 순환 구조 해결 |
