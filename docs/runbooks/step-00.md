# Step 00 — Walking Skeleton

## 1. 목적

6 Filter(MarketData → Indicator → Strategy → RiskGuard → OrderExecutor → FSM)를 pass-through stub으로 관통하는 80줄짜리 파이프라인 구축. "봉 1개 → BUY 1번 → 로그 1줄 → FSM IDLE 복귀"가 흐른다.

## 2. 합격 기준 매핑

- Phase 1 합격기준: (기반 Step — 직접 기여 없음)
- 기여 방식: 이후 Step 3~11의 출발점. 이 Step이 없으면 어떤 합격기준도 시작 불가.

## 3. 착수 전 체크리스트

- [ ] Python 3.11+ 설치 확인 (`python3 --version`)
- [ ] pytest 설치 확인 (`pip install pytest`)
- [ ] ADR-012 §1~6 독해 완료 (30분)
- [ ] seam-map.md §1 Filter 테이블 확인 — 6 Filter 이름과 입출력 숙지 (5분)
- [ ] 작업 디렉토리 생성: `mkdir -p atlas tests/step_00`

## 4. 참조 문서 (읽을 순서)

1. `docs/decisions/012-implementation-methodology.md` — §4 어휘, §6 Step 0 행 (5분)
2. `docs/architecture/path1-phase1.md` — 6노드 목록과 각 노드의 입출력만 (10분)
   - MarketData: 출력 Bar
   - Indicator: 입력 Bar, 출력 dict
   - Strategy: 입력 Bar + dict, 출력 Signal
   - RiskGuard: 입력 Signal, 출력 bool (통과/거부)
   - OrderExecutor: 입력 Signal, 출력 Order
   - TradingFSM: 입력 이벤트, 내부 상태 전이
3. `docs/specs/domain-types-phase1.md` — Bar, Signal, Order, Fill 4개만 (5분)
   - ※ 나머지 16개 타입은 이 Step에서 읽지 않음

**이 Step에서 읽지 않는 문서**: ports-phase1.md (Step 2), fsm-design.md (Step 8), db-schema (Step 9), cli-design (Step 10), backtesting (Step 11)

## 5. 작업 단계

### 5.1 Domain Types 최소 정의

```python
# atlas/walking_skeleton.py 상단
from dataclasses import dataclass
from datetime import datetime

@dataclass
class Bar:
    ts: datetime
    symbol: str
    open: float
    high: float
    low: float
    close: float
    volume: int

@dataclass
class Signal:
    action: str   # "BUY" | "SELL" | "HOLD"
    symbol: str
    reason: str

@dataclass
class Order:
    symbol: str
    qty: int
    side: str     # "BUY" | "SELL"
    intent_id: str

@dataclass
class Fill:
    order_id: str
    symbol: str
    qty: int
    price: float
```

### 5.2 6 Filter Stub 함수

```python
def market_data() -> Bar:
    return Bar(datetime.now(), "005930", 70000, 70500, 69500, 70200, 100000)

def indicator(bar: Bar) -> dict:
    return {"sma_short": bar.close, "sma_long": bar.close}

def strategy(bar: Bar, ind: dict) -> Signal:
    return Signal("BUY", bar.symbol, "stub: always buy")

def risk_guard(sig: Signal) -> bool:
    return True  # 무조건 통과

def order_executor(sig: Signal) -> Order:
    import uuid
    order = Order(sig.symbol, 10, sig.action, str(uuid.uuid4())[:8])
    print(f"[ORDER] {order.side} {order.qty}x {order.symbol} (id={order.intent_id})")
    return order

class TradingFSM:
    def __init__(self):
        self.state = "IDLE"

    def on_order_sent(self):
        self.state = "IN_POSITION"
        print(f"[FSM] IDLE → IN_POSITION")

    def on_fill_received(self):
        self.state = "IDLE"
        print(f"[FSM] IN_POSITION → IDLE")
```

### 5.3 Orchestrator (run_once)

```python
def run_once():
    bar = market_data()
    ind = indicator(bar)
    sig = strategy(bar, ind)

    if risk_guard(sig):
        order = order_executor(sig)
        fsm = TradingFSM()
        fsm.on_order_sent()
        fsm.on_fill_received()
    else:
        print("[RISK] Signal rejected")

    print(f"[DONE] Final state: {fsm.state if 'fsm' in dir() else 'N/A'}")

if __name__ == "__main__":
    run_once()
```

### 5.4 테스트 작성

```python
# tests/step_00/test_skeleton.py
from atlas.walking_skeleton import run_once

def test_skeleton_produces_order(capsys):
    run_once()
    out = capsys.readouterr().out
    assert "[ORDER]" in out
    assert "BUY" in out

def test_skeleton_fsm_returns_to_idle(capsys):
    run_once()
    out = capsys.readouterr().out
    assert "IDLE → IN_POSITION" in out
    assert "IN_POSITION → IDLE" in out
    assert "Final state: IDLE" in out
```

### 5.5 실행 확인

```bash
# 직접 실행
python -m atlas.walking_skeleton

# 기대 출력:
# [ORDER] BUY 10x 005930 (id=a1b2c3d4)
# [FSM] IDLE → IN_POSITION
# [FSM] IN_POSITION → IDLE
# [DONE] Final state: IDLE

# 테스트 실행
pytest tests/step_00/ -v

# 기대 결과:
# tests/step_00/test_skeleton.py::test_skeleton_produces_order PASSED
# tests/step_00/test_skeleton.py::test_skeleton_fsm_returns_to_idle PASSED
```

### 5.6 __init__.py 생성

```bash
touch atlas/__init__.py
touch tests/__init__.py
touch tests/step_00/__init__.py
```

## 6. 완료 조건 (전부 통과해야 커밋)

- [ ] `python -m atlas.walking_skeleton` 실행 시 `[ORDER] BUY` 출력됨
- [ ] `pytest tests/step_00/ -v` 결과 2 passed
- [ ] `atlas/walking_skeleton.py` 파일 크기 ≤ 80줄 (`wc -l atlas/walking_skeleton.py`)
- [ ] Port 변경: 해당 없음 (Port는 Step 2에 도입)
- [ ] seam-map.md 갱신: 해당 없음 (Seam은 Step 2에 첫 등장)
- [ ] PROGRESS.md: Step 00 체크박스 체크 + Daily Log 한 줄 추가

## 7. 커밋

```bash
git add -A
git commit -m "Step 00: Walking Skeleton — 6-filter pass-through pipeline

Observable change: run_once() produces one BUY order, FSM cycles IDLE→IN_POSITION→IDLE
Fitness criteria:  (foundation — no direct mapping)
Port changes:      none (Ports introduced in Step 02)
Tests added:       tests/step_00/test_skeleton.py (2 tests)"
```
