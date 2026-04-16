# Architecture Reinforcement Patch — v2.0

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | architecture_reinforcement_patch_v2.0 |
| 선행 문서 | architecture_deep_review (2026-04-16), architecture_review_patch_v1.0, path_reinforcement_v1.0 |
| 작성일 | 2026-04-16 |
| 상태 | Draft |
| 목적 | Deep Review에서 발견된 5취약점 + 8누락 + 4분기의 공식 패치 |

---

## 1. 패치 총괄

### 1.1 변경 요약

| ID | 분류 | 제목 | 영향 범위 | 우선순위 |
|----|------|------|----------|---------|
| P-01 | 인프라 신설 | KISAPIGateway (Rate Limit 중앙 관리) | 전체 KIS 어댑터 | 🔴 P1 필수 |
| P-02 | 노드 변경 | SubscriptionRouter 구독 Tier 분리 | Path 1A | 🔴 P1 필수 |
| P-03 | 노드 신설 | ApprovalGate (SEMI_AUTO 흐름) | Path 1B | 🟡 P1 필수 |
| P-04 | 기능 추가 | MANUAL 모드 주문 경로 | Path 5 → Path 1B | 🟡 P1 필수 |
| P-05 | 시퀀스 정의 | Boot / Shutdown / Crash Recovery | 전 Path | 🟡 P1 필수 |
| P-06 | 기능 내장 | SimplifiedPortfolioCheck (Phase 1) | Path 1B RiskGuard | 🟡 P1 필수 |
| P-07 | 타입 추가 | EnvironmentProfile (demo/live 분리) | 전 어댑터 | 🟡 P1 필수 |
| P-08 | 인프라 내장 | TokenManager (토큰 자동 갱신) | BrokerPort 어댑터 | 🟠 P1 필수 |
| P-09 | 노드 신설 | MarketContextBuilder | Path 6 | 🟠 P1 권장 |
| P-10 | 분기 정의 | Path 6 → 6A(실시간) + 6B(주기적) | Path 6 | 🟠 P2 |
| P-11 | 이중 경로 | VI 즉시 차단 (Redis + in-memory) | Path 6 → Path 1 | 🟡 P1 권장 |
| P-12 | 내부 분기 | CommandController 핸들러 그룹핑 | Path 5 | 🟠 P1 |
| P-13 | 타입 추가 | StatusReport (상태 조회 응답) | Path 5 | 🟠 P1 |
| P-14 | 절차 정의 | demo → live 전환 절차 | ConfigStore + Adapters | 🟠 P1→P2 |
| P-15 | 규약 정의 | Phase 1 전략 파일 로딩 규약 | Path 3 StrategyLoader | 🟠 P1 |
| P-16 | 안전장치 | Redis critical 플래그 이중 저장 | 인프라 | 🟠 P2 |
| P-17 | API 예산 | Path별 KIS API 호출 예산 배분 | KISAPIGateway | 🟠 P1 권장 |

### 1.2 수치 변경

| 항목 | Patch v1.0 이후 | 이번 Patch 후 | 변경 |
|------|---------------|-------------|------|
| Nodes | 43 | 45 | +2 (ApprovalGate, MarketContextBuilder) |
| Edges | 89 | 95 | +6 |
| Domain Types | 91 | 96 | +5 |
| Infra Components | 1 (Redis Cache) | 3 | +2 (KISAPIGateway, TokenManager) |
| Pre-Order Checks | 18 | 22 | +4 |
| Validation Rules | 39 | 46 | +7 |
| SubPaths | 6 (1A/1B/1C/기타) | 8 | +2 (6A/6B) |

---

## 2. P-01: KISAPIGateway — API Rate Limit 중앙 관리

### 2.1 문제

KIS REST API 초당 20건(2026.03 이후 신규 고객은 더 낮을 수 있음) 제한을 각 Path의 어댑터가 독립적으로 호출하여 합산 초과 위험.

### 2.2 해결

infrastructure 레이어에 `KISAPIGateway` 신설. 모든 KIS REST API 호출이 이 게이트웨이를 경유.

```python
"""infrastructure/kis_api_gateway.py"""
import asyncio
from dataclasses import dataclass, field
from datetime import datetime
from collections import deque


@dataclass
class APICallRequest:
    """API 호출 요청."""
    endpoint: str
    method: str                   # "GET" | "POST"
    params: dict
    headers: dict
    priority: int = 5             # 1(주문)~9(배치 스크리닝)
    caller: str = ""              # "path1.order_executor" 등
    created_at: datetime = field(default_factory=datetime.now)


class KISAPIGateway:
    """KIS REST API 중앙 제어.
    
    책임:
    1. 초당 호출 수 제한 (sliding window)
    2. 우선순위 기반 큐잉 (주문 > 시세 > 스크리닝)
    3. Path별 호출 예산 배분
    4. 토큰 자동 갱신 위임 (TokenManager)
    5. 에러 분류 및 재시도 판단
    
    위치: infrastructure/ (어떤 Path에도 속하지 않음)
    DI: 모든 KIS 어댑터가 생성자에서 주입받음
    """
    
    MAX_REQUESTS_PER_SECOND = 18  # 20건 중 2건 여유
    
    def __init__(self, token_manager, env_profile):
        self._token_manager = token_manager
        self._env_profile = env_profile
        self._window: deque = deque()           # (timestamp,) 슬라이딩 윈도우
        self._priority_queue = asyncio.PriorityQueue()
        self._budget = PathBudget()             # P-17 참조
        self._call_count = {"path1": 0, "path6": 0, "other": 0}
    
    async def call(self, request: APICallRequest) -> dict:
        """우선순위 기반 API 호출."""
        # 1. Path별 예산 확인
        self._budget.check(request.caller, request.priority)
        
        # 2. 슬라이딩 윈도우 대기
        await self._wait_for_slot()
        
        # 3. 토큰 확인
        token = await self._token_manager.get_valid_token()
        
        # 4. 실행
        request.headers["authorization"] = f"Bearer {token}"
        request.headers["appkey"] = self._env_profile.app_key
        request.headers["appsecret"] = self._env_profile.app_secret
        
        response = await self._execute(request)
        
        # 5. 에러 분류
        if response.get("rt_cd") != "0":
            return await self._handle_error(request, response)
        
        return response
    
    async def _wait_for_slot(self):
        """슬라이딩 윈도우 — 1초 내 호출 수 제한."""
        now = datetime.now()
        # 1초 이전 기록 제거
        while self._window and (now - self._window[0]).total_seconds() > 1.0:
            self._window.popleft()
        # 상한 도달 시 대기
        while len(self._window) >= self.MAX_REQUESTS_PER_SECOND:
            await asyncio.sleep(0.05)
            now = datetime.now()
            while self._window and (now - self._window[0]).total_seconds() > 1.0:
                self._window.popleft()
        self._window.append(now)
    
    async def _handle_error(self, request, response):
        """에러 분류 및 재시도 판단."""
        msg_cd = response.get("msg_cd", "")
        if msg_cd == "EGW00123":          # 토큰 만료
            await self._token_manager.refresh()
            return await self.call(request)  # 1회 재시도
        elif msg_cd == "EGW00201":        # Rate limit
            await asyncio.sleep(1.0)
            return await self.call(request)  # 대기 후 재시도
        else:
            return response               # 호출자에게 반환
```

### 2.3 어댑터 변경

모든 KIS 어댑터의 생성자에 `gateway: KISAPIGateway` 파라미터 추가.

```python
# 변경 전
class KISWebSocketAdapter:
    def __init__(self, app_key, app_secret, ...):
        ...

# 변경 후
class KISRestPollingAdapter:
    def __init__(self, gateway: KISAPIGateway, ...):
        self._gw = gateway
    
    async def get_quote(self, symbol):
        return await self._gw.call(APICallRequest(
            endpoint="/uapi/domestic-stock/v1/quotations/inquire-price",
            method="GET",
            params={"fid_input_iscd": symbol, ...},
            headers={"tr_id": "FHKST01010100"},
            priority=5,
            caller="path1.market_data_receiver",
        ))
```

### 2.4 YAML 설정 추가

```yaml
# settings.yaml
infrastructure:
  kis_api_gateway:
    max_requests_per_second: 18
    priority_levels:
      order_execution: 1           # 주문/정정/취소
      risk_check: 2                # 가능수량 조회
      position_query: 3            # 잔고/체결 조회
      market_data: 5               # 시세/호가
      intelligence: 6              # 수급/종목상태
      screening: 8                 # 스크리닝/순위
      batch: 9                     # 배치 수집
```

---

## 3. P-02: SubscriptionRouter 구독 Tier 분리

### 3.1 문제

KIS WebSocket 세션당 실시간 구독 상한: 체결(H0STCNT0) + 호가(H0STASP0) 합산 **20개** (향후 60개 확장 예정). 설계의 `max_subscriptions: 50`과 충돌.

### 3.2 해결: 2-Tier 구독 모델

```yaml
# SubscriptionRouter 설정 변경
subscription_router:
  tier1_ws:
    max_symbols: 20                 # WebSocket 실시간
    priority_rule: "in_position > entry_triggered > watching(by_priority)"
    data_types: [H0STCNT0]         # 체결가만 (호가는 Path 6B로 이동)
  
  tier2_poll:
    max_symbols: 30                 # REST 폴링
    poll_interval_seconds: 3        # 3초 주기
    data_scope: "quote_only"        # 현재가 스냅샷만
  
  total_max: 50                     # Tier 1 + Tier 2 합산
  
  auto_promotion:
    trigger: "entry_triggered"      # WATCHING → ENTRY_TRIGGERED 시 Tier 2 → Tier 1 자동 승격
    demotion: "position_closed"     # 포지션 청산 후 Tier 1 → Tier 2 강등
```

### 3.3 SubscriptionPort 확장

```python
# 기존 SubscriptionPort에 추가
class SubscriptionTier(Enum):
    REALTIME_WS = "tier1"       # WebSocket 실시간
    POLLING_REST = "tier2"      # REST 폴링

@dataclass(frozen=True)
class SubscriptionChange:
    action: str                 # "subscribe" | "unsubscribe"
    symbol: str
    tier: SubscriptionTier      # ★ 신규 필드
    reason: str
    priority: int
    timestamp: datetime = field(default_factory=datetime.now)

class SubscriptionPort(ABC):
    # 기존 메서드 유지 + 추가
    
    @abstractmethod
    async def promote_tier(self, symbol: str) -> bool:
        """Tier 2 → Tier 1 승격 (ENTRY_TRIGGERED 시)."""
        ...
    
    @abstractmethod
    async def demote_tier(self, symbol: str) -> bool:
        """Tier 1 → Tier 2 강등."""
        ...
    
    @abstractmethod
    async def get_tier_status(self) -> dict:
        """Tier별 구독 현황.
        Returns: {"tier1": {"count": 15, "symbols": [...]},
                  "tier2": {"count": 25, "symbols": [...]}}
        """
        ...
```

### 3.4 MarketDataReceiver 변경

MarketDataReceiver 내부에서 Tier별 데이터 수신 방식 분기:

```python
class MarketDataReceiver:
    async def _dispatch_tick(self, symbol: str, quote: Quote):
        """Tier 1(WS)과 Tier 2(REST) 모두 동일한 Quote 객체로 변환 후 하위에 전달.
        하위 노드(IndicatorCalculator, PositionMonitor)는 Tier를 알 필요 없음.
        """
        # Tier 정보는 메타데이터로만 전달
        quote_with_meta = quote._replace(
            metadata={"source": "ws" if self._is_ws_symbol(symbol) else "rest"}
        )
        await self._publish(quote_with_meta)
```

---

## 4. P-03: ApprovalGate 노드 신설

### 4.1 노드 정의

```yaml
# 신규 노드 — graph_ir에 추가
approval_gate:
  path: path1.1b
  runMode: stateful-service
  llm_level: L0
  category: Core
  
  description: |
    3-Mode 매매의 SEMI_AUTO 모드를 처리하는 게이트 노드.
    AUTO: 즉시 통과. SEMI_AUTO: Telegram 알림 → 사람 확인 → 통과/폐기.
    MANUAL: 이 체인을 타지 않음 (P-04 MANUAL 경로 참조).
  
  state:
    pending_approvals: dict       # correlation_id → {order_request, trading_context, expires_at}
    mode: ExecutionMode           # ConfigStore에서 읽음
  
  config:
    approval_timeout_seconds: 120
    max_pending: 10               # 동시 대기 최대 10건
    auto_reject_on_timeout: true
  
  ports_used:
    - input: SignalOutput (from StrategyEngine)
    - output: SignalOutput (to RiskGuard, 통과 시)
    - output: ApprovalNotification (to AlertDispatcher, SEMI_AUTO 시)
    - input: ApprovalResponse (from CommandController, approve/reject)
```

### 4.2 내부 로직

```python
"""path1/nodes/approval_gate.py"""

class ApprovalGate:
    async def process_signal(self, signal: SignalOutput, ctx: TradingContext):
        mode = await self._config_store.get("execution_mode")
        
        if mode == ExecutionMode.AUTO:
            # 즉시 통과
            return await self._forward_to_risk_guard(signal, ctx)
        
        elif mode == ExecutionMode.SEMI_AUTO:
            # 1. 대기 큐에 등록
            approval_id = str(uuid.uuid4())
            self._pending[approval_id] = PendingApproval(
                approval_id=approval_id,
                signal=signal,
                context=ctx,
                expires_at=datetime.now() + timedelta(
                    seconds=self._config.approval_timeout_seconds
                ),
            )
            
            # 2. Telegram 알림 발송
            await self._alert_dispatcher.send(Alert(
                priority=AlertPriority.HIGH,
                title=f"매매 확인 요청: {signal.symbol} {signal.side}",
                body=(
                    f"종목: {signal.symbol}\n"
                    f"방향: {signal.side}\n"
                    f"강도: {signal.strength:.1%}\n"
                    f"사유: {signal.reason}\n"
                    f"전략: {signal.strategy_id}\n"
                    f"\n/approve {approval_id}\n/reject {approval_id}"
                ),
                channels=[AlertChannel.TELEGRAM],
                metadata={"approval_id": approval_id, "inline_keyboard": True},
            ))
            
            # 3. 비동기 대기 (타임아웃까지)
            # CommandController에서 approve/reject가 오면 _on_approval_response() 호출
            return  # 여기서 리턴 — 승인 시 _on_approval_response에서 forward
        
        elif mode == ExecutionMode.MANUAL:
            # MANUAL 모드에서는 전략 신호를 무시 (로깅만)
            await self._audit_log("signal_ignored_manual_mode", signal)
            return
    
    async def on_approval_response(self, approval_id: str, approved: bool):
        pending = self._pending.pop(approval_id, None)
        if not pending:
            return  # 이미 만료/처리됨
        
        if approved:
            # TradingContext의 E2E budget 재확인 (대기 시간 경과)
            if pending.context.is_expired():
                await self._audit_log("approval_expired_budget", pending.signal)
                await self._alert_send("승인했지만 시세가 오래되어 폐기됨")
                return
            
            # 시세 신선도 재확인
            if pending.context.is_price_stale():
                # 현재 시세로 재갱신
                fresh_quote = await self._market_data.get_quote(pending.signal.symbol)
                pending.context.price_observed_at = fresh_quote.timestamp
                pending.context.chain_started_at = datetime.now()  # budget 리셋
            
            await self._forward_to_risk_guard(pending.signal, pending.context)
        else:
            await self._audit_log("signal_rejected_by_user", pending.signal)
    
    async def _cleanup_expired(self):
        """만료된 대기 건 정리 — 1초마다 실행."""
        now = datetime.now()
        expired = [k for k, v in self._pending.items() if v.expires_at < now]
        for approval_id in expired:
            pending = self._pending.pop(approval_id)
            await self._audit_log("approval_timeout", pending.signal)
            if self._config.auto_reject_on_timeout:
                await self._alert_send(f"⏰ 타임아웃 자동 거부: {pending.signal.symbol}")
```

### 4.3 신규 Edge (3개)

```yaml
# E-AG-01: StrategyEngine → ApprovalGate
- id: e_strategy_to_approval
  type: DataFlow
  role: DataPipe
  source: strategy_engine
  target: approval_gate
  payload: SignalOutput
  contract:
    delivery: sync
    ordering: strict
    timeout_ms: 50
    idempotency: false
  note: "기존 e_strategy_to_riskguard를 대체. StrategyEngine은 이제 RiskGuard가 아닌 ApprovalGate에 연결"

# E-AG-02: ApprovalGate → RiskGuard (승인 후)
- id: e_approval_to_riskguard
  type: DataFlow
  role: DataPipe
  source: approval_gate
  target: risk_guard
  payload: SignalOutput
  contract:
    delivery: sync
    ordering: strict
    timeout_ms: 200
    idempotency: false

# E-AG-03: ApprovalGate → AlertDispatcher (SEMI_AUTO 알림)
- id: e_approval_to_alert
  type: Event
  role: EventNotify
  source: approval_gate
  target: alert_dispatcher
  payload: Alert
  contract:
    delivery: async
    ordering: best-effort
    timeout_ms: 5000
    idempotency: true
```

### 4.4 기존 Edge 변경

```yaml
# 삭제: e_strategy_to_riskguard (StrategyEngine → RiskGuard 직접 연결)
# 대체: e_strategy_to_approval + e_approval_to_riskguard
#
# 주문 체인 변경:
#   변경 전: StrategyEngine → RiskGuard → DedupGuard → OrderExecutor
#   변경 후: StrategyEngine → ApprovalGate → RiskGuard → DedupGuard → OrderExecutor
```

---

## 5. P-04: MANUAL 모드 주문 경로

### 5.1 CommandType 확장

```python
# common.py CommandType에 추가
class CommandType(Enum):
    # 기존 12종 유지
    # ...
    
    # 신규: 매매 명령 (MANUAL 모드)
    BUY_ORDER = "buy_order"
    SELL_ORDER = "sell_order"
    
    # 신규: 승인 명령 (SEMI_AUTO 모드)
    APPROVE_ORDER = "approve_order"
    REJECT_ORDER = "reject_order"

# 리스크 레벨 매핑 추가
COMMAND_RISK_MAP.update({
    CommandType.BUY_ORDER: CommandRiskLevel.MEDIUM,     # 확인 후 실행
    CommandType.SELL_ORDER: CommandRiskLevel.MEDIUM,
    CommandType.APPROVE_ORDER: CommandRiskLevel.LOW,     # 이미 신호 검증됨
    CommandType.REJECT_ORDER: CommandRiskLevel.READ_ONLY,
})
```

### 5.2 MANUAL 주문 흐름

```
Telegram: "/buy 005930 10 72000"  또는  "/sell 005930 10"
  │
  ▼
CommandController
  ├─ AuthGuard: jdw 확인
  ├─ 파싱: symbol=005930, qty=10, price=72000(지정가) 또는 None(시장가)
  ├─ RiskLevelGate: MEDIUM → 실행 전 확인 메시지
  │     "005930 삼성전자 10주 72,000원 매수합니다. /confirm 또는 /cancel"
  ├─ /confirm 수신 시:
  │     ManualOrderRequest 생성
  │     → RiskGuard (Pre-Order 22항목 검증)
  │     → DedupGuard → OrderExecutor
  └─ 결과 Telegram 회신: "005930 10주 72,000원 매수 주문 제출 완료 (주문번호: ...)"
```

### 5.3 신규 Edge (1개)

```yaml
# E-MO-01: CommandController → RiskGuard (MANUAL 주문)
- id: e_manual_order_to_riskguard
  type: DataFlow
  role: DataPipe
  source: command_controller
  target: risk_guard
  payload: OrderRequest
  contract:
    delivery: sync
    ordering: strict
    timeout_ms: 5000
    idempotency: true
  note: "MANUAL 모드 전용. StrategyEngine을 거치지 않고 CommandController에서 직접 RiskGuard로"
```

### 5.4 CommandController → ApprovalGate 연결 (SEMI_AUTO 승인)

```yaml
# E-MO-02: CommandController → ApprovalGate (approve/reject)
- id: e_command_to_approval
  type: Event
  role: Command
  source: command_controller
  target: approval_gate
  payload: ApprovalResponse    # {approval_id, approved: bool}
  contract:
    delivery: sync
    ordering: strict
    timeout_ms: 1000
    idempotency: true
```

---

## 6. P-05: Boot / Shutdown / Crash Recovery 시퀀스

### 6.1 Boot Sequence

```yaml
boot_sequence:
  description: "장 시작 전 시스템 초기화 순서. 의존관계 순으로 실행."
  
  phase_1_infrastructure:
    order: 1
    steps:
      - name: config_load
        action: "ConfigStore에서 settings 로드"
        fail_action: "시스템 시작 중단"
      
      - name: db_connect
        action: "PostgreSQL + Redis 연결 확인"
        fail_action: "재시도 3회, 실패 시 시스템 시작 중단"
      
      - name: kis_token
        action: "TokenManager — KIS 접근토큰 발급/확인"
        fail_action: "재시도 3회, 실패 시 알림 + 시스템 시작 중단"
      
      - name: env_profile
        action: "EnvironmentProfile 로드 (demo/live 판별)"
        fail_action: "기본값 demo 적용"
  
  phase_2_state_restore:
    order: 2
    steps:
      - name: watchlist_restore
        action: "WatchlistStore → WatchlistManager 상태 복원"
        depends_on: [db_connect]
      
      - name: position_restore
        action: "PortfolioStore → PositionMonitor 보유 포지션 복원"
        depends_on: [db_connect]
      
      - name: fsm_restore
        action: "TradingFSM 마지막 상태 복원"
        depends_on: [db_connect]
      
      - name: crash_recovery
        action: "WAL 테이블 pending/submitted 레코드 확인 → 복구 프로세스"
        depends_on: [kis_token, position_restore, fsm_restore]
        detail: |
          1. audit_events에서 status='pending'/'submitted' WAL 레코드 조회
          2. BrokerPort.get_pending_orders() + get_daily_orders() 대조
          3. 불일치 발견 시:
             - 실계좌 체결 ← FSM 미반영 → FSM 강제 갱신 + PositionMonitor 등록
             - FSM 주문 중 ← 실계좌 미존재 → FSM → Idle 복원
          4. WatchlistManager ↔ PortfolioStore 포지션 대조
          5. 불일치 리포트 → AuditLogger + AlertDispatcher(HIGH)
  
  phase_3_connection:
    order: 3
    steps:
      - name: ws_connect
        action: "MarketDataReceiver — KIS WebSocket 연결"
        depends_on: [kis_token]
      
      - name: subscription_start
        action: "SubscriptionRouter — 복원된 워치리스트 기반 구독 시작"
        depends_on: [watchlist_restore, ws_connect]
      
      - name: execution_notice_subscribe
        action: "OrderExecutor — 체결통보(H0STCNI0/H0STCNI9) 구독"
        depends_on: [ws_connect]
  
  phase_4_logic:
    order: 4
    steps:
      - name: strategy_load
        action: "StrategyLoader — 전략 .py 파일 로딩"
        depends_on: [config_load]
      
      - name: screener_warmup
        action: "Screener — 장 시작 전 스크리닝 (pre_market 모드)"
        depends_on: [subscription_start]
      
      - name: indicator_warmup
        action: "IndicatorCalculator — 과거 200봉 프리로드"
        depends_on: [ws_connect]
  
  phase_5_ready:
    order: 5
    steps:
      - name: system_started
        action: "AuditLogger — SYSTEM_STARTED 이벤트"
      
      - name: startup_alert
        action: "AlertDispatcher — 시스템 시작 완료 알림"
        message: |
          ✅ HR-DAG 시작 완료
          모드: {execution_mode}
          환경: {trading_env}
          워치리스트: {watchlist_count}종목
          보유: {position_count}종목
          복구: {recovery_result}
```

### 6.2 Shutdown Sequence

```yaml
shutdown_sequence:
  description: "장 마감 후 정리. 안전 방향 우선."
  
  phase_1_trading_stop:
    - name: cancel_unfilled
      action: "OrderExecutor — 미체결 주문 전량 취소"
      timeout_seconds: 30
    
    - name: halt_signals
      action: "ApprovalGate — pending approvals 전량 자동 reject"
    
    - name: halt_strategy
      action: "StrategyEngine — 신호 생성 중지"
  
  phase_2_reconciliation:
    - name: account_sync
      action: "BrokerPort.get_account() → PortfolioStore 대조"
    
    - name: daily_pnl
      action: "PortfolioStore.daily_pnl 기록"
    
    - name: watchlist_persist
      action: "WatchlistManager — 전체 상태 WatchlistStore에 영속화"
  
  phase_3_disconnect:
    - name: ws_disconnect
      action: "MarketDataReceiver — WebSocket 해제"
    
    - name: system_stopped
      action: "AuditLogger — SYSTEM_STOPPED 이벤트"
  
  phase_4_report:
    - name: daily_report
      action: "DailyReporter — 일일 리포트 생성 + Telegram 발송"
```

---

## 7. P-06: SimplifiedPortfolioCheck (Phase 1)

### 7.1 RiskGuard Pre-Order 22항목 (18 → 22)

기존 18항목에 추가되는 4항목 (Path 4 없을 때 RiskGuard 내장):

```python
"""path1/nodes/risk_guard.py — Phase 1 확장"""

# 기존 Step 1~5 유지 (종목/시장/자금/주문유형 검증)

# Step 6 (신규): 포트폴리오 수준 검증 — Phase 1 한정
class SimplifiedPortfolioCheck:
    """Path 4 RiskBudgetManager 부재 시 대행.
    Phase 2에서 Path 4 활성화 시 이 클래스는 비활성화되고
    ExposureCache 기반 검증으로 전환.
    """
    
    async def check(self, order: OrderRequest, config: dict) -> PreOrderCheck:
        snapshot = await self._portfolio_store.get_latest_snapshot()
        failed = []
        
        # Check 19: 일일 손실 한도
        if snapshot.daily_pnl_pct <= config["max_portfolio_loss_pct"]:
            failed.append("daily_loss_limit_reached")
        
        # Check 20: 단일 종목 비중
        order_value = order.quantity * (order.price or 0)
        if snapshot.total_equity > 0:
            weight = order_value / snapshot.total_equity * 100
            if weight > config["max_single_position_pct"]:
                # 축소 가능: 한도 내 최대 수량 계산
                max_value = snapshot.total_equity * config["max_single_position_pct"] / 100
                adjusted_qty = int(max_value / (order.price or 1))
                return PreOrderCheck(
                    passed=True, verdict="REDUCED",
                    adjusted_quantity=adjusted_qty,
                    reason=f"단일 종목 비중 {weight:.1f}% > {config['max_single_position_pct']}%"
                )
        
        # Check 21: 동시 보유 종목 수
        if order.side == OrderSide.BUY:
            if snapshot.position_count >= config["max_in_position"]:
                failed.append("max_positions_reached")
        
        # Check 22: 일일 거래 횟수
        if snapshot.trade_count_today >= config["max_daily_trades"]:
            failed.append("daily_trade_limit")
        
        return PreOrderCheck(
            passed=len(failed) == 0,
            failed_checks=failed,
        )
```

---

## 8. P-07: EnvironmentProfile

### 8.1 타입 정의 (core/domain/common.py에 추가)

```python
@dataclass(frozen=True)
class EnvironmentProfile:
    """모의투자/실전 환경 분리 프로필.
    
    ConfigStore에서 로드. 모든 KIS 어댑터가 참조.
    """
    env: str                        # "demo" | "live"
    app_key: str
    app_secret: str
    account_no: str                 # "50012345-01"
    hts_id: str
    
    # 환경별 차이
    api_domain: str                 # demo: "openapivts.koreainvestment.com:29443"
                                    # live: "openapi.koreainvestment.com:9443"
    ws_domain: str                  # demo: "ops.koreainvestment.com:31000"
                                    # live: "ops.koreainvestment.com:21000"
    
    allowed_order_divisions: list[str]   # demo: ["00","01"] / live: 전체 24종
    ws_execution_tr_id: str              # demo: "H0STCNI9" / live: "H0STCNI0"
    rest_rate_limit_per_second: int      # demo: 10 / live: 20
    
    # 주문 tr_id 매핑
    buy_tr_id: str                  # demo: "VTTC0802U" / live: "TTTC0802U"
    sell_tr_id: str                 # demo: "VTTC0801U" / live: "TTTC0801U"
    cancel_tr_id: str               # demo: "VTTC0803U" / live: "TTTC0803U"
    modify_tr_id: str               # demo: "VTTC0803U" / live: "TTTC0803U"
```

### 8.2 YAML 설정

```yaml
# settings.yaml
environment:
  active: "demo"                    # ★ 이것만 바꾸면 전환
  
  profiles:
    demo:
      api_domain: "openapivts.koreainvestment.com:29443"
      ws_domain: "ops.koreainvestment.com:31000"
      app_key: "${KIS_DEMO_APP_KEY}"
      app_secret: "${KIS_DEMO_APP_SECRET}"
      account_no: "${KIS_DEMO_ACCOUNT}"
      allowed_order_divisions: ["00", "01"]
      ws_execution_tr_id: "H0STCNI9"
      rest_rate_limit_per_second: 10
      buy_tr_id: "VTTC0802U"
      sell_tr_id: "VTTC0801U"
    
    live:
      api_domain: "openapi.koreainvestment.com:9443"
      ws_domain: "ops.koreainvestment.com:21000"
      app_key: "${KIS_LIVE_APP_KEY}"
      app_secret: "${KIS_LIVE_APP_SECRET}"
      account_no: "${KIS_LIVE_ACCOUNT}"
      allowed_order_divisions: ["00","01","02","03","04","05","06","07","11","12","13","14","15","16","21","22","23","24"]
      ws_execution_tr_id: "H0STCNI0"
      rest_rate_limit_per_second: 18
      buy_tr_id: "TTTC0802U"
      sell_tr_id: "TTTC0801U"
```

---

## 9. P-08: TokenManager

### 9.1 구현

```python
"""infrastructure/token_manager.py"""

class TokenManager:
    """KIS API 접근토큰 자동 관리.
    
    책임:
    1. 토큰 발급 (최초)
    2. 만료 30분 전 자동 갱신
    3. 토큰 파일 캐싱 (재시작 시 재사용)
    4. 갱신 실패 시 알림
    
    위치: KISAPIGateway 내부 컴포넌트
    """
    
    TOKEN_REFRESH_BEFORE_SECONDS = 1800  # 만료 30분 전 갱신
    TOKEN_FILE = "./config/kis_token.json"
    
    def __init__(self, env_profile: EnvironmentProfile):
        self._profile = env_profile
        self._token: str | None = None
        self._expires_at: datetime | None = None
        self._refresh_task: asyncio.Task | None = None
    
    async def get_valid_token(self) -> str:
        if self._token and self._expires_at and \
           datetime.now() < self._expires_at - timedelta(seconds=self.TOKEN_REFRESH_BEFORE_SECONDS):
            return self._token
        return await self.refresh()
    
    async def refresh(self) -> str:
        response = await self._request_token()
        self._token = response["access_token"]
        self._expires_at = datetime.fromisoformat(response["access_token_token_expired"])
        await self._save_to_file()
        return self._token
    
    async def start_auto_refresh(self):
        """백그라운드 자동 갱신 태스크."""
        self._refresh_task = asyncio.create_task(self._refresh_loop())
    
    async def _refresh_loop(self):
        while True:
            if self._expires_at:
                sleep_seconds = max(
                    0,
                    (self._expires_at - datetime.now()).total_seconds() - self.TOKEN_REFRESH_BEFORE_SECONDS
                )
                await asyncio.sleep(sleep_seconds)
                try:
                    await self.refresh()
                except Exception as e:
                    # 갱신 실패 시 5분 후 재시도 + 알림
                    await asyncio.sleep(300)
            else:
                await asyncio.sleep(60)
```

---

## 10. P-09: MarketContextBuilder 노드 신설

### 10.1 노드 정의

```yaml
market_context_builder:
  path: path6
  runMode: event
  llm_level: L0
  category: Core
  
  description: |
    Path 6의 다른 노드가 MarketIntelStore에 데이터를 쓸 때마다
    해당 종목의 MarketContext를 재계산하여 market_context_cache에 저장.
    이전에 "별도 노드가 아닌 materialized view" 라고 적었던 것을 노드로 명확화.
  
  trigger: |
    다음 이벤트 중 하나 발생 시:
    - SupplyDemandAnalyzer가 supply_demand 테이블 갱신
    - OrderBookAnalyzer가 orderbook_analysis 갱신
    - MarketRegimeDetector가 market_regime 갱신
    - StockStateMonitor가 stock_state 갱신
  
  output: MarketContext → market_context_cache (MarketIntelStore)
  
  config:
    debounce_ms: 200              # 200ms 내 중복 트리거 병합
    watchlist_only: true          # 워치리스트 + 보유종목만 재계산
```

### 10.2 신규 Edge (1개)

```yaml
- id: e_intel_nodes_to_context_builder
  type: Event
  role: EventNotify
  source: "path6.*"              # SD/OB/Regime/State 모두
  target: market_context_builder
  payload: StoreUpdateEvent      # {table, symbol, updated_at}
  contract:
    delivery: async
    ordering: best-effort
    timeout_ms: 500
    idempotency: true
```

---

## 11. P-10: Path 6 서브패스 분리 (6A/6B)

### 11.1 분리 기준

```yaml
path6:
  subpaths:
    6a_realtime:
      name: "Realtime Intelligence"
      description: "실시간 시장 감시. Phase 1 필수."
      nodes:
        - MarketRegimeDetector (event)
        - StockStateMonitor (poll 5분)
        - MarketContextBuilder (event)
      priority: "Path 1 다음으로 높음"
      api_budget: "초당 2건"
    
    6b_periodic:
      name: "Periodic Intelligence"
      description: "주기적 수급/호가/조건검색. Phase 2."
      nodes:
        - SupplyDemandAnalyzer (poll 1분)
        - OrderBookAnalyzer (stream)
        - ConditionSearchBridge (batch 30분)
      priority: "배치 수준"
      api_budget: "초당 3건"
```

---

## 12. P-11: VI 즉시 차단 이중 경로

### 12.1 현재 문제

MarketRegimeDetector → Event Edge → Path 1 (100ms) 경로만 존재. 주문 제출 중이면 이벤트 처리 지연.

### 12.2 해결: Redis + in-memory 이중 경로

```python
"""path6/nodes/market_regime_detector.py — 확장"""

class MarketRegimeDetector:
    async def on_vi_detected(self, symbol: str, vi_status: VIStatus):
        # 경로 1: Redis에 즉시 세팅 (OrderExecutor가 주문 전 확인)
        await self._redis.set(
            f"halt:vi:{symbol}",
            json.dumps(asdict(vi_status)),
            ex=300,  # 5분 TTL
        )
        
        # 경로 2: Event Edge로 Path 1 통보 (기존)
        await self._publish_regime_change(vi_status)
        
        # 경로 3: in-memory 플래그 (같은 프로세스인 경우)
        self._vi_flags[symbol] = vi_status


"""path1/nodes/order_executor.py — 확장"""

class OrderExecutor:
    async def submit_order(self, order: OrderRequest, ctx: TradingContext):
        # 주문 제출 직전 — VI 확인 (Redis + in-memory)
        vi_key = f"halt:vi:{order.symbol}"
        vi_active = await self._redis.exists(vi_key)
        
        if vi_active:
            if order.order_type == OrderType.MARKET:
                return OrderResult(status=OrderStatus.REJECTED,
                                   message="VI 발동 중 — 시장가 차단")
            # 지정가는 통과 (force_limit_on_vi 설정에 따라)
        
        # 이후 기존 주문 로직
        ...
```

---

## 13. P-12 ~ P-17: 경량 패치

### P-12: CommandController 핸들러 그룹핑

```python
# CommandController 내부 라우팅 테이블
COMMAND_HANDLERS = {
    # Trading
    CommandType.HALT_TRADING: TradingCommandHandler,
    CommandType.RESUME_TRADING: TradingCommandHandler,
    CommandType.CLOSE_POSITION: TradingCommandHandler,
    CommandType.CLOSE_ALL: TradingCommandHandler,
    CommandType.BUY_ORDER: TradingCommandHandler,       # P-04
    CommandType.SELL_ORDER: TradingCommandHandler,       # P-04
    CommandType.APPROVE_ORDER: TradingCommandHandler,    # P-04
    CommandType.REJECT_ORDER: TradingCommandHandler,     # P-04
    
    # Strategy
    CommandType.DEPLOY_STRATEGY: StrategyCommandHandler,
    CommandType.RETIRE_STRATEGY: StrategyCommandHandler,
    CommandType.UPDATE_PARAMS: StrategyCommandHandler,
    
    # System
    CommandType.RESTART_NODE: SystemCommandHandler,
    CommandType.RELOAD_CONFIG: SystemCommandHandler,
    CommandType.STATUS: SystemCommandHandler,
    CommandType.POSITIONS: SystemCommandHandler,
    CommandType.HEALTH: SystemCommandHandler,
}
```

### P-13: StatusReport 타입

```python
# core/domain/audit.py에 추가
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
    total_equity: float
    cash: float
    pending_orders: int
    pending_approvals: int
    unhealthy_components: list[str]
    last_trade_at: str | None
    uptime_hours: float
    tier1_ws_count: int          # P-02 Tier별 구독 수
    tier2_poll_count: int
```

### P-14: demo → live 전환 절차

```yaml
environment_switch_procedure:
  description: "모의투자 → 실전 전환. 역방향도 동일."
  
  pre_conditions:
    - "모의투자에서 최소 5거래일 정상 운영 확인"
    - "일일 리포트 5일분 검토 완료"
  
  steps:
    1: { action: "/halt", note: "거래 중단" }
    2: { action: "모의 포지션 전량 청산 확인", note: "실전에는 포지션 없음" }
    3: { action: "settings.yaml environment.active: live", note: "환경 전환" }
    4: { action: "시스템 재시작", note: "EnvironmentProfile 전체 교체" }
    5: { action: "BrokerPort.get_account() 실전 계좌 확인", note: "잔고 확인" }
    6: { action: "ConfigStore 위험 한도 실전용 조정", note: "금액 하향" }
    7: { action: "/mode manual", note: "MANUAL로 시작 (AUTO 즉시 전환 금지)" }
    8: { action: "/resume", note: "거래 재개" }
    9: { action: "1거래일 MANUAL 운영 후 /mode semi_auto", note: "단계적 전환" }
```

### P-15: Phase 1 전략 파일 로딩 규약

```yaml
strategy_loading:
  phase1:
    method: "filesystem"
    directory: "./strategies/"
    pattern: "*.py"
    required_base: "BaseStrategy"
    hot_reload: false
    validation:
      - "AST 파싱 성공"
      - "BaseStrategy 상속 확인"
      - "strategy_id, params 속성 존재"
      - "evaluate() 메서드 존재"
      - "금지 import 없음 (os, subprocess, socket 등)"
  
  # Phase 2에서 StrategyStore(DB) 기반으로 전환
  phase2:
    method: "database"
    store: StrategyStore
    status_filter: ["APPROVED", "DEPLOYED"]
```

### P-16: Redis critical 플래그 이중 저장 (Phase 2)

```
VI/CB 같은 critical 플래그:
  Write: MarketRegimeDetector → Redis SET + asyncio.Event broadcast
  Read: OrderExecutor → Redis GET (1차) + in-memory flag (2차)
  Fallback: Redis 장애 시 in-memory flag만으로 판단
```

### P-17: Path별 KIS API 호출 예산

```yaml
api_budget:
  total_per_second: 18
  allocation:
    order_execution: 4             # 주문/정정/취소 (최우선)
    risk_check: 2                  # 가능수량/잔고 조회
    market_data_ws_fallback: 4     # Tier 2 REST 폴링
    path6_realtime: 2              # 종목상태/시장환경
    path6_periodic: 3              # 수급/호가/순위
    screening: 2                   # Screener 순위 API
    reserve: 1                     # 예비
  
  overflow_policy:
    strategy: "queue_with_priority"
    max_queue_size: 100
    queue_timeout_seconds: 5
```

---

## 14. 신규 Validation Rules (+7)

| Rule ID | Description | Severity |
|---------|-------------|----------|
| V-PATCH2-001 | 모든 KIS REST 호출은 KISAPIGateway 경유 필수 | error |
| V-PATCH2-002 | WebSocket 구독 수가 SubscriptionTier.tier1_ws.max_symbols 초과 불가 | error |
| V-PATCH2-003 | SEMI_AUTO 모드에서 ApprovalGate 미경유 주문 금지 | error |
| V-PATCH2-004 | MANUAL 주문도 RiskGuard Pre-Order 22항목 통과 필수 | error |
| V-PATCH2-005 | Boot Sequence phase_2 완료 전 phase_3 진입 금지 | error |
| V-PATCH2-006 | EnvironmentProfile.env와 ConfigStore.trading_env 불일치 시 시스템 시작 중단 | error |
| V-PATCH2-007 | demo 환경에서 allowed_order_divisions 외 주문 유형 사용 시 차단 | error |

---

## 15. 영향받는 문서 변경 목록

| 문서 | 변경 내용 | 패치 ID |
|------|----------|---------|
| `graph_ir_v1.0.yaml` | nodes +2, edges +6, stats 갱신, infra 섹션 추가 | P-01~P-11 |
| `port_interface_path1_v2.0.md` | SubscriptionPort 확장 (Tier), ApprovalGate 추가, Pre-Order 22항목 | P-02, P-03, P-06 |
| `port_interface_path5_v1.0.md` | CommandType +4, MANUAL 주문 흐름, StatusReport | P-04, P-12, P-13 |
| `port_interface_path6_v1.0.md` | MarketContextBuilder 노드, 6A/6B 서브패스 | P-09, P-10 |
| `edge_contract_definition_v1.0.md` | +6 edges, 기존 e_strategy_to_riskguard 삭제 | P-03, P-04, P-09 |
| `system_manifest_v1.0.md` | 45 nodes, 95 edges, infra components 추가 | 전체 |
| `node_blueprint_path1_v1.0.md` | ApprovalGate blueprint, RiskGuard 22항목 | P-03, P-06 |
| `shared_domain_types_v1.0.md` | +5 타입 (EnvironmentProfile, StatusReport 등) | P-07, P-13 |
| `order_lifecycle_spec_v1.0.md` | MANUAL 주문 진입 경로, EnvironmentProfile 참조 | P-04, P-07 |
| `shared_store_ddl_v1.0.md` | approval_queue 테이블 (선택), config 초기값 갱신 | P-03 |
| `INDEX.md` | Phase 1 노드 18→20, Boot/Shutdown 참조, 3-Mode 상세 | 전체 |

---

## 16. Graph IR 변경 요약 (graph_ir_v1.0.yaml 반영분)

```yaml
# === 신규 nodes ===
approval_gate:
  path: path1.1b
  runMode: stateful-service
  llm_level: L0
  config:
    approval_timeout_seconds: 120
    max_pending: 10

market_context_builder:
  path: path6
  runMode: event
  llm_level: L0
  config:
    debounce_ms: 200
    watchlist_only: true

# === 삭제 edge ===
# e_strategy_to_riskguard (ApprovalGate로 대체)

# === 신규 edges (+6) ===
- e_strategy_to_approval          # StrategyEngine → ApprovalGate
- e_approval_to_riskguard         # ApprovalGate → RiskGuard
- e_approval_to_alert             # ApprovalGate → AlertDispatcher
- e_manual_order_to_riskguard     # CommandController → RiskGuard (MANUAL)
- e_command_to_approval           # CommandController → ApprovalGate (approve/reject)
- e_intel_nodes_to_context_builder # Path 6 nodes → MarketContextBuilder

# === stats 갱신 ===
stats:
  nodes: 45                       # 43 → 45
  edges: 95                       # 89 → 95 (+6)
  domain_types: 96                # 91 → 96 (+5)
  validation_rules: 46            # 39 → 46 (+7)
  pre_order_checks: 22            # 18 → 22

# === 신규 섹션: infrastructure ===
infrastructure:
  kis_api_gateway:
    max_requests_per_second: 18
    priority_levels: {order: 1, risk: 2, position: 3, market: 5, intel: 6, screen: 8, batch: 9}
  
  token_manager:
    refresh_before_seconds: 1800
    token_file: "./config/kis_token.json"
    retry_on_failure: 3

# === 신규 섹션: boot_shutdown ===
boot_shutdown:
  boot_phases: 5
  shutdown_phases: 4
  crash_recovery: true
```

---

*End of Document — Architecture Reinforcement Patch v2.0*
*17 patches | +2 nodes (43→45) | +6 edges (89→95) | +5 types (91→96)*
*+7 validation rules (39→46) | +2 infra components | +4 pre-order checks (18→22)*
*Boot/Shutdown/Crash Recovery 시퀀스 정의 | 3-Mode 매매 흐름 완성*
*KIS API Rate Limit 중앙 관리 | WebSocket 구독 Tier 분리*
