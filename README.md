# ATLAS — Automated Trading & Learning Algorithm System

**Korean stock market automated trading system** built on KIS (Korea Investment & Securities) Open API.

---

## 현재 Phase

> **Phase 1 (설계 통폐합 완료, 구현 착수 전)**
> **날짜**: 2026-04-16
> **범위 문서**: [`docs/decisions/011-phase1-scope.md`](docs/decisions/011-phase1-scope.md)

---

## Phase 1 한 줄 정의

**"MockBroker 위에서 단일 전략의 E2E 사이클을 완주하고, 모의투자 계좌로 동일 코드가 무사고 동작함을 증명한다."**

Phase 1 합격 기준 5개를 모두 충족하면 Phase 2로 진입한다.

---

## Phase 1 구조 (한 장 요약)

```
┌─────────────────────────────────────────────────────────────┐
│                        Path 1 (6 nodes)                     │
│                                                             │
│   KIS WS/REST ─► MarketDataReceiver                         │
│                       │                                     │
│                       ▼                                     │
│                  IndicatorCalculator                        │
│                       │                                     │
│                       ▼                                     │
│                  StrategyEngine  ◄── strategies/*.py        │
│                       │                                     │
│                       ▼                                     │
│                    RiskGuard (Pre-Order 7 checks)           │
│                       │                                     │
│                       ▼                                     │
│                  OrderExecutor ◄──► TradingFSM (6 states)   │
│                       │                                     │
│                       ▼                                     │
│                KIS Broker (mock | kis_paper)                │
└─────────────────────────────────────────────────────────────┘
            │                    │                    │
            ▼                    ▼                    ▼
    MarketDataStore      PortfolioStore          AuditStore
      (market_ohlcv)      (positions,            (audit_events,
                           trades,                order_tracker)
                           daily_pnl)
```

**제외 (Phase 2+)**: Screener / WatchlistManager / MarketContext / LLM / Knowledge Graph / Telegram / Grafana / ApprovalGate / Code Generator / Path 2~6 전체

---

## Tech Stack

| 구분 | 기술 |
|------|------|
| 언어 | Python 3.11+ |
| Async | asyncio |
| FSM | transitions |
| 지표 | pandas-ta |
| 검증 | pydantic v2 |
| DB | PostgreSQL 16 + TimescaleDB |
| Cache | Redis (Phase 2 분리) |
| 스케줄러 | APScheduler |
| 배포 | Docker Compose |

---

## Quickstart (Phase 1 구현 시작 후)

```bash
# 1. DB 기동
docker compose up -d postgres

# 2. 스키마 적용
psql -U atlas -d atlas -f docs/specs/db-schema-phase1.sql

# 3. 설정 파일 편집
cp config/config.example.yaml config/config.yaml
vim config/config.yaml          # broker, watchlist, strategy 지정

# 4. 백테스트
atlas backtest strategies/ma_crossover.py --period 2024-01-01:2025-12-31

# 5. 모의투자 시작
atlas start
```

---

## 문서 지도

**먼저 읽기**:
1. [`docs/decisions/011-phase1-scope.md`](docs/decisions/011-phase1-scope.md) — **Phase 1 범위 (모든 문서의 기준)**
2. [`INDEX.md`](INDEX.md) — 전체 문서 지도
3. [`docs/architecture/system-overview.md`](docs/architecture/system-overview.md) — 시스템 개요

**설계 상세**:
- [`docs/architecture/path1-phase1.md`](docs/architecture/path1-phase1.md) — Path 1 6노드 상세
- [`docs/architecture/cli-design.md`](docs/architecture/cli-design.md) — `atlas` CLI 설계
- [`docs/architecture/fsm-design.md`](docs/architecture/fsm-design.md) — TradingFSM 설계
- [`docs/architecture/db-stack.md`](docs/architecture/db-stack.md) — DB 선정 이유

**명세**:
- [`docs/specs/domain-types-phase1.md`](docs/specs/domain-types-phase1.md) — Domain Types 20개
- [`docs/specs/db-schema-phase1.sql`](docs/specs/db-schema-phase1.sql) — 실행 가능 DDL

**파이프라인**:
- [`docs/pipelines/data-collection.md`](docs/pipelines/data-collection.md)
- [`docs/pipelines/backtesting.md`](docs/pipelines/backtesting.md)

**Archive (Phase 2+)**:
- [`docs/archive/README.md`](docs/archive/README.md) — 연기된 문서들의 설명

---

## 설계 철학

1. **Plug & Play** — YAML 한 줄로 Broker·Adapter 교체, Edge 계약 유지 시 노드 교체 가능
2. **Role Separation** — 전략엔진=뇌(결정적·백테스트가능), KIS=손(실행만), LLM=참모(판단주체 아님, Phase 3에서)
3. **완벽한 설계는 불가** — 나중에 빠진 것을 **끼워넣을 수 있는 구조**가 핵심
4. **Living Snapshot Documents** — 상류 문서가 진실의 원천, 하류는 그것에서 파생

---

## Phase 1 합격 기준 (요약)

1. 백테스트 샤프 > 1.0
2. 모의투자 5거래일 무사고
3. 일일 손익 자동 기록
4. `atlas halt` 30초 내 신규 주문 차단
5. Crash 후 포지션 정상 복원

전부 통과하면 **Phase 2**로 진입한다.

---

## 라이선스 및 주의

- 개인 프로젝트. 재사용 시 저자 책임 없음.
- Phase 1은 **실전 자금 절대 투입 금지**. 모의투자(KIS paper)까지만.
- 실전 전환은 Phase 2D에서 별도 결정 프로세스를 거친다.

---

*Last updated: 2026-04-16*
