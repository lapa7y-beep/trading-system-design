# 구현 방법론 (Tracer Bullet·Walking Skeleton·17 Step)

> **목적**: Phase 1 구현의 증분 원칙(세 원칙), 어휘 정의, 17 Step 순서, 안티패턴을 확정한다.
> **층**: How

**상태**: Accepted
**작성일**: 2026-04-17
**관련**: ADR-011 (Phase 1 Scope), `docs/what/architecture/path1-design.md`, `docs/what/specs/project-structure-phase1.md`

---

## 1. Context

Phase 1 설계는 5차 교차 검증까지 완료되어 188개 항목의 정합성이 확보되었다. 그러나 설계 문서는 **"무엇을 만드는가(What)"** 에 집중되어 있으며, **"어떻게 점진적으로 증분하는가(How to grow)"** 에 대한 명시적 방법론이 부족했다.

## 2. Decision

Phase 1 및 이후 모든 Phase의 구현은 **Tracer Bullet Development** 방법론에 따른다.

1. 각 Phase는 **Walking Skeleton**으로 시작한다.
2. 이후 증분은 **Stepwise Stub Replacement** — 한 번에 한 노드의 stub을 실제 구현으로 교체.
3. 교체 작업은 **Port 경계를 불변점(invariant)** 으로 삼는다.
4. 증분 단위는 **세 원칙의 교집합**으로 결정한다.
5. 각 Step의 실행 절차는 **Step Runbook** (`docs/run/step-NN.md`)에 기록한다.

## 3. 문서 3층 구조

```
What 층 (기존 설계)  — 시스템이 무엇인가. SSoT. 불변 원칙.
  ├── ADR-011, path1-design.md, port-signatures-phase1.md, domain-types 등
  └── 5차 검증 188항목 정합성 보존

How 층 (방법론)      — 어떻게 증분하는가. 원칙과 분류.
  ├── ADR-012 (본 문서)
  ├── seam-map.md
  └── seam-classification.md

Run 층 (Runbook)     — 지금 무엇을 하는가. 매일 실행.
  ├── docs/run/step-00.md ~ step-11b.md (17개)
  ├── docs/run/PROGRESS.md
  └── docs/run/README.md, TEMPLATE.md
```

## 4. 어휘 정의

| 용어 | 정의 | ATLAS에서의 대응 |
|------|------|-----------------|
| **Scaffold** | 전체 구조의 껍데기 | Step 0 산출물 전체 |
| **Filter** | 데이터 파이프라인의 처리 단위 | Path 1의 6노드 (MarketDataReceiver, IndicatorCalculator, StrategyEngine, RiskGuard, OrderExecutor, TradingFSM) |
| **Seam** | 교체 가능 접합부 | Port 호출 지점 (Orchestrator가 Port를 호출하는 모든 위치) |
| **Port** | Seam을 규정하는 계약. 시그니처는 불변 | 6 Port: MarketDataPort, BrokerPort, StoragePort, ClockPort, StrategyRuntimePort, AuditPort |
| **Adapter** | Port를 구현하는 구체 클래스 | MockBrokerAdapter, CSVReplayAdapter 등 12 Adapter |
| **Stub** | Port를 만족하지만 실제 로직이 없는 임시 구현 | Step 0의 pass-through 함수들 |
| **Walking Skeleton** | 엔드투엔드 동작하는 최소 골격 | Step 0 ~ Step 2 종료 시점 |
| **Tracer Bullet** | 모든 층을 관통하는 가장 얇은 실행 가능 경로 | Step 0의 run_once() |
| **Stub Replacement** | Stub을 실제 구현으로 교체하는 행위 | Step 3 ~ Step 11의 각 Step |
| **Enabling Point** | Adapter 선택을 활성화하는 지점 | config.yaml의 mode 설정 키 (`config-schema-phase1.md` 참조) |
| **Step Runbook** | 한 Step의 완결된 실행 절차를 기록한 문서 | docs/run/step-NN.md |

> Filter들을 Scaffold로 먼저 세우고, Seam을 Port로 박은 뒤, Stub을 점진적으로 실제 구현으로 교체한다.

## 5. 증분 단위 결정의 세 원칙

### 원칙 1 — Vertical Slice Principle

한 Step은 하나의 관찰 가능한 행동 변화를 만든다. 예외: 구조적 경계점 (Phase 1에서 Step 1, 2만 해당).

### 원칙 2 — One-Day Rule

한 Step은 하루 안에 완료되고 테스트를 통과한다. 하루 초과 시 쪼갠다.

### 원칙 3 — Fitness Function Coverage

한 Step은 최소 하나의 합격 기준을 부분적으로라도 충족시킨다. Phase 1 합격 기준 (`011-phase1-scope.md §5`): (1) Sharpe > 1.0, (2) 모의투자 5일 무사고, (3) P&L 자동 기록, (4) halt 30초, (5) 크래시 복구.

## 6. Phase 1의 17 Step 확정

| Step | 산출물 | 관찰 변화 | 합격기준 | 참조 문서 | 예상 |
|------|-------|---------|--------|---------|------|
| 0 | Walking Skeleton 단일 파일 | 파이프라인 관통 | (기반) | `path1-design.md §2`, `domain-types-phase1.md §3.1~3.5`, `system-overview.md` | 1일 |
| 1 | 6파일 분리 | (구조, 행동 불변) | — | `project-structure-phase1.md §2,§10` | 0.5일 |
| 2 | 6 Port ABC + DI | (구조, 행동 불변) | — | `port-signatures-phase1.md` 전체, `adapter-spec-phase1.md §1~2`, `config-schema-phase1.md §1~2`, `seam-classification.md §5` | 1일 |
| 3 | CSVReplayAdapter | 실제 봉 흐름 | 1 | `data-collection.md §1`, `adapter-spec-phase1.md §4.3`, `domain-types-phase1.md §3.3` | 1일 |
| 4 | IndicatorCalculator 실제 | 실제 지표 값 | 1 | `path1-design.md §2.2` | 1일 |
| 5 | StrategyEngine 실제 | 조건부 신호 | 1 | `path1-design.md §2.3`, `domain-types-phase1.md §3.4` | 1일 |
| 6 | RiskGuard 포지션 한도 | 첫 거부 가능 | 2 | `path1-design.md §2.4,§5`, `error-handling-phase1.md §3.4` | 1일 |
| 7 | MockBrokerAdapter + OrderExecutor | 체결 응답 수신 | 2 | `adapter-spec-phase1.md §5.1`, `path1-design.md §2.5`, `error-handling-phase1.md §3.5` | 1일 |
| 8a | 개별 종목 FSM 기본 4상태 (IDLE/ORDER_PLACED/HOLDING/DONE) | 기본 전이 | 2 | `fsm-design.md §3` (IDLE~HOLDING~DONE 경로만) | 1일 |
| 8b | 개별 종목 FSM 나머지 (13상태 완전) | 전체 전이 | 2, 5 | `fsm-design.md` 전체, `boot-shutdown.md §3` | 1일 |
| 9 | DB 영속화 | 주문 DB 기록 | 3 | `db-schema-phase1.sql`, `006-db-stack.md`, `db-stack.md` | 2일 |
| 10a | RiskGuard 손실한도 | 손실 거부 | 2 | `path1-design.md §5`, `config-schema-phase1.md §5` | 1일 |
| 10b | RiskGuard 변동성 | 변동성 거부 | 2 | `path1-design.md §5` | 1일 |
| 10c | CLI start/stop/status | CLI 제어 | (기반) | `cli-design.md §2~5`, `boot-shutdown.md §2,§4` | 1일 |
| 10d | CLI halt 30초 | halt 동작 | 4 | `cli-design.md §5.2`, `boot-shutdown.md §5`, `fsm-design.md §3` (SUSPENDED) | 1일 |
| 11a | 백테스트 + Sharpe | Sharpe 산출 | 1 | `backtesting.md` 전체, `test-strategy-phase1.md §5.2` | 1일 |
| 11b | 모의투자 5일 검증 | 5일 무사고 | 2,3,4,5 | `011-phase1-scope.md §5`, `test-strategy-phase1.md §5`, `error-handling-phase1.md §11` | 5일 |

**총 17 Step, 순수 개발 약 11일 + 모의투자 5일 = 16일.**

## 7. Step별 완료 기준

1. **관찰 기준**: 관찰 가능한 변화가 실제로 관찰된다
2. **테스트 기준**: 기존 + 신규 테스트 최소 1개 통과
3. **불변 기준**: Step 2 이후 Port 시그니처 미변경
4. **커밋 기준**: 단일 커밋, Step 번호와 합격기준 매핑 명시
5. **문서 기준**: seam-map.md Stub 행 갱신, PROGRESS.md 체크

## 8. 안티패턴과 방어책

1. **Skeleton Never Grows** — Stub이 교체 안 됨. 방어: Phase 1 완료 시 Stub 전수 체크.
2. **Port Churn** — Port 시그니처 반복 변경. 방어: 변경 시 ADR 발행.
3. **Over-Scaffolded Skeleton** — Step 0 비대. 방어: 80줄 이하, 의존성 0.
4. **Fitness Orphan** — 합격기준 매핑 없는 Step. 방어: §6 테이블 확인.

## 9. 참고 문헌

- Hunt & Thomas, *The Pragmatic Programmer* (2019). Ch.7 Tracer Bullets.
- Cockburn, *Crystal Clear* (2004). Walking Skeleton.
- Feathers, *Working Effectively with Legacy Code* (2004). Seam Model.
- Meszaros, *xUnit Test Patterns* (2007). Stub/Mock/Fake.
- Wirth, "Program Development by Stepwise Refinement" (CACM, 1971).
- Buschmann et al., *POSA Vol.1* (1996). Pipe & Filter.

## 10. Status & Review

- 현재 상태: Accepted
- Phase 1 완료 후 재검토: 17 Step 구분이 세 원칙을 만족했는지 회고
