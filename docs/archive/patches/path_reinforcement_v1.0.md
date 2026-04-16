# Path Analysis Reinforcement Design — v1.0

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | path_reinforcement_v1.0 |
| 선행 문서 | architecture_review_patch_v1.0, edge_contract_definition_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |
| 동기 | 경로 분석에서 발견된 4개 이슈 + 추가 구조 보강 |

---

## 1. 보강 대상 요약

| ID | 이슈 | 위험도 | 해결 |
|----|------|-------|------|
| R1 | 매수 체인 12 hop — E2E timestamp 전파 미구현 | 중 | TradingContext 전파 프로토콜 |
| R2 | 청산→매수 경로 공유 시 매도 불필요 검증 | 저 | RiskGuard 매도 fast-path |
| R3 | Knowledge 영향 지연 — 긴급 뉴스 반응 부재 | 저→중 | Knowledge Fast-Path 신설 |
| R4 | AuditLogger 동시 4 Path 수신 부하 | 저 | Backpressure + batch flush |
| R5 | 부분 체결 + 청산 동시 발생 경합 | 중 | OrderExecutor 내부 FSM 잠금 |
| R6 | 장 시간대 전이 시 Edge 상태 변경 누락 | 중 | ClockPort 이벤트 브로드캐스트 |

---

## 2. R1: E2E Latency Chain — TradingContext 전파 프로토콜

### 2.1 문제

매수 체인이 12 hop을 통과하지만, E2E budget 시작 시각이 edge payload에 포함되는 구체적 메커니즘이 없다. edge_contract_definition의 Safety Contract에서 `trading_context.chain_started_at`을 선언했으나, 각 노드가 이를 어떻게 생성/전달/검증하는지 미정의.

### 2.2 해결: TradingContext 구조체 + Middleware

```python
"""core/domain/trading_context.py"""
from dataclasses import dataclass, field
from datetime import datetime
import uuid


@dataclass
class TradingContext:
    """주문 흐름 전체를 관통하는 컨텍스트.
    
    매수/매도 체인의 첫 노드(StrategyEngine)에서 생성되어
    마지막 노드(OrderExecutor)까지 모든 edge payload에 동반.
    """
    chain_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    chain_started_at: datetime = field(default_factory=datetime.now)
    price_observed_at: datetime | None = None   # 시세 관측 시각
    e2e_budget_ms: int = 500                    # 지정가 500ms, 시장가 200ms
    
    # 각 hop에서 자동 갱신
    hops: list[dict] = field(default_factory=list)
    # [{"node": "StrategyEngine", "entered_at": "...", "exited_at": "...", "elapsed_ms": 12}]
    
    def enter_node(self, node_id: str) -> None:
        """노드 진입 시 호출."""
        self.hops.append({
            "node": node_id,
            "entered_at": datetime.now().isoformat(),
            "exited_at": None,
            "elapsed_ms": None,
        })
    
    def exit_node(self) -> None:
        """노드 퇴출 시 호출."""
        if self.hops:
            hop = self.hops[-1]
            now = datetime.now()
            hop["exited_at"] = now.isoformat()
            entered = datetime.fromisoformat(hop["entered_at"])
            hop["elapsed_ms"] = int((now - entered).total_seconds() * 1000)
    
    def elapsed_ms(self) -> int:
        """체인 시작 후 경과 시간."""
        return int((datetime.now() - self.chain_started_at).total_seconds() * 1000)
    
    def remaining_ms(self) -> int:
        """남은 budget."""
        return max(0, self.e2e_budget_ms - self.elapsed_ms())
    
    def is_expired(self) -> bool:
        """budget 초과 여부."""
        return self.elapsed_ms() > self.e2e_budget_ms
    
    def is_price_stale(self, max_age_ms: int = 3000) -> bool:
        """시세 신선도 검증."""
        if self.price_observed_at is None:
            return True
        age = (datetime.now() - self.price_observed_at).total_seconds() * 1000
        return age > max_age_ms
```

### 2.3 Edge Middleware (각 노드에서 자동 적용)

```python
"""core/middleware/latency_guard.py"""

async def latency_guard_middleware(ctx: TradingContext, node_id: str, handler):
    """모든 주문 흐름 노드에 적용되는 미들웨어.
    
    1. 노드 진입 기록
    2. budget 초과 검사
    3. 핸들러 실행
    4. 노드 퇴출 기록
    """
    ctx.enter_node(node_id)
    
    # Budget 초과 시 즉시 drop
    if ctx.is_expired():
        ctx.exit_node()
        return DropResult(
            reason="e2e_budget_exceeded",
            chain_id=ctx.chain_id,
            elapsed_ms=ctx.elapsed_ms(),
            budget_ms=ctx.e2e_budget_ms,
            last_hop=node_id,
        )
    
    # 시세 신선도 검증 (RiskGuard 이후 노드에서만)
    if node_id in ("risk_guard", "dedup_guard", "order_executor"):
        if ctx.is_price_stale():
            ctx.exit_node()
            return DropResult(
                reason="stale_price",
                chain_id=ctx.chain_id,
                price_age_ms=int((datetime.now() - ctx.price_observed_at).total_seconds() * 1000),
            )
    
    result = await handler(ctx)
    ctx.exit_node()
    return result
```

### 2.4 적용 대상 노드

| 노드 | TradingContext 행동 |
|------|-------------------|
| StrategyEngine | **생성**: `TradingContext(price_observed_at=quote.timestamp)` |
| ConflictResolver (P4) | 전달: ctx 그대로 전파 |
| AllocationEngine (P4) | 전달: ctx 그대로 전파 |
| RiskGuard | **검증**: budget + stale price 체크 |
| DedupGuard | **검증**: budget 체크 |
| WAL write | 전달: ctx.chain_id를 WAL correlation_id로 |
| OrderExecutor | **최종 검증**: budget 체크 + 주문 제출 |

### 2.5 Drop 시 처리

```yaml
drop_policy:
  on_budget_exceeded:
    action: discard_order
    log: audit_event (severity: WARNING)
    alert: none  # 빈번할 수 있으므로 알림 없음
    metric: counter(e2e_budget_drops)
  
  on_stale_price:
    action: discard_order
    log: audit_event (severity: WARNING)
    alert: none
    metric: counter(stale_price_drops)
  
  on_drop_rate_spike:
    threshold: 10_drops_per_minute
    action: alert (MEDIUM) + anomaly_detector 통보
```

---

## 3. R2: 매도 전용 Fast-Path — RiskGuard 분기

### 3.1 문제

ExitExecutor가 매도 주문을 생성하여 SubPath 1B에 재진입할 때, RiskGuard의 18개 Pre-Order Check 중 매수 전용 항목(자금 검증, 포지션 한도, 섹터 비중 등)이 불필요하게 실행된다.

### 3.2 해결: RiskGuard 내부 매도 fast-path

```python
class RiskGuard:
    async def validate(self, order: OrderRequest, ctx: TradingContext) -> PreOrderCheck:
        if order.side == OrderSide.SELL:
            return await self._validate_sell(order, ctx)
        else:
            return await self._validate_buy(order, ctx)
    
    async def _validate_sell(self, order, ctx) -> PreOrderCheck:
        """매도 fast-path: 18개 중 7개만 실행.
        
        실행하는 검증:
        1. 거래 가능 여부 (StockState.is_tradable)
        2. VI 발동 여부 (시장가 차단)
        3. 호가단위 준수 (지정가일 때)
        4. 가격제한폭 범위
        5. 장 시간대 주문 유형 제한
        6. 매도 가능 수량 (D+2 고려)
        7. 서킷브레이커/사이드카
        
        건너뛰는 검증:
        8~14. 매수 가능 수량/금액, 증거금률, 미수금, 포지션 한도, 섹터 비중, 일일 손실 한도
        15~18. 전략 배분 비중, 상관종목 수, 분할 주문, 스톱지정가 조건가
        """
        checks = []
        checks.append(await self._check_tradable(order.symbol))
        checks.append(await self._check_vi(order))
        if order.order_type == OrderType.LIMIT:
            checks.append(await self._check_tick_size(order))
            checks.append(await self._check_price_limit(order))
        checks.append(await self._check_market_phase(order))
        checks.append(await self._check_sellable_qty(order))
        checks.append(await self._check_circuit_breaker())
        
        failed = [c for c in checks if not c.passed]
        return PreOrderCheck(
            passed=len(failed) == 0,
            failed_checks=[c.name for c in failed],
            warnings=[],
            corrected_price=None,
            fast_path="sell",   # 진단 표시
        )
```

### 3.3 Latency 개선 효과

| 경로 | 검증 항목 | 예상 시간 |
|------|---------|----------|
| 매수 full-path | 18개 | ~50ms |
| 매도 fast-path | 7개 | ~20ms |
| 손절 매도 (urgent) | 7개 + market order | ~15ms |

### 3.4 Edge Contract 변경

```yaml
# e_exit_to_riskguard 패치: 매도 전용 budget
- id: e_exit_to_riskguard
  payload: OrderRequest
  contract:
    delivery: sync
    ordering: strict
    timeout_ms: 100         # 기존 200ms → 100ms (매도 fast-path)
    idempotency: false
  metadata:
    fast_path: sell          # RiskGuard가 이 표시를 보고 분기
```

---

## 4. R3: Knowledge Fast-Path — 긴급 뉴스 즉시 반영

### 4.1 문제

Knowledge Pipeline이 batch_async(분~시간 단위)로만 작동하므로, "삼성전자 거래정지 예고" 같은 긴급 뉴스가 기존 파이프라인(수집→파싱→온톨로지→인과추론)을 거치면 수십 분 지연. 그 사이 시스템은 해당 종목에 진입 시도를 할 수 있다.

### 4.2 분석

현재 설계에서 긴급 종목 상태 변경은 Path 6 StockStateMonitor가 5분 주기 폴링으로 감지한다. 거래정지/투자위험은 이 경로로 이미 커버되지만, **뉴스 기반 정성 판단**(예: 부정 공시, 대표이사 횡령, 주요 거래처 파산)은 Path 6이 감지하지 못한다.

### 4.3 해결: Knowledge Urgent Channel

기존 배치 파이프라인 옆에 **긴급 채널**을 추가. 전체 온톨로지 구축 없이, 핵심 정보만 빠르게 MarketIntelStore에 전달.

```yaml
# Knowledge Scheduler에 urgent trigger 추가
knowledge_scheduler:
  triggers:
    batch:
      cron: "0 6 * * 1-5"
      target: external_collector
      pipeline: full   # 수집→파싱→온톨로지→인과추론→인덱스
    
    urgent:             # 신규
      source: dart_realtime_websocket   # DART 실시간 공시 알림
      filter:
        filing_types: ["주요사항보고", "조회공시", "거래정지", "투자주의환기"]
        keywords: ["횡령", "배임", "상장폐지", "감사의견거절", "자본잠식"]
      pipeline: fast   # 수집→간이파싱→MarketIntelStore 직접 기록
      max_latency_seconds: 30
```

### 4.4 Urgent Pipeline 구성

```
DART 실시간 공시 알림 (WebSocket/RSS)
       ↓ filter: 긴급 유형만
ExternalCollector.collect_urgent()
       ↓ RawDocument (1건)
DocumentParser.parse_urgent()          ← 정규식만 (LLM 호출 없음, L0)
       ↓ UrgentAlert
MarketIntelStore 직접 기록             ← 온톨로지 건너뜀
       ↓ Event Edge (신규)
Path 1 StrategyEngine                  ← MarketContext.caution_reasons에 추가
       + ExitConditionGuard            ← 보유종목이면 즉시 재평가
```

### 4.5 신규 Domain Type

```python
@dataclass(frozen=True)
class UrgentAlert:
    """긴급 지식 알림 — Knowledge Fast-Path 전용.
    
    온톨로지/인과추론을 거치지 않고 MarketIntelStore에 직접 기록.
    기존 batch 파이프라인과 별개 경로.
    """
    alert_id: str
    symbol: str | None            # 특정 종목 관련이면
    alert_type: str               # "filing_urgent" | "news_urgent"
    title: str
    summary: str                  # 간이 파싱 결과 (정규식 기반, 200자 이내)
    sentiment: float              # -1.0 ~ +1.0 (간이 판단)
    source_id: str                # DART 공시번호
    source_url: str
    impact_level: str             # "high" | "critical"
    published_at: datetime
    detected_at: datetime = field(default_factory=datetime.now)
```

### 4.6 신규 Edge (2개)

```yaml
# E-R3-01: Knowledge urgent → MarketIntelStore
- id: e_urgent_to_intel_store
  type: DataFlow
  role: DataPipe
  source: document_parser
  target: MarketIntelStore
  payload: UrgentAlert
  contract:
    delivery: async
    ordering: strict
    timeout_ms: 5000
    idempotency: true

# E-R3-02: MarketIntelStore → Path 1 (urgent event)
- id: e_urgent_to_path1
  type: Event
  role: EventNotify
  source: MarketIntelStore
  target: strategy_engine
  payload: UrgentAlert
  contract:
    delivery: async
    ordering: strict
    timeout_ms: 100
    idempotency: true
```

### 4.7 MarketContext 확장

```python
# MarketContext에 urgent_alerts 필드 추가
@dataclass(frozen=True)
class MarketContext:
    # ... 기존 필드 ...
    
    # R3: 긴급 알림 (Knowledge Fast-Path)
    urgent_alerts: list[UrgentAlert] = field(default_factory=list)
    # 최근 30분 이내 해당 종목 관련 긴급 알림
    
    # entry_safe 판단에 urgent_alerts 반영
    # urgent_alert with sentiment < -0.5 → entry_safe = False
    # urgent_alert with impact_level == "critical" → exit_urgent = True
```

### 4.8 기존 배치 파이프라인과의 관계

```
Urgent Channel은 배치 파이프라인을 대체하지 않는다.

Urgent: 즉시 → MarketContext에 caution 추가 (30분 TTL)
Batch:  수시간 후 → 온톨로지 구축 + 인과추론 → 장기 지식으로 정착

둘 다 KnowledgeStore에 영속화되지만:
- Urgent → market_context_cache.urgent_alerts (단기 캐시)
- Batch → ontology_triples + causal_links (장기 지식)
```

---

## 5. R4: AuditLogger Backpressure

### 5.1 문제

4개 Path에서 fire-and-forget으로 동시에 AuditEvent를 보내면, 장중 활발한 매매 시 초당 수십~수백 건이 AuditLogger에 몰린다.

### 5.2 해결: asyncio.Queue + Batch Flush

```python
"""path5/audit_logger.py — Backpressure 설계"""

class AuditLogger:
    def __init__(self, adapter: AuditPort, config: dict):
        self._adapter = adapter
        self._queue: asyncio.Queue = asyncio.Queue(maxsize=10000)
        self._flush_interval = config.get("flush_interval_seconds", 1.0)
        self._batch_size = config.get("batch_size", 100)
        self._running = False
    
    async def receive_event(self, event: AuditEvent) -> None:
        """fire-and-forget 수신. Queue full이면 drop + 카운터 증가."""
        try:
            self._queue.put_nowait(event)
        except asyncio.QueueFull:
            self._drop_count += 1
            if self._drop_count % 100 == 0:
                # 100건 drop마다 경고 (AnomalyDetector에 직접 통보)
                await self._notify_backpressure(self._drop_count)
    
    async def _flush_loop(self):
        """배치 플러시 루프."""
        while self._running:
            batch = []
            try:
                # 최대 batch_size만큼 또는 flush_interval까지 수집
                while len(batch) < self._batch_size:
                    event = await asyncio.wait_for(
                        self._queue.get(),
                        timeout=self._flush_interval,
                    )
                    batch.append(event)
            except asyncio.TimeoutError:
                pass
            
            if batch:
                await self._adapter.log_batch(batch)
                # AnomalyDetector에도 전달 (별도 큐)
                for event in batch:
                    await self._anomaly_queue.put(event)
```

### 5.3 Config

```yaml
audit_logger:
  queue_maxsize: 10000        # 10K 이벤트 버퍼
  flush_interval_seconds: 1.0 # 1초마다 flush
  batch_size: 100             # 최대 100건 배치
  drop_alert_threshold: 100   # 100건 drop마다 경고
```

---

## 6. R5: 부분 체결 + 청산 동시 경합

### 6.1 문제

OrderExecutor가 매수 주문의 부분 체결을 처리하는 중에, ExitConditionGuard가 해당 종목의 청산 조건 충족을 감지하여 매도 주문을 보낼 수 있다. 동시에 같은 종목에 대해 매수 부분 체결 + 매도 주문이 교차하면 상태 불일치.

예시:
```
t=0: 매수 100주 주문 → KIS API
t=1: 30주 체결 (PARTIALLY_FILLED) → PositionMonitor 등록 (30주)
t=2: 30주 기준 -3% 도달 → ExitConditionGuard → 매도 30주 주문 생성
t=3: 추가 50주 체결 → 이제 80주 보유인데 매도는 30주만 진행 중
t=4: 잔량 20주 → 어떻게 처리?
```

### 6.2 해결: Per-Symbol Order Lock + Position Snapshot Versioning

```python
"""core/concurrency/order_lock.py"""

class OrderLockManager:
    """종목별 주문 잠금.
    
    동일 종목에 대해 매수 체결 처리와 매도 주문 생성이 동시에
    발생하지 않도록 직렬화.
    """
    def __init__(self):
        self._locks: dict[str, asyncio.Lock] = {}
        self._active_orders: dict[str, str] = {}  # symbol → active_order_id
    
    def get_lock(self, symbol: str) -> asyncio.Lock:
        if symbol not in self._locks:
            self._locks[symbol] = asyncio.Lock()
        return self._locks[symbol]
    
    async def with_order_lock(self, symbol: str, handler):
        """종목별 잠금 하에 주문 처리."""
        async with self.get_lock(symbol):
            return await handler()


class OrderExecutor:
    async def on_fill_event(self, notification: ExecutionNotification):
        """체결 통보 처리 — 종목 잠금 하에 실행."""
        symbol = notification.stock_code
        async with self._lock_manager.get_lock(symbol):
            tracker = self._trackers[notification.order_no]
            tracker.filled_qty += notification.filled_qty
            tracker.remaining_qty = tracker.requested_qty - tracker.filled_qty
            
            if tracker.remaining_qty == 0:
                tracker.state = OrderLifecycleState.FILLED
                # PositionMonitor에 최종 수량 통보
                await self._notify_position_final(tracker)
            else:
                tracker.state = OrderLifecycleState.PARTIALLY_FILLED
                # PositionMonitor에 현재 수량 갱신
                await self._notify_position_partial(tracker)
```

### 6.3 부분 체결 중 청산 방지 규칙

```yaml
partial_fill_exit_rules:
  # 매수 주문이 PARTIALLY_FILLED 상태일 때
  while_buy_partial:
    allow_exit: false           # 매수 완료(FILLED) 또는 미체결 취소 후에만 청산
    allow_cancel_remaining: true # 잔량 취소는 허용
    timeout_then_cancel: true    # partial_fill_timeout 후 잔량 자동 취소
    
  # 취소 후 보유분에 대해서만 청산 판단
  after_cancel_remaining:
    recalculate_position: true   # 실제 체결된 수량으로 포지션 재계산
    re_evaluate_exit: true       # 청산 조건 재평가 (수량 변경으로 pnl 변동)
```

### 6.4 ExitConditionGuard 변경

```python
class ExitConditionGuard:
    async def evaluate(self, position: LivePosition) -> ExitSignal | None:
        # R5: 해당 종목에 진행 중인 매수 주문이 있으면 평가 보류
        if await self._lock_manager.has_active_buy(position.symbol):
            return None  # 매수 완료 후 다음 틱에서 재평가
        
        # 기존 6종 청산 조건 평가
        return await self._evaluate_conditions(position)
```

---

## 7. R6: 장 시간대 전이 이벤트 브로드캐스트

### 7.1 문제

장 상태 전이(PRE_MARKET → OPEN → CLOSING → CLOSED)가 발생할 때, 각 노드가 ClockPort.get_status()를 독립적으로 폴링하므로 전이 시점의 동기화가 보장되지 않는다. 특히 CLOSING 전이 시 "마감 3분 전 신규 주문 차단" 규칙이 노드별로 서로 다른 시점에 적용될 수 있다.

### 7.2 해결: MarketPhase 이벤트 Edge 추가

```yaml
# ClockPort에 브로드캐스트 기능 추가
clock_port_extension:
  methods:
    on_phase_change:
      callback: "(phase: MarketStatus, meta: dict) -> None"
      description: "장 상태 전이 시 즉시 콜백. 모든 관련 노드에 동시 통보."
```

### 7.3 신규 Domain Type

```python
@dataclass(frozen=True)
class MarketPhaseEvent:
    """장 시간대 전이 이벤트."""
    previous: MarketStatus
    current: MarketStatus
    transition_time: datetime
    meta: dict = field(default_factory=dict)
    # CLOSING: {"minutes_to_close": 10, "exit_only": true}
    # CLOSED: {"next_open": "2026-04-16T09:00:00"}
```

### 7.4 신규 Edge (1개)

```yaml
- id: e_clock_phase_broadcast
  type: Event
  role: EventNotify
  source: clock_port    # KRXClockAdapter가 발행
  target: "path1.*"     # Path 1 전 노드에 브로드캐스트
  payload: MarketPhaseEvent
  contract:
    delivery: async
    ordering: strict
    timeout_ms: 100
    idempotency: true
```

### 7.5 수신 노드별 행동

| 장 전이 | StrategyEngine | RiskGuard | OrderExecutor | ExitCondGuard | Screener |
|---------|---------------|-----------|---------------|---------------|----------|
| → OPEN | 전략 실행 시작 | 정상 검증 | 주문 수락 | 감시 시작 | 장중 스크리닝 |
| → CLOSING (10분전) | 매수 신호 억제 | 매수 차단, 매도만 | 매도만 수락 | 시간 청산 평가 | 중지 |
| → CLOSING (3분전) | 전면 중지 | 전면 차단 | 미체결 취소 시작 | FORCE_CLOSE 발동 | 중지 |
| → CLOSED | 중지 | 중지 | 미체결 전량 취소 | 중지 | 다음일 준비 |
| → PRE_MARKET | — | — | — | — | 장전 스크리닝 |

### 7.6 마감 카운트다운 타이머

```python
class ClockAdapter:
    async def _monitor_close(self):
        """장 마감 접근 시 단계적 이벤트 발행."""
        while self._market_open:
            remaining = await self.time_until_close()
            if remaining is None:
                await asyncio.sleep(10)
                continue
            
            remaining_min = remaining / 60
            
            if remaining_min <= 10 and not self._exit_only_sent:
                await self._broadcast(MarketPhaseEvent(
                    previous=MarketStatus.OPEN,
                    current=MarketStatus.CLOSING,
                    transition_time=datetime.now(),
                    meta={"minutes_to_close": 10, "exit_only": True},
                ))
                self._exit_only_sent = True
            
            if remaining_min <= 3 and not self._cutoff_sent:
                await self._broadcast(MarketPhaseEvent(
                    previous=MarketStatus.CLOSING,
                    current=MarketStatus.CLOSING,
                    transition_time=datetime.now(),
                    meta={"minutes_to_close": 3, "new_order_cutoff": True},
                ))
                self._cutoff_sent = True
            
            if remaining_min <= 1 and not self._force_close_sent:
                await self._broadcast(MarketPhaseEvent(
                    previous=MarketStatus.CLOSING,
                    current=MarketStatus.CLOSING,
                    transition_time=datetime.now(),
                    meta={"minutes_to_close": 1, "force_cancel_unfilled": True},
                ))
                self._force_close_sent = True
            
            await asyncio.sleep(5)
```

---

## 8. 전체 변경 통계

| 항목 | Review Patch 후 | 보강 후 | 변경 |
|------|---------------|--------|------|
| Edges | 86 | 89 | +3 (R3: 2개, R6: 1개) |
| Domain Types | 88 | 91 | +3 (TradingContext, UrgentAlert, MarketPhaseEvent) |
| Validation Rules | 35 | 39 | +4 |
| Contract Patterns | 7 | 7 | 변경 없음 |

### 8.1 신규 Validation Rules

| Rule ID | Description | Severity |
|---------|-------------|----------|
| V-REINF-001 | 주문 흐름 edge의 payload에 TradingContext 포함 필수 | error |
| V-REINF-002 | TradingContext.is_expired() == true인 주문은 즉시 drop | error |
| V-REINF-003 | PARTIALLY_FILLED 상태 종목에 대한 청산 시도 차단 | error |
| V-REINF-004 | MarketPhaseEvent 수신 후 1초 이내 edge 상태 변경 반영 | warning |

---

## 9. 구현 우선순위

| 순위 | 보강 | 이유 |
|------|------|------|
| 1 | R1 TradingContext | 매수/매도 체인의 기반 인프라. 이것 없이 E2E budget 강제 불가 |
| 2 | R5 Order Lock | 실전 매매 시 부분 체결 경합은 첫 날부터 발생 |
| 3 | R6 Phase Event | 장 마감 처리 오류 시 미체결 잔량이 익일로 이월 — 자본 위험 |
| 4 | R2 Sell Fast-Path | 손절 속도 최적화. R1 이후 자연스럽게 구현 |
| 5 | R4 Audit Backpressure | 장중 부하에서만 발생. 초기에는 단순 구현 가능 |
| 6 | R3 Knowledge Fast-Path | 긴급 뉴스 반응은 MVP 이후 추가해도 무방 |

---

*End of Document — Path Reinforcement Design v1.0*
*6 reinforcements | +3 edges (86→89) | +3 domain types (88→91) | +4 validation rules (35→39)*
*구현 순서: R1 → R5 → R6 → R2 → R4 → R3*
