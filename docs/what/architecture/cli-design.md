# atlas CLI 명령어 설계 (12명령·IPC·보안)

> **목적**: atlas 명령줄 도구의 12개 명령, 프로세스 아키텍처, IPC 방식, 보안 장치를 정의한다.
> **층**: What

> **구현 여정**: Step 10c(start/stop/status)와 Step 10d(halt 30초)에서 구현. ADR-012 §6 참조.
> **상태**: stable
> **선행 문서**: `docs/what/decisions/011-phase1-scope.md`
> **배경**: Phase 1에서 Telegram Bot을 제외(α 선택)함에 따라, 운영 제어는 CLI로 일원화.

---

## 1. 설계 원칙

1. **접근 수단은 SSH** — `ssh jdw@host` 후 `atlas <subcommand>`
2. **모든 명령은 idempotent** — 같은 명령을 두 번 실행해도 해가 없어야 함
3. **Critical 명령은 확인 프롬프트** — `atlas halt`, `atlas stop` 등은 `--yes` 없으면 y/N 확인
4. **출력은 사람-우선 + JSON 옵션** — 기본은 인간이 읽기 쉬운 테이블, `--json`은 파이프 가능
5. **프로세스 간 통신은 Unix Signal + 파일** — 별도 RPC 없이 최소 의존성
6. **로그는 모두 `audit_events`에 남김** — 누가 언제 halt 했는지 추적 가능

---

## 2. 명령 목록

| 명령 | 설명 | 파괴성 |
|------|------|--------|
| `atlas start` | 데몬 시작 | low (이미 실행 중이면 에러) |
| `atlas stop` | 정상 종료 (진행 중 주문 완료 대기) | medium |
| `atlas halt` | **긴급 정지** — 30초 내 신규 주문 차단 | high |
| `atlas resume` | SAFE_MODE 해제 | high |
| `atlas status` | 현재 상태 요약 출력 | none |
| `atlas positions` | 보유 포지션 테이블 | none |
| `atlas pnl [--today / --week / --from=YYYY-MM-DD]` | 손익 조회 | none |
| `atlas orders [--open / --today]` | 주문 내역 | none |
| `atlas backtest <strategy.py> [--period=...]` | 백테스트 실행 | none |
| `atlas audit [--tail=N]` | 감사 로그 조회 | none |
| `atlas config [show / validate]` | 설정 확인 | none |
| `atlas version` | 버전 정보 | none |

**Phase 1 범위 밖** (Phase 2에 추가될 것):
- `atlas strategy reload` — hot reload
- `atlas screener run` — Screener 수동 실행
- `atlas watchlist add/remove` — 종목 추가/제거

---

## 3. 프로세스 아키텍처

```
┌─────────────────────────────────────┐
│ atlas CLI (short-lived)             │
│  └─ subprocess: argparse            │
└──────────────┬──────────────────────┘
               │ signal / file write / DB read
               ▼
┌─────────────────────────────────────┐
│ atlas daemon (long-running)         │
│  ├─ Path 1 실행 엔진                 │
│  ├─ SignalHandler (SIGUSR1/2)       │
│  ├─ ControlFileWatcher              │
│  └─ PID file: /var/run/atlas.pid    │
└─────────────────────────────────────┘
```

**CLI와 Daemon 분리 이유**:
- CLI는 짧게 실행, 결과 출력 후 종료
- Daemon은 장중 24시간 가동
- CLI가 Daemon을 죽이지 않음 (오직 `stop`/`halt`만)

---

## 4. IPC (Inter-Process Communication)

### 4.1 방법 매트릭스

| 명령 종류 | IPC 방식 | 이유 |
|---------|---------|------|
| 조회 (`status`, `positions`, `pnl`) | DB 직접 조회 | Daemon 부하 없음, read-only |
| 제어 (`halt`, `resume`) | Unix Signal + 파일 | 간단, 신뢰성 |
| 시작 (`start`) | systemd 또는 nohup | Daemon 독립 |

### 4.2 Signal Table

| Signal | 의미 | Daemon 동작 |
|--------|------|-----------|
| `SIGTERM` | 정상 종료 | 진행 중 주문 완료 대기 후 종료 |
| `SIGUSR1` | 긴급 정지 | 모든 TradingFSM을 SAFE_MODE 전이 |
| `SIGUSR2` | resume | SAFE_MODE 해제 |
| `SIGHUP` | 설정 재로드 (Phase 2) | - |

### 4.3 Control File

`/var/run/atlas.control`:
```yaml
mode: active       # active | halted | safe_mode
halt_reason: null  # halt 시 문자열
halted_at: null    # halt 시 ISO8601
halted_by: null    # 사용자명
```

Daemon이 5초마다 폴링. Signal이 들어오지 않을 경우의 backup 경로.

---

## 5. 핵심 명령 상세

### 5.1 `atlas start`

```bash
$ atlas start
[2026-04-16 09:00:00] Loading config from /etc/atlas/config.yaml
[2026-04-16 09:00:01] Connecting to PostgreSQL... OK
[2026-04-16 09:00:01] Recovering state from DB... 2 open positions found
[2026-04-16 09:00:02] Loading strategy: ma_crossover v1.0
[2026-04-16 09:00:02] Connecting to KIS (mode=paper)... OK
[2026-04-16 09:00:03] Subscribing to 3 symbols: [005930, 000660, 035720]
[2026-04-16 09:00:03] TradingFSM initialized (3 instances, state=IN_POSITION×2, IDLE×1)
[2026-04-16 09:00:03] Daemon started. PID=12345
```

**Crash Recovery 동작**:
1. `positions` 테이블 조회 → 미청산 포지션 복원
2. 각 종목별 TradingFSM을 `IN_POSITION`으로 초기화
3. `order_tracker` WHERE status IN ('pending', 'partially_filled') → 주문 상태 재조회

---

### 5.2 `atlas halt`

```bash
$ atlas halt
⚠  WARNING: This will immediately block all new orders.
   Current positions will NOT be closed automatically.
Continue? [y/N]: y

[2026-04-16 11:23:45] Sending SIGUSR1 to daemon (PID 12345)
[2026-04-16 11:23:46] Daemon acknowledged. All FSMs → SAFE_MODE.
[2026-04-16 11:23:47] Verified: 0 new orders in last 2 seconds.
Halt complete.
```

**내부 동작**:
1. CLI가 PID 파일 읽기 → daemon PID 획득
2. `kill -USR1 <pid>`
3. `/var/run/atlas.control` 파일에 `mode: halted` 기록
4. Daemon의 SignalHandler가 모든 TradingFSM에 `halt_requested` 이벤트 발송
5. 각 FSM이 SAFE_MODE 전이 → OrderExecutor가 신규 주문 거부
6. CLI가 `audit_events`를 2초간 모니터링 — 신규 order 엔트리 0건 확인
7. `audit_events`에 `severity=warn, type=halt_executed` 기록

**목표 시간**: Signal 발송부터 모든 FSM 전이 완료까지 30초 이내 (합격 기준 #4).

---

### 5.3 `atlas status`

```bash
$ atlas status
┌─────────────────────────────────────────────┐
│ ATLAS Status                                │
├─────────────────────────────────────────────┤
│ Mode:           active                      │
│ Daemon PID:     12345                       │
│ Uptime:         4h 23m                      │
│ Broker:         kis_paper                   │
│ Strategy:       ma_crossover v1.0           │
│ Symbols:        005930, 000660, 035720      │
├─────────────────────────────────────────────┤
│ FSM States:                                 │
│   005930 (삼성전자):   IN_POSITION          │
│   000660 (SK하이닉스): IDLE                 │
│   035720 (카카오):     IDLE                 │
├─────────────────────────────────────────────┤
│ Today:                                      │
│   Trades:     3 (2 buy, 1 sell)             │
│   PnL:        +124,500 KRW (+0.62%)         │
│   Risk:       OK (all 7 checks passing)     │
└─────────────────────────────────────────────┘
```

`--json` 플래그로 파싱 가능한 JSON 출력.

---

### 5.4 `atlas backtest`

```bash
$ atlas backtest strategies/ma_crossover.py --period 2024-01-01:2025-12-31 --symbols 005930,000660
Loading historical data... 502 trading days × 2 symbols
Running backtest...  [████████████████████] 100%

Results:
  Total Return:     +18.4%
  Annualized:       +9.1%
  Sharpe Ratio:     1.24    ✓ (≥ 1.0)
  Max Drawdown:     -8.7%
  Trades:           47
  Win Rate:         58.5%

Report saved: reports/backtest_20260416_122500.json
```

샤프 ≥ 1.0 이면 녹색 체크, 미달이면 빨간 X.

---

## 6. 보안 / 안전 장치

### 6.1 실행 권한

- `atlas` 바이너리는 OS 사용자 `jdw`만 실행 가능 (`chmod 750`)
- DB 연결 정보는 `/etc/atlas/config.yaml` (perm `640`, owner `atlas:atlas`)
- KIS API key는 환경변수 or macOS Keychain

### 6.2 Double-Confirm 명령

다음 명령은 `--yes` 없이 실행 시 y/N 프롬프트:
- `stop`, `halt`, `resume`
- 추후 `purge`, `delete-strategy` 등

### 6.3 감사 로그

모든 CLI 명령 실행이 `audit_events`에 남음:
```
event_type: 'cli_command'
severity: info
actor: jdw (OS user)
payload: { command: 'halt', args: [], pid: 99123 }
correlation_id: auto-gen
```

---

## 7. Phase 2 확장 시

| Phase 2 기능 | CLI 확장 | Daemon 변경 |
|-----------|---------|-----------|
| 다종목 전략 | `atlas strategy list`, `atlas strategy assign` | StrategyRegistry |
| Hot Reload | `atlas strategy reload <name>` | SIGHUP 핸들러 |
| Telegram 재도입 | Daemon 측 Adapter 추가 | CLI 변화 없음 — 두 경로 병존 |
| Grafana 대시보드 | `atlas metrics export` | PrometheusExporter 노드 추가 |

**핵심**: Phase 1의 CLI 설계를 깨지 않고 Phase 2 기능을 **추가만** 한다.

---

## 8. 구현 체크리스트 (Phase 1)

- [ ] `atlas` 엔트리포인트 (`pyproject.toml` scripts)
- [ ] argparse 기반 서브커맨드 파서
- [ ] PID 파일 관리
- [ ] Signal handler (daemon 측)
- [ ] Control file watcher (daemon 측)
- [ ] DB 조회 헬퍼 (status/positions/pnl)
- [ ] Double-confirm 프롬프트
- [ ] `--json` 출력 포맷터
- [ ] systemd unit 파일 (optional)

---

*End of Document — CLI Design*
