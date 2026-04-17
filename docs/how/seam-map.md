# Seam Map: 방법론 어휘 → 저장소 파일·코드 위치 매핑

> **목적**: 방법론 어휘(Filter, Seam, Port, Adapter, Stub)를 저장소의 실제 파일, 코드 위치, YAML 키와 1:1 매핑한다.
> **층**: How

**범위**: Phase 1 (Path 1의 6노드 + 6 Port + 12 Adapter).
**갱신 원칙**: Stub이 Real로 교체될 때마다 "현재 Status" 컬럼 갱신.

---

## 1. Filter — 6노드

| Filter | 파일 경로 | 주 책임 | Port 의존 | Status |
|--------|---------|---------|-----------|--------|
| MarketDataReceiver | `core/nodes/market_data.py` | 시장 봉 공급 | MarketDataPort | stub |
| IndicatorCalculator | `core/nodes/indicator.py` | 기술적 지표 계산 | — | stub |
| StrategyEngine | `core/nodes/strategy.py` | 매매 신호 생성 | StrategyRuntimePort | stub |
| RiskGuard | `core/nodes/risk_guard.py` | 주문 전 리스크 체크 | StoragePort | stub |
| OrderExecutor | `core/nodes/order_executor.py` | 주문 실행 | BrokerPort, StoragePort, AuditPort | stub |
| TradingFSM | `core/fsm/trading_fsm.py` | 거래 상태 머신 | StoragePort, AuditPort | stub |

**Orchestrator**: `core/orchestrator.py` — 6 Filter 순서 호출, Port만 의존.

## 2. Port — 6 Port ABC (`port-signatures-phase1.md` SSoT)

| Port | SSoT 위치 | 주요 메서드 | Adapter 수 |
|------|---------|-----------|----------|
| MarketDataPort | `port-signatures-phase1.md §3.1` | `subscribe`, `unsubscribe`, `get_bar` | 3 |
| BrokerPort | `port-signatures-phase1.md §3.2` | `submit_order`, `cancel_order`, `get_fills` | 2 |
| StoragePort | `port-signatures-phase1.md §3.3` | `save_order`, `save_fill`, `get_positions`, `get_daily_pnl` | 2 |
| ClockPort | `port-signatures-phase1.md §3.4` | `now`, `sleep` | 2 |
| StrategyRuntimePort | `port-signatures-phase1.md §3.5` | `load_strategy`, `evaluate` | 1 |
| AuditPort | `port-signatures-phase1.md §3.6` | `log_event`, `query_events` | 2 |

## 3. Seam — 교체 가능 지점 (Object Seam)

| Seam ID | 위치 | 호출 Port | 호출 시점 |
|---------|------|----------|---------|
| S-MD-1 | `orchestrator.py` — 매 tick | MarketDataPort.get_bar() | 봉 수신 |
| S-BR-1 | `order_executor.py` — 주문 시 | BrokerPort.submit_order() | 주문 발생 |
| S-BR-2 | `order_executor.py` — halt 시 | BrokerPort.cancel_order() | halt |
| S-ST-1 | `order_executor.py` — 영속화 | StoragePort.save_order() | 주문 후 |
| S-ST-2 | `trading_fsm.py` — 전이 시 | StoragePort (전이 기록) | FSM 전이 |
| S-ST-3 | `risk_guard.py` — 체크 시 | StoragePort.get_positions() | 리스크 |
| S-CK-1 | `orchestrator.py` — 루프 | ClockPort.now() | 매 tick |
| S-AU-1 | `risk_guard.py` — 거부 시 | AuditPort.log_event() | 거부 |
| S-AU-2 | `trading_fsm.py` — ERROR 시 | AuditPort.log_event() | 에러 |
| S-SR-1 | `strategy.py` — 전략 로드 | StrategyRuntimePort.load_strategy() | 부팅 |

## 4. Adapter — 12 Adapter (`adapter-spec-phase1.md` SSoT)

| Port | Adapter (저장소 공식 이름) | SSoT 위치 | 용도 | Step |
|------|--------------------------|---------|------|------|
| MarketDataPort | KISWebSocketAdapter | `adapter-spec §4.1` | 실시간 (Phase 2) | — |
| MarketDataPort | KISRestAdapter | `adapter-spec §4.2` | 폴링 (Phase 2) | — |
| MarketDataPort | CSVReplayAdapter | `adapter-spec §4.3` | 백테스트 CSV 리플레이 | 3 |
| BrokerPort | MockBrokerAdapter | `adapter-spec §5.1` | Mock 체결 시뮬레이션 | 7 |
| BrokerPort | KISPaperBrokerAdapter | `adapter-spec §5.2` | 모의투자 실제 연결 | 11b |
| StoragePort | PostgresStorageAdapter | `adapter-spec §6.1` | DB 영속화 | 9 |
| StoragePort | InMemoryStorageAdapter | `adapter-spec §6.2` | Step 0~8 pass-through | 0 |
| ClockPort | WallClockAdapter | `adapter-spec §7.1` | 실제 시계 | 0 |
| ClockPort | HistoricalClockAdapter | `adapter-spec §7.2` | 백테스트용 시간 제어 | 2 |
| StrategyRuntimePort | FileSystemStrategyLoader | `adapter-spec §8.1` | strategies/*.py 로드 | 5 |
| AuditPort | PostgresAuditAdapter | `adapter-spec §9.1` | DB 감사 로그 | 9 |
| AuditPort | StdoutAuditAdapter | `adapter-spec §9.2` | Step 0 기본 콘솔 출력 | 0 |

**Phase 1 Stub용 FakeAdapter** (저장소에 없으나 Step 0~2에서 생성):
- inline stub (Step 0) — Step 0~2용 고정 Bar 반환 (Step 3에서 CSVReplayAdapter로 교체)
- inline stub (Step 0) — Step 0~6용 즉시 체결 (Step 7에서 MockBrokerAdapter로 교체)

### Enabling Point — `config/config.yaml` (`config-schema-phase1.md` SSoT)

```yaml
broker:
  adapter: mock         # mock | kis_paper
market_data:
  adapter: csv_replay   # csv_replay | kis_ws | kis_rest
storage:
  adapter: postgres     # memory | postgres
clock:
  adapter: wall         # wall | historical
audit:
  adapter: stdout       # stdout | postgres
```

## 5. Stub 현황 (Phase 1 착수 전)

| 위치 | 현재 내용 | 교체 Step | 교체 후 |
|------|---------|---------|--------|
| market_data | 고정 Bar 1개 | Step 3 | CSVReplayAdapter |
| indicator | sma = bar.close | Step 4 | pandas-ta SMA(20) |
| strategy | return BUY | Step 5 | SMA 골든크로스 |
| risk_guard | return True | Step 6,10a,10b | 7체크 로직 |
| order_executor | print() | Step 7 | MockBrokerAdapter.submit_order() |
| trading_fsm | 2상태 | Step 8a,8b | 13상태 (개별 종목 FSM) |
| storage | dict | Step 9 | PostgresStorageAdapter |
| audit | print() | Step 9 | PostgresAuditAdapter |

## 6. 매 Step 종료 후 갱신 절차

1. §1 Filter Status 갱신 (`stub` → `real`)
2. §4 Adapter 테이블에 신규 Adapter 추가 (해당 시)
3. §5 Stub 목록에서 교체 완료 항목 제거
4. Step 커밋의 일부로 포함

## 7. 관련 문서

- `docs/how/methodology.md` — 방법론 (상위)
- `docs/what/specs/port-signatures-phase1.md` — Port 시그니처 SSoT
- `docs/what/specs/adapter-spec-phase1.md` — Adapter 명세 SSoT
- `docs/what/specs/config-schema-phase1.md` — 설정 스키마 SSoT
- `docs/what/architecture/path1-design.md` — 6노드 설계
- `graph_ir_phase1.yaml` — 노드/엣지 정식 정의
