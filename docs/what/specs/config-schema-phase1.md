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

Phase 1에서 **환경 전환의 핵심**은 `broker.mode` 단 한 줄이다.

```
broker.mode: mock      → MockBroker (백테스트)
broker.mode: paper     → KISPaperBrokerAdapter (모의투자)
broker.mode: live      → Phase 2D까지 절대 사용 금지
```

---

## 2. 전체 스키마 (annotated YAML)

```yaml
# ==========================================================================
# 1. 브로커 (BrokerPort 어댑터 선택)
# ==========================================================================
broker:
  mode: "mock"                    # 필수 | enum: mock | paper | live
                                  # mock   → MockBrokerAdapter (백테스트)
                                  # paper  → KISPaperBrokerAdapter (모의투자)
                                  # live   → 금지 (Phase 2D 이후)
  kis:                            # mode=paper/live 일 때만 사용
    app_key: ""                   # string | KIS API App Key
    app_secret: ""                # string | KIS API App Secret
    account_no: ""                # string | 계좌번호 (예: "50123456-01")
    base_url: "https://openapivts.koreainvestment.com:29443"
                                  # 모의투자 URL (paper)
                                  # live: https://openapi.koreainvestment.com:9443

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
# 12. 백테스트 (MockBrokerAdapter 전용)
# ==========================================================================
backtest:
  initial_cash: 100000000         # int | 초기 자금 (KRW, 기본 1억)
  slippage_bps: 5                 # int ≥ 0 | 슬리피지 (basis points, 기본 5 = 0.05%)
  fee_rate: 0.00015               # float ≥ 0 | 매수·매도 수수료율 (기본 0.015%)
  tax_rate: 0.0023                # float ≥ 0 | 증권거래세 (매도 시, 기본 0.23%)

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

**MockBroker → KISPaperBroker 전환 시 변경 키 (총 5줄)**

```yaml
# BEFORE (백테스트)
broker:
  mode: "mock"
market_data:
  mode: "csv_replay"

# AFTER (모의투자) — 변경 줄만 표시
broker:
  mode: "paper"
  kis:
    app_key: "PSxxxxxxxxxxxxxxxx"
    app_secret: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    account_no: "50123456-01"
market_data:
  mode: "ws"
```

**KISPaperBroker → 실전 전환 (Phase 2D에서만)**

```yaml
broker:
  mode: "live"            # 이 한 줄 + base_url 변경
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
| `broker.mode` | enum 강제 | 기동 중단 |
| `broker.mode == live` | Phase 1에서 금지 | 기동 중단 |
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
