# 수치 파이프라인 — Phase 1

> **층**: What
> **상태**: stable
> **최종 수정**: 2026-04-19
> **SSoT**: [`graph_ir_phase1.yaml`](../../../graph_ir_phase1.yaml) v1.1.0
> **기반 문서**: [`path1-design.md`](../architecture/path1-design.md), [`fsm-design.md`](../architecture/fsm-design.md), ADR-012, ADR-013
> **목적**: Phase 1 거래 실행 경로(Path 1)의 데이터 플로우·실패 모드·계약을 한곳에 기술한다.

## 1. 스코프 명시

이 문서는 Phase 1에서 **실제로 구현되는 7노드 / 18엣지 / 8포트**만 다룬다. Phase 2+ 6노드 (Screener, WatchlistManager, SubscriptionRouter, PositionMonitor, ExitConditionGuard, ExitExecutor)는 [`path1-design.md`](../architecture/path1-design.md) §2.1에서 별도 확인.

## 2. 데이터 플로우

```
                            ┌──────────────────────────┐
                            │   KIS API (외부 경계)      │
                            └──────┬────────────┬──────┘
                        WS/HTTP    │            │  체결 WS
                                   ▼            ▼
                          ┌─────────────┐  ┌───────────────────┐
                          │ MarketData  │  │ ExecutionEvent    │
                          │ Port        │  │ Port  (ADR-013)   │
                          └──────┬──────┘  └─────────┬─────────┘
                                 │ e01:raw_tick       │ e15:execution_event
                                 ▼                     ▼
                          ┌──────────────┐      ┌────────────────┐
                          │ MarketData   │      │ Execution      │
                          │ Receiver     │      │ Receiver       │
                          │ (스트림+폴링) │      │ (ADR-013 신설) │
                          └──────┬───────┘      └────────┬───────┘
                        e02:quote_stream         e16/e17/e18 ─┐
                                 ▼                            │
                          ┌──────────────┐                    │
                          │ Indicator    │                    │
                          │ Calculator   │                    │
                          │ (ring buf×200)│                   │
                          └──────┬───────┘                    │
                        e03:indicator_bundle                   │
                                 ▼                             │
      ┌───[e04: position_snapshot (ConfigRef)]──┐             │
      │   from PortfolioStore                   │             │
      │                                         ▼             │
      │                                  ┌──────────────┐    │
      │                                  │ Strategy     │    │
      │                                  │ Engine       │    │
      │                                  │ (strategies/ │    │
      │                                  │  *.py · 1개) │    │
      │                                  └──────┬───────┘    │
      │                              e05:signal_output       │
      │                                         ▼             │
      │  ┌──[e06: portfolio_snapshot (ConfigRef)]─┐           │
      │  │  from PortfolioStore                    │          │
      │  │                                         ▼          │
      │  │                                  ┌──────────────┐ │
      │  │                                  │ RiskGuard    │ │
      │  │                                  │ Pre-Order    │ │
      │  │                                  │ 8체크        │ │
      │  │                                  └──────┬───────┘ │
      │  │                            e07:approved_signal     │
      │  │                        e08:rejection_event         │
      │  │                                         ▼          │
      │  │                                  ┌──────────────┐ │
      │  │                                  │ Order        │ │
      │  │                                  │ Executor     │ │
      │  │                                  │ (요청만)      │ │
      │  │                                  └───┬─────┬────┘ │
      │  │                          e09:order_request        │
      │  │                          e10:order_ack            │
      │  │                          e11:order_audit          │
      │  │                                ▼     ▼     ▼      │
      │  │                          OrderPort   │     │      │
      │  │                                      │     │      │
      │  │                                      ▼     ▼      │
      │  │                              ┌──────────────────┐ │
      │  │                              │  TradingFSM      │◄┤ e16
      │  │                              │  6상태·12전이    │ │
      │  │                              └───┬──────┬───────┘ │
      │  │                          e12:state_transition    │
      │  │                          e13:fsm_audit            │
      │  │                          e14:halt_signal(←cli)    │
      │  │                                 ▼      ▼           │
      │  ▼                                 │      │           │
      │  │                                 │      │           │
      └──┼─────────────────────────────────┘      │           │
         │                                         ▼           │
         │   ┌──────────────────────────────────────────┐     │
         └──►│      PortfolioStore (Shared Store)        │◄───┘
             │   [positions · trades · daily_pnl]         │  e17
             └──────────────────────────────────────────┘
                                       
             ┌──────────────────────────────────────────┐
             │      AuditStore (Shared Store)            │
             │   [audit_events · order_tracker]           │
             └──────────────────────────────────────────┘
                  ▲   e08    e11   e13   e18
                  └────┴─────┴─────┴─────┘

             ┌──────────────────────────────────────────┐
             │      MarketDataStore (Shared Store)       │
             │   [market_ohlcv]                           │
             └──────────────────────────────────────────┘
                  ▲ MarketDataReceiver writes
                  │ IndicatorCalculator/backtest_cli reads
```

## 3. 노드 7개 — graph_ir_phase1.yaml 정규 정의

| # | 노드 | runMode | 주요 Port | 책임 |
|---|------|---------|-----------|------|
| 1 | MarketDataReceiver | `stream_with_poll_fallback` | MarketDataPort | KIS WS 우선, REST polling fallback |
| 2 | IndicatorCalculator | `event` | — | OHLCV→SMA/EMA/RSI/MACD/Bollinger/ATR, 종목별 Ring Buffer 200틱 |
| 3 | StrategyEngine | `event` | StrategyRuntimePort, StoragePort | `strategies/*.py` 로딩 (Phase 1 활성 1개), `evaluate()` 결정론 |
| 4 | RiskGuard | `event` | StoragePort, ClockPort, AuditPort, AccountPort | Pre-Order 8체크 + Circuit Breaker |
| 5 | OrderExecutor | `stateful_service` | OrderPort, StoragePort, AuditPort | 주문 송신만 — `order_uuid` 멱등성 |
| 6 | **ExecutionReceiver** (ADR-013) | `event` | ExecutionEventPort, StoragePort, AuditPort | 체결 통보 수신 — `execution_uuid` 멱등성 |
| 7 | TradingFSM | `stateful_service` | StoragePort, AuditPort, AccountPort | 6상태 상태머신 + Halt 처리 |

**ADR-013 경계 확정 핵심**: OrderExecutor(송신)와 ExecutionReceiver(체결 수신)는 별개 노드. 송신 멱등성 키는 `order_uuid`, 수신 멱등성 키는 `execution_uuid`.

## 4. 엣지 18개 — 완전 목록

| id | from | to | type | role | name |
|----|------|----|----|------|------|
| e01 | MarketDataPort | MarketDataReceiver | DataFlow | DataPipe | raw_tick |
| e02 | MarketDataReceiver | IndicatorCalculator | DataFlow | DataPipe | quote_stream |
| e03 | IndicatorCalculator | StrategyEngine | DataFlow | DataPipe | indicator_bundle |
| e04 | PortfolioStore | StrategyEngine | DataFlow | ConfigRef | position_snapshot |
| e05 | StrategyEngine | RiskGuard | DataFlow | DataPipe | signal_output |
| e06 | PortfolioStore | RiskGuard | DataFlow | ConfigRef | portfolio_snapshot |
| e07 | RiskGuard | OrderExecutor | DataFlow | DataPipe | approved_signal |
| e08 | RiskGuard | AuditStore | Event | AuditTrace | rejection_event |
| e09 | OrderExecutor | OrderPort | DataFlow | DataPipe | order_request |
| e10 | OrderExecutor | TradingFSM | Event | EventNotify | order_ack |
| e11 | OrderExecutor | AuditStore | Event | AuditTrace | order_audit |
| e12 | TradingFSM | PortfolioStore | StateTransition | DataPipe | state_transition |
| e13 | TradingFSM | AuditStore | StateTransition | AuditTrace | fsm_audit |
| e14 | cli_halt | TradingFSM | Event | Command | halt_signal |
| **e15** | ExecutionEventPort | ExecutionReceiver | DataFlow | DataPipe | execution_event (ADR-013) |
| **e16** | ExecutionReceiver | TradingFSM | Event | EventNotify | execution_event (ADR-013) |
| **e17** | ExecutionReceiver | PortfolioStore | StateTransition | DataPipe | portfolio_update (ADR-013) |
| **e18** | ExecutionReceiver | AuditStore | Event | AuditTrace | execution_audit (ADR-013) |

**Role 분포**: DataPipe 10 · AuditTrace 4 · EventNotify 2 · ConfigRef 2 · Command 1 (DataPipe만 DAG 참여, 나머지는 불참여).

## 5. 8 Port 어댑터 매트릭스

| Port | Phase 1 어댑터 | Phase 2+ 어댑터 (보류) |
|------|---------------|----------------------|
| MarketDataPort | CSVReplayAdapter (mock), SyntheticMarketAdapter | KISWebSocketAdapter, KISRestAdapter |
| OrderPort | MockOrderAdapter, SyntheticOrderAdapter, KISPaperOrderAdapter | KISLiveOrderAdapter |
| AccountPort | MockAccountAdapter, SyntheticAccountAdapter, KISPaperAccountAdapter | KISLiveAccountAdapter |
| StoragePort | PostgresStorageAdapter (primary), InMemoryStorageAdapter (test) | — |
| ClockPort | WallClockAdapter (live), HistoricalClockAdapter (backtest) | — |
| StrategyRuntimePort | FileSystemStrategyLoader | DB/Network 로더 |
| AuditPort | PostgresAuditAdapter (primary), StdoutAuditAdapter (test) | — |
| **ExecutionEventPort** (ADR-013) | MockExecutionEventAdapter, SyntheticExecutionEventAdapter, KISPaperExecutionEventAdapter | KISLiveExecutionEventAdapter |

Phase 1 활성 Primary Adapter: 14개.

## 6. TradingFSM — Phase 1 6상태 / 12전이

```
                ┌────────┐
         ┌────►│  IDLE  │◄────────────────┐
         │     └────┬───┘                  │ recovery / manual_resume
         │          │ entry_signal         │
         │          ▼                      │
         │   ┌──────────────┐              │
         │   │ENTRY_PENDING │              │
         │   └──┬───────┬───┘              │
         │ fill │       │ cancel/reject     │ broker_error
         │ complete     │                   │
         │      ▼       └──►┌──────────────┤
         │ ┌──────────┐     │    ERROR     │
         │ │IN_POSITION│────┼──────────────┤
         │ └────┬─────┘     │              │ unrecoverable
         │      │ exit_signal              ▼
         │      ▼                   ┌──────────────┐
         │ ┌──────────────┐  fill   │ SAFE_MODE    │
         │ │EXIT_PENDING  ├────────►│              │◄── halt_requested
         │ └──┬──────┬────┘ complete│              │    (*모든 상태)
         │    │      │              └──────────────┘
         │ cancel    │ broker_error
         │    ▼      ▼
         │ IN_POSITION  ERROR
         │
```

**12 전이**:
1. IDLE → ENTRY_PENDING (entry_signal)
2. ENTRY_PENDING → IN_POSITION (fill_complete)
3. ENTRY_PENDING → IDLE (cancel_or_reject)
4. ENTRY_PENDING → ERROR (broker_error)
5. IN_POSITION → EXIT_PENDING (exit_signal)
6. EXIT_PENDING → IDLE (fill_complete)
7. EXIT_PENDING → IN_POSITION (cancel)
8. EXIT_PENDING → ERROR (broker_error)
9. ERROR → IDLE (recovery)
10. ERROR → SAFE_MODE (unrecoverable)
11. `*` → SAFE_MODE (halt_requested) — wildcard
12. SAFE_MODE → IDLE (manual_resume)

**Phase 1은 종목당 1개 FSM 인스턴스.** 종목군 FSM(레벨 1)과 개별종목 FSM 13상태의 나머지 7상태는 Phase 2 이후 활성화.

## 7. MockBroker ↔ ClockPort 계약

```
┌────────────────────┐               ┌──────────────────┐
│  MockOrderAdapter  │──now()───────►│   ClockPort      │
│                    │◄──timestamp───│                  │
│                    │               │ WallClock (live) │
│  submit(spec)      │               │ Historical (bt)  │
│    └ slippage 모델링│               └──────────────────┘
│    └ fill 지연 시뮬레 이션         
│                    │
└────────────────────┘

계약 핵심:
  - MockOrderAdapter는 datetime.now()를 직접 호출하지 않는다
  - 체결 지연·슬리피지 계산 전부 ClockPort.now() 기반
  - HistoricalClockAdapter 주입 시 시간 가속 백테스트 가능
  - WallClockAdapter 주입 시 실시간 주문과 동일 타이밍
```

**이 계약 덕분에 "백테스트 코드 = 실전 코드" 보장이 성립**한다.

## 8. Pre-Order 8체크 (RiskGuard)

| id | name | block | threshold |
|----|------|-------|-----------|
| 1 | insufficient_cash | true | cash × 95% |
| 2 | concentration_limit | true | 0.20 (종목당 20%) |
| 3 | daily_loss_limit | entry_only | −0.02 (−2%) |
| 4 | trade_count_limit | true | 40회/일 |
| 5 | outside_trading_hours | true | 09:00–15:20 |
| 6 | vi_triggered | true | — |
| 7 | circuit_breaker_open | true | 60초·3회 실패 |
| 8 | price_limit_violation | true | 상하한가 ±30% 위반 (quant-spec §5.3) |

**Phase 2 연기 5체크**: sector_concentration, correlation_check, leverage_limit, market_regime, var_calculation.

## 9. 실패 모드 매트릭스

| ID | 실패 | 탐지 | 방어 | Safeguard |
|----|------|------|------|-----------|
| F1 | KIS WS 단절 | 연속 3회 수신 실패 | FALLBACK_POLL 모드 10초 polling | — |
| F2 | KIS REST 타임아웃 | asyncio.wait_for 5s | 재시도 3회 → audit_event(severity=error) | — |
| F3 | 체결 미확인 | ExecutionReceiver 미수신 | (Phase 2) RECONCILING 전이. Phase 1은 수동 | event_durability |
| F4 | 중복 주문 요청 | order_uuid 중복 | OrderExecutor 멱등 거부 | duplicate_order_prevention |
| F5 | 중복 체결 수신 | execution_uuid 중복 | ExecutionReceiver 멱등 거부 | duplicate_order_prevention |
| F6 | OrderPort 3회 실패/60초 | CircuitBreaker 트립 | FSM BROKER_FAILURE → SAFE_MODE | command_control_security |
| F7 | Crash 재시작 | `atlas start` 부팅 | positions 테이블 조회 → FSM 복원 | state_account_consistency |
| F8 | 핼트 명령 | CLI halt → e14 | 30초 내 신규 진입 차단 | command_control_security |

## 10. 직접 엣지 금지 원칙 검증

Phase 1은 Path 1 단일 경로만 활성. Cross-Path 엣지가 **존재하지 않는다** (graph_ir_phase1.yaml `meta.paths_active: [path1]`). Phase 2+ 진입 시 다른 Path와 통신은 Shared Store 경유만 허용.

Phase 1 내부 노드 ↔ Store 접근:

| Store | Writers | Readers |
|-------|---------|---------|
| MarketDataStore | MarketDataReceiver | IndicatorCalculator · backtest_cli |
| PortfolioStore | OrderExecutor · TradingFSM · **ExecutionReceiver** | RiskGuard · StrategyEngine · cli_status |
| AuditStore | OrderExecutor · RiskGuard · TradingFSM · **ExecutionReceiver** · cli | cli_audit · cli_orders |

## 11. 문서 상호 참조

- Node·Edge 정규 정의: `graph_ir_phase1.yaml`
- Port 시그니처: `docs/what/specs/port-signatures-phase1.md`
- Adapter 구현: `docs/what/specs/adapter-spec-phase1.md`
- Domain Types: `docs/what/specs/domain-types-phase1.md`
- DB 스키마: `docs/what/specs/db-schema-phase1.sql`
- FSM 설계: `docs/what/architecture/fsm-design.md`
- Path1 설계: `docs/what/architecture/path1-design.md`

---

*End of Document — Numeric Pipeline Phase 1*
