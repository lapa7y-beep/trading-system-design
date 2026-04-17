# Phase 1 에러 핸들링 매트릭스 (4계층·CB·SAFE_MODE·KIS코드)

> **목적**: 노드별·Port별 에러 유형, Circuit Breaker, SAFE_MODE, 재시도 정책, KIS 에러 코드 매핑을 통합 정의한다.
> **층**: What

> **구현 여정**: Step 02(PortError), 06~10(CB), 10d(SAFE_MODE)에서 구현. ADR-012 §6 참조.
> **상태**: Phase 1 확정
> **최종 수정**: 2026-04-17
> **목적**: 시스템 전체에서 발생 가능한 에러 유형과 대응 정책을 단일 매트릭스로 통합.
> **선행 문서**: `docs/what/specs/port-signatures-phase1.md` (PortError 계층), `docs/what/specs/adapter-spec-phase1.md` (Adapter 실패 처리), `docs/what/architecture/path1-node-blueprint.md` (노드별 매트릭스), `docs/what/architecture/fsm-design.md`

---

## 1. 에러 처리 4계층 원칙

```
Layer 1: Adapter         ← 외부 예외 → PortError로 변환
Layer 2: Node (Port 호출) ← PortError catch → 도메인 의사결정
Layer 3: FSM             ← SAFE_MODE 전환 판단
Layer 4: AuditPort       ← 모든 에러 발생 기록 (append-only)
```

**핵심 규칙**
1. Adapter 내부의 httpx/asyncpg/websockets 예외는 **절대** Node까지 올라가지 않는다. 반드시 `PortError` 하위로 변환.
2. Node는 `PortError`를 잡고 **도메인 판단**을 내린다 (재시도, degrade, SAFE_MODE 요청).
3. 모든 에러 경로는 `AuditPort.log()`를 경유한다. 로깅 실패 시 fallback 필수 (adapter-spec §9.1).
4. 예측 불가 예외 (`Exception`)가 최상위까지 올라가면 프로세스 전체 SAFE_MODE + 재시작 검토.

---

## 2. 에러 분류 (Severity)

| severity | 의미 | 예시 | FSM 영향 |
|----------|------|------|---------|
| **info** | 정상 흐름 중 기록 가치 있는 이벤트 | 주문 제출됨, 전이 발생 | 없음 |
| **warn** | 회복 가능한 일시 장애 | WS 재연결, 일부 지표 null, rate limit | 없음 |
| **error** | 회복 시도 필요, 개별 주문/틱 단위 실패 | REST 폴링 실패, 주문 타임아웃, 전략 예외 | 해당 FSM만 ERROR 전이 |
| **critical** | 시스템 레벨 실패, 안전성 위협 | DB 연결 불가, crash recovery 불일치, Circuit Breaker trip | 전체 SAFE_MODE |

**사용 원칙**:
- info는 디버깅·감사 추적용. 알림 없음.
- warn은 추세를 모니터링. 급증 시 수동 확인.
- error는 즉시 알림 (Phase 2에서 Telegram). Phase 1은 `atlas audit` CLI로 확인.
- critical은 즉시 SAFE_MODE + 수동 개입 필수.

---

## 3. 통합 에러 매트릭스 — 노드별

### 3.1 MarketDataReceiver

| 에러 | 감지 | 행동 | severity |
|------|------|------|---------|
| WS 끊김 (heartbeat 미수신) | 5초 타이머 | 재연결 시도 | warn |
| WS 재연결 3회 실패 | 카운터 | FALLBACK_POLL 전환 | error |
| REST 폴링 실패 (HTTP 에러/타임아웃) | httpx Exception | 지수 백오프 재시도 3회 | error |
| 이상 시세 (전일 종가 대비 ±31%) | 값 비교 | WARN 로그, 전달은 계속 | warn |
| 틱 3초 미수신 (stale) | 타이머 | stale 경고 | warn |
| KIS 인증 실패 (최초 기동) | `AuthError` | 기동 중단 | critical |

### 3.2 IndicatorCalculator

| 에러 | 감지 | 행동 | severity |
|------|------|------|---------|
| pandas-ta 계산 오류 | try/except | 해당 지표 null, 나머지 정상 전달 | warn |
| buffer 부족 (< warmup_bars) | `len()` 체크 | 계산 가능한 지표만, 나머지 null | info |
| 메모리 초과 | ring buffer 구현 | 자동 trim (FIFO) | — |

### 3.3 StrategyEngine

| 에러 | 감지 | 행동 | severity |
|------|------|------|---------|
| 전략 파일 import 실패 (기동 시) | `ImportError` / `DataError` | 기동 중단 | critical |
| evaluate() 예외 | try/except | 해당 틱 무시, 다음 틱에 재시도 | error |
| evaluate() 50ms 초과 | `asyncio.timeout` | 해당 틱 폐기 | warn |
| PortfolioStore 조회 실패 | `StorageError` | 빈 snapshot으로 진행 (신규 진입만 가능) | warn |
| signal_cooldown_seconds 내 중복 | 내부 카운터 | drop, audit 없음 | — |

### 3.4 RiskGuard

| 에러 | 감지 | 행동 | severity |
|------|------|------|---------|
| 7체크 중 1개라도 차단 | 각 체크 로직 | `rejection_event` → AuditStore, 신호 drop | warn |
| PortfolioStore 조회 실패 | `StorageError` | 보수적 거부 (진입 차단, 청산 허용) | error |
| ClockPort 실패 (거래시간 판정 불가) | `PortError` | 전체 차단 (안전 우선) | error |
| Circuit Breaker trip | 내부 플래그 | 모든 신호 거부 (recovery_seconds까지) | critical |

### 3.5 OrderExecutor

| 에러 | 감지 | 행동 | severity |
|------|------|------|---------|
| API 타임아웃 | `asyncio.timeout` | status=failed, CB 카운터++ | error |
| 인증 만료 (KIS EGW00123) | 응답 코드 | 토큰 갱신 → 1회 재시도 | warn |
| Rate limit (KIS EGW00201) | 응답 코드 | 1초 대기 → 재시도 | warn |
| 자금 부족 (KIS APBK0919) | 응답 코드 | status=rejected, 신호 drop | warn |
| 호가단위 불일치 (KIS APBK0634) | 응답 코드 | 가격 보정 → 재시도 1회 | warn |
| 동일 order_uuid 재제출 | DB UNIQUE 위반 | 기존 OrderResult 반환 (멱등성) | info |
| CB tripped | 내부 플래그 | 신규 주문 즉시 거부 | critical |
| `BrokerRejectError` (그 외) | PortError | status=rejected, audit 기록 | error |
| 브로커 연결 끊김 | `ConnectionError` | 3회 재시도 → 실패 시 FSM 전이 `broker_error` → ERROR 상태 | error |

### 3.6 TradingFSM

| 에러 | 감지 | 행동 | severity |
|------|------|------|---------|
| 잘못된 전이 시도 | `transitions.MachineError` | 무시 + 로그 | warn |
| positions UPDATE 실패 | `StorageError` | 재시도 3회, 실패 시 ERROR 전이 | critical |
| 복원 시 불일치 (crash recovery) | boot 시 positions vs broker | 전체 SAFE_MODE + 수동 개입 대기 | critical |
| state_transition → audit 실패 | `StorageError` | fallback 파일 기록, FSM 전이는 유지 | error |

---

## 4. Port별 에러 → 표준 대응

### 4.1 MarketDataPort

| PortError | 발생 지점 | 기본 대응 | 대응 주체 |
|-----------|----------|---------|----------|
| `ConnectionError` | subscribe, stream, get_current_price | 재연결 정책 (ws→poll fallback) | MarketDataReceiver |
| `TimeoutError` | get_current_price, get_historical | 지수 백오프 재시도 | Adapter 내부 |
| `AuthError` | subscribe (최초) | 기동 중단 | Boot 시퀀스 |
| `DataError` | get_historical (빈 응답) | 호출자 판단 (Risk/Strategy) | Node |

### 4.2 BrokerPort

| PortError | 발생 지점 | 기본 대응 | 대응 주체 |
|-----------|----------|---------|----------|
| `BrokerRejectError` | submit, cancel | status=rejected, audit 기록 | OrderExecutor |
| `TimeoutError` | submit | CB 카운터 증가, 상태 확인 필요 | OrderExecutor |
| `ConnectionError` | 전체 | 3회 재시도 → FSM broker_error | OrderExecutor |
| `AuthError` | get_account_balance | Boot 실패, SAFE_MODE | Boot 시퀀스 |

### 4.3 StoragePort

| PortError | 발생 지점 | 기본 대응 | 대응 주체 |
|-----------|----------|---------|----------|
| `ConnectionError` | 모든 메서드 | **즉시 SAFE_MODE** — DB 없이 불가 | 전역 핸들러 |
| `TimeoutError` | 쿼리 실행 | 재시도 1회, 실패 시 호출자 에러 | 호출 Node |
| `StorageError` | save/update | 재시도 3회 (update_position만), 그 외는 호출자 | 호출 Node |

### 4.4 ClockPort

| PortError | 대응 |
|-----------|------|
| 거의 없음 | `now()`, `sleep()`는 OS/asyncio만 사용. 실패 시 프로세스 전체 문제 |

### 4.5 StrategyRuntimePort

| PortError | 발생 지점 | 기본 대응 |
|-----------|----------|---------|
| `DataError` (load 시) | 기동 | Boot 실패 → critical |
| `DataError` (evaluate 시) | 매 틱 | 해당 틱 폐기, error 기록 |

### 4.6 AuditPort

| PortError | 대응 |
|-----------|------|
| `StorageError` | 로컬 파일 `logs/audit_fallback.jsonl` 에 append → critical 로깅 |
| 연속 실패 | 전역 SAFE_MODE (감사 유실은 시스템 신뢰성 붕괴) |

---

## 5. Circuit Breaker 통합

### 5.1 CB 위치 (2곳)

| 위치 | 트리거 | 영향 범위 | 복구 |
|------|--------|---------|------|
| **OrderExecutor** | `circuit_breaker.window_seconds` 내 `max_failures` 도달 | 신규 주문 전체 거부 | `recovery_seconds` 후 자동 half-open |
| **RiskGuard** | (동일 CB 참조) | 모든 signal을 approved 아닌 상태로 drop | OrderExecutor CB 복구와 연동 |

**구성**: `config.order_executor.circuit_breaker.*`, `config.risk.circuit_breaker_*`

### 5.2 CB 상태 전이

```
CLOSED (정상)
   │   window 내 max_failures 도달
   ▼
OPEN (차단)
   │   recovery_seconds 경과
   ▼
HALF_OPEN (시험)
   │   1건 성공        1건 실패
   ▼                   ▼
CLOSED              OPEN
```

**중요**: HALF_OPEN 중 실패 1건도 즉시 OPEN 복귀. Phase 1은 보수적 운영.

---

## 6. SAFE_MODE 진입 조건 통합

FSM이 SAFE_MODE로 강제 전이되는 경우를 모두 모음.

| # | 조건 | 감지 위치 | severity |
|---|------|----------|---------|
| 1 | `atlas halt` 명령 | Signal Handler | info (사용자 의도) |
| 2 | Crash recovery 불일치 | Boot §4 | critical |
| 3 | DB 연결 끊김 (지속적) | StoragePort | critical |
| 4 | BrokerPort get_account_balance 실패 (Boot) | Boot §7 | critical |
| 5 | MarketData 구독 완전 실패 (ws+poll 모두) | Boot §8 | critical |
| 6 | Strategy 로드 실패 | Boot §6 | critical |
| 7 | TradingFSM positions UPDATE 3회 실패 | FSM | critical |
| 8 | AuditPort 연속 실패 | AuditPort | critical |
| 9 | CB trip 후 recovery 실패 반복 | OrderExecutor | critical |
| 10 | 예측 불가 `Exception` (catch-all) | 전역 핸들러 | critical |

---

## 7. 재시도 정책 표

어디서 몇 번, 어떤 간격으로 재시도하는지 통합.

| 대상 | 위치 | 시도 횟수 | 백오프 | 최종 실패 시 |
|------|------|---------|--------|------------|
| KIS WS 재연결 | KISWebSocketAdapter | 3회 | `ws_reconnect_interval_seconds` (5s 기본) | FALLBACK_POLL |
| KIS REST 호출 | KISRestAdapter | 3회 | 지수 (1s → 2s → 4s) | `ConnectionError` raise |
| KIS 주문 제출 (타임아웃) | KISPaperBrokerAdapter | 1회 | 즉시 | CB 카운터++ |
| 토큰 만료 재시도 | KISPaperBrokerAdapter | 1회 | 즉시 | `AuthError` |
| Rate limit 대기 | KISPaperBrokerAdapter | 1회 | 1s | 재시도 |
| 호가단위 보정 | KISPaperBrokerAdapter | 1회 | 즉시 | `BrokerRejectError` |
| DB update_position | PostgresStorageAdapter | 3회 | 지수 (0.5s → 1s → 2s) | ERROR 전이 → 전역 SAFE_MODE |
| Audit 로깅 | PostgresAuditAdapter | 1회 | 즉시 | 파일 fallback |
| Strategy evaluate | FileSystemStrategyLoader | 0 (재시도 없음) | — | 해당 틱 drop |

---

## 8. 타임아웃 표

| 작업 | config 키 | 기본값 | 초과 시 |
|------|----------|-------|--------|
| 주문 제출 응답 | `order_executor.submit_timeout_seconds` | 5 | `TimeoutError`, CB++ |
| DB 쿼리 | `database.pool_timeout_seconds` | 30 | `TimeoutError` |
| WS 재연결 대기 | `market_data.ws_reconnect_interval_seconds` | 5 | 다음 시도 |
| REST 폴링 주기 | `market_data.poll_interval_seconds` | 10 | 다음 주기 |
| 틱 stale 경고 | `market_data.stale_tick_warn_seconds` | 3 | warn 기록 |
| halt 완료 | `cli.halt_timeout_seconds` | 30 | 합격 기준 #4 (필수) |
| Strategy evaluate | (코드 상수) | 50ms | 해당 틱 drop |
| Graceful shutdown 주문 대기 | (코드 상수) | 60s | 강제 진행 |

---

## 9. audit_events 표준 payload 구조

모든 에러는 동일한 형식으로 기록된다.

```json
{
  "event_type": "order_rejected",
  "severity": "warn",
  "source": "RiskGuard",
  "correlation_id": "uuid",
  "occurred_at": "2026-04-17T10:23:45+09:00",
  "payload": {
    "check": "concentration_limit",
    "symbol": "005930",
    "threshold": 0.20,
    "actual": 0.23,
    "signal_price": 72100,
    "signal_quantity": 100
  }
}
```

**필수 필드**: `event_type`, `severity`, `source`, `correlation_id`, `occurred_at`.
**payload**: 이벤트 유형별 자유 형식. 단, JSON-serializable 필수.

---

## 10. 에러 분석 CLI

```bash
atlas audit --recent 50                    # 최근 50건
atlas audit --severity=error --today       # 오늘의 error 이상
atlas audit --correlation-id=<uuid>        # 특정 주문 체인 전체
atlas audit --event-type=fsm_transition    # 특정 이벤트 타입
atlas audit --source=OrderExecutor         # 특정 노드 발생
```

---

## 11. 알려진 KIS 에러 코드 매핑 (Phase 1 필수)

| KIS 코드 | 의미 | 매핑 | severity |
|---------|------|------|---------|
| EGW00123 | 인증 토큰 만료 | `AuthError` → 재인증 → 1회 재시도 | warn |
| EGW00201 | 요청 유량 초과 | rate limit → 1s 대기 → 재시도 | warn |
| APBK0919 | 주문 가능 금액 초과 | `BrokerRejectError('INSUFFICIENT_CASH')` | warn |
| APBK0634 | 호가 단위 불일치 | 가격 보정 → 1회 재시도 | warn |
| APBK0914 | 주문 종목 코드 오류 | `DataError` | error |
| APBK8001 | 단일가 미체결 | `BrokerRejectError` (Phase 1은 재시도 안 함) | warn |
| MCA00000 | 정상 처리 | `OrderResult(status=ACCEPTED)` | info |

**추가 코드는 `docs/what/references/kis-api-notes.md`에 축적.**

---

## 12. Phase 2 확장 예약

Phase 1에 **포함되지 않는** 에러 처리:

- ❌ Telegram 즉시 알림 (critical 이벤트)
- ❌ PagerDuty/Slack 통합
- ❌ 자동 복구 루프 (self-healing)
- ❌ 분산 트랜잭션 (Outbox pattern)
- ❌ Saga compensation

Phase 1은 **로그 기반 수동 운영** 모델. 알림은 `atlas audit` CLI 폴링.

---

## 13. 변경 이력

| 날짜 | 버전 | 변경 |
|------|------|------|
| 2026-04-17 | v1.0 | Phase 1 최초 작성. 6노드 매트릭스 + 6 Port 대응 + CB + SAFE_MODE 조건 + KIS 코드 매핑 통합. |

---

*Phase 1 에러 핸들링 통합 매트릭스 — 4 severity | 10 SAFE_MODE 조건 | 9 재시도 정책 | 8 타임아웃 | KIS 7코드*
