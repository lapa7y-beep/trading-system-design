# Port Interface Design — Path 3: Strategy Development

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | port_interface_path3_v1.0 |
| Path | Path 3: Strategy Development |
| 선행 문서 | boundary_definition_v1.0, port_interface_path1_v1.0, port_interface_path2_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |

---

## 1. Path 3 개요

### 1.1 책임 범위

Strategy Development Path는 전략의 전체 생명주기를 관리한다: 아이디어 수집 → 전략 코드 생성 → 파라미터 저장 → 버전 관리 → 런타임 로딩 → 백테스트 검증 → 파라미터 최적화.

Path 1이 "손", Path 2가 "장기 기억"이라면, Path 3는 "전략 연구소"다. 검증이 완료된 전략만 Path 1(Realtime Trading)에 배포되며, 미검증 전략은 절대로 실전에 투입되지 않는다.

### 1.2 노드 구성 (7개)

| 노드 ID | 역할 | runMode | LLM Level |
|---------|------|---------|-----------|
| StrategyCollector | 전략 아이디어 수집/등록 | event | L1 (도구) |
| StrategyGenerator | 전략 코드 자동 생성 | batch | L2 (제약 에이전트) |
| StrategyRegistry | 전략 메타데이터/버전 저장 | stateful-service | L0 (없음) |
| StrategyLoader | 런타임 전략 동적 로딩 | poll | L0 (없음) |
| BacktestEngine | 과거 데이터 기반 전략 검증 | batch | L0 (없음) |
| Optimizer | 파라미터 그리드/베이지안 최적화 | batch | L1 (도구) |
| StrategyEvaluator | 백테스트 결과 분석/리포트 | batch | L1 (도구) |

### 1.3 전략 생명주기

```
아이디어 → 코드 생성 → 등록 → 백테스트 → 최적화 → 승인 → 배포(Path 1)
  ↑                                                           │
  └─────────────── 피드백 (실전 성과) ─────────────────────────┘
```

### 1.4 접촉하는 Shared Store (4개)

| Store | 용도 | 접근 방식 |
|-------|------|----------|
| StrategyStore | 전략 코드, 파라미터, 버전 이력 | Read/Write |
| MarketDataStore | 백테스트용 과거 시세 데이터 | Read Only |
| KnowledgeStore | 전략 아이디어 소스 (인과 관계 참조) | Read Only |
| ConfigStore | 백테스트 설정, 최적화 범위 | Read Only |

---

## 2. Port Interface 정의 (5개 Port)

### 2.1 StrategyRepositoryPort — 전략 저장/조회 규격

전략의 코드, 메타데이터, 파라미터, 버전 이력을 관리한다. Git 기반이든, DB 기반이든 이 포트 규격만 맞추면 교체 가능.

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class StrategyStatus(Enum):
    DRAFT = "draft"               # 초안 (미검증)
    BACKTESTED = "backtested"     # 백테스트 완료
    OPTIMIZED = "optimized"       # 최적화 완료
    APPROVED = "approved"         # 배포 승인
    DEPLOYED = "deployed"         # 실전 배포 중
    RETIRED = "retired"           # 은퇴 (비활성)


class StrategyType(Enum):
    MOMENTUM = "momentum"         # 모멘텀/추세
    MEAN_REVERSION = "mean_reversion"  # 평균 회귀
    BREAKOUT = "breakout"         # 돌파
    STATISTICAL_ARB = "statistical_arb"  # 통계적 차익
    EVENT_DRIVEN = "event_driven" # 이벤트 드리븐
    COMPOSITE = "composite"       # 복합 전략


@dataclass(frozen=True)
class StrategyParam:
    """전략 파라미터 정의"""
    name: str                     # "fast_period"
    param_type: str               # "int" | "float" | "str" | "bool"
    default: any                  # 5
    min_value: any | None = None  # 2
    max_value: any | None = None  # 50
    step: any | None = None       # 1 (최적화 스텝)
    description: str = ""


@dataclass(frozen=True)
class StrategyMeta:
    """전략 메타데이터"""
    strategy_id: str              # "ma_crossover_v2"
    name: str                     # "이동평균 교차 전략"
    version: str                  # "2.1.0" (semver)
    strategy_type: StrategyType
    status: StrategyStatus
    author: str                   # "system" | "user"
    description: str
    params: list[StrategyParam]
    target_symbols: list[str] | None = None  # None = 전체 종목
    target_timeframe: str = "1d"  # "1m" | "5m" | "1d"
    created_at: datetime = field(default_factory=datetime.now)
    updated_at: datetime = field(default_factory=datetime.now)
    tags: list[str] = field(default_factory=list)  # ["kospi", "large_cap"]


@dataclass(frozen=True)
class StrategyCode:
    """전략 실행 코드"""
    strategy_id: str
    version: str
    source_code: str              # Python 소스 코드
    entry_class: str              # "MACrossoverStrategy"
    dependencies: list[str] = field(default_factory=list)  # ["pandas-ta", "numpy"]
    checksum: str = ""            # SHA256 of source_code


@dataclass(frozen=True)
class StrategyVersion:
    """전략 버전 이력"""
    strategy_id: str
    version: str
    changelog: str
    params_snapshot: dict         # 해당 버전의 파라미터 값
    backtest_result_id: str | None = None
    created_at: datetime = field(default_factory=datetime.now)


class StrategyRepositoryPort(ABC):
    """
    전략 저장소 인터페이스.
    
    PostgreSQL이든, Git 기반이든, 파일시스템이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def save_strategy(
        self, meta: StrategyMeta, code: StrategyCode
    ) -> str:
        """
        전략 저장 (신규 생성 또는 버전 업데이트).
        기존 strategy_id가 있으면 새 버전으로 저장.
        Returns: strategy_id
        """
        ...

    @abstractmethod
    async def get_strategy(
        self, strategy_id: str, version: str | None = None
    ) -> tuple[StrategyMeta, StrategyCode] | None:
        """
        전략 조회. version=None이면 최신 버전.
        Returns: (meta, code) 또는 None
        """
        ...

    @abstractmethod
    async def list_strategies(
        self,
        status: StrategyStatus | None = None,
        strategy_type: StrategyType | None = None,
        tags: list[str] | None = None
    ) -> list[StrategyMeta]:
        """
        전략 목록 조회. 필터 조합 가능.
        """
        ...

    @abstractmethod
    async def update_status(
        self, strategy_id: str, new_status: StrategyStatus
    ) -> bool:
        """
        전략 상태 변경 (생명주기 전이).
        DRAFT → BACKTESTED → OPTIMIZED → APPROVED → DEPLOYED
        역방향 전이: DEPLOYED → RETIRED
        """
        ...

    @abstractmethod
    async def get_versions(
        self, strategy_id: str
    ) -> list[StrategyVersion]:
        """전략 버전 이력 조회 (최신순)."""
        ...

    @abstractmethod
    async def delete_strategy(
        self, strategy_id: str
    ) -> bool:
        """
        전략 삭제 (DRAFT 상태만 가능).
        DEPLOYED 전략은 RETIRED로 전환 후 삭제.
        """
        ...
```

**Adapters:**
- PostgresStrategyAdapter — PostgreSQL 기반 (운영)
- FileSystemStrategyAdapter — YAML + Python 파일 (개발)
- GitStrategyAdapter — Git 저장소 기반 (버전 관리 강화)
- MockStrategyAdapter — 테스트용

---

### 2.2 BacktestPort — 백테스트 실행 규격

전략 코드를 과거 시세 데이터에 대해 시뮬레이션한다. 내부 엔진이든, QuantConnect Lean이든 이 포트 규격만 맞추면 교체 가능.

```python
@dataclass(frozen=True)
class BacktestConfig:
    """백테스트 설정"""
    strategy_id: str
    version: str
    params: dict                  # 전략 파라미터 오버라이드
    symbols: list[str]            # 대상 종목
    start_date: str               # "2024-01-01"
    end_date: str                 # "2026-03-31"
    initial_capital: int = 100_000_000  # 1억원
    commission_rate: float = 0.00015    # 매매 수수료율
    slippage_bps: float = 5.0          # 슬리피지 (bps)
    benchmark: str = "KOSPI"           # 벤치마크


@dataclass(frozen=True)
class TradeRecord:
    """개별 거래 기록"""
    trade_id: str
    symbol: str
    side: str                     # "buy" | "sell"
    quantity: int
    entry_price: float
    exit_price: float | None = None
    entry_time: str = ""
    exit_time: str = ""
    pnl: float = 0.0
    pnl_pct: float = 0.0
    holding_days: int = 0


@dataclass(frozen=True)
class BacktestResult:
    """백테스트 결과"""
    result_id: str
    strategy_id: str
    version: str
    config: BacktestConfig

    # 수익률 지표
    total_return: float           # 총 수익률 (%)
    cagr: float                   # 연환산 수익률 (%)
    sharpe_ratio: float           # 샤프 비율
    sortino_ratio: float          # 소르티노 비율
    max_drawdown: float           # 최대 낙폭 (%)
    max_drawdown_duration: int    # 최대 낙폭 지속 기간 (일)
    calmar_ratio: float           # 칼마 비율

    # 거래 통계
    total_trades: int
    win_rate: float               # 승률 (%)
    profit_factor: float          # 이익/손실 비율
    avg_win: float                # 평균 이익 (%)
    avg_loss: float               # 평균 손실 (%)
    avg_holding_days: float       # 평균 보유 기간

    # 벤치마크 비교
    benchmark_return: float
    alpha: float                  # 초과 수익률
    beta: float                   # 시장 민감도
    information_ratio: float

    # 상세 데이터
    trades: list[TradeRecord]
    equity_curve: list[dict]      # [{"date": "...", "equity": 105000000}, ...]

    executed_at: datetime = field(default_factory=datetime.now)
    duration_seconds: float = 0.0


class BacktestPort(ABC):
    """
    백테스트 엔진 인터페이스.
    
    자체 구현 엔진이든, QuantConnect Lean이든, Zipline이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def run(self, config: BacktestConfig) -> BacktestResult:
        """
        백테스트 실행.
        config에 지정된 전략을 과거 데이터로 시뮬레이션.
        Returns: 성과 지표 + 거래 목록 + 자산 곡선
        """
        ...

    @abstractmethod
    async def run_batch(
        self,
        configs: list[BacktestConfig],
        concurrency: int = 4
    ) -> list[BacktestResult]:
        """
        배치 백테스트 (최적화용).
        여러 파라미터 조합을 동시 실행.
        """
        ...

    @abstractmethod
    async def get_result(
        self, result_id: str
    ) -> BacktestResult | None:
        """저장된 백테스트 결과 조회."""
        ...

    @abstractmethod
    async def list_results(
        self,
        strategy_id: str,
        limit: int = 20
    ) -> list[BacktestResult]:
        """전략별 백테스트 결과 목록 (최신순)."""
        ...

    @abstractmethod
    async def get_available_data_range(
        self, symbol: str
    ) -> tuple[str, str]:
        """
        종목별 이용 가능한 과거 데이터 범위.
        Returns: (start_date, end_date)
        """
        ...
```

**Adapters:**
- InternalBacktestAdapter — 자체 구현 (pandas + asyncio, 권장 MVP)
- LeanBacktestAdapter — QuantConnect Lean (Docker, 미래)
- VectorbtAdapter — vectorbt (고속 벡터 백테스트)
- MockBacktestAdapter — 테스트용

---

### 2.3 OptimizerPort — 파라미터 최적화 규격

전략 파라미터의 최적 조합을 탐색한다. 그리드 서치든, 베이지안 최적화든 이 포트 규격만 맞추면 교체 가능.

```python
class OptimizationMethod(Enum):
    GRID_SEARCH = "grid_search"         # 전수 탐색
    RANDOM_SEARCH = "random_search"     # 랜덤 탐색
    BAYESIAN = "bayesian"               # 베이지안 최적화 (Optuna)
    WALK_FORWARD = "walk_forward"       # 워크 포워드 분석


@dataclass(frozen=True)
class ParamRange:
    """파라미터 탐색 범위"""
    name: str
    min_value: float
    max_value: float
    step: float | None = None     # Grid에서 사용
    log_scale: bool = False       # 로그 스케일 탐색


@dataclass(frozen=True)
class OptimizationConfig:
    """최적화 설정"""
    strategy_id: str
    version: str
    param_ranges: list[ParamRange]
    method: OptimizationMethod
    objective: str = "sharpe_ratio"     # 최적화 목표
    max_trials: int = 100              # 최대 시행 횟수
    backtest_config: BacktestConfig | None = None  # 백테스트 기본 설정
    # Walk-forward 전용
    train_ratio: float = 0.7           # 학습 기간 비율
    n_splits: int = 5                  # 분할 수


@dataclass(frozen=True)
class OptimizationResult:
    """최적화 결과"""
    optimization_id: str
    strategy_id: str
    config: OptimizationConfig
    best_params: dict             # {"fast_period": 7, "slow_period": 25}
    best_score: float             # 최적화 목표 기준 최고 점수
    all_trials: list[dict]        # [{"params": {...}, "score": 1.85}, ...]
    param_importance: dict        # {"fast_period": 0.65, "slow_period": 0.35}
    overfitting_score: float      # 과적합 위험도 (0=안전, 1=과적합)
    duration_seconds: float
    executed_at: datetime = field(default_factory=datetime.now)


class OptimizerPort(ABC):
    """
    파라미터 최적화 인터페이스.
    
    Optuna든, scipy.optimize든, 자체 구현이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def optimize(
        self, config: OptimizationConfig
    ) -> OptimizationResult:
        """
        파라미터 최적화 실행.
        method에 따라 탐색 방식 결정.
        """
        ...

    @abstractmethod
    async def get_result(
        self, optimization_id: str
    ) -> OptimizationResult | None:
        """최적화 결과 조회."""
        ...

    @abstractmethod
    async def suggest_ranges(
        self, strategy_id: str
    ) -> list[ParamRange]:
        """
        전략 파라미터 기반 탐색 범위 자동 제안.
        StrategyMeta의 param 정의에서 min/max/step 참조.
        """
        ...
```

**Adapters:**
- OptunaAdapter — Optuna 기반 베이지안 최적화 (권장)
- GridSearchAdapter — 단순 그리드 서치 (소규모)
- WalkForwardAdapter — 워크 포워드 분석 (과적합 방지)
- MockOptimizerAdapter — 테스트용

---

### 2.4 StrategyRuntimePort — 전략 동적 로딩/실행 규격

저장된 전략을 런타임에 동적으로 로딩하여 실행 가능한 인스턴스로 만든다. Path 1(Realtime Trading)에서 이 포트를 통해 전략을 받아 사용한다.

```python
@dataclass(frozen=True)
class SignalOutput:
    """전략이 생성하는 매매 신호"""
    symbol: str
    side: str                     # "buy" | "sell" | "hold"
    strength: float               # 0.0 ~ 1.0 (신호 강도)
    reason: str                   # "MA5 crossed above MA20"
    suggested_quantity: int | None = None
    suggested_price: float | None = None
    stop_loss: float | None = None
    take_profit: float | None = None
    metadata: dict = field(default_factory=dict)


class StrategyRuntimePort(ABC):
    """
    전략 동적 로딩 및 실행 인터페이스.
    
    Python importlib든, 프로세스 격리든, WASM이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def load(
        self, strategy_id: str, version: str | None = None,
        params: dict | None = None
    ) -> str:
        """
        전략을 메모리에 로딩.
        params로 파라미터 오버라이드 가능.
        Returns: instance_id (로딩된 인스턴스 식별자)
        """
        ...

    @abstractmethod
    async def execute(
        self, instance_id: str, market_data: dict
    ) -> SignalOutput:
        """
        로딩된 전략에 시장 데이터를 전달하고 신호를 받는다.
        market_data: {"symbol": "005930", "ohlcv": [...], "indicators": {...}}
        Returns: 매매 신호
        """
        ...

    @abstractmethod
    async def unload(self, instance_id: str) -> bool:
        """전략 인스턴스 해제. 메모리 정리."""
        ...

    @abstractmethod
    async def list_loaded(self) -> list[dict]:
        """
        현재 로딩된 전략 목록.
        Returns: [{"instance_id": "...", "strategy_id": "...", "loaded_at": "..."}]
        """
        ...

    @abstractmethod
    async def hot_reload(
        self, instance_id: str, new_params: dict
    ) -> bool:
        """
        실행 중인 전략의 파라미터 핫 리로드.
        전략 언로드 없이 파라미터만 교체.
        """
        ...
```

**Adapters:**
- ImportlibRuntimeAdapter — Python importlib 기반 동적 로딩 (권장)
- SubprocessRuntimeAdapter — 프로세스 격리 (안전)
- MockRuntimeAdapter — 테스트용

---

### 2.5 MarketDataHistoryPort — 과거 시세 데이터 조회 규격

백테스트와 전략 개발에 필요한 과거 시세 데이터를 제공한다. Path 1의 MarketDataPort(실시간)와 구분되는 히스토리 전용 포트.

```python
@dataclass(frozen=True)
class OHLCV:
    """캔들 데이터"""
    date: str                     # "2026-04-15"
    open: float
    high: float
    low: float
    close: float
    volume: int
    amount: int | None = None     # 거래대금


@dataclass(frozen=True)
class HistoryRequest:
    """과거 데이터 요청"""
    symbol: str
    timeframe: str                # "1m" | "5m" | "15m" | "1d" | "1w"
    start_date: str
    end_date: str
    adjust: str = "forward"       # 수정주가: "forward" | "backward" | "none"


class MarketDataHistoryPort(ABC):
    """
    과거 시세 데이터 조회 인터페이스.
    
    로컬 DB든, KIS API 직접 호출이든, 외부 데이터 벤더든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def get_ohlcv(
        self, request: HistoryRequest
    ) -> list[OHLCV]:
        """
        OHLCV 캔들 데이터 조회.
        로컬 캐시 우선, 없으면 외부 소스에서 수집.
        """
        ...

    @abstractmethod
    async def get_multiple(
        self, symbols: list[str], timeframe: str,
        start_date: str, end_date: str
    ) -> dict[str, list[OHLCV]]:
        """
        복수 종목 동시 조회.
        Returns: {"005930": [OHLCV, ...], "000660": [OHLCV, ...]}
        """
        ...

    @abstractmethod
    async def get_available_symbols(self) -> list[dict]:
        """
        이용 가능한 종목 목록.
        Returns: [{"symbol": "005930", "name": "삼성전자", 
                    "market": "KOSPI", "sector": "반도체"}]
        """
        ...

    @abstractmethod
    async def sync_data(
        self, symbols: list[str], since: str
    ) -> dict:
        """
        외부 소스에서 최신 데이터 동기화.
        Returns: {"synced": 150, "symbols": 10, "duration_seconds": 45}
        """
        ...
```

**Adapters:**
- PostgresHistoryAdapter — PostgreSQL (운영, MarketDataStore 직접 참조)
- KISHistoryAdapter — KIS API 직접 호출 (데이터 보충)
- CSVHistoryAdapter — CSV 파일 기반 (개발/테스트)
- MockHistoryAdapter — 테스트용 (랜덤 생성)

---

## 3. Domain Types 정의 (Path 3 전용)

### 3.1 Enum 정의

```python
class StrategyStatus(Enum):
    DRAFT = "draft"
    BACKTESTED = "backtested"
    OPTIMIZED = "optimized"
    APPROVED = "approved"
    DEPLOYED = "deployed"
    RETIRED = "retired"

class StrategyType(Enum):
    MOMENTUM = "momentum"
    MEAN_REVERSION = "mean_reversion"
    BREAKOUT = "breakout"
    STATISTICAL_ARB = "statistical_arb"
    EVENT_DRIVEN = "event_driven"
    COMPOSITE = "composite"

class OptimizationMethod(Enum):
    GRID_SEARCH = "grid_search"
    RANDOM_SEARCH = "random_search"
    BAYESIAN = "bayesian"
    WALK_FORWARD = "walk_forward"
```

### 3.2 Core Data Types (10종)

| Type | 용도 | 주요 필드 |
|------|------|----------|
| StrategyMeta | 전략 메타데이터 | strategy_id, version, status, strategy_type, params |
| StrategyCode | 전략 소스 코드 | source_code, entry_class, checksum |
| StrategyParam | 파라미터 정의 | name, type, default, min, max, step |
| StrategyVersion | 버전 이력 | version, changelog, params_snapshot |
| BacktestConfig | 백테스트 설정 | symbols, date_range, initial_capital, commission |
| BacktestResult | 백테스트 결과 | returns, sharpe, MDD, trades, equity_curve |
| TradeRecord | 개별 거래 | symbol, side, entry/exit price, pnl |
| OptimizationConfig | 최적화 설정 | param_ranges, method, objective, max_trials |
| OptimizationResult | 최적화 결과 | best_params, best_score, overfitting_score |
| SignalOutput | 매매 신호 | symbol, side, strength, reason, stop_loss |

---

## 4. 데이터 흐름 (Edge 정의, 12개)

### 4.1 내부 Edge (Path 3 내부)

| # | Source → Target | Edge Type | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 1 | StrategyCollector → StrategyGenerator | DataFlow | 아이디어 스펙 | 전략 아이디어 전달 |
| 2 | StrategyGenerator → StrategyRegistry | DataFlow | StrategyMeta + Code | 생성된 전략 등록 |
| 3 | StrategyRegistry → BacktestEngine | DataFlow | StrategyCode + Params | 백테스트 대상 전달 |
| 4 | BacktestEngine → StrategyEvaluator | DataFlow | BacktestResult | 결과 분석 요청 |
| 5 | StrategyEvaluator → StrategyRegistry | DataFlow | 상태 업데이트 | BACKTESTED/REJECTED |
| 6 | StrategyRegistry → Optimizer | DataFlow | StrategyMeta | 최적화 대상 전달 |
| 7 | Optimizer → BacktestEngine | DataFlow | BacktestConfig[] | 배치 백테스트 요청 |
| 8 | Optimizer → StrategyRegistry | DataFlow | 최적 파라미터 | 결과 저장 |

### 4.2 Shared Store / Cross-Path Edge

| # | Source → Target | Edge Type | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 9 | StrategyRegistry → StrategyStore | DataPipe | 전략 코드/메타 | 전략 영속화 |
| 10 | BacktestEngine ← MarketDataStore | ConfigRef | 과거 시세 | 백테스트 데이터 |
| 11 | StrategyCollector ← KnowledgeStore | ConfigRef | 인과 관계 | 아이디어 소스 |
| 12 | StrategyLoader → Path 1 (Realtime) | DataPipe | StrategyInstance | 검증된 전략 배포 |

---

## 5. Shared Store 스키마 (Path 3 기여분)

### 5.1 StrategyStore

```sql
-- 전략 메타데이터
CREATE TABLE strategies (
    strategy_id     TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    version         TEXT NOT NULL,
    strategy_type   TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'draft',
    author          TEXT DEFAULT 'system',
    description     TEXT,
    params_def      JSONB NOT NULL,        -- 파라미터 정의 목록
    target_symbols  TEXT[],
    target_timeframe TEXT DEFAULT '1d',
    tags            TEXT[],
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 전략 소스 코드
CREATE TABLE strategy_codes (
    strategy_id     TEXT NOT NULL,
    version         TEXT NOT NULL,
    source_code     TEXT NOT NULL,
    entry_class     TEXT NOT NULL,
    dependencies    TEXT[],
    checksum        TEXT NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (strategy_id, version)
);

-- 백테스트 결과
CREATE TABLE backtest_results (
    result_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_id     TEXT NOT NULL,
    version         TEXT NOT NULL,
    config          JSONB NOT NULL,
    total_return    FLOAT,
    cagr            FLOAT,
    sharpe_ratio    FLOAT,
    sortino_ratio   FLOAT,
    max_drawdown    FLOAT,
    win_rate        FLOAT,
    profit_factor   FLOAT,
    total_trades    INT,
    alpha           FLOAT,
    beta            FLOAT,
    trades          JSONB,
    equity_curve    JSONB,
    executed_at     TIMESTAMPTZ DEFAULT NOW(),
    duration_seconds FLOAT
);

-- 최적화 결과
CREATE TABLE optimization_results (
    optimization_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_id     TEXT NOT NULL,
    config          JSONB NOT NULL,
    best_params     JSONB NOT NULL,
    best_score      FLOAT,
    all_trials      JSONB,
    param_importance JSONB,
    overfitting_score FLOAT,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);

-- 인덱스
CREATE INDEX idx_strategies_status ON strategies(status);
CREATE INDEX idx_strategies_type ON strategies(strategy_type);
CREATE INDEX idx_backtest_strategy ON backtest_results(strategy_id, version);
CREATE INDEX idx_optimization_strategy ON optimization_results(strategy_id);
```

---

## 6. Safeguard 적용

### 6.1 Path 3 Safeguard Chain

```
StrategyGenerator
    → [CodeSandbox]          생성된 코드 격리 실행 (import 제한)
    → [SyntaxValidator]      Python AST 검증, 금지 패턴 차단
    → StrategyRegistry
    → [VersionGuard]         DEPLOYED 전략 덮어쓰기 방지
BacktestEngine
    → [ResourceLimiter]      CPU/메모리/실행시간 상한
    → [DataLeakageGuard]     미래 데이터 참조 방지 (look-ahead bias)
Optimizer
    → [OverfitDetector]      과적합 점수 > threshold 시 경고
    → [ParamBoundGuard]      탐색 범위 이탈 방지
StrategyLoader
    → [DeploymentGate]       status == APPROVED만 배포 허용
```

### 6.2 전략 배포 안전장치

| 제약 | 규칙 |
|------|------|
| 배포 자격 | status == APPROVED 전략만 Path 1에 배포 |
| 코드 무결성 | checksum 검증 실패 시 로딩 거부 |
| 파라미터 범위 | StrategyParam의 min/max 이탈 시 거부 |
| 핫 리로드 | 파라미터만 변경 가능, 코드 변경은 재배포 필요 |
| 동시 전략 수 | ConfigStore에서 max_concurrent_strategies 읽음 |

---

## 7. Adapter Mapping 요약

| Port | 운영 Adapter | 개발 Adapter | 테스트 Adapter |
|------|-------------|-------------|---------------|
| StrategyRepositoryPort | PostgresStrategyAdapter | FileSystemStrategyAdapter | MockStrategyAdapter |
| BacktestPort | InternalBacktestAdapter | InternalBacktestAdapter | MockBacktestAdapter |
| OptimizerPort | OptunaAdapter | GridSearchAdapter | MockOptimizerAdapter |
| StrategyRuntimePort | ImportlibRuntimeAdapter | ImportlibRuntimeAdapter | MockRuntimeAdapter |
| MarketDataHistoryPort | PostgresHistoryAdapter | CSVHistoryAdapter | MockHistoryAdapter |

**YAML 설정 예시:**

```yaml
path3_strategy:
  strategy_repository:
    implementation: PostgresStrategyAdapter
    params:
      dsn: ${POSTGRES_DSN}

  backtest:
    implementation: InternalBacktestAdapter
    params:
      max_concurrent: 4
      timeout_seconds: 300
      data_source: MarketDataStore

  optimizer:
    implementation: OptunaAdapter
    params:
      sampler: "TPESampler"
      pruner: "MedianPruner"
      storage: ${POSTGRES_DSN}

  strategy_runtime:
    implementation: ImportlibRuntimeAdapter
    params:
      sandbox: true
      allowed_imports: ["pandas", "numpy", "pandas_ta", "talib"]
      max_memory_mb: 512

  market_data_history:
    implementation: PostgresHistoryAdapter
    params:
      dsn: ${POSTGRES_DSN}
      cache_days: 365
```

---

## 8. 다음 단계

- Port Interface Path 4 (Portfolio Management) 설계
- Port Interface Path 5 (Watchdog & Operations) 설계
- Edge Contract Definition (전체 Path 간 엣지 스키마)
