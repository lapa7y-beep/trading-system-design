# Port Interface Design — Path 4: Portfolio Management

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | port_interface_path4_v1.0 |
| Path | Path 4: Portfolio Management |
| 선행 문서 | boundary_definition_v1.0, port_interface_path1~3_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |

---

## 1. Path 4 개요

### 1.1 책임 범위

Portfolio Management Path는 포트폴리오 수준의 의사결정을 담당한다: 자산 배분, 리스크 예산, 포지션 사이징, 전략 간 충돌 해소, 일일/주간 리밸런싱, 성과 귀인 분석.

Path 1이 "개별 종목의 매매 손", Path 3이 "전략 연구소"라면, Path 4는 "자금 운용 본부"다. 개별 전략이 아무리 좋은 신호를 내더라도 전체 포트폴리오의 리스크 예산을 초과하면 실행을 차단한다.

### 1.2 노드 구성 (6개)

| 노드 ID | 역할 | runMode | LLM Level |
|---------|------|---------|-----------|
| PositionAggregator | 실시간 포지션/손익 통합 집계 | poll | L0 (없음) |
| RiskBudgetManager | 리스크 예산 배분/한도 관리 | stateful-service | L0 (없음) |
| ConflictResolver | 전략 간 매매 충돌 해소 | event | L0 (없음) |
| Rebalancer | 주기적 포트폴리오 리밸런싱 | batch | L1 (도구) |
| PerformanceAnalyzer | 성과 귀인/리포트 생성 | batch | L1 (도구) |
| AllocationEngine | 자산 배분/포지션 사이징 | event | L0 (없음) |

### 1.3 Path 4의 핵심 원칙

```
규칙 1: 개별 전략은 주문을 "제안"만 한다. 실행 권한은 Path 4에 있다.
규칙 2: 전체 포트폴리오 리스크 예산을 초과하는 주문은 축소 또는 거부된다.
규칙 3: 동일 종목에 대한 상충 신호(전략A=매수, 전략B=매도)는 ConflictResolver가 해소한다.
규칙 4: 일일 손실 한도 도달 시 모든 신규 주문 차단 (기존 포지션 보호만).
```

### 1.4 접촉하는 Shared Store (4개)

| Store | 용도 | 접근 방식 |
|-------|------|----------|
| PortfolioStore | 포지션, 손익, 리밸런싱 이력 | Read/Write |
| MarketDataStore | 현재가, 상관관계 데이터 | Read Only |
| StrategyStore | 배포 중인 전략 목록, 배분 비중 | Read Only |
| ConfigStore | 리스크 한도, 리밸런싱 주기 | Read Only |

---

## 2. Port Interface 정의 (5개 Port)

### 2.1 PositionPort — 포지션 관리 규격

전체 포트폴리오의 실시간 포지션과 손익을 통합 관리한다. 개별 전략별 포지션과 합산 포지션을 동시에 추적.

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class PositionSide(Enum):
    LONG = "long"
    SHORT = "short"      # 국내 주식은 제한적이나 선물/공매도 대비
    FLAT = "flat"


@dataclass(frozen=True)
class PositionEntry:
    """개별 포지션"""
    symbol: str
    side: PositionSide
    quantity: int
    avg_price: float              # 평균 단가
    current_price: float
    unrealized_pnl: float         # 미실현 손익 (원)
    unrealized_pnl_pct: float     # 미실현 손익률 (%)
    market_value: float           # 시장가치 (현재가 × 수량)
    weight: float                 # 포트폴리오 내 비중 (%)
    strategy_id: str              # 어떤 전략이 보유 중인지
    entry_date: str
    holding_days: int


@dataclass(frozen=True)
class PortfolioSnapshot:
    """포트폴리오 전체 스냅샷"""
    snapshot_id: str
    timestamp: datetime
    total_equity: float           # 총 자산 (현금 + 평가액)
    cash: float                   # 가용 현금
    invested: float               # 투자 중 금액
    positions: list[PositionEntry]
    daily_pnl: float              # 당일 손익
    daily_pnl_pct: float
    total_pnl: float              # 누적 손익
    total_pnl_pct: float
    position_count: int
    # 리스크 지표
    portfolio_beta: float         # 포트폴리오 베타
    concentration: float          # 집중도 (HHI)
    max_single_weight: float      # 단일 종목 최대 비중


@dataclass(frozen=True)
class PnLRecord:
    """일일 손익 기록"""
    date: str
    total_equity: float
    daily_pnl: float
    daily_return_pct: float
    realized_pnl: float           # 실현 손익 (청산 종목)
    unrealized_pnl: float         # 미실현 손익 (보유 종목)
    by_strategy: dict             # {"ma_cross": 50000, "breakout": -20000}
    by_symbol: dict               # {"005930": 30000, "000660": 0}


class PositionPort(ABC):
    """
    포지션/손익 관리 인터페이스.
    
    로컬 계산이든, 브로커 계좌 동기화든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def get_snapshot(self) -> PortfolioSnapshot:
        """현재 포트폴리오 전체 스냅샷."""
        ...

    @abstractmethod
    async def get_position(
        self, symbol: str, strategy_id: str | None = None
    ) -> PositionEntry | None:
        """
        개별 포지션 조회.
        strategy_id=None이면 전체 합산 포지션.
        """
        ...

    @abstractmethod
    async def get_positions_by_strategy(
        self, strategy_id: str
    ) -> list[PositionEntry]:
        """전략별 포지션 목록."""
        ...

    @abstractmethod
    async def update_position(
        self, symbol: str, strategy_id: str,
        quantity_delta: int, price: float
    ) -> PositionEntry:
        """
        포지션 업데이트 (체결 반영).
        quantity_delta: 양수=매수, 음수=매도
        """
        ...

    @abstractmethod
    async def reconcile(
        self, broker_positions: list[dict]
    ) -> dict:
        """
        브로커 실제 잔고와 내부 포지션 대조.
        Returns: {"matched": 10, "mismatched": 1, "details": [...]}
        """
        ...

    @abstractmethod
    async def get_pnl_history(
        self, start_date: str, end_date: str
    ) -> list[PnLRecord]:
        """기간별 일일 손익 이력."""
        ...
```

**Adapters:**
- PostgresPositionAdapter — PostgreSQL 기반 (운영)
- InMemoryPositionAdapter — 메모리 기반 (백테스트)
- MockPositionAdapter — 테스트용

---

### 2.2 RiskBudgetPort — 리스크 예산 관리 규격

전체 포트폴리오의 리스크 한도를 관리하고, 개별 주문이 한도를 초과하는지 검증한다.

```python
@dataclass(frozen=True)
class RiskLimits:
    """리스크 한도 설정"""
    max_portfolio_loss_pct: float     # 일일 최대 손실률 (e.g., -5.0)
    max_single_position_pct: float    # 단일 종목 최대 비중 (e.g., 20.0)
    max_sector_exposure_pct: float    # 단일 섹터 최대 비중 (e.g., 40.0)
    max_strategy_allocation_pct: float  # 단일 전략 최대 배분 (e.g., 30.0)
    max_total_exposure_pct: float     # 총 투자 비중 상한 (e.g., 95.0)
    max_correlated_positions: int     # 상관계수 > 0.8인 종목 최대 동시 보유 수
    max_daily_trades: int             # 일일 최대 거래 횟수
    max_single_order_amount: int      # 단일 주문 최대 금액 (원)


@dataclass(frozen=True)
class RiskCheckRequest:
    """리스크 검증 요청"""
    symbol: str
    side: str                         # "buy" | "sell"
    quantity: int
    price: float
    strategy_id: str


class RiskVerdict(Enum):
    APPROVED = "approved"             # 승인
    REDUCED = "reduced"               # 수량 축소 후 승인
    REJECTED = "rejected"             # 거부
    HALTED = "halted"                 # 전체 거래 중단 상태


@dataclass(frozen=True)
class RiskCheckResult:
    """리스크 검증 결과"""
    verdict: RiskVerdict
    original_quantity: int
    approved_quantity: int            # REDUCED인 경우 축소된 수량
    reason: str                       # 거부/축소 사유
    violated_limits: list[str]        # ["max_single_position_pct", ...]
    current_exposure: dict            # 현재 리스크 지표
    timestamp: datetime = field(default_factory=datetime.now)


class RiskBudgetPort(ABC):
    """
    리스크 예산 관리 인터페이스.
    
    단순 한도 체크든, VaR 기반이든, 시뮬레이션 기반이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def check_order(
        self, request: RiskCheckRequest
    ) -> RiskCheckResult:
        """
        주문의 리스크 한도 위반 여부 검증.
        Returns: 승인/축소/거부 + 사유
        """
        ...

    @abstractmethod
    async def get_current_limits(self) -> RiskLimits:
        """현재 적용 중인 리스크 한도."""
        ...

    @abstractmethod
    async def get_exposure(self) -> dict:
        """
        현재 리스크 노출도.
        Returns: {"total_exposure_pct": 72.5,
                  "by_sector": {"반도체": 25.0, "자동차": 15.0},
                  "by_strategy": {"ma_cross": 40.0, "breakout": 32.5},
                  "daily_loss_pct": -1.2,
                  "remaining_budget": {"daily_loss": 3.8, "trades": 15}}
        """
        ...

    @abstractmethod
    async def update_limits(
        self, new_limits: RiskLimits
    ) -> bool:
        """
        리스크 한도 업데이트.
        운영 중 동적 변경 가능 (ConfigStore 우선).
        """
        ...

    @abstractmethod
    async def halt_trading(self, reason: str) -> bool:
        """
        전체 거래 중단.
        모든 신규 주문 차단, 기존 포지션 보호만.
        """
        ...

    @abstractmethod
    async def resume_trading(self) -> bool:
        """거래 재개."""
        ...

    @abstractmethod
    async def is_halted(self) -> bool:
        """현재 거래 중단 상태 여부."""
        ...
```

**Adapters:**
- SimpleRiskAdapter — 한도 기반 단순 체크 (MVP)
- VaRRiskAdapter — Value-at-Risk 기반 (운영)
- MockRiskAdapter — 테스트용

---

### 2.3 ConflictResolutionPort — 전략 충돌 해소 규격

동일 종목에 대해 여러 전략이 상충 신호를 낼 때 최종 행동을 결정한다.

```python
@dataclass(frozen=True)
class SignalConflict:
    """전략 간 신호 충돌"""
    symbol: str
    signals: list[dict]
    # signals 예시:
    # [{"strategy_id": "ma_cross", "side": "buy", "strength": 0.8},
    #  {"strategy_id": "mean_rev", "side": "sell", "strength": 0.6}]


class ResolutionMethod(Enum):
    PRIORITY = "priority"             # 전략 우선순위 기반
    STRENGTH = "strength"             # 신호 강도 기반
    CONSENSUS = "consensus"           # 다수결
    CANCEL = "cancel"                 # 상충 시 모두 취소
    WEIGHTED = "weighted"             # 가중 합산


@dataclass(frozen=True)
class ResolvedAction:
    """충돌 해소 결과"""
    symbol: str
    final_side: str               # "buy" | "sell" | "hold"
    final_quantity: int
    contributing_strategies: list[str]
    resolution_method: ResolutionMethod
    reasoning: str                # "ma_cross(buy, 0.8) > mean_rev(sell, 0.6) by priority"


class ConflictResolutionPort(ABC):
    """
    전략 충돌 해소 인터페이스.
    
    우선순위 기반이든, 앙상블이든, ML 기반이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def resolve(
        self, conflict: SignalConflict
    ) -> ResolvedAction:
        """
        충돌 해소.
        동일 종목의 상충 신호를 하나의 행동으로 결정.
        """
        ...

    @abstractmethod
    async def set_priority(
        self, strategy_priorities: dict[str, int]
    ) -> bool:
        """
        전략 우선순위 설정.
        {"ma_cross": 1, "breakout": 2, "mean_rev": 3}
        낮은 숫자 = 높은 우선순위
        """
        ...

    @abstractmethod
    async def get_conflict_history(
        self, symbol: str | None = None, limit: int = 50
    ) -> list[ResolvedAction]:
        """충돌 해소 이력 조회."""
        ...
```

**Adapters:**
- PriorityConflictAdapter — 우선순위 기반 (기본)
- WeightedConflictAdapter — 가중 합산 (운영)
- MockConflictAdapter — 테스트용

---

### 2.4 AllocationPort — 자산 배분/포지션 사이징 규격

전략별 자금 배분과 개별 주문의 포지션 크기를 결정한다.

```python
@dataclass(frozen=True)
class AllocationPlan:
    """자산 배분 계획"""
    total_equity: float
    allocations: list[dict]
    # allocations 예시:
    # [{"strategy_id": "ma_cross", "target_pct": 40.0, "current_pct": 38.5},
    #  {"strategy_id": "breakout", "target_pct": 30.0, "current_pct": 32.0},
    #  {"strategy_id": "cash",     "target_pct": 30.0, "current_pct": 29.5}]
    rebalance_needed: bool
    drift_threshold_pct: float    # 이 비율 이상 이탈 시 리밸런싱


@dataclass(frozen=True)
class SizingRequest:
    """포지션 사이징 요청"""
    symbol: str
    side: str
    strategy_id: str
    signal_strength: float        # 0.0 ~ 1.0
    current_price: float
    volatility: float | None = None  # ATR 또는 일일 변동성


@dataclass(frozen=True)
class SizingResult:
    """포지션 사이징 결과"""
    symbol: str
    quantity: int                 # 최종 수량
    amount: float                 # 투자 금액
    weight_pct: float             # 포트폴리오 내 비중
    sizing_method: str            # "fixed_pct" | "kelly" | "volatility_target"
    reasoning: str


class AllocationPort(ABC):
    """
    자산 배분/포지션 사이징 인터페이스.
    
    고정 비율이든, Kelly criterion이든, Risk parity든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def get_allocation_plan(self) -> AllocationPlan:
        """현재 자산 배분 계획 및 이탈도."""
        ...

    @abstractmethod
    async def calculate_position_size(
        self, request: SizingRequest
    ) -> SizingResult:
        """
        개별 주문의 포지션 크기 결정.
        전략 배분 비중, 리스크 한도, 변동성을 종합 고려.
        """
        ...

    @abstractmethod
    async def set_target_allocation(
        self, allocations: dict[str, float]
    ) -> bool:
        """
        전략별 목표 배분 비율 설정.
        {"ma_cross": 40.0, "breakout": 30.0, "cash": 30.0}
        합계 = 100.0
        """
        ...

    @abstractmethod
    async def get_rebalance_orders(self) -> list[dict]:
        """
        리밸런싱에 필요한 주문 목록 생성.
        Returns: [{"symbol": "005930", "side": "sell", "quantity": 5, "reason": "overweight"}]
        """
        ...
```

**Adapters:**
- FixedPctAllocationAdapter — 고정 비율 배분 (MVP)
- VolatilityTargetAdapter — 변동성 타겟 (운영)
- KellyAdapter — Kelly criterion (공격적)
- MockAllocationAdapter — 테스트용

---

### 2.5 PerformancePort — 성과 분석/리포트 규격

포트폴리오와 개별 전략의 성과를 분석하고 리포트를 생성한다.

```python
@dataclass(frozen=True)
class PerformanceMetrics:
    """성과 지표"""
    period: str                   # "daily" | "weekly" | "monthly" | "ytd" | "all"
    total_return_pct: float
    annualized_return_pct: float
    sharpe_ratio: float
    sortino_ratio: float
    max_drawdown_pct: float
    win_rate_pct: float
    profit_factor: float
    avg_daily_return_pct: float
    daily_volatility_pct: float
    calmar_ratio: float
    information_ratio: float      # vs benchmark
    tracking_error: float


@dataclass(frozen=True)
class AttributionResult:
    """성과 귀인 분석"""
    period: str
    total_return: float
    by_strategy: dict             # {"ma_cross": 3.2, "breakout": -0.5}
    by_sector: dict               # {"반도체": 2.1, "자동차": 0.6}
    by_factor: dict               # {"market": 1.5, "size": 0.3, "value": 0.9}
    selection_effect: float       # 종목 선택 효과
    timing_effect: float          # 타이밍 효과


@dataclass(frozen=True)
class PerformanceReport:
    """성과 리포트"""
    report_id: str
    generated_at: datetime
    metrics: PerformanceMetrics
    attribution: AttributionResult
    top_winners: list[dict]       # [{"symbol": "005930", "pnl": 500000}]
    top_losers: list[dict]
    strategy_comparison: list[dict]  # 전략별 성과 비교
    risk_summary: dict            # 리스크 지표 요약
    recommendations: list[str]    # 개선 제안 (LLM 생성)


class PerformancePort(ABC):
    """
    성과 분석/리포트 인터페이스.
    
    자체 분석이든, 외부 분석 서비스든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def get_metrics(
        self, period: str = "ytd",
        strategy_id: str | None = None
    ) -> PerformanceMetrics:
        """
        성과 지표 조회.
        strategy_id=None이면 전체 포트폴리오.
        """
        ...

    @abstractmethod
    async def get_attribution(
        self, start_date: str, end_date: str
    ) -> AttributionResult:
        """
        성과 귀인 분석.
        전략별, 섹터별, 팩터별 기여도 분해.
        """
        ...

    @abstractmethod
    async def generate_report(
        self, period: str = "monthly"
    ) -> PerformanceReport:
        """
        종합 성과 리포트 생성.
        지표 + 귀인 + 상위/하위 종목 + 전략 비교 + 개선 제안.
        """
        ...

    @abstractmethod
    async def get_equity_curve(
        self, start_date: str | None = None,
        end_date: str | None = None,
        benchmark: str = "KOSPI"
    ) -> list[dict]:
        """
        자산 곡선 데이터.
        Returns: [{"date": "...", "equity": ..., "benchmark": ..., "drawdown": ...}]
        """
        ...
```

**Adapters:**
- InternalPerformanceAdapter — 자체 분석 (pandas + numpy)
- LLMEnhancedPerformanceAdapter — LLM 기반 개선 제안 포함 (L1)
- MockPerformanceAdapter — 테스트용

---

## 3. Domain Types 정의 (Path 4 전용)

### 3.1 Enum 정의

```python
class PositionSide(Enum):
    LONG = "long"
    SHORT = "short"
    FLAT = "flat"

class RiskVerdict(Enum):
    APPROVED = "approved"
    REDUCED = "reduced"
    REJECTED = "rejected"
    HALTED = "halted"

class ResolutionMethod(Enum):
    PRIORITY = "priority"
    STRENGTH = "strength"
    CONSENSUS = "consensus"
    CANCEL = "cancel"
    WEIGHTED = "weighted"
```

### 3.2 Core Data Types (12종)

| Type | 용도 | 주요 필드 |
|------|------|----------|
| PositionEntry | 개별 포지션 | symbol, quantity, avg_price, unrealized_pnl, strategy_id |
| PortfolioSnapshot | 전체 스냅샷 | total_equity, cash, positions, daily_pnl, concentration |
| PnLRecord | 일일 손익 | daily_pnl, by_strategy, by_symbol |
| RiskLimits | 리스크 한도 | max_loss, max_position, max_sector, max_daily_trades |
| RiskCheckRequest | 검증 요청 | symbol, side, quantity, strategy_id |
| RiskCheckResult | 검증 결과 | verdict, approved_quantity, violated_limits |
| SignalConflict | 신호 충돌 | symbol, signals (전략별 상충 신호) |
| ResolvedAction | 해소 결과 | final_side, final_quantity, reasoning |
| AllocationPlan | 배분 계획 | allocations, rebalance_needed |
| SizingResult | 사이징 결과 | quantity, amount, weight_pct, sizing_method |
| PerformanceMetrics | 성과 지표 | return, sharpe, MDD, win_rate, calmar |
| AttributionResult | 귀인 분석 | by_strategy, by_sector, by_factor |

---

## 4. 데이터 흐름 (Edge 정의, 11개)

### 4.1 내부 Edge (Path 4 내부)

| # | Source → Target | Edge Type | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 1 | PositionAggregator → RiskBudgetManager | DataFlow | PortfolioSnapshot | 현재 노출도 전달 |
| 2 | PositionAggregator → AllocationEngine | DataFlow | PortfolioSnapshot | 배분 이탈도 계산용 |
| 3 | ConflictResolver → AllocationEngine | DataFlow | ResolvedAction | 해소된 최종 신호 |
| 4 | AllocationEngine → RiskBudgetManager | DataFlow | SizingRequest | 리스크 검증 요청 |
| 5 | Rebalancer → AllocationEngine | Command | 리밸런싱 트리거 | 주기적 리밸런싱 |
| 6 | PositionAggregator → PerformanceAnalyzer | DataFlow | PnLRecord | 성과 분석용 |

### 4.2 Cross-Path / Shared Store Edge

| # | Source → Target | Edge Type | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 7 | Path 1 → ConflictResolver | Event | SignalOutput[] | 전략별 매매 신호 수신 |
| 8 | RiskBudgetManager → Path 1 | DataPipe | RiskCheckResult | 승인/거부 결과 반환 |
| 9 | PositionAggregator → PortfolioStore | DataPipe | PortfolioSnapshot | 포지션 영속화 |
| 10 | PositionAggregator ← MarketDataStore | ConfigRef | 현재가 | 시가 평가용 |
| 11 | PerformanceAnalyzer → PortfolioStore | DataPipe | PerformanceReport | 리포트 영속화 |

---

## 5. Shared Store 스키마 (Path 4 기여분)

### 5.1 PortfolioStore

```sql
-- 포지션 테이블
CREATE TABLE positions (
    symbol          TEXT NOT NULL,
    strategy_id     TEXT NOT NULL,
    side            TEXT NOT NULL DEFAULT 'long',
    quantity        INT NOT NULL,
    avg_price       FLOAT NOT NULL,
    entry_date      DATE NOT NULL,
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (symbol, strategy_id)
);

-- 일일 손익 이력
CREATE TABLE daily_pnl (
    date            DATE NOT NULL,
    total_equity    FLOAT NOT NULL,
    cash            FLOAT NOT NULL,
    daily_pnl       FLOAT NOT NULL,
    daily_return_pct FLOAT NOT NULL,
    realized_pnl    FLOAT,
    unrealized_pnl  FLOAT,
    by_strategy     JSONB,
    by_symbol       JSONB,
    PRIMARY KEY (date)
);

-- 리밸런싱 이력
CREATE TABLE rebalance_history (
    rebalance_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    executed_at     TIMESTAMPTZ DEFAULT NOW(),
    before_snapshot JSONB,
    after_snapshot  JSONB,
    orders_executed JSONB,
    trigger         TEXT          -- "scheduled" | "drift" | "manual"
);

-- 리스크 이벤트 로그
CREATE TABLE risk_events (
    event_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    timestamp       TIMESTAMPTZ DEFAULT NOW(),
    event_type      TEXT NOT NULL,  -- "order_rejected" | "trading_halted" | "limit_breach"
    details         JSONB NOT NULL,
    resolved        BOOLEAN DEFAULT FALSE
);

-- 전략 충돌 이력
CREATE TABLE conflict_history (
    conflict_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    timestamp       TIMESTAMPTZ DEFAULT NOW(),
    symbol          TEXT NOT NULL,
    signals         JSONB NOT NULL,
    resolution      JSONB NOT NULL,
    method          TEXT NOT NULL
);

-- 인덱스
CREATE INDEX idx_positions_strategy ON positions(strategy_id);
CREATE INDEX idx_daily_pnl_date ON daily_pnl(date);
CREATE INDEX idx_risk_events_type ON risk_events(event_type, timestamp);
```

---

## 6. Safeguard 적용

### 6.1 Path 4 Safeguard Chain (주문 흐름)

```
Path 1에서 SignalOutput 수신
    → [ConflictResolver]    전략 간 충돌 해소
    → [AllocationEngine]    포지션 사이징
    → [RiskBudgetManager]   리스크 한도 검증
        → APPROVED: Path 1에 실행 승인
        → REDUCED:  수량 축소 후 승인
        → REJECTED: 거부 + 사유 로깅
        → HALTED:   전체 거래 중단
```

### 6.2 일일 리스크 자동 방어

| 조건 | 행동 |
|------|------|
| 일일 손실 ≥ max_portfolio_loss_pct | halt_trading() 자동 호출 |
| 단일 종목 비중 ≥ max_single_position_pct | 해당 종목 추가 매수 거부 |
| 일일 거래 횟수 ≥ max_daily_trades | 신규 주문 차단 |
| 포지션-계좌 불일치 감지 | reconcile() + 알림 |

---

## 7. Adapter Mapping 요약

| Port | 운영 Adapter | 개발 Adapter | 테스트 Adapter |
|------|-------------|-------------|---------------|
| PositionPort | PostgresPositionAdapter | InMemoryPositionAdapter | MockPositionAdapter |
| RiskBudgetPort | VaRRiskAdapter | SimpleRiskAdapter | MockRiskAdapter |
| ConflictResolutionPort | WeightedConflictAdapter | PriorityConflictAdapter | MockConflictAdapter |
| AllocationPort | VolatilityTargetAdapter | FixedPctAllocationAdapter | MockAllocationAdapter |
| PerformancePort | LLMEnhancedPerformanceAdapter | InternalPerformanceAdapter | MockPerformanceAdapter |

**YAML 설정 예시:**

```yaml
path4_portfolio:
  position:
    implementation: PostgresPositionAdapter
    params:
      dsn: ${POSTGRES_DSN}
      reconcile_interval_minutes: 5

  risk_budget:
    implementation: VaRRiskAdapter
    params:
      max_portfolio_loss_pct: -5.0
      max_single_position_pct: 20.0
      max_sector_exposure_pct: 40.0
      max_daily_trades: 50
      var_confidence: 0.99
      var_horizon_days: 1

  conflict_resolution:
    implementation: WeightedConflictAdapter
    params:
      default_method: "weighted"
      strategy_priorities:
        ma_cross: 1
        breakout: 2
        mean_rev: 3

  allocation:
    implementation: VolatilityTargetAdapter
    params:
      target_volatility_pct: 15.0
      rebalance_drift_pct: 5.0
      min_cash_pct: 10.0

  performance:
    implementation: LLMEnhancedPerformanceAdapter
    params:
      llm_model: "claude-sonnet-4-20250514"
      report_schedule: "weekly"
```

---

## 8. 다음 단계

- Port Interface Path 5 (Watchdog & Operations) 설계
- Edge Contract Definition (전체 Path 간 엣지 스키마)
