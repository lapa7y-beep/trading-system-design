# INDEX — 문서 지도

> **기준 버전**: Phase 1 확정본 (2026-04-16)
> **진실의 원천**: [`docs/decisions/011-phase1-scope.md`](docs/decisions/011-phase1-scope.md)

본 저장소의 문서를 **읽는 순서**와 **역할**로 정리한다.

---

## 0. 먼저 읽을 것

| 순서 | 문서 | 읽는 이유 |
|------|------|---------|
| 1 | [`README.md`](README.md) | 프로젝트 한 장 요약 |
| 2 | [`docs/decisions/011-phase1-scope.md`](docs/decisions/011-phase1-scope.md) | **모든 판단의 기준** — Phase 1 범위 |
| 3 | [`docs/references/glossary.md`](docs/references/glossary.md) | 용어 |

---

## 1. 결정 (Decisions)

시간순, 상류에서 하류로.

| # | 파일 | 내용 | 상태 |
|---|------|------|------|
| 006 | `docs/decisions/006-db-stack.md` | PostgreSQL + TimescaleDB 선택 | active |
| 007 | `docs/decisions/007-fsm-design.md` | 개별 FSM (종목군·실행군 Phase 2) | active (축약) |
| 008 | `docs/decisions/008-data-collection.md` | KIS REST + APScheduler | active |
| 009 | ~~Cross-Validation~~ | Phase 5+ 연기 | archive/phase3/ |
| 010 | ~~LLM Storage + Code Generator~~ | Phase 3 연기 | archive/phase3/ |
| **011** | [`docs/decisions/011-phase1-scope.md`](docs/decisions/011-phase1-scope.md) | **Phase 1 범위 확정** | **stable** |

---

## 2. 아키텍처 (Architecture)

| 파일 | 내용 |
|------|------|
| [`docs/architecture/system-overview.md`](docs/architecture/system-overview.md) | 전체 구조 (HR-DAG 개념, 5 Path — Phase 1은 Path 1만) |
| [`docs/architecture/path1-phase1.md`](docs/architecture/path1-phase1.md) | **Path 1의 Phase 1 상세 설계** (6노드, Pre-Order 7체크) |
| [`docs/architecture/cli-design.md`](docs/architecture/cli-design.md) | `atlas` CLI 설계 (Telegram 대체) |
| [`docs/architecture/fsm-design.md`](docs/architecture/fsm-design.md) | TradingFSM 6상태 |
| [`docs/architecture/db-stack.md`](docs/architecture/db-stack.md) | DB 스택 선정 근거 |
| [`docs/architecture/screens/screen-architecture.md`](docs/architecture/screens/screen-architecture.md) | **화면 설계** (4카테고리, 17화면, 외곽·전환·레이아웃) |
| [`docs/architecture/boot-shutdown-phase1.md`](docs/architecture/boot-shutdown-phase1.md) | **Boot/Shutdown 시퀀스** (기동·종료·긴급정지·크래시복구) |

---

## 3. 파이프라인 (Pipelines)

| 파일 | 내용 |
|------|------|
| [`docs/pipelines/data-collection.md`](docs/pipelines/data-collection.md) | OHLCV 수집 (일봉/분봉) |
| [`docs/pipelines/backtesting.md`](docs/pipelines/backtesting.md) | 백테스트 실행 구조 |

---

## 4. 명세 (Specs)

| 파일 | 내용 |
|------|------|
| [`docs/specs/domain-types-phase1.md`](docs/specs/domain-types-phase1.md) | Phase 1 Domain Types 20개 (Pydantic) |
| [`docs/specs/db-schema-phase1.sql`](docs/specs/db-schema-phase1.sql) | 실행 가능 DDL (6 테이블) |
| [`docs/specs/config-schema-phase1.md`](docs/specs/config-schema-phase1.md) | **config.yaml 통합 스키마** (11섹션, 브로커 전환 명세) |
| [`docs/specs/port-signatures-phase1.md`](docs/specs/port-signatures-phase1.md) | **6 Port ABC 통합 시그니처** (28 메서드, PortError 계층) |
| [`docs/specs/adapter-spec-phase1.md`](docs/specs/adapter-spec-phase1.md) | **12 Adapter 구현 명세** (내부동작·실패처리·전환규칙) |
| [`docs/specs/error-handling-phase1.md`](docs/specs/error-handling-phase1.md) | **에러 핸들링 통합 매트릭스** (4계층·Severity·SAFE_MODE·CB·KIS코드) |
| [`docs/specs/project-structure-phase1.md`](docs/specs/project-structure-phase1.md) | **프로젝트 폴더 구조** (Hexagonal 3층·의존방향·구현착수순서) |
| [`docs/specs/test-strategy-phase1.md`](docs/specs/test-strategy-phase1.md) | **테스트 전략** (Unit/Integration/Acceptance, 합격기준 5 자동화, CI) |

---

## 5. 청사진 (Blueprints)

| 파일 | 내용 |
|------|------|
| [`docs/blueprints/path1-phase1-blueprint.md`](docs/blueprints/path1-phase1-blueprint.md) | Path 1 Phase 1 노드 6개의 L3 확장 청사진 |

---

## 6. 참고 (References)

| 파일 | 내용 |
|------|------|
| [`docs/references/glossary.md`](docs/references/glossary.md) | 용어집 (Phase 1 용어만) |
| [`docs/references/decision-log.md`](docs/references/decision-log.md) | 결정 이력 |
| [`docs/references/kis-api-notes.md`](docs/references/kis-api-notes.md) | KIS API 사용 메모 |

---

## 7. Archive

| 파일 | 내용 |
|------|------|
| [`docs/archive/README.md`](docs/archive/README.md) | Archive 이동 이유 및 복원 절차 |
| `docs/archive/phase2plus/` | Phase 2 이후 복원 예정 (Path 3/4/5/6, 고급 Risk 등) |
| `docs/archive/phase3/` | Phase 3 LLM·지식그래프 관련 |
| `docs/archive/patches/` | 반영 완료된 델타 문서 (재사용 금지) |

---

## 8. SSoT (Single Source of Truth)

| 파일 | 역할 |
|------|------|
| [`graph_ir_phase1.yaml`](graph_ir_phase1.yaml) | Phase 1 그래프 구조 (노드·엣지·Port·Adapter 전부) |

Phase 2 진입 시 확장 예정. 현재는 Phase 1 범위만.

---

## 수치 요약 (Phase 1)

| 항목 | 수 |
|------|----|
| Nodes | **6** |
| Ports | **6** |
| Shared Stores | **3** |
| Edges | **14** |
| Domain Types | **20** |
| DB Tables | **6** |
| Adapters (Primary) | **6** |
| Adapters (Mock) | **6** |
| Pre-Order Checks | **7** |
| FSM States | **6** |
| CLI Commands | **12** |
| Screens | **17** |
| 합격 기준 | **5** |

**이 수치가 활성 문서들 간에 일치하지 않으면 설계 문서가 꼬인 것이다.** — 통폐합 시 최우선 검증 포인트.

---

## 폐기된 수치 (Phase 1 이전 문서에 있던 것 — 참고용)

| 항목 | 이전 주장 | Phase 1 실제 | 차이 |
|------|---------|-----------|------|
| Nodes | 45 | 6 | -39 |
| Edges | 95 | 12 | -83 |
| Ports | 36 | 6 | -30 |
| DB Tables | 34 | 6 | -28 |
| Domain Types | 86 | 20 | -66 |
| Adapters | 68 | 12 | -56 |

**설계 복잡도 1/6로 감소.** Phase 2 이후 단계적으로 복원.

---

## 변경 이력

| 날짜 | 변경 |
|------|------|
| 2026-04-16 | Phase 1 확정 + 통폐합. 활성 문서 40여 개 → 16개. Phase 2+ 문서 Archive 이동. |
| 2026-04-17 | screen-architecture.md v1.3 추가 (방향 A~C 완료). INDEX.md에 화면 설계 등재. |
| 2026-04-17 | 설계작업 2/3/4/5 완료 — config-schema, port-signatures, adapter-spec, boot-shutdown 4개 문서 추가. INDEX 섹션 2/4 갱신. |
| 2026-04-17 | 설계작업 6 완료 — error-handling-phase1 추가. 에러 처리 규칙 노드·Port·CB·SAFE_MODE·KIS코드 통합. |
| 2026-04-17 | 설계작업 7 완료 — project-structure-phase1 추가. Hexagonal 3층 폴더 트리 + 의존 방향 + 구현 착수 순서. |
| 2026-04-17 | **설계작업 8 완료 — test-strategy-phase1 추가. Phase 1 설계 단계 전체 완료.** |

---

## 남은 설계 작업 (구현 설계 진입 전 완료 필요)

| 순서 | 작업 | 상태 |
|------|------|------|
| 1 | 방향 C — Operating 화면 레이아웃 | ✅ 완료 |
| 2 | config.yaml 통합 스키마 | ✅ 완료 |
| 3 | Port ABC 시그니처 통합 (6개 Port Phase 1) | ✅ 완료 |
| 4 | Adapter 구현 명세 (Mock/CSV/KIS) | ✅ 완료 |
| 5 | Boot/Shutdown 시퀀스 Phase 1 축약판 | ✅ 완료 |
| 6 | 에러 핸들링 통합 매트릭스 | ✅ 완료 |
| 7 | 프로젝트 폴더 구조 | ✅ 완료 |
| 8 | 테스트 전략 | ✅ 완료 |

**🎯 Phase 1 설계 완료.** 전체 점검 후 구현 착수.

---

## 구현 착수 조건 체크리스트

구현을 시작하기 전에 다음을 확인한다:

- [ ] 활성 문서 수치 체크섬 일치 (Nodes 6 / Ports 6 / Edges 14 / Domain Types 20 / Adapters 12 / CLI 12 / Screens 17 / 합격기준 5)
- [ ] `graph_ir_phase1.yaml`이 모든 설계 문서의 SSoT 역할 수행
- [ ] `config-schema`와 `path1-phase1-blueprint`의 config 키 일치
- [ ] `port-signatures`와 `adapter-spec`의 메서드 시그니처 일치
- [ ] `project-structure` §10의 구현 착수 8단계 확인
- [ ] `test-strategy` §5의 합격 기준 5개 자동화 가능 여부 확인
- [ ] 로컬 개발 환경 준비 (Python 3.11+, Docker, PostgreSQL)
- [ ] KIS API 인증 정보 준비 (모의투자 계정)

---

*End of INDEX*
