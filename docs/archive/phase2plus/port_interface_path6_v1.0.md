# Port Interface Design — Path 6: Market Intelligence

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | port_interface_path6_v1.0 |
| Path | Path 6: Market Intelligence |
| 선행 문서 | boundary_definition_v1.0, port_interface_path1_v2.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |

---

## 1. Path 6 개요

### 1.1 설계 동기

> **"시세를 보는 것"과 "시장을 읽는 것"은 다르다.**

Path 1은 시세를 받아서 기술지표를 계산하고 조건이 맞으면 주문한다. 하지만 실전에서는 기술지표만으로 진입/청산을 결정하지 않는다. 외국인이 대량 매도 중인데 기술적 매수 신호가 떴다고 매수하면 안 된다. VI가 발동된 종목에 시장가 주문을 넣으면 안 된다. 업종 전체가 급락 중인데 해당 업종 종목에 진입하면 안 된다.

Path 6는 **시장을 읽는 눈** — 수급, 호가, 시장 환경, 종목 상태를 종합 분석하여 다른 Path에 "지금 매수해도 되는 환경인가"를 알려주는 인텔리전스 레이어다.

### 1.2 책임 범위

```
수급 분석     — 외국인/기관/프로그램매매 순매수 추이, 체결강도
호가 분석     — 매수/매도 잔량 비율, 스프레드, 매물대 분포
시장 환경     — 업종 지수, 서킷브레이커, VI, 사이드카 상태
종목 상태     — 거래정지, 투자경고/위험, 배당락, 상하한가 도달
조건검색 연동 — KIS HTS 조건검색, 순위 API 기반 스크리닝 보조
```

### 1.3 노드 구성 (5개)

| 노드 ID | 역할 | runMode | LLM Level |
|---------|------|---------|-----------|
| SupplyDemandAnalyzer | 수급 분석 (투자자별, 프로그램매매, 공매도, 신용) | poll | L0 |
| OrderBookAnalyzer | 호가 구조 분석 (잔량비율, 스프레드, 매물대) | stream | L0 |
| MarketRegimeDetector | 시장 환경 판단 (업종, 서킷브레이커, VI, 사이드카) | event | L0 |
| StockStateMonitor | 종목 상태 감시 (거래정지, 투자경고, 배당락, 상하한가) | poll | L0 |
| ConditionSearchBridge | KIS 조건검색/순위 API 연동 브릿지 | batch | L0 |

### 1.4 핵심 원칙

```
규칙 1: Path 6 전체 L0 — 수치 기반 분석만. LLM 호출 없음.
규칙 2: Path 6은 "판단"하지 않는다. "정보를 제공"할 뿐이다.
         매수/매도 결정은 Path 1의 StrategyEngine이 한다.
규칙 3: 출력물은 Shared Store(MarketIntelStore)에 저장.
         Path 1, 3, 4가 ConfigRef로 읽어간다.
규칙 4: 긴급 상태(VI 발동, 서킷브레이커, 거래정지)는
         Shared Store 외에 Event Edge로 Path 1에 즉시 통보.
```

### 1.5 출력 형태 — Market Context

Path 6의 핵심 출력물은 종목별/시장별 **MarketContext** 객체. Path 1의 StrategyEngine과 ExitConditionGuard가 이 컨텍스트를 참조하여 판단에 반영한다.

```python
@dataclass(frozen=True)
class MarketContext:
    """시장 인텔리전스 종합 — 종목별"""
    symbol: str
    timestamp: datetime

    # 수급
    foreign_net_buy: int          # 외국인 순매수 (주)
    institution_net_buy: int      # 기관 순매수 (주)
    program_net_buy: int          # 프로그램 순매수 (주)
    volume_power: float           # 체결강도 (매수체결/매도체결 %)
    short_sale_ratio: float       # 공매도 비율 (%)
    credit_balance_ratio: float   # 신용잔고율 (%)

    # 호가
    bid_ask_ratio: float          # 매수잔량/매도잔량 비율
    spread_bps: float             # 호가 스프레드 (bps)
    spread_normal: bool           # 스프레드 정상 범위 여부
    large_sell_wall: bool         # 대형 매도벽 존재 여부

    # 종목 상태
    is_tradable: bool             # 매매 가능 여부 (거래정지 아님)
    vi_active: bool               # VI 발동 중
    warning_level: str            # "none" | "caution" | "warning" | "danger"
    is_ex_dividend: bool          # 배당락일 여부
    at_upper_limit: bool          # 상한가 도달
    at_lower_limit: bool          # 하한가 도달

    # 시장 환경
    sector_trend: str             # "up" | "flat" | "down"
    sector_change_pct: float      # 업종 등락률
    market_regime: str            # "normal" | "volatile" | "circuit_breaker" | "sidecar"
    kospi_change_pct: float       # KOSPI 등락률

    # 종합 판단 보조
    entry_safe: bool              # 진입 안전 여부 (모든 조건 종합)
    exit_urgent: bool             # 긴급 청산 필요 여부
    caution_reasons: list[str]    # 주의 사유 목록
```

### 1.6 접촉하는 Shared Store (3개)

| Store | 용도 | 접근 방식 |
|-------|------|----------|
| **MarketIntelStore** (신규) | MarketContext, 수급 이력, 호가 이력 | Write |
| MarketDataStore | 시세/호가 원시 데이터 | Read Only |
| ConfigStore | 임계값 설정 (스프레드 상한, 수급 반전 기준 등) | Read Only |

---

## 2. Port Interface 정의 (5개 Port)

### 2.1 SupplyDemandPort — 수급 분석 규격

투자자별 매매 동향, 프로그램매매, 공매도, 신용잔고를 분석한다.

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class InvestorType(Enum):
    FOREIGN = "foreign"           # 외국인
    INSTITUTION = "institution"   # 기관
    INDIVIDUAL = "individual"     # 개인
    PROGRAM = "program"           # 프로그램매매
    FOREIGN_MEMBER = "foreign_member"  # 외국계 회원사


@dataclass(frozen=True)
class InvestorFlow:
    """투자자별 매매 동향"""
    symbol: str
    investor_type: InvestorType
    buy_volume: int
    sell_volume: int
    net_volume: int               # 순매수 (양수=순매수, 음수=순매도)
    buy_amount: int               # 매수 금액
    sell_amount: int              # 매도 금액
    net_amount: int               # 순매수 금액
    timestamp: datetime


@dataclass(frozen=True)
class SupplyDemandSnapshot:
    """수급 스냅샷 — 종목별 종합"""
    symbol: str
    flows: list[InvestorFlow]     # 투자자별 동향
    volume_power: float           # 체결강도 (%)
    short_sale_volume: int        # 공매도 거래량
    short_sale_ratio: float       # 공매도 비율 (%)
    credit_balance: int           # 신용잔고 (주)
    credit_balance_ratio: float   # 신용잔고율 (%)
    program_net_buy: int          # 프로그램 순매수
    timestamp: datetime


@dataclass(frozen=True)
class SupplyDemandSignal:
    """수급 신호"""
    symbol: str
    signal_type: str
    # "foreign_reversal"     — 외국인 매매 방향 전환
    # "institution_entry"    — 기관 대량 순매수 시작
    # "program_surge"        — 프로그램매매 급증
    # "short_squeeze_risk"   — 공매도 잔고 급증 + 가격 상승
    # "credit_unwinding"     — 신용잔고 급감 (반대매매 위험)
    direction: str                # "bullish" | "bearish"
    strength: float               # 0.0 ~ 1.0
    evidence: dict                # 근거 데이터
    timestamp: datetime


class SupplyDemandPort(ABC):
    """
    수급 분석 인터페이스.

    KIS REST API든, 자체 DB 집계든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def get_snapshot(self, symbol: str) -> SupplyDemandSnapshot:
        """종목별 수급 스냅샷 조회."""
        ...

    @abstractmethod
    async def get_investor_flow(
        self, symbol: str, investor_type: InvestorType,
        days: int = 5
    ) -> list[InvestorFlow]:
        """투자자별 매매 추이 (일별)."""
        ...

    @abstractmethod
    async def detect_signals(
        self, symbol: str, snapshot: SupplyDemandSnapshot
    ) -> list[SupplyDemandSignal]:
        """수급 신호 감지. 방향 전환, 대량 매매 등."""
        ...

    @abstractmethod
    async def get_market_flow(self) -> dict:
        """
        시장 전체 수급 요약.
        Returns: {"foreign_net": -500억, "institution_net": 300억,
                  "program_net": -200억, "individual_net": 400억}
        """
        ...

    @abstractmethod
    async def get_bulk_transactions(
        self, symbol: str, min_volume: int = 10000
    ) -> list[dict]:
        """대량 체결 내역. 기관/외국인 대량 매매 감지."""
        ...
```

**Adapters:**
- KISSupplyDemandAdapter — KIS 투자자매매동향 + 프로그램매매 + 공매도 API (운영)
- DBSupplyDemandAdapter — PostgreSQL 집계 (보조)
- MockSupplyDemandAdapter — 테스트용

**KIS API 매핑:**

| 메서드 | KIS API |
|--------|---------|
| get_investor_flow | investor-trade-by-stock-daily (FHPTJ04160001) |
| get_market_flow | inquire-investor-daily-by-market (FHPTJ04040000) |
| detect_signals (프로그램) | program-trade-by-stock (FHPPG04650101) |
| detect_signals (공매도) | daily-short-sale (FHPST04830000) |
| detect_signals (신용) | daily-credit-balance (FHPST04760000) |
| get_bulk_transactions | bulk-trans-num (FHKST190900C0) |

---

### 2.2 OrderBookPort — 호가 분석 규격

실시간 호가 데이터를 분석하여 유동성, 매매 압력, 매물대를 판단한다.

```python
@dataclass(frozen=True)
class OrderBookLevel:
    """호가 단계"""
    price: int
    volume: int
    count: int                    # 주문 건수


@dataclass(frozen=True)
class OrderBookSnapshot:
    """호가 스냅샷 (10단계)"""
    symbol: str
    asks: list[OrderBookLevel]    # 매도호가 (최우선~10차)
    bids: list[OrderBookLevel]    # 매수호가 (최우선~10차)
    total_ask_volume: int
    total_bid_volume: int
    bid_ask_ratio: float          # 매수잔량/매도잔량
    spread: int                   # 최우선 매도-매수 가격 차이
    spread_bps: float             # 스프레드 (bps)
    timestamp: datetime


@dataclass(frozen=True)
class OrderBookAnalysis:
    """호가 분석 결과"""
    symbol: str
    bid_ask_ratio: float
    spread_bps: float
    spread_normal: bool           # 평균 대비 정상 범위
    large_sell_wall: bool         # 특정 가격대에 대형 매도벽
    large_buy_wall: bool          # 특정 가격대에 대형 매수벽
    sell_wall_price: int | None   # 매도벽 가격 (있으면)
    buy_wall_price: int | None    # 매수벽 가격 (있으면)
    liquidity_score: float        # 유동성 점수 (0=매우 낮음, 1=매우 높음)
    imbalance_direction: str      # "buy_pressure" | "sell_pressure" | "balanced"
    timestamp: datetime


@dataclass(frozen=True)
class PriceDistribution:
    """매물대 분포"""
    symbol: str
    levels: list[dict]
    # [{"price_range": [70000, 71000], "volume_pct": 15.3, "type": "resistance"},
    #  {"price_range": [68000, 69000], "volume_pct": 12.1, "type": "support"}]
    strongest_resistance: int     # 가장 강한 저항선
    strongest_support: int        # 가장 강한 지지선


class OrderBookPort(ABC):
    """
    호가 분석 인터페이스.

    실시간 WebSocket이든, REST 폴링이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def get_snapshot(self, symbol: str) -> OrderBookSnapshot:
        """현재 호가 스냅샷."""
        ...

    @abstractmethod
    async def analyze(self, symbol: str) -> OrderBookAnalysis:
        """호가 분석 (잔량비율, 스프레드, 매도벽/매수벽 감지)."""
        ...

    @abstractmethod
    async def get_distribution(self, symbol: str) -> PriceDistribution:
        """매물대 분포 조회."""
        ...

    @abstractmethod
    async def on_orderbook_update(
        self, callback: callable
    ) -> None:
        """호가 변경 콜백 등록 (실시간)."""
        ...

    @abstractmethod
    async def detect_spread_anomaly(
        self, symbol: str, threshold_bps: float = 50.0
    ) -> bool:
        """스프레드 이상 감지. 급확대 시 True."""
        ...
```

**Adapters:**
- KISOrderBookAdapter — KIS WebSocket H0STASP0 + REST inquire-asking-price (운영)
- MockOrderBookAdapter — 테스트용

**KIS API 매핑:**

| 메서드 | KIS API |
|--------|---------|
| get_snapshot | inquire-asking-price-exp-ccn (FHKST01010200) |
| get_distribution | pbar-tratio (FHPST01130000) |
| on_orderbook_update | WebSocket H0STASP0 (실시간 호가) |

---

### 2.3 MarketRegimePort — 시장 환경 판단 규격

시장 전체의 상태를 판단한다. 정상/변동성 확대/위기 등.

```python
class MarketRegime(Enum):
    NORMAL = "normal"
    VOLATILE = "volatile"           # 변동성 확대 (VIX 상승 등)
    CIRCUIT_BREAKER_1 = "cb_1"      # 서킷브레이커 1단계 (8% 하락)
    CIRCUIT_BREAKER_2 = "cb_2"      # 서킷브레이커 2단계 (15% 하락)
    CIRCUIT_BREAKER_3 = "cb_3"      # 서킷브레이커 3단계 (20% 하락)
    SIDECAR = "sidecar"             # 사이드카 발동
    PRE_MARKET = "pre_market"
    POST_MARKET = "post_market"
    CLOSED = "closed"


@dataclass(frozen=True)
class VIStatus:
    """종목별 VI (변동성완화장치) 상태"""
    symbol: str
    vi_active: bool
    vi_type: str                    # "static" | "dynamic"
    trigger_price: int              # VI 발동 가격
    reference_price: int            # 기준가
    deviation_pct: float            # 괴리율
    start_time: datetime | None
    expected_end_time: datetime | None  # VI 해제 예상 시각 (발동 후 2분)


@dataclass(frozen=True)
class SectorIndex:
    """업종 지수"""
    sector_code: str              # "0001"=KOSPI, "1001"=KOSDAQ, "0028"=반도체 등
    sector_name: str
    index_value: float
    change_pct: float
    volume: int
    timestamp: datetime


@dataclass(frozen=True)
class MarketEnvironment:
    """시장 환경 종합"""
    regime: MarketRegime
    kospi_change_pct: float
    kosdaq_change_pct: float
    sectors: list[SectorIndex]    # 주요 업종 동향
    vi_stocks: list[VIStatus]     # 현재 VI 발동 종목
    circuit_breaker_active: bool
    sidecar_active: bool
    market_volatility: float      # 시장 변동성 지표
    foreign_net_total: int        # 외국인 순매수 총액
    program_net_total: int        # 프로그램 순매수 총액
    timestamp: datetime


class MarketRegimePort(ABC):
    """
    시장 환경 판단 인터페이스.
    """

    @abstractmethod
    async def get_regime(self) -> MarketRegime:
        """현재 시장 상태."""
        ...

    @abstractmethod
    async def get_environment(self) -> MarketEnvironment:
        """시장 환경 종합 스냅샷."""
        ...

    @abstractmethod
    async def get_sector_trend(self, sector_code: str) -> SectorIndex:
        """개별 업종 동향."""
        ...

    @abstractmethod
    async def get_vi_status(self, symbol: str | None = None) -> list[VIStatus]:
        """VI 상태 조회. symbol=None이면 전체 VI 발동 종목."""
        ...

    @abstractmethod
    async def on_regime_change(self, callback: callable) -> None:
        """시장 상태 변경 콜백 (서킷브레이커, VI 등)."""
        ...

    @abstractmethod
    async def is_safe_to_trade(self) -> tuple[bool, list[str]]:
        """
        지금 매매해도 안전한 환경인지.
        Returns: (safe, reasons)
        예: (False, ["circuit_breaker_1_active", "kospi_down_5pct"])
        """
        ...
```

**Adapters:**
- KISMarketRegimeAdapter — KIS 업종지수 + VI현황 + 장운영정보 API (운영)
- MockMarketRegimeAdapter — 테스트용

**KIS API 매핑:**

| 메서드 | KIS API |
|--------|---------|
| get_sector_trend | inquire-index-price (FHPUP02100000) |
| get_vi_status | inquire-vi-status (FHPST01390000) |
| on_regime_change | WebSocket H0STMKO0 (장운영정보) |
| get_environment (업종 전체) | inquire-index-category-price (FHPUP02140000) |

---

### 2.4 StockStatePort — 종목 상태 감시 규격

개별 종목의 거래 가능 여부, 투자 경고 등급, 권리락 일정 등을 추적한다.

```python
class StockWarningLevel(Enum):
    NONE = "none"
    CAUTION = "caution"             # 투자주의
    WARNING = "warning"             # 투자경고
    DANGER = "danger"               # 투자위험


class StockTradingStatus(Enum):
    TRADABLE = "tradable"
    HALTED = "halted"               # 거래정지
    SUSPENDED = "suspended"         # 매매거래 중지 (단기)
    ADMIN_ISSUE = "admin_issue"     # 관리종목 지정
    DELISTING = "delisting"         # 상장폐지 사유 발생


@dataclass(frozen=True)
class StockState:
    """종목 상태 종합"""
    symbol: str
    name: str
    trading_status: StockTradingStatus
    warning_level: StockWarningLevel
    is_credit_available: bool       # 신용거래 가능 여부
    margin_rate: float              # 증거금률 (0.2 = 20%, 1.0 = 100%)
    at_upper_limit: bool
    at_lower_limit: bool
    is_ex_dividend: bool            # 배당락일
    is_ex_rights: bool              # 권리락일
    vi_active: bool
    tick_size: int                  # 호가단위 (현재가 기준)
    price_limit_upper: int          # 상한가
    price_limit_lower: int          # 하한가
    updated_at: datetime


@dataclass(frozen=True)
class CorporateEvent:
    """기업 이벤트"""
    symbol: str
    event_type: str
    # "dividend"          — 배당
    # "bonus_issue"       — 무상증자
    # "rights_offering"   — 유상증자
    # "stock_split"       — 액면분할
    # "stock_merge"       — 액면병합
    # "merger"            — 합병
    # "delisting_notice"  — 상장폐지 사유 발생
    record_date: str              # 기준일
    ex_date: str                  # 권리/배당락일
    details: dict
    # dividend: {"per_share": 1000, "yield_pct": 2.5}
    # stock_split: {"ratio": "1:5", "new_par": 200}


@dataclass(frozen=True)
class TickSizeTable:
    """KRX 호가단위 테이블"""
    ranges: list[dict]
    # [{"min_price": 0, "max_price": 2000, "tick_size": 1},
    #  {"min_price": 2000, "max_price": 5000, "tick_size": 5},
    #  {"min_price": 5000, "max_price": 20000, "tick_size": 10},
    #  {"min_price": 20000, "max_price": 50000, "tick_size": 50},
    #  {"min_price": 50000, "max_price": 200000, "tick_size": 100},
    #  {"min_price": 200000, "max_price": 500000, "tick_size": 500},
    #  {"min_price": 500000, "max_price": None, "tick_size": 1000}]


class StockStatePort(ABC):
    """
    종목 상태 감시 인터페이스.
    """

    @abstractmethod
    async def get_state(self, symbol: str) -> StockState:
        """종목 상태 종합 조회."""
        ...

    @abstractmethod
    async def get_states_batch(
        self, symbols: list[str]
    ) -> dict[str, StockState]:
        """복수 종목 상태 일괄 조회."""
        ...

    @abstractmethod
    async def is_tradable(self, symbol: str) -> tuple[bool, str]:
        """
        매매 가능 여부.
        Returns: (tradable, reason)
        예: (False, "거래정지 종목"), (False, "VI 발동 중")
        """
        ...

    @abstractmethod
    async def get_tick_size(self, price: int) -> int:
        """가격에 해당하는 호가단위."""
        ...

    @abstractmethod
    async def validate_order_price(
        self, symbol: str, price: int
    ) -> tuple[bool, int]:
        """
        주문 가격 호가단위 검증.
        Returns: (valid, corrected_price)
        price가 호가단위에 안 맞으면 corrected_price로 보정.
        """
        ...

    @abstractmethod
    async def get_price_limits(
        self, symbol: str
    ) -> tuple[int, int]:
        """상한가, 하한가 조회. Returns: (upper, lower)."""
        ...

    @abstractmethod
    async def get_corporate_events(
        self, symbol: str | None = None,
        days_ahead: int = 5
    ) -> list[CorporateEvent]:
        """
        기업 이벤트 일정 조회.
        symbol=None이면 전체 보유종목 대상.
        days_ahead: 향후 n일 이내 이벤트.
        """
        ...

    @abstractmethod
    async def get_margin_rate(self, symbol: str) -> float:
        """증거금률 조회. Returns: 0.2~1.0"""
        ...

    @abstractmethod
    async def on_state_change(self, callback: callable) -> None:
        """종목 상태 변경 콜백 (거래정지, VI 등)."""
        ...
```

**Adapters:**
- KISStockStateAdapter — KIS 상품기본조회 + 신용가능종목 + 예탁원정보 API (운영)
- MockStockStateAdapter — 테스트용

**KIS API 매핑:**

| 메서드 | KIS API |
|--------|---------|
| get_state | search-stock-info (CTPF1002R), inquire-price (시세 내 상태 필드) |
| is_tradable | search-stock-info의 temp_stop_yn, iscd_stat_cls_code |
| get_margin_rate | search-stock-info의 marg_rate, grmn_rate_cls_code |
| get_corporate_events | 예탁원 API: dividend, bonus-issue, paidin-capin, merger-split 등 |
| get_tick_size | KRX 호가단위 규칙 (로컬 테이블) |
| validate_order_price | 로컬 계산 (호가단위 테이블 기반) |

---

### 2.5 ConditionSearchPort — KIS 조건검색/순위 연동 규격

KIS HTS에서 만든 조건검색과 순위 API를 Path 1의 Screener에 보조 데이터로 제공한다.

```python
@dataclass(frozen=True)
class ConditionProfile:
    """KIS HTS 조건검색 프로파일"""
    seq: str                      # 조건 일련번호
    name: str                     # 조건명
    user_id: str                  # HTS 사용자 ID


@dataclass(frozen=True)
class ConditionResult:
    """조건검색 결과"""
    profile: ConditionProfile
    matches: list[dict]           # 종목 목록
    # [{"symbol": "005930", "name": "삼성전자", "price": 72000, ...}]
    total_count: int
    searched_at: datetime


@dataclass(frozen=True)
class RankingResult:
    """순위 조회 결과"""
    ranking_type: str             # "volume", "fluctuation", "volume_power", "market_cap", ...
    items: list[dict]
    # [{"rank": 1, "symbol": "005930", "name": "삼성전자", "value": 15000000}]
    searched_at: datetime


class ConditionSearchPort(ABC):
    """
    KIS 조건검색/순위 연동 인터페이스.
    """

    @abstractmethod
    async def list_conditions(self, user_id: str) -> list[ConditionProfile]:
        """HTS에 등록된 조건검색 목록."""
        ...

    @abstractmethod
    async def search(self, seq: str, user_id: str) -> ConditionResult:
        """조건검색 실행. 최대 100건."""
        ...

    @abstractmethod
    async def get_ranking(
        self, ranking_type: str, market: str = "all",
        top_n: int = 30
    ) -> RankingResult:
        """
        순위 조회.
        ranking_type: "volume" | "fluctuation" | "volume_power" |
                      "market_cap" | "near_new_high" | "short_sale" |
                      "credit_balance" | "dividend_rate" | "disparity" | ...
        """
        ...

    @abstractmethod
    async def get_watchlist_groups(self) -> list[dict]:
        """KIS 서버 관심종목 그룹 목록."""
        ...

    @abstractmethod
    async def get_watchlist_stocks(self, group_id: str) -> list[dict]:
        """관심종목 그룹 내 종목 목록."""
        ...

    @abstractmethod
    async def get_multi_price(self, symbols: list[str]) -> list[dict]:
        """멀티종목 시세 일괄 조회."""
        ...
```

**Adapters:**
- KISConditionSearchAdapter — KIS psearch + ranking + intstock API (운영)
- MockConditionSearchAdapter — 테스트용

**KIS API 매핑:**

| 메서드 | KIS API |
|--------|---------|
| list_conditions | psearch-title (HHKST03900300) |
| search | psearch-result (HHKST03900400) |
| get_ranking (거래량) | volume-rank (FHPST01710000) |
| get_ranking (등락률) | fluctuation (FHPST01700000) |
| get_ranking (체결강도) | volume-power (FHPST01680000) |
| get_ranking (시가총액) | market-cap (FHPST01740000) |
| get_ranking (신고가) | near-new-highlow (FHPST01870000) |
| get_watchlist_groups | intstock-grouplist (HHKCM113004C7) |
| get_watchlist_stocks | intstock-stocklist-by-group (HHKCM113004C6) |
| get_multi_price | intstock-multprice (FHKST11300006) |

---

## 3. Domain Types 정의 (14종)

### 3.1 Enum (4종)

```python
class InvestorType(Enum):       # FOREIGN, INSTITUTION, INDIVIDUAL, PROGRAM, FOREIGN_MEMBER
class MarketRegime(Enum):       # NORMAL, VOLATILE, CB_1/2/3, SIDECAR, PRE/POST_MARKET, CLOSED
class StockWarningLevel(Enum):  # NONE, CAUTION, WARNING, DANGER
class StockTradingStatus(Enum): # TRADABLE, HALTED, SUSPENDED, ADMIN_ISSUE, DELISTING
```

### 3.2 Core Data Types (10종)

| Type | 용도 | 주요 필드 |
|------|------|----------|
| MarketContext | 종합 인텔리전스 (핵심 출력) | 수급+호가+상태+시장 종합, entry_safe, exit_urgent |
| InvestorFlow | 투자자별 매매 | investor_type, net_volume, net_amount |
| SupplyDemandSnapshot | 수급 종합 | flows, volume_power, short_sale_ratio, credit_balance |
| SupplyDemandSignal | 수급 신호 | signal_type, direction, strength |
| OrderBookSnapshot | 호가 스냅샷 | asks/bids 10단계, bid_ask_ratio, spread_bps |
| OrderBookAnalysis | 호가 분석 | large_sell_wall, liquidity_score, imbalance_direction |
| PriceDistribution | 매물대 | strongest_resistance, strongest_support |
| MarketEnvironment | 시장 환경 | regime, vi_stocks, sector 동향 |
| StockState | 종목 상태 | trading_status, warning_level, tick_size, margin_rate |
| CorporateEvent | 기업 이벤트 | event_type, record_date, ex_date |

---

## 4. 데이터 흐름 (Edge 정의, 12개)

### 4.1 내부 Edge (5 Edges)

| # | Source → Target | Type/Role | 데이터 |
|---|----------------|-----------|--------|
| 1 | SupplyDemandAnalyzer → MarketIntelStore | DataFlow/DataPipe | SupplyDemandSnapshot |
| 2 | OrderBookAnalyzer → MarketIntelStore | DataFlow/DataPipe | OrderBookAnalysis |
| 3 | MarketRegimeDetector → MarketIntelStore | DataFlow/DataPipe | MarketEnvironment |
| 4 | StockStateMonitor → MarketIntelStore | DataFlow/DataPipe | StockState |
| 5 | ConditionSearchBridge → MarketIntelStore | DataFlow/DataPipe | ConditionResult |

### 4.2 입력 Edge (3 Edges)

| # | Source → Target | Type/Role | 데이터 |
|---|----------------|-----------|--------|
| 6 | MarketDataStore → SupplyDemandAnalyzer | Dependency/ConfigRef | 시세 데이터 |
| 7 | MarketDataStore → OrderBookAnalyzer | Dependency/ConfigRef | 호가 데이터 |
| 8 | ConfigStore → Path 6 전체 | Dependency/ConfigRef | 임계값 설정 |

### 4.3 출력 Edge — Cross-Path (4 Edges)

| # | Source → Target | Type/Role | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 9 | MarketIntelStore → Path 1 StrategyEngine | Dependency/ConfigRef | MarketContext | 진입 판단 참조 |
| 10 | MarketIntelStore → Path 1 ExitConditionGuard | Dependency/ConfigRef | MarketContext | 청산 판단 참조 |
| 11 | MarketIntelStore → Path 3 StrategyCollector | Dependency/ConfigRef | ConditionResult | 전략 아이디어 소스 |
| 12 | MarketRegimeDetector → Path 1 (긴급) | Event/EventNotify | MarketRegime 변경 | CB/VI 즉시 통보 |

---

## 5. Shared Store 스키마 (신규: MarketIntelStore)

```sql
-- 종목별 수급 스냅샷
CREATE TABLE supply_demand (
    symbol          TEXT NOT NULL,
    foreign_net     INT,
    institution_net INT,
    program_net     INT,
    individual_net  INT,
    volume_power    FLOAT,
    short_sale_ratio FLOAT,
    credit_balance_ratio FLOAT,
    snapshot_at     TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (symbol, snapshot_at)
);

-- 종목별 호가 분석
CREATE TABLE orderbook_analysis (
    symbol          TEXT NOT NULL,
    bid_ask_ratio   FLOAT,
    spread_bps      FLOAT,
    large_sell_wall BOOLEAN,
    large_buy_wall  BOOLEAN,
    liquidity_score FLOAT,
    imbalance       TEXT,          -- "buy_pressure" | "sell_pressure" | "balanced"
    analyzed_at     TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (symbol, analyzed_at)
);

-- 시장 환경 이력
CREATE TABLE market_regime (
    regime          TEXT NOT NULL,
    kospi_pct       FLOAT,
    kosdaq_pct      FLOAT,
    cb_active       BOOLEAN DEFAULT FALSE,
    sidecar_active  BOOLEAN DEFAULT FALSE,
    vi_count        INT DEFAULT 0,
    recorded_at     TIMESTAMPTZ DEFAULT NOW() PRIMARY KEY
);

-- 종목 상태
CREATE TABLE stock_state (
    symbol          TEXT PRIMARY KEY,
    trading_status  TEXT NOT NULL DEFAULT 'tradable',
    warning_level   TEXT NOT NULL DEFAULT 'none',
    margin_rate     FLOAT DEFAULT 0.4,
    is_credit_ok    BOOLEAN DEFAULT TRUE,
    tick_size       INT,
    upper_limit     INT,
    lower_limit     INT,
    is_ex_dividend  BOOLEAN DEFAULT FALSE,
    vi_active       BOOLEAN DEFAULT FALSE,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 기업 이벤트
CREATE TABLE corporate_events (
    event_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol          TEXT NOT NULL,
    event_type      TEXT NOT NULL,
    record_date     DATE,
    ex_date         DATE,
    details         JSONB,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 종합 MarketContext (캐시)
CREATE TABLE market_context_cache (
    symbol          TEXT PRIMARY KEY,
    context         JSONB NOT NULL,    -- MarketContext 전체 직렬화
    entry_safe      BOOLEAN,
    exit_urgent     BOOLEAN,
    caution_reasons TEXT[],
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 인덱스
CREATE INDEX idx_supply_demand_symbol ON supply_demand(symbol, snapshot_at);
CREATE INDEX idx_regime_time ON market_regime(recorded_at);
CREATE INDEX idx_stock_state_status ON stock_state(trading_status);
CREATE INDEX idx_corporate_events_date ON corporate_events(ex_date);
CREATE INDEX idx_context_cache_safe ON market_context_cache(entry_safe);
```

---

## 6. Safeguard 적용

### 6.1 Path 6 → Path 1 긴급 통보 규칙

| 감지 조건 | 즉시 통보 대상 | 행동 |
|----------|---------------|------|
| 서킷브레이커 발동 | Path 1 전체 | 모든 신규 주문 Edge 즉시 차단 |
| 사이드카 발동 | Path 1 StrategyEngine | 프로그램매매 기반 전략 5분 일시정지 |
| 보유 종목 VI 발동 | Path 1 ExitConditionGuard | 해당 종목 시장가 청산 보류, VI 해제 후 재평가 |
| 보유 종목 거래정지 | Path 1 WatchlistManager | 상태 HALTED로 전환, 청산 불가 표시 |
| 보유 종목 투자위험 지정 | Path 1 ExitConditionGuard | 즉시 청산 검토 (FORCE_CLOSE 규칙 추가) |
| 보유 종목 배당락일 | Path 1 ExitConditionGuard | 손절 기준가를 배당락 조정가로 변경 |

### 6.2 Path 6 자체 Safeguard

```
수급 데이터 수집
    → [RateLimitGuard]      KIS API 호출 속도 제한 (초당 20건)
    → [StalenessGuard]      데이터 신선도 검증 (5분 이상 오래된 수급 데이터 폐기)
    → MarketIntelStore 저장
    → [ConsistencyGuard]    전일 대비 비정상 변동 감지 (데이터 오류 필터링)
```

---

## 7. Adapter Mapping 요약

| Port | 운영 | 테스트 |
|------|------|--------|
| SupplyDemandPort | KISSupplyDemandAdapter | MockSupplyDemandAdapter |
| OrderBookPort | KISOrderBookAdapter | MockOrderBookAdapter |
| MarketRegimePort | KISMarketRegimeAdapter | MockMarketRegimeAdapter |
| StockStatePort | KISStockStateAdapter | MockStockStateAdapter |
| ConditionSearchPort | KISConditionSearchAdapter | MockConditionSearchAdapter |

**YAML 설정 예시:**

```yaml
path6_intelligence:
  supply_demand:
    implementation: KISSupplyDemandAdapter
    params:
      poll_interval_seconds: 60         # 1분 주기
      bulk_threshold_volume: 10000      # 대량체결 기준 (주)

  orderbook:
    implementation: KISOrderBookAdapter
    params:
      realtime: true                    # WebSocket 실시간 호가
      spread_alert_bps: 50             # 스프레드 경고 임계값

  market_regime:
    implementation: KISMarketRegimeAdapter
    params:
      sector_codes: ["0001", "1001", "0028", "0017", "0024"]
      # KOSPI, KOSDAQ, 반도체, 자동차, 2차전지
      volatility_threshold: 2.0        # 변동성 확대 판단 기준 (%)

  stock_state:
    implementation: KISStockStateAdapter
    params:
      check_interval_seconds: 300       # 5분 주기 상태 갱신
      event_lookahead_days: 5           # 5일 이내 기업 이벤트

  condition_search:
    implementation: KISConditionSearchAdapter
    params:
      hts_user_id: ${KIS_HTS_USER_ID}
      scan_interval_minutes: 30
```

---

## 8. 전체 아키텍처 업데이트 요약

### Shared Store 변경: 7 → 8개

| # | Store | 신규 여부 |
|---|-------|----------|
| 1 | MarketDataStore | 기존 |
| 2 | PortfolioStore | 기존 |
| 3 | ConfigStore | 기존 |
| 4 | KnowledgeStore | 기존 |
| 5 | StrategyStore | 기존 |
| 6 | AuditStore | 기존 |
| 7 | WatchlistStore | Path 1 v2.0에서 추가 |
| 8 | **MarketIntelStore** | **Path 6에서 추가** |

### 전체 수치 업데이트

| 항목 | 이전 | Path 6 추가 | 현재 |
|------|------|------------|------|
| Paths | 5 | +1 | 6 |
| Nodes | 38 | +5 | 43 |
| Ports | 31 | +5 | 36 |
| Domain Types | 62 | +14 | 76 |
| Edges | 68 | +12 | 80 |
| Shared Stores | 7 | +1 | 8 |

---

## 9. 다음 단계

- **Order Lifecycle Spec** — 주문 상태 머신 + BrokerPort 확장 + 에러 처리
- **Edge Contract Definition 갱신** — Path 6 Edge 12개 + Path 1↔Path 6 연결
- **System Manifest** — 43개 노드 전체 레지스트리
- **INDEX.md 갱신**

---

*End of Document — Port Interface Path 6 v1.0*
*5 Nodes | 5 Ports | 14 Domain Types | 12 Edges | 1 New Shared Store*
*전체 L0 — 수치 기반 분석만, LLM 호출 없음*
*핵심 출력: MarketContext — "지금 매수해도 되는 환경인가"*
