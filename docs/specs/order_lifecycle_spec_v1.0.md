# Order Lifecycle Specification

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | order_lifecycle_spec_v1.0 |
| 선행 문서 | port_interface_path1_v2.0, edge_contract_definition_v1.0, port_interface_path6_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |

---

## 1. 주문 상태 머신 (OrderFSM)

### 1.1 주문 상태 (11종)

```python
class OrderLifecycleState(Enum):
    # === 주문 전 ===
    DRAFT = "draft"                     # 시스템 내부에서 생성, 아직 미제출
    VALIDATING = "validating"           # Pre-order 검증 중

    # === 주문 제출 ===
    SUBMITTING = "submitting"           # API 전송 중 (응답 대기)
    SUBMITTED = "submitted"             # API 응답 수신, 주문번호 발급

    # === 거래소 처리 ===
    ACCEPTED = "accepted"               # 거래소 접수 완료
    REJECTED = "rejected"               # 거래소 거부 (terminal)

    # === 체결 ===
    PARTIALLY_FILLED = "partially_filled"  # 부분 체결
    FILLED = "filled"                   # 전량 체결 (terminal)

    # === 정정/취소 ===
    MODIFYING = "modifying"             # 정정 요청 중
    CANCELLING = "cancelling"           # 취소 요청 중
    CANCELLED = "cancelled"             # 취소 완료 (terminal)

    # === 장애 ===
    UNKNOWN = "unknown"                 # 응답 미수신 — 상태 불명
```

### 1.2 상태 전이 규칙

```
DRAFT → VALIDATING → SUBMITTING → SUBMITTED → ACCEPTED
                                       ↓              ↓
                                    UNKNOWN        REJECTED
                                                      ↓
ACCEPTED → PARTIALLY_FILLED → FILLED                (terminal)
    ↓              ↓
 MODIFYING    CANCELLING
    ↓              ↓
 ACCEPTED      CANCELLED (terminal)

특수 전이:
  SUBMITTING → UNKNOWN       (API 타임아웃, 네트워크 장애)
  UNKNOWN → SUBMITTED        (재조회로 상태 확인)
  UNKNOWN → REJECTED         (재조회로 거부 확인)
  MODIFYING → REJECTED       (이미 체결되어 정정 불가)
  CANCELLING → REJECTED      (이미 체결되어 취소 불가)
  PARTIALLY_FILLED → CANCELLING  (잔량 취소)
```

### 1.3 Terminal 상태

| 상태 | 의미 | 후속 처리 |
|------|------|----------|
| FILLED | 전량 체결 완료 | PositionMonitor에 포지션 등록 |
| CANCELLED | 취소 완료 | WatchlistManager 상태 복원 |
| REJECTED | 거부 | 사유 분석 → 재시도 또는 폐기 |

### 1.4 UNKNOWN 상태 복구 프로세스

```
1. 주문 전송 후 5초 내 응답 없음 → UNKNOWN 전이
2. 즉시 미체결 주문 조회 API 호출 (inquire-psbl-rvsecncl)
3. 주문번호가 존재하면 → SUBMITTED로 복원
4. 존재하지 않으면 → 5초 후 재조회 (최대 3회)
5. 3회 모두 미발견 → REJECTED로 처리 (주문이 접수되지 않은 것으로 판단)
6. 모든 복구 시도 → AuditLogger에 기록 + 알림
```

---

## 2. 주문 유형 전체 목록

### 2.1 KRX 주문 구분 (ORD_DVSN)

```python
class OrderDivision(Enum):
    """KIS API ORD_DVSN 코드 — 완전한 목록"""
    # === 기본 ===
    LIMIT = "00"                    # 지정가
    MARKET = "01"                   # 시장가
    CONDITIONAL = "02"              # 조건부지정가 (장중=지정가, 종가=시장가)
    BEST_LIMIT = "03"               # 최유리지정가
    BEST_FIRST = "04"               # 최우선지정가

    # === 시간외 ===
    PRE_MARKET = "05"               # 장전 시간외
    POST_MARKET = "06"              # 장후 시간외
    AFTER_HOURS_SINGLE = "07"       # 시간외 단일가

    # === IOC (Immediate or Cancel) ===
    IOC_LIMIT = "11"                # IOC 지정가 — 즉시체결, 잔량취소
    FOK_LIMIT = "12"                # FOK 지정가 — 전량체결, 아니면 전량취소
    IOC_MARKET = "13"               # IOC 시장가
    FOK_MARKET = "14"               # FOK 시장가
    IOC_BEST = "15"                 # IOC 최유리
    FOK_BEST = "16"                 # FOK 최유리

    # === NXT/SOR 전용 ===
    MID_PRICE = "21"                # 중간가 (매수/매도 최우선 호가의 중간)
    STOP_LIMIT = "22"               # 스톱지정가 (조건가 도달 시 지정가 주문)
    MID_PRICE_IOC = "23"            # 중간가 IOC
    MID_PRICE_FOK = "24"            # 중간가 FOK
```

### 2.2 거래소 구분

```python
class ExchangeType(Enum):
    """거래소 ID 구분"""
    KRX = "KRX"                     # 한국거래소 (기본)
    NXT = "NXT"                     # 넥스트레이드 (대체거래소)
    SOR = "SOR"                     # Smart Order Routing (자동 최적 경로)
```

### 2.3 주문 유형별 제약 조건

| 주문 유형 | 가격 필수 | 장중 | 동시호가 | 시간외 | NXT | SOR |
|----------|----------|------|---------|--------|-----|-----|
| LIMIT (00) | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| MARKET (01) | ❌ (0) | ✅ | ❌ | ❌ | ❌ | ✅ |
| CONDITIONAL (02) | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| BEST_LIMIT (03) | ❌ | ✅ | ❌ | ❌ | ✅ | ✅ |
| BEST_FIRST (04) | ❌ | ✅ | ❌ | ❌ | ✅ | ✅ |
| PRE_MARKET (05) | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ |
| POST_MARKET (06) | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ |
| STOP_LIMIT (22) | ✅+조건가 | ✅ | ❌ | ❌ | ✅ | ❌ |
| IOC_LIMIT (11) | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ |
| FOK_LIMIT (12) | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ |

---

## 3. Pre-Order 검증 체크리스트

주문이 DRAFT → VALIDATING 단계에서 통과해야 하는 검증 항목. **하나라도 실패하면 주문 폐기.**

### 3.1 종목 검증

```python
@dataclass(frozen=True)
class PreOrderCheck:
    """주문 전 검증 결과"""
    passed: bool
    failed_checks: list[str]      # 실패한 검증 항목
    warnings: list[str]           # 경고 (통과하지만 주의)
    corrected_price: int | None   # 호가단위 보정된 가격 (있으면)
```

| # | 검증 항목 | 소스 | 실패 시 |
|---|----------|------|---------|
| 1 | **거래 가능 여부** | Path 6 StockState.is_tradable | 주문 폐기 |
| 2 | **VI 발동 여부** | Path 6 StockState.vi_active | 시장가 차단, 지정가만 허용 |
| 3 | **투자경고/위험 종목** | Path 6 StockState.warning_level | WARNING/DANGER면 매수 차단 |
| 4 | **상한가/하한가 도달** | Path 6 StockState.at_upper/lower_limit | 상한가 매수/하한가 매도 차단 |
| 5 | **호가단위 준수** | Path 6 StockState.validate_order_price | 자동 보정 + 경고 |
| 6 | **가격제한폭 범위** | Path 6 StockState.price_limits | 범위 초과 시 폐기 |
| 7 | **장 시간대 주문 유형 제한** | ClockPort.get_status + OrderDivision | 동시호가 중 시장가 → 차단 |
| 8 | **시장 환경 안전** | Path 6 MarketContext.entry_safe | False면 경고 (차단 아님, 전략 판단) |
| 9 | **서킷브레이커/사이드카** | Path 6 MarketRegime | CB/사이드카 중이면 주문 폐기 |

### 3.2 자금 검증

| # | 검증 항목 | KIS API | 실패 시 |
|---|----------|---------|---------|
| 10 | **매수 가능 수량** | inquire-psbl-order → nrcvb_buy_qty | 수량 부족 → 가능 수량으로 축소 or 폐기 |
| 11 | **매수 가능 금액** | inquire-psbl-order → nrcvb_buy_amt | 금액 부족 → 폐기 |
| 12 | **매도 가능 수량** | inquire-psbl-sell | D+2 미도래분 제외 → 가능 수량으로 축소 |
| 13 | **증거금률 확인** | StockState.margin_rate | 100% 종목은 전액 현금 필요 → 가능 수량 재계산 |
| 14 | **미수금 발생 여부** | 매수금액 > 예수금 | 미수 사용 불가 설정이면 폐기 |

### 3.3 주문 유형 검증

| # | 검증 항목 | 규칙 | 실패 시 |
|---|----------|------|---------|
| 15 | **거래소 지원 확인** | OrderDivision × ExchangeType 매트릭스 | 미지원 조합 → 폐기 |
| 16 | **스톱지정가 조건가** | ORD_DVSN=22면 CNDT_PRIC 필수 | 누락 → 폐기 |
| 17 | **시장가 주문 금액 산정** | 시장가는 상한가 기준 금액 산정 | 예수금 부족 가능성 경고 |
| 18 | **분할 주문 필요성** | 주문 수량 > 일일거래량의 1% | 분할 주문 제안 (경고) |

---

## 4. During-Order 처리 (주문 실행 중)

### 4.1 주문 정정 (Modify Order)

```python
@dataclass(frozen=True)
class ModifyOrderRequest:
    """주문 정정 요청"""
    original_order_id: str        # 원주문 번호 (ORGN_ODNO)
    krx_org_no: str               # 한국거래소전송주문조직번호
    modify_type: str              # "price" | "quantity" | "both"
    new_price: int | None         # 정정 가격
    new_quantity: int | None      # 정정 수량
    new_order_division: str | None  # 주문구분 변경 (예: 지정가→시장가)
    all_quantity: bool = False    # 잔량 전부 여부 (QTY_ALL_ORD_YN)
    exchange: ExchangeType = ExchangeType.KRX
```

**정정 규칙:**
- 정정 전 반드시 `inquire-psbl-rvsecncl` 호출하여 정정 가능 수량 확인
- 정정 수량은 원주문 수량을 초과할 수 없음
- 이미 체결된 수량은 정정 불가 (잔량만 정정 가능)
- 정정 성공 시 새 주문번호 발급 — 원주문번호와 다름
- 주문 구분(지정가↔시장가) 변경도 정정으로 처리

### 4.2 주문 취소 (Cancel Order)

```python
@dataclass(frozen=True)
class CancelOrderRequest:
    """주문 취소 요청"""
    original_order_id: str
    krx_org_no: str
    cancel_quantity: int | None   # None이면 잔량 전부
    all_quantity: bool = True     # QTY_ALL_ORD_YN
    exchange: ExchangeType = ExchangeType.KRX
```

**취소 규칙:**
- 이미 전량 체결된 주문 취소 시도 → API 거부 → REJECTED
- 부분 체결 후 잔량만 취소 가능
- 취소 성공 시 새 주문번호 발급
- IOC/FOK 주문은 자동 취소되므로 수동 취소 불필요

### 4.3 부분 체결 (Partial Fill) 처리

```python
@dataclass
class OrderTracker:
    """주문 추적기 — 부분 체결 관리"""
    order_id: str
    symbol: str
    side: str
    requested_qty: int
    filled_qty: int = 0
    remaining_qty: int = 0
    fills: list[dict] = field(default_factory=list)
    # [{"fill_qty": 30, "fill_price": 72000, "fill_time": "...", "fill_no": "..."}]
    avg_fill_price: float = 0.0
    total_commission: float = 0.0
    state: OrderLifecycleState = OrderLifecycleState.DRAFT
    created_at: datetime = field(default_factory=datetime.now)
    last_event_at: datetime | None = None
```

**부분 체결 규칙:**
1. WebSocket 체결통보(H0STCNI0)에서 CNTG_YN=2(체결) 수신
2. `filled_qty += CNTG_QTY`, `remaining_qty = requested_qty - filled_qty`
3. `avg_fill_price` 가중평균 재계산
4. `remaining_qty == 0`이면 FILLED로 전이
5. 미체결 타임아웃(configurable, 기본 5분) 도달 시 잔량 자동 취소

### 4.4 실시간 체결통보 파싱

KIS WebSocket H0STCNI0 응답은 `^`로 구분된 문자열. 핵심 필드:

```python
@dataclass(frozen=True)
class ExecutionNotification:
    """실시간 체결통보 파싱 결과"""
    account_no: str               # [1] 계좌번호
    order_no: str                 # [2] 주문번호
    original_order_no: str        # [3] 원주문번호
    side: str                     # [4] 01=매도, 02=매수
    modify_cancel_flag: str       # [5] 0=정상, 1=정정, 2=취소
    order_division: str           # [6] 주문종류 (00~24)
    order_condition: str          # [7] 0=없음, 1=IOC, 2=FOK
    stock_code: str               # [8] 종목코드
    filled_qty: int               # [9] 체결수량
    filled_price: int             # [10] 체결단가
    fill_time: str                # [11] 체결시간
    is_rejected: bool             # [12] 0=승인, 1=거부
    is_fill: bool                 # [13] 1=접수/정정/취소/거부, 2=체결
    is_accepted: str              # [14] 1=접수, 2=확인, 3=취소(FOK/IOC)
    order_qty: int                # [16] 주문수량
    exchange_id: str              # [20] 1=KRX, 2=NXT, 3=SOR-KRX, 4=SOR-NXT
    stop_price: int               # [21] 스톱지정가 조건가격
    order_price: int              # [23] 주문가격

    @property
    def event_type(self) -> str:
        if self.is_fill:
            return "FILL"
        if self.is_rejected:
            return "REJECTED"
        if self.modify_cancel_flag == "1":
            return "MODIFIED"
        if self.modify_cancel_flag == "2":
            return "CANCELLED"
        return "ACCEPTED"
```

---

## 5. Post-Order 처리 (체결 후)

### 5.1 체결 후 즉시 처리

| # | 처리 항목 | 대상 | 시점 |
|---|----------|------|------|
| 1 | 포지션 갱신 | PositionMonitor.register_position | FILLED 즉시 |
| 2 | 워치리스트 상태 전이 | WatchlistManager.update_status → IN_POSITION | FILLED 즉시 |
| 3 | 잔고 동기화 | BrokerPort.get_account → PortfolioStore | FILLED 후 1초 |
| 4 | 청산 규칙 설정 | ExitConditionGuard.set_rules | FILLED 즉시 |
| 5 | 슬리피지 기록 | AuditLogger | FILLED 즉시 |
| 6 | 체결 기록 저장 | StoragePort.save_trade (WAL) | FILLED 즉시 |

### 5.2 슬리피지 추적

```python
@dataclass(frozen=True)
class SlippageRecord:
    """슬리피지 기록"""
    order_id: str
    symbol: str
    side: str
    expected_price: int           # 주문 시점 예상 가격 (전략이 본 가격)
    order_price: int              # 실제 주문가 (지정가) 또는 0 (시장가)
    avg_fill_price: float         # 실제 체결 평균가
    slippage_amount: float        # 슬리피지 금액 (원)
    slippage_bps: float           # 슬리피지 (bps)
    quantity: int
    market_impact_estimate: float # 시장 충격 추정 (거래량 대비 주문량)
```

### 5.3 일일 결산

| # | 처리 항목 | 시점 |
|---|----------|------|
| 1 | 미체결 주문 전량 취소 | 장 마감 3분 전 (configurable) |
| 2 | 실계좌 잔고 대조 (Reconciliation) | 장 마감 후 |
| 3 | 일일 거래 요약 생성 | 장 마감 후 |
| 4 | 수수료/세금 정산 확인 | 장 마감 후 |
| 5 | D+2 결제 예정 내역 업데이트 | 장 마감 후 |

---

## 6. BrokerPort 확장 메서드

기존 BrokerPort에 추가해야 하는 메서드들.

```python
class BrokerPortExtended(BrokerPort):
    """BrokerPort 확장 — 정정/취소/가능수량/체결통보"""

    # === 주문 정정/취소 ===

    @abstractmethod
    async def modify_order(
        self, request: ModifyOrderRequest
    ) -> OrderResult:
        """
        주문 정정 (가격/수량/주문유형 변경).
        정정 전 get_modifiable_orders 호출 필수.
        Returns: 새 주문번호 포함 결과
        """
        ...

    @abstractmethod
    async def get_modifiable_orders(self) -> list[dict]:
        """
        정정/취소 가능한 미체결 주문 목록.
        KIS API: inquire-psbl-rvsecncl
        Returns: [{"order_no": "...", "symbol": "...", "psbl_qty": 50, ...}]
        """
        ...

    # === 가능 수량/금액 조회 ===

    @abstractmethod
    async def get_buyable_quantity(
        self, symbol: str, price: int,
        order_division: str = "01"
    ) -> dict:
        """
        매수 가능 수량/금액 조회.
        KIS API: inquire-psbl-order
        Returns: {"nrcvb_buy_qty": 100, "nrcvb_buy_amt": 7200000,
                  "max_buy_qty": 200, "max_buy_amt": 14400000,
                  "margin_rate": 0.4}
        """
        ...

    @abstractmethod
    async def get_sellable_quantity(
        self, symbol: str
    ) -> dict:
        """
        매도 가능 수량 조회 (D+2 결제 고려).
        KIS API: inquire-psbl-sell
        Returns: {"total_qty": 100, "sellable_qty": 80,
                  "unsettled_qty": 20, "loan_qty": 0}
        """
        ...

    # === 실시간 체결통보 ===

    @abstractmethod
    async def subscribe_execution_notice(
        self, callback: callable
    ) -> None:
        """
        실시간 체결통보 구독.
        KIS WebSocket: H0STCNI0
        callback(notification: ExecutionNotification)
        모든 주문의 접수/정정/취소/거부/체결을 실시간 수신.
        """
        ...

    @abstractmethod
    async def unsubscribe_execution_notice(self) -> None:
        """체결통보 구독 해제."""
        ...

    # === 주문 이력 ===

    @abstractmethod
    async def get_daily_orders(
        self, start_date: str, end_date: str
    ) -> list[dict]:
        """
        일별 주문 체결 조회.
        KIS API: inquire-daily-ccld
        """
        ...

    # === 예약 주문 ===

    @abstractmethod
    async def submit_reserved_order(
        self, order: OrderRequest, reserve_time: str
    ) -> str:
        """
        예약 주문 접수. 지정 시간에 자동 제출.
        KIS API: order-resv
        Returns: 예약 주문 번호
        """
        ...

    @abstractmethod
    async def cancel_reserved_order(
        self, reserve_order_no: str
    ) -> bool:
        """예약 주문 취소."""
        ...

    @abstractmethod
    async def get_reserved_orders(self) -> list[dict]:
        """예약 주문 조회."""
        ...
```

---

## 7. KRX 호가단위 테이블

```python
KRX_TICK_SIZE_TABLE = [
    # (min_price, max_price, tick_size)
    (0,       2_000,     1),
    (2_000,   5_000,     5),
    (5_000,   20_000,    10),
    (20_000,  50_000,    50),
    (50_000,  200_000,   100),
    (200_000, 500_000,   500),
    (500_000, None,      1_000),   # 50만원 이상
]

def get_tick_size(price: int) -> int:
    for min_p, max_p, tick in KRX_TICK_SIZE_TABLE:
        if max_p is None or price < max_p:
            return tick
    return 1_000

def round_to_tick(price: int, direction: str = "down") -> int:
    """호가단위에 맞게 가격 보정. direction: 'down'=내림, 'up'=올림"""
    tick = get_tick_size(price)
    if direction == "down":
        return (price // tick) * tick
    else:
        return ((price + tick - 1) // tick) * tick
```

---

## 8. 에러 코드 + 복구 전략

### 8.1 KIS API 에러 분류

| 에러 유형 | 대표 코드 | 복구 전략 |
|----------|----------|----------|
| **인증 만료** | EGW00123 | 토큰 재발급 → 재시도 |
| **요청 초과** | EGW00201 | 지수 백오프 (1s→2s→4s) → 재시도 |
| **주문 거부 (자금 부족)** | APBK0919 | 가능 수량 재조회 → 수량 축소 → 재시도 |
| **주문 거부 (호가 단위)** | APBK0634 | 호가단위 보정 → 재시도 |
| **주문 거부 (거래 정지)** | APBK0698 | 즉시 폐기 + 워치리스트 상태 변경 |
| **주문 거부 (상한가/하한가)** | APBK0640 | 즉시 폐기 |
| **정정 불가 (이미 체결)** | APBK0721 | 정정 취소 + 체결 확인 |
| **취소 불가 (이미 체결)** | APBK0722 | 취소 취소 + 체결 확인 |
| **서버 오류** | 5xx | 3회 재시도 → Circuit Breaker |
| **네트워크 타임아웃** | — | UNKNOWN 상태 → 복구 프로세스 |

### 8.2 재시도 정책

```python
@dataclass(frozen=True)
class RetryPolicy:
    """주문 재시도 정책"""
    max_attempts: int = 3
    backoff_type: str = "exponential"   # "fixed" | "exponential"
    base_delay_ms: int = 1000
    max_delay_ms: int = 10000
    retryable_errors: list[str] = field(default_factory=lambda: [
        "EGW00123",   # 토큰 만료
        "EGW00201",   # 요청 초과
    ])
    non_retryable_errors: list[str] = field(default_factory=lambda: [
        "APBK0698",   # 거래 정지
        "APBK0640",   # 상한가/하한가
        "APBK0721",   # 이미 체결 (정정 불가)
    ])
```

### 8.3 에러 → OrderFSM 전이 매핑

| 에러 | 현재 상태 | 전이 | 후속 |
|------|----------|------|------|
| 인증 만료 | SUBMITTING | → VALIDATING | 토큰 갱신 후 재제출 |
| 자금 부족 | VALIDATING | → REJECTED | 수량 축소 후 재검증 가능 |
| 호가 단위 | VALIDATING | → VALIDATING | 가격 보정 후 재검증 |
| 거래 정지 | VALIDATING | → REJECTED | 즉시 폐기 |
| 서버 오류 | SUBMITTING | → UNKNOWN | 재시도 정책 적용 |
| 타임아웃 | SUBMITTING | → UNKNOWN | 주문 상태 재조회 |
| 정정 실패 | MODIFYING | → ACCEPTED | 원 주문 상태 유지 |

---

## 9. 수수료/세금 계산

```python
@dataclass(frozen=True)
class TransactionCost:
    """거래 비용 계산"""
    commission: float             # 증권사 수수료
    securities_tax: float         # 증권거래세 (매도 시만)
    education_tax: float          # 농어촌특별세 (매도 시만)
    total_cost: float

# 2026년 기준 (변경 가능 — ConfigStore에서 관리)
COST_PARAMS = {
    "commission_rate": 0.00015,     # 매매 수수료율 (0.015%)
    "min_commission": 0,            # 최소 수수료 (무료 이벤트 시 0)
    "securities_tax_rate": 0.0018,  # 증권거래세 (0.18%, 매도 시만)
    "education_tax_rate": 0.0,      # 농어촌특별세 (코스피 면제)
}

def calculate_cost(
    side: str, price: float, quantity: int, market: str = "kospi"
) -> TransactionCost:
    amount = price * quantity
    commission = max(
        amount * COST_PARAMS["commission_rate"],
        COST_PARAMS["min_commission"]
    )
    if side == "sell":
        securities_tax = amount * COST_PARAMS["securities_tax_rate"]
        education_tax = amount * COST_PARAMS["education_tax_rate"]
    else:
        securities_tax = 0
        education_tax = 0
    return TransactionCost(
        commission=commission,
        securities_tax=securities_tax,
        education_tax=education_tax,
        total_cost=commission + securities_tax + education_tax,
    )
```

---

## 10. Edge Contract 추가 (Order Lifecycle 관련)

### 10.1 신규 Edge (4개)

```yaml
# E-OL-01: BrokerPort → OrderTracker (체결통보)
edge_id: e_broker_execution_notice
edge_type: Event
edge_role: EventNotify
source: { node_id: BrokerPort, port_name: execution_notice, path: path1.1b }
target: { node_id: OrderExecutor, port_name: notice_in, path: path1.1b }
payload: { type: ExecutionNotification }
contract:
  delivery: async
  ordering: strict              # 체결 순서 보장 필수
  retry: { max_attempts: 0, backoff: null, dead_letter: false }
  timeout_ms: null              # WebSocket push — 타임아웃 없음
  idempotency: true             # order_no + fill_no 기반

# E-OL-02: OrderExecutor → OrderTracker 상태 갱신
edge_id: e_executor_order_tracker
edge_type: DataFlow
edge_role: DataPipe
source: { node_id: OrderExecutor, port_name: tracker_out, path: path1.1b }
target: { node_id: TradingFSM, port_name: order_state_in, path: path1.1b }
payload: { type: OrderTracker }
contract: { delivery: sync, ordering: strict, timeout_ms: 200, idempotency: true }

# E-OL-03: Path 6 StockState → Pre-Order Validator
edge_id: e_stock_state_to_validator
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: MarketIntelStore, port_name: stock_state_out, path: shared }
target: { node_id: RiskGuard, port_name: stock_state_in, path: path1.1b }
payload: { type: StockState }
contract: { delivery: sync, ordering: best-effort, timeout_ms: 500, idempotency: true }

# E-OL-04: BrokerPort → Pre-Order (가능수량 조회)
edge_id: e_broker_buyable_check
edge_type: Dependency
edge_role: ConfigRef
source: { node_id: BrokerPort, port_name: buyable_out, path: path1.1b }
target: { node_id: RiskGuard, port_name: buyable_in, path: path1.1b }
payload: { type: "dict (nrcvb_buy_qty, margin_rate)" }
contract: { delivery: sync, ordering: strict, timeout_ms: 2000, idempotency: false }
```

---

## 11. Validation Rules (Order Lifecycle)

| Rule ID | Description | Severity |
|---------|-------------|----------|
| V-ORDER-001 | 모든 주문은 DRAFT → VALIDATING → SUBMITTING 순서 필수 | error |
| V-ORDER-002 | VALIDATING에서 PreOrderCheck.passed == false면 REJECTED 전이 | error |
| V-ORDER-003 | SUBMITTING 후 5초 내 응답 없으면 UNKNOWN 전이 | error |
| V-ORDER-004 | UNKNOWN 상태에서 3회 재조회 실패 시 REJECTED | warning |
| V-ORDER-005 | 정정 전 get_modifiable_orders 호출 필수 | error |
| V-ORDER-006 | 시장가 주문 시 ORD_UNPR = "0" 필수 | error |
| V-ORDER-007 | 호가단위 미준수 주문은 자동 보정 + 경고 로깅 | warning |
| V-ORDER-008 | IOC/FOK 주문의 미체결 잔량은 자동 취소 — 수동 취소 불필요 | info |
| V-ORDER-009 | 부분 체결 주문의 잔량 타임아웃은 ConfigStore에서 관리 | warning |
| V-ORDER-010 | 체결통보(H0STCNI0) 구독 없이 주문 제출 금지 | error |

---

## 12. 전체 수치 업데이트

| 항목 | 이전 | 추가 | 현재 |
|------|------|------|------|
| Domain Types | 76 | +6 (OrderLifecycleState, OrderDivision, ExchangeType, ModifyOrderRequest, CancelOrderRequest, ExecutionNotification, OrderTracker, PreOrderCheck, SlippageRecord, TransactionCost) | 86 |
| Edges | 80 | +4 | 84 |
| BrokerPort 메서드 | 8 | +8 | 16 |
| Validation Rules | (기존) | +10 | (누적) |

---

## 13. 다음 단계

- **Edge Contract Definition v1.1** — Path 6 + Order Lifecycle 반영 (68 → 84 Edges)
- **System Manifest** — 43개 노드 + 36개 Port + 84개 Edge
- **BrokerPort v2.0** — 기존 + 확장 메서드 통합
- **KIS Adapter 구현 시작** (Claude Code)

---

*End of Document — Order Lifecycle Spec v1.0*
*11 OrderFSM States | 24 Order Divisions | 3 Exchanges | 18 Pre-Order Checks*
*BrokerPort +8 Methods | 4 New Edges | 10 Validation Rules*
*KIS WebSocket H0STCNI0 체결통보 완전 파싱*
