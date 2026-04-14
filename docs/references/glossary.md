# Glossary — 설계 용어 사전

> 최종 수정: 2026-04-14

## HR-DAG & 시각 설계

| 용어 | 정의 |
|------|------|
| HR-DAG | 횡적계층 + 종적DAG + 재귀전개 |
| Zoom Level | L2 경로그룹(접힘) / L3 경로내부(펼침) |
| Visual Composer | L2-L3 접기펼치기 캔버스 |
| Code Generator | 그래프 → 실행코드 변환기 |
| Node Blueprint | L3 자동전개 설계도 |
| Graph IR | 캔버스 JSON/YAML 중간표현 |
| Port Interface | 노드 입출력 접점 |
| Adapter Mapping | 파라미터 → 구현체 매핑 |
| PathCanvas | n8n+ComfyUI 융합 UI 컨셉 |

## 시스템 구조

| 용어 | 정의 |
|------|------|
| System Manifest | 전체 구성요소 목록 (8영역 ~40항목) |
| Validation Engine | 실시간 설계오류 검출 |
| Edge Type 4종 | Dependency / DataFlow / Event / StateTransition |
| Four Critical Safeguards | 중복주문방지 / 상태일관성 / 이벤트내구성 / 명령보안 |
| 고립경로설계 | 5 Path + 6 저장소, 직접엣지 금지 |

## 원칙

| 용어 | 정의 |
|------|------|
| Plug & Play | YAML로 어댑터 교체, 엣지계약 유지 시 노드 교체 |
| Role Separation | 전략엔진=뇌 / KIS MCP=손 / LLM=참모 |
| runMode | batch / poll / stream / event / stateful-service |
| EdgeRole | DataPipe / EventNotify / Command / ConfigRef / AuditTrace |

## 인프라

| 용어 | 정의 |
|------|------|
| KIS Trading MCP | 주문 실행 (Docker, port 3000) |
| KIS Code Assistant MCP | 문서·코드 검색 전용 |
| 5-layer hierarchy | 신호생성 → 전략엔진 → 주문관리 → KIS MCP → KIS API |
