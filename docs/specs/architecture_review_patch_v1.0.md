# Architecture Review Patch — v1.0

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | architecture_review_patch_v1.0 |
| 선행 문서 | architecture_review (구현 전 점검), edge_contract_definition_v1.0, shared_store_ddl_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |
| 목적 | Architecture Review에서 발견된 WARNING 3건 + ISSUE 1건의 공식 해결 |

---

## 1. 패치 요약

| ID | 분류 | 제목 | 영향 문서 | 해결 상태 |
|----|------|------|----------|----------|
| I1 | ISSUE | Domain Type 중복 정의 | 신규 shared_domain_types_v1.0 | ✅ 별도 문서 |
| W1 | WARNING | Path 4↔Path 1 동기 의존 | edge_contract_definition | ✅ 이 문서 |
| W2 | WARNING | WAL 패턴 미적용 | edge_contract_definition | ✅ 이 문서 |
| W3 | WARNING | PortfolioStore 동시 쓰기 | shared_store_ddl | ✅ 이 문서 |

---

## 2. W1 해결: Path 4↔Path 1 동기 의존 제거

### 2.1 문제

`e_risk_to_path1` edge (RiskBudgetManager → RiskGuard):
- `delivery: sync, timeout_ms: 200`
- Path 4 장애 시 Path 1 주문 실행 체인이 직접 차단됨
- Isolated Path 원칙 위반

### 2.2 해결: Redis 캐시 기반 비동기 분리

#### 2.2.1 아키텍처 변경

```
변경 전:
  RiskGuard ──[sync 200ms]──→ RiskBudgetManager (Path 4)
                                    ↓ check_order()
                               RiskCheckResult

변경 후:
  RiskBudgetManager (Path 4) ──[async]──→ Redis (exposure_cache)
                                              ↑ [sync read, local]
  RiskGuard (Path 1) ─────────────────────────┘
```

#### 2.2.2 Edge 변경

```yaml
# 삭제: e_risk_to_path1 (sync cross-path)
# 이 edge를 2개로 분리:

# 신규 Edge 1: Path 4 → Redis 캐시 (비동기 쓰기)
- id: e_risk_budget_to_cache
  type: DataFlow
  role: DataPipe
  source: risk_budget_manager
  target: ExposureCache  # Redis
  payload: RiskExposureSnapshot
  contract:
    delivery: fire-and-forget
    ordering: best-effort
    retry: { max_attempts: 2, backoff: fixed, dead_letter: false }
    timeout_ms: 500
    idempotency: true
  update_interval_ms: 1000  # 1초마다 갱신

# 신규 Edge 2: RiskGuard ← Redis 캐시 (로컬 동기 읽기)
- id: e_cache_to_risk_guard
  type: Dependency
  role: ConfigRef
  source: ExposureCache  # Redis
  target: risk_guard
  payload: RiskExposureSnapshot
  contract:
    delivery: sync
    ordering: best-effort
    timeout_ms: 10  # Redis 로컬 읽기 — 10ms 이내
    idempotency: true
```

#### 2.2.3 RiskExposureSnapshot (core/domain에 추가)

```python
@dataclass(frozen=True)
class RiskExposureSnapshot:
    """Path 4 RiskBudgetManager가 주기적으로 갱신하는 리스크 노출도 스냅샷.
    
    Redis에 캐싱. Path 1 RiskGuard가 로컬 읽기.
    """
    total_exposure_pct: float
    daily_loss_pct: float
    trade_count_today: int
    by_sector: dict               # {"반도체": 25.0, "자동차": 15.0}
    by_strategy: dict             # {"ma_cross": 40.0, "breakout": 32.5}
    is_halted: bool               # 전체 거래 중단 상태
    remaining_budget: dict        # {"daily_loss": 3.8, "trades": 15}
    updated_at: datetime
```

#### 2.2.4 Fallback 규칙

| 조건 | RiskGuard 행동 |
|------|--------------|
| Redis 정상 + 캐시 < 3초 | 캐시 기반 판단 |
| Redis 정상 + 캐시 > 3초 | 캐시 기반 + 경고 로깅 |
| Redis 장애 | 안전 방향 (수량 50% 축소, 1종목당 max 10%) |
| 캐시 is_halted == true | 즉시 REJECTED (halt 상태) |

#### 2.2.5 Edge 수 변경

- 삭제: 1개 (e_risk_to_path1)
- 추가: 2개 (e_risk_budget_to_cache, e_cache_to_risk_guard)
- 순증: +1 → 전체 84 → **85 Edges**
- Cross-Path sync edge: 14 → **13** (1개 제거)

---

## 3. W2 해결: WAL 패턴 Edge 수준 강제

### 3.1 문제

- `boundary_definition`에서 WAL(Write-Ahead Log)을 4대 취약점 방어의 핵심으로 선언
- 그러나 edge contract에서 주문 실행 전 이벤트 선기록 edge가 없음
- `e_executor_to_portfolio`는 체결 후 기록 (post-write) — 체결 전 crash 시 이벤트 유실

### 3.2 해결: Pre-Order WAL Edge 추가

#### 3.2.1 Edge 정의

```yaml
# 신규 Edge: 주문 제출 직전 WAL 기록
- id: e_preorder_wal_write
  type: DataFlow
  role: DataPipe
  source: dedup_guard
  target: AuditStore  # audit_events 테이블 직접
  payload: PreOrderWALEvent
  contract:
    delivery: sync              # ★ 반드시 동기 — 기록 완료 후에만 주문 진행
    ordering: strict
    retry: { max_attempts: 3, backoff: exponential, dead_letter: false }
    timeout_ms: 500
    idempotency: true           # correlation_id 기반
  failure_action: reject_order  # WAL 기록 실패 시 주문 폐기 (안전 방향)
```

#### 3.2.2 주문 흐름 변경

```
변경 전:
  DedupGuard → OrderExecutor → (주문 실행) → PortfolioStore

변경 후:
  DedupGuard → [WAL Write] → OrderExecutor → (주문 실행) → PortfolioStore
               ↓ sync                         ↓ 
          AuditStore                     AuditStore (체결 결과)
          (DRAFT 상태 기록)              (FILLED/REJECTED 기록)
```

#### 3.2.3 PreOrderWALEvent 타입

```python
@dataclass(frozen=True)
class PreOrderWALEvent:
    """주문 제출 전 WAL 이벤트.
    
    주문이 제출되기 전에 AuditStore에 기록.
    crash 복구 시 이 레코드로 미완료 주문 감지.
    """
    correlation_id: str           # E2E 체인 ID
    symbol: str
    side: str                     # "buy" | "sell"
    quantity: int
    order_type: str
    price: int | None
    strategy_id: str
    chain_started_at: datetime    # E2E budget 시작 시각
    wal_written_at: datetime = field(default_factory=datetime.now)
    status: str = "pending"       # "pending" → "submitted" → "completed" → "failed"
```

#### 3.2.4 Crash 복구 프로세스

```
시스템 재시작 시:
1. AuditStore에서 status="pending" 또는 "submitted"인 WAL 레코드 조회
2. 각 레코드에 대해:
   a. BrokerPort.get_pending_orders() 호출
   b. 해당 주문 발견 → status="submitted", 체결 대기
   c. 해당 주문 미발견 → status="failed" (주문이 KIS에 도달하지 않음)
   d. 체결 완료 발견 → status="completed", PortfolioStore 갱신
3. 복구 결과 → AuditLogger + AlertDispatcher(HIGH)
```

#### 3.2.5 Edge 수 변경

- 추가: 1개 (e_preorder_wal_write)
- 전체: 85 → **86 Edges**

---

## 4. W3 해결: PortfolioStore 동시 쓰기 제어

### 4.1 문제

| Writer | 테이블 | 빈도 |
|--------|--------|------|
| Path 1B OrderExecutor | trades, order_tracker | 체결 시 |
| Path 1C PositionMonitor | positions | 틱마다 |
| Path 4 PositionAggregator | daily_pnl, rebalance_history | 10초마다/일 1회 |

`positions` 테이블에서 동일 symbol에 대해 Path 1C(틱 기반 갱신)와 Path 1B(체결 반영)가 동시에 UPDATE할 수 있음.

### 4.2 해결: Advisory Lock + 테이블 수준 분리 명시

#### 4.2.1 DDL 추가 (shared_store_ddl에 반영)

```sql
-- ============================================================
-- PortfolioStore 동시 쓰기 제어
-- ============================================================

-- 4.1.1 positions 테이블에 advisory lock 함수 추가
CREATE OR REPLACE FUNCTION acquire_position_lock(p_symbol TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    lock_key BIGINT;
BEGIN
    -- symbol을 hash하여 advisory lock key 생성
    lock_key := hashtext(p_symbol);
    RETURN pg_try_advisory_xact_lock(lock_key);
END;
$$ LANGUAGE plpgsql;

-- 4.1.2 positions 업데이트 시 반드시 lock 획득
-- 애플리케이션 코드에서:
--   BEGIN;
--   SELECT acquire_position_lock('005930');
--   UPDATE positions SET ... WHERE symbol='005930' AND strategy_id=...;
--   COMMIT;  -- lock 자동 해제

-- 4.1.3 Writer 권한 매트릭스 (코멘트로 명시)
COMMENT ON TABLE positions IS 
  'Writers: Path1B(OrderExecutor-체결반영), Path1C(PositionMonitor-시가갱신). '
  'Concurrency: per-symbol advisory lock via acquire_position_lock(). '
  'Path4 PositionAggregator는 READ ONLY — 집계/스냅샷만.';

COMMENT ON TABLE trades IS 
  'Writer: Path1B(OrderExecutor) ONLY. Append-only. No concurrent write conflict.';

COMMENT ON TABLE daily_pnl IS 
  'Writer: Path4(PositionAggregator) ONLY. Daily upsert on PK(date). No conflict.';

COMMENT ON TABLE order_tracker IS 
  'Writer: Path1B(OrderExecutor) ONLY. Per-order lifecycle. No conflict.';

COMMENT ON TABLE rebalance_history IS 
  'Writer: Path4(Rebalancer) ONLY. Append-only. No conflict.';
```

#### 4.2.2 Writer 권한 매트릭스

| 테이블 | 유일 Writer | 동시 쓰기 가능? | 해결 |
|--------|-----------|---------------|------|
| positions | Path 1B + 1C | ✅ (동일 symbol) | per-symbol advisory lock |
| trades | Path 1B only | ❌ | 불필요 (append-only) |
| daily_pnl | Path 4 only | ❌ | 불필요 (PK=date, 일 1회) |
| order_tracker | Path 1B only | ❌ | 불필요 (per-order) |
| rebalance_history | Path 4 only | ❌ | 불필요 (append-only) |
| risk_events | Path 4 only | ❌ | 불필요 (append-only) |

**핵심**: 실제 동시 쓰기 충돌 지점은 `positions` 테이블의 동일 symbol뿐. 나머지는 Writer가 단일이거나 append-only.

#### 4.2.3 asyncio 레벨 보호 (추가 안전장치)

```python
# Path 1 내부에서 positions 업데이트 시
# asyncio.Lock per symbol — DB lock의 상위 보호층

class PositionLockManager:
    """Per-symbol asyncio lock.
    
    DB advisory lock이 1차 방어, 이 클래스가 2차 방어.
    동일 프로세스 내에서 동일 symbol의 동시 업데이트를 직렬화.
    """
    def __init__(self):
        self._locks: dict[str, asyncio.Lock] = {}
    
    def get_lock(self, symbol: str) -> asyncio.Lock:
        if symbol not in self._locks:
            self._locks[symbol] = asyncio.Lock()
        return self._locks[symbol]
    
    async def update_position(self, symbol: str, updater: callable):
        async with self.get_lock(symbol):
            await updater()
```

---

## 5. Graph IR v1.0 패치 (graph_ir_v1.0.yaml 변경사항)

### 5.1 stats 섹션 업데이트

```yaml
stats:
  paths: 6
  nodes: 43
  ports: 36
  methods: 192
  domain_types: 86
  edges: 86                     # 84 → 86 (+2: WAL edge, cache edge 1쌍 순증 +2, sync edge 1 삭제 = net +2)
  shared_stores: 8
  tables: 34
  adapters: 34
  validation_rules: 35          # 31 → 35 (+4: 신규 규칙)
  agent_nodes: 5
  l0_nodes: 31
  l0_ratio: "72%"
  cross_path_sync_edges: 13     # 14 → 13 (e_risk_to_path1 제거)
```

### 5.2 신규 edges 추가

```yaml
edges:
  # ... 기존 84개 유지 ...

  # W1: Path 4 → Redis 캐시
  - id: e_risk_budget_to_cache
    type: DataFlow
    role: DataPipe
    source: risk_budget_manager
    target: ExposureCache
    payload: RiskExposureSnapshot
    contract: *fire_and_forget

  # W1: Redis 캐시 → Path 1 RiskGuard
  - id: e_cache_to_risk_guard
    type: Dependency
    role: ConfigRef
    source: ExposureCache
    target: risk_guard
    payload: RiskExposureSnapshot
    contract: { delivery: sync, ordering: best-effort, timeout_ms: 10, idempotency: true }

  # W2: WAL 선기록
  - id: e_preorder_wal_write
    type: DataFlow
    role: DataPipe
    source: dedup_guard
    target: AuditStore
    payload: PreOrderWALEvent
    contract:
      delivery: sync
      ordering: strict
      retry: { max_attempts: 3, backoff: exponential, dead_letter: false }
      timeout_ms: 500
      idempotency: true
```

### 5.3 삭제 edge

```yaml
# 삭제: e_risk_to_path1 (sync cross-path → 캐시 기반으로 대체)
# 이전 정의:
#   - id: e_risk_to_path1
#     source: risk_budget_manager
#     target: risk_guard
#     contract: { delivery: sync, timeout_ms: 200 }
```

### 5.4 shared_stores 섹션 추가

```yaml
shared_stores:
  # ... 기존 8개 유지 ...

  # Redis 캐시 (신규 — Shared Store는 아니지만 캐시 레이어로 등록)
  ExposureCache:
    type: redis_cache             # PostgreSQL store와 구분
    tables: []                    # Redis key-value, 테이블 없음
    keys:
      - "risk:exposure:snapshot"  # RiskExposureSnapshot JSON
    ttl_seconds: 5                # 5초 TTL — 갱신 안 되면 자동 만료
    writer: risk_budget_manager
    reader: risk_guard
```

---

## 6. 신규 Validation Rules (+4)

| Rule ID | Description | Severity |
|---------|-------------|----------|
| V-PATCH-001 | positions 테이블 UPDATE는 acquire_position_lock() 호출 후에만 가능 | error |
| V-PATCH-002 | e_preorder_wal_write 실패 시 주문 진행 금지 (reject_order) | error |
| V-PATCH-003 | ExposureCache TTL(5초) 초과 시 RiskGuard는 안전 방향 판단 | warning |
| V-PATCH-004 | core/domain/ 타입은 2개 이상 Path에서 사용되는 경우에만 등록 | info |

---

## 7. Edge Contract 패턴 사전 업데이트

### Pattern F: Redis Cache Read (신규)

```yaml
redis_cache_read: &redis_cache_read
  delivery: sync
  ordering: best-effort
  retry: { max_attempts: 1, backoff: null, dead_letter: false }
  timeout_ms: 10
  idempotency: true
```
적용: e_cache_to_risk_guard

### Pattern G: WAL Sync Write (신규)

```yaml
wal_sync_write: &wal_sync_write
  delivery: sync
  ordering: strict
  retry: { max_attempts: 3, backoff: exponential, dead_letter: false }
  timeout_ms: 500
  idempotency: true
```
적용: e_preorder_wal_write

---

## 8. 전체 수치 최종 확인

| 항목 | Review 전 | Review 후 | 변경 |
|------|----------|----------|------|
| Edges | 84 | 86 | +3 추가, -1 삭제 |
| Cross-Path Sync | 14 | 13 | -1 (e_risk_to_path1 제거) |
| Contract Patterns | 5 | 7 | +2 (redis_cache_read, wal_sync_write) |
| Validation Rules | 31 | 35 | +4 |
| Domain Types | 86 | 87 | +1 (RiskExposureSnapshot, PreOrderWALEvent) — 88 |
| Shared Store | 8 | 8 + 1 Redis Cache | ExposureCache 추가 |
| 설계 문서 | 15 | 17 | +shared_domain_types, +architecture_review_patch |

---

*End of Document — Architecture Review Patch v1.0*
*Resolves: I1 (→ separate doc), W1 (cache decoupling), W2 (WAL edge), W3 (advisory lock)*
*Net change: +2 edges, -1 cross-path sync, +4 validation rules, +2 domain types*
