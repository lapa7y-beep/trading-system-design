# Seam Map — 어휘와 저장소 실제 위치 매핑

**목적**: ADR-012에서 정의한 어휘(Scaffold / Filter / Seam / Port / Adapter / Stub)를 저장소의 **실제 파일·라인·YAML 키**와 1:1 매핑한다.

**범위**: Phase 1 (Path 1의 6노드 + 6 Port + 12 Adapter).

**갱신 원칙**: Stub이 Real로 교체될 때마다 본 문서의 "현재 구현 상태" 컬럼을 갱신한다. Step N 완료 시 Step N 관련 행의 Status가 `stub → real`로 전환된다.

---

## 1. Filter — 6노드

Filter는 Path 1 파이프라인의 처리 단위다. 각 Filter는 `atlas/nodes/<name>.py` 한 파일에 대응한다.

| Filter | 파일 경로 | 주 책임 | Port 의존 | 현재 Status |
|--------|---------|---------|-----------|------------|
| MarketData | `atlas/nodes/market_data.py` | 시장 봉 데이터 공급 | MarketDataPort (out) | stub |
| Indicator | `atlas/nodes/indicator.py` | 기술적 지표 계산 | — | stub |
| Strategy | `atlas/nodes/strategy.py` | 매매 신호 생성 | — | stub |
| RiskGuard | `atlas/nodes/risk_guard.py` | 주문 전 리스크 체크 | StoragePort (조회) | stub |
| OrderExecutor | `atlas/nodes/order_executor.py` | 주문 실행 및 영속화 | BrokerPort, StoragePort | stub |
| TradingFSM | `atlas/nodes/trading_fsm.py` | 거래 상태 머신 | StoragePort (전이 기록) | stub |

**Orchestrator 위치**: `atlas/orchestrator.py`  
6 Filter를 순서대로 호출하는 조립자. Step 2 이후 Orchestrator는 **Port만 호출**하며, 구체 Adapter는 모른다.

---

## 2. Seam — 교체 가능 지점

Seam은 Orchestrator가 Port를 호출하는 **코드 위치**다. Step 2에서 박힌 이후 Phase 1 종료까지 위치와 시그니처는 불변.

Step 2 완료 시점의 Seam 목록 (라인 번호는 Step 2 커밋 기준, 구현 시 확정):

| Seam ID | 위치 | 호출 Port | 호출 시점 |
|---------|------|----------|---------|
| S-MD-1 | `atlas/orchestrator.py` — `run_once()` 초입 | `MarketDataPort.get_bar()` | 매 tick |
| S-BR-1 | `atlas/nodes/order_executor.py` — `execute()` 내부 | `BrokerPort.submit(order)` | 주문 발생 시 |
| S-BR-2 | `atlas/nodes/order_executor.py` — `execute()` 내부 | `BrokerPort.cancel(order_id)` | halt 발생 시 |
| S-ST-1 | `atlas/nodes/order_executor.py` — `execute()` 말미 | `StoragePort.insert_order(order)` | 주문 영속화 |
| S-ST-2 | `atlas/nodes/trading_fsm.py` — `transition()` 말미 | `StoragePort.insert_transition(t)` | FSM 전이 시 |
| S-ST-3 | `atlas/nodes/risk_guard.py` — `check()` 초입 | `StoragePort.get_positions()` | 리스크 체크 시 |
| S-CK-1 | `atlas/orchestrator.py` — 루프 조건 | `ClockPort.now()` | 매 tick |
| S-NT-1 | `atlas/nodes/risk_guard.py` — 거부 시 | `NotifierPort.alert(msg)` | 거부 발생 시 |
| S-NT-2 | `atlas/nodes/trading_fsm.py` — ERROR 진입 시 | `NotifierPort.alert(msg)` | 에러 상태 시 |

**Feathers의 Seam 분류 적용 (§5 참조)**: 위 Seam은 전부 **Object Seam**에 해당한다 (Python DI 기반).

---

## 3. Port — 계약 (Contract)

Port는 `atlas/ports/<name>_port.py`에 Protocol로 정의. 시그니처는 ADR-012 이후 **불변**.

| Port | 파일 경로 | 주요 메서드 | 구현 Adapter 수 |
|------|---------|-----------|---------------|
| MarketDataPort | `atlas/ports/market_data_port.py` | `get_bar()`, `subscribe(symbol)`, `unsubscribe(symbol)` | 3 |
| BrokerPort | `atlas/ports/broker_port.py` | `submit(order)`, `cancel(order_id)`, `get_fills()` | 2 |
| StoragePort | `atlas/ports/storage_port.py` | `insert_order`, `insert_transition`, `get_positions`, `get_orders` | 2 |
| NotifierPort | `atlas/ports/notifier_port.py` | `alert(msg, level)` | 2 |
| ClockPort | `atlas/ports/clock_port.py` | `now()`, `sleep(sec)` | 2 |
| StrategyPort | `atlas/ports/strategy_port.py` | `evaluate(bar, indicators)` | 1 (Phase 1) |

각 Port의 정확한 시그니처는 `docs/specs/ports-phase1.md` (SSoT)에 정의. 본 문서는 **위치 지도**일 뿐 계약 원본이 아니다.

---

## 4. Adapter — 구현체

Adapter는 `atlas/adapters/<name>.py`에 위치. 하나의 Port에 여러 Adapter가 대응 가능하며, 교체는 `config.yaml`의 한 줄로 이루어진다.

### 4.1 Adapter 목록 (Phase 1)

| Port | Adapter | 파일 경로 | 용도 | Step |
|------|---------|---------|------|------|
| MarketDataPort | FakeMarketData | `atlas/adapters/fake_market_data.py` | Step 0~2 pass-through | 0 |
| MarketDataPort | CSVMarketData | `atlas/adapters/csv_market_data.py` | 백테스트용 CSV 리플레이 | 3 |
| MarketDataPort | KISMarketData | `atlas/adapters/kis_market_data.py` | 모의투자 실시간 | 11b |
| BrokerPort | FakeBroker | `atlas/adapters/fake_broker.py` | Step 0~6 pass-through | 0 |
| BrokerPort | MockBroker | `atlas/adapters/mock_broker.py` | Step 7~11a 검증용 | 7 |
| BrokerPort | KISPaperBroker | `atlas/adapters/kis_paper_broker.py` | 모의투자 실제 연결 | 11b |
| StoragePort | InMemoryStorage | `atlas/adapters/in_memory_storage.py` | Step 0~8 pass-through | 0 |
| StoragePort | PostgresStorage | `atlas/adapters/postgres_storage.py` | Step 9 이후 영속화 | 9 |
| NotifierPort | ConsoleNotifier | `atlas/adapters/console_notifier.py` | Step 0 기본 | 0 |
| NotifierPort | TelegramNotifier | `atlas/adapters/telegram_notifier.py` | Phase 1 제외 (Phase 2) | — |
| ClockPort | SystemClock | `atlas/adapters/system_clock.py` | Step 0 기본 | 0 |
| ClockPort | FakeClock | `atlas/adapters/fake_clock.py` | 테스트용 시간 제어 | 2 |

### 4.2 Enabling Point — `config/phase1.yaml`

Adapter 선택은 단일 YAML 파일에서 이루어진다. Step 2 이후 Orchestrator는 이 YAML만을 본다.

```yaml
# config/phase1.yaml 구조
market_data:
  mode: csv          # fake | csv | kis
  path: data/samsung_2024.csv

broker:
  mode: mock         # fake | mock | kis_paper

storage:
  mode: postgres     # memory | postgres
  dsn: postgresql://atlas:atlas@localhost/atlas

clock:
  mode: system       # system | fake

notifier:
  mode: console      # console | telegram
```

**Enabling Point 개수**: 5 (Port 하나당 하나, Strategy 제외).

**교체 검증**: 각 Step 완료 후 해당 YAML 키를 다른 mode로 바꿔 기존 테스트가 여전히 통과하는지 확인 — Plug & Play Principle의 실증.

---

## 5. Feathers의 Seam 유형 분류

Michael Feathers는 Seam을 **교체 메커니즘**에 따라 네 유형으로 분류했다. Phase 1의 9개 Seam은 전부 **Object Seam**에 해당한다.

| 유형 | 교체 메커니즘 | 언어 예시 | Phase 1 사용 여부 |
|------|--------------|---------|----------------|
| **Preprocessor Seam** | 매크로 치환 | C/C++ `#define` | 해당 없음 |
| **Link Seam** | 링커가 다른 바이너리 선택 | C/C++ 정적 링크 | 해당 없음 |
| **Object Seam** | 런타임 객체 주입 | Python/Java DI | **전 Seam 이 유형** |
| **Compile Seam** | 컴파일 시점 타입 분기 | C++ 템플릿 | 해당 없음 |

**Object Seam의 함의**:

- 교체가 **런타임**에 일어남 — YAML 한 줄로 Adapter 변경 가능
- 교체 대상은 **Port를 구현한 객체** — Duck typing이 아닌 Protocol 기반 구조적 타이핑
- 테스트 시 **임의 Mock 주입 가능** — pytest fixture로 FakeBroker 주입

**교체 난이도 평가**: 모든 Seam이 Object Seam이므로 난이도 균일. Port 시그니처만 안정적이면 Adapter 교체는 항상 **YAML 한 줄 수정 + 테스트 재실행**.

---

## 6. Stub — 현재 "비어있는" 자리

각 Step의 진행에 따라 Stub 목록이 줄어든다. 본 섹션은 **현재 시점에 여전히 Stub인 위치**를 추적한다.

### 현재 Stub 목록 (Phase 1 착수 전)

| 위치 | 현재 내용 | 교체 예정 Step | 교체 후 |
|------|---------|-------------|--------|
| `nodes/market_data.py::get_bar()` | `return Bar(now, "005930", 100.0)` | Step 3 | CSV 읽기 |
| `nodes/indicator.py::compute()` | `return {"sma": bar.price}` | Step 4 | pandas-ta SMA(20) |
| `nodes/strategy.py::evaluate()` | `return Signal("BUY")` | Step 5 | SMA 골든크로스 |
| `nodes/risk_guard.py::check()` | `return True` | Step 6, 10a, 10b | 7체크 로직 |
| `nodes/order_executor.py::execute()` | `print("ORDER sent")` | Step 7 | MockBroker.submit() |
| `nodes/trading_fsm.py` | 2상태 (IDLE/IN_POSITION) | Step 8a, 8b | 10상태 23전이 |
| `adapters/fake_broker.py` | `return Fill(qty=order.qty)` 즉시 체결 | Step 7 | MockBroker로 교체 |
| `adapters/in_memory_storage.py` | Python dict | Step 9 | PostgreSQL |

### Stub 교체 체크리스트 (Phase 1 종료 시)

Phase 1 완료 시점에 **모든 Stub이 Real로 교체**되어야 한다. 남아있는 Stub은 ADR-012 안티패턴 1("Skeleton Never Grows")에 해당.

예외적으로 **테스트 전용 Fake**는 Phase 1 이후에도 유지:

- `FakeBroker` (Step 7 이후 테스트 fixture로만 사용)
- `FakeClock` (시간 의존 테스트용)
- `InMemoryStorage` (단위 테스트용, 통합 테스트는 Postgres)

이들은 Stub이 아닌 **Test Double**로 재분류된다 (Meszaros의 구분에 따름).

---

## 7. 매 Step 종료 후 본 문서 갱신 절차

Step N 완료 시:

1. §1 Filter 테이블의 해당 Filter Status 갱신 (`stub` → `real`)
2. §4.1 Adapter 테이블에 신규 Adapter 추가 (해당 Step이 새 Adapter를 도입한 경우)
3. §6 Stub 목록에서 교체 완료된 Stub 제거
4. 변경 사항을 Step N 커밋의 일부로 포함 (별도 커밋 금지)

이 갱신을 빠뜨리면 방법론 자기 감시가 실패한다. **Step 완료의 5번째 조건**으로 간주.

---

## 8. 관련 문서

- `docs/decisions/012-implementation-methodology.md` — 방법론 원칙 (본 문서의 상위 문서)
- `docs/specs/ports-phase1.md` — Port 시그니처 SSoT
- `docs/specs/project-structure-phase1.md` — 파일 레이아웃 상세
- `docs/architecture/path1-phase1.md` — Path 1 6노드 설계 상세
- `graph_ir_phase1.yaml` — 노드/엣지 정식 정의
