# ADR-012 — 구현 방법론: Tracer Bullet + Walking Skeleton + Stepwise Stub Replacement

**상태**: Accepted
**작성일**: 2026-04-17
**관련**: ADR-011 (Phase 1 Scope), `path1-phase1.md`, `project-structure-phase1.md`

---

## 1. Context

Phase 1 설계는 5차 교차 검증까지 완료되어 188개 항목의 정합성이 확보되었다. 그러나 설계 문서는 **"무엇을 만드는가(What)"** 에 집중되어 있으며, **"어떻게 점진적으로 증분하는가(How to grow)"** 에 대한 명시적 방법론이 부족했다.

이 공백은 두 가지 실제 문제를 낳는다.

첫째, 설계 완성도에 비해 구현 착수 부담이 비대칭적으로 크게 느껴진다. 6노드·14엣지·20 Domain Types·6 Port·12 Adapter를 어떤 순서로 만들어야 하는지 판단 기준이 문서 내부에 분산되어 있어, 착수 시점마다 매번 재탐색이 필요하다.

둘째, 증분 단위에 대한 명시적 규율이 없다. "한 번에 어느 정도를 만들고, 언제 테스트를 통과시키고, 언제 커밋하는가"가 합의되지 않으면 증분이 비대해지고, 비대해진 증분은 깨진 상태로 며칠을 끈다.

## 2. Decision

Phase 1 및 이후 모든 Phase의 구현은 **Tracer Bullet Development** 방법론에 따른다. 구체적으로:

1. 각 Phase는 **Walking Skeleton**으로 시작한다 — 해당 Phase의 모든 노드를 pass-through stub으로 관통하는 최소 실행 경로를 먼저 구축한다.
2. Walking Skeleton 이후의 증분은 **Stepwise Stub Replacement** — 한 번에 한 노드의 stub을 실제 구현으로 교체한다.
3. 교체 작업은 **Port 경계를 불변점(invariant)** 으로 삼는다. Port 시그니처가 유지되는 한, 어떤 Adapter/구현체 교체도 파괴적 변경이 아니다.
4. 증분 단위는 **세 원칙의 교집합**으로 결정한다: Vertical Slice, One-Day Rule, Fitness Function Coverage.
5. 각 Step의 실행 절차는 **Step Runbook** (`docs/runbooks/step-NN.md`)에 기록한다.

## 3. 문서 3층 구조

본 방법론 도입 후 저장소의 문서는 세 층으로 구성된다.

```
What 층 (기존 설계)  — 시스템이 무엇인가. SSoT. 불변 원칙.
  ├── ADR-011, path1-phase1.md, ports-phase1.md, domain-types 등
  └── 5차 검증 188항목 정합성 보존

How 층 (방법론)      — 어떻게 증분하는가. 원칙과 분류.
  ├── ADR-012 (본 문서)
  ├── seam-map.md
  └── seam-classification.md

Run 층 (Runbook)     — 지금 무엇을 하는가. 매일 실행.
  ├── docs/runbooks/step-00.md ~ step-11b.md (17개)
  ├── docs/runbooks/PROGRESS.md
  └── docs/runbooks/README.md, TEMPLATE.md
```

**관계**: Run 층은 What 층을 포인터로 참조한다. 내용을 복제하지 않는다. What 층의 변경은 ADR 발행을 경유한다.

## 4. 어휘 정의

이후 모든 설계/구현 문서에서 다음 어휘는 본 ADR의 정의를 따른다.

| 용어 | 정의 | ATLAS에서의 대응 |
|------|------|-----------------|
| **Scaffold** | 전체 구조의 껍데기. 동작은 최소화하고 형태만 갖춘 골격 | Step 0 산출물 전체 |
| **Filter** | 데이터 파이프라인의 처리 단위. 입력을 받아 변형하여 출력하는 노드 | Path 1의 6노드 각각 |
| **Seam** | 해당 지점을 수정하지 않고도 동작을 바꿀 수 있는 장소. 교체 가능 접합부 | Port 호출 지점 |
| **Port** | Seam을 규정하는 계약(contract). 시그니처는 불변 | 6 Port 인터페이스 |
| **Adapter** | Port를 구현하는 구체 클래스. 교체 가능 | MockBroker, CSVMarketData 등 12 Adapter |
| **Stub** | Port를 만족하지만 실제 로직이 없는 임시 구현 | Step 0의 pass-through 함수들 |
| **Walking Skeleton** | 모든 구성 요소의 아주 작은 구현을 갖고 있지만 엔드투엔드로 동작하는 최소 골격 | Step 0 ~ Step 2 종료 시점 |
| **Tracer Bullet** | 시스템의 모든 층을 관통하는 가장 얇은 실행 가능 경로 | Step 0의 run_once() 호출 경로 |
| **Stub Replacement** | Stub을 실제 구현으로 교체하는 행위. 시그니처는 유지 | Step 3 ~ Step 11의 각 Step |
| **Enabling Point** | Adapter 선택을 활성화하는 지점 | config.yaml의 mode 설정 키 |
| **Step Runbook** | 한 Step의 완결된 실행 절차를 기록한 문서 | docs/runbooks/step-NN.md |

**한 줄 정식**:

> Filter들을 Scaffold로 먼저 세우고, Seam을 Port로 박은 뒤, Stub을 점진적으로 실제 구현으로 교체한다.

## 5. 증분 단위 결정의 세 원칙

### 원칙 1 — Vertical Slice Principle

**한 Step은 하나의 관찰 가능한 행동 변화를 만든다.**

Step의 단위는 코드 줄 수나 파일 수가 아닌 외부 관찰 가능성으로 판단한다.

예외: 구조적 경계점(structural boundary step). Phase 1에서는 Step 1, Step 2만 해당. Phase당 최대 2~3개.

### 원칙 2 — One-Day Rule

**한 Step은 하루 안에 완료되고 테스트를 통과한다.**

하루를 초과하는 Step은 쪼갠다. 쪼갤 수 없다면 범위 설정이 틀렸거나 설계 부채가 있는 것이다.

### 원칙 3 — Fitness Function Coverage

**한 Step은 최소 하나의 합격 기준을 부분적으로라도 충족시킨다.**

Phase 1 합격 기준 (ADR-011):

1. 백테스트 Sharpe > 1.0
2. 모의투자 5일 incident-free
3. 일일 P&L 자동 기록
4. `atlas halt` 30초 블록
5. 크래시 복구

## 6. Phase 1의 17 Step 확정

| Step | 산출물 | 관찰 가능한 변화 | 합격기준 | 참조 문서 (Runbook §4에서 상세화) | 예상 |
|------|-------|----------------|---------|-------------------------------|------|
| 0 | Walking Skeleton 단일 파일 | 파이프라인 관통 | (기반) | path1-phase1 §노드목록, domain-types §Bar/Signal/Order/Fill | 1일 |
| 1 | 6파일 분리 | (구조, 행동 불변) | — | project-structure §폴더구조 | 0.5일 |
| 2 | 6 Port Protocol + DI | (구조, 행동 불변) | — | ports-phase1 전체, seam-classification §5 체크리스트 | 1일 |
| 3 | CSVMarketData Adapter | 실제 봉이 흐름 | 1 | data-collection §CSV형식, adapters §CSVMarketData | 1일 |
| 4 | Indicator 실제 (SMA) | 실제 지표 값 | 1 | path1-phase1 §Indicator | 1일 |
| 5 | Strategy 실제 (골든크로스) | 조건부 신호 | 1 | path1-phase1 §Strategy | 1일 |
| 6 | RiskGuard 포지션 한도 | 첫 거부 가능 | 2 | path1-phase1 §RiskGuard | 1일 |
| 7 | MockBroker + OrderExecutor | 체결 응답 수신 | 2 | adapters §MockBroker, path1-phase1 §OrderExecutor | 1일 |
| 8a | FSM 3상태 | 기본 전이 | 2 | fsm-design §상태목록(IDLE/IN_POSITION/EXIT_PENDING) | 1일 |
| 8b | FSM 나머지 | 10상태 23전이 | 2, 5 | fsm-design 전체 | 1일 |
| 9 | DB 영속화 | 주문 DB 기록 | 3 | db-schema-phase1.sql, db-stack 전체 | 2일 |
| 10a | RiskGuard 손실한도 | 손실 거부 | 2 | path1-phase1 §RiskGuard 체크항목 | 1일 |
| 10b | RiskGuard 변동성 | 변동성 거부 | 2 | path1-phase1 §RiskGuard 체크항목 | 1일 |
| 10c | CLI start/stop/status | CLI 제어 | (기반) | cli-design 전체 | 1일 |
| 10d | CLI halt 30초 | halt 동작 | 4 | cli-design §halt, fsm-design §HALTED | 1일 |
| 11a | 백테스트 + Sharpe | Sharpe 산출 | 1 | backtesting 전체 | 1일 |
| 11b | 모의투자 5일 검증 | 5일 무사고 | 2 | 011-phase1-scope §합격기준 | 5일 |

**총 17 Step, 순수 개발 약 11일 + 모의투자 5일 = 16일.**

## 7. Step별 완료 기준

각 Step은 다음 다섯 조건을 모두 만족할 때 완료된다.

1. **관찰 기준**: 해당 Step의 관찰 가능한 변화가 실제로 관찰된다
2. **테스트 기준**: 기존 테스트 전부 + 신규 테스트 최소 1개 통과
3. **불변 기준**: Step 2 이후라면 Port 시그니처 미변경
4. **커밋 기준**: 단일 커밋, Step 번호와 합격기준 매핑 명시
5. **문서 기준**: seam-map.md Stub 행 갱신, PROGRESS.md 체크 + Daily Log

커밋 메시지 템플릿:

```
Step NN: <한 줄 요약>

Observable change: <무엇이 관찰 가능하게 바뀌는가>
Fitness criteria:  <합격기준 번호들>
Port changes:      none (or: <변경 내역>)
Tests added:       <신규 테스트 목록>
```

## 8. 안티패턴과 방어책

### 안티패턴 1 — Skeleton Never Grows (영원한 해골)

Stub이 교체되지 않고 남는 현상. 방어: Phase 1 완료 시 Stub 전수 체크. seam-map.md §6 참조.

### 안티패턴 2 — Port Churn (포트 변덕)

Port 시그니처 반복 변경. 방어: 변경 시 ADR 수준 결정. Step 중간 변경 금지.

### 안티패턴 3 — Over-Scaffolded Skeleton (비대한 해골)

Step 0이 Phase 1 범위를 넘어섬. 방어: Step 0은 80줄 이하, 의존성 0.

### 안티패턴 4 — Fitness Orphan (고아 Step)

합격 기준에 매핑 안 되는 Step. 방어: §6 테이블의 합격기준 컬럼 비어있으면 재검토. 기반 Step은 Phase당 최대 4개.

## 9. Phase 2+ 일반화

새 노드는 항상 Stub으로 먼저 pass-through 연결 후 이후 Step에서 실체화. Port 경계 덕분에 기존 흐름 파괴 없음.

## 10. 참고 문헌

### 직접 근거

- Hunt & Thomas, *The Pragmatic Programmer* (2019). Ch.7 Tracer Bullets.
- Cockburn, *Crystal Clear* (2004). Walking Skeleton.
- Feathers, *Working Effectively with Legacy Code* (2004). Seam Model.
- Meszaros, *xUnit Test Patterns* (2007). Stub/Mock/Fake.

### 배경 원리

- Wirth, "Program Development by Stepwise Refinement" (CACM, 1971).
- Beck, *Test-Driven Development* (2002).
- Ford et al., *Building Evolutionary Architectures* (2017).

### 아키텍처 결합

- Cockburn, "Hexagonal Architecture" (2005).
- Buschmann et al., *POSA Vol.1* (1996). Pipe & Filter.
- Martin, *Clean Architecture* (2017). Ch.7 Boundaries.

## 11. Status & Review

- 현재 상태: Accepted
- Phase 1 완료 후 재검토: 17 Step 구분이 세 원칙을 만족했는지 회고
- 변경 이력: 어휘/원칙 변경은 새 ADR 발행
