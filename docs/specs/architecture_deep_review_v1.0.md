# HR-DAG Architecture Deep Review — 취약점·누락·구조 보강 분석

> **2026-04-16 | 전체 6 Path × 43 Node 재분석**
> 실전 KIS API 제약, 실전 매매 시나리오, 경로별 분기/분리 필요성을 중심으로 점검

---

## Executive Summary

18개 설계 문서를 경로별로 재분석한 결과, **5개 구조적 취약점, 8개 누락 요소, 4개 경로 분리/분기 필요 사항**을 발견했습니다. 가장 심각한 것은 KIS WebSocket의 실제 구독 제한(세션당 체결+호가 합산 20~41종목)이 설계의 max_subscriptions: 50과 충돌하는 것과, 3-Mode 매매의 SEMI_AUTO 흐름이 노드 수준에서 미설계된 것입니다.

---

## 1. Path 1: Realtime Trading (13 nodes)

### 1.1 발견된 취약점

#### V1-1: WebSocket 구독 상한 현실 불일치 (심각도: 🔴 Critical)

설계에서 `max_subscriptions: 50`으로 정의했으나, KIS WebSocket은 **세션당 체결(H0STCNT0) + 호가(H0STASP0) 합산 20개**(최근 확장 예정 60개)가 실제 상한입니다. 체결통보(H0STCNI0)는 별도 1개. 이는 설계에서 가정한 50종목 동시 감시와 직접적으로 충돌합니다.

**보강안:**
- SubscriptionRouter에 **SubscriptionTier** 개념 도입: Tier 1(실시간 WebSocket, 최대 20종목) / Tier 2(REST 폴링 3초 주기, 나머지)
- 다중 계좌 WebSocket 세션으로 확장하는 경우 `WebSocketPoolManager` 서브컴포넌트 필요
- `max_subscriptions` → `max_ws_subscriptions: 20` + `max_poll_subscriptions: 30`으로 분리
- SubscriptionRouter 노드를 **SubscriptionRouter + WebSocketPoolManager**로 분기

```
변경 전: SubscriptionRouter (단일)
변경 후: SubscriptionRouter ──→ WebSocketPoolManager (WS 세션 관리)
                              └→ PollingScheduler (REST 폴링 관리)
```

#### V1-2: 3-Mode(AUTO/SEMI_AUTO/MANUAL) 실행 흐름 미설계 (심각도: 🟡 High)

INDEX.md에서 3-Mode를 선언했지만, 실제 노드 수준의 설계가 없습니다. 특히 SEMI_AUTO에서 Telegram 확인 후 주문을 실행하는 비동기 대기 흐름이 어디에도 정의되어 있지 않습니다.

**보강안:** StrategyEngine 내부에 `ModeRouter` 서브컴포넌트 추가가 아니라, **StrategyEngine과 RiskGuard 사이에 `ApprovalGate` 노드 삽입** 권장. 이유: SEMI_AUTO의 "사람 확인 대기"는 수 초~수 분의 지연을 발생시키므로 StrategyEngine 내부에 두면 이벤트 루프를 블로킹합니다.

```
변경 전: StrategyEngine → RiskGuard → DedupGuard → OrderExecutor
변경 후: StrategyEngine → ApprovalGate → RiskGuard → DedupGuard → OrderExecutor
                             │
                             ├─ AUTO: 즉시 통과
                             ├─ SEMI_AUTO: Telegram 알림 → 비동기 대기 → approve/reject
                             └─ MANUAL: (이 체인을 타지 않음, 별도 ManualOrderEndpoint)
```

ApprovalGate 노드 명세:
- runMode: stateful-service
- LLM Level: L0
- 내부 상태: pending_approvals 큐 (symbol → TradingContext 매핑)
- 타임아웃: ConfigStore.approval_timeout_seconds (기본 120초, 초과 시 자동 reject)
- 신규 Edge: e_approval_to_alert (ApprovalGate → AlertDispatcher, Telegram 발송)
- 신규 Edge: e_command_to_approval (CommandController → ApprovalGate, approve/reject 수신)

#### V1-3: MANUAL 모드 주문 진입점 부재 (심각도: 🟡 High)

MANUAL 모드에서 사용자가 Telegram으로 `/buy 005930 10 72000` 같은 명령을 보내면 어떤 노드가 수신하여 어떤 경로로 주문이 실행되는지 미정의.

**보강안:** CommandController(Path 5)에 매매 명령 처리를 추가하되, 주문은 반드시 RiskGuard를 통과시켜야 합니다.

```
Telegram "/buy 005930 10 72000"
  → CommandController (인증 + 파싱)
  → ManualOrderRequest 생성
  → RiskGuard (Pre-Order 18항목 검증)
  → DedupGuard → OrderExecutor
```

기존 CommandController의 CommandType에 `BUY_ORDER`, `SELL_ORDER` 추가 필요. CommandRiskLevel은 `MEDIUM` (확인 후 실행).

#### V1-4: Screener의 API Rate Limit 충돌 (심각도: 🟠 Medium)

장중 실시간 스크리닝에서 KIS 등락률/거래량 순위 API를 30분마다 호출하는데, 이때 종목별 시세 조회와 합산하면 초당 20건 제한에 걸릴 수 있습니다. 특히 Screener가 전 종목(약 2,500개)을 스캔하면 REST API만으로 125초 소요.

**보강안:**
- Screener는 전 종목 스캔 대신 **KIS 순위 API(상위 100건) + MarketDataStore 캐시 조합**으로 전환
- REST API 호출 전체를 관리하는 **APIRateLimiter** 공용 컴포넌트를 infrastructure 레이어에 추가
- Path 1, Path 6 모두가 이 RateLimiter를 경유

### 1.2 누락 요소

#### M1-1: 장 시작/마감 전 초기화 시퀀스 미정의

시스템 시작 시 각 노드의 초기화 순서가 정의되어 있지 않습니다. 예를 들어 MarketDataReceiver가 SubscriptionRouter보다 먼저 시작하면 구독 목록이 비어있고, WatchlistManager가 WatchlistStore를 복원하기 전에 Screener가 promote()를 호출하면 중복이 발생합니다.

**보강안:** `SystemBootstrap` 시퀀스 정의 필요

```
Boot Sequence (장 시작 전):
  1. ConfigStore 로드
  2. DB 연결 확인 (PostgreSQL, Redis)
  3. WatchlistManager: WatchlistStore에서 기존 상태 복원
  4. PositionMonitor: PortfolioStore에서 보유 포지션 복원
  5. TradingFSM: 마지막 상태 복원 (UNKNOWN 주문 있으면 복구 프로세스)
  6. MarketDataReceiver: KIS WebSocket 연결
  7. SubscriptionRouter: 복원된 워치리스트 기반 구독 시작
  8. StrategyEngine: 전략 로딩
  9. AuditLogger: SYSTEM_STARTED 이벤트 기록
  10. AlertDispatcher: "시스템 시작 완료" 알림
```

```
Shutdown Sequence (장 마감 후):
  1. 미체결 주문 전량 취소 (OrderExecutor)
  2. 최종 잔고 동기화 (PositionAggregator → BrokerPort.get_account)
  3. 일일 결산 기록 (PortfolioStore.daily_pnl)
  4. WatchlistManager: 상태 영속화
  5. MarketDataReceiver: WebSocket 해제
  6. AuditLogger: SYSTEM_STOPPED 이벤트
  7. DailyReporter: 일일 리포트 생성 + 발송
```

#### M1-2: 토큰 갱신 노드/컴포넌트 부재

KIS API 접근토큰은 24시간 유효하며, 만료 전 갱신이 필요합니다. 현재 설계에서 토큰 관리 책임이 어떤 노드에도 할당되어 있지 않습니다.

**보강안:** BrokerPort 어댑터 내부에 `TokenManager` 서브컴포넌트 추가. 토큰 만료 30분 전 자동 갱신, 갱신 실패 시 AuditLogger에 기록 + AlertDispatcher로 알림.

---

## 2. Path 6: Market Intelligence (5 nodes)

### 2.1 발견된 취약점

#### V6-1: SupplyDemandAnalyzer의 1분 주기 폴링 = 초당 20건 제한과 충돌 (심각도: 🟠 Medium)

투자자매매동향 API를 워치리스트 전 종목(최대 30)에 대해 1분마다 호출하면, 30건/60초 = 0.5건/초로 자체는 괜찮지만, Path 1의 REST 폴링과 합산하면 문제됩니다.

**보강안:** Path 6 전체를 **APIRateLimiter 경유 필수**로 설정. API 호출 예산을 Path별로 배분:
- Path 1: 초당 12건 (시세 폴링 + 주문)
- Path 6: 초당 5건 (수급/종목상태/업종)
- Path 3/기타: 초당 3건

#### V6-2: Path 6 → Path 1 긴급 통보의 실제 지연 (심각도: 🟡 High)

MarketRegimeDetector가 WebSocket H0STMKO0으로 VI/CB를 감지하여 Path 1에 Event Edge로 통보하는데, 이 edge의 timeout은 100ms입니다. 그러나 VI 발동 시 Path 1이 해당 종목에 대해 이미 주문을 제출 중이라면, 주문 제출 후에야 VI 통보를 처리합니다.

**보강안:** VI/CB 감지 시 **즉시 OrderExecutor의 내부 차단 플래그 세팅** 필요. 이벤트 전파와 별개로, MarketRegimeDetector → Redis `halt:vi:{symbol}` 키 세팅 → OrderExecutor가 주문 전 Redis 키 확인하는 이중 경로 추가.

### 2.2 누락 요소

#### M6-1: MarketContext 조합 로직의 주체 미정의

node_blueprint_path2to6에 `build_market_context()` 함수가 정의되어 있으나, 이걸 실행하는 노드가 명시되어 있지 않습니다. "별도 노드가 아닌 MarketIntelStore의 materialized view 또는 캐시 갱신 트리거로 구현"이라고만 적혀 있습니다.

**보강안:** `MarketContextBuilder`를 Path 6의 6번째 노드로 명시 추가하거나, MarketIntelStore에 PostgreSQL 트리거로 구현할 경우 그 트리거 DDL을 shared_store_ddl에 추가.

권장: **MarketContextBuilder 노드 신설** (runMode: event, L0). Path 6의 다른 4개 노드가 MarketIntelStore에 데이터를 쓸 때마다 이벤트를 수신하여 해당 종목의 MarketContext를 재계산하고 market_context_cache에 저장.

### 2.3 경로 분기 권장

#### Path 6 → 6A(실시간) + 6B(배치) 분리

현재 Path 6의 5개 노드가 혼재된 runMode를 사용합니다:
- 실시간: OrderBookAnalyzer(stream), MarketRegimeDetector(event)
- 주기적: SupplyDemandAnalyzer(poll 1분), StockStateMonitor(poll 5분)
- 배치: ConditionSearchBridge(batch 30분)

실시간 노드와 배치 노드가 같은 Path에 있으면, 배치 노드의 대량 API 호출이 실시간 노드의 응답성에 영향을 줄 수 있습니다.

```
Path 6A: Realtime Intelligence (Phase 1 핵심)
  ├─ MarketRegimeDetector (event) — VI/CB 즉시 감지
  ├─ StockStateMonitor (poll 5분) — 거래정지/투자경고
  └─ MarketContextBuilder (event) — 컨텍스트 재계산

Path 6B: Periodic Intelligence (Phase 2)
  ├─ SupplyDemandAnalyzer (poll 1분) — 수급 분석
  ├─ OrderBookAnalyzer (stream) — 호가 분석
  └─ ConditionSearchBridge (batch) — 조건검색/순위
```

---

## 3. Path 5: Watchdog & Operations (6 nodes)

### 3.1 발견된 취약점

#### V5-1: CommandController의 책임 과부하 (심각도: 🟠 Medium)

현재 CommandController가 처리하는 명령:
- 거래 제어: halt/resume/close_position/close_all
- 전략 제어: deploy/retire/update_params
- 시스템: restart_node/reload_config
- 조회: status/positions/health
- (신규) 매매 명령: buy/sell (MANUAL 모드)
- (신규) 승인: approve/reject (SEMI_AUTO 모드)

이 모든 것이 단일 Telegram Bot 핸들러에 몰리면 코드 복잡도가 급증합니다.

**보강안:** CommandController를 역할별로 분기

```
Path 5 CommandController 분기:
  ├─ TradingCommandHandler — halt/resume/close/buy/sell/approve/reject
  ├─ SystemCommandHandler — restart/reload/status/health
  └─ StrategyCommandHandler — deploy/retire/update_params

세 핸들러가 공유하는 것:
  - AuthGuard (인증)
  - RiskLevelGate (위험도 판단)
  - AuditLogger 연결
```

구현 수준에서는 CommandController 내부의 서브클래스로 충분하며, 별도 노드까지 분리할 필요는 없습니다. 단, `CommandType` Enum의 그룹핑과 라우팅 로직은 명시해야 합니다.

### 3.2 누락 요소

#### M5-1: 시스템 상태 대시보드 / 상태 조회 API 부재

Telegram 명령으로 `/status`를 치면 현재 시스템 상태를 볼 수 있어야 하지만, 그 응답 포맷과 데이터 수집 범위가 미정의.

**보강안:** `StatusReport` 타입 정의 필요

```python
@dataclass(frozen=True)
class StatusReport:
    mode: str                    # "auto" | "semi_auto" | "manual"
    trading_env: str             # "demo" | "live"
    market_status: str           # "pre_market" | "open" | "closed"
    is_halted: bool
    watchlist_count: int
    position_count: int
    daily_pnl: float
    daily_pnl_pct: float
    pending_orders: int
    pending_approvals: int       # SEMI_AUTO 대기 중 주문
    unhealthy_components: list[str]
    last_trade_at: str | None
    uptime_hours: float
```

---

## 4. Path 4: Portfolio Management (6 nodes)

### 4.1 발견된 취약점

#### V4-1: Phase 1에서 Path 4 부재 시 리스크 보호 공백 (심각도: 🟡 High)

Phase 1에서 Path 4가 없으므로, RiskBudgetManager의 포트폴리오 수준 검증(일일 손실 한도, 섹터 비중, 전략 배분)이 빠집니다. 현재 설계에서 이를 RiskGuard가 대행한다고 INDEX.md에 적었지만, RiskGuard의 기존 검증 항목 18개에 포트폴리오 검증이 포함되어 있지 않습니다.

**보강안:** Phase 1에서 RiskGuard에 **SimplifiedPortfolioCheck** 서브로직 추가

```python
# Phase 1 전용 — Path 4 없을 때 RiskGuard 내부 보호
class SimplifiedPortfolioCheck:
    """Path 4 RiskBudgetManager의 최소 기능 내장."""
    
    async def check(self, order: OrderRequest) -> RiskCheckResult:
        snapshot = await portfolio_store.get_snapshot()
        
        # 1. 일일 손실 한도
        if snapshot.daily_pnl_pct <= config.max_portfolio_loss_pct:
            return REJECTED("daily_loss_limit_reached")
        
        # 2. 단일 종목 비중
        order_value = order.quantity * order.price
        if order_value / snapshot.total_equity > config.max_single_position_pct / 100:
            return REDUCED(adjusted_quantity)
        
        # 3. 동시 보유 종목 수
        if snapshot.position_count >= config.max_in_position:
            return REJECTED("max_positions_reached")
        
        # 4. 일일 거래 횟수
        if snapshot.trade_count_today >= config.max_daily_trades:
            return REJECTED("daily_trade_limit")
        
        return APPROVED
```

Pre-Order 18항목에 이 4개를 추가하여 22항목으로 확장.

### 4.2 누락 요소

#### M4-1: 실전 전환 시 demo→live 스위칭 절차 미정의

모의투자에서 실전으로 전환할 때 변경해야 하는 것:
- KIS API 엔드포인트 (demo → prod)
- AppKey/AppSecret (모의용 → 실전용)
- 계좌번호
- 주문 tr_id (모의: VTTC0802U → 실전: TTTC0802U)
- 위험 한도 재설정

이 전환을 안전하게 수행하는 절차가 없습니다.

**보강안:** `EnvironmentSwitcher` 절차 정의
1. halt_trading 명령 실행
2. 모든 모의투자 포지션 확인 (실전에는 없음)
3. ConfigStore.trading_env 변경 (demo → live)
4. BrokerPort 어댑터 재초기화 (새 토큰 발급)
5. 잔고 조회로 실전 계좌 확인
6. 위험 한도 실전용으로 조정 (금액 하향)
7. MANUAL 모드로 시작 (AUTO 즉시 전환 금지)
8. resume_trading

---

## 5. Path 3: Strategy Development (7 nodes)

### 5.1 구조적 문제

#### S3-1: Phase 1에서 전략 로딩 경로 불명확 (심각도: 🟠 Medium)

Phase 1에서는 수동 작성 전략 .py 파일을 사용하는데, StrategyLoader(poll, 30초 주기)가 어디서 파일을 읽어오는지, StrategyStore(DB)에 등록된 것만 로딩하는지, 파일시스템에서 직접 읽는지 미정의.

**보강안:** Phase 1 전용 `FileSystemStrategyAdapter` 동작 명시

```yaml
# Phase 1: 파일 기반 전략 로딩
strategy_runtime:
  implementation: ImportlibRuntimeAdapter
  params:
    strategy_dir: "./strategies/"      # .py 파일 위치
    watch_mode: true                   # 파일 변경 감지 (watchdog)
    auto_reload: false                 # 변경 감지 시 자동 리로드 여부
    required_base_class: "BaseStrategy"
```

전략 파일 규약:
```python
# strategies/ma_crossover.py
class MACrossoverStrategy(BaseStrategy):
    strategy_id = "ma_crossover_v1"
    params = {"fast": 5, "slow": 20}
    
    def evaluate(self, indicators: dict) -> SignalOutput:
        ...
```

---

## 6. Path 2: Knowledge Building (6 nodes)

### 6.1 Phase 3 전용이므로 현 시점 취약점 분석 생략

단, Phase 3 진입 시 확인해야 할 핵심 리스크:
- DART API 분당 100건 제한과 대량 수집의 충돌
- LLM 기반 파싱(L1/L2 노드)의 비용 통제 (Claude Sonnet 호출 비용)
- CausalReasoner의 LangGraph checkpointer가 PostgreSQL 부하에 미치는 영향

---

## 7. 시스템 횡단 취약점 (Cross-Cutting)

### 7.1 API Rate Limiter 부재 (심각도: 🔴 Critical)

KIS REST API 초당 20건 제한이 시스템 전체에서 관리되지 않습니다. 현재 각 노드가 독립적으로 API를 호출하므로:
- Path 1 MarketDataReceiver (REST 폴링 모드): 최대 30종목 × 0.33건/초 = 10건/초
- Path 1 Screener (장중 스크리닝): 순위 API 3건/초
- Path 6 SupplyDemandAnalyzer: 30종목/60초 = 0.5건/초
- Path 6 StockStateMonitor: 30종목/300초 = 0.1건/초
- Path 1 RiskGuard (가능수량 조회): 주문 시 1건
- 합산: **~14건/초** (정상 시) → 스크리닝 + 폴링 모드 동시 시 **20건/초 초과 가능**

**보강안: `KISAPIGateway` 인프라 컴포넌트 신설**

```python
class KISAPIGateway:
    """KIS REST API 호출을 중앙에서 제어.
    
    모든 Path의 KIS REST 호출이 이 게이트웨이를 경유.
    초당 20건 제한 + 토큰 관리 + 에러 핸들링 통합.
    """
    def __init__(self):
        self._semaphore = asyncio.Semaphore(18)  # 여유 2건
        self._token_manager = TokenManager()
        self._rate_limiter = SlidingWindowRateLimiter(
            max_requests=18,
            window_seconds=1.0,
        )
    
    async def call(self, endpoint: str, params: dict, 
                   priority: int = 5) -> dict:
        """우선순위 기반 API 호출.
        priority: 1=주문(최우선), 5=시세조회, 9=배치스크리닝
        """
        await self._rate_limiter.acquire(priority)
        async with self._semaphore:
            return await self._execute(endpoint, params)
```

이 컴포넌트는 어떤 Path에도 속하지 않는 **infrastructure 레이어**에 위치. 모든 KIS 어댑터가 이 게이트웨이를 DI로 주입받음.

### 7.2 Redis 단일 장애점 (심각도: 🟠 Medium)

architecture_review_patch에서 Path 4→Path 1 동기 의존을 Redis 캐시로 분리했는데, Redis가 죽으면 RiskGuard가 안전 방향(수량 50% 축소)으로 동작합니다. 그러나 Redis가 VI 긴급 차단 플래그(V6-2 보강안)도 담당하게 되면, Redis 장애 = VI 차단 실패 = 자본 손실 위험.

**보강안:** VI/CB 같은 critical 플래그는 Redis + 인메모리 이중 저장. MarketRegimeDetector가 Redis에 쓸 때 동시에 asyncio Event로도 브로드캐스트하여 OrderExecutor가 인메모리에서도 확인.

### 7.3 모의투자 vs 실전 API 차이 미반영 (심각도: 🟡 High)

실전과 모의투자의 핵심 차이:
- 모의투자 REST API 호출 제한이 더 낮음
- 모의투자에서는 지정가/시장가만 가능 (IOC/FOK/조건부 미지원)
- 체결 통보 tr_id가 다름 (H0STCNI0 vs H0STCNI9)
- 호가단위/체결 시뮬레이션이 실제와 다를 수 있음

현재 설계의 OrderDivision Enum에 24종 주문 유형이 정의되어 있지만, 모의투자에서 사용 가능한 것은 2종뿐.

**보강안:** `EnvironmentProfile` 타입 추가

```python
@dataclass(frozen=True)
class EnvironmentProfile:
    env: str                        # "demo" | "live"
    allowed_order_types: list[str]  # demo: ["00", "01"] / live: 전체
    ws_execution_tr_id: str         # demo: "H0STCNI9" / live: "H0STCNI0"
    rest_rate_limit: int            # demo: 10/sec / live: 20/sec
    api_domain: str                 # demo: "openapivts..." / live: "openapi..."
```

BrokerPort 어댑터와 MarketDataPort 어댑터가 이 프로필을 참조하여 동작을 분기.

### 7.4 장애 복구 후 상태 정합성 검증 부재 (심각도: 🟡 High)

시스템이 장중에 crash 후 재시작되면:
- WatchlistStore에는 IN_POSITION 종목이 있는데, 실제 브로커 계좌에는 이미 체결/취소되었을 수 있음
- TradingFSM이 EntryPending 상태인데, 주문은 이미 체결되었을 수 있음
- WAL(e_preorder_wal_write)에 pending 레코드가 있으면 복구 필요

**보강안:** Boot Sequence에 **ReconciliationStep** 추가 (M1-1의 Step 5 확장)

```
Crash Recovery Sequence:
  1. WAL 테이블에서 status="pending"/"submitted" 레코드 조회
  2. 각 레코드에 대해 BrokerPort.get_pending_orders() + get_daily_orders() 확인
  3. TradingFSM 상태와 실계좌 상태 대조
  4. 불일치 발견 시:
     - 실계좌에 체결 있는데 FSM이 모르면 → FSM 상태 강제 갱신
     - FSM이 주문 중인데 실계좌에 없으면 → FSM → Idle 복원
  5. WatchlistManager 상태와 PortfolioStore 포지션 대조
  6. 불일치 리포트 생성 → AuditLogger + AlertDispatcher(HIGH)
```

---

## 8. 경로 분리/분기 요약

| 변경 | 유형 | 위치 | 근거 |
|------|------|------|------|
| SubscriptionRouter → WS Pool + Poll Scheduler | 서브컴포넌트 분기 | Path 1A | KIS WS 20종목 제한 |
| ApprovalGate 노드 신설 | 노드 추가 | Path 1B | SEMI_AUTO 비동기 대기 |
| CommandController 내부 핸들러 분기 | 내부 분기 | Path 5 | 책임 과부하 방지 |
| Path 6 → 6A(실시간) + 6B(주기적) | 서브패스 분리 | Path 6 | 실시간 응답성 보호 |
| MarketContextBuilder 노드 신설 | 노드 추가 | Path 6A | 조합 로직 주체 명확화 |
| KISAPIGateway 신설 | 인프라 레이어 | 횡단 | API Rate Limit 중앙 관리 |

---

## 9. 수치 변경 요약

| 항목 | 기존 | 보강 후 | 변경 |
|------|------|--------|------|
| Nodes | 43 | 45 | +2 (ApprovalGate, MarketContextBuilder) |
| Edges | 89 | 93 | +4 (ApprovalGate 2개, MANUAL 경로, MCB 이벤트) |
| Domain Types | 91 | 94 | +3 (StatusReport, EnvironmentProfile, ApprovalRequest 확장) |
| Infra Components | 0 | 2 | +2 (KISAPIGateway, TokenManager) |
| Pre-Order Checks | 18 | 22 | +4 (SimplifiedPortfolioCheck) |
| SubPaths | Path 1: 3개 | Path 1: 3개 + Path 6: 2개 | Path 6 서브패스 분리 |
| Boot/Shutdown Seq | 미정의 | 정의됨 | 신규 |

---

## 10. 우선순위별 보강 권장 순서

| 순위 | ID | 제목 | 심각도 | Phase |
|------|-----|------|--------|-------|
| 1 | V1-1 | WebSocket 구독 상한 현실 반영 | 🔴 | P1 필수 |
| 2 | CC-1 | KISAPIGateway (Rate Limit 중앙 관리) | 🔴 | P1 필수 |
| 3 | V1-2 | ApprovalGate 노드 (SEMI_AUTO 흐름) | 🟡 | P1 필수 |
| 4 | V1-3 | MANUAL 모드 주문 경로 | 🟡 | P1 필수 |
| 5 | M1-1 | Boot/Shutdown 시퀀스 | 🟡 | P1 필수 |
| 6 | V4-1 | SimplifiedPortfolioCheck (Path 4 대행) | 🟡 | P1 필수 |
| 7 | CC-3 | 모의투자/실전 EnvironmentProfile | 🟡 | P1 필수 |
| 8 | CC-4 | Crash Recovery Reconciliation | 🟡 | P1 권장 |
| 9 | M6-1 | MarketContextBuilder 노드 | 🟠 | P1 권장 |
| 10 | V6-1 | Path 6 API 예산 배분 | 🟠 | P1 권장 |
| 11 | M1-2 | TokenManager | 🟠 | P1 필수 |
| 12 | V6-2 | VI 즉시 차단 이중 경로 | 🟡 | P1 권장 |
| 13 | CC-2 | Redis 이중 저장 (critical 플래그) | 🟠 | P2 |
| 14 | S3-1 | Phase 1 전략 로딩 규약 | 🟠 | P1 |
| 15 | M4-1 | demo→live 전환 절차 | 🟠 | P1→P2 전환 시 |
| 16 | V5-1 | CommandController 핸들러 분기 | 🟠 | P1 |
| 17 | Path 6 분리 | 6A/6B 서브패스 | 🟠 | P2 |
