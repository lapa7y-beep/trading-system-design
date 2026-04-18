# Phase 1 Adapter 구현 명세 (19 Adapter·실패처리·전환규칙)

> **목적**: Phase 1에서 구현할 19개 Adapter의 내부 동작, 의존성, 실패 처리, 전환 규칙을 단일 문서로 정의.
> **층**: What
> **상태**: Phase 1 확정 (ADR-013: ExecutionEventPort 신설 반영)
> **최종 수정**: 2026-04-17
> **구현 여정**: Step 02(Port+DI), 03(CSVReplay), 07(MockOrder/Account/ExecEvent), 09(Postgres), 11b(KISPaper)에서 참조. ADR-012 §6, ADR-013 참조.
> **선행 문서**: `docs/what/specs/port-signatures-phase1.md`, `docs/what/specs/config-schema-phase1.md`, `graph_ir_phase1.yaml`, `docs/what/decisions/013-atlas-driver-broker-boundary.md`
> **구현 위치**: `adapters/*/`

## 1. Adapter 설계 원칙

1. **단일 Port 구현** — 하나의 Adapter는 반드시 하나의 Port ABC를 상속.
2. **상태 최소화** — 가능하면 stateless. 상태는 `__init__` 주입과 내부 연결 핸들로만.
3. **예외 변환** — 내부 예외(httpx, asyncpg 등)는 반드시 `PortError` 하위로 변환 후 raise.
4. **로깅 분리** — `logging.getLogger(__name__)` 사용. AuditPort와 다름 (감사=도메인, 로깅=기술).
5. **설정 주입** — config는 `__init__`에서 받음. 모듈 전역 접근 금지.
6. **타임아웃 필수** — 외부 호출은 모두 `asyncio.wait_for`로 래핑. config의 `*_timeout_seconds` 사용.
7. **재시도 정책 명시** — 자체 재시도 있으면 지수 백오프, 없으면 호출자가 처리.

---

## 2. Adapter 전체 목록 (19개)

| # | Port | Adapter | 모드 | 외부 의존 |
|---|------|---------|------|----------|
| 1 | MarketDataPort | **KISWebSocketAdapter** | ws | KIS WS API, `websockets` |
| 2 | MarketDataPort | **KISRestAdapter** | poll | KIS REST API, `httpx` |
| 3 | MarketDataPort | **CSVReplayAdapter** | csv_replay | 파일시스템, `pandas` |
| 4 | MarketDataPort | **SyntheticMarketAdapter** | synthetic | 없음 (in-process, ExchangeEngine) |
| 5 | OrderPort | **MockOrderAdapter** | mock | 없음 (in-process) |
| 6 | OrderPort | **KISPaperOrderAdapter** | paper | KIS REST API, `httpx` |
| 7 | OrderPort | **SyntheticOrderAdapter** | synthetic | 없음 (in-process, ExchangeEngine) |
| 8 | AccountPort | **MockAccountAdapter** | mock | 없음 (MockOrder와 in-process 상태 공유) |
| 9 | AccountPort | **KISPaperAccountAdapter** | paper | KIS REST API, `httpx` |
| 10 | AccountPort | **SyntheticAccountAdapter** | synthetic | 없음 (ExchangeEngine 공유) |
| 11 | ExecutionEventPort | **MockExecutionEventAdapter** | mock | 없음 (MockOrder 체결 in-process emit) |
| 12 | ExecutionEventPort | **KISPaperExecutionEventAdapter** | paper | KIS WebSocket (H0STCNI0), `websockets` |
| 13 | ExecutionEventPort | **SyntheticExecutionEventAdapter** | synthetic | 없음 (ExchangeEngine 체결 event) |
| 14 | StoragePort | **PostgresStorageAdapter** | primary | PostgreSQL, `asyncpg` |
| 15 | StoragePort | **InMemoryStorageAdapter** | test | 없음 |
| 16 | ClockPort | **WallClockAdapter** | live/paper | OS 시계 |
| 17 | ClockPort | **HistoricalClockAdapter** | backtest | 없음 (내부 시뮬 시계) |
| 18 | StrategyRuntimePort | **FileSystemStrategyLoader** | primary | 파일시스템, `importlib` |
| 19 | AuditPort | **PostgresAuditAdapter** | primary | PostgreSQL, `asyncpg` |
| 20 | AuditPort | **StdoutAuditAdapter** | test | 없음 |

> **참고**: 표는 20행이지만 **Adapter 종류는 19개**. Phase 2 예약: `KISLiveOrderAdapter` + `KISLiveAccountAdapter` + `KISLiveExecutionEventAdapter` 3개 별도.

---

## 3. Adapter 선택 규칙 (Factory)

`order.mode` + `account.mode` + `market_data.mode` 3개 키로 어댑터 세트 결정.
**원칙**: 같은 증권사로 통일이 기본이지만, **Port가 분리되어 있으므로 혼합 사용 가능**.

| order.mode | account.mode | market_data.mode | 선택되는 어댑터 세트 | 용도 |
|------------|--------------|------------------|---------------------|------|
| mock | mock | csv_replay | MockOrder + MockAccount + CSVReplay + InMemory + HistoricalClock + StdoutAudit | 백테스트 (CSV 데이터) |
| mock | mock | ws | MockOrder + MockAccount + KISWS + Postgres + WallClock + PostgresAudit | 실시세 + 가짜주문 |
| paper | paper | ws | KISPaperOrder + KISPaperAccount + KISWS + Postgres + WallClock + PostgresAudit | 모의투자 (KIS) |
| synthetic | synthetic | synthetic | SyntheticOrder + SyntheticAccount + SyntheticMarket + InMemory + HistoricalClock + StdoutAudit | 가상거래소 |
| paper | paper | synthetic | KISPaperOrder + KISPaperAccount + SyntheticMarket + Postgres + WallClock + PostgresAudit | KIS 주문 + 가상시세 |

> **Phase 1 기본 경로 3개**
> - **백테스트**: `mock + mock + csv_replay` (InMemory, HistoricalClock)
> - **모의투자**: `paper + paper + ws` (Postgres 영속, WallClock)
> - **가상검증**: `synthetic + synthetic + synthetic` (Monte Carlo)

> **혼합 사용 제약**: SyntheticOrder를 사용하면 SyntheticAccount도 사용해야 한다 (ExchangeEngine 상태 공유 필요).
> 마찬가지로 MockOrder + MockAccount는 항상 쌍으로 사용 (in-process 상태 공유).

---

## 4. MarketDataPort 어댑터 (4개)

### 4.1 KISWebSocketAdapter

**역할**: KIS WebSocket으로 실시간 체결가 수신.

**핵심 동작**
- 최초 `subscribe` 호출 시 KIS 인증 → WS 연결 → H0STCNT0 (실시간 체결가) 구독
- `unsubscribe`: WS 구독 해제 메시지 전송 → `_subscribed_symbols`에서 제거. 남은 구독 0이면 WS 연결 close.
- `stream()` 은 내부 asyncio.Queue에서 Quote를 pop하여 yield
- `get_current_price`: `_queue`의 최신 Quote를 반환 (WS 미연결 시 `ConnectionError`)
- `get_historical`: WS에서는 미지원. KISRestAdapter에 위임 (Adapter Factory가 두 어댑터를 조합)
- WS 수신 루프는 별도 task로 구동

**의존성**
```python
import websockets
import httpx                         # 토큰 발급
from tenacity import retry, ...      # 재시도
```

**config 사용 키**
- `broker.kis.app_key / app_secret` (WS 인증 토큰 발급용)
- `market_data.ws_reconnect_max`
- `market_data.ws_reconnect_interval_seconds`
- `market_data.stale_tick_warn_seconds`

**실패 처리**
| 상황 | 동작 |
|------|------|
| 최초 인증 실패 | `AuthError` raise. 기동 중단. |
| WS 연결 끊김 | `ws_reconnect_interval_seconds` 대기 후 재연결. 최대 `ws_reconnect_max` 회. |
| 연속 재연결 실패 | `ConnectionError` raise → 상위(MarketDataReceiver)가 poll로 전환 |
| `stale_tick_warn_seconds` 동안 틱 없음 | WARN 로깅만. 에러 아님 |

**상태**
- `_ws: websockets.ClientConnection | None`
- `_token: str | None` (24시간 유효)
- `_queue: asyncio.Queue[Quote]`
- `_subscribed_symbols: set[Symbol]`

---

### 4.2 KISRestAdapter

**역할**: WS 장애 시 fallback. REST polling으로 현재가 수집.
과거 OHLCV 조회(`get_historical`)는 이 어댑터가 **항상** 담당.

**핵심 동작**
- `subscribe` 시 내부 polling task 시작. `poll_interval_seconds`마다 `/uapi/domestic-stock/v1/quotations/inquire-price` 호출
- `unsubscribe`: polling task 취소 → `_subscribed_symbols`에서 제거
- `stream()` 은 WebSocketAdapter와 동일한 인터페이스 (asyncio.Queue)
- `get_current_price`: 마지막 polling 결과의 Quote 반환 (polling 미시작 시 즉시 1회 REST 호출)
- `get_historical` 은 `/uapi/domestic-stock/v1/quotations/inquire-daily-itemchartprice` 호출

**의존성**
```python
import httpx
```

**config 사용 키**
- `broker.kis.app_key / app_secret / base_url`
- `market_data.poll_interval_seconds`
- `market_data.poll_reconnect_check_seconds` (WS 복구 시도 주기)

**실패 처리**
| 상황 | 동작 |
|------|------|
| HTTP 4xx (인증 오류) | `AuthError` raise |
| HTTP 5xx / 타임아웃 | 지수 백오프 재시도 3회, 실패 시 `ConnectionError` raise |
| KIS API Rate Limit | 응답 헤더 확인 후 자동 대기 (KIS: 초당 20회 제한) |

---

### 4.3 CSVReplayAdapter

**역할**: 백테스트용. CSV 파일을 Quote 스트림으로 재생.

**핵심 동작**
- `__init__`에서 `csv_replay.data_dir` 내 파일 목록 스캔
- `subscribe` 시 지정 종목 CSV 로드 → 시간순 정렬 → 내부 큐 적재
- `unsubscribe`: 해당 종목의 내부 큐 비우기 + `_subscribed_symbols`에서 제거
- `stream()` 은 `speed_multiplier` 비율로 Quote를 yield. `1.0` = 실시간, `0` = 즉시

**CSV 포맷**
```csv
ts,symbol,price,volume,bid_price,ask_price
2024-01-02 09:00:01,005930,72100,100,72050,72100
2024-01-02 09:00:02,005930,72150,50,72100,72150
...
```

**의존성**
```python
import pandas as pd
from datetime import datetime
```

**config 사용 키**
- `market_data.csv_replay.data_dir`
- `market_data.csv_replay.speed_multiplier`

**실패 처리**
| 상황 | 동작 |
|------|------|
| 파일 없음 | `DataError` raise |
| CSV 포맷 오류 | `DataError` raise |
| 구독 종목 CSV 없음 | `DataError` raise |

**주의**: `get_historical`은 CSV 전체 반환. `get_current_price`는 마지막 재생 시점의 Quote 반환.

---

### 4.4 SyntheticMarketAdapter

**역할**: 가상거래소(ExchangeEngine) 기반 시세 생성. 실제 데이터 없이 파이프라인 전체 검증.
상세 설계: `docs/what/specs/synthetic-exchange-phase1.md`

**핵심 동작**
- `subscribe`: ExchangeEngine 초기화. 종목별 GBM 시작가 설정.
- `stream()`: HistoricalClockAdapter가 tick 단위로 시간을 진행할 때마다 ExchangeEngine.advance_to(ts) 호출 → Quote 생성하여 yield.
- `get_current_price`: 현재 SymbolState.last_price 반환.
- `get_historical`: 빈 리스트 반환 (가상거래소는 과거 없음).

**의존성**
```python
import numpy as np
from atlas.exchange.engine import ExchangeEngine   # 내부 모듈
```

**config 사용 키**
- `synthetic.seed`
- `synthetic.price_model.*`
- `synthetic.initial_prices`
- `synthetic.market_rules.*`
- `synthetic.scenarios`

**실패 처리**
| 상황 | 동작 |
|------|------|
| 미구독 종목 시세 요청 | `DataError` raise |
| ExchangeEngine 미초기화 | `ConnectionError` raise |

**주의**: SyntheticOrderAdapter, SyntheticAccountAdapter와 **동일한 ExchangeEngine 인스턴스를 공유**해야 한다.
반드시 쌍으로 사용 (`market_data.mode: synthetic` + `order.mode: synthetic` + `account.mode: synthetic`).

---

## 5. OrderPort 어댑터 (3개)

### 5.1 MockOrderAdapter

**역할**: 백테스트용 주문 처리. 주문을 메모리에서만 처리. 슬리피지·수수료 반영. **MockAccountAdapter와 in-process 상태 공유**.

**핵심 동작**
- `submit` 호출 시 즉시 `OrderResult(status=FILLED)` 반환 (시장가) 또는 가격 조건 검사 후 체결 (지정가)
- `cancel`: `_orders` 딕셔너리에서 해당 UUID 조회 → 이미 FILLED면 `BrokerRejectError`, 아니면 CANCELLED 반환
- `get_order_status`: `_orders[order_uuid]` 조회 → 없으면 `DataError`
- 체결가는 현재 시세(ClockPort.now 기준 CSV 재생 시점의 마지막 Quote) 기반
- 슬리피지: `price ± slippage_ticks * tick_size`
- 수수료: 매수=0.015%, 매도=0.015% + 거래세 0.18% + 농특세 0.15%
- **계좌 변경**: 체결 시 `_shared_account_state`(MockAccountAdapter와 공유)의 cash/positions 갱신

**의존성**
```python
from collections import defaultdict
from atlas.adapters.account.mock_account import MockAccountState   # 공유 상태
```

**config 사용 키**
- `backtest.slippage_ticks` (기본 1)
- `backtest.fee_rate` (기본 0.00015)
- `backtest.transaction_tax_rate` (기본 0.0018)
- `backtest.special_tax_rate` (기본 0.0015)

**상태**
- `_orders: dict[UUID, OrderResult]` — 멱등성 보장용
- `_last_quote_by_symbol: dict[Symbol, Quote]` — 체결가 계산용 (MarketDataPort와 연동)
- `_shared_state: MockAccountState` — MockAccountAdapter와 공유 (cash, positions)

**실패 처리**
| 상황 | 동작 |
|------|------|
| 잔고 부족 | `BrokerRejectError(code='INSUFFICIENT_CASH')` raise |
| 동일 `order_uuid` 재제출 | 기존 `OrderResult` 반환 (멱등성) |
| 시세 없음 (Quote 캐시 비어있음) | `DataError` raise |

---

### 5.2 KISPaperOrderAdapter

**역할**: KIS 모의투자 계좌로 주문 제출. **계좌 조회는 KISPaperAccountAdapter가 담당**.

**핵심 동작**
- `submit`: POST `/uapi/domestic-stock/v1/trading/order-cash` 호출
- `cancel`: POST `/uapi/domestic-stock/v1/trading/order-rvsecncl`
- `get_order_status`: GET `/uapi/domestic-stock/v1/trading/inquire-psbl-order`
- 멱등성: `order_uuid`를 KIS 주문 시 `ORD_DVSN_CD` 확장 필드에 포함. 이미 제출된 UUID면 기존 결과 반환.

**의존성**
```python
import httpx
```

**config 사용 키**
- `broker.kis.app_key / app_secret / account_no / base_url`
- `order_executor.submit_timeout_seconds`

**실패 처리**
| 상황 | 동작 |
|------|------|
| HTTP 4xx (인증) | `AuthError` raise |
| KIS 응답 `rt_cd != '0'` | `BrokerRejectError(code=rt_cd, message=msg1)` raise |
| 타임아웃 | `TimeoutError` raise |
| 중복 `order_uuid` | 내부 캐시에서 기존 결과 반환 |

**주의**: KIS API는 계좌 구분 코드(`CANO`, `ACNT_PRDT_CD`)가 필수. `account_no` 형식 `"50123456-01"`에서 `-` 기준으로 분리. 같은 KIS config를 KISPaperAccountAdapter와 공유한다.

---

### 5.3 SyntheticOrderAdapter

**역할**: 가상거래소(ExchangeEngine) 기반 주문 체결. 호가창 매칭, 수수료·세금·슬리피지 반영. **SyntheticAccountAdapter와 ExchangeEngine 공유**.
상세 설계: `docs/what/specs/synthetic-exchange-phase1.md`

**핵심 동작**
- `submit`: ExchangeEngine.submit_order() 호출. 호가창 등록 후 즉시 매칭 시도. 체결 시 ExchangeEngine 내부 cash/positions 갱신.
- `cancel`: OrderBook에서 해당 UUID 주문 취소.
- `get_order_status`: 내부 fills 캐시 조회.

**의존성**
```python
from atlas.exchange.engine import ExchangeEngine   # 내부 모듈 (SyntheticMarket/Account와 공유)
```

**config 사용 키**
- `synthetic.initial_cash` (기본 100_000_000)
- `backtest.slippage_ticks` (기본 1)
- `backtest.fee_rate` (기본 0.00015)
- `backtest.transaction_tax_rate` (기본 0.0018)
- `backtest.special_tax_rate` (기본 0.0015)

**상태**
- `_fills: dict[UUID, OrderResult]` — 멱등성 보장용 캐시
- 잔고/포지션은 ExchangeEngine 내부에 위치 (SyntheticAccountAdapter가 조회)

**실패 처리**
| 상황 | 동작 |
|------|------|
| 잔고 부족 | `BrokerRejectError(code='INSUFFICIENT_CASH')` raise |
| 상하한가 위반 | `BrokerRejectError(code='PRICE_LIMIT')` raise |
| VI 중 주문 | `BrokerRejectError(code='VI_TRIGGERED')` raise |
| 동일 UUID 재제출 | 기존 OrderResult 반환 (멱등성) |
| 10초 타임아웃 | `OrderResult(status=EXPIRED)` 반환 |

**주의**: SyntheticMarketAdapter, SyntheticAccountAdapter와 **동일한 ExchangeEngine 인스턴스 공유 필수**.
AdapterFactory에서 ExchangeEngine을 먼저 생성한 뒤 세 Adapter에 주입한다.

---

## 5b. AccountPort 어댑터 (3개)

### 5b.1 MockAccountAdapter

**역할**: 백테스트용 계좌 조회. **MockOrderAdapter와 in-process 상태 공유**.

**핵심 동작**
- `get_balance`: `_shared_state.cash` 반환
- `get_positions`: `_shared_state.positions` 전체 목록 반환
- `get_position(symbol)`: `_shared_state.positions.get(symbol)` 반환
- `reconcile`: in-process이므로 항상 일관 → `{'consistent': True, 'discrepancies': []}` 반환

**의존성**
```python
from atlas.adapters.account.mock_account import MockAccountState   # 공유 상태 정의
```

**config 사용 키**
- `backtest.initial_cash` (기본 100_000_000) — 부팅 시 _shared_state.cash 초기화

**상태**
- `_shared_state: MockAccountState` — MockOrderAdapter와 공유
  - `cash: Money`
  - `positions: dict[Symbol, Position]`

**실패 처리**
| 상황 | 동작 |
|------|------|
| 미존재 종목 조회 | `None` 반환 (예외 아님) |

---

### 5b.2 KISPaperAccountAdapter

**역할**: KIS 모의투자 계좌의 잔고·포지션 조회 및 일관성 검증.

**핵심 동작**
- `get_balance`: GET `/uapi/domestic-stock/v1/trading/inquire-balance` → `dnca_tot_amt` (예수금)
- `get_positions`: GET `/uapi/domestic-stock/v1/trading/inquire-balance` → `output1[]` 파싱하여 Position 리스트로 변환
- `get_position(symbol)`: get_positions 후 필터링 (KIS는 단일 종목 조회 API 없음)
- `reconcile`: StoragePort.load_all_positions() 결과와 KIS 응답 비교, 불일치 종목/수량 list 반환

**의존성**
```python
import httpx
from atlas.ports.storage_port import StoragePort   # reconcile 시 내부 DB 조회
```

**config 사용 키**
- `broker.kis.app_key / app_secret / account_no / base_url` (KISPaperOrderAdapter와 동일 키 공유)
- `account.reconcile_interval_seconds` (기본 10)

**실패 처리**
| 상황 | 동작 |
|------|------|
| HTTP 4xx (인증) | `AuthError` raise |
| KIS 응답 `rt_cd != '0'` | `DataError(code=rt_cd, message=msg1)` raise |
| 타임아웃 | `TimeoutError` raise |
| reconcile 불일치 | 정상 반환 (`consistent: False`), audit 기록은 호출자(TradingFSM)가 결정 |

**주의**: 같은 KIS HTTP 세션을 KISPaperOrderAdapter와 **공유 가능** (커넥션 풀 효율).
다만 인증 토큰은 두 어댑터 모두 갱신 시점이 다를 수 있으므로 토큰 매니저는 별도 모듈로 분리 권장.

---

### 5b.3 SyntheticAccountAdapter

**역할**: 가상거래소(ExchangeEngine) 내부 계좌 상태 조회. **SyntheticOrderAdapter와 ExchangeEngine 공유**.

**핵심 동작**
- `get_balance`: `_engine.get_cash()` 반환
- `get_positions`: `_engine.get_all_positions()` 반환
- `get_position(symbol)`: `_engine.get_position(symbol)` 반환
- `reconcile`: in-process이므로 항상 일관 → `{'consistent': True, 'discrepancies': []}` 반환

**의존성**
```python
from atlas.exchange.engine import ExchangeEngine
```

**config 사용 키**
- `synthetic.initial_cash` (ExchangeEngine 초기화 시 사용, AccountAdapter는 직접 사용 안 함)

**상태**
- `_engine: ExchangeEngine` — SyntheticOrder/SyntheticMarket과 공유

**실패 처리**
| 상황 | 동작 |
|------|------|
| 미존재 종목 조회 | `None` 반환 (예외 아님) |
| ExchangeEngine 미초기화 | `ConnectionError` raise |

**주의**: ExchangeEngine 인스턴스가 SyntheticOrder/Market과 **반드시 동일**해야 한다. AdapterFactory가 보장.

---

## 5c. ExecutionEventPort 어댑터 (3개) — ADR-013 신설

> **사용 노드**: ExecutionReceiver (체결 통보 push 구독 전용)
> **ADR**: 013-atlas-driver-broker-boundary
> **역할**: 체결 이벤트를 ExecutionReceiver에 전달. ExecutionReceiver는 trades INSERT + PortfolioStore 갱신 + TradingFSM emit.

### 5c.1 MockExecutionEventAdapter

**역할**: 백테스트·단위 테스트용. MockOrderAdapter가 체결 처리할 때 in-process 이벤트 emit.

**핵심 동작**
- `subscribe(handler)`: handler를 내부 리스트에 등록
- `unsubscribe()`: 등록 해제
- MockOrderAdapter가 OrderStatus.FILLED 생성 시 `_shared_event_bus.emit(execution_event)` → 등록된 handler 호출
- **공유 이벤트 버스**: MockOrderAdapter와 MockExecutionEventAdapter가 같은 `MockEventBus` 인스턴스 공유

**의존성**
```python
from atlas.adapters.execution_event.mock_execution_event import MockEventBus
```

**config 사용 키**
- 없음

**상태**
- `_handlers: list[ExecutionHandler]` — 등록된 handler 목록
- `_bus: MockEventBus` — MockOrderAdapter와 공유

**실패 처리**
| 상황 | 동작 |
|------|------|
| handler가 예외 발생 | 로깅만, 이벤트 버스 정상 유지 |
| 등록 전 이벤트 수신 | 버퍼링 안 함 (드롭) |

---

### 5c.2 KISPaperExecutionEventAdapter

**역할**: KIS 모의투자 체결 통보 WebSocket(H0STCNI0) 구독. 실제 체결 통보를 받아 ATLAS로 전달.

**핵심 동작**
- `subscribe(handler)`:
  1. KIS approval_key 발급 (`POST /oauth2/Approval`)
  2. WebSocket 연결 (`wss://openapivts.koreainvestment.com:29443`)
  3. TR 등록 메시지 전송 (tr_id=`H0STCNI0`, tr_key=HTS ID)
  4. 백그라운드 task: 수신 루프 → 파싱 → ExecutionEvent 생성 → handler 호출
- `unsubscribe()`: WebSocket close, task cancel
- 재연결: 끊김 시 지수 백오프 (1s, 2s, 4s, ... max 60s)
- 멱등성: execution_uuid 기준 중복 이벤트 무시 (KIS가 중복 전송하는 경우 대비)

**의존성**
```python
import websockets
import httpx  # approval_key 발급용
```

**config 사용 키**
- `broker.kis.app_key / app_secret / hts_id / ws_url`
- `execution_event.reconnect_max_seconds` (기본 60)

**상태**
- `_ws: websockets.WebSocketClientProtocol | None`
- `_task: asyncio.Task | None`
- `_seen_uuids: LRUCache[UUID]` — 중복 제거용 (최근 1000개)

**실패 처리**
| 상황 | 동작 |
|------|------|
| approval_key 발급 실패 | `AuthError` raise |
| WebSocket 연결 실패 | `ConnectionError` raise, 호출자가 재시도 결정 |
| 파싱 실패 | 로깅만, 다음 메시지 진행 |
| 중복 execution_uuid | 무시 (audit에 기록) |
| 5초 무응답 | heartbeat ping, 10초 무응답 시 재연결 |

**주의**: KIS `H0STCNI0`은 체결 + 접수 + 거부 모두 포함. adapter 내부에서 체결(execution)만 필터링하여 handler 호출. 접수·거부는 OrderPort 응답으로 처리.

---

### 5c.3 SyntheticExecutionEventAdapter

**역할**: 가상거래소(ExchangeEngine) 체결 결과를 이벤트로 emit. SyntheticOrderAdapter와 같은 ExchangeEngine 공유.

**핵심 동작**
- `subscribe(handler)`: ExchangeEngine에 체결 콜백 등록
- `unsubscribe()`: 콜백 해제
- ExchangeEngine 내부 매칭 엔진이 체결 발생 시 → ExecutionEvent 생성 → handler 호출

**의존성**
```python
from atlas.exchange.engine import ExchangeEngine
```

**config 사용 키**
- 없음 (ExchangeEngine이 모든 설정 소유)

**상태**
- `_engine: ExchangeEngine` — SyntheticOrder/Market/Account와 공유

**실패 처리**
| 상황 | 동작 |
|------|------|
| handler 예외 | 로깅만, ExchangeEngine 정상 유지 |
| ExchangeEngine 미초기화 | `ConnectionError` raise |

**주의**: ExchangeEngine의 `register_fill_callback()`에 등록. ExchangeEngine은 매칭 직후 callback을 동기 호출 (asyncio.create_task로 비동기 전환).

---

## 6. StoragePort 어댑터 (2개)

### 6.1 PostgresStorageAdapter

**역할**: PostgreSQL + TimescaleDB로 영속 저장.

**핵심 동작**
- `__init__`에서 `asyncpg.create_pool(database.url, min_size=1, max_size=pool_size)`
- 모든 쿼리는 `async with pool.acquire() as conn:` 패턴
- `save_ohlcv`: `INSERT ... ON CONFLICT (symbol, ts) DO UPDATE` (upsert)
- `load_ohlcv`: `SELECT ... WHERE symbol=$1 AND interval=$2 AND ts BETWEEN $3 AND $4 ORDER BY ts ASC`
- `load_position`: `SELECT ... FROM positions WHERE symbol = $1` (없으면 None)
- `load_all_positions`: `SELECT ... FROM positions` (전체 오픈 포지션)
- `update_position`: 트랜잭션 내에서 `UPDATE positions ... WHERE symbol = $1` (없으면 INSERT)
- `load_portfolio_snapshot`: 단일 쿼리로 positions + daily_pnl + cash 조인

**의존성**
```python
import asyncpg
from decimal import Decimal
```

**config 사용 키**
- `database.url`
- `database.pool_size`
- `database.pool_timeout_seconds`

**실패 처리**
| 상황 | 동작 |
|------|------|
| 연결 실패 (기동 시) | `ConnectionError` raise → 기동 중단 |
| 쿼리 타임아웃 | `TimeoutError` raise |
| `UNIQUE` 위반 | 로깅 후 `StorageError` raise (상위가 멱등성 처리) |
| 일시 연결 끊김 | `asyncpg` 풀이 자동 재연결. 첫 재시도만 수행 후 실패 시 `StorageError` |

**트랜잭션 경계**
- `TradingFSM.state_transition` → `update_position` 은 **반드시 단일 트랜잭션** (상태-계좌 일관성 Safeguard)
- `save_trade` + `save_pnl` 은 별도 트랜잭션 (손익 집계 실패가 체결 기록을 막으면 안 됨)

---

### 6.2 InMemoryStorageAdapter

**역할**: 백테스트 및 단위 테스트용. 메모리 딕셔너리로 전체 대체.

**핵심 동작**
- StoragePort ABC의 8개 메서드 전부 구현. 모든 테이블을 `dict` 또는 `list`로 보관.
- `save_ohlcv`: `_ohlcv[(symbol, interval, ts)]`에 upsert
- `load_ohlcv / load_position / load_all_positions`: 딕셔너리 조회
- `update_position / save_trade / save_pnl`: 딕셔너리 upsert 또는 list append
- `load_portfolio_snapshot`: `_positions` + `_daily_pnl` 합산
- 트랜잭션 의사 구현: `async with self._lock:` (asyncio.Lock)

**상태**
```python
_ohlcv: dict[tuple[Symbol, str, datetime], OHLCV]
_positions: dict[Symbol, Position]
_trades: list[TradeRecord]
_daily_pnl: dict[date, Money]
_lock: asyncio.Lock
```

**실패 처리**: 거의 없음. 로직 버그만 raise.

---

## 7. ClockPort 어댑터 (2개)

### 7.1 WallClockAdapter

**역할**: 실제 OS 시계 사용.

**핵심 동작**
- `now()`: `datetime.now(ZoneInfo('Asia/Seoul'))`
- `sleep(s)`: `await asyncio.sleep(s)`
- `is_trading_hours()`: config의 `trading_hours_start ~ end`와 현재 시각 비교
- `trading_hours_check()`: 시간 외 사유를 문자열로 반환 ('장 마감 전', '주말', '공휴일')

**의존성**
```python
from datetime import datetime, time
from zoneinfo import ZoneInfo
import asyncio
import holidays    # 한국 공휴일
```

**config 사용 키**
- `risk.trading_hours_start / end`
- `scheduler.timezone` (기본 `Asia/Seoul`)

---

### 7.2 HistoricalClockAdapter

**역할**: 백테스트용. 내부 시뮬 시계를 갖고 `now()`가 시뮬 시각 반환.

**핵심 동작**
- `__init__`에서 시작 시각 주입
- `advance_to(ts)` 메서드로 외부(CSVReplayAdapter)가 시뮬 시각 진행
- `now()`: `_current` 반환 (시뮬 시각)
- `sleep(s)` 은 즉시 반환 (시뮬 시각만 `_current += s`)
- `is_trading_hours`: 시뮬 시각 기준으로 판단
- `trading_hours_check`: `is_trading_hours` + 사유 문자열 반환 (WallClockAdapter와 동일 로직, 시뮬 시각 기준)

**상태**
- `_current: datetime` — 시뮬 현재 시각
- `_advance_callback: list[Callable]` — 시각 변경 시 호출할 훅

**주의**: `WallClockAdapter`와 동일 인터페이스. 차이는 내부 시계 소스.

---

## 8. StrategyRuntimePort 어댑터 (1개)

### 8.1 FileSystemStrategyLoader

**역할**: `strategies/*.py` 파일을 동적 임포트하여 실행.

**핵심 동작**
- `load(name)`: `importlib.import_module(f'strategies.{name}')` → 모듈에 `Strategy` 클래스 존재 확인 → 인스턴스화
- `evaluate(indicators, portfolio)`: `self._strategy.evaluate(indicators, portfolio)` 호출 → `SignalOutput | None` 반환
- `list()`: `strategies/` 디렉토리 스캔, `.py` 파일명 (확장자 제외) 목록 반환

**전략 파일 계약**
```python
# strategies/ma_crossover.py
from domain.market import IndicatorBundle
from domain.portfolio import PortfolioSnapshot
from domain.signal import SignalOutput

class Strategy:
    NAME = "ma_crossover"
    VERSION = "1.0"

    def __init__(self, config: dict): ...

    def evaluate(
        self,
        indicators: IndicatorBundle,
        portfolio: PortfolioSnapshot,
    ) -> SignalOutput | None:
        ...
```

**의존성**
```python
import importlib
import inspect
```

**config 사용 키**
- `strategy.directory`
- `strategy.active`
- `strategy.hot_reload` (Phase 1=false)

**실패 처리**
| 상황 | 동작 |
|------|------|
| 파일 없음 | `DataError` raise |
| `Strategy` 클래스 미정의 | `DataError` raise |
| `evaluate` 시그니처 불일치 | `DataError` raise |
| 전략 실행 중 예외 | `DataError` raise (상위 StrategyEngine이 AuditPort로 기록) |

**hot_reload=true 시**: `importlib.reload` 사용. Phase 1은 미지원.

---

## 9. AuditPort 어댑터 (2개)

### 9.1 PostgresAuditAdapter

**역할**: `audit_events` 테이블에 append-only 기록.

**핵심 동작**
- `log()`: `INSERT INTO audit_events (...) VALUES (...)`. 트리거로 `UPDATE/DELETE` 차단됨 (DB 스키마에서).
- `payload`는 pydantic 모델 → `model_dump(mode='json')` → JSONB 저장
- `query_recent`: `SELECT ... ORDER BY occurred_at DESC LIMIT $1`
- `query_by_correlation`: `SELECT ... WHERE correlation_id = $1 ORDER BY occurred_at ASC`

**의존성**
```python
import asyncpg
import json
```

**config 사용 키**
- `database.url` (StoragePort와 동일 풀 공유 가능)

**실패 처리**
| 상황 | 동작 |
|------|------|
| DB 쓰기 실패 | 로컬 파일 `logs/audit_fallback.jsonl`에 append → `StorageError` raise → 상위가 SAFE_MODE 진입 |
| 직렬화 실패 | `DataError` raise (payload 버그) |

**주의**: 감사 로그 실패는 시스템의 **신뢰성 자체**를 무너뜨리므로, 로컬 fallback은 필수.

---

### 9.2 StdoutAuditAdapter

**역할**: 테스트/백테스트용. stdout에 JSON 라인으로 출력.

**핵심 동작**
- `log()`: `print(json.dumps({...}))` 한 줄 출력
- `query_recent / query_by_correlation`: 내부 리스트에서 필터링

**상태**
- `_events: list[dict]` — 프로세스 메모리에만 보관

---

## 10. Adapter 팩토리

```python
# adapters/factory.py

def create_order_port(config: Config, exchange: ExchangeEngine | None = None) -> OrderPort:
    if config.order.mode == OrderMode.MOCK:
        return MockOrderAdapter(config.backtest, MockAccountState.shared())
    elif config.order.mode == OrderMode.KIS_PAPER:
        return KISPaperOrderAdapter(config.broker.kis, config.order_executor)
    elif config.order.mode == OrderMode.SYNTHETIC:
        if exchange is None:
            raise ValueError("synthetic 모드는 ExchangeEngine 주입 필요")
        return SyntheticOrderAdapter(exchange, config.synthetic, config.backtest)
    elif config.order.mode == OrderMode.KIS_LIVE:
        raise ValueError("kis_live 는 Phase 2D 까지 사용 금지")
    else:
        raise ValueError(f"Unknown order.mode: {config.order.mode}")


def create_account_port(config: Config, exchange: ExchangeEngine | None = None) -> AccountPort:
    if config.account.mode == AccountMode.MOCK:
        return MockAccountAdapter(MockAccountState.shared(), config.backtest.initial_cash)
    elif config.account.mode == AccountMode.KIS_PAPER:
        return KISPaperAccountAdapter(config.broker.kis, config.account.reconcile_interval_seconds)
    elif config.account.mode == AccountMode.SYNTHETIC:
        if exchange is None:
            raise ValueError("synthetic 모드는 ExchangeEngine 주입 필요")
        return SyntheticAccountAdapter(exchange)
    elif config.account.mode == AccountMode.KIS_LIVE:
        raise ValueError("kis_live 는 Phase 2D 까지 사용 금지")
    else:
        raise ValueError(f"Unknown account.mode: {config.account.mode}")


def create_execution_event_port(config: Config, exchange: ExchangeEngine | None = None,
                                  mock_bus: MockEventBus | None = None) -> ExecutionEventPort:
    """ADR-013: 체결 통보 push 수신 전용."""
    if config.execution_event.mode == ExecutionEventMode.MOCK:
        if mock_bus is None:
            raise ValueError("mock 모드는 MockEventBus 주입 필요 (MockOrderAdapter와 공유)")
        return MockExecutionEventAdapter(mock_bus)
    elif config.execution_event.mode == ExecutionEventMode.KIS_PAPER:
        return KISPaperExecutionEventAdapter(config.broker.kis, config.execution_event.reconnect_max_seconds)
    elif config.execution_event.mode == ExecutionEventMode.SYNTHETIC:
        if exchange is None:
            raise ValueError("synthetic 모드는 ExchangeEngine 주입 필요")
        return SyntheticExecutionEventAdapter(exchange)
    elif config.execution_event.mode == ExecutionEventMode.KIS_LIVE:
        raise ValueError("kis_live 는 Phase 2D 까지 사용 금지")
    else:
        raise ValueError(f"Unknown execution_event.mode: {config.execution_event.mode}")


def create_all_ports(config: Config) -> dict:
    """Boot 시퀀스 — synthetic 모드는 ExchangeEngine 먼저 생성 후 모든 Adapter에 주입.
    mock 모드는 MockEventBus 먼저 생성 후 MockOrder/MockExecutionEvent에 주입."""
    exchange = None
    mock_bus = None
    modes = [config.market_data.mode, config.order.mode, config.account.mode, config.execution_event.mode]
    if any(m == 'synthetic' for m in modes):
        if not all(m == 'synthetic' for m in modes):
            raise ValueError("synthetic 모드는 market_data/order/account/execution_event 모두 synthetic이어야 한다")
        exchange = ExchangeEngine(config.synthetic, seed=config.synthetic.seed)
    if any(m == 'mock' for m in [config.order.mode, config.execution_event.mode]):
        mock_bus = MockEventBus.shared()

    return {
        'market_data': create_market_data_port(config, exchange),
        'order': create_order_port(config, exchange, mock_bus),
        'account': create_account_port(config, exchange),
        'execution_event': create_execution_event_port(config, exchange, mock_bus),
        # ... storage, clock, audit, strategy_runtime
    }
```

각 Port별로 동일 패턴의 팩토리 함수 존재. Boot 시퀀스에서 `create_all_ports()` 호출.

---

## 11. 변경 이력

| 날짜 | 버전 | 변경 |
|------|------|------|
| 2026-04-17 | v1.0 | Phase 1 최초 작성. 12 Adapter 명세 통합. |
| 2026-04-17 | v1.1 | 교차 검증 후 보완: MockBroker 3메서드, KISWebSocket 3메서드, KISRest 2메서드, PostgresStorage 3메서드, InMemoryStorage 전체, HistoricalClock 2메서드 설명 추가. |
| 2026-04-17 | v1.2 | 3차 검증: CSVReplayAdapter unsubscribe 설명 추가. |
| 2026-04-17 | v1.3 | SyntheticMarketAdapter, SyntheticOrderAdapter, SyntheticAccountAdapter 추가 (가상거래소 연동). |
| 2026-04-17 | v2.0 | **BrokerPort 분리** → OrderPort + AccountPort. Mock/KISPaper/Synthetic 각각 Order판/Account판 6개로 분리. 12 → 16 Adapters. 단일 책임 원칙 적용. |
| 2026-04-17 | v2.1 | **ADR-013 적용**: ExecutionEventPort 신설. Mock/KISPaper/Synthetic 각각 ExecutionEvent 어댑터 3개 추가. 16 → 19 Adapters. OrderExecutor의 체결 통보 수신 책임 분해. |

---

*Phase 1 Adapter 구현 명세 — 19 Adapters | 8 Ports | 3 기본 경로 (백테스트/모의투자/가상검증)*
