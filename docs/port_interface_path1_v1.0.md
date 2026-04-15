# HR-DAG Trading System — Port Interface Design (Path 1: Realtime Trading)

> Version 1.0 | April 2026 | Based on Boundary Definition v1.0

---

## 1. Path 1 Port Architecture

| Port | 책임 | 기본 Adapter | Fallback |
|------|------|-------------|----------|
| MarketDataPort | 시세 수신/조회 | KIS REST + WebSocket | REST Polling |
| BrokerPort | 주문 실행/조회/취소 | KIS REST API | Mock (테스트) |
| AccountPort | 잔고/계좌 조회 | KIS REST API | Cached Snapshot |
| StoragePort | 시세/체결 영속화 | PostgreSQL | SQLite |

> **Hexagonal 원칙**: Core 노드는 Port만 import. Adapter는 main.py에서 주입. settings.yaml 한 줄로 교체.

---

## 2. Domain Types

### 2.1 Quote (시세 데이터)

| Field | Type | Description | KIS Field |
|-------|------|-------------|-----------|
| symbol | str | 종목코드 (6자리) | stck_shrn_iscd |
| name | str | 업종 한글 종목명 | bstp_kor_isnm |
| price | int | 현재가 | stck_prpr |
| change | int | 전일 대비 | prdy_vrss |
| change_sign | str | 전일 대비 부호 (1~5) | prdy_vrss_sign |
| change_rate | float | 전일 대비율 (%) | prdy_ctrt |
| open | int | 시가 | stck_oprc |
| high | int | 최고가 | stck_hgpr |
| low | int | 최저가 | stck_lwpr |
| volume | int | 누적 거래량 | acml_vol |
| trade_amount | int | 누적 거래 대금 | acml_tr_pbmn |
| upper_limit | int | 상한가 | stck_mxpr |
| lower_limit | int | 하한가 | stck_llam |
| per | float | PER | per |
| pbr | float | PBR | pbr |
| market_cap | int | HTS 시가총액 | hts_avls |
| foreign_ratio | float | HTS 외국인 소진율 | hts_frgn_ehrt |
| timestamp | datetime | 조회 시점 | (시스템 생성) |

### 2.2 OrderRequest (주문 요청)

| Field | Type | Description | KIS Field |
|-------|------|-------------|-----------|
| symbol | str | 종목코드 | PDNO |
| side | OrderSide | 매수/매도 (BUY\|SELL) | ord_dv |
| order_type | OrderType | 주문유형 (LIMIT\|MARKET) | ORD_DVSN |
| quantity | int | 주문 수량 | ORD_QTY |
| price | int \| None | 주문 단가 (시장가면 None) | ORD_UNPR |
| strategy_id | str | 요청한 전략 ID | (내부) |
| request_id | str | 중복방지용 UUID | (내부) |

### 2.3 OrderResult (주문 결과)

| Field | Type | Description | KIS Field |
|-------|------|-------------|-----------|
| success | bool | 주문 성공 여부 | (로직) |
| order_no | str | KIS 주문번호 | ODNO |
| order_time | str | 주문 시간 | ORD_TMD |
| exchange_code | str | 거래소 코드 | KRX_FWDG_ORD_ORGNO |
| error_code | str \| None | 에러 코드 | msg_cd |
| error_msg | str \| None | 에러 메시지 | msg1 |
| request_id | str | 원본 요청 UUID | (내부) |

### 2.4 Position (보유 포지션)

| Field | Type | Description | KIS Field |
|-------|------|-------------|-----------|
| symbol | str | 상품번호 | pdno |
| name | str | 상품명 | prdt_name |
| quantity | int | 보유수량 | hldg_qty |
| orderable_qty | int | 주문가능수량 | ord_psbl_qty |
| avg_price | float | 매입평균가격 | pchs_avg_pric |
| purchase_amount | int | 매입금액 | pchs_amt |
| current_price | int | 현재가 | prpr |
| eval_amount | int | 평가금액 | evlu_amt |
| eval_pnl | int | 평가손익금액 | evlu_pfls_amt |
| eval_pnl_rate | float | 평가손익률 (%) | evlu_pfls_rt |
| change_rate | float | 등락율 (%) | fltt_rt |

### 2.5 AccountSummary (계좌 요약)

| Field | Type | Description | KIS Field |
|-------|------|-------------|-----------|
| deposit | int | 예수금총금액 | dnca_tot_amt |
| total_purchase | int | 매입금액합계 | pchs_amt_smtl_amt |
| total_eval | int | 평가금액합계 | evlu_amt_smtl_amt |
| total_pnl | int | 평가손익합계 | evlu_pfls_smtl_amt |
| net_asset | int | 순자산금액 | nass_amt |
| total_eval_amount | int | 총평가금액 | tot_evlu_amt |
| asset_change | int | 자산증감액 | asst_icdc_amt |
| asset_change_rate | float | 자산증감수익률 | asst_icdc_erng_rt |

### 2.6 Enums

| Enum | Values | KIS Mapping |
|------|--------|-------------|
| OrderSide | BUY \| SELL | buy → TTTC0012U, sell → TTTC0011U |
| OrderType | LIMIT \| MARKET | 00:지정가, 01:시장가 |
| MarketStatus | PRE \| OPEN \| CLOSE | WebSocket market_status_krx |
| ChangeSign | RISE \| FLAT \| FALL | 1:상한, 2:상승, 3:보합, 4:하락, 5:하한 |

---

## 3. Port Interfaces

### 3.1 MarketDataPort

| Method | Input | Output | KIS API |
|--------|-------|--------|---------|
| get_price(symbol) | str | Quote | inquire_price |
| get_daily_prices(symbol, period) | str, int | list[DailyBar] | inquire_daily_price |
| get_minute_chart(symbol, interval) | str, int | list[MinuteBar] | inquire_time_dailychartprice |
| get_asking_price(symbol) | str | AskingPrice | inquire_asking_price_exp_ccn |
| subscribe(symbol, callback) | str, Callable | Subscription | WebSocket ccnl_krx |
| unsubscribe(subscription_id) | str | bool | WebSocket unsubscribe |
| get_market_status() | (none) | MarketStatus | market_status_krx |

### 3.2 BrokerPort

| Method | Input | Output | KIS API |
|--------|-------|--------|---------|
| place_order(request) | OrderRequest | OrderResult | order_cash (POST) |
| cancel_order(order_no) | str | OrderResult | order_rvsecncl |
| modify_order(order_no, new_price, new_qty) | str, int, int | OrderResult | order_rvsecncl |
| get_pending_orders() | (none) | list[PendingOrder] | inquire_daily_ccld |
| get_order_history(date_range) | DateRange | list[OrderHistory] | inquire_daily_ccld |

> **Safeguard 순서**: Strategy → RiskGuard → DedupGuard → BrokerPort.place_order()

### 3.3 AccountPort

| Method | Input | Output | KIS API |
|--------|-------|--------|---------|
| get_positions() | (none) | list[Position] | inquire_balance output1 |
| get_summary() | (none) | AccountSummary | inquire_balance output2 |
| get_buyable_amount(symbol) | str | int | inquire_psbl_order |
| reconcile(internal_state) | PositionState | ReconcileResult | (내부 비교 로직) |

### 3.4 StoragePort

| Method | Input | Output | KIS API |
|--------|-------|--------|---------|
| save_quote(quote) | Quote | bool | (내부 DB) |
| save_order(result) | OrderResult | bool | (내부 DB) |
| save_position_snapshot(positions) | list[Position] | bool | (내부 DB) |
| get_latest_quotes(symbol, n) | str, int | list[Quote] | (내부 DB) |
| save_event(event) | SystemEvent | bool | (이벤트 WAL) |

---

## 4. Data Flow

| Source | → | Target | Data Type | Edge Type |
|--------|---|--------|-----------|-----------|
| MarketDataPort | → | Indicator Calculator | Quote | DataFlow |
| Indicator Calculator | → | Strategy Engine | IndicatorSet | DataFlow |
| Strategy Engine | → | RiskGuard | SignalEvent | Event |
| RiskGuard | → | DedupGuard | ValidatedSignal | DataFlow |
| DedupGuard | → | BrokerPort | OrderRequest | DataFlow |
| BrokerPort | → | TradingFSM | OrderResult | Event |
| TradingFSM | → | StoragePort | StateTransition | Event |
| AccountPort | → | TradingFSM | ReconcileResult | Event |
| StoragePort | ↔ | Shared Store | Quote/Position/Event | DataFlow |

---

## 5. Shared Store Schema (Path 1 Scope)

### 5.1 Market Data Store
| Table | Key | Value | Readers |
|-------|-----|-------|---------|
| quotes | symbol + timestamp | Quote | Path 1, 3, 4 |
| daily_bars | symbol + date | DailyBar | Path 1, 3 |
| minute_bars | symbol + datetime | MinuteBar | Path 1 |

### 5.2 Position Store
| Table | Key | Value | Readers |
|-------|-----|-------|---------|
| positions | symbol | Position | Path 1, 4, 5 |
| orders | order_no | OrderResult | Path 1, 4, 5 |
| events_wal | event_id | SystemEvent | Path 1, 5 |
| fsm_state | session_id | FSMSnapshot | Path 1, 5 |

### 5.3 Config Store
| Key | Type | Description | Writable By |
|-----|------|-------------|-------------|
| watchlist | list[str] | 감시 종목 목록 | 외부 LLM only |
| strategy_config | dict | 전략 파라미터 | 외부 LLM only |
| risk_limits | RiskConfig | 손절/한도 설정 | 외부 LLM only |
| adapter_selection | dict | 사용 중 Adapter 선택 | 외부 LLM only |

> **Config Store 쓰기 권한**: 외부 LLM만 변경. 내부 LLM은 읽기만. Constrained Agent 원칙.

---

*End of Document — Port Interface Design v1.0 (Path 1)*
