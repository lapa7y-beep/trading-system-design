# Phase 1 설정 파일 스키마 (config.yaml·11섹션·브로커전환)

> **목적**: config/config.yaml의 전체 구조, 타입, 기본값, 유효범위, 브로커 전환 명세를 정의한다.
> **층**: What
> **상태**: Phase 1 확정
> **최종 수정**: 2026-04-17
> **구현 여정**: Step 02(Enabling Point 설정)에서 참조. ADR-012 §6 참조.
> **선행 문서**: `docs/what/decisions/011-phase1-scope.md`
> **진실의 원천**: 이 문서 ↔ `docs/what/architecture/path1-node-blueprint.md` 상호 참조.

## 1. 파일 구조 개요

```
config/
├── config.yaml          ← 이 문서가 정의하는 메인 설정
└── watchlist.yaml       ← 종목 목록 (별도 파일, 섹션 8 참조)
```

Phase 1에서 **환경 전환의 핵심**은 `order.mode` + `account.mode` 두 줄이다.
(보통 같은 증권사로 통일하지만, Port가 분리되어 있어 혼합도 가능.)

```
order.mode + account.mode: mock + mock           → MockOrder + MockAccount (백테스트)
order.mode + account.mode: paper + paper         → KISPaper Order/Account (모의투자)
order.mode + account.mode: synthetic + synthetic → Synthetic Order/Account (가상거래소)
order.mode + account.mode: live + live           → Phase 2D까지 절대 사용 금지
```

> **혼합 사용**: SyntheticOrder ↔ SyntheticAccount는 **반드시 쌍**으로 사용 (ExchangeEngine 공유 필수).
> MockOrder ↔ MockAccount도 마찬가지 (in-process 상태 공유). KIS는 혼합 가능 (KISPaperOrder + KISPaperAccount, 또는 OrderPort만 KIS 사용 + AccountPort는 다른 증권사 등).

---

## 2. 전체 스키마 (annotated YAML)

```yaml
# ==========================================================================
# 1. 주문 (OrderPort 어댑터 선택) — BrokerPort 분리 결과
# ==========================================================================
order:
  mode: "mock"                    # 필수 | enum: mock | paper | synthetic | live
                                  # mock      → MockOrderAdapter (백테스트)
                                  # paper     → KISPaperOrderAdapter (모의투자)
                                  # synthetic → SyntheticOrderAdapter (가상거래소)
                                  # live      → 금지 (Phase 2D 이후)

# ==========================================================================
# 1b. 계좌 (AccountPort 어댑터 선택) — BrokerPort 분리 결과
# ==========================================================================
account:
  mode: "mock"                    # 필수 | enum: mock | paper | synthetic | live
                                  # mock      → MockAccountAdapter (MockOrder와 상태 공유)
                                  # paper     → KISPaperAccountAdapter
                                  # synthetic → SyntheticAccountAdapter (ExchangeEngine 공유)
                                  # live      → 금지 (Phase 2D 이후)
  reconcile_interval_seconds: 10  # int ≥ 1 | 내부 DB ↔ 브로커 잔고 일관성 검증 주기

# ==========================================================================
# 1c. 브로커 인증 정보 (KIS 공통, OrderPort+AccountPort+ExecutionEventPort가 공유)
# ==========================================================================
broker:
  kis:                            # order.mode 또는 account.mode 또는 execution_event.mode가 paper/live 일 때 사용
    app_key: ""                   # string | KIS API App Key
    app_secret: ""                # string | KIS API App Secret
    account_no: ""                # string | 계좌번호 (예: "50123456-01")
    hts_id: ""                    # string | 체결 통보 WebSocket(H0STCNI0) tr_key 용
    base_url: "https://openapivts.koreainvestment.com:29443"
                                  # 모의투자 URL (paper)
                                  # live: https://openapi.koreainvestment.com:9443
    ws_url: "wss://openapivts.koreainvestment.com:29443"
                                  # 체결 통보 WebSocket URL (paper)

# ==========================================================================
# 1d. 체결 통보 (ExecutionEventPort 어댑터 선택) — ADR-013 신설
# ==========================================================================
execution_event:
  mode: "mock"                    # 필수 | enum: mock | paper | synthetic | live
                                  # mock      → MockExecutionEventAdapter (MockOrder 체결 in-process emit)
                                  # paper     → KISPaperExecutionEventAdapter (H0STCNI0 WebSocket)
                                  # synthetic → SyntheticExecutionEventAdapter (ExchangeEngine 공유)
                                  # live      → 금지 (Phase 2D 이후)
  reconnect_max_seconds: 60       # int | WebSocket 재연결 최대 대기 (지수 백오프 상한)
  dedup_cache_size: 1000          # int | execution_uuid 중복 제거 LRU 캐시 크기
  crash_replay: true              # bool | 부팅 시 최근 5분 이벤트 replay 여부

# ==========================================================================
# 2. 시세 수신 (MarketDataPort 어댑터 선택)
# ==========================================================================
market_data:
  mode: "ws"                      # enum: ws | poll | csv_replay
                                  # ws          → KISWebSocketAdapter (기본)
                                  # poll        → KISRestAdapter (ws 장애 시 자동 전환)
                                  # csv_replay  → CSVReplayAdapter (백테스트)
  ws_reconnect_max: 3             # int ≥ 1 | ws 재연결 최대 시도 횟수
  ws_reconnect_interval_seconds: 5  # int ≥ 1 | 재연결 대기 (초)
  poll_interval_seconds: 10       # int ≥ 1 | polling 주기 (초)
  poll_reconnect_check_seconds: 30  # int ≥ 1 | ws 복구 시도 주기 (초)
  price_deviation_warn_pct: 3     # float > 0 | 직전 체결가 대비 이상 괴리 경고 (%)
  stale_tick_warn_seconds: 3      # int ≥ 1 | 시세 미수신 경고 임계 (초)
  csv_replay:                     # mode=csv_replay 일 때만 사용
    data_dir: "data/ohlcv/"       # string | CSV 파일 디렉토리
    speed_multiplier: 1.0         # float > 0 | 1.0=실시간 속도, 0=즉시

# ==========================================================================
# 3. 지표 계산 (IndicatorCalculator)
# ==========================================================================
indicators:
  buffer_size: 200                # int ≥ 100 | 봉 버퍼 크기
  warmup_bars: 60                 # int ≥ 1 | 워밍업 최소 봉 수 (미달 시 신호 null)
  sma_periods: [5, 20]            # list[int] | SMA 기간 목록
  ema_periods: [12, 26]           # list[int] | EMA 기간 목록
  rsi_period: 14                  # int ≥ 2 | RSI 기간
  macd:
    fast: 12                      # int ≥ 1
    slow: 26                      # int > fast
    signal: 9                     # int ≥ 1
  bbands:
    period: 20                    # int ≥ 2
    std: 2                        # float > 0 | 표준편차 배수
  atr_period: 14                  # int ≥ 2 | ATR 기간

# ==========================================================================
# 4. 전략 엔진 (StrategyEngine)
# ==========================================================================
strategy:
  directory: "strategies/"        # string | 전략 .py 파일 디렉토리
  active: "ma_crossover"          # string | 활성 전략 파일명 (확장자 제외)
  active_count: 1                 # int = 1 | Phase 1 고정. 복수 전략은 Phase 2
  signal_cooldown_seconds: 60     # int ≥ 0 | 동일 종목 연속 신호 억제 (초)
  hot_reload: false               # bool | 실행 중 전략 파일 변경 감지. Phase 1=false

# ==========================================================================
# 5. 리스크 관리 (RiskGuard — Pre-Order 7체크)
# ==========================================================================
risk:
  max_cash_usage_ratio: 0.95      # float 0~1 | 총 현금 대비 최대 투입 비율
  max_single_position_pct: 20     # float 0~100 | 단일 종목 최대 비중 (%)
  max_daily_loss_pct: 2.0         # float > 0 | 일일 최대 손실 한도 (%)
  max_daily_trades: 40            # int ≥ 1 | 일일 최대 주문 건수
  trading_hours_start: "09:00"    # string HH:MM | 매매 시작 시각 (KST)
  trading_hours_end: "15:20"      # string HH:MM | 매매 종료 시각 (KST)
  circuit_breaker_window_seconds: 60   # int ≥ 1 | 연속 실패 집계 윈도우 (초)
  circuit_breaker_max_failures: 3      # int ≥ 1 | 윈도우 내 최대 허용 실패 수

# ==========================================================================
# 6. 주문 실행 (OrderExecutor)
# ==========================================================================
order_executor:
  submit_timeout_seconds: 5       # int ≥ 1 | 주문 제출 응답 대기 최대 (초)
  idempotency_check: true         # bool | 중복 주문 방지 DB 조회 여부. 항상 true
  circuit_breaker:
    window_seconds: 60            # int ≥ 1 | risk.circuit_breaker와 별도 카운터
    max_failures: 3               # int ≥ 1
    recovery_seconds: 30          # int ≥ 1 | 차단 후 복구 대기 (초)

# ==========================================================================
# 7. FSM / 상태 관리 (TradingFSM)
# ==========================================================================
fsm:
  persist_on_every_transition: true  # bool | 전이마다 PostgreSQL 저장. 항상 true
  crash_recovery_on_boot: true       # bool | 기동 시 미완료 포지션 복원. 항상 true

# ==========================================================================
# 8. DB / 스토리지 (StoragePort)
# ==========================================================================
database:
  url: "postgresql://atlas:atlas@localhost:5432/atlas"
                                  # string | PostgreSQL 연결 URL
  pool_size: 5                    # int ≥ 1 | 연결 풀 크기
  pool_timeout_seconds: 30        # int ≥ 1

# ==========================================================================
# 9. 스케줄러 (APScheduler — 일봉 수집)
# ==========================================================================
scheduler:
  daily_ohlcv_fetch_time: "16:00" # string HH:MM | 일봉 수집 시각 (KST)
  timezone: "Asia/Seoul"          # string | 스케줄러 타임존

# ==========================================================================
# 10. 로깅
# ==========================================================================
logging:
  level: "INFO"                   # enum: DEBUG | INFO | WARNING | ERROR
  format: "json"                  # enum: json | text
  file: "logs/atlas.log"          # string | 로그 파일 경로 (비어있으면 stdout만)
  max_bytes: 10485760             # int | 로그 파일 최대 크기 (기본 10MB)
  backup_count: 5                 # int | 보관 파일 수

# ==========================================================================
# 11. CLI / 운영 (atlas 명령 동작)
# ==========================================================================
cli:
  halt_timeout_seconds: 30        # int ≥ 1 | atlas halt 후 신규 주문 차단 완료 대기
  status_refresh_seconds: 5       # int ≥ 1 | atlas status 폴링 주기

# ==========================================================================
# 12. 백테스트 (MockOrderAdapter + MockAccountAdapter 전용)
# ==========================================================================
backtest:
  initial_cash: 100000000         # int | 초기 자금 (KRW, 기본 1억)
  slippage_ticks: 1               # int ≥ 0 | 슬리피지 (호가단위 tick 수, 기본 1)
  fee_rate: 0.00015               # float ≥ 0 | 매수·매도 수수료율 (기본 0.015%)
  transaction_tax_rate: 0.0018    # float ≥ 0 | 증권거래세 (매도 시, KOSPI 2024~ 기준 0.18%)
  special_tax_rate: 0.0015        # float ≥ 0 | 농어촌특별세 (KOSPI만, 0.15%. KOSDAQ은 0)

# ==========================================================================
# [Phase 2 예약 — Phase 1에서 설정해도 무시됨]
# ==========================================================================
# telegram:
#   bot_token: ""
#   allowed_chat_ids: []
#
# redis:
#   url: "redis://localhost:6379"
#
# screener:
#   enabled: false
```

---

## 3. 브로커 전환 — 변경 키 명세

**Mock → KISPaper 전환 시 변경 키 (총 8줄)**

```yaml
# BEFORE (백테스트)
order:
  mode: "mock"
account:
  mode: "mock"
execution_event:
  mode: "mock"
market_data:
  mode: "csv_replay"

# AFTER (모의투자) — 변경 줄만 표시
order:
  mode: "paper"
account:
  mode: "paper"
execution_event:
  mode: "paper"                   # ADR-013: KIS H0STCNI0 WebSocket
broker:
  kis:
    app_key: "PSxxxxxxxxxxxxxxxx"
    app_secret: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    account_no: "50123456-01"
    hts_id: "USERID"              # 체결 통보 tr_key
market_data:
  mode: "ws"
```

**가상거래소로 전환**

```yaml
order:
  mode: "synthetic"
account:
  mode: "synthetic"
execution_event:
  mode: "synthetic"               # ADR-013
market_data:
  mode: "synthetic"
synthetic:
  seed: 42
  # ... synthetic 섹션 (§9 참조)
```

**Phase 2D 실전 전환** — 변경 줄만:

```yaml
order:
  mode: "live"            # OrderPort만 live로
account:
  mode: "live"            # AccountPort만 live로
execution_event:
  mode: "live"            # ExecutionEventPort도 live로 (ADR-013)
broker:
  kis:
    base_url: "https://openapi.koreainvestment.com:9443"
```

---

## 4. watchlist.yaml 구조

```yaml
# config/watchlist.yaml
symbols:
  - "005930"   # 삼성전자
  - "000660"   # SK하이닉스
  - "035720"   # 카카오
# Phase 1: 3~5개 권장. 종목 수 증가 시 ws 구독 슬롯 확인 필요.
```

---

## 5. 유효성 검사 규칙 (Pydantic 구현 기준)

| 키 | 검사 | 실패 시 동작 |
|-----|------|------------|
| `order.mode` / `account.mode` / `execution_event.mode` | enum 강제 | 기동 중단 |
| `*.mode == live` | Phase 1에서 금지 (3개 Port 모두) | 기동 중단 |
| `order.mode == synthetic` ⇔ `account.mode == synthetic` ⇔ `execution_event.mode == synthetic` | 3개 쌍으로만 사용 | 기동 중단 |
| `order.mode == mock` ⇔ `account.mode == mock` ⇔ `execution_event.mode == mock` | 3개 쌍으로만 사용 | 기동 중단 |
| `execution_event.mode == paper` ⇒ `broker.kis.hts_id` 필수 | H0STCNI0 tr_key | 기동 중단 |
| `execution_event.reconnect_max_seconds` | 1 ≤ x ≤ 300 | 기동 중단 |
| `execution_event.dedup_cache_size` | 100 ≤ x ≤ 10000 | 기동 중단 |
| `risk.max_cash_usage_ratio` | 0 < x ≤ 1 | 기동 중단 |
| `risk.max_daily_loss_pct` | x > 0 | 기동 중단 |
| `indicators.buffer_size` ≥ `indicators.warmup_bars` | 필수 | 기동 중단 |
| `macd.slow` > `macd.fast` | 필수 | 기동 중단 |
| `trading_hours_start` < `trading_hours_end` | HH:MM 형식 + 순서 | 기동 중단 |
| `database.url` | 연결 가능 여부 | 기동 중단 |
| `watchlist.symbols` | 1개 이상 | 기동 중단 |

---

## 6. 환경변수 오버라이드

민감 정보는 YAML에 직접 쓰지 않고 환경변수로 주입한다.

```bash
ATLAS_BROKER_KIS_APP_KEY=PSxxx
ATLAS_BROKER_KIS_APP_SECRET=xxxxxxxx
ATLAS_BROKER_KIS_ACCOUNT_NO=50123456-01
ATLAS_DATABASE_URL=postgresql://atlas:secret@localhost:5432/atlas
```

적재 우선순위: **환경변수 > config.yaml > 기본값**

---

## 7. 변경 이력

| 날짜 | 버전 | 변경 |
|------|------|------|
| 2026-04-17 | v1.0 | Phase 1 최초 작성. 6노드 설정 키 통합. |
| 2026-04-17 | v1.1 | 4차 검증: backtest 섹션 추가 (slippage_bps, fee_rate, tax_rate, initial_cash). |

---

*Phase 1 config.yaml 통합 스키마 — 12개 섹션, MockBroker↔KISPaper 전환 명세 포함*

---

## 추가 섹션 (quant-spec-phase1 §9 연동)

> **출처**: `docs/what/specs/quant-spec-phase1.md` §9
> **추가일**: 2026-04-17

```yaml
# ---- quant-spec §9 연동 키 ----

market_data:
  bar_timeframe: "1m"               # str | Bar 집계 주기 (Phase 1 고정)
  skip_opening_auction: true        # bool | 08:30~09:00 동시호가 tick 제외
  skip_closing_auction: true        # bool | 15:20~15:30 동시호가 tick 제외

strategy:
  active: "ma_crossover"            # str | Phase 1 활성 전략
  params:
    fast: 5                         # int | 단기 SMA 기간
    slow: 20                        # int | 장기 SMA 기간
    warmup_bars: 25                 # int | slow + 여유
  reentry_cooldown_seconds: 300     # int | 청산 후 동일종목 재진입 대기

position_sizing:
  algorithm: "fixed_notional"       # str | 수량 산정 알고리즘
  cash_usage_pct: 0.15              # float | 가용현금 대비 비율
  max_notional_krw: 5000000         # int | 최대 투자금 (원)

exit_rules:
  enable_ma_cross_exit: true        # bool | 데드크로스 청산
  enable_stop_loss: true            # bool | 고정 손절
  stop_loss_pct: -0.025             # float | 손절 기준 (-2.5%)
  enable_eod_exit: true             # bool | 장 마감 전 강제 청산
  eod_exit_time: "15:10"            # str | 청산 시각 (KST)

order_execution:
  price_mode: "limit"               # str | 지정가만 (시장가 금지)
  tick_round_buy: "floor"           # str | 매수 호가 하향 보정
  tick_round_sell: "ceil"           # str | 매도 호가 상향 보정
  unfill_timeout_seconds: 10        # int | 미체결 대기 시간
  unfill_retry_count: 1             # int | 미체결 재시도 횟수

vi_detection:
  enabled: true                     # bool | VI 감지 활성화
  price_heuristic_window_min: 10    # int | 급등락 판단 윈도우 (분)
  price_heuristic_threshold_pct: 10 # int | 급등락 기준 (%)
  poll_interval_seconds: 5          # int | REST 폴링 주기
  cooldown_after_vi_seconds: 120    # int | VI 후 신호 폐기 기간

market_rules_file: "config/market_rules.yaml"  # str | 수수료·세금 외부 파일
```

---

## synthetic 섹션 (가상거래소 — synthetic-exchange-phase1.md 연동)

> **출처**: `docs/what/specs/synthetic-exchange-phase1.md` §10
> **사용 조건**: `order.mode: synthetic` + `account.mode: synthetic` + `market_data.mode: synthetic` 3개 모두 synthetic이어야 함

```yaml
synthetic:
  seed: 42                           # int | 재현성 시드 (같은 시드 = 같은 시계열)
  simulation_days: 504               # int | 시뮬레이션 영업일 수 (2년)
  initial_cash: 100000000            # int | 초기 자본 (원, 1억)

  price_model:
    type: "gbm_realistic"            # str | gbm | gbm_realistic | regime_switching
    drift_annual: 0.08               # float | 연간 기대수익률 (8%)
    vol_annual: 0.25                 # float | 연간 변동성 (25%)
    jump_intensity: 0.3              # float | 일 평균 점프 횟수 (Level 2)
    jump_std: 0.03                   # float | 점프 크기 표준편차

  initial_prices:                    # 종목별 시작가 (watchlist와 일치해야 함)
    "005930": 72000                  # 삼성전자
    "000660": 180000                 # SK하이닉스
    "373220": 380000                 # LG에너지솔루션
    "207940": 750000                 # 삼성바이오로직스
    "005380": 210000                 # 현대차

  market_rules:
    tick_size_table: "kospi"         # str | kospi | kosdaq
    limit_pct: 0.30                  # float | 상하한가 비율 (30%)
    vi_threshold_pct: 0.10           # float | VI 발동 기준 (10%)
    vi_cooldown_seconds: 120         # int | VI 후 신호 폐기 기간
    trading_hours_start: "09:00"     # str | 장 시작 (KST)
    trading_hours_end: "15:20"       # str | 장 종료 (KST)

  scenarios: []                      # list | 이벤트 주입 (§8 synthetic-exchange 참조)
  # 예시:
  # - type: "flash_crash"
  #   symbol: "005930"
  #   at_minute: 180
  #   magnitude: -0.08

  monte_carlo:
    n_runs: 1000                     # int | Monte Carlo 시뮬 횟수
    acceptance_sharpe_median: 0.8    # float | 합격기준 1-A: Sharpe 중앙값
```
