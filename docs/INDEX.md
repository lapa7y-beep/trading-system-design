# INDEX — 설계 문서 현황

> 최종 업데이트: 2026-04-14
> 이 문서가 전체 설계의 지도입니다. 새 대화를 시작할 때 이것을 먼저 참조하세요.

## 상태 범례

| 상태 | 의미 |
|------|------|
| ✅ stable | 검토 완료, 현재 유효 |
| 🔨 draft | 작성 중 또는 미검증 |
| ⚠️ outdated | 변경 필요, 현재 버전과 불일치 |
| 🗑️ deprecated | 폐기됨, 참고용으로만 보존 |

---

## architecture/ — 시스템 구조

| 문서 | 상태 | 설명 | 최종 수정 |
|------|------|------|-----------|
| [system-overview.md](architecture/system-overview.md) | 🔨 draft | HR-DAG, 5경로, 6저장소, 역할분리 | 2026-04-14 |
| hexagonal-ports.md | 📋 예정 | 6개 Port ABC 정의 | — |
| state-machine.md | 📋 예정 | 주문 상태 전이도 | — |
| safeguards.md | 📋 예정 | 4대 방어장치 상세 | — |

## pipelines/ — 파이프라인

| 문서 | 상태 | 설명 | 최종 수정 |
|------|------|------|-----------|
| numerical.md | 📋 예정 | 수치 파이프라인 | — |
| knowledge.md | 📋 예정 | 지식 파이프라인 | — |
| strategy.md | 📋 예정 | 전략 파이프라인 | — |

## specs/ — 스펙 문서

| 문서 | 상태 | 설명 | 최종 수정 |
|------|------|------|-----------|
| manifest.md | 📋 예정 | 8영역 ~40항목 구성요소 목록 | — |
| node-blueprint.md | 📋 예정 | L3 노드 스펙 | — |
| edge-types.md | 📋 예정 | 4종 엣지 + EdgeRole 정의 | — |

## decisions/ — 설계 결정 기록

| 번호 | 상태 | 제목 | 날짜 |
|------|------|------|------|
| [001](decisions/001-hexagonal-architecture.md) | ✅ stable | Hexagonal Architecture 채택 | 2026-03 |
| 002 | 📋 예정 | TrustGraph는 배경지식용, 실시간 제외 | 2026-03 |
| 003 | 📋 예정 | HR-DAG 설계방식 채택 | 2026-03 |
| 004 | 📋 예정 | PathCanvas UI 컨셉 | 2026-04 |

## references/ — 참고 자료

| 문서 | 상태 | 설명 |
|------|------|------|
| [glossary.md](references/glossary.md) | 🔨 draft | 설계 용어 사전 |
| kis-api-notes.md | 📋 예정 | KIS API 사용 메모 |
| tech-stack.md | 📋 예정 | 기술 스택 정리 |

---

## 다음 작업

- [ ] 기존 대화에서 확정된 내용으로 각 draft 문서 채우기
- [ ] system-overview.md 리뷰 후 stable 승격
- [ ] manifest.md에 ~40항목 전체 목록 정리
