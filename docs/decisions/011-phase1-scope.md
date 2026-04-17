# Phase 1 Scope — 확정본 (Source of Truth)

> **구현 여정**: 이 문서의 범위와 합격 기준은 ADR-012에 정의된 17 Step으로 점진 구현됩니다. 각 Step의 실행 절차는 docs/runbooks/step-NN.md 참조.
> **상태**: stable
> **확정일**: 2026-04-16
> **위치**: `docs/decisions/011-phase1-scope.md` (예정)
> **우선순위**: 이 문서와 다른 문서가 충돌하면 이 문서가 우선한다

---

## 1. Phase 1 한 줄 정의

> **"MockBroker 위에서 단일 전략의 E2E 사이클을 완주하고, 모의투자 계좌로 동일 코드가 무사고 동작하는 것을 증명한다."**

---

## 2. 확정 선택지

| 항목 | 선택 | 의미 |
|------|------|------|
| 성공 정의 | **A** | 전략이 수익을 낸다는 증명 (샤프 > 1.0) |
| 제어 수단 | **α** | CLI 도구 (`atlas start/stop/status`) |
| 자금 범위 | **II** | 모의투자 계좌까지. 실전 투자는 Phase 2 |

---

## 3. Phase 1 포함 범위 (7개)

### 3.1 데이터 레이어
- PostgreSQL 16 + TimescaleDB + pgvector + AGE 세팅
- Docker Compose 구성
- 최소 스키마: `market_ohlcv`, `trades`, `positions`, `daily_pnl`, `audit_events`, `order_tracker`
- 기타 테이블(28개)은 Phase 2 이후

### 3.2 시세 수집
- KIS REST API 기반 OHLCV 수집기
- 일봉 + 분봉(1분/5분)
- APScheduler cron 스케줄
- rate limit 준수(초당 18건)
- 수동 선택 3~5 종목만 대상 (Screener 없음)

### 3.3 MockBroker + ClockPort
- 과거 OHLCV를 리플레이하여 체결 시뮬레이션
- 다음 봉 시가 체결, 슬리피지(bps) 설정
- KIS/Kiwoom 실제 수수료율 반영
- `broker: mock` YAML 한 줄로 활성화

### 3.4 Path 1 최소 노드 (6개)
```
MarketDataReceiver → IndicatorCalculator → StrategyEngine
                                              ↓
                                          RiskGuard
                                              ↓
                                         OrderExecutor ← → TradingFSM
```

- **MarketDataReceiver** — KIS WebSocket + REST fallback, 수동 지정 종목만
- **IndicatorCalculator** — pandas-ta, 종목별 200봉 버퍼
- **StrategyEngine** — 수동 전략 1~2개 로드, MarketContext 없음
- **RiskGuard** — Pre-Order 체크 **7항목만** (Phase 1 전용 축소판)
- **OrderExecutor** — 주문 + 체결통보 + Circuit Breaker
- **TradingFSM** — Idle/EntryPending/InPosition/ExitPending/Error/SafeMode 6상태

### 3.5 수동 전략 파일
```
strategies/
├── ma_crossover.py    # 5-20 이동평균 교차
└── rsi_reversion.py   # RSI 과매도 반등
```
- `BaseStrategy` 상속, `evaluate(indicators, context) -> SignalOutput`
- LLM 생성 없음
- StrategyLoader가 파일시스템에서 직접 import
- hot reload 없음

### 3.6 CLI 제어 도구
```bash
atlas start           # 시스템 시작
atlas stop            # 정상 종료
atlas halt            # 긴급 정지 (30초 내 신규 주문 차단)
atlas status          # 현재 상태 출력
atlas positions       # 보유 포지션 출력
atlas pnl [--today]   # 손익 조회
atlas backtest <file> # 백테스트 실행
```
- Python argparse + asyncio
- SSH로 접속해서 사용
- 인증은 OS 사용자 레벨(jdw)

### 3.7 감사 로그
- `audit_events` 테이블 (append-only, 불변 트리거)
- 주문·체결·상태전이·리스크위반·시스템시작/종료 기록
- Grafana 없음 — SQL로 직접 조회
- `correlation_id`로 E2E 체인 추적

---

## 4. Phase 1 제외 범위 (명시)

**이 목록에 있는 것은 Phase 1에서 단 한 줄도 구현하지 않는다.**

| 제외 | 원래 계획 | Phase 1 대체 | 언제 |
|------|----------|-------------|------|
| Screener | 전 종목 조건 필터링 | 수동으로 3~5종목 선정 | Phase 2 |
| WatchlistManager | 8단계 상태 전이 허브 | 없음 (종목 리스트 고정) | Phase 2 |
| SubscriptionRouter | Tier 1/2 동적 관리 | 고정 종목 WebSocket 구독 | Phase 2 |
| PositionMonitor (1C) | 틱별 실시간 갱신 | OrderExecutor가 체결 시 1회 계산 | Phase 2 |
| ExitConditionGuard | 6종 청산 조건 감시 | 전략 내부에서 손절/익절 직접 판단 | Phase 2 |
| ExitExecutor | 청산 → 1B 재진입 | 전략이 매도 SignalOutput 직접 생성 | Phase 2 |
| Path 2 전체 | Knowledge Building | 없음 | Phase 3 |
| Path 3 자동 생성 | 전략 코드 LLM 생성 | 수동 `.py` | Phase 3 |
| Path 3 Optimizer | Optuna 파라미터 최적화 | 수동 튜닝 | Phase 2 |
| Path 4 전체 | Portfolio Management | RiskGuard 내장 간이 체크 | Phase 2 |
| Path 6 전체 | Market Intelligence | 없음 (MarketContext 없이 동작) | Phase 2 |
| Telegram Bot | S7 운영 인터페이스 | CLI | **Phase 2-0** (긴급 제어 채널) |
| Discord | 알림 채널 | `audit_events` SQL 조회 | Phase 2 |
| Grafana S1 대시보드 | Path 6 + 포트폴리오 시각화 | 없음 | **Phase 2-0** (UI 인프라 선행) |
| ApprovalGate | SEMI_AUTO 비동기 승인 | AUTO 또는 MANUAL만 | 필요시 |
| SEMI_AUTO 모드 | 3-Mode 중 중간 | AUTO 또는 MANUAL만 | 필요시 |
| Knowledge Fast-Path (R3) | 긴급 뉴스 반응 | 없음 | Phase 3 |
| LangGraph + checkpointer | LLM 상태 영속화 | LLM 자체 없음 | Phase 3 |
| PathCanvas UI | LiteGraph.js 캔버스 | YAML 수동 편집 | Phase 2+ |
| Code Generator | Graph IR → 코드 생성 | 수동 코딩 | Phase 2+ |
| KISAPIGateway | API Rate Limit 중앙 관리 | 간단한 asyncio.Semaphore(18) | Phase 2 |
| Kiwoom 듀얼 브로커 | KIS + Kiwoom 이중화 | KIS만 | Phase 2 |

---

## 5. Phase 1 합격 기준 (5개)

**모든 기준을 충족해야 Phase 2로 넘어간다.**

| # | 기준 | 검증 방법 |
|---|------|----------|
| 1 | 백테스트에서 전략 1개가 **샤프 비율 > 1.0** 달성 | `atlas backtest strategies/ma_crossover.py --period 2024-01-01:2025-12-31` 실행 후 result.json 확인 |
| 2 | 모의투자 환경에서 동일 코드로 **5거래일 연속 무사고** 동작 | `audit_events`에서 severity='error' 이상 0건 |
| 3 | 장 마감 시 **미체결 주문 자동 취소 + 일일 손익 자동 기록** | `daily_pnl` 테이블에 매일 1행 자동 insert |
| 4 | 장중 `atlas halt` 실행 시 **30초 이내 신규 주문 차단** | halt 실행 시각 vs 마지막 주문 시각 diff < 30s |
| 5 | 프로세스 강제 종료 후 재시작 시 **포지션 상태 정상 복원** | crash 직전 `positions` 테이블과 재시작 후 TradingFSM 상태 일치 |

---

## 6. Phase 1 노드·엣지·Port 수치

| 항목 | 수 | 비고 |
|------|----|----|
| Nodes | **6** | MarketDataReceiver, IndicatorCalculator, StrategyEngine, RiskGuard, OrderExecutor, TradingFSM |
| Ports | **6** | MarketDataPort, BrokerPort, StoragePort, ClockPort, StrategyRuntimePort(파일 로드), AuditPort |
| Shared Stores | **3** | MarketDataStore, PortfolioStore, AuditStore (ConfigStore는 YAML 파일로 대체) |
| Edges | **약 12** | Path 1 내부만. Cross-Path 없음 |
| Domain Types | **약 20** | Quote, OHLCV, OrderRequest, OrderResult, TradeRecord, Position, SignalOutput 등 |
| Adapters (Primary) | **6** | KISWebSocketAdapter, KISRestAdapter, MockBrokerAdapter, PostgresStorageAdapter, KRXClockAdapter, PostgresAuditAdapter |
| Adapters (Mock) | **6** | 모든 Port에 대응하는 Mock |
| Validation Rules | **약 10** | Phase 1에 해당하는 것만 |

---

## 7. 구현 순서 (Phase 1 내부)

기존 "화면 → Code Generator → 경로별 구현"은 **폐기**. Phase 1은 다음 순서:

### Step 0: 설계 문서 통폐합 (선행 작업)
- Patch v2.0을 원본 문서에 반영 또는 **Phase 1 범위 밖은 archive로 이동**
- `graph_ir_v1.0.yaml`을 Phase 1 범위로 축소해서 실제 내용으로 채움
- INDEX.md를 Phase 1 중심으로 재작성

### Step 1: 기반 (1~2주)
- Docker Compose (postgres + redis)
- 최소 DB 스키마 (6개 테이블)
- Python 프로젝트 구조 (`core/domain/`, `adapters/`, `strategies/`, `cli/`)
- Domain Types 정의 (`core/domain/`)
- Port ABC 정의 (`core/ports/`)

### Step 2: Mock 파이프라인 (1~2주)
- MockBrokerAdapter
- HistoricalClockAdapter (과거 데이터 리플레이)
- CSVHistoryAdapter (로컬 CSV 기반)
- 전략 1개 (`ma_crossover.py`)
- 백테스트 CLI (`atlas backtest`)
- **검증**: 과거 데이터로 샤프 계산 가능

### Step 3: 수집기 (1주)
- KISRestAdapter (인증 + OHLCV 조회)
- APScheduler 스케줄러
- `market_ohlcv` 테이블 적재
- **검증**: 3종목 × 6개월 OHLCV 수집 완료

### Step 4: Path 1 실행 엔진 (2~3주)
- MarketDataReceiver (KISWebSocketAdapter + REST fallback)
- IndicatorCalculator (pandas-ta)
- StrategyEngine (파일 로드)
- RiskGuard (Pre-Order 7항목)
- OrderExecutor (OrderTracker + Circuit Breaker)
- TradingFSM (transitions)
- AuditLogger (append-only)
- **검증**: MockBroker로 E2E 1회 성공

### Step 5: CLI + 운영 (1주)
- `atlas start/stop/halt/status/positions/pnl/backtest`
- Boot/Shutdown 시퀀스 (축약판)
- Crash Recovery 최소 구현
- **검증**: 합격 기준 #4, #5 통과

### Step 6: 모의투자 연결 (1주)
- `broker: mock → kis_paper` 전환
- KIS demo 계좌 연결 확인
- 체결통보 WebSocket 구독
- **검증**: 모의투자 1거래일 동작

### Step 7: 5거래일 안정화 (1주)
- 5거래일 연속 동작 관찰
- 발견되는 버그 수정
- **검증**: 합격 기준 전체 5개 충족 → Phase 1 완료

---

## 8. Phase 1 예상 기간

| 구분 | 기간 | 비고 |
|------|------|------|
| Step 0 (통폐합) | 3~5일 | 지금 착수할 작업 |
| Step 1~7 (구현) | 8~11주 | 풀타임 기준 |
| 총 | 약 2.5~3개월 | 1인 프로젝트 + vibe coding |

---

## 9. Phase 2 진입 조건

Phase 1 합격 기준 5개 모두 충족 후, **반드시 2-0부터 시작**:

### Phase 2-0: UI 인프라 (선행 필수)

Phase 2A~D의 기능을 화면에서 보려면 반드시 2-0이 선행되어야 한다.

| 항목 | 내용 |
|------|------|
| FastAPI 서버 | `atlas/api/` — REST 14개 + WebSocket 2개 엔드포인트 |
| Grafana | PostgreSQL 직결 — 읽기 전용 모니터링 패널 |
| HTML 제어 화면 | FastAPI `/static/` 서빙 — 버튼/폼 (HALT, Policy, Strategy) |
| Telegram Bot | 긴급 제어 + 승인 — `/halt`, `/approve`, 체결 알림 |

**설계 문서**: `graph_ir_phase1.yaml` §api_layer, §frontend_stack

**React 전환 경로**: HTML static/ → React build 교체. FastAPI API 무변경.

### Phase 2A~D (기존)

- **Phase 2A**: Path 6 (Market Intelligence) 추가 — 수급/호가/VI 반영
- **Phase 2B**: Path 4 (Portfolio Management) 추가 — 다종목·다전략 관리
- **Phase 2C**: Screener + WatchlistManager 추가 — 종목 자동 선정
- **Phase 2D**: 실전 전환 — KIS live 계좌 소액 운용

권장 순서: **2-0 → 2A → 2B → 2C → 2D** (안전성 우선)

---

## 10. 이 문서의 역할

1. **범위의 진실의 원천** — Phase 1 여부 판단 시 이 문서만 본다
2. **통폐합 작업의 기준** — 기존 18개 설계 문서를 이 범위에 맞춰 재구성
3. **Phase 2 진입 기준** — Section 5의 합격 기준이 유일한 게이트
4. **변경 불가** — Phase 1 진행 중 이 문서는 수정하지 않는다. 수정이 필요하면 Phase 1을 중단하고 재결정

---

*End of Document — Phase 1 Scope (Confirmed)*
*다음 작업: Step 0 (설계 문서 통폐합)*
