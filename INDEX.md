# ATLAS 문서 지도

> **기준**: Phase 1 확정본 (2026-04-17)
> **최상위 기준 문서**: [`docs/what/decisions/011-phase1-scope.md`](docs/what/decisions/011-phase1-scope.md)
> **SSoT**: [`graph_ir_phase1.yaml`](graph_ir_phase1.yaml)

---

## 독해 순서

### 경로 A — 구현을 바로 시작하려는 경우 (권장)

1. `docs/how/methodology.md` §1~6 — 방법론·어휘·17 Step 지도 (20분)
2. `docs/how/seam-map.md` §1~4 — 어휘가 어느 파일에 대응하는지 (10분)
3. `docs/run/PROGRESS.md` — 현재 Step 확인 (2분)
4. `docs/run/step-NN.md` — 해당 Step의 §4에 지정된 문서만 정독
5. 구현 시작

### 경로 B — 전체 설계를 먼저 파악하려는 경우

1. `docs/what/decisions/011-phase1-scope.md` — Phase 1 범위·합격기준
2. `docs/what/architecture/path1-design.md` — 6노드 상세 설계
3. `graph_ir_phase1.yaml` — 노드/엣지 정식 정의
4. `docs/what/specs/port-signatures-phase1.md` — 7 Port 시그니처
5. `docs/what/specs/domain-types-phase1.md` — 20 타입
6. `docs/how/methodology.md` — 방법론
7. 이후 경로 A의 3~5 반복

---

## 문서 3층 구조

```
What 층 (docs/what/)  — 시스템이 무엇인가. SSoT. 188항목 정합성 보존.
How 층  (docs/how/)   — 어떻게 증분하는가. Tracer Bullet + Walking Skeleton.
Run 층  (docs/run/)   — 지금 무엇을 하는가. 매일 한 Step.
```

---

## What 층 — `docs/what/`

### 결정 (decisions/) — 왜 이렇게 결정했는가

| # | 파일 | 내용 |
|---|------|------|
| 006 | `006-db-stack.md` | PostgreSQL + TimescaleDB 스택 선정 |
| 007 | `007-fsm-design.md` | 이중 레벨 FSM 설계 (종목군 + 개별 종목) |
| 008 | `008-data-collection.md` | 데이터 수집 원칙 및 파이프라인 구조 |
| **011** | `011-phase1-scope.md` | **Phase 1 범위·합격기준·구현순서 확정** |

### 아키텍처 (architecture/) — 어떻게 생겼는가

| 파일 | 내용 |
|------|------|
| `system-overview.md` | ATLAS 전체 아키텍처 개요 (5 Path, HR-DAG) |
| `path1-design.md` | Phase 1 거래 실행 경로 상세 설계 (6노드·14엣지) |
| `path1-node-blueprint.md` | Phase 1 6노드 내부 상세 (L3 Blueprint) |
| `fsm-design.md` | 거래 상태 머신 설계 (종목군 5상태 + 개별 13상태) |
| `cli-design.md` | atlas CLI 명령어 설계 (12명령·IPC·보안) |
| `db-stack.md` | 데이터 저장소 구조 (PostgreSQL·TimescaleDB·Redis) |
| `boot-shutdown.md` | 시스템 기동·종료·긴급정지·크래시복구 시퀀스 |
| `screens/screen-architecture.md` | 화면 아키텍처 (3카테고리·14화면·횡단감시) |

### 명세 (specs/) — 정확히 무엇인가

| 파일 | 내용 |
|------|------|
| `port-signatures-phase1.md` | Phase 1 Port 인터페이스 시그니처 (7 Port·31 메서드) |
| `adapter-spec-phase1.md` | Phase 1 Adapter 구현 명세 (16 Adapter·실패처리·전환규칙) |
| `domain-types-phase1.md` | Phase 1 도메인 타입 정의 (20개·Pydantic v2) |
| `config-schema-phase1.md` | Phase 1 설정 파일 스키마 (config.yaml·11섹션·브로커전환) |
| `error-handling-phase1.md` | Phase 1 에러 핸들링 매트릭스 (4계층·CB·SAFE_MODE·KIS코드) |
| `project-structure-phase1.md` | Phase 1 프로젝트 폴더 구조 (Hexagonal 3층·의존방향) |
| `test-strategy-phase1.md` | Phase 1 테스트 전략 (피라미드·합격기준 자동화·CI) |
| `quant-spec-phase1.md` | Phase 1 퀀트 명세 (전략수식·한국시장규칙·체결모델·백테스트재현성) |
| `synthetic-exchange-phase1.md` | 가상거래소 설계 (GBM시세생성·호가창·시나리오주입·MonteCarlo) |
| `db-schema-phase1.sql` | 실행 가능 DDL (6테이블) |

### 파이프라인 (pipelines/) — 데이터가 어떻게 흐르는가

| 파일 | 내용 |
|------|------|
| `data-collection.md` | 시세 데이터 수집 파이프라인 (정형·비정형·CSV) |
| `backtesting.md` | 백테스트 파이프라인 (이중 엔진·성과지표·전환기준) |

### 참고 (references/) — 보조 자료

| 파일 | 내용 |
|------|------|
| `glossary.md` | ATLAS 용어 사전 |
| `decision-log.md` | 설계 결정 이력 (시간순) |
| `kis-api-notes.md` | KIS Open API 사용 메모 (환경구분·인증·주의사항) |
| `design-validation-report.md` | Phase 1 설계 검증 보고서 (5차 교차검증·188항목) |

---

## How 층 — `docs/how/`

| 파일 | 내용 |
|------|------|
| `methodology.md` | 구현 방법론 (Tracer Bullet·Walking Skeleton·17 Step) |
| `seam-map.md` | Seam Map: 방법론 어휘 → 저장소 파일·코드 위치 매핑 |
| `seam-classification.md` | Port별 교체 난이도 분석 (Seam 4유형·7 Port 분류) |

---

## Run 층 — `docs/run/`

### 보조 문서

| 파일 | 내용 |
|------|------|
| `README.md` | Runbook 사용법, 매일 반복 루프, 규칙 |
| `TEMPLATE.md` | 7섹션 표준 템플릿 |
| `PROGRESS.md` | 17 Step 진행 상태 + Daily Log |

### 17 Step 실행 절차서

| Step | 파일 | 산출물 | 합격기준 | 예상 |
|------|------|-------|--------|------|
| 00 | `step-00.md` | Walking Skeleton 단일 파일 | 기반 | 1일 |
| 01 | `step-01.md` | 6파일 분리 | — | 0.5일 |
| 02 | `step-02.md` | Port 추상화 도입 (7 Port ABC + DI) | 기반 | 1일 |
| 03 | `step-03.md` | CSVReplayAdapter 구현 | 1 | 1일 |
| 04 | `step-04.md` | IndicatorCalculator 실제 (pandas-ta SMA) | 1 | 1일 |
| 05 | `step-05.md` | StrategyEngine 실제 (SMA 골든크로스) | 1 | 1일 |
| 06 | `step-06.md` | RiskGuard 포지션 한도 1체크 | 2 | 1일 |
| 07 | `step-07.md` | MockOrderAdapter + MockAccountAdapter + OrderExecutor 실제 | 2 | 1일 |
| 08a | `step-08a.md` | 개별 종목 FSM 기본 4상태 | 2 | 1일 |
| 08b | `step-08b.md` | 개별 종목 FSM 나머지 (13상태 완전) | 2, 5 | 1일 |
| 09 | `step-09.md` | DB 영속화 (PostgreSQL) | 3 | 2일 |
| 10a | `step-10a.md` | RiskGuard 손실한도 | 2 | 1일 |
| 10b | `step-10b.md` | RiskGuard 변동성/유동성 | 2 | 1일 |
| 10c | `step-10c.md` | CLI start/stop/status 3명령 | 기반 | 1일 |
| 10d | `step-10d.md` | CLI halt 30초 블록 | 4 | 1일 |
| 11a | `step-11a.md` | 백테스트 + Sharpe 계산 | 1 | 1일 |
| 11b | `step-11b.md` | 모의투자 5일 검증 | 2,3,4,5 | 5일 |

총 17 Step. 순수 개발 11일 + 모의투자 5일 = 16일.
상세 근거는 `docs/how/methodology.md` §6 참조.

---

## SSoT

| 파일 | 역할 |
|------|------|
| `graph_ir_phase1.yaml` | Phase 1 그래프 구조 (노드·엣지·Port·Adapter 전부) |

---

## Archive — `docs/archive/`

| 디렉토리 | 내용 |
|---------|------|
| `phase2plus/` | Phase 2 이후 복원 예정 (Path 3~6, 고급 Risk 등) |
| `phase3/` | Phase 3 LLM·지식그래프 관련 |
| `patches/` | 반영 완료된 델타 문서 (재사용 금지) |
