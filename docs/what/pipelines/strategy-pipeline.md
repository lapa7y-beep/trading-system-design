# 전략 파이프라인 — Phase 1 현실 + Phase 2+ 확장

> **층**: What
> **상태**: stable (Phase 1) / reserved (Phase 2+)
> **최종 수정**: 2026-04-19
> **SSoT**: `graph_ir_phase1.yaml` `ports.StrategyRuntimePort`, `nodes.StrategyEngine.strategy_load`
> **목적**: Phase 1에서 수동 전략(`strategies/*.py`)이 로딩·실행·백테스트되는 경로를 고정하고, Phase 2+ 자동생성 전략이 동일 인터페이스로 끼워넣어짐을 보증한다.

## 1. Phase 1 전략 수명주기

Phase 1은 **전략 생성은 수동**. strategies/ 디렉토리에 `*.py` 파일을 사람이 작성.

```
사람
 │ 파이썬 파일 작성
 ▼
┌──────────────────────────────┐
│ strategies/ma_crossover.py   │  ← Phase 1 활성 1개
│ strategies/rsi_reversion.py  │  (선택사항, 미활성)
└───────────┬──────────────────┘
            │ FileSystemStrategyLoader
            │ import via StrategyRuntimePort.load()
            ▼
┌──────────────────────────────┐
│     StrategyEngine           │
│   (Path 1 노드 3번)           │
│                              │
│  evaluate(bundle, snapshot)  │
│  → SignalOutput | None       │
└───────────┬──────────────────┘
            │ e05:signal_output
            ▼
        RiskGuard
            │
            ▼
       OrderExecutor
            │
            ▼
   (실전 / 백테스트 분기는 여기서)
            │
     ┌──────┴──────┐
     │             │
   실전 모드     백테스트 모드
     │             │
  KISPaper      MockOrder
  Adapter       Adapter
  (Port 교체)   (Port 교체)
     │             │
     └──────┬──────┘
            │ e10/e11/e15/e16/e17/e18
            ▼
       TradingFSM
            │
            ▼
       PortfolioStore
            │
            ▼
       일일 P&L 집계
            │
            ▼
     Sharpe 계산 (백테스트)
     실거래 성과 (실전)
```

## 2. Phase 1 strategy_load 정의 (graph_ir_phase1.yaml)

```yaml
StrategyEngine:
  strategy_load:
    source: "strategies/*.py"
    active_count: 1             # Phase 1 제약
    hot_reload: false           # 재시작 필요
```

**Phase 1 제약**:
- 동시에 **1개 전략만** 활성 (선정 기준: config로 지정)
- Hot reload 없음 → 전략 변경 시 `atlas stop` → `atlas start`
- 전략 DB 없음 → 파일시스템이 곧 저장소

## 3. StrategyPort 인터페이스 (수동/자동 통일)

```python
# atlas/core/ports/strategy_runtime.py

from abc import ABC, abstractmethod
from atlas.core.domain import (
    IndicatorBundle, PositionSnapshot, SignalOutput
)

class BaseStrategy(ABC):
    """
    수동 작성 전략과 Phase 2+ 자동생성 전략이 공통 구현.
    StrategyEngine은 이 ABC 타입만 안다.
    """
    name: str
    version: str
    symbols: list[str]

    @abstractmethod
    def evaluate(
        self,
        indicators: IndicatorBundle,
        position: PositionSnapshot,
    ) -> SignalOutput | None:
        """결정론. 같은 입력 → 같은 출력."""
        ...

    def metadata(self) -> dict:
        """전략 출처 태깅 (manual / generated_vN)."""
        return {
            "name": self.name,
            "version": self.version,
            "source": "manual",  # Phase 2 generated는 "auto_gen_vN"
        }


class StrategyRuntimePort(ABC):
    """전략 로딩·평가·조회 인터페이스."""

    @abstractmethod
    def load(self, strategy_id: str) -> BaseStrategy: ...

    @abstractmethod
    def evaluate(
        self,
        strategy: BaseStrategy,
        indicators: IndicatorBundle,
        position: PositionSnapshot,
    ) -> SignalOutput | None: ...

    @abstractmethod
    def list(self) -> list[str]:
        """사용 가능한 전략 id 목록."""
        ...
```

## 4. Phase 1 수동 전략 예시

```python
# strategies/ma_crossover.py

from atlas.core.ports import BaseStrategy
from atlas.core.domain import (
    IndicatorBundle, PositionSnapshot, SignalOutput, OrderSide
)

class MACrossoverStrategy(BaseStrategy):
    name = "ma_crossover"
    version = "1.0.0"
    symbols = ["005930"]  # Phase 1: config/watchlist.yaml에서 주입

    def __init__(self, short: int = 5, long: int = 20):
        self.short = short
        self.long = long

    def evaluate(self, indicators, position):
        sma_short = indicators.get(f"sma_{self.short}")
        sma_long = indicators.get(f"sma_{self.long}")
        
        if sma_short is None or sma_long is None:
            return None

        # 골든크로스
        if sma_short > sma_long and position.quantity == 0:
            return SignalOutput(
                symbol=indicators.symbol,
                side=OrderSide.BUY,
                quantity=10,
                is_entry=True,
                reason="golden_cross",
            )
        # 데드크로스
        if sma_short < sma_long and position.quantity > 0:
            return SignalOutput(
                symbol=indicators.symbol,
                side=OrderSide.SELL,
                quantity=position.quantity,
                is_entry=False,
                reason="dead_cross",
            )
        return None
```

## 5. Plug & Play — config.yaml 한 줄 교체

```yaml
# config/phase1.yaml

strategy:
  active: ma_crossover               # 전략 id
  module: strategies.ma_crossover    # import 경로
  class: MACrossoverStrategy         # 클래스명
  params:
    short: 5
    long: 20

# 전략 교체 시 → 이 4줄만 바꾸면 됨
# StrategyEngine 코드 무변경
# 나머지 6개 노드 코드 무변경
```

## 6. 백테스트 ↔ 실전 동일성 보장

```
┌───────────────────────────────────────────────┐
│       동일 StrategyEngine 인스턴스              │
│                                                │
│   MACrossoverStrategy.evaluate()               │
│   → SignalOutput                               │
│                                                │
└────────────────────┬──────────────────────────┘
                     │
            config.yaml의 broker 모드에 따라 분기
                     │
         ┌───────────┴───────────┐
         │                       │
     [백테스트]               [모의투자]
     broker: mock            broker: kis_paper
         │                       │
    ┌────┴────┐              ┌───┴────┐
    │OrderPort│              │OrderPort│
    │=Mock    │              │=KISPaper│
    │Order    │              │Order    │
    │Adapter  │              │Adapter  │
    └─────────┘              └────────┘
    ┌──────────┐             ┌──────────┐
    │Clock     │             │Clock     │
    │=Historical│            │=WallClock│
    └──────────┘             └──────────┘
    ┌──────────┐             ┌──────────┐
    │MarketData│             │MarketData│
    │=CSVReplay│             │=KISWS    │
    └──────────┘             └──────────┘

각 모드에서 StrategyEngine 코드는 동일.
변경되는 것은 Port 어댑터 주입뿐.
```

**핵심**: StrategyEngine의 어떤 코드도 "지금 백테스트인가 실전인가"를 판단하지 않는다. Port만 바라보기 때문에 동일성 자동 보장.

## 7. Phase 1 acceptance criteria 연결

`graph_ir_phase1.yaml.acceptance_criteria`에서 전략 파이프라인 관련 기준:

| id | 기준 | 검증 |
|----|------|------|
| 1 | 백테스트 Sharpe > 1.0 | `atlas backtest` → `result.json` |
| 2 | 모의투자 5거래일 무사고 | `audit_events WHERE severity IN ('error','critical')` → 0건 |
| 3 | 일일 손익 자동 기록 | `daily_pnl` 테이블 5일치 존재 |

위 3개가 전략 파이프라인이 **백테스트 = 실전** 동일성을 실제로 달성했다는 증거.

## 8. Phase 2+ 확장 계획

| 기능 | Phase | 끼워넣기 지점 |
|------|-------|--------------|
| StrategyGenerator (LLM 자동생성) | Phase 3 | `BaseStrategy`를 구현하는 생성기 클래스 추가 |
| 전략 DB 저장소 (StrategyStore) | Phase 2 | 새 Shared Store 추가. FileSystemStrategyLoader → DBStrategyLoader로 Port 교체 |
| Hot reload | Phase 2 | StrategyRuntimePort에 `reload()` 메서드 추가 |
| 동시 다중 전략 | Phase 2 | `active_count: 1` → `active_count: N`, 자본 배분 로직 추가 |
| 전략 최적화 (Grid/Bayesian) | Phase 3 | `atlas optimize` 명령 추가 |
| 시장 레짐 어댑테이션 | Phase 3 | Path 2 KnowledgePort 활용 |

**원칙**: 위 모든 기능 추가 시 `BaseStrategy.evaluate()` 시그니처는 변하지 않는다. 수동 전략 코드도 수정 불필요.

## 9. 끼워넣기 가능성 검증표

| Phase 2+ 추가 항목 | 엣지 계약 변경? | 다른 노드 코드 변경? | 판정 |
|------------------|----------------|-------------------|------|
| StrategyGenerator | ✗ | ✗ | ✅ 가능 |
| StrategyStore (DB) | ✗ | ✗ | ✅ 가능 (Port 어댑터만 교체) |
| Hot reload | ✗ | ✗ | ✅ 가능 (Port 메서드 추가) |
| 다중 전략 | ✗ (signal 합산 로직만 StrategyEngine 내부) | ✗ | ✅ 가능 |
| Screener (Phase 1 제외 노드) | △ (MarketDataReceiver 앞 노드 추가) | StrategyEngine 코드 변경 없음 | ✅ 가능 |
| Watchlist 자동 관리 | △ | StrategyEngine 코드 변경 없음 | ✅ 가능 |

**전원 ✅** = 전략 파이프라인은 Plug & Play 원칙을 만족한다.

## 10. 문서 상호 참조

- Port 시그니처: `docs/what/specs/port-signatures-phase1.md`
- 전략 예시: `strategies/ma_crossover.py` (Phase 1 구현 시)
- 백테스트: `docs/what/pipelines/backtesting.md`
- Quant spec: `docs/what/specs/quant-spec-phase1.md`

---

*End of Document — Strategy Pipeline*
