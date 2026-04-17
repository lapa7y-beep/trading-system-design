# Seam 분류 심화 — ATLAS Port별 교체 난이도 분석

**목적**: Michael Feathers의 Seam 4 유형 분류를 ATLAS Phase 1의 6 Port에 적용하여, **각 Port의 교체 난이도·위험도·테스트 용이성**을 구조적으로 분석한다.

**독자**: 구현 착수 전 각 Port의 특성을 이해하고자 하는 개발자. 특히 Step 2(Port 추상화 도입) 직전에 정독 권장.

**기반 문헌**: Feathers, Michael. *Working Effectively with Legacy Code* (2004), Chapter 4 "The Seam Model".

---

## 1. Feathers의 Seam 4 유형 — 재정리

| 유형 | 교체 시점 | 교체 단위 | 언어/환경 예시 |
|------|---------|---------|-------------|
| **Preprocessor Seam** | 전처리 시점 | 매크로/include 치환 | C/C++ `#define`, `#ifdef` |
| **Link Seam** | 링크 시점 | 바이너리/라이브러리 | C/C++ 정적/동적 링크, Java classpath |
| **Object Seam** | 런타임 | 객체/메서드 디스패치 | Python, Java, C# DI |
| **Compile Seam** | 컴파일 시점 | 타입 파라미터 | C++ 템플릿, Rust 제네릭 |

각 Seam 유형의 교체 비용·안전성·관찰 용이성은 다음과 같이 비교된다.

| 지표 | Preprocessor | Link | Object | Compile |
|------|-------------|------|--------|---------|
| 교체 비용 | 낮음 (재빌드) | 중간 (재링크) | **최저 (설정)** | 높음 (재빌드) |
| 런타임 교체 | ✗ | ✗ | **✓** | ✗ |
| 테스트 주입 | 어려움 | 중간 | **쉬움** | 중간 |
| 동적 관찰 | ✗ | ✗ | **✓** | ✗ |
| 타입 안전성 | 낮음 | 낮음 | 중간 | **높음** |

**ATLAS의 선택**: Object Seam. Python Protocol + 런타임 DI + YAML 설정의 조합. 타입 안전성은 `mypy --strict` + `pydantic`으로 보강.

---

## 2. Object Seam의 하위 분류

Object Seam은 단일 유형이지만, 실무에서는 **교체 주기·상태 보유·외부 의존성**에 따라 세부 특성이 다르다. ATLAS Phase 1의 6 Port를 다음 4개 하위 유형으로 재분류한다.

### 2.1 Replaceable Seam (상시 교체형)

**특성**: 개발/검증/운영 단계마다 Adapter가 바뀜. 교체가 일상적.

**예시**: BrokerPort, MarketDataPort

**판단 기준**:
- Adapter 수 ≥ 3
- 각 환경(backtest / paper / live)마다 다른 Adapter 사용
- Port 시그니처의 안정성이 전체 시스템 안정성의 핵심

### 2.2 Stateful Seam (상태 보유형)

**특성**: Adapter 내부에 상태(연결, 세션, 트랜잭션)를 보유. 교체 시 상태 이관 또는 초기화 필요.

**예시**: StoragePort, MarketDataPort(실시간 스트리밍)

**판단 기준**:
- Adapter가 연결(connection)을 보유
- 재시작 시 복원 로직 필요
- 테스트 시 각 테스트마다 상태 초기화 fixture 필요

### 2.3 Observational Seam (관측용)

**특성**: 시스템의 주 흐름에 영향 없이 출력/알림만 수행. 실패해도 주 흐름 계속.

**예시**: NotifierPort

**판단 기준**:
- Port 호출 실패가 비즈니스 로직에 영향 없음
- 비동기 처리 가능
- 테스트에서 Null Object 주입만으로 충분

### 2.4 Deterministic Seam (결정적 제어형)

**특성**: 외부 비결정성(시간, 난수)을 격리. 테스트 결정성 확보가 핵심 목적.

**예시**: ClockPort

**판단 기준**:
- 테스트 시 반드시 Fake 주입 (실제 시스템 시간 사용 금지)
- Adapter가 상태 없음 (순수 함수형)
- 교체 자체보다 "테스트 가능성"이 도입 이유

---

## 3. Phase 1 6 Port의 분류 적용

각 Port를 위 4 하위 유형으로 분류하고, 교체 난이도·리스크·테스트 전략을 정리한다.

### 3.1 MarketDataPort — Replaceable + Stateful

**유형**: Replaceable Seam (3 Adapter: Fake/CSV/KIS) + Stateful Seam (KIS는 WebSocket 연결 보유)

**시그니처 (SSoT 발췌)**:
```python
class MarketDataPort(Protocol):
    def get_bar(self) -> Bar: ...
    def subscribe(self, symbol: str) -> None: ...
    def unsubscribe(self, symbol: str) -> None: ...
```

**교체 난이도**: **중** (Replaceable이지만 Stateful 때문에)

**핵심 리스크**:
- `FakeMarketData` → `CSVMarketData` 교체는 상태 없음 (쉬움)
- `CSVMarketData` → `KISMarketData` 교체는 WebSocket 연결 수립/복구 로직 필요 (주의)
- 재연결 중 bar 누락 가능성 — Port 시그니처에 `is_connected()` 또는 `last_error()` 추가 필요할 수 있음

**테스트 전략**:
- 단위 테스트: `FakeMarketData`로 고정 Bar 주입
- 통합 테스트: `CSVMarketData`로 재현 가능한 시계열 주입
- 시스템 테스트: `KISMarketData` 모의투자 환경에서 실시간 확인

**Stub 진화 경로**:
```
Step 0: FakeMarketData (고정 Bar 1개 반환)
Step 3: CSVMarketData (CSV 순차 리플레이)
Step 11b: KISMarketData (모의투자 실시간 스트림)
```

---

### 3.2 BrokerPort — Replaceable + Stateful

**유형**: Replaceable + Stateful (3 Adapter, MockBroker는 내부 체결 시뮬레이션 상태 보유)

**시그니처**:
```python
class BrokerPort(Protocol):
    def submit(self, order: Order) -> OrderAck: ...
    def cancel(self, order_id: str) -> CancelAck: ...
    def get_fills(self) -> list[Fill]: ...
```

**교체 난이도**: **높음**

**핵심 리스크**: Phase 1에서 **가장 민감한 Seam**.
- MockBroker → KISPaperBroker 교체 시 체결 지연·슬리피지·거부율이 드러남
- Four Critical Safeguards 중 "중복주문방지"가 이 Port에서 구현됨 (intent_id 기반)
- Port 시그니처에 `intent_id` 파라미터가 누락되면 교체 후 이중 주문 가능성

**시그니처 보완 필요성 검토**: Step 2 작성 시 Order 도메인 타입에 `intent_id: str` 필드를 반드시 포함할 것.

**테스트 전략**:
- 단위 테스트: `FakeBroker`로 즉시 체결 응답
- 시나리오 테스트: `MockBroker`로 지연/거부/부분체결 시뮬레이션
- 합격 기준 4 (halt 30초) 검증: `MockBroker.cancel_all()` 호출 시 모두 취소되는지

**Stub 진화 경로**:
```
Step 0: FakeBroker (submit → 즉시 Fill)
Step 7: MockBroker (지연, 슬리피지 모델 포함)
Step 11b: KISPaperBroker (KIS 모의투자 API)
```

---

### 3.3 StoragePort — Stateful (Replaceable 약함)

**유형**: Stateful 주. Replaceable 약함 (2 Adapter: InMemory/Postgres).

**시그니처**:
```python
class StoragePort(Protocol):
    def insert_order(self, order: Order) -> None: ...
    def insert_transition(self, t: FSMTransition) -> None: ...
    def get_positions(self) -> list[Position]: ...
    def get_orders(self, since: datetime) -> list[Order]: ...
```

**교체 난이도**: **중**

**핵심 리스크**:
- InMemory → Postgres 교체 시 **크래시 복구(합격기준 5)** 동작이 처음 드러남
- 트랜잭션 경계 설계가 시그니처에 노출되지 않음 — 내부 구현에 맡김
- Four Safeguards 중 "이벤트 내구성"이 Postgres WAL 패턴에 의존

**테스트 전략**:
- 단위 테스트: `InMemoryStorage` (dict 기반)
- 통합 테스트: `PostgresStorage` + testcontainers-postgres
- 크래시 시뮬레이션: Postgres 프로세스 강제 종료 후 재시작, 미완료 주문 복구 확인

**Stub 진화 경로**:
```
Step 0: InMemoryStorage (dict 저장)
Step 9: PostgresStorage (6테이블 DDL 적용)
```

---

### 3.4 ClockPort — Deterministic

**유형**: Deterministic Seam 전형.

**시그니처**:
```python
class ClockPort(Protocol):
    def now(self) -> datetime: ...
    def sleep(self, sec: float) -> None: ...
```

**교체 난이도**: **낮음**

**핵심 리스크**: 거의 없음. 단, **모든 시간 의존 로직이 ClockPort를 경유해야** 함. `datetime.now()` 직접 호출이 코드에 남아 있으면 테스트 결정성 깨짐.

**테스트 전략**:
- 단위 테스트: `FakeClock(frozen_at=datetime(2026,1,1,9,0))`로 시간 고정
- halt 30초 테스트: `FakeClock.advance(30)` 호출 후 상태 확인
- 린트 규칙: `datetime.now()`, `time.time()` 직접 호출 금지 (CI 체크)

**Stub 진화 경로**:
```
Step 0: SystemClock (표준 datetime.now())
Step 2: FakeClock 추가 (테스트 용도, 동시 존재)
```

ClockPort는 다른 Port와 달리 **Stub → Real 교체가 없다**. Step 0부터 SystemClock이 이미 실제 구현. FakeClock은 교체가 아닌 **테스트 전용 추가**.

---

### 3.5 NotifierPort — Observational

**유형**: Observational Seam 전형.

**시그니처**:
```python
class NotifierPort(Protocol):
    def alert(self, msg: str, level: str = "INFO") -> None: ...
```

**교체 난이도**: **최저**

**핵심 리스크**: 없음. 실패해도 주 흐름 무영향.

**Phase 1 제한**: Phase 1에서는 `ConsoleNotifier` (stdout 출력)만 구현. TelegramNotifier는 Phase 2 범위 (ADR-011 제외 목록).

**테스트 전략**:
- 단위 테스트: `NullNotifier` (아무 것도 안 함) 주입으로 충분
- 호출 검증 필요 시: `SpyNotifier` (호출 기록만)

**Stub 진화 경로**:
```
Step 0: ConsoleNotifier (실제 구현으로 즉시 시작)
```

NotifierPort 역시 Stub → Real 교체 없음. ConsoleNotifier가 Step 0부터 "단순하지만 실제".

---

### 3.6 StrategyPort — Replaceable (Phase 1은 단일 Adapter)

**유형**: 잠재적 Replaceable (Phase 2에서 다중 전략 지원 예정), Phase 1에서는 단일 Adapter.

**시그니처**:
```python
class StrategyPort(Protocol):
    def evaluate(self, bar: Bar, indicators: dict) -> Signal: ...
```

**교체 난이도 (Phase 1 기준)**: **낮음** (교체 대상 없음)  
**교체 난이도 (Phase 2 기준)**: **중** (복수 전략 병렬 실행 시 동기화 이슈)

**핵심 리스크 (Phase 1)**: 없음. 단일 `SMACrossStrategy` 구현만 존재.

**Phase 2 대비 시그니처 고려 사항**: Phase 1에서 `evaluate()` 시그니처를 확정할 때 **다중 전략 호출 시 충돌 없는 형태**여야 함. 구체적으로:
- 전략이 상태를 가지면 안 됨 (또는 Strategy 인스턴스별로 격리)
- 반환하는 Signal에 전략 식별자(`strategy_id`) 포함 검토

**테스트 전략**:
- 고정 입력 → 고정 출력 검증 (pure function-like)
- `evaluate()` 동일 입력 반복 호출 시 동일 출력 보장 (idempotency)

---

## 4. Port 교체 난이도 종합 매트릭스

| Port | 유형 | 난이도 | Adapter 수 | Port 변경 위험 | Phase 1 테스트 난이도 |
|------|------|-------|----------|-------------|-------------------|
| MarketDataPort | Replaceable + Stateful | 중 | 3 | 중 | 중 |
| BrokerPort | Replaceable + Stateful | **높음** | 3 | **높음** | 높음 |
| StoragePort | Stateful | 중 | 2 | 중 | 중 |
| ClockPort | Deterministic | 낮음 | 2 | 낮음 | 낮음 |
| NotifierPort | Observational | 최저 | 1 (Phase 1) | 최저 | 최저 |
| StrategyPort | Replaceable (약) | 낮음 (P1) | 1 | 중 (P2 대비) | 낮음 |

**전략적 시사점**:

- **집중 투자 대상**: BrokerPort. 시그니처 설계에 가장 많은 시간을 투자. intent_id, 부분 체결, 취소 응답 지연 등의 엣지 케이스를 전부 시그니처 수준에서 수용.
- **안전지대**: ClockPort, NotifierPort. Step 0부터 완성도 높은 상태로 시작 가능. 방법론 검증 초기에 방해 요인 없음.
- **중간 지대**: MarketDataPort, StoragePort. Phase 1 중반(Step 3, Step 9)에 주요 교체 발생. 해당 Step을 여유 있게 계획.
- **Phase 2 준비**: StrategyPort의 다중 전략 대비 시그니처 설계. Phase 1에서 미리 고려하지 않으면 Phase 2에서 Port Churn (안티패턴 2) 위험.

---

## 5. Seam 설계 검토 체크리스트 (Step 2 착수 전)

Step 2(Port 추상화 도입) 착수 직전에 다음 체크리스트를 통과해야 한다. 하나라도 실패하면 Step 2를 시작하지 않는다.

- [ ] 6 Port의 메서드 시그니처가 `docs/specs/ports-phase1.md`에 확정되어 있다
- [ ] BrokerPort의 Order 타입에 `intent_id: str` 필드가 있다 (중복주문방지)
- [ ] StoragePort의 메서드가 트랜잭션 경계를 가정하지 않는다 (구현 자유도 보장)
- [ ] ClockPort 외에 `datetime.now()` / `time.time()` 직접 호출이 금지됨이 명시되었다
- [ ] NotifierPort.alert()의 실패가 호출자에게 예외를 던지지 않음이 명시되었다
- [ ] StrategyPort.evaluate()가 순수 함수처럼 동작함이 명시되었다 (Phase 2 대비)
- [ ] 각 Port에 대응하는 FakeAdapter가 `atlas/adapters/fake_*.py` 에 존재한다

7개 항목 전부 통과 시 Step 2 착수. 통과하지 못한 항목은 Step 1.5 (ports spec refinement)로 별도 Step 신설하여 선행.

---

## 6. 관련 문서

- `docs/decisions/012-implementation-methodology.md` — 방법론 (본 문서는 이것의 심화)
- `docs/references/seam-map.md` — Seam 위치 지도 (본 문서는 난이도 분석)
- `docs/specs/ports-phase1.md` — Port 시그니처 SSoT
- Feathers, M. *Working Effectively with Legacy Code* (2004) — Chapter 4 Seam Model
