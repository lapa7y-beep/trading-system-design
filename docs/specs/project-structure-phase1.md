# project-structure-phase1 — 프로젝트 폴더 구조

> **상태**: Phase 1 확정
> **최종 수정**: 2026-04-17
> **목적**: 구현 시작 시점의 전체 디렉토리 트리와 각 파일의 책임·의존 관계를 단일 문서로 정의.
> **선행 문서**: `docs/specs/port-signatures-phase1.md`, `docs/specs/adapter-spec-phase1.md`, `docs/architecture/cli-design.md`, `docs/architecture/boot-shutdown-phase1.md`
> **구현 시작 지점**: 이 구조가 확정되면 `atlas/` 코드 베이스 착수.

---

## 1. 설계 원칙

1. **설계 문서 구조와 1:1 미러링** — 설계(docs/specs/port-signatures)에 정의된 Port가 코드에서도 동일한 경로(`ports/`)에 위치.
2. **Hexagonal 경계 유지** — Core ↔ Port ↔ Adapter 3층이 폴더로 분리되어 서로 의존 방향이 역전되지 않음.
3. **최소 의존** — `core/domain`은 표준 라이브러리 + pydantic 외 의존 없음. adapters만 외부 라이브러리(httpx, asyncpg) 임포트.
4. **테스트 공존** — 각 모듈의 테스트는 최상위 `tests/` 아래에 동일한 트리 구조로 배치.
5. **설정과 코드 분리** — `config/`는 코드 외부. 환경변수 오버라이드 가능.
6. **생성물 격리** — `data/`, `logs/`, `strategies/` 3개는 런타임 데이터. gitignore 대상.

---

## 2. 전체 디렉토리 트리

```
atlas/                                    ← 저장소 루트 (구현 시작 시 이 이름으로 신규 저장소)
│
├── README.md                             ← 설치·실행 가이드 (trading-system-design의 README 참조)
├── pyproject.toml                        ← Python 의존성 + 빌드 설정 (poetry 또는 uv)
├── poetry.lock                           ← 고정 의존성
├── .gitignore                            ← data/, logs/, *.pyc, .env 등
├── .env.example                          ← 환경변수 템플릿
├── Makefile                              ← 개발 편의 명령 (test, lint, run)
├── docker-compose.yml                    ← PostgreSQL + (Phase 2) Redis
│
├── config/                               ← 런타임 설정 (코드 외부)
│   ├── config.yaml                       ← 메인 설정 (git-ignored, example 제공)
│   ├── config.example.yaml               ← 템플릿 (git 추적)
│   └── watchlist.yaml                    ← 종목 목록 (git-ignored)
│
├── atlas/                                ← 메인 패키지
│   │
│   ├── __init__.py                       ← 버전 정보
│   ├── __main__.py                       ← `python -m atlas` 진입점
│   │
│   ├── cli/                              ← CLI 명령 구현
│   │   ├── __init__.py
│   │   ├── main.py                       ← `atlas` 엔트리포인트 (click/typer)
│   │   ├── start.py                      ← atlas start
│   │   ├── stop.py                       ← atlas stop
│   │   ├── halt.py                       ← atlas halt / resume
│   │   ├── status.py                     ← atlas status / positions / pnl / orders
│   │   ├── audit.py                      ← atlas audit
│   │   ├── backtest.py                   ← atlas backtest
│   │   ├── config_cmd.py                 ← atlas config show/validate
│   │   └── version.py                    ← atlas version
│   │
│   ├── core/                             ← 도메인 핵심 (외부 의존 없음)
│   │   ├── __init__.py
│   │   │
│   │   ├── domain/                       ← Domain Types 20개
│   │   │   ├── __init__.py
│   │   │   ├── primitives.py             ← Symbol, Price, Quantity, Money, CorrelationId
│   │   │   ├── enums.py                  ← OrderSide, OrderType, OrderStatus, FSMState, BrokerMode
│   │   │   ├── market.py                 ← Quote, OHLCV, IndicatorBundle
│   │   │   ├── signal.py                 ← SignalOutput
│   │   │   ├── order.py                  ← OrderRequest, OrderResult, TradeRecord
│   │   │   ├── portfolio.py              ← Position, PortfolioSnapshot
│   │   │   └── risk.py                   ← RiskDecision
│   │   │
│   │   ├── nodes/                        ← Path 1 노드 6개
│   │   │   ├── __init__.py
│   │   │   ├── market_data_receiver.py   ← MarketDataReceiver
│   │   │   ├── indicator_calculator.py   ← IndicatorCalculator
│   │   │   ├── strategy_engine.py        ← StrategyEngine
│   │   │   ├── risk_guard.py             ← RiskGuard (Pre-Order 7체크)
│   │   │   ├── order_executor.py         ← OrderExecutor
│   │   │   └── trading_fsm.py            ← TradingFSM
│   │   │
│   │   ├── risk/                         ← RiskGuard 내부 체크 로직
│   │   │   ├── __init__.py
│   │   │   ├── checks.py                 ← 7개 체크 함수
│   │   │   └── circuit_breaker.py        ← CB 구현 (CLOSED/OPEN/HALF_OPEN)
│   │   │
│   │   ├── fsm/                          ← FSM 정의 및 관리
│   │   │   ├── __init__.py
│   │   │   ├── states.py                 ← 6 states, 12 transitions 선언
│   │   │   └── manager.py                ← FSM 인스턴스 관리 (종목별)
│   │   │
│   │   └── pipeline/                     ← 이벤트 루프 / 노드 연결
│   │       ├── __init__.py
│   │       └── main_loop.py              ← MarketDataPort.stream() → ... → OrderExecutor
│   │
│   ├── ports/                            ← Port ABC 6개 (port-signatures-phase1.md 그대로)
│   │   ├── __init__.py
│   │   ├── exceptions.py                 ← PortError 계층
│   │   ├── market_data_port.py
│   │   ├── broker_port.py
│   │   ├── storage_port.py
│   │   ├── clock_port.py
│   │   ├── strategy_runtime_port.py
│   │   └── audit_port.py
│   │
│   ├── adapters/                         ← 구현체 12개 (adapter-spec-phase1.md 그대로)
│   │   ├── __init__.py
│   │   ├── factory.py                    ← broker.mode / market_data.mode 기반 팩토리
│   │   │
│   │   ├── market_data/
│   │   │   ├── __init__.py
│   │   │   ├── kis_websocket.py
│   │   │   ├── kis_rest.py
│   │   │   └── csv_replay.py
│   │   │
│   │   ├── broker/
│   │   │   ├── __init__.py
│   │   │   ├── mock_broker.py
│   │   │   └── kis_paper_broker.py
│   │   │
│   │   ├── storage/
│   │   │   ├── __init__.py
│   │   │   ├── postgres_storage.py
│   │   │   └── in_memory_storage.py
│   │   │
│   │   ├── clock/
│   │   │   ├── __init__.py
│   │   │   ├── wall_clock.py
│   │   │   └── historical_clock.py
│   │   │
│   │   ├── strategy/
│   │   │   ├── __init__.py
│   │   │   └── filesystem_loader.py
│   │   │
│   │   └── audit/
│   │       ├── __init__.py
│   │       ├── postgres_audit.py
│   │       └── stdout_audit.py
│   │
│   ├── infrastructure/                   ← 횡단 관심사 (cross-cutting)
│   │   ├── __init__.py
│   │   ├── config_loader.py              ← config.yaml → Pydantic Config 객체
│   │   ├── logging_setup.py              ← 로거 초기화
│   │   ├── signal_handlers.py            ← SIGTERM / SIGUSR1 / SIGUSR2
│   │   ├── pid_file.py                   ← /var/run/atlas.pid 관리
│   │   ├── control_file.py               ← /var/run/atlas.control (mode: active/halted)
│   │   └── boot_sequence.py              ← Boot 12단계 오케스트레이션
│   │
│   ├── scheduler/                        ← APScheduler 일봉 수집
│   │   ├── __init__.py
│   │   └── daily_ohlcv.py                ← 16:00 일봉 수집 잡
│   │
│   └── backtest/                         ← 백테스트 엔진
│       ├── __init__.py
│       ├── runner.py                     ← CSVReplay + InMemoryStorage 조합 실행
│       └── report.py                     ← sharpe, drawdown, result.json 출력
│
├── strategies/                           ← 사용자 전략 파일 (런타임 로드)
│   ├── __init__.py                       ← (비어있음, 패키지 표식만)
│   ├── ma_crossover.py                   ← 예시 전략
│   └── README.md                         ← 전략 작성 가이드
│
├── db/                                   ← DB 스키마 관리
│   ├── migrations/                       ← (Phase 2: alembic. Phase 1은 단일 .sql)
│   └── init.sql                          ← docs/specs/db-schema-phase1.sql 복사본
│
├── data/                                 ← 런타임 데이터 (git-ignored)
│   └── ohlcv/                            ← CSV 백테스트 데이터
│
├── logs/                                 ← 로그 출력 (git-ignored)
│   ├── atlas.log                         ← 메인 로그
│   └── audit_fallback.jsonl              ← AuditPort 실패 시 fallback
│
├── scripts/                              ← 운영 스크립트
│   ├── init_db.sh                        ← psql로 init.sql 실행
│   ├── install.sh                        ← 의존성 설치
│   └── systemd/
│       └── atlas.service                 ← systemd 유닛 파일 템플릿
│
├── tests/                                ← 테스트 (atlas/ 구조 미러링)
│   ├── __init__.py
│   ├── conftest.py                       ← pytest 공통 fixture
│   │
│   ├── unit/                             ← 단위 테스트
│   │   ├── core/
│   │   │   ├── domain/
│   │   │   ├── nodes/
│   │   │   ├── risk/
│   │   │   └── fsm/
│   │   ├── adapters/
│   │   │   ├── broker/                   ← MockBroker 멱등성, 슬리피지
│   │   │   ├── market_data/
│   │   │   └── storage/
│   │   └── infrastructure/
│   │
│   ├── integration/                      ← 통합 테스트
│   │   ├── path1_e2e_backtest.py         ← CSVReplay → 전체 Path → InMemoryStorage
│   │   ├── crash_recovery.py             ← kill 후 재기동
│   │   └── halt_timing.py                ← 합격 기준 #4 (30초 내 차단)
│   │
│   ├── fixtures/                         ← 테스트 데이터
│   │   ├── ohlcv_samsung.csv
│   │   └── fake_kis_responses.json
│   │
│   └── acceptance/                       ← 합격 기준 5개 검증
│       ├── criterion_1_sharpe.py
│       ├── criterion_2_paper_5days.py
│       ├── criterion_3_pnl_logging.py
│       ├── criterion_4_halt_30s.py
│       └── criterion_5_crash_recovery.py
│
└── trading-system-design/                ← 설계 저장소 (git submodule 또는 별도 체크아웃)
    ← 별도 관리. 구현 저장소는 이것을 참조만.
```

---

## 3. 의존 방향 (Import Rules)

```
       ┌─────────────────────────────────────────────┐
       │                  cli/                       │
       │                    │                        │
       │                    ▼                        │
       │            infrastructure/                  │
       │                    │                        │
       │                    ▼                        │
       │  ┌──────────── core/ ─────────────┐         │
       │  │    nodes / risk / fsm / pipe   │         │
       │  │              │                 │         │
       │  │              ▼                 │         │
       │  │          core/domain/          │         │
       │  └────────────────────────────────┘         │
       │                    │                        │
       │                    ▼                        │
       │                 ports/                      │
       │                    ▲                        │
       │                    │                        │
       │              adapters/                      │
       └─────────────────────────────────────────────┘
```

**허용되는 import**

| from | 허용 import 대상 |
|------|---------------|
| `core/domain/` | 표준 라이브러리 + pydantic 만 |
| `core/nodes/` | `core/domain`, `ports/` |
| `core/risk/`, `core/fsm/` | `core/domain`, `ports/` |
| `core/pipeline/` | `core/nodes`, `core/domain`, `ports/` |
| `ports/` | `core/domain` 만 |
| `adapters/` | `ports/`, `core/domain`, 외부 라이브러리 |
| `infrastructure/` | `core/*`, `ports/`, `adapters/factory` |
| `cli/` | `infrastructure/`, `adapters/factory` (직접 호출 X) |

**금지되는 import** (Hexagonal 경계 위반)
- `core/` → `adapters/` (절대 금지)
- `ports/` → `adapters/` (절대 금지)
- `core/domain/` → `ports/` (절대 금지)

**위반 검증**: lint 단계에서 `import-linter` 적용. `pyproject.toml`에 규칙 선언.

---

## 4. 파일 책임 분리 원칙

| 유형 | 파일당 | 이유 |
|------|-------|------|
| Domain Type | 1 파일 = 복수 type 묶음 | 한 도메인(`market.py` = Quote+OHLCV+IndicatorBundle) |
| Node | 1 파일 = 1 노드 | 노드 경계 = 파일 경계 |
| Port | 1 파일 = 1 Port ABC | 설계 문서와 1:1 |
| Adapter | 1 파일 = 1 Adapter | 구현 상세가 파일 크기 150~300줄 |
| CLI 명령 | 1 파일 = 1 명령 그룹 | status/positions/pnl 같은 조회는 묶어도 됨 |

---

## 5. 명명 규칙

| 대상 | 규칙 | 예시 |
|------|------|------|
| 모듈 파일 | `snake_case.py` | `market_data_receiver.py` |
| 클래스 | `PascalCase` | `MarketDataReceiver` |
| 함수 / 변수 | `snake_case` | `get_current_price` |
| 상수 | `UPPER_SNAKE` | `DEFAULT_POOL_SIZE` |
| 비공개 | `_` 접두 | `_internal_queue` |
| Port ABC | `XxxPort` | `BrokerPort` |
| Adapter | `XxxAdapter` | `KISPaperBrokerAdapter` |
| Port 예외 | `XxxError` | `BrokerRejectError` |
| 테스트 파일 | `test_<모듈>.py` | `test_risk_guard.py` |

---

## 6. pyproject.toml 주요 의존성 (Phase 1)

```toml
[tool.poetry.dependencies]
python = "^3.11"
pydantic = "^2.6"
asyncpg = "^0.29"
httpx = "^0.27"
websockets = "^12.0"
pandas = "^2.2"
pandas-ta = "^0.3"
transitions = "^0.9"
apscheduler = "^3.10"
click = "^8.1"                 # CLI
tenacity = "^8.2"              # 재시도
holidays = "^0.45"             # 한국 공휴일
python-dateutil = "^2.9"

[tool.poetry.group.dev.dependencies]
pytest = "^8.0"
pytest-asyncio = "^0.23"
pytest-cov = "^4.1"
import-linter = "^6.0"         # 의존 방향 검증
ruff = "^0.3"                  # lint + format
mypy = "^1.9"
```

**Phase 2-0 추가 예정**: `fastapi`, `uvicorn`, `websockets`, `aiogram` (Telegram Bot), `prometheus-client`, `httpx`

**Phase 2 추가 예정**: `redis`, `alembic` (DB migration)

---

## 7. 설정 파일 찾기 우선순위

Boot 시퀀스에서 `config.yaml`을 찾는 순서:

1. `ATLAS_CONFIG_PATH` 환경변수로 지정된 경로
2. `./config/config.yaml` (프로젝트 루트 기준)
3. `~/.config/atlas/config.yaml`
4. `/etc/atlas/config.yaml`

**없으면 기동 실패 (critical)**. 환경변수는 YAML을 찾은 후 개별 키 오버라이드에만 사용.

---

## 8. systemd 통합 (운영 시)

```ini
# scripts/systemd/atlas.service
[Unit]
Description=ATLAS Automated Trading System
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=atlas
Group=atlas
WorkingDirectory=/opt/atlas
Environment="ATLAS_CONFIG_PATH=/etc/atlas/config.yaml"
EnvironmentFile=/etc/atlas/atlas.env
ExecStart=/opt/atlas/.venv/bin/atlas start
ExecStop=/opt/atlas/.venv/bin/atlas stop
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
```

**Phase 1**: 수동 실행 (`atlas start` 직접). systemd는 선택사항.
**Phase 2**: systemd 운영 기본.

---

## 9. .gitignore 핵심 항목

```gitignore
# Python
__pycache__/
*.py[cod]
*.egg-info/
.venv/

# 설정 및 비밀
config/config.yaml
config/watchlist.yaml
.env
.env.local

# 런타임 데이터
data/
logs/

# 테스트
.pytest_cache/
.coverage
htmlcov/

# IDE
.vscode/
.idea/

# OS
.DS_Store
Thumbs.db

# PID / control files (local dev)
/var/run/atlas.*
```

---

## 10. 구현 착수 순서 (폴더 생성 → 코드 채우기)

구현 시작 시 권장 순서:

```
Step 1: 저장소 + 인프라 (1~2시간)
  - atlas/ 저장소 초기화, pyproject.toml, .gitignore
  - docker-compose.yml (PostgreSQL), db/init.sql 적용
  - config/config.example.yaml 작성

Step 2: Core/Domain (반나절)
  - core/domain/ 20개 타입 (pydantic 모델)
  - tests/unit/core/domain/ 동시 작성

Step 3: Ports (반나절)
  - ports/*.py 6개 ABC + exceptions.py

Step 4: Adapters — Mock 우선 (1일)
  - MockBroker / InMemoryStorage / HistoricalClock / CSVReplay / StdoutAudit
  - adapters/factory.py

Step 5: Core/Nodes (2~3일)
  - 6개 노드 + core/risk (7체크) + core/fsm
  - tests/integration/path1_e2e_backtest.py 가 돌면 Step 5 완료

Step 6: Infrastructure + CLI (1~2일)
  - config_loader, boot_sequence, signal_handlers
  - atlas start/stop/halt/status 구현

Step 7: Real Adapters (2~3일)
  - KISWebSocketAdapter, KISRestAdapter, KISPaperBrokerAdapter
  - PostgresStorageAdapter, PostgresAuditAdapter

Step 8: Acceptance 테스트 (1일)
  - 합격 기준 5개 자동 검증 스위트

총 예상: 2주 내외 (풀타임 기준).
```

---

## 11. 변경 이력

| 날짜 | 버전 | 변경 |
|------|------|------|
| 2026-04-17 | v1.0 | Phase 1 최초 작성. Hexagonal 3층 + CLI/Infra/Tests 전체 트리 + 의존 방향 규칙 + 구현 착수 순서. |
| 2026-04-17 | v1.1 | 4차 검증: enums.py 설명에 OrderType 추가 (Domain Types 20개 완전 커버). |

---

*Phase 1 프로젝트 폴더 구조 — atlas/ 패키지 + 7 최상위 폴더 + Hexagonal 의존 방향 보장*

---

## Phase 2-0 추가 폴더 구조

Phase 1 합격 기준 5개 통과 후 아래 구조를 추가한다.

```
atlas/
├── api/                              ← Phase 2-0 신규
│   ├── __init__.py
│   ├── main.py                       ← FastAPI app, uvicorn 포트 8000
│   ├── dependencies.py               ← DB 세션·설정 의존성 주입
│   ├── routers/
│   │   ├── __init__.py
│   │   ├── status.py                 ← GET /api/status · /health · /audit
│   │   ├── trading.py                ← GET /api/positions · /pnl · /orders
│   │   ├── control.py                ← POST /api/control/halt|resume|stop
│   │   ├── config.py                 ← GET/POST /api/config
│   │   ├── strategies.py             ← GET/POST /api/strategies/{name}
│   │   ├── backtest.py               ← POST /api/backtest
│   │   ├── approvals.py              ← GET/POST /api/approvals
│   │   └── rules.py                  ← GET/POST /api/rules
│   ├── websockets/
│   │   ├── __init__.py
│   │   ├── fsm_stream.py             ← WS /ws/fsm
│   │   └── orders_stream.py          ← WS /ws/orders
│   └── static/
│       ├── index.html
│       ├── control.html
│       ├── policy.html
│       ├── strategy.html
│       ├── notify.html
│       └── rules.html
│
└── adapters/
    └── telegram/                     ← Phase 2-0 신규
        ├── __init__.py
        └── bot.py                    ← aiogram Bot

grafana/                              ← Phase 2-0 신규 (저장소 루트)
├── dashboards/
│   ├── overview.json
│   ├── p1_monitor.json
│   ├── market_data.json
│   ├── health.json
│   └── system.json
└── provisioning/
    ├── datasources/postgres.yaml
    └── dashboards/default.yaml
```

**docker-compose.yml Phase 2-0 추가 서비스**

```yaml
services:
  # 기존 유지
  postgres: ...

  # Phase 2-0 추가
  grafana:
    image: grafana/grafana:latest
    ports: ["3000:3000"]

  prometheus:
    image: prom/prometheus:latest
    ports: ["9090:9090"]

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
```
