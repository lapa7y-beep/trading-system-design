# INDEX — 트레이딩 시스템 설계 마스터 인덱스

> 최종 업데이트: 2026-04-16  
> 새 대화 시작 시 이 문서를 먼저 참조한다

---

## 프로젝트 개요

KIS(한국투자증권) + Kiwoom Open API 기반 반자동 트레이딩 시스템.  
LLM은 advisor 역할만, 사람이 최종 승인, 실전 코드와 백테스트 코드 공유.

---

## 시스템 성격 (확정)

- **반자동** — 신호 생성은 자동, 주문 실행은 사람 승인 후
- **외부 인터페이스** — jdw 입장에서는 대화 기반 Agent처럼 보임
- **내부 실행 엔진** — FSM이 제어. LLM은 FSM 내부에 개입하지 않음
- **증권사** — KIS + Kiwoom 양쪽 (BrokerPort 어댑터 교체)

### LLM 역할 3분리 (ADR-010)

```
LLM = 관제사 + 감시카메라  /  FSM = 신호 시스템(레일)  /  jdw = 최종 승인

역할 1 — 활성화 판단 (LLM):  시나리오를 FSM에 넘길지 말지 결정
역할 2 — 경로 실행 (FSM):    정해진 상태 전이 그대로 실행, LLM 개입 없음
역할 3 — 감시·보고 (LLM):    전체 FSM 상태 파악 → jdw에게 보고·제안

LLM이 절대 하지 않는 것: FSM 경로 중간 개입 / 실시간 주문 판단 / 경로 임의 변경
```

---

## 구현 Phase 순서

| Phase | 내용 | 상태 |
|-------|------|------|
| 1 | DB 스키마 확정 + KIS REST OHLCV·수급 수집기 + 스케줄러 | 설계 완료 |
| 2 | 백테스팅 프레임워크 (MockBroker + ClockPort + 전략 인터페이스 E2E) | 설계 완료 |
| 3 | Telegram CommandController + 관심종목 FSM + KIS/Kiwoom 모의 | 설계 완료 |
| 4 | Grafana S1 Dashboard + 실전 전환 + 리스크 가드 | 설계 완료 |
| 5 | Knowledge 파이프라인 (뉴스·임베딩·CausalReasoner·교차검증) | 미착수 |

**구현 단계 진행 순서:**
1. 초기 화면 설계 (S1 Dashboard + S7 Telegram 와이어프레임)
2. Code Generator 설계 (Graph IR YAML → Python 코드 자동 생성, 노드 명세 확정 후)
3. Phase별 상세 구현

---

## 문서 인덱스

### 1. 루트 문서

| 파일 | 내용 | 상태 |
|------|------|------|
| `README.md` | 저장소 개요, 폴더 구조, 운영 규칙 | stable |
| `INDEX.md` | 이 문서 — 전체 지도 | stable |
| `graph_ir_v1.0.yaml` | Graph IR Single Source of Truth (43→45 노드, 89→95 엣지) | draft |

---

### 2. 아키텍처 기반 문서 (docs/architecture/)

오늘(2026-04-16) 확정된 내용을 기반으로 신규 작성.

| 파일 | 내용 | 상태 |
|------|------|------|
| `docs/architecture/system-overview.md` | 전체 시스템 구조, 5개 Path, LLM 역할 3분리, Shared Store | stable |
| `docs/architecture/fsm-design.md` | FSM 이중 레벨 (군 5상태 + 개별 13상태), 취약점 대응 | stable |
| `docs/architecture/db-stack.md` | DB 스택 확정 (postgres+redis), 정형·비정형 저장 원칙 | stable |
| `docs/boundary_definition_v1.0.md` | LLM 역할 경계, L0/L1/L2 분류, Constrained Agent 원칙 (이전 채팅 작성) | stable |

---

### 3. Port Interface 설계 (docs/)

6개 Path 각각의 Port ABC, Domain Type, Edge 정의.

| 파일 | Path | Port 수 | Edge 수 | 상태 |
|------|------|---------|---------|------|
| `docs/port_interface_path1_v2.0.md` | Realtime Trading (3 SubPath, 13 노드) | 10 | 23 | draft |
| `docs/port_interface_path2_v1.0.md` | Knowledge Building (6 노드) | 5 | 9 | draft |
| `docs/port_interface_path3_v1.0.md` | Strategy Development (7 노드) | 5 | 12 | draft |
| `docs/port_interface_path4_v1.0.md` | Portfolio Management (6 노드) | 5 | 11 | draft |
| `docs/port_interface_path5_v1.0.md` | Watchdog & Operations (6 노드) | 5 | 13 | draft |
| `docs/port_interface_path6_v1.0.md` | Market Intelligence (5 노드) | 5 | 12 | draft |

---

### 4. 상세 명세 (docs/specs/)

| 파일 | 내용 | 상태 |
|------|------|------|
| `docs/specs/system_manifest_v1.0.md` | 43개 노드 전체 레지스트리 + 36개 Port + 84개 Edge 통합 | draft |
| `docs/specs/graph_ir_agent_extension_v1.0.md` | runMode:agent 확장, LLMPort(7번째), Task Router | stable |
| `docs/specs/edge_contract_definition_v1.0.md` | 62개 Edge 전체 계약 + Trading Lifecycle 5단계 | draft |
| `docs/specs/order_lifecycle_spec_v1.0.md` | 주문 FSM 11상태, 24종 주문유형, Pre-Order 18항목 | draft |
| `docs/specs/shared_store_ddl_v1.0.md` | 8개 Shared Store DDL (34테이블, 7 Hypertable) | draft |
| `docs/specs/shared_domain_types_v1.0.md` | 25개 Canonical Type + 30종 Enum (core/domain/) | draft |
| `docs/specs/architecture_review_patch_v1.0.md` | Review 패치 v1.0 (Cross-Path 동기 의존 제거, WAL 패턴) | draft |
| `docs/specs/path_reinforcement_v1.0.md` | 보강 설계 v1.0 (TradingContext, 매도 Fast-Path, Urgent Channel 등) | draft |
| `docs/specs/architecture_deep_review_v1.0.md` | 6 Path 전체 재분석 — 취약점 5개·누락 8개·분기 4개 | draft |
| `docs/specs/architecture_reinforcement_patch_v2.0.md` | 패치 v2.0 — 17개 패치 (KISAPIGateway, ApprovalGate, Boot/Shutdown 등) | draft |
| `docs/specs/session_summary_20260416.md` | 2026-04-16 세션 전체 요약 | stable |
| `docs/specs/llm-role.md` | LLM 역할 3분리 상세 + 대화 저장 구조 (오늘 신규) | stable |

---

### 5. 파이프라인 문서 (docs/pipelines/)

오늘(2026-04-16) 확정된 내용을 기반으로 신규 작성.

| 파일 | 내용 | 상태 |
|------|------|------|
| `docs/pipelines/data-collection.md` | 정형 수집 파이프라인 + IngestPort 플러그인 구조 | stable |
| `docs/pipelines/backtesting.md` | 백테스팅 이중 엔진 + 포트폴리오 + 실전 전환 기준 | stable |

---

### 6. Node Blueprint (docs/blueprints/)

| 파일 | 내용 | 상태 |
|------|------|------|
| `docs/blueprints/node_blueprint_path1_v1.0.md` | Path 1 13개 노드 내부 상세 (lifecycle, internal_logic, config, error) | draft |
| `docs/blueprints/node_blueprint_path2to6_v1.0.md` | Path 2~6 30개 노드 내부 상세 + MarketContext 조합 로직 | draft |

---

### 7. 설계 결정 기록 (docs/decisions/)

오늘(2026-04-16) 확정된 핵심 결정들.

| 파일 | 내용 | 상태 |
|------|------|------|
| `docs/decisions/006-db-stack.md` | DB 스택 확정 (postgres+redis 2개, TimescaleDB+pgvector+AGE) | stable |
| `docs/decisions/007-fsm-design.md` | FSM 이중 레벨 (군 5상태 + 개별 13상태, 취약점 17개 반영) | stable |
| `docs/decisions/008-data-collection.md` | 데이터 수집 원칙 (한정기간 수치만 저장, IngestPort 플러그인) | stable |
| `docs/decisions/009-cross-validation.md` | 정형·비정형 교차 검증 (현재 구현 불가, Phase 5 이후) | stable |
| `docs/decisions/010-llm-storage-code-generator.md` | LLM 역할 3분리 + 대화 저장(LangGraph+PG) + Code Generator | stable |

> ADR 001~005는 이전 채팅에서 결정된 내용이며 현재 파일 없음 (추후 복원 필요):
> 001 Hexagonal Architecture, 002 TrustGraph 범위, 003 PathCanvas UI,
> 004 저장소 4종(deprecated), 005 PostgreSQL-first

---

## 핵심 확정 사항 요약

### DB 스택
```
postgres  — PostgreSQL 16 + TimescaleDB + pgvector + AGE
redis     — Redis 7 (이벤트 버퍼 + FSM 상태 캐시)
```

### FSM 설계
```
레벨 1 — 종목군 FSM (5개 상태): INACTIVE → ACTIVE ↔ SUSPENDED → CLOSING → CLOSED
레벨 2 — 개별 종목 FSM (13개 상태): IDLE → WATCHING → SCENARIO_RUNNING →
         PENDING_APPROVAL → ORDER_PLACED → PARTIAL_FILLED → HOLDING ↔ RECONCILING →
         EXITING → DONE / ERROR / SUSPENDED

포지션 키 = (종목코드 + 증권사)  /  종목당 활성 시나리오 1개 mutex
모든 전이 → PostgreSQL 영속화 필수
```

### 백테스팅 프레임워크
```
이중 엔진:
  벡터 기반 — 전체 기간 배열 처리, 빠른 파라미터 탐색
  이벤트 기반 — 틱/봉 단위 FSM 재생, 실전 코드와 동일

실전 전환 기준: 모의 30일+ / 샤프 > 1.0 / MDD < 15%
포트폴리오: 복수 전략 × 복수 종목 동시 실행
```

### 데이터 수집 원칙
```
저장: OHLCV(일봉/분봉), 수급, 프로그램매매, FSM이력, 주문·체결, 감사로그
저장 안 함: 재무제표, 종목기본정보, 공시 목록 (API 실시간 조회)
비정형: IngestPort ABC (fetch/parse/get_metadata) — 파서만 추가하면 자동 연결
```

### LLM 저장
```
LangGraph StateGraph + PostgreSQL checkpointer (Phase 3)
저장: 대화이력, 중간추론, activation_log, monitoring_log
적용: Knowledge·Strategy Path LLM 노드 + 감시·보고 LLM
```

---

## 기술 스택

```
언어·런타임:  Python 3.11+ / asyncio
전략·FSM:    transitions / pandas-ta / pydantic
DB:          PostgreSQL 16 + TimescaleDB + pgvector + AGE
캐시·버퍼:   Redis 7
LLM 워크플로: LangGraph (Knowledge·Strategy Path 노드 한정)
UI:          LiteGraph.js (PathCanvas) / Grafana / Telegram Bot
인프라:      Docker Compose
외부 API:    KIS Open API / Kiwoom Open API / DART OpenAPI
```

---

## 미정 항목

- 비정형 데이터 수집 대상 사이트 (크롤러 파서)
- 임베딩 모델 선택
- 정형 DB 세부 스키마 (테이블 명세)
- ADR 001~005 파일 복원

---

## 새 대화 시작 방법

이 INDEX.md를 첨부하거나 내용을 복사하여 "이어서 진행"이라고 하면 된다.
