# ADR-012 — 구현 방법론: Tracer Bullet + Walking Skeleton + Stepwise Stub Replacement

**상태**: Accepted  
**작성일**: 2026-04-17  
**관련**: ADR-011 (Phase 1 Scope), `docs/architecture/path1-phase1.md`, `docs/specs/project-structure-phase1.md`

---

## 1. Context

Phase 1 설계는 5차 교차 검증까지 완료되어 188개 항목의 정합성이 확보되었다. 그러나 설계 문서는 **"무엇을 만드는가(What)"** 에 집중되어 있으며, **"어떻게 점진적으로 증분하는가(How to grow)"** 에 대한 명시적 방법론이 부족했다.

이 공백은 두 가지 실제 문제를 낳는다.

첫째, 설계 완성도에 비해 구현 착수 부담이 비대칭적으로 크게 느껴진다. 6노드·14엣지·20 Domain Types·6 Port·12 Adapter를 **어떤 순서로** 만들어야 하는지 판단 기준이 문서 내부에 분산되어 있어, 착수 시점마다 매번 재탐색이 필요하다.

둘째, 증분 단위에 대한 명시적 규율이 없다. "한 번에 어느 정도를 만들고, 언제 테스트를 통과시키고, 언제 커밋하는가"가 합의되지 않으면 증분이 비대해지고, 비대해진 증분은 깨진 상태로 며칠을 끈다.

## 2. Decision

Phase 1 및 이후 모든 Phase의 구현은 **Tracer Bullet Development** 방법론에 따른다. 구체적으로:

1. 각 Phase는 **Walking Skeleton**으로 시작한다 — 해당 Phase의 모든 노드를 pass-through stub으로 관통하는 최소 실행 경로를 먼저 구축한다.
2. Walking Skeleton 이후의 증분은 **Stepwise Stub Replacement** — 한 번에 한 노드의 stub을 실제 구현으로 교체한다.
3. 교체 작업은 **Port 경계를 불변점(invariant)** 으로 삼는다. Port 시그니처가 유지되는 한, 어떤 Adapter/구현체 교체도 파괴적 변경이 아니다.
4. 증분 단위는 **세 원칙의 교집합**으로 결정한다: Vertical Slice, One-Day Rule, Fitness Function Coverage.

## 3. 어휘 정의

이후 모든 설계/구현 문서에서 다음 어휘는 본 ADR의 정의를 따른다.

| 용어 | 정의 | ATLAS에서의 대응 |
|------|------|-----------------|
| **Scaffold** | 전체 구조의 껍데기. 동작은 최소화하고 형태만 갖춘 골격 | Step 0 산출물 전체 (`atlas/walking_skeleton.py` 또는 6파일 분리 후 구조) |
| **Filter** | 데이터 파이프라인의 처리 단위. 입력을 받아 변형하여 출력하는 노드 | Path 1의 6노드 각각 (MarketData, Indicator, Strategy, RiskGuard, OrderExecutor, TradingFSM) |
| **Seam** | 해당 지점을 수정하지 않고도 동작을 바꿀 수 있는 장소. 교체 가능 접합부 | Port 호출 지점 (Orchestrator가 Port를 호출하는 모든 위치) |
| **Port** | Seam을 규정하는 계약(contract). 시그니처는 불변 | Path 1의 6 Port 인터페이스 (MarketDataPort 외) |
| **Adapter** | Port를 구현하는 구체 클래스. 교체 가능 | MockBroker, KISBrokerAdapter, CSVMarketData 등 12 Adapter |
| **Stub** | Port를 만족하지만 실제 로직이 없는 임시 구현 | Step 0의 `return Signal("BUY")` 같은 pass-through 함수 |
| **Walking Skeleton** | 모든 구성 요소의 아주 작은 구현을 갖고 있지만 엔드투엔드로 동작하는 최소 골격 | Step 0 ~ Step 2 종료 시점의 시스템 |
| **Tracer Bullet** | 시스템의 모든 층을 관통하는 가장 얇은 실행 가능 경로 | Step 0의 run_once() 호출 경로 |
| **Stub Replacement** | Stub을 실제 구현으로 교체하는 행위. 시그니처는 유지 | Step 3 ~ Step 11의 각 Step이 수행하는 작업 |
| **Enabling Point** | Adapter 선택을 활성화하는 지점 | `config.yaml`의 `broker.mode: mock` 같은 설정 한 줄 |

**한 줄 정식**:

> Filter들을 Scaffold로 먼저 세우고, Seam을 Port로 박은 뒤, Stub을 점진적으로 실제 구현으로 교체한다.

## 4. 증분 단위 결정의 세 원칙

### 원칙 1 — Vertical Slice Principle

**한 Step은 하나의 관찰 가능한 행동 변화를 만든다.**

Step의 단위는 코드 줄 수나 파일 수가 아닌 **외부 관찰 가능성**으로 판단한다. `run_once()`의 출력, 테스트의 합격 조건, 로그의 새 라인 — 이 중 최소 하나가 전 Step과 달라져야 한다.

**예외**: 구조적 경계점(structural boundary step). 외부 행동은 불변이지만 이후 Step들의 안전성을 확보하기 위한 구조 변경만을 수행하는 Step. Phase 1에서는 Step 1(파일 분리)과 Step 2(Port 추상화 도입) 두 개만 이에 해당한다. 구조적 경계점은 Phase당 최대 2~3개를 넘지 않는다.

### 원칙 2 — One-Day Rule

**한 Step은 하루 안에 완료되고 테스트를 통과한다.**

하루를 초과하는 Step은 쪼갠다. 쪼갤 수 없다면 범위 설정이 틀렸거나 설계 부채가 있는 것이다.

하루 단위의 세 가지 근거:

- 인간 집중력의 자연 단위 — 맥락 재진입 비용 최소화
- 실패 시 버리는 비용의 상한선 — 실험 정신 유지
- 일일 리듬의 형성 — "오늘 무엇을 끝낼 것인가"의 매일 명확성

### 원칙 3 — Fitness Function Coverage

**한 Step은 최소 하나의 합격 기준을 부분적으로라도 충족시킨다.**

Phase 1의 합격 기준(ADR-011 참조):

1. 백테스트 Sharpe > 1.0
2. 모의투자 5일 incident-free
3. 일일 P&L 자동 기록
4. `atlas halt` 30초 블록
5. 크래시 복구

각 Step은 위 5개 중 어느 것에 기여하는지 명시한다. 매핑이 안 되는 Step은 현재 Phase 범위 밖이며, 다음 Phase로 이월한다.

### 세 원칙의 교집합

```
원칙 1 통과 + 원칙 2 통과 + 원칙 3 통과 = 올바른 Step

원칙 1 실패 → 내부 작업. 다른 Step에 흡수
원칙 2 실패 → 과대. 쪼개기
원칙 3 실패 → Phase 밖. 다음 Phase로 이월
```

## 5. Phase 1의 17 Step 확정

세 원칙을 엄격히 적용한 Phase 1 증분 순서.

| Step | 산출물 | 관찰 가능한 변화 | 합격기준 매핑 | 예상 |
|------|-------|----------------|-------------|------|
| 0 | Walking Skeleton 단일 파일 | 파이프라인이 처음부터 끝까지 흐름 | (기반) | 1일 |
| 1 | 6파일 분리 | (구조 변경, 행동 불변) | — | 0.5일 |
| 2 | 6 Port Protocol + DI 도입 | (구조 변경, 행동 불변) | — | 1일 |
| 3 | CSVMarketData Adapter | 실제 KOSPI 봉이 흐름 | 1 | 1일 |
| 4 | Indicator 실제 (pandas-ta SMA) | 실제 지표 값 산출 | 1 | 1일 |
| 5 | Strategy 실제 (SMA 골든크로스) | 조건부 신호 발생 | 1 | 1일 |
| 6 | RiskGuard 포지션 한도 1체크 | 첫 주문 거부 발생 가능 | 2 | 1일 |
| 7 | MockBroker + OrderExecutor 실제 | 체결 응답 수신 | 2 | 1일 |
| 8a | FSM 3상태 (IDLE/IN_POSITION/EXIT_PENDING) | 기본 전이 관찰 | 2 | 1일 |
| 8b | FSM 나머지 상태 (ERROR/RECONCILING/HALTED 등) | 10상태 23전이 완전 동작 | 2, 5 | 1일 |
| 9 | DB 영속화 (orders, fsm_transitions) | 주문이 DB에 기록 | 3 | 2일 |
| 10a | RiskGuard 손실한도 (일일/포지션별) | 손실 한도 거부 | 2 | 1일 |
| 10b | RiskGuard 변동성/유동성 체크 | 변동성 기반 거부 | 2 | 1일 |
| 10c | CLI start/stop/status 3명령 | CLI로 제어 가능 | (기반) | 1일 |
| 10d | CLI halt 30초 블록 | halt가 30초 내 전 주문 취소 | 4 | 1일 |
| 11a | 백테스트 엔진 + Sharpe 계산 | Sharpe 수치 산출 | 1 | 1일 |
| 11b | 모의투자 5일 검증 | 5일 연속 무사고 | 2 | 5일 (실시간) |

**총 17 Step, 순수 개발 약 11일 + 모의투자 검증 5일 = 16일.**

## 6. Step별 완료 기준

각 Step은 다음 네 조건을 **모두** 만족할 때 완료된다.

1. **관찰 기준**: 해당 Step의 "관찰 가능한 변화"가 실제로 관찰된다 (로그, 테스트 출력, DB 레코드 등)
2. **테스트 기준**: 기존 테스트 전부 + 이 Step의 신규 테스트 최소 1개가 통과한다
3. **불변 기준**: Step 2 이후라면 Port 시그니처가 변경되지 않았다
4. **커밋 기준**: 단일 Git 커밋으로 기록되며, 커밋 메시지에 Step 번호와 합격기준 매핑을 명시한다

**커밋 메시지 템플릿**:

```
Step N: <한 줄 요약>

Observable change: <무엇이 관찰 가능하게 바뀌는가>
Fitness criteria:  <합격기준 번호들>
Port changes:      none (or: <변경 내역>)
Tests added:       <신규 테스트 목록>
```

## 7. 방법론의 한계와 안티패턴

이 방법론에는 문헌에 기록된 실패 패턴이 있다. Phase 1 진행 중 다음 신호가 감지되면 즉시 점검한다.

### 안티패턴 1 — Skeleton Never Grows (영원한 해골)

Stub이 Step 8, 9, 10에서도 교체되지 않고 남는 경우. "일단 돌아가니까" 로직 구현을 미루는 현상.

**방어책**: 각 Step의 명시적 Stub Replacement 대상을 Step 정의에 포함. Step 11(백테스트 Sharpe) 시점에 모든 Phase 1 stub이 교체 완료되어야 함을 체크리스트로 관리.

### 안티패턴 2 — Port Churn (포트 변덕)

Port 시그니처를 반복적으로 변경하는 현상. Port 불변 원칙이 무너지면 모든 Adapter와 호출 측이 연쇄 수정된다.

**방어책**: Port 시그니처 변경은 ADR 수준의 결정. Step 중간에 임의 변경 금지. 변경 필요 시 Phase 중단 후 ADR 작성 → 전체 테스트 재설계.

### 안티패턴 3 — Over-Scaffolded Skeleton (비대한 해골)

Walking Skeleton 단계에서 이후 Phase의 구조까지 미리 반영하는 현상. Step 0이 며칠씩 걸리고 Phase 1 범위를 넘어선다.

**방어책**: Step 0의 파일은 80줄 이하, 함수 6개, 의존성 0 (표준 라이브러리만). 넘으면 Step 0 범위 위반.

### 안티패턴 4 — Fitness Orphan (고아 Step)

어떤 합격 기준에도 매핑되지 않는 Step이 존재하는 현상.

**방어책**: 본 ADR §5 테이블의 "합격기준 매핑" 컬럼이 비어 있는 Step은 착수 전 재검토. 기반 Step(0, 1, 2, 10c)은 "기반"으로 명시하며, Phase당 4개를 넘지 않는다.

## 8. Phase 2+ 로의 일반화

Phase 2 이후에도 동일 방법론을 적용한다.

```
새 노드 추가 = 해당 노드를 Stub으로 먼저 pass-through 연결
             → 이후 Step들에서 Stub을 실제 구현으로 교체
```

Phase 2의 Screener 노드 도입을 예로 들면:

```
Step N   : Screener pass-through (하드코딩 리스트 반환)
Step N+1 : Watchlist pass-through
Step N+2 : Screener 실제 로직 (거래량 상위 N)
Step N+3 : Watchlist 실제 로직
Step N+4 : Screener → Strategy 엣지 연결
```

Phase 1에서 확립한 Port 경계 덕분에, 새 노드 도입이 기존 흐름을 파괴하지 않는다. 이것이 HR-DAG 설계의 "Plug & Play Principle"과 본 방법론의 결합 지점이다.

## 9. 참고 문헌

### 직접 근거

- Hunt, Andrew & Thomas, David. *The Pragmatic Programmer* (20주년판, 2019). Chapter 7: Tracer Bullets.
- Cockburn, Alistair. *Crystal Clear: A Human-Powered Methodology for Small Teams* (2004). Walking Skeleton 정의.
- Feathers, Michael. *Working Effectively with Legacy Code* (2004). Seam 개념의 바이블.
- Meszaros, Gerard. *xUnit Test Patterns* (2007). Stub/Mock/Fake 구분.

### 배경 원리

- Wirth, Niklaus. "Program Development by Stepwise Refinement". *CACM* 14(4), 1971. 점진적 정제의 원조.
- Beck, Kent. *Test-Driven Development: By Example* (2002). Stub Replacement의 일상화.
- Ford, Neal et al. *Building Evolutionary Architectures* (2017). Fitness Function 개념.

### 아키텍처 결합

- Cockburn, Alistair. "Hexagonal Architecture" (2005). Port/Adapter 원 논문.
- Buschmann, Frank et al. *Pattern-Oriented Software Architecture Vol.1* (1996). Pipe & Filter 패턴.
- Martin, Robert. *Clean Architecture* (2017). Chapter 7: Boundaries.

## 10. Status & Review

- **현재 상태**: Accepted, Phase 1 착수 직전 확정
- **Phase 1 완료 후 재검토**: 17 Step 구분이 실제로 세 원칙을 만족했는지 회고 (retrospective)
- **변경 이력**: 본 ADR의 어휘/원칙 변경은 새 ADR 발행 (012-rev, 012.1 등)
