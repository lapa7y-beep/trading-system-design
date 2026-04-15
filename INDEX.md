# HR-DAG Trading System — Design Documents Index

## Document Registry

| # | Document | Version | Status | Description |
|---|----------|---------|--------|-------------|
| 1 | `docs/boundary_definition_v1.0.docx` | 1.0 | **Confirmed** | 경계 정의서 + LLM 역할 매트릭스 |
| 2 | `docs/boundary_definition_v1.0.md` | 1.0 | **Confirmed** | 위 문서의 Markdown 버전 |
| 3 | `docs/specs/graph_ir_agent_extension_v1.0.md` | 1.0 | **Confirmed** | Graph IR 확장: runMode:agent + agent_spec + LLMPort |

## Design Progression

```
[Confirmed] 경계 정의서 (Boundary Definition)
     ↓
[Confirmed] Graph IR Agent Extension (runMode:agent, LLMPort, Task Router)
     ↓
[Next] System Manifest에 runMode 필드 반영
     ↓
[Next] Port Interface 설계 (LLMPort 포함 7개 포트)
     ↓
[Planned] KIS Adapter 구현
     ↓
[Planned] Node Blueprint 상세
     ↓
[Planned] CausalReasoner LangGraph 프로토타입
```

## Key Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-15 | Internal LLM = Constrained Agent | 런타임에서 시스템 변경 금지, 구조적 권한 제한 |
| 2026-04-15 | LLM Engagement Level 3등급 (L0/L1/L2) | Port Interface 설계의 입력값으로 사용 |
| 2026-04-15 | Watchdog 3-Channel Architecture | 대화/보고서/외부LLM 소비 분리 |
| 2026-04-15 | Ontology Lifecycle → Shared Store 간접 루프 | DAG 원칙 유지하면서 순환 구조 해결 |
| 2026-04-15 | runMode: agent 추가 (6종) | LangGraph 도입에 따른 Graph IR 스키마 확장 |
| 2026-04-15 | LangGraph 단독 선정 + LlamaIndex 보조 | State 영속화/conditional branching/실패 복구 네이티브. 비교: Haystack, MS Agent FW, CrewAI 탈락 |
| 2026-04-15 | LLMPort 신설 (7번째 포트) | Plug & Play LLM 통합. provider 교체 시 core 변경 0줄 |
| 2026-04-15 | Task Router — 노드별 모델 분기 | 비용/품질/속도 균형. Local Gemma4(반복) vs Claude Sonnet(추론) |
| 2026-04-15 | Agent 노드 6개 확정 | 5개 Path 전수 스캔. Path 1,5는 deterministic 고정 (immutable) |
| 2026-04-15 | Validation 규칙 9개 추가 (V-AGENT-*) | agent 노드 설계 오류 조기 감지 |
