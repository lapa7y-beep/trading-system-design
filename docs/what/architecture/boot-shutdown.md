# 시스템 기동·종료·긴급정지·크래시복구 시퀀스

> **목적**: ATLAS 데몬의 Boot, Graceful Shutdown, Emergency Halt(30초), Crash Recovery, Resume 절차를 정의한다.
> **층**: What
> **상태**: Phase 1 확정
> **최종 수정**: 2026-04-17
> **구현 여정**: Step 10a(부팅), Step 10b(종료)에서 구현. ADR-012 §6 참조.
> **선행 문서**: `docs/what/architecture/cli-design.md`, `docs/what/architecture/fsm-design.md`, `docs/what/specs/config-schema-phase1.md`, `docs/what/specs/adapter-spec-phase1.md`
> **관련 Safeguards**: `duplicate_order_prevention`, `state_account_consistency`, `event_durability`

## 1. 개요

| 이벤트 | 트리거 | 목표 시간 |
|--------|--------|----------|
| **Boot** | `atlas start` | 5초 이내 (DB 연결 + 상태 복원 포함) |
| **Graceful Shutdown** | `atlas stop` | 진행 중 주문 완료 대기 (최대 60초) |
| **Emergency Halt** | `atlas halt` | 30초 이내 신규 주문 차단 (합격 기준 #4) |
| **Crash Recovery** | `atlas start` 이후 자동 | Boot 내부 단계 4에서 처리 |
| **SAFE_MODE Resume** | `atlas resume` | 5초 이내 |

---

## 2. Boot 시퀀스

### 2.1 단계별 흐름

```
[0] 프로세스 기동 (atlas start)
     │
     ▼
[1] 설정 로딩
     │   config.yaml + 환경변수 → Config 객체 (Pydantic 검증)
     │   실패 시 즉시 중단 + stderr 출력
     ▼
[2] 로거 초기화
     │   logging.yaml 적용, 파일 핸들러 + stdout
     ▼
[3] Storage 어댑터 초기화 (DB 연결)
     │   asyncpg pool 생성 → ping 쿼리 성공 확인
     │   실패 시 즉시 중단 (DB 없이는 불가)
     ▼
[4] Crash Recovery
     │   4.1 미청산 포지션 로드 (positions 테이블)
     │   4.2 미완료 주문 상태 재조회 (order_tracker)
     │   4.3 FSM 상태 복원 (각 종목별 인스턴스 재구성)
     │   4.4 불일치 감지 시 AuditPort 기록 → SAFE_MODE 진입
     ▼
[5] Adapter Factory로 나머지 포트 초기화
     │   ExchangeEngine (synthetic 모드일 때만, 3 Adapter가 공유)
     │   OrderPort (config.order.mode 기준 선택)
     │   AccountPort (config.account.mode 기준 선택)
     │   MarketDataPort (config.market_data.mode 기준)
     │   ClockPort, StrategyRuntimePort, AuditPort
     ▼
[6] 전략 로드
     │   StrategyRuntimePort.load(config.strategy.active)
     │   실패 시 SAFE_MODE 진입 (기동은 완료하되 매매 중단)
     ▼
[7] 브로커 연결 확인
     │   AccountPort.get_balance() 호출 → 잔고 조회 성공 = 인증 OK
     │   AccountPort.get_balance() + get_positions() 호출 → PortfolioStore 증권사 기준 덮어쓰기
     │   실패 시 SAFE_MODE 진입
     ▼
[7b] 체결 통보 구독 시작 (ADR-013)
     │   ExecutionEventPort.subscribe(ExecutionReceiver.on_execution_event)
     │   mode=paper: KIS H0STCNI0 WebSocket 연결
     │   mode=mock: MockEventBus 핸들러 등록
     │   mode=synthetic: ExchangeEngine 콜백 등록
     │   config.execution_event.crash_replay=true 이면 audit_events에서 최근 5분 이벤트 replay
     │   실패 시 SAFE_MODE 진입 (체결 유실 위험)
     ▼
[8] 시세 구독 시작
     │   MarketDataPort.subscribe(watchlist.symbols)
     │   실패 시 fallback (ws → poll) 시도 후 SAFE_MODE
     ▼
[9] 스케줄러 기동
     │   APScheduler 시작 (일봉 수집 스케줄 등록)
     ▼
[10] Signal Handler 등록
     │   SIGTERM → graceful shutdown
     │   SIGUSR1 → emergency halt
     │   SIGUSR2 → reload config (Phase 2, Phase 1은 미지원)
     ▼
[11] PID 파일 기록
     │   /var/run/atlas.pid 에 현재 PID 기록
     ▼
[12] 메인 이벤트 루프 진입
     │   MarketDataPort.stream() → IndicatorCalculator → ... → OrderExecutor
     │   ExecutionEventPort (백그라운드 수신) → ExecutionReceiver → PortfolioStore + FSM
     │   atlas.control 파일에 mode: active 기록
     │
     └─► 정상 가동 상태
```

### 2.2 단계별 실패 처리

| 단계 | 실패 시 동작 | 이유 |
|------|------------|------|
| 1 | **즉시 중단** + stderr에 에러 출력, 종료 코드 1 | config 없이는 아무것도 못 함 |
| 2 | 경고만 출력, 계속 진행 | 로거 실패는 치명적이지 않음 |
| 3 | **즉시 중단**, 종료 코드 2 | DB 없이 상태 영속화 불가 |
| 4 | **SAFE_MODE 진입** (기동은 완료) | 불일치 상태로 매매 시작 금지 |
| 5 | **SAFE_MODE** (Broker/MarketData 개별 실패 시) | 일부라도 없으면 매매 불가 |
| 6 | **SAFE_MODE** | 전략 없으면 신호 생성 불가 |
| 7 | **SAFE_MODE** | 잔고 조회 실패 = 주문 제출 불가 |
| **7b** | **SAFE_MODE** | **체결 통보 구독 실패 = 포지션 추적 불가 (ADR-013)** |
| 8 | fallback 시도 → 계속 실패 시 **SAFE_MODE** | 시세 없으면 지표 계산 불가 |
| 9 | 경고 로깅, 계속 진행 | 스케줄러는 부차적 기능 |
| 10~12 | **즉시 중단** | 프로세스 제어 불가 |

**원칙**: 데이터 일관성에 영향 주는 실패는 **SAFE_MODE**, 인프라 기반 실패는 **즉시 중단**.

---

## 3. Crash Recovery 상세

### 3.1 목적

비정상 종료 (kill -9, OOM, 정전 등) 이후 재기동 시 **정확히 이전 상태를 재현**.
합격 기준 #5: `kill -9 → restart → positions 테이블과 FSM 상태 일치`.

### 3.2 복구 로직

```python
# 의사 코드
async def crash_recovery(
    storage: StoragePort,
    order: OrderPort,
    account: AccountPort,
    audit: AuditPort,
):
    # 3.2.1 미청산 포지션 로드
    positions = await storage.load_all_positions()

    # 3.2.2 미완료 주문 조회 (status IN pending/submitted/partial)
    pending_orders = await storage.load_pending_orders()

    # 3.2.3 브로커에 실제 주문 상태 재확인 (OrderPort 사용)
    for o in pending_orders:
        try:
            real_result = await order.get_order_status(o.order_uuid)

            if real_result.status != o.status:
                # 브로커 기준이 진실. DB 업데이트.
                await storage.update_order_status(real_result)
                await audit.log(
                    event_type='crash_recovery_mismatch',
                    severity='warning',
                    source='BootSequence',
                    correlation_id=o.correlation_id,
                    payload={'db_status': o.status, 'broker_status': real_result.status},
                )
        except DataError:
            # 브로커가 모르는 주문 = 제출 전 크래시
            await storage.mark_order_as('failed_before_submit', o.order_uuid)

    # 3.2.3b 계좌 일관성 검증 (AccountPort 사용)
    reconcile_result = await account.reconcile()
    if not reconcile_result['consistent']:
        await audit.log(
            event_type='crash_recovery_account_mismatch',
            severity='critical',
            source='BootSequence',
            payload=reconcile_result,
        )

    # 3.2.4 FSM 인스턴스 재구성
    fsms = {}
    for symbol in watchlist:
        pos = next((p for p in positions if p.symbol == symbol), None)
        initial_state = FSMState.IN_POSITION if pos else FSMState.IDLE
        fsms[symbol] = TradingFSM(symbol, initial_state, storage, audit)

    # 3.2.5 불일치가 1건이라도 있었다면 전체 SAFE_MODE
    if audit.recent_recovery_mismatches() > 0:
        for fsm in fsms.values():
            await fsm.transition(FSMState.SAFE_MODE, reason='crash_recovery_mismatch')

    return fsms
```

### 3.3 복구 실패 시나리오

| 시나리오 | 감지 | 대응 |
|---------|------|------|
| DB는 포지션 있는데 브로커에는 없음 | `get_account_balance` vs `positions` 수량 불일치 | SAFE_MODE + `audit_events` 기록 + 사용자 수동 개입 대기 |
| DB에 없는 포지션이 브로커에 있음 | 잔고 조회 시 알려지지 않은 종목 포지션 | SAFE_MODE + 수동 개입 |
| 미완료 주문이 브로커에서 이미 체결됨 | `get_order_status` 응답이 `FILLED` | DB 업데이트 → `trades` 테이블 upsert → 정상 복구 |
| 주문이 브로커에서 거절된 줄 몰랐음 | `REJECTED` 응답 | DB 업데이트, FSM을 IDLE로 복귀 |

**원칙**: 브로커가 진실의 원천 (money-of-truth). DB는 브로커에 맞춰 업데이트.

### 3.4 멱등성 보장

Crash recovery가 여러 번 실행되어도 결과는 동일해야 한다.
- `audit_events` 기록에 `correlation_id` + `event_type='crash_recovery_mismatch'`로 중복 감지 가능
- 복구 로직 자체는 read → compare → update 패턴. 이미 최신 상태면 update가 no-op.

---

## 4. Graceful Shutdown 시퀀스 (`atlas stop`)

### 4.1 흐름

```
[0] CLI가 SIGTERM 발송
     │
     ▼
[1] Signal Handler 수신
     │   shutdown_requested 플래그 설정
     ▼
[2] 메인 루프에서 플래그 감지
     │   새 신호 생성 중단 (StrategyEngine 게이트)
     ▼
[3] 진행 중 주문 완료 대기 (최대 60초)
     │   모든 FSM이 ENTRY_PENDING / EXIT_PENDING 아닌 상태까지 대기
     │   60초 초과 시 audit 기록 후 다음 단계로 (강제 종료는 아님)
     ▼
[4] MarketDataPort 구독 해제
     │   unsubscribe → ws 연결 close
     ▼
[5] 스케줄러 정지
     │   APScheduler.shutdown(wait=True)
     ▼
[6] FSM 상태 최종 저장
     │   각 FSM의 현재 state를 positions 테이블 저장 (persist_on_every_transition이 이미 처리)
     ▼
[7] Audit 기록
     │   audit.log(event_type='shutdown_graceful', severity='info', ...)
     ▼
[8] DB 연결 풀 종료
     │   asyncpg pool.close()
     ▼
[9] PID 파일 제거
     │   /var/run/atlas.pid 삭제
     ▼
[10] 프로세스 종료 (exit code 0)
```

### 4.2 주의사항

- `atlas stop`은 **합격 기준과 무관** (halt가 아니므로). 단, 일관성 보장 필요.
- Phase 1은 주문 대기 타임아웃 60초. Phase 2에서 설정 가능하도록.
- 시세 끊김은 로깅만. 이미 shutdown 중이므로 재연결 불필요.

---

## 5. Emergency Halt 시퀀스 (`atlas halt`) — 합격 기준 #4

### 5.1 흐름 (30초 이내 완료 필수)

```
[0] CLI가 SIGUSR1 발송 + atlas.control 파일에 mode: halted 기록
     │
     ▼
[1] Signal Handler 수신 (즉시, <100ms)
     │
     ▼
[2] halt_requested 이벤트를 모든 FSM에 브로드캐스트
     │   모든 상태에서 → SAFE_MODE 전이 (wildcard transition)
     ▼
[3] OrderExecutor가 신규 주문 거부 모드로 전환 (<1초)
     │   approved_signal 수신해도 즉시 BrokerRejectError 발생시키지 않고
     │   AuditPort에 'halted_state_rejection' 기록 후 drop
     ▼
[4] StrategyEngine 게이트 차단 (<1초)
     │   signal_output 생성 중단
     ▼
[5] CLI가 audit_events 폴링 (최대 30초)
     │   신규 order_submitted 이벤트 0건 확인될 때까지
     ▼
[6] Audit 최종 기록
     │   audit.log(event_type='halt_completed', severity='critical', ...)
     ▼
[7] SAFE_MODE 유지 (daemon 프로세스는 살아있음)
     │   시세 구독은 유지, 전략 평가는 중단
     │   atlas resume 까지 대기
```

### 5.2 설계 포인트

- **halt는 프로세스 종료가 아님** — SAFE_MODE에서 시세·포지션 모니터링은 계속
- 전체 30초 내 차단을 위한 내부 목표치: **step 2~4는 합산 3초 이내**, 여유 27초는 실제 브로커 응답 대기
- `atlas.control` 파일 + Signal 이중 경로: signal 유실 대비 파일을 주기적으로 polling
- config: `cli.halt_timeout_seconds` (기본 30)

### 5.3 halt 중 진행 중 주문의 운명

- ENTRY_PENDING / EXIT_PENDING 상태에서 halt 진입 → 해당 주문은 **계속 진행** (브로커 응답 기다림)
- 체결 완료 시 → FSM이 SAFE_MODE 유지 (IN_POSITION으로 돌아가지 않음)
- 취소 실패 시 → AuditPort 기록, 수동 개입

---

## 6. Resume 시퀀스 (`atlas resume`)

### 6.1 전제

- halt 원인이 해소되었음이 사용자 판단으로 확인됨
- 진행 중 주문이 모두 종결 상태 (체결 or 취소)

### 6.2 흐름

```
[0] CLI가 SIGUSR2 발송 + atlas.control에 mode: active 기록
     │
     ▼
[1] Pre-resume 검증
     │   - 모든 FSM이 SAFE_MODE 인지 확인
     │   - 미완료 주문 (pending/partial) 0건 확인
     │   둘 중 하나라도 실패 → resume 거부, 에러 반환
     ▼
[2] FSM을 SAFE_MODE → IDLE 또는 IN_POSITION으로 전이
     │   포지션 보유 종목: IN_POSITION
     │   미보유 종목: IDLE
     ▼
[3] StrategyEngine 게이트 해제
     │
     ▼
[4] OrderExecutor 신규 주문 수락 모드
     │
     ▼
[5] Audit 기록
     │   audit.log(event_type='resume_completed', severity='info', ...)
```

### 6.3 Resume 실패 조건

- 미완료 주문이 남아있으면 resume 거부 (먼저 수동 cancel 또는 완료 대기)
- DB-브로커 불일치가 있으면 resume 거부 (crash recovery로 해결)

---

## 7. CLI 명령과의 매핑

| CLI | Signal | atlas.control mode | 대상 시퀀스 |
|-----|--------|-------------------|------------|
| `atlas start` | (프로세스 기동) | active | Boot (§2) + Crash Recovery (§3) |
| `atlas stop` | SIGTERM | (파일 삭제) | Graceful Shutdown (§4) |
| `atlas halt` | SIGUSR1 | halted | Emergency Halt (§5) |
| `atlas resume` | SIGUSR2 | active | Resume (§6) |

---

## 8. 관련 Safeguards

| Safeguard | 기여 시퀀스 | 메커니즘 |
|-----------|-----------|---------|
| duplicate_order_prevention | Boot §4, Halt §5 | order_uuid + DB UNIQUE — 크래시 후 재제출에도 중복 방지 |
| state_account_consistency | Boot §4, Resume §6 | Crash recovery의 브로커 진실성 원칙 |
| event_durability | 모든 시퀀스 | audit_events append-only + 전이마다 persist |
| command_control_security | Halt §5, Resume §6 | SIGUSR1/SIGUSR2 + OS-level user 권한 |

---

## 9. config.yaml 관련 키 (참조)

```yaml
cli:
  halt_timeout_seconds: 30          # 합격 기준 #4 의 기준
  status_refresh_seconds: 5

fsm:
  persist_on_every_transition: true  # Shutdown/Halt 신뢰성의 전제
  crash_recovery_on_boot: true       # Boot §4 활성화 스위치
```

---

## 10. 변경 이력

| 날짜 | 버전 | 변경 |
|------|------|------|
| 2026-04-17 | v1.0 | Phase 1 최초 작성. Boot/Graceful Shutdown/Emergency Halt/Resume/Crash Recovery 5개 시퀀스 통합. |

---

*Phase 1 Boot/Shutdown 시퀀스 — 5 시퀀스 | 12 Boot 단계 | 30초 Halt 보장 | Crash Recovery 멱등성*
