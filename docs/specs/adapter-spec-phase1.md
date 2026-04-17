# adapter-spec-phase1 — Adapter 구현 명세

> **상태**: Phase 1 확정
> **최종 수정**: 2026-04-17
> **목적**: Phase 1에서 구현할 12개 Adapter의 내부 동작, 의존성, 실패 처리, 전환 규칙을 단일 문서로 정의.
> **구현 위치**: `adapters/*/`
> **선행 문서**: `docs/specs/port-signatures-phase1.md`, `docs/specs/config-schema-phase1.md`, `graph_ir_phase1.yaml`

---

## 1. Adapter 설계 원칙

1. **단일 Port 구현** — 하나의 Adapter는 반드시 하나의 Port ABC를 상속.
2. **상태 최소화** — 가능하면 stateless. 상태는 `__init__` 주입과 내부 연결 핸들로만.
3. **예외 변환** — 내부 예외(httpx, asyncpg 등)는 반드시 `PortError` 하위로 변환 후 raise.
4. **로깅 분리** — `logging.getLogger(__name__)` 사용. AuditPort와 다름 (감사=도메인, 로깅=기술).
5. **설정 주입** — config는 `__init__`에서 받음. 모듈 전역 접근 금지.
6. **타임아웃 필수** — 외부 호출은 모두 `asyncio.wait_for`로 래핑. config의 `*_timeout_seconds` 사용.
7. **재시도 정책 명시** — 자체 재시도 있으면 지수 백오프, 없으면 호출자가 처리.

---

## 2. Adapter 전체 목록 (12개)

| # | Port | Adapter | 모드 | 외부 의존 |
|---|------|---------|------|----------|
| 1 | MarketDataPort | **KISWebSocketAdapter** | ws | KIS WS API, `websockets` |
| 2 | MarketDataPort | **KISRestAdapter** | poll | KIS REST API, `httpx` |
| 3 | MarketDataPort | **CSVReplayAdapter** | csv_replay | 파일시스템, `pandas` |
| 4 | BrokerPort | **MockBrokerAdapter** | mock | 없음 (in-process) |
| 5 | BrokerPort | **KISPaperBrokerAdapter** | paper | KIS REST API, `httpx` |
| 6 | StoragePort | **PostgresStorageAdapter** | primary | PostgreSQL, `asyncpg` |
| 7 | StoragePort | **InMemoryStorageAdapter** | test | 없음 |
| 8 | ClockPort | **WallClockAdapter** | live/paper | OS 시계 |
| 9 | ClockPort | **HistoricalClockAdapter** | backtest | 없음 (내부 시뮬 시계) |
| 10 | StrategyRuntimePort | **FileSystemStrategyLoader** | primary | 파일시스템, `importlib` |
| 11 | AuditPort | **PostgresAuditAdapter** | primary | PostgreSQL, `asyncpg` |
| 12 | AuditPort | **StdoutAuditAdapter** | test | 없음 |

---

## 3. Adapter 선택 규칙 (Factory)

`broker.mode` + `market_data.mode` 조합으로 전체 어댑터 세트가 결정된다.

| broker.mode | market_data.mode | 선택되는 어댑터 세트 |
|-------------|------------------|---------------------|
| mock | csv_replay | Mock + CSVReplay + InMemory + HistoricalClock + StdoutAudit |
| mock | ws | Mock + KISWebSocket + Postgres + WallClock + PostgresAudit |
| paper | ws | KISPaper + KISWebSocket + Postgres + WallClock + PostgresAudit |

> **Phase 1 기본 경로 2개**
> - **백테스트**: `mock + csv_replay` (InMemory 스토리지, HistoricalClock)
> - **모의투자**: `paper + ws` (Postgres 영속, WallClock)

---

## 4. MarketDataPort 어댑터 (3개)

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

## 5. BrokerPort 어댑터 (2개)

### 5.1 MockBrokerAdapter

**역할**: 백테스트용. 주문을 메모리에서만 처리. 설정된 슬리피지·수수료 반영.

**핵심 동작**
- `submit` 호출 시 즉시 `OrderResult(status=FILLED)` 반환 (시장가) 또는 가격 조건 검사 후 체결 (지정가)
- `cancel`: `_orders` 딕셔너리에서 해당 UUID 조회 → 이미 FILLED면 `BrokerRejectError`, 아니면 CANCELLED 반환
- `get_order_status`: `_orders[order_uuid]` 조회 → 없으면 `DataError`
- `get_account_balance`: `_cash` 반환
- 체결가는 현재 시세(ClockPort.now 기준 CSV 재생 시점의 마지막 Quote) 기반
- 슬리피지: `price * (1 ± slippage_bps/10000)`
- 수수료: 매수=0.015%, 매도=0.015% + 거래세 0.23%

**의존성**
```python
# 없음 (in-process)
from collections import defaultdict
```

**config 사용 키**
- `backtest.slippage_bps` (기본 5)
- `backtest.fee_rate` (기본 0.00015)
- `backtest.tax_rate` (기본 0.0023)

> **note**: 백테스트 세부 설정은 Phase 1 config.yaml의 예약 구역. Phase 2에서 정식 스키마화.

**상태**
- `_orders: dict[UUID, OrderResult]` — 멱등성 보장용
- `_last_quote_by_symbol: dict[Symbol, Quote]` — 체결가 계산용 (MarketDataPort와 연동)
- `_cash: Money` — 현재 잔고 (초기값은 `backtest.initial_cash`)

**실패 처리**
| 상황 | 동작 |
|------|------|
| 잔고 부족 | `BrokerRejectError(code='INSUFFICIENT_CASH')` raise |
| 동일 `order_uuid` 재제출 | 기존 `OrderResult` 반환 (멱등성) |
| 시세 없음 (Quote 캐시 비어있음) | `DataError` raise |

---

### 5.2 KISPaperBrokerAdapter

**역할**: KIS 모의투자 계좌로 실제 주문 제출.

**핵심 동작**
- `submit`: POST `/uapi/domestic-stock/v1/trading/order-cash` 호출
- `cancel`: POST `/uapi/domestic-stock/v1/trading/order-rvsecncl`
- `get_order_status`: GET `/uapi/domestic-stock/v1/trading/inquire-psbl-order`
- `get_account_balance`: GET `/uapi/domestic-stock/v1/trading/inquire-balance`
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

**주의**: KIS API는 계좌 구분 코드(`CANO`, `ACNT_PRDT_CD`)가 필수. `account_no` 형식 `"50123456-01"`에서 `-` 기준으로 분리.

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

def create_broker_port(config: Config) -> BrokerPort:
    if config.broker.mode == BrokerMode.MOCK:
        return MockBrokerAdapter(config.backtest)
    elif config.broker.mode == BrokerMode.KIS_PAPER:
        return KISPaperBrokerAdapter(config.broker.kis, config.order_executor)
    elif config.broker.mode == BrokerMode.KIS_LIVE:
        raise ValueError("kis_live 는 Phase 2D 까지 사용 금지")
    else:
        raise ValueError(f"Unknown broker.mode: {config.broker.mode}")
```

각 Port별로 동일 패턴의 팩토리 함수 존재. Boot 시퀀스에서 호출 (다음 설계 문서).

---

## 11. 변경 이력

| 날짜 | 버전 | 변경 |
|------|------|------|
| 2026-04-17 | v1.0 | Phase 1 최초 작성. 12 Adapter 명세 통합. |
| 2026-04-17 | v1.1 | 교차 검증 후 보완: MockBroker 3메서드, KISWebSocket 3메서드, KISRest 2메서드, PostgresStorage 3메서드, InMemoryStorage 전체, HistoricalClock 2메서드 설명 추가. |
| 2026-04-17 | v1.2 | 3차 검증: CSVReplayAdapter unsubscribe 설명 추가. |

---

*Phase 1 Adapter 구현 명세 — 12 Adapters | 6 Ports | 2 기본 경로 (백테스트/모의투자)*
