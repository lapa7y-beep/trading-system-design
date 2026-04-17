# Phase 1 테스트 전략 (피라미드·합격기준 자동화·CI)

> **목적**: Phase 1 구현 시작 전, 단위/통합/합격 기준 테스트의 범위·도구·자동화 수준을 단일 문서로 정의.
> **층**: What
> **상태**: Phase 1 확정
> **최종 수정**: 2026-04-17
> **구현 여정**: 각 Step의 테스트 작성 시점은 ADR-012 §8 표 참조. Step별 합격 기준은 Runbook step-NN.md §4.
> **선행 문서**: `docs/what/decisions/011-phase1-scope.md` (합격 기준), `docs/what/specs/project-structure-phase1.md` (tests/ 폴더 구조), `docs/what/specs/error-handling-phase1.md` (실패 시나리오)

## 1. 테스트 피라미드

```
              ┌───────────────────────┐
              │  Acceptance Tests (5) │  ← 합격 기준 자동 검증
              │      느림, 고비용        │
              ├───────────────────────┤
              │   Integration Tests    │  ← 노드 조합, E2E 백테스트
              │       보통              │
              ├───────────────────────┤
              │     Unit Tests         │  ← 각 함수/클래스 단위
              │    빠름, 저비용         │
              └───────────────────────┘
```

**비율 목표 (Phase 1)**
- Unit: 70% (수량 기준)
- Integration: 25%
- Acceptance: 5%

**커버리지 목표**: core/domain 100%, core/nodes 80% 이상, adapters 60% 이상 (Real 어댑터는 통합 테스트로 검증).

---

## 2. 도구 스택

| 용도 | 도구 | 비고 |
|------|------|------|
| 테스트 러너 | `pytest` | `pyproject.toml`에 설정 |
| 비동기 | `pytest-asyncio` | mode=auto |
| 커버리지 | `pytest-cov` | `--cov=atlas --cov-report=html` |
| Mock | `unittest.mock` + `pytest-mock` | 외부 의존만 mock |
| Property-based | `hypothesis` | Domain Type invariants 검증 (선택) |
| Snapshot | `syrupy` | Adapter 응답 고정 검증 (선택) |
| DB 테스트 | `pytest-postgresql` 또는 `testcontainers` | 통합 테스트용 |
| HTTP Mock | `respx` (httpx 전용) | KIS API 응답 모킹 |
| WebSocket Mock | 자체 Fake class | websockets 라이브러리 mock |
| Lint 의존 검증 | `import-linter` | Hexagonal 경계 위반 감지 |

---

## 3. 단위 테스트 (Unit Tests)

### 3.1 대상 및 원칙

**원칙**:
1. **외부 의존 없음** — 네트워크, DB, 파일시스템 모두 mock
2. **결정적** — 시간 의존은 `HistoricalClock` 주입, 랜덤은 시드 고정
3. **빠름** — 개별 테스트 100ms 이하, 전체 30초 이하
4. **독립적** — 순서 무관, 병렬 실행 가능

### 3.2 필수 단위 테스트 목록

#### core/domain/

| 대상 | 검증 항목 |
|------|----------|
| `Symbol` | 6자리 숫자 검증, 잘못된 입력 시 ValueError |
| `Price` | Decimal 변환, 음수 거부 |
| `Quantity` | int 강제, 음수 거부 |
| `OrderRequest` | 필수 필드, immutable 확인 |
| `FSMState` | Enum 값 6개 확인 |
| `RiskDecision` | 7체크 결과 집계 |
| 모든 pydantic 모델 | `model_dump()` / `model_validate()` 라운드트립 |

#### core/nodes/

| 노드 | 핵심 테스트 |
|------|-----------|
| MarketDataReceiver | WS→POLL fallback, stale 경고 타이밍 |
| IndicatorCalculator | 200봉 입력 → SMA/RSI/MACD 정확도 (수동 계산 대조), buffer 부족 시 null |
| StrategyEngine | ma_crossover golden cross → BUY, dead cross → SELL, cooldown 억제 |
| RiskGuard | 7체크 개별 경계값, 여러 체크 동시 실패 시 첫 번째만 audit |
| OrderExecutor | 멱등성 (동일 UUID 재제출), CB trip/recovery |
| TradingFSM | 12 transition 전부, 불가능 전이 시 warn, persist 타이밍 |

#### core/risk/

| 대상 | 테스트 |
|------|-------|
| `check_insufficient_cash` | 경계값 (95%, 95.01%) |
| `check_concentration_limit` | 동일 종목 기존 포지션 포함 계산 |
| `check_daily_loss_limit` | 진입만 차단, 청산 허용 |
| `check_trade_count` | 경계값 (39, 40, 41) |
| `check_trading_hours` | 장 시작 1분 전/후, 주말, 공휴일 |
| `check_vi_triggered` | VI 상태 감지 |
| `check_circuit_breaker` | CB OPEN 상태에서 차단 |
| `CircuitBreaker` | CLOSED→OPEN (window 내 3회 실패), OPEN→HALF_OPEN (recovery), HALF_OPEN→OPEN (1회 실패), HALF_OPEN→CLOSED (1회 성공) |

#### core/fsm/

| 대상 | 테스트 |
|------|-------|
| `FSMStates` | 12개 전이 존재 확인, 불가능 전이 검증 |
| `FSMManager` | 종목별 인스턴스 생성, 독립성 확인, halt broadcast |

#### adapters/ (Mock 계열)

| Adapter | 테스트 |
|---------|-------|
| `MockBrokerAdapter` | 슬리피지 계산 정확도, 수수료+세금 적용, 잔고 부족 거부, 멱등성 |
| `InMemoryStorageAdapter` | upsert 동작, 트랜잭션 Lock 경합 |
| `HistoricalClockAdapter` | advance_to 이후 now() 반영, sleep 즉시 반환 |
| `CSVReplayAdapter` | CSV 로드, speed_multiplier=0 즉시, 1.0 실시간 |
| `StdoutAuditAdapter` | JSON 라인 출력 형식 |

### 3.3 Mock 전략

**Mock 대상**:
- 네트워크 (httpx, websockets) → `respx`, Fake class
- DB (asyncpg) → `InMemoryStorageAdapter` 또는 `testcontainers`
- 시계 (datetime) → `HistoricalClockAdapter`
- 파일 (CSV) → `tmp_path` fixture + 테스트 데이터

**Mock하지 않는 것**:
- `core/domain/` pydantic 모델 — 그대로 사용
- `core/nodes/` 내 순수 로직 — 그대로 실행
- Port ABC — 테스트에서도 그대로 사용, 구현체만 mock

### 3.4 Fixture 규칙

`tests/conftest.py`에 공통 fixture 정의:

```python
# 예시
@pytest.fixture
def mock_clock():
    return HistoricalClockAdapter(start=datetime(2025, 1, 1, 9, 0))

@pytest.fixture
def in_memory_storage():
    return InMemoryStorageAdapter()

@pytest.fixture
def sample_quote():
    return Quote(
        ts=datetime(2025, 1, 1, 9, 0, 1),
        symbol=Symbol("005930"),
        price=Price(Decimal("72100")),
        volume=Quantity(100),
        source="test",
    )

@pytest.fixture
def stub_strategy_loader():
    """항상 BUY 신호만 내는 stub"""
    ...
```

**원칙**: 한 fixture = 하나의 책임. 복합 fixture는 다른 fixture 조합으로 구성.

---

## 4. 통합 테스트 (Integration Tests)

### 4.1 대상 및 원칙

**목적**: 노드 간 연결, Port-Adapter 계약, DB 영속성을 실제 환경에 가깝게 검증.

**원칙**:
1. 실제 PostgreSQL 사용 (`testcontainers` 또는 docker-compose)
2. Mock KIS API (`respx`로 응답 고정)
3. 각 테스트는 DB 스키마 reset 후 시작
4. 실행 시간 허용: 개별 10초, 전체 3분

### 4.2 필수 통합 테스트

| # | 이름 | 시나리오 |
|---|------|---------|
| 1 | `path1_e2e_backtest` | CSVReplay + MockBroker + InMemory → 200봉 실행 → 체결 발생 → trades/positions/daily_pnl 기록 확인 |
| 2 | `path1_e2e_paper` | Fake KIS (respx) + Postgres → 10틱 처리 → 주문 제출 → 체결 이벤트 → FSM 전이 |
| 3 | `crash_recovery` | 정상 운영 중 kill -9 → 재기동 → positions/order_tracker 복원 확인 |
| 4 | `halt_timing` | 진행 중 주문 상태에서 halt 발송 → 30초 내 신규 주문 차단 확인 |
| 5 | `fsm_transition_persistence` | 각 전이마다 DB UPDATE 확인, audit 기록 동반 |
| 6 | `idempotency_duplicate_order` | 동일 order_uuid 2회 제출 → 한 번만 실제 주문 |
| 7 | `rest_fallback` | WS 강제 실패 → REST 폴링 자동 전환 |
| 8 | `audit_fallback_on_db_fail` | AuditPort DB 실패 → logs/audit_fallback.jsonl 기록 확인 |
| 9 | `risk_reject_chain` | 7체크 중 1개 실패 → approved_signal 미발행, rejection_event만 기록 |
| 10 | `circuit_breaker_integration` | 연속 3회 주문 실패 → CB OPEN → 신규 주문 거부 → recovery 후 half-open |

### 4.3 테스트 데이터 관리

- `tests/fixtures/` 에 고정 데이터 보관
- `ohlcv_samsung_2024.csv` — 삼성전자 2024년 일봉 (백테스트용)
- `fake_kis_responses.json` — KIS API 응답 샘플 (정상/에러 코드별)
- 생성 스크립트: `scripts/generate_test_data.py` (최초 1회 실행 후 git에 포함)

### 4.4 통합 테스트 환경

```yaml
# tests/docker-compose.test.yml
services:
  postgres-test:
    image: timescale/timescaledb:latest-pg16
    environment:
      POSTGRES_DB: atlas_test
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
    ports: ["5433:5432"]    # 개발용과 분리
    tmpfs: /var/lib/postgresql/data   # 메모리 기반, 재시작 시 초기화
```

**CI 환경**: GitHub Actions에서 `services:` 블록으로 PostgreSQL 컨테이너 기동.

---

## 5. 합격 기준 테스트 (Acceptance Tests)

`docs/what/decisions/011-phase1-scope.md`에서 정의된 **5개 합격 기준**을 자동화된 테스트로 검증.

### 5.1 합격 기준 5개

| # | 기준 | 검증 방법 | 테스트 파일 |
|---|------|---------|------------|
| 1 | 백테스트 샤프 > 1.0 | `atlas backtest` 실행 → result.json의 sharpe 필드 파싱 | `criterion_1_sharpe.py` |
| 2 | 모의투자 5거래일 무사고 | audit_events에 severity IN ('error', 'critical') COUNT = 0 | `criterion_2_paper_5days.py` |
| 3 | 일일 손익 자동 기록 | daily_pnl 테이블에 최근 5일 레코드 5개 존재 | `criterion_3_pnl_logging.py` |
| 4 | atlas halt 30초 내 차단 | halt 시각 vs 최종 order_submitted 시각 diff < 30s | `criterion_4_halt_30s.py` |
| 5 | Crash 후 포지션 복원 | kill -9 → restart → positions와 FSM state 일치 | `criterion_5_crash_recovery.py` |

### 5.2 합격 기준 1 — 백테스트 샤프

```python
# tests/acceptance/criterion_1_sharpe.py
import json
import subprocess

def test_sharpe_ratio_above_one():
    """백테스트 결과 샤프 > 1.0 확인."""
    result = subprocess.run([
        "atlas", "backtest",
        "strategies/ma_crossover.py",
        "--period", "2024-01-01:2024-12-31",
        "--json",
    ], capture_output=True, check=True)

    data = json.loads(result.stdout)
    sharpe = data["metrics"]["sharpe_ratio"]

    assert sharpe > 1.0, f"Sharpe {sharpe} below threshold 1.0"
```

**주의**: 이 기준은 **전략 성능**에 의존. 전략 자체가 나쁘면 구현이 정상이어도 fail. Phase 1의 `ma_crossover.py`는 샤프 > 1.0을 달성하는 전략이어야 함 (파라미터 튜닝 포함).

### 5.3 합격 기준 4 — halt 30초

```python
# tests/acceptance/criterion_4_halt_30s.py
import asyncio
from datetime import datetime

async def test_halt_blocks_orders_within_30s(atlas_daemon):
    """atlas halt 발송 후 30초 내 신규 주문 차단 확인."""
    # 1. daemon 기동 + 활발히 주문 중 상태 만들기 (fake signal 주입)
    await atlas_daemon.inject_signals(rate_per_sec=5, duration=10)

    # 2. halt 발송
    halt_sent_at = datetime.now()
    await run_cli("atlas", "halt", "--yes")

    # 3. 30초 대기
    await asyncio.sleep(35)

    # 4. audit_events에서 halt 이후 order_submitted 0건 확인
    last_order_at = await query_last_order_submitted()
    diff = (last_order_at - halt_sent_at).total_seconds()

    assert diff < 30, f"Order submitted {diff}s after halt (limit: 30s)"
```

### 5.4 합격 기준 5 — Crash Recovery

```python
# tests/acceptance/criterion_5_crash_recovery.py
import os
import signal
import subprocess
import time

def test_crash_recovery_preserves_state():
    """kill -9 후 재기동 시 positions와 FSM state 일치."""
    # 1. 데몬 기동 + 활발한 상태 (포지션 2개 보유)
    daemon = subprocess.Popen(["atlas", "start"])
    time.sleep(5)
    seed_positions(symbols=["005930", "000660"])

    # 2. 상태 스냅샷 (crash 전)
    before_positions = db_select("SELECT * FROM positions ORDER BY symbol")
    before_fsm = db_select("SELECT symbol, fsm_state FROM positions")

    # 3. kill -9
    os.kill(daemon.pid, signal.SIGKILL)
    time.sleep(2)

    # 4. 재기동
    daemon2 = subprocess.Popen(["atlas", "start"])
    time.sleep(10)  # crash recovery 완료 대기

    # 5. 상태 비교
    after_positions = db_select("SELECT * FROM positions ORDER BY symbol")
    after_fsm = db_select("SELECT symbol, fsm_state FROM positions")

    assert before_positions == after_positions
    assert before_fsm == after_fsm
```

### 5.5 합격 기준 2·3 — 다일 운영 기준

**#2 (5거래일 무사고)**, **#3 (일일 손익 기록)**은 자동 테스트로 5일을 기다릴 수 없으므로 **가속 모드** 사용:

- `HistoricalClockAdapter.speed_multiplier`를 극한으로 올려서 (예: 100x) 5거래일을 짧은 시간에 시뮬레이션
- 또는 **실제 paper 계좌에서 5일 운영 후 수동 검증** (Phase 1 출시 전 최종 관문)

**자동화 한계**: #2, #3은 부분 자동화 + 수동 확인 조합. Phase 2에서 더 긴 운영 시나리오 자동화 강화.

---

## 6. CI/CD 파이프라인 (Phase 1)

### 6.1 GitHub Actions 워크플로우

```yaml
# .github/workflows/test.yml
name: Test
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: pip install ruff mypy import-linter
      - run: ruff check atlas/
      - run: mypy atlas/
      - run: lint-imports    # Hexagonal 경계 검증

  unit-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: pip install -e ".[dev]"
      - run: pytest tests/unit/ -v --cov=atlas --cov-fail-under=70

  integration-test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: timescale/timescaledb:latest-pg16
        env:
          POSTGRES_PASSWORD: test
        ports: ["5432:5432"]
    steps:
      - uses: actions/checkout@v4
      - run: pip install -e ".[dev]"
      - run: psql -f db/init.sql
      - run: pytest tests/integration/ -v --timeout=60

  acceptance-test:
    # 수동 트리거만 (on: workflow_dispatch)
    # 최종 배포 전 실행
    runs-on: ubuntu-latest
    steps:
      - ...
      - run: pytest tests/acceptance/ -v --timeout=300
```

### 6.2 로컬 개발 스크립트

```makefile
# Makefile
.PHONY: test test-unit test-integration lint

test-unit:
	pytest tests/unit/ -v

test-integration:
	docker compose -f tests/docker-compose.test.yml up -d
	pytest tests/integration/ -v
	docker compose -f tests/docker-compose.test.yml down

test: test-unit test-integration

lint:
	ruff check atlas/
	mypy atlas/
	lint-imports
```

---

## 7. 테스트 작성 시기

구현 단계별 테스트 작성 시점:

| 구현 Step (project-structure §10) | 작성해야 할 테스트 |
|------|----------------|
| Step 1: 저장소 + 인프라 | (테스트 없음, 의존성 설치만) |
| Step 2: Core/Domain | unit/core/domain/* (동시 작성) |
| Step 3: Ports | unit/ports/exceptions 만 |
| Step 4: Mock Adapters | unit/adapters/ (mock 계열) |
| Step 5: Core/Nodes | unit/core/nodes/*, unit/core/risk/*, unit/core/fsm/* **+** integration/path1_e2e_backtest |
| Step 6: Infrastructure + CLI | unit/infrastructure/* |
| Step 7: Real Adapters | unit/adapters/ (real 계열, respx mock), integration/path1_e2e_paper |
| Step 8: 합격 기준 | acceptance/criterion_* 5개 |

**원칙**: TDD는 강제하지 않지만, 구현과 동일한 commit에 관련 테스트 포함.

---

## 8. 테스트 실패 시 대응 흐름

```
테스트 실패 감지
    │
    ▼
실패 유형 분류
    │
    ├─ 단위 테스트 실패  → 해당 모듈 회귀. 즉시 수정 또는 revert.
    │
    ├─ 통합 테스트 실패  → 노드 간 계약 위반. Port signature 또는 Domain Type 재검토.
    │
    └─ 합격 기준 실패    → Phase 1 출시 보류.
        │
        ├─ #1 (샤프) → 전략 파라미터 튜닝
        ├─ #2 (무사고) → audit_events 분석 후 에러 핸들링 보강
        ├─ #3 (PnL) → daily_pnl 기록 로직 재검토
        ├─ #4 (halt) → signal handler / OrderExecutor 게이트 재검토
        └─ #5 (crash) → crash_recovery 로직 재검토
```

**Phase 1 출시 조건**: 합격 기준 5개 **전부 통과** + 단위/통합 테스트 전체 통과.

---

## 9. 테스트 제외 대상 (Phase 1 비범위)

다음 항목은 Phase 1 자동화 테스트 범위 **밖**:

- ❌ KIS Live 계좌 (Phase 2D 이후)
- ❌ 복수 전략 동시 실행
- ❌ Telegram 알림 시나리오
- ❌ Grafana 대시보드
- ❌ Screener / WatchlistManager
- ❌ 성능 벤치마크 (처리량, 지연)
- ❌ 장기 운영 시뮬레이션 (1개월+)
- ❌ 장애 주입 (chaos engineering)

**Phase 2 예정**:
- 성능 테스트 (`pytest-benchmark`)
- 복수 전략 동시 실행 검증
- Chaos testing (네트워크 지연, 부분 실패)

---

## 10. 변경 이력

| 날짜 | 버전 | 변경 |
|------|------|------|
| 2026-04-17 | v1.0 | Phase 1 최초 작성. 피라미드·도구·Unit/Integration/Acceptance 범위·CI 파이프라인·합격 기준 5개 자동화. |

---

*Phase 1 테스트 전략 — 3계층 피라미드 | 10 통합 테스트 | 5 합격 기준 자동화 | 70% 커버리지 목표*
