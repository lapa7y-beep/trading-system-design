# INDEX — 트레이딩 시스템 설계 마스터 인덱스

> 최종 업데이트: 2026-04-16  
> 새 대화 시작 시 이 문서를 먼저 참조한다

---

## 프로젝트 개요

KIS(한국투자증권) + Kiwoom Open API 기반 반자동 트레이딩 시스템.  
LLM은 advisor 역할만, 사람이 최종 승인, 실전 코드와 백테스트 코드 공유.

---

## 핵심 확정 사항 (2026-04-16 기준)

### 시스템 성격

- **반자동** — 신호 생성은 자동, 주문 실행은 사람 승인 후
- **외부 인터페이스** — jdw 입장에서는 대화 기반 Agent처럼 보임
- **내부 실행 엔진** — FSM이 제어. LLM은 FSM 내부에 개입하지 않음
- **Telegram(S7)** — 운영 제어 인터페이스, 매매 판단 인터페이스 아님
- **증권사** — KIS + Kiwoom 양쪽 (BrokerPort 어댑터 교체)

### LLM 역할 3분리 (ADR-010)

```
LLM = 관제사 + 감시카메라  /  FSM = 신호 시스템(레일)  /  jdw = 최종 승인

역할 1 — 활성화 판단 (LLM):  시나리오를 FSM에 넘길지 말지 결정
역할 2 — 경로 실행 (FSM):    정해진 상태 전이 그대로 실행, LLM 개입 없음
역할 3 — 감시·보고 (LLM):    전체 FSM 상태 파악 → jdw에게 보고·제안

LLM이 절대 하지 않는 것: FSM 경로 중간 개입 / 실시간 주문 판단 / 경로 임의 변경
```

### DB 스택 (ADR-006)

```
서비스 2개만:
  postgres  — PostgreSQL 16 + TimescaleDB + pgvector + AGE
  redis     — Redis 7 (이벤트 버퍼 + FSM 상태 캐시)

점진적 분리 경로 (현재 불필요):
  pgvector → ChromaDB  (벡터 검색 latency 문제 시)
  AGE → Neo4j          (그래프 규모 급증 시)
  Redis → Kafka        (이벤트 처리량 급증 시)
```

### 데이터 수집 원칙 (ADR-008)

```
저장 기준: 한정 기간만 제공되는 수치 데이터만 저장
저장 안 함: 재무제표, 종목기본정보, 공시 목록 (언제든 API 조회 가능)

Phase 1 저장 항목:
  - OHLCV 일봉 / 분봉 (1·5·30분)
  - 업종·지수 (KOSPI 등)
  - 기관·외인 수급
  - 프로그램 매매
  - FSM 상태 전이 이력
  - 주문·체결 이력
  - 감사 로그

비정형: IngestPort ABC (fetch/parse/get_metadata 3개 메서드)
        파서만 추가하면 코어 파이프라인 자동 연결
        현재 수집 대상 사이트·임베딩 모델 미정
```

### FSM 설계 (ADR-007)

```
이중 레벨:
  레벨 1 — 종목군 FSM (5개 상태): INACTIVE → ACTIVE ↔ SUSPENDED → CLOSING → CLOSED
  레벨 2 — 개별 종목 FSM (13개 상태): IDLE → WATCHING → SCENARIO_RUNNING →
           PENDING_APPROVAL → ORDER_PLACED → PARTIAL_FILLED → HOLDING ↔ RECONCILING →
           EXITING → DONE / ERROR / SUSPENDED

연동 원칙:
  군→개별 직접 제어 없음 — 개별이 전이 전 군 상태 참조만
  포지션 키 = (종목코드 + 증권사)
  종목당 활성 시나리오 1개 mutex
  DB 영속화 필수 (모든 전이 PostgreSQL 저장)

종목군 정의:
  시나리오 기반 (기본) — 시나리오 생성 시 대상 종목 목록이 군
  수동 그룹 (허용) — 사람이 임의 정의
```

### 전략 구조

```
StrategyPort (인터페이스) — 교체 가능한 추상화
  구현체 1: 시나리오 전략 — LLM 초안 → 사람 승인 → FSM 경로 실행
  구현체 2: 단순 지표 전략 — 이동평균·RSI 등 계산 기반
  구현체 3: 복합 전략 — 정형+비정형 데이터 결합

신호 = 트리거만, 실제 경로는 시나리오가 결정
```

### 백테스팅 프레임워크

```
이중 엔진:
  벡터 기반 — 전체 기간 배열 처리, 빠른 파라미터 탐색
  이벤트 기반 — 틱/봉 단위 FSM 재생, 실전 코드와 동일

실전 전환 기준: 모의 30일+ / 샤프 > 1.0 / MDD < 15%
모의투자: KIS + Kiwoom 양쪽 (settings.yaml broker: 교체)
포트폴리오: 복수 전략 × 복수 종목 동시 실행
```

### LLM 저장·교차 검증 (ADR-009, 010)

```
LLM 대화 저장 (Phase 3 구현):
  LangGraph StateGraph + PostgreSQL checkpointer
  적용: Knowledge·Strategy Path LLM 노드 + 감시·보고 LLM
  저장: 대화이력, 중간추론, activation_log(FSM 넘김 이력), monitoring_log

정형·비정형 교차 검증 (현재 구현 불가):
  전제: 정형+비정형 데이터 모두 수집·저장 중이어야 함
  Phase 5 이후, 데이터 존재 확인 후 구현
  유형: 이벤트 기반 / 감성-수치 상관 / 시나리오 사전 검증

Code Generator (구현 단계 2번):
  전제: 노드 내부 명세 완전 확정 후 시작 가능
  현재 노드 명세 미완성 → 시작 불가
  PathCanvas → Graph IR YAML → Python 코드 자동 생성
  구조만 생성, 비즈니스 로직은 사람 작성
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
2. Code Generator 설계 (Graph IR YAML → Python 코드 자동 생성)
3. Phase별 상세 구현

---

## 설계 결정 문서 (ADR)

| # | 문서 | 내용 | 상태 |
|---|------|------|------|
| 001 | decisions/001-hexagonal-architecture.md | Hexagonal Architecture 채택 | stable |
| 002 | decisions/002-trustgraph-scope.md | TrustGraph 배경지식용, 실시간 제외 | stable |
| 003 | decisions/003-pathcanvas-ui.md | PathCanvas UI (LiteGraph.js) | stable |
| 004 | decisions/004-storage-separation.md | 저장소 4종 분화 (구버전) | deprecated |
| 005 | decisions/005-ontology-postgres-first.md | PostgreSQL-first 전략 | stable |
| 006 | decisions/006-db-stack.md | DB 스택 확정 (postgres+redis 2개) | stable |
| 007 | decisions/007-fsm-design.md | FSM 이중 레벨 설계 (13개 상태) | stable |
| 008 | decisions/008-data-collection.md | 데이터 수집 원칙 + IngestPort | stable |
| 009 | decisions/009-cross-validation.md | 정형·비정형 교차 검증 설계 | stable |
| 010 | decisions/010-llm-storage-code-generator.md | LLM 대화 저장 + Code Generator | stable |

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

## 미정 항목 (추후 결정)

- 비정형 데이터 수집 대상 사이트 (크롤러 파서)
- 개인 직접 입력 UI 상세
- 임베딩 모델 선택
- 정형 DB 세부 스키마 (테이블 명세)

---

## 새 대화 시작 방법

이 INDEX.md를 첨부하거나 내용을 복사하여 "이어서 진행"이라고 하면 된다.
