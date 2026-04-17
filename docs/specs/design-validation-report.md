# Design Validation Report — Phase 1 설계 점검 결과

> **실행 일자**: 2026-04-17
> **범위**: 저장소 `lapa7y-beep/trading-system-design` 전체 활성 문서
> **대조 기준**: `graph_ir_phase1.yaml` (SSoT)
> **검증 대상**: 설계작업 1~8의 8개 신규 문서 + 기존 활성 문서

---

## 결과 요약

**총 검증 항목**: 20개
**일치**: 16개 ✅
**수정함**: 3개 🔧
**의도된 차이**: 1개 ℹ️

**최종 판정**: ✅ **구현 착수 가능.** 수정 사항 반영 완료.

---

## 1. 완벽 일치 항목 (16개)

| # | 항목 | 검증 범위 | 결과 |
|---|------|---------|------|
| 1 | Node 6개 이름 | SSoT = blueprint = struct | ✅ |
| 2 | Port 6개 이름 | SSoT = ports.md = struct.md | ✅ |
| 3 | Adapter 12개 목록 | adapters.md = struct.md | ✅ |
| 4 | Adapter 클래스명 | ports.md §4 = adapters.md §2 = struct.md | ✅ |
| 5 | Domain Types 20개 | SSoT = domain-types.md | ✅ |
| 6 | CLI 12 명령 | cli-design = struct.md (파일 통합 의도적) | ✅ |
| 7 | DB 테이블 6개 | SSoT = db-schema.sql | ✅ |
| 8 | FSM 6 states | SSoT = blueprint = error.md | ✅ |
| 9 | FSM 12 transitions | SSoT (wildcard 포함) | ✅ |
| 10 | Edges 14개 | SSoT (cli_halt 포함) | ✅ |
| 11 | Pre-Order 7체크 | SSoT = blueprint = config.md | ✅ |
| 12 | 합격 기준 5개 | SSoT = test.md = boot.md = cli-design | ✅ |
| 13 | config 키 (halt_timeout, broker.mode 등) | config.md = boot.md = error.md = adapters.md | ✅ |
| 14 | Screens 17개 (W3+D4+O3+Op7) | screen-arch.md | ✅ |
| 15 | Severity 4단계 (info/warn/error/critical) | error.md 통합 기준 | ✅ |
| 16 | 4 Safeguards | SSoT = boot.md §8 | ✅ |
| 17 | KIS 에러 코드 | blueprint = error.md §11 | ✅ |
| 18 | Port → Adapter 매핑 | ports.md = adapters.md | ✅ |
| 19 | Boot §2.2 vs error.md §6 SAFE_MODE | 맥락 구분된 의도 (Boot중=중단, 운영중=SAFE) | ✅ |
| 20 | Domain Types 위치 (primitives/enums/market/...) | domain-types.md = struct.md | ✅ |

---

## 2. 수정 사항 (3건)

### 🔧 수정 #1: SSoT Port methods 업데이트 (3개 Port)

**원인**: 설계 문서(`port-signatures-phase1.md`)에서 확장한 메서드가 SSoT에 반영되지 않음.

| Port | 기존 SSoT | 추가된 메서드 | 수정 후 총 |
|------|---------|------------|-----------|
| MarketDataPort | 4개 | `stream` | 5개 |
| StoragePort | 5개 | `load_ohlcv`, `load_all_positions`, `load_portfolio_snapshot` | 8개 |
| ClockPort | 3개 | `is_trading_hours` | 4개 |

**총 메서드 수**: 22 → **28** (port-signatures-phase1.md와 일치)

**수정 파일**: `graph_ir_phase1.yaml` (version 1.0 → 1.0.1)

---

### 🔧 수정 #2: test-strategy-phase1.md 오기재

**원인**: TradingFSM transitions 수가 잘못 기재됨.

**파일**: `docs/specs/test-strategy-phase1.md` line 84
```diff
- | TradingFSM | 23 transition 전부, 불가능 전이 시 warn, persist 타이밍 |
+ | TradingFSM | 12 transition 전부, 불가능 전이 시 warn, persist 타이밍 |
```

SSoT 기준 실제 transitions: **12개** (+ wildcard halt_requested 1개, 총 13개 중 wildcard 제외 12개가 정답).

---

### 🔧 수정 #3: test.md §7 Step 1 누락

**원인**: 구현 Step 8개 중 Step 1 (저장소 + 인프라)에 대응하는 항목이 테스트 작성 시기 표에서 빠짐.

**파일**: `docs/specs/test-strategy-phase1.md` §7
```diff
+ | Step 1: 저장소 + 인프라 | (테스트 없음, 의존성 설치만) |
| Step 2: Core/Domain | unit/core/domain/* (동시 작성) |
```

작은 완전성 보완.

---

## 3. 의도된 차이 (1건)

### ℹ️ SSoT adapters 13개 vs adapters-spec 12개

**이유**: SSoT는 `KISLiveBrokerAdapter`를 포함 (Phase 2D까지 금지 플래그). Phase 1 구현 범위에서는 제외되므로 `adapters-spec-phase1.md` 목록은 12개.

**판정**: 의도적 설계. 수정 불필요.

---

## 4. 남은 경미한 불완전성 (수정 불필요)

| 사항 | 비고 |
|------|------|
| struct.md cli 폴더의 파일 8개 vs CLI 명령 12개 | `status.py`가 status/positions/pnl/orders 묶음, `halt.py`가 halt/resume 묶음. **의도된 통합**. |
| INDEX.md 수치 요약에 Screens·Mock 어댑터 수 포함 | SSoT의 `expected_counts`에는 없으나 INDEX는 총괄 문서로 추가 정보 포함. 불일치 아님. |

---

## 5. 구현 착수 체크리스트 최종 확인

INDEX.md에 명시된 8개 체크리스트 전부 확인:

- [x] 수치 체크섬 일치 (Nodes 6 / Ports 6 / Edges 14 / Domain Types 20 / Adapters 12 / CLI 12 / Screens 17 / 합격기준 5)
- [x] `graph_ir_phase1.yaml`이 모든 설계 문서의 SSoT 역할 수행 (v1.0.1로 최신화)
- [x] config-schema ↔ blueprint의 config 키 일치
- [x] port-signatures ↔ adapter-spec 메서드 시그니처 일치 (SSoT도 동기화 완료)
- [x] project-structure §10 구현 착수 8단계 확인
- [x] test-strategy §5 합격 기준 5개 자동화 가능 확인
- [ ] 로컬 개발 환경 (Python 3.11+, Docker, PostgreSQL) — 사용자 준비 항목
- [ ] KIS API 인증 정보 (모의투자 계정) — 사용자 준비 항목

---

## 6. 결론

**Phase 1 설계 문서는 내부 일관성을 달성했다.** 발견된 3건의 경미한 수정 사항은 본 보고서와 함께 반영되었으며, 의도된 차이 1건은 설계 문서의 "단계적 확장 전략"의 결과로 문제 없음.

**🎯 구현 착수 가능.**

---

## 7. 부록 — 검증 스크립트 (재현용)

```bash
# 1. 전체 저장소 파일 목록
curl -s "https://api.github.com/repos/lapa7y-beep/trading-system-design/git/trees/main?recursive=1" \
  | jq -r '.tree[] | select(.type=="blob") | .path' | sort

# 2. SSoT 수치 체크섬 확인
curl -sL ".../graph_ir_phase1.yaml" | grep -A20 "^expected_counts:"

# 3. Node 목록 대조
curl -sL ".../graph_ir_phase1.yaml" | grep -E "^  [A-Z][a-zA-Z]+:$"
curl -sL ".../docs/blueprints/path1-phase1-blueprint.md" | grep "^## [0-9]\+\."

# 4. Port 메서드 대조
for port in MarketDataPort BrokerPort StoragePort ClockPort StrategyRuntimePort AuditPort; do
  echo "=== $port ==="
  grep "methods" graph_ir.yaml  # SSoT
  sed -n "/^class $port(ABC):/,/^class /p" port-signatures-phase1.md \
    | grep -oE "async def [a-z_]+|def [a-z_]+"  # ports.md
done
```

---

*Design Validation Report v1.0 — 2026-04-17*

---

## 8. 2차 교차 검증 (2026-04-17)

1차 점검 완료 후, 저장소 최신 상태 기준으로 11개 항목 재검증 수행.

### 신규 발견 → 수정 완료

**adapters.md 메서드 커버리지 부족 6건** — Port ABC 메서드에 대한 Adapter 설명이 축약되어 있던 것을 보완.

| Adapter | 추가된 메서드 설명 |
|---------|----------------|
| MockBrokerAdapter | `cancel`, `get_order_status`, `get_account_balance` |
| KISWebSocketAdapter | `unsubscribe`, `get_current_price`, `get_historical` (REST 위임 명시) |
| KISRestAdapter | `unsubscribe`, `get_current_price` |
| PostgresStorageAdapter | `load_ohlcv`, `load_position`, `load_all_positions` |
| InMemoryStorageAdapter | 전체 8메서드 커버리지 명시 |
| HistoricalClockAdapter | `now`, `trading_hours_check` |

**수정 파일**: `docs/specs/adapter-spec-phase1.md` (v1.0 → v1.1)

### 재확인 완료 항목

- SSoT Port methods: 1차 수정 정상 반영 ✅
- test.md FSM transition: "12" 수정 반영 ✅
- INDEX 등재 24파일: 전부 존재 ✅
- config 키 일관성: 완벽 ✅
- Domain Types ↔ DB: 의도적 차이만 ✅

*Design Validation Report v1.1 — 2026-04-17*

---

## 9. 3차 교차 검증 (2026-04-17)

자동화 검증 스크립트(Python)로 71개 항목 일괄 검증. 결과: 69 통과 / 2 실패.

### 실패 분석

| # | 항목 | 원인 | 조치 |
|---|------|------|------|
| 1 | CSVReplayAdapter unsubscribe 미언급 | 2차 검증에서 누락 | adapters.md v1.2에서 보완 |
| 2 | CLI 15개 감지 | 스크립트 오탐 — Phase 2 범위 밖 명령 (`strategy reload`, `metrics export`)까지 매칭 | **문서 정상** (Phase 1 CLI는 정확히 12개) |

### 수정 파일

- `docs/specs/adapter-spec-phase1.md` v1.1 → v1.2: CSVReplayAdapter unsubscribe 추가

### 최종 결과

**71개 항목 중 70개 통과, 1개 오탐(문서 정상). 실질 불일치 0건.**

*Design Validation Report v1.2 — 2026-04-17*
