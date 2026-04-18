# Phase 1 Port 인터페이스 시그니처 (8 Port·33 메서드)

> **목적**: Phase 1에서 사용하는 6개 Port의 Python ABC 시그니처, PortError 예외 계층, Adapter 매핑을 정의한다.
> **층**: What
> **상태**: Phase 1 확정
> **최종 수정**: 2026-04-17
> **구현 여정**: Step 02에서 코드로 구현. Phase 1 종료까지 불변 (ADR-012 §7). 변경 시 ADR 발행 필수.
> **선행 문서**: `docs/what/specs/domain-types-phase1.md` (입출력 타입 정의)
> **구현 위치**: `ports/*.py`
> **진실의 원천**: `graph_ir_phase1.yaml` → Port 메서드 목록 기준

## 1. Port 설계 원칙

1. **ABC만 정의** — 구현 없음. 모든 로직은 Adapter가 담당.
2. **async 전용** — 모든 메서드는 `async def`. 동기 호출 금지.
3. **Domain Type 의존** — 파라미터/반환 타입은 `domain_types_phase1`의 20개 타입만 사용.
4. **예외 체계** — Port 전용 예외를 `PortError` 기반으로 통일. Adapter가 내부 예외를 변환해 raise.
5. **Phase 2 확장 예약** — 메서드 추가 시 기존 ABC를 수정하지 않고 `Port2`처럼 확장.

---

## 2. 공통 예외 계층

```python
# ports/exceptions.py

class PortError(Exception):
    """모든 Port 예외의 기반. Adapter가 내부 예외를 이것으로 변환."""
    pass

class ConnectionError(PortError):
    """브로커/시세/DB 연결 실패"""
    pass

class TimeoutError(PortError):
    """응답 대기 초과 (config의 *_timeout_seconds 기준)"""
    pass

class AuthError(PortError):
    """인증 실패 (KIS API key 오류 등)"""
    pass

class DataError(PortError):
    """입력/출력 데이터 파싱 실패"""
    pass

class BrokerRejectError(PortError):
    """브로커가 명시적으로 주문 거절 (자금 부족, 제한 종목 등)"""
    code: str    # KIS 에러 코드
    message: str

class StorageError(PortError):
    """DB 저장/조회 실패"""
    pass
```

---

## 3. 8개 Port ABC

### 3.1 MarketDataPort

> **역할**: 시세 수신 추상화 (WebSocket / REST / CSV Replay)
> **사용 노드**: MarketDataReceiver
> **어댑터**: KISWebSocketAdapter (primary), KISRestAdapter (fallback), CSVReplayAdapter (mock)

```python
# ports/market_data_port.py
from abc import ABC, abstractmethod
from collections.abc import AsyncIterator
from datetime import datetime

from domain.market import Quote, OHLCV
from domain.primitives import Symbol


class MarketDataPort(ABC):

    @abstractmethod
    async def subscribe(self, symbols: list[Symbol]) -> None:
        """종목 구독 시작.

        Args:
            symbols: 구독할 종목 코드 목록 (1개 이상)
        Raises:
            ConnectionError: 연결 실패
            AuthError: 인증 실패
        """

    @abstractmethod
    async def unsubscribe(self, symbols: list[Symbol]) -> None:
        """종목 구독 해제.

        Raises:
            ConnectionError: 연결 끊어진 상태
        """

    @abstractmethod
    def stream(self) -> AsyncIterator[Quote]:
        """구독 중인 종목의 틱 데이터를 비동기 스트림으로 반환.

        Usage:
            async for quote in port.stream():
                process(quote)
        Raises:
            ConnectionError: 연결 끊김 (재연결 정책은 Adapter 내부)
        """

    @abstractmethod
    async def get_current_price(self, symbol: Symbol) -> Quote:
        """단일 종목 현재가 조회 (REST 1회 요청).

        Returns:
            Quote: 최신 체결 틱
        Raises:
            ConnectionError, TimeoutError, DataError
        """

    @abstractmethod
    async def get_historical(
        self,
        symbol: Symbol,
        interval: str,           # '1d' | '1m' | '5m'
        start: datetime,
        end: datetime,
    ) -> list[OHLCV]:
        """과거 OHLCV 조회.

        Returns:
            list[OHLCV]: 시간 오름차순 정렬
        Raises:
            ConnectionError, TimeoutError, DataError
        """
```

---

### 3.2 OrderPort

> **역할**: 주문 제출/취소/조회 추상화 (주문 실행 전용)
> **사용 노드**: OrderExecutor
> **어댑터**: MockOrderAdapter (mock), KISPaperOrderAdapter (paper), SyntheticOrderAdapter (synthetic)
> **Phase 1 제약**: `kis_live` 어댑터는 연결 금지

```python
# ports/order_port.py
from abc import ABC, abstractmethod
from uuid import UUID

from domain.order import OrderRequest, OrderResult


class OrderPort(ABC):

    @abstractmethod
    async def submit(self, order: OrderRequest) -> OrderResult:
        """주문 제출.

        멱등성 보장: order.order_uuid 기준으로 중복 제출 시
        동일한 OrderResult를 반환 (Adapter 내부에서 처리).

        Returns:
            OrderResult: 제출 즉시 응답 (체결 완료 아님)
        Raises:
            BrokerRejectError: 브로커가 명시적 거절
            TimeoutError: config의 submit_timeout_seconds 초과
            ConnectionError: 브로커 연결 끊김
        """

    @abstractmethod
    async def cancel(self, order_uuid: UUID) -> OrderResult:
        """주문 취소 요청.

        Returns:
            OrderResult: 취소 결과 (status=CANCELLED or FAILED)
        Raises:
            BrokerRejectError: 이미 체결된 주문 취소 시도 등
            TimeoutError, ConnectionError
        """

    @abstractmethod
    async def get_order_status(self, order_uuid: UUID) -> OrderResult:
        """주문 현재 상태 조회.

        Raises:
            DataError: 해당 UUID 주문 없음
            ConnectionError, TimeoutError
        """
```

---

### 3.2b AccountPort

> **역할**: 계좌 조회 및 일관성 검증 (계좌 정보 전용, 주문 실행과 분리)
> **사용 노드**: RiskGuard (잔고/포지션 조회), TradingFSM (crash recovery 시 브로커 포지션 대조)
> **어댑터**: MockAccountAdapter (mock), KISPaperAccountAdapter (paper), SyntheticAccountAdapter (synthetic)
> **Phase 1 제약**: `kis_live` 어댑터는 연결 금지

**왜 OrderPort와 분리했는가**: KIS API가 주문(`/trading/order-cash`)과 계좌(`/trading/inquire-balance`)를
다른 엔드포인트로 분리해놓았다. ATLAS도 이 구조에 맞춰 단일 책임 원칙을 따른다.
이로써 OrderExecutor는 OrderPort만, RiskGuard는 AccountPort만 의존하게 되어 결합도가 낮아진다.

```python
# ports/account_port.py
from abc import ABC, abstractmethod

from domain.portfolio import Position
from domain.primitives import Money, Symbol


class AccountPort(ABC):

    @abstractmethod
    async def get_balance(self) -> Money:
        """가용 현금 잔고 조회.

        Returns:
            Money: 주문 가능 KRW 잔고
        Raises:
            AuthError, ConnectionError, TimeoutError
        """

    @abstractmethod
    async def get_positions(self) -> list[Position]:
        """전체 보유 포지션 목록 조회.

        Returns:
            list[Position]: 현재 보유 종목별 수량·평단가
        Raises:
            AuthError, ConnectionError, TimeoutError
        """

    @abstractmethod
    async def get_position(self, symbol: Symbol) -> Position | None:
        """특정 종목 포지션 조회.

        Returns:
            Position | None: 보유 중이면 Position, 미보유 시 None
        Raises:
            AuthError, ConnectionError, TimeoutError
        """

    @abstractmethod
    async def reconcile(self) -> dict:
        """내부 DB(positions 테이블)와 브로커 계좌 간 일관성 검증.

        TradingFSM crash recovery 시 호출. 불일치 발견 시 audit 기록.

        Returns:
            dict: {'consistent': bool, 'discrepancies': list[dict]}
        """
```

---

### 3.3 StoragePort

> **역할**: DB 읽기/쓰기 추상화
> **사용 노드**: MarketDataReceiver, StrategyEngine, RiskGuard, OrderExecutor, TradingFSM
> **어댑터**: PostgresStorageAdapter (primary), InMemoryStorageAdapter (테스트)

```python
# ports/storage_port.py
from abc import ABC, abstractmethod
from datetime import date, datetime

from domain.market import OHLCV
from domain.order import TradeRecord
from domain.portfolio import Position, PortfolioSnapshot
from domain.primitives import Money, Symbol


class StoragePort(ABC):

    # ── MarketData ──────────────────────────────────────────────

    @abstractmethod
    async def save_ohlcv(self, bars: list[OHLCV]) -> None:
        """OHLCV 배치 저장 (upsert).

        Raises:
            StorageError
        """

    @abstractmethod
    async def load_ohlcv(
        self,
        symbol: Symbol,
        interval: str,
        start: datetime,
        end: datetime,
    ) -> list[OHLCV]:
        """과거 OHLCV 로드.

        Returns:
            list[OHLCV]: 시간 오름차순
        Raises:
            StorageError
        """

    # ── Portfolio ────────────────────────────────────────────────

    @abstractmethod
    async def load_position(self, symbol: Symbol) -> Position | None:
        """단일 종목 포지션 조회.

        Returns:
            Position | None: 포지션 없으면 None
        """

    @abstractmethod
    async def load_all_positions(self) -> list[Position]:
        """전체 오픈 포지션 조회."""

    @abstractmethod
    async def update_position(self, position: Position) -> None:
        """포지션 저장/업데이트 (upsert by symbol).

        Raises:
            StorageError
        """

    # ── Trade & P&L ──────────────────────────────────────────────

    @abstractmethod
    async def save_trade(self, trade: TradeRecord) -> None:
        """체결 기록 저장.

        Raises:
            StorageError
        """

    @abstractmethod
    async def save_pnl(self, trade_date: date, realized_pnl: Money) -> None:
        """일일 손익 기록 (upsert by trade_date).

        Raises:
            StorageError
        """

    # ── Snapshot ─────────────────────────────────────────────────

    @abstractmethod
    async def load_portfolio_snapshot(self) -> PortfolioSnapshot:
        """전체 포트폴리오 스냅샷 조회 (RiskGuard 전처리용).

        Returns:
            PortfolioSnapshot: 현재 포지션 + 가용 현금 + 오늘 손익
        """
```

---

### 3.4 ClockPort

> **역할**: 시간/스케줄 추상화 (백테스트 시 시간 제어 가능)
> **사용 노드**: RiskGuard (거래시간 체크), TradingFSM (타임아웃)
> **어댑터**: WallClockAdapter (live/paper), HistoricalClockAdapter (backtest)

```python
# ports/clock_port.py
from abc import ABC, abstractmethod
from datetime import datetime


class ClockPort(ABC):

    @abstractmethod
    def now(self) -> datetime:
        """현재 시각 반환 (timezone-aware, KST).

        백테스트 시 재생 시각 반환.
        동기 메서드 — 성능상 async 불필요.
        """

    @abstractmethod
    async def sleep(self, seconds: float) -> None:
        """지정 시간 대기.

        백테스트 시 즉시 반환 (시뮬레이션 시간만 진행).
        Raises:
            asyncio.CancelledError: halt 시그널로 취소될 수 있음
        """

    @abstractmethod
    def is_trading_hours(self) -> bool:
        """현재 시각이 거래시간인지 확인.

        config의 trading_hours_start ~ trading_hours_end 기준.
        동기 메서드.
        """

    @abstractmethod
    def trading_hours_check(self) -> tuple[bool, str]:
        """거래시간 여부 + 사유 반환.

        Returns:
            (True, '') 또는 (False, '장 마감 전' | '장 마감 후' | '주말' | '공휴일')
        """
```

---

### 3.5 StrategyRuntimePort

> **역할**: 전략 파일 로드/실행 추상화
> **사용 노드**: StrategyEngine
> **어댑터**: FileSystemStrategyLoader (primary)

```python
# ports/strategy_runtime_port.py
from abc import ABC, abstractmethod

from domain.market import IndicatorBundle
from domain.portfolio import PortfolioSnapshot
from domain.signal import SignalOutput


class StrategyRuntimePort(ABC):

    @abstractmethod
    async def load(self, strategy_name: str) -> None:
        """전략 파일 로드 및 초기화.

        Args:
            strategy_name: strategies/ 디렉토리 내 파일명 (확장자 제외)
        Raises:
            DataError: 파일 없음 / 구문 오류 / 필수 인터페이스 미구현
        """

    @abstractmethod
    async def evaluate(
        self,
        indicators: IndicatorBundle,
        portfolio: PortfolioSnapshot,
    ) -> SignalOutput | None:
        """전략 실행 — 신호 생성.

        Args:
            indicators: 최신 지표 묶음
            portfolio: 현재 포트폴리오 상태 (포지션 보유 여부 판단용)
        Returns:
            SignalOutput: 신호 있을 때
            None: 신호 없을 때 (관망)
        Raises:
            DataError: 전략 실행 중 예외
        """

    @abstractmethod
    async def list(self) -> list[str]:
        """사용 가능한 전략 목록 반환.

        Returns:
            list[str]: strategies/ 디렉토리 내 .py 파일명 목록 (확장자 제외)
        """
```

---

### 3.6 AuditPort

> **역할**: 감사 로그 저장/조회 추상화
> **사용 노드**: RiskGuard, OrderExecutor, TradingFSM
> **어댑터**: PostgresAuditAdapter (primary), StdoutAuditAdapter (테스트)

```python
# ports/audit_port.py
from abc import ABC, abstractmethod
from datetime import datetime
from uuid import UUID

from domain.primitives import CorrelationId


class AuditPort(ABC):

    @abstractmethod
    async def log(
        self,
        event_type: str,          # 'order_submitted' | 'risk_rejected' | 'fsm_transition' | ...
        severity: str,            # 'info' | 'warning' | 'error' | 'critical'
        source: str,              # 노드명 ('OrderExecutor' | 'RiskGuard' | ...)
        correlation_id: CorrelationId,
        payload: dict,            # JSON-serializable Domain Type 또는 dict
        occurred_at: datetime | None = None,  # None이면 현재 시각
    ) -> None:
        """감사 이벤트 기록.

        append-only. 기록 후 수정/삭제 금지.
        Raises:
            StorageError: DB 기록 실패
        """

    @abstractmethod
    async def query_recent(
        self,
        limit: int = 50,
        severity: str | None = None,   # 필터. None이면 전체
    ) -> list[dict]:
        """최근 이벤트 조회 (atlas audit CLI 용).

        Returns:
            list[dict]: 시간 내림차순 정렬
        """

    @abstractmethod
    async def query_by_correlation(
        self,
        correlation_id: CorrelationId,
    ) -> list[dict]:
        """단일 주문 체인 전체 이벤트 조회.

        Returns:
            list[dict]: 시간 오름차순 정렬 (신호 → 리스크 → 주문 → FSM)
        """
```

---

### 3.7 ExecutionEventPort

> **역할**: 체결 통보 이벤트 구독 (push 수신 전용). ADR-013으로 신설.
> **사용 노드**: ExecutionReceiver
> **어댑터**: MockExecutionEventAdapter (mock), KISPaperExecutionEventAdapter (paper), SyntheticExecutionEventAdapter (synthetic)
> **Phase 1 제약**: `kis_live` 어댑터는 연결 금지

**왜 별도 Port인가**: 주문 요청(pull, OrderPort)과 체결 통보(push, ExecutionEventPort)는 시간 모델이 다르다.
KIS는 체결 통보 전용 WebSocket(H0STCNI0)을 별도 엔드포인트로 제공한다.
ATLAS도 이 구조에 맞춰 요청(OrderExecutor)과 수신(ExecutionReceiver)을 분리한다.

```python
# ports/execution_event_port.py
from abc import ABC, abstractmethod
from typing import Callable, Awaitable

from domain.order import ExecutionEvent


ExecutionHandler = Callable[[ExecutionEvent], Awaitable[None]]


class ExecutionEventPort(ABC):

    @abstractmethod
    async def subscribe(self, handler: ExecutionHandler) -> None:
        """체결 통보 구독.

        증권사가 체결 발생 시 handler를 호출한다.
        Adapter는 내부적으로 WebSocket 연결 + 재연결 + 이벤트 dispatch 담당.

        Raises:
            AuthError: 인증 실패 (KIS approval_key 오류 등)
            ConnectionError: 연결 실패
        """

    @abstractmethod
    async def unsubscribe(self) -> None:
        """구독 해제. 프로세스 shutdown 시 호출.

        진행 중인 이벤트 핸들러는 완료될 때까지 대기.
        """
```

---

## 4. Port → Adapter 매핑 요약

| Port | mock 어댑터 | Phase 1 어댑터 | Phase 2+ |
|------|------------|--------------|---------|
| MarketDataPort | CSVReplayAdapter, SyntheticMarketAdapter | KISWebSocketAdapter + KISRestAdapter | - |
| OrderPort | MockOrderAdapter, SyntheticOrderAdapter | KISPaperOrderAdapter | KISLiveOrderAdapter |
| AccountPort | MockAccountAdapter, SyntheticAccountAdapter | KISPaperAccountAdapter | KISLiveAccountAdapter |
| **ExecutionEventPort** | MockExecutionEventAdapter, SyntheticExecutionEventAdapter | KISPaperExecutionEventAdapter | KISLiveExecutionEventAdapter |
| StoragePort | InMemoryStorageAdapter | PostgresStorageAdapter | - |
| ClockPort | HistoricalClockAdapter | WallClockAdapter | - |
| StrategyRuntimePort | - | FileSystemStrategyLoader | - |
| AuditPort | StdoutAuditAdapter | PostgresAuditAdapter | - |

**전환 방법**: `config.yaml`의 `order.mode` + `account.mode` + `execution_event.mode` 변경 → Adapter 팩토리가 자동 선택.

---

## 5. 파일 구조 예시

```
ports/
├── __init__.py
├── exceptions.py              ← PortError 계층 (섹션 2)
├── market_data_port.py        ← MarketDataPort ABC
├── order_port.py              ← OrderPort ABC      (BrokerPort 분리 결과)
├── account_port.py            ← AccountPort ABC    (BrokerPort 분리 결과)
├── execution_event_port.py    ← ExecutionEventPort ABC (ADR-013 신설)
├── storage_port.py            ← StoragePort ABC
├── clock_port.py              ← ClockPort ABC
├── strategy_runtime_port.py   ← StrategyRuntimePort ABC
└── audit_port.py              ← AuditPort ABC

adapters/
├── market_data/
│   ├── kis_websocket.py       ← KISWebSocketAdapter
│   ├── kis_rest.py            ← KISRestAdapter
│   ├── csv_replay.py          ← CSVReplayAdapter
│   └── synthetic_market.py    ← SyntheticMarketAdapter
├── order/
│   ├── mock_order.py          ← MockOrderAdapter
│   ├── kis_paper_order.py     ← KISPaperOrderAdapter
│   └── synthetic_order.py     ← SyntheticOrderAdapter
├── account/
│   ├── mock_account.py        ← MockAccountAdapter
│   ├── kis_paper_account.py   ← KISPaperAccountAdapter
│   └── synthetic_account.py   ← SyntheticAccountAdapter
├── execution_event/           ← ADR-013 신설
│   ├── mock_execution_event.py       ← MockExecutionEventAdapter
│   ├── kis_paper_execution_event.py  ← KISPaperExecutionEventAdapter (H0STCNI0)
│   └── synthetic_execution_event.py  ← SyntheticExecutionEventAdapter
├── storage/
│   ├── postgres_storage.py    ← PostgresStorageAdapter
│   └── in_memory_storage.py   ← InMemoryStorageAdapter
├── clock/
│   ├── wall_clock.py          ← WallClockAdapter
│   └── historical_clock.py    ← HistoricalClockAdapter
├── strategy/
│   └── filesystem_loader.py   ← FileSystemStrategyLoader
└── audit/
    ├── postgres_audit.py      ← PostgresAuditAdapter
    └── stdout_audit.py        ← StdoutAuditAdapter
```

---

## 6. 변경 이력

| 날짜 | 버전 | 변경 |
|------|------|------|
| 2026-04-17 | v1.0 | Phase 1 최초 작성. 6개 Port ABC + PortError 계층 통합. |
| 2026-04-17 | v1.1 | BrokerPort 분리 → OrderPort + AccountPort. 단일 책임 원칙 적용. KIS API 구조(주문 API와 계좌 API 분리)와 정합. 7개 Port·31 메서드. |
| 2026-04-17 | v1.2 | ExecutionEventPort 신설 (ADR-013). OrderExecutor의 체결 통보 수신 책임을 ExecutionReceiver로 분해. KIS H0STCNI0 WebSocket을 별도 Port로 명시. 8개 Port·33 메서드. |

---

*Phase 1 Port ABC 통합 시그니처 — 8 Ports | 33 메서드 | 1 예외 계층*
