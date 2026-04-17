# 화면 아키텍처 (3카테고리·14화면·횡단감시)

> **목적**: 거래/거래지원/설계 3카테고리와 횡단 감시 레이어로 구성된 14화면의 구조, 레이아웃, 기술스택을 정의한다.
> **층**: What
> **상태**: confirmed
> **최종 수정**: 2026-04-17 (v2.1)
> **레이아웃**: v2.3 (구현 도구 기준 전면 재작성)
> **변경 사유**: 4 카테고리 → 3 카테고리 + 횡단 감시. Path 쌍 기반 재분류.

## 1. 분류 원칙

### 1.1 왜 바꿨는가

v1의 4 카테고리(Watchdog / Operating / Design / Ontology)는 두 가지 문제가 있었다.

- **5 Paths와 4 Categories의 축이 다르다.** Path는 백엔드 실행 단위(데이터 흐름·실행 시점), Category는 사용자 작업 의도. 이 둘을 1:1로 맞추려 해서 Operating에 P1+P4가 혼재하고, P5(감시운영)가 이름과 위치가 불일치했다.
- **P1(실시간매매)과 P4(포트폴리오)는 한 쌍이다.** P1이 개별 매매를 실행하고 P4가 전체 포지션을 관리한다. P4의 리밸런싱 주문은 P1의 OrderGate → ExecEngine을 재사용한다. 같은 카테고리에 있어야 한다.

### 1.2 새 분류 기준

| 기준 | 질문 |
|------|------|
| 거래 | 돈이 움직이는가? |
| 거래 지원 | 거래가 잘 되도록 준비하는 것인가? |
| 설계 | ATLAS 시스템 자체를 만드는 것인가? |
| 감시 | 전부 정상인가? |

감시는 카테고리가 아니라 **횡단 레이어**다. 거래·거래 지원·설계 모두를 관찰하고 보호한다.

### 1.3 백엔드 구조와 화면 구조의 관계

```
백엔드 (HR-DAG)              화면 (사용자 관점)
━━━━━━━━━━━━━━━━━            ━━━━━━━━━━━━━━━━━━━━━
ATLAS                        ┌─ 감시 (횡단 오버레이) ─┐
├── 설계                     │                       │
└── 운영                     │ 거래 | 거래 지원 | 설계 │
    └── 감시/제어 (P5 껍질)   │                       │
        ├── 거래 (P1+P4)     └───────────────────────┘
        └── 거래 지원 (P2,P3)

백엔드 진실: P5는 모든 운영을 감싸는 껍질 (선택 B)
화면 표현: 감시는 횡단 오버레이 (선택 C)
```

---

## 2. 화면 구조

### 2.0 감시 횡단 (P5 — Header 오버레이, 항상 위)

어느 화면에서든 접근 가능. 카테고리가 아닌 레이어.

| 화면 | Path 노드 | 역할 |
|------|-----------|------|
| Health | Guardian (HealthMonitor, AccountReconciler, AuditLogger) | 전체 시스템 상태 한눈에. Safeguards 4개 상태. Kill switch. |
| System | EventBus (EventRouter, EventPersister) + StoragePort (인프라) | EventBus 흐름/적체, DB/Redis 연결, Docker 상태, Scheduler 현황 |
| Notify | Operator.Notifier | 알림 채널(Telegram/Discord) 상태, 알림 이력, 채널 설정 |
| Rules | Guardian 규칙 + Operator.ApprovalGate | Watchdog 규칙 관리, 승인 대기 목록, 승인 이력 |

**Operator 서브노드 배치:**
- Notifier → 감시(Notify) — 주 화면
- ApprovalGate → 감시(Rules) — 주 화면. 거래(P1 Control)에서는 읽기 전용 참조
- Scheduler → 감시(System) — 주 화면. 배치 스케줄 현황/설정
- ConfigManager → 설계(Docs/설정) — 주 화면. 감시(System)에서는 런타임 파라미터 읽기 전용

### 2.1 거래 (P1+P4 — 돈이 움직이는 곳)

| 화면 | Path 노드 | 역할 |
|------|-----------|------|
| Overview | — (집계 뷰) | 거래 KPI 요약: 일간 P&L, 포지션 현황, 체결 건수, 전략별 성과 |
| P1 Trading | DataIngest, SignalFusion, OrderGate, ExecEngine | 4탭 유지: Monitor / Control / Policy / Test |
| P4 Portfolio | PortfolioManager | 성과 분석, 비중 조정, 리밸런싱, 리포트 |

**Overview vs Health 경계:**
- Overview = 거래 KPI (P&L, 포지션, 체결) — "얼마 벌었나"
- Health = 시스템 상태 (Safeguards, 연결, 프로세스) — "정상 동작하나"

### 2.2 거래 지원 (P2+P3+Market data — 거래를 뒷받침하는 곳)

| 화면 | Path 노드 | 역할 |
|------|-----------|------|
| Strategy | StrategyWorkbench + StrategyValidator | 전략 개발 + 백테스트 통합. 서브탭: Edit / Backtest / Optimize / History |
| Knowledge | KnowledgeIngest, KnowledgeEngine | 서브탭: Build(수집/파싱) / Explore(검색/조회) / Quality(무결성) |
| Market data | DataIngest 수집 설정 + StoragePort(TimeSeries) | 수집 종목 관리, OHLCV 저장 상태, 수집 설정 |

**Strategy + Backtest 통합 근거:**
- 사용 흐름: 전략 작성 → 백테스트 → 결과 확인 → 수정 → 재실행
- 별도 화면이면 왕복 발생. 서브탭으로 통합하면 한 화면 내에서 순환.
- 화면 수: 4 → 3. 마우스 동선 개선.

### 2.3 설계 (시스템 전체를 만드는 곳)

| 화면 | 역할 |
|------|------|
| PathCanvas | 5 Path 전체의 노드/엣지 설계. L2 접기 ↔ L3 펼치기. Graph IR 편집. |
| Code Generator | Graph IR → 실행 가능 코드 변환. 변환 결과 미리보기. |
| Validator | 설계 규칙 위반 검출. 실시간 피드백. |
| Docs | 설계 문서 편집/조회. ConfigManager 설정 관리. System Manifest 동기화. |

**설계 ≠ P3.** 설계는 ATLAS 시스템 전체를 만드는 메타 레이어. P3 전략개발은 거래 지원.

**Phase 매핑:**
- Phase 1: 설계 카테고리 전체 미구현. CLI + MockBroker + 수동 전략.
- Phase 2+: PathCanvas → Code Generator → Validator 순차 구현.

---

## 3. 화면 집계

```
감시 횡단:   4 화면 (Health, System, Notify, Rules)
거래:       3 화면 (Overview, P1 Trading, P4 Portfolio)
거래 지원:   3 화면 (Strategy, Knowledge, Market data)
설계:       4 화면 (PathCanvas, Code Generator, Validator, Docs)
━━━━━━━━━━━━━━━━━━━━━
총:         14 화면 (v1 대비 17 → 14, 3개 감소)
```

감소 이유:
- Strategy + Backtest 통합 (2 → 1)
- Ontology 3화면(Build/Explore/Quality) → Knowledge 1화면 + 서브탭
- Watchdog 카테고리 해체 → 감시 횡단으로 재편

---

## 4. HR-DAG 노드 → 화면 매핑

### 4.1 13개 인터페이스 노드

| 인터페이스 노드 | Path | 화면 | 카테고리 |
|----------------|------|------|----------|
| DataIngest | P1 | P1 Trading (Monitor) + Market data | 거래 + 거래 지원 |
| SignalFusion | P1 | P1 Trading (Monitor) | 거래 |
| OrderGate | P1 | P1 Trading (Control) | 거래 |
| ExecEngine | P1 | P1 Trading (Control) | 거래 |
| KnowledgeIngest | P2 | Knowledge (Build) | 거래 지원 |
| KnowledgeEngine | P2 | Knowledge (Explore, Quality) | 거래 지원 |
| StrategyWorkbench | P3 | Strategy (Edit) | 거래 지원 |
| StrategyValidator | P3 | Strategy (Backtest, Optimize) | 거래 지원 |
| PortfolioManager | P4 | P4 Portfolio | 거래 |
| EventBus | P5 | System | 감시 |
| Guardian | P5 | Health + Rules | 감시 |
| Operator | P5 | Notify + Rules + System(Scheduler) | 감시 (+설계 ConfigManager) |
| StoragePort | 공유 | System + Market data | 감시 + 거래 지원 |

### 4.2 Four Critical Safeguards

| 취약점 | 화면 위치 |
|--------|----------|
| 중복주문방지 | 거래 → P1 Trading (Control) |
| 상태계좌일관성 | 거래 → P1 Trading + 감시 → Health |
| 이벤트내구성 | 감시 → System |
| 명령제어보안 | 감시 → Rules + Notify |

### 4.3 6개 공유 저장소

| 저장소 | 상태 확인 화면 | 데이터 사용 화면 |
|--------|---------------|-----------------|
| TimeSeries DB | 감시(System) | 거래 지원(Market data), 거래(P1 Monitor) |
| Knowledge Graph | 감시(System) | 거래 지원(Knowledge) |
| Strategy Registry | 감시(System) | 거래 지원(Strategy) |
| Position State | 감시(System) | 거래(Overview, P1, P4) |
| Event Log | 감시(System) | 감시(Health, Rules) |
| Config | 설계(Docs) | 감시(System 읽기 전용) |

---

## 5. 외곽 프레임 (v1에서 유지)

### 5.1 Header (상단 고정) — v2.4 기준

```
┌──────────────────────────────────────────────────────────────────┐
│ [ATLAS]  [LIVE ▾]     [감시 띠: ● ● ● ●]               [설정] │
└──────────────────────────────────────────────────────────────────┘
```

- ATLAS 로고 → 현재 카테고리 홈
- 환경 표시 (LIVE/PAPER/SIM) — LIVE=빨강, PAPER=주황, SIM=회색
- 감시 띠 — Safeguards 4개 상태 점. 이상 시 점멸. 클릭 → Health 진입
- 설정 — 테마·환경 설정

> **HALT 버튼 제거 (v2.4)** — 긴급 제어는 Telegram `/halt` 우선.
> 화면 버튼은 오조작 위험이 있고, 장중 긴급 상황에서는
> 폰 Telegram이 웹보다 빠름. `§10.7` 참조.

### 5.2 Sidebar (좌측)

```
┌──────────────────────┐
│ ◆ 거래         [2-0] │
│   Overview            │
│   P1 Trading          │
│   P4 Portfolio        │
│                      │
│ ◆ 거래 지원    [2-0] │
│   Strategy            │
│   Knowledge           │
│   Market data         │
│                      │
│ ◆ 설계         [2+]  │ ← 잠금
│   PathCanvas  🔒     │
│   Code Gen    🔒     │
│   Validator   🔒     │
│   Docs        🔒     │
└──────────────────────┘
```

- 감시는 Sidebar에 없음 — Header 띠에서 접근.
- `[2-0]` — Phase 2-0 구현 대상.
- `[2+]` 🔒 — Phase 2+ 구현 전까지 클릭 시 "Phase 2+ 기능입니다" 안내.

### 5.3 Layout

```
┌─────────────────────────────────────────┐
│ Header (감시 띠 포함)                    │
├──────────┬──────────────────────────────┤
│ Sidebar  │ Main content                 │
│          │                              │
│          │                              │
└──────────┴──────────────────────────────┘
```

---

## 6. 공통 설계 원칙 (v2.4 기준)

1. **대기 없음 / 즉시 표시** — 스피너 대신 점진적 채움. 연결은 백그라운드.
2. **시스템이 다음 단계 제시** — 작업 완료 후 toast 제안. HTML 화면만 해당 (Grafana 불가).
3. **보안 게이트 — Phase별 적용**
   - Phase 1: pydantic Validator 통과 → YAML 저장. 승인 없음.
   - Phase 2-0: Validator + Audit 2단계. Telegram ApprovalGate 연동.
   - Phase 2+: Validator + Telegram ApprovalGate + Audit 3 게이트 완성.
4. **컨텍스트 전달 = URL 파라미터** — 화면 간 이동 시 `?symbol=X` 등으로 대상 자동 세팅.
5. **감시는 항상 위에서** — Header 띠로 1-click Health 진입. 어느 화면이든.
6. **거래 지원 참조 = 사이드 노트** — Knowledge 결과를 거래 화면에 일시 패널로 표시 (Phase 3).
7. **긴급 제어는 Telegram 우선** — HALT/KILL은 화면 버튼 없음. Telegram `/halt`가 유일한 긴급 채널.
8. **설계 화면은 Phase 2+ 잠금** — Sidebar 표시되나 클릭 시 Phase 안내. 오조작 방지.

---

## 7. 카테고리 간 이동 규칙 (v2.4 기준)

| 횡단 방향 | 성격 | UX 장치 | 구현 도구 |
|-----------|------|---------|---------|
| 거래 ↔ 거래 | 내부 이동 | Sidebar 클릭 또는 Overview 카드 | Grafana link / HTML |
| 거래 → 감시 | 비상 확인 | Header 감시 띠 클릭 → Health | Grafana |
| 거래 → 거래 지원 | 참조 | Sidebar 또는 카드 🔍 아이콘 | Grafana link |
| 거래 지원 → 거래 | 전략 적용 | 전략 저장 후 toast 제안 | HTML toast만 |
| 설계 → 운영 | 배포 (Phase 2+) | Code Generator 완료 후 toast | HTML toast만 |
| → 설계 | 수동만 | Sidebar (Phase 2+ 잠금 해제 후) | — |
| 긴급 제어 | HALT/KILL | Telegram `/halt` `/kill` | Telegram Bot |

> **toast 구현 범위**: Grafana는 toast 불가. HTML 화면(`control.html`, `strategy.html` 등)만 toast 사용.
> Grafana에서의 화면 전환은 패널 내 `Data links` 기능으로 대체.

---

## 8. P1 Trading 4탭 (v1에서 유지)

| 탭 | 역할 | 주요 영역 |
|----|------|----------|
| Monitor | 실시간 관찰 | 좌: FSM 상태 + 포지션. 우: 시세/지표 서브탭 |
| Control | 개입/조치 | 상: 조치 버튼(일시정지/재개/긴급청산). 하: 조치 이력. ApprovalGate 읽기 전용 |
| Policy | 정책 설정 | 전략 목록 + 리스크 한도 + 종목 필터. 3 게이트 Save |
| Test | 테스트 실행 | MockBroker 기반 시뮬레이션. 세션 단위, 영구 저장 없음 |

---

## 9. Strategy 통합 서브탭 (신규)

| 서브탭 | 역할 |
|--------|------|
| Edit | 전략 코드 작성/편집. `strategies/*.py` 관리 |
| Backtest | 백테스트 실행 + 결과 차트 + 성과 지표 (Sharpe, MDD 등) |
| Optimize | 파라미터 최적화 + 워크포워드 분석 |
| History | 전략 버전 이력 + 비교 |

워크플로: Edit → Backtest → (수정) → Backtest → Optimize → History에 저장

---

## 10. 변경 이력

| 일자 | 버전 | 변경 | 근거 |
|------|------|------|------|
| 2026-04-16 | v1.0 | 초안 (4 카테고리, 17 화면) | 대화 세션 결과를 .md로 고정 |
| 2026-04-16 | v1.1 | 외곽 프레임 추가 | 방향 A 완료 |
| 2026-04-16 | v1.2 | 화면 전환 흐름 추가 | 방향 B 완료 |
| 2026-04-16 | v1.3 | P1 Trading 4탭 추가 | 방향 C Phase 1 완료 |
| 2026-04-16 | v1.4 | Phase 2 5화면 추가 | 방향 C Phase 2 완료 |
| 2026-04-17 | v2.1 | 전체 14화면 내부 레이아웃 추가 (§10). Phase1 CLI 매핑 전수 |
| 2026-04-17 | **v2.0** | **3 카테고리 + 횡단 감시로 전면 재편** | 5 Paths와 Categories 축 불일치 해소. P1+P4 한 쌍. 감시 횡단. Strategy+Backtest 통합. Operator 서브노드 배치 확정. 14 화면. |

---

## 11. 다음 단계

- [x] v1 방향 D — 구조 .md로 고정
- [x] v1 방향 A — 공통 외곽 프레임 설계
- [x] v1 방향 B — 화면 간 전환 흐름
- [x] v1 방향 C Phase 1~2 — P1 Trading + 5 화면 큰 테두리
- [x] **v2 — 카테고리 재편 (3 + 횡단)**
- [x] **v2.1 — 전체 14화면 내부 레이아웃**
- [x] **v2.2 — 프론트엔드 기술스택 확정 + FastAPI 레이어 설계**
- [ ] Phase 2-0 구현 — FastAPI 서버 + Grafana 패널 + HTML 제어 + Telegram Bot
- [ ] Phase 2A 진입 — Path 6 Market Intelligence

---

## 12. 프론트엔드 기술스택 확정 (v2.2)

> 결정일: 2026-04-17
> 기준: 프론트엔드 경험 최소 + 백엔드 중심 + React 전환 경로 확보

### 12.1 전략: A+B 조합

| 구분 | 도구 | 역할 | 한계 |
|------|------|------|------|
| A | Telegram Bot | 긴급 제어 + 승인 (모바일) | 복잡한 폼 불가 |
| B-읽기 | Grafana | 모니터링/차트/수치 시각화 | 버튼 없음 |
| B-쓰기 | HTML + FastAPI | 제어/설정 화면 (버튼, 폼) | React보다 단순 |

### 12.2 화면별 구현 도구

| 화면 | 도구 | 이유 |
|------|------|------|
| Overview KPI/차트 | Grafana | 읽기 전용, SQL 직결 |
| P1 Trading Monitor (차트) | Grafana | OHLCV 시계열 |
| P1 Trading Control | HTML (버튼) + Telegram | HALT/Resume/Stop |
| P1 Trading Policy | HTML (폼) | config 편집 |
| P4 Portfolio 성과 | Grafana | 차트/수치 |
| Strategy Edit/Backtest | HTML (편집기/폼) | 파일 R/W + 실행 |
| Knowledge | Grafana (현황) | Phase 3까지 최소 |
| Market data | Grafana | 수집 현황 |
| Health | Grafana + HTML | Safeguards 표시 + HALT 버튼 |
| System | Grafana | EventBus/Docker/Scheduler |
| Notify | HTML (설정폼) | 채널 ON/OFF |
| Rules | HTML (승인버튼) + Telegram | ApprovalGate |
| 설계 4화면 | Phase 2+ 별도 | LiteGraph.js 등 |

### 12.3 FastAPI 엔드포인트 요약

```
읽기 (GET)
  /api/status  /api/health  /api/audit
  /api/positions  /api/pnl  /api/orders  /api/orders/live
  /api/config  /api/strategies  /api/strategies/{name}
  /api/backtest/{job_id}

쓰기 (POST)
  /api/control/halt  /api/control/resume  /api/control/stop
  /api/config  /api/strategies/{name}  /api/backtest

실시간 (WebSocket)
  /ws/fsm      ← FSM 상태 변화 push
  /ws/orders   ← 체결/거절 이벤트 push

합계: REST 14 + WS 2 = 16 엔드포인트
```

### 12.4 React 전환 경로

```
Phase 2-0 (지금)          Phase 2+ (필요 시)
─────────────────         ─────────────────
FastAPI API   ──────────▶ FastAPI API (무변경)
WebSocket     ──────────▶ WebSocket (무변경)
Grafana 패널  ──────────▶ React 차트 컴포넌트
HTML static/  ──────────▶ React build 결과물

전환 비용: 프론트엔드만 교체. 백엔드 재설계 없음.
전환 조건: Grafana+HTML 안정화 후 React 학습 or Claude Code 활용
```

### 12.5 핵심 규칙

```
1. HTML 로직 금지 — fetch()/WebSocket 호출과 표시만
2. 모든 API 응답 JSON — HTML/React 동일 재사용
3. 제어는 control_file.py 경유 — CLI와 동일 경로
4. 긴급 제어는 Telegram 우선 — 폰에서 /halt가 가장 빠름
```

---

## 10. 화면 내부 레이아웃 (v2.3 — 구현 도구 기준 전면 재작성)

> 최종 수정: 2026-04-17 (v2.3)
> 기준: 3카테고리 + 횡단 감시, 14화면, 구현 도구 확정
>
> **구현 도구 범례**
> - `[Grafana]` — PostgreSQL 직결, 읽기 전용, 버튼 없음
> - `[HTML]`    — FastAPI /static/ 서빙, 버튼/폼 중심
> - `[Telegram]`— Bot 명령으로 대체, 별도 화면 없음
> - `[CLI]`     — Phase 1 대응 명령어
> - `[Phase N]` — 구현 시점

---

### 10.1 거래 — Overview `[Grafana]` `[Phase 2-0]`

Grafana 대시보드. 버튼 없음. PostgreSQL 직결 SQL 쿼리로 패널 구성.

| 패널 | Grafana 패널 타입 | SQL 소스 | Phase 1 대응 |
|------|-----------------|---------|-------------|
| 일간 P&L | Stat | `SELECT SUM(realized_pnl) FROM trades WHERE date=today` | `atlas pnl` |
| 보유 포지션 수 | Stat | `SELECT COUNT(*) FROM positions WHERE quantity > 0` | `atlas positions` |
| 오늘 체결 수 | Stat | `SELECT COUNT(*) FROM trades WHERE date=today` | `atlas orders` |
| 누적 수익률 + Sharpe | Stat | `SELECT total_return, sharpe FROM daily_pnl ORDER BY date DESC LIMIT 1` | `atlas pnl` |
| 포지션 현황 테이블 | Table | `SELECT symbol, quantity, avg_price, unrealized_pnl FROM positions` | `atlas positions` |
| 전략별 성과 | Bar chart | `SELECT strategy_id, SUM(pnl) FROM trades GROUP BY strategy_id` | `atlas pnl` |
| 체결 내역 | Table | `SELECT executed_at, symbol, side, qty, price, strategy_id FROM trades ORDER BY executed_at DESC LIMIT 50` | `atlas orders` |

**Grafana 대시보드 파일**: `grafana/dashboards/overview.json`

---

### 10.2 거래 — P1 Trading

#### Monitor 탭 `[Grafana]` `[Phase 2-0]`

| 패널 | Grafana 패널 타입 | SQL/소스 | Phase 1 대응 |
|------|-----------------|---------|-------------|
| FSM 상태 (종목별) | Table | `SELECT symbol, fsm_state FROM positions` | `atlas status` |
| 노드 파이프라인 상태 | Stat × 4 | `/api/health` WebSocket | Phase 2 |
| OHLCV 차트 (1분봉 + MA) | TimeSeries | `SELECT ts, open,high,low,close FROM market_ohlcv WHERE symbol=? ORDER BY ts` | Phase 2 |
| 주문 로그 | Table (실시간) | `SELECT executed_at,symbol,side,qty,price,status,reject_reason FROM order_tracker ORDER BY created_at DESC` | `atlas orders` |

**Grafana 대시보드 파일**: `grafana/dashboards/p1_monitor.json`

#### Control 탭 `[HTML]` `[Phase 2-0]`

HTML 파일: `atlas/api/static/control.html`
FastAPI 엔드포인트: `POST /api/control/*`

```
┌─────────────────────────────────────────┐
│ P1 Trading — Control                    │
├─────────────────────────────────────────┤
│  시스템 제어                             │
│  [⏸ HALT]   [▶ Resume]   [■ Stop]      │
│  ← POST /api/control/halt|resume|stop   │
│                                         │
│  Mode:  AUTO ◉   MANUAL ○               │
│  ← POST /api/control/mode               │
├─────────────────────────────────────────┤
│  포지션 조치 (Phase 2)                   │
│  005930  [손절 청산]  [전량 청산]          │
│  000660  [손절 청산]  [전량 청산]          │
│  ← POST /api/positions/{symbol}/close   │
├─────────────────────────────────────────┤
│  Master: [전 포지션 청산] ← 더블 확인     │
│  ← POST /api/positions/close_all        │
├─────────────────────────────────────────┤
│  조치 이력                               │
│  ← GET /api/audit?type=control          │
└─────────────────────────────────────────┘
```

**긴급 HALT**: Telegram `/halt` 명령이 우선 — 폰에서 즉시 실행 가능

#### Policy 탭 `[HTML]` `[Phase 2-0]`

HTML 파일: `atlas/api/static/policy.html`
FastAPI 엔드포인트: `GET/POST /api/config`

```
┌─────────────────────────────────────────┐
│ P1 Trading — Policy                     │
├─────────────────────────────────────────┤
│  활성 전략 (체크박스)                    │
│  ☑ ma_crossover  ☑ rsi_reversal         │
│                                         │
│  리스크 파라미터 (입력 폼)               │
│  max_cash_usage    [95  ]%               │
│  max_position_pct  [20  ]%               │
│  max_daily_loss    [-2  ]%               │
│  max_daily_trades  [40  ]                │
│  trading_hours     [09:00] ~ [15:20]     │
│  circuit_breaker   [3  ] / [60  ]s       │
│                                         │
│  Watchlist (종목 목록)                   │
│  [005930] [000660] [035720] [+ 추가]     │
│                                         │
│  [Save] ← POST /api/config              │
│  ← pydantic Validator 통과 후 저장       │
└─────────────────────────────────────────┘
```

#### Test 탭 `[HTML]` `[Phase 2-0]`

HTML 파일: `atlas/api/static/strategy.html` (Strategy Backtest 탭과 공유)
FastAPI 엔드포인트: `POST /api/backtest`

```
┌─────────────────────────────────────────┐
│ P1 Trading — Test                       │
├─────────────────────────────────────────┤
│  전략    [ma_crossover.py ▼]             │
│  기간    [2024-01-01] ~ [2025-12-31]     │
│  초기자본 [100,000,000]                  │
│  종목    [005930, 000660]                │
│                                         │
│  [▶ Run Backtest]                       │
│  ← POST /api/backtest                   │
│  ← atlas backtest (Phase 1 CLI 직접)    │
├─────────────────────────────────────────┤
│  결과 (GET /api/backtest/{job_id})       │
│  Sharpe  [1.24 ✓]   Return  [+18.4%]   │
│  MDD     [-8.7%]    Trades  [47]        │
│  Win Rate [58.5%]                        │
│                                         │
│  Equity Curve: Phase 2 Grafana 패널      │
└─────────────────────────────────────────┘
```

---

### 10.3 거래 — P4 Portfolio `[Grafana]` `[Phase 2B]`

Grafana 대시보드. 버튼 없음. 리밸런싱 실행은 Telegram `/rebalance` 명령.

| 패널 | Grafana 패널 타입 | SQL 소스 |
|------|-----------------|---------|
| 총 자산 + 누적 수익률 | Stat | `daily_pnl` 최신 행 |
| Sharpe / MDD | Stat | `daily_pnl` 집계 |
| 종목별 비중 | PieChart | `positions` |
| 전략별 수익률 | Bar chart | `trades GROUP BY strategy_id` |
| 수익률 곡선 | TimeSeries | `daily_pnl ORDER BY trade_date` |
| 리스크 지표 (HHI) | Stat | `positions` 집중도 계산 |

**리밸런싱 실행**: Telegram `/rebalance` → ApprovalGate → OrderGate 경유

**Grafana 대시보드 파일**: `grafana/dashboards/portfolio.json`

---

### 10.4 거래 지원 — Strategy

#### Edit 탭 `[HTML]` `[Phase 2-0]`

HTML 파일: `atlas/api/static/strategy.html`
FastAPI 엔드포인트: `GET/POST /api/strategies/{name}`

```
┌─────────────────────────────────┬────────────────────────────────┐
│ 전략 목록                        │ 코드 편집기                     │
│ ─────────────────────────────── │ ────────────────────────────── │
│ ▶ ma_crossover.py  v1.0         │ class MACrossover(BaseStrategy):│
│   rsi_reversal.py  v0.3         │   def __init__(self):           │
│   bollinger.py     v0.1         │     self.fast = 5               │
│                                 │     self.slow = 20              │
│ [+ 새 전략]                      │   def evaluate(self, data):     │
│ ← GET /api/strategies           │     ...                         │
│                                 │ ← GET /api/strategies/{name}    │
│ 파라미터                         │                                 │
│ fast_period  [5 ]               │ [저장]  [→ Backtest 실행]        │
│ slow_period  [20]               │ ← POST /api/strategies/{name}   │
│ stop_loss    [3%]               │                                 │
└─────────────────────────────────┴────────────────────────────────┘
```

#### Backtest 탭 `[HTML]` `[Phase 2-0]`

P1 Test 탭과 동일 HTML 공유. `POST /api/backtest` 재사용.

#### Optimize 탭 `[HTML]` `[Phase 2A]`

HTML 파일: `atlas/api/static/optimize.html`
FastAPI 엔드포인트: `POST /api/optimize`

```
┌─────────────────────────────────────────┐
│ 파라미터 범위 설정 (Grid Search)          │
│  fast_period   min[3] max[10] step[1]   │
│  slow_period   min[15] max[30] step[5]  │
│  조합 수: 56가지                          │
│  [▶ Run Grid Search]                    │
├─────────────────────────────────────────┤
│ 최적 파라미터 Top 3                      │
│  #1  fast=5  slow=20  Sharpe 1.24       │
│  #2  fast=5  slow=25  Sharpe 1.18       │
│  [#1 적용 → Edit]                        │
├─────────────────────────────────────────┤
│ Walk-Forward 과적합 지수: 0.82  양호      │
└─────────────────────────────────────────┘
```

#### History 탭 `[HTML]` `[Phase 2-0]`

FastAPI 엔드포인트: `GET /api/strategies/{name}/history`

```
┌─────────────────────────────────────────┐
│ 전략 버전 이력                            │
│  ma_crossover                            │
│  ├── v1.0  2026-04-15  Sharpe 1.24 ★   │
│  ├── v0.9  2026-04-10  Sharpe 1.18      │
│  └── v0.8  2026-04-05  Sharpe 0.92      │
│                                         │
│  선택 버전 상세                           │
│  작성일: 2026-04-15                      │
│  변경 내용: fast 7→5 수정                │
│  [이 버전으로 복원]                       │
│  ← POST /api/strategies/{name}/restore  │
└─────────────────────────────────────────┘
```

**전략 버전 저장소**: `strategies/` 파일 + git 이력 활용

---

### 10.5 거래 지원 — Knowledge `[Grafana]` + `[HTML]` `[Phase 3]`

Phase 3 전까지 최소 구현.

| 서브탭 | 도구 | 내용 |
|--------|------|------|
| Build | HTML 폼 | 수집 소스 설정, 수집 주기, [수집 실행] 버튼 |
| Explore | Grafana | 온톨로지 노드·엣지 수 Stat 패널 + 검색 입력 (Phase 3) |
| Quality | Grafana | 중복/이상 건수 Stat 패널 |

**Grafana 대시보드 파일**: `grafana/dashboards/knowledge.json` (Phase 3)

---

### 10.6 거래 지원 — Market data `[Grafana]` `[Phase 2-0]`

Grafana 대시보드. 버튼 없음. 수집 종목 변경은 Policy 탭(config.yaml) 경유.

| 패널 | Grafana 패널 타입 | SQL 소스 |
|------|-----------------|---------|
| KIS WS 연결 상태 | Stat | `/api/health` 파생 |
| 활성 종목 수 | Stat | `SELECT COUNT(DISTINCT symbol) FROM market_ohlcv WHERE ts > NOW()-INTERVAL '5m'` |
| 오늘 수집 봉 수 | Stat | `SELECT COUNT(*) FROM market_ohlcv WHERE DATE(ts)=today` |
| 마지막 수집 시각 | Stat | `SELECT MAX(ts) FROM market_ohlcv` |
| OHLCV 미리보기 | Table | `SELECT symbol,ts,open,high,low,close,volume FROM market_ohlcv ORDER BY ts DESC LIMIT 20` |
| 저장 지연 | Stat | `MAX(ts) vs NOW()` diff |

**Grafana 대시보드 파일**: `grafana/dashboards/market_data.json`

---

### 10.7 감시 횡단 — Health `[Grafana]` + `[Telegram]` `[Phase 2-0]`

읽기 부분은 Grafana. 긴급 제어(HALT/KILL)는 Telegram 명령으로 대체 — 화면에 버튼 없음.

| 패널 | 도구 | 내용 |
|------|------|------|
| Safeguards 4개 상태 | Grafana Stat | `/api/health` JSON → Grafana JSON datasource |
| 노드 파이프라인 13개 | Grafana Stat | `/api/status` |
| 계좌 일관성 | Grafana Table | `SELECT * FROM audit_events WHERE type='account_reconcile' ORDER BY occurred_at DESC LIMIT 5` |
| 감사 로그 | Grafana Table | `SELECT occurred_at, severity, message FROM audit_events ORDER BY occurred_at DESC LIMIT 30` |

```
긴급 제어:
  Telegram /halt    → POST /api/control/halt (Bot 경유)
  Telegram /kill    → POST /api/control/stop (Bot 경유)
  (화면 버튼 없음 — Telegram이 유일한 긴급 제어 채널)
```

**Grafana 대시보드 파일**: `grafana/dashboards/health.json`

---

### 10.8 감시 횡단 — System `[Grafana]` `[Phase 2-0]`

전부 Grafana. 버튼 없음. Scheduler 설정 변경은 config.yaml(Policy) 경유.

| 패널 | Grafana 패널 타입 | 소스 |
|------|-----------------|------|
| EventBus 처리량 | TimeSeries | Redis INFO + Prometheus exporter |
| EventBus 적체 | Stat | Redis Streams XLEN |
| PostgreSQL 연결 | Stat | Grafana PostgreSQL datasource health |
| Redis 연결 | Stat | Redis Prometheus exporter |
| Docker 컨테이너 | Table | Cadvisor + Prometheus |
| Scheduler 현황 | Table | `SELECT job_id, next_run, last_run FROM scheduler_log` (Phase 2) |
| 6개 공유 저장소 상태 | Stat × 6 | 각 테이블 COUNT + 최신 ts |
| 디스크/메모리 | Gauge | Node exporter |

**Grafana 대시보드 파일**: `grafana/dashboards/system.json`
**추가 docker-compose 서비스**: `prometheus`, `grafana`, `cadvisor`, `redis-exporter`

---

### 10.9 감시 횡단 — Notify `[HTML]` `[Phase 2-0]`

HTML 파일: `atlas/api/static/notify.html`
알림 이력 조회는 Grafana 패널로.

```
┌─────────────────────────────────────────┐
│ 감시 > Notify                           │
├─────────────────────────────────────────┤
│ 채널 상태 (읽기 전용 — Grafana 임베드)    │
│  Telegram  CONNECTED ●                  │
│  Discord   CONNECTED ●                  │
├─────────────────────────────────────────┤
│ 채널 설정 (폼 — HTML)                    │
│  체결 알림      [ON ◉] [OFF ○]          │
│  에러 알림      [ON ◉] [OFF ○]          │
│  일일 리포트    [15:50]                  │
│  승인 요청 채널 [Telegram ▼]             │
│                                         │
│  [Save] ← POST /api/config (notify 섹션)│
├─────────────────────────────────────────┤
│ 알림 이력 (Grafana iframe 임베드)         │
│  SELECT occurred_at, message            │
│  FROM audit_events WHERE type='notify'  │
└─────────────────────────────────────────┘
```

---

### 10.10 감시 횡단 — Rules `[HTML]` + `[Telegram]` `[Phase 2-0]`

HTML 파일: `atlas/api/static/rules.html`
승인 실행은 Telegram `/approve {id}` 명령이 주. HTML은 조회 + 보조.

```
┌─────────────────────────────────────────┐
│ 감시 > Rules                            │
├─────────────────────────────────────────┤
│ 승인 대기 (ApprovalGate)                 │
│  대기 없음 (현재)                         │
│  ← GET /api/approvals/pending           │
│                                         │
│  승인은 Telegram /approve {id} 우선      │
│  [승인] [거절] 버튼은 보조 수단            │
│  ← POST /api/approvals/{id}/approve     │
├─────────────────────────────────────────┤
│ Watchdog 규칙 목록                       │
│  ┌─────────────────────────────────┐    │
│  │ 일일 손실 한도  max_daily_loss>3% │    │
│  │ → HALT                          │    │
│  └─────────────────────────────────┘    │
│  ┌─────────────────────────────────┐    │
│  │ 연속 거절  rejected>5/60s        │    │
│  │ → PAUSE                         │    │
│  └─────────────────────────────────┘    │
│  [+ 규칙 추가]  [규칙 테스트]            │
│  ← POST /api/rules                      │
├─────────────────────────────────────────┤
│ 승인 이력 (Grafana iframe 임베드)         │
└─────────────────────────────────────────┘
```

---

### 10.11 구현 도구 전체 요약

| 화면 | 도구 | Phase | 버튼 여부 |
|------|------|-------|----------|
| Overview | Grafana | 2-0 | 없음 |
| P1 Trading Monitor | Grafana | 2-0 | 없음 |
| P1 Trading Control | HTML + Telegram | 2-0 | 있음 (HALT/Resume/Stop) |
| P1 Trading Policy | HTML | 2-0 | 있음 (Save) |
| P1 Trading Test | HTML | 2-0 | 있음 (Run) |
| P4 Portfolio | Grafana | 2B | 없음 |
| Strategy Edit | HTML | 2-0 | 있음 (저장) |
| Strategy Backtest | HTML | 2-0 | 있음 (Run) |
| Strategy Optimize | HTML | 2A | 있음 (Run) |
| Strategy History | HTML | 2-0 | 있음 (복원) |
| Knowledge | Grafana + HTML | 3 | 최소 |
| Market data | Grafana | 2-0 | 없음 |
| Health | Grafana + Telegram | 2-0 | 없음 (Telegram 대체) |
| System | Grafana | 2-0 | 없음 |
| Notify | HTML + Grafana iframe | 2-0 | 있음 (Save) |
| Rules | HTML + Telegram | 2-0 | 있음 (보조) |
| 설계 4화면 | Phase 2+ 별도 | 2+ | — |

**Grafana 대시보드 파일 목록**
```
grafana/dashboards/
├── overview.json
├── p1_monitor.json
├── portfolio.json
├── market_data.json
├── health.json
├── system.json
└── knowledge.json   (Phase 3)
```

**HTML 파일 목록**
```
atlas/api/static/
├── index.html       ← 메인 레이아웃 (Grafana iframe + 제어 링크)
├── control.html     ← HALT/Resume/Stop
├── policy.html      ← config.yaml 편집 폼
├── strategy.html    ← 전략 편집 + Backtest + History
├── optimize.html    ← Grid Search (Phase 2A)
├── notify.html      ← 채널 설정
└── rules.html       ← 규칙 목록 + 승인 보조
```

---

### 10.12 Phase 1 ↔ CLI 전체 매핑

| 화면 영역 | Phase 1 CLI | Phase 2 API |
|----------|------------|-------------|
| Overview KPI | `atlas status` / `atlas pnl` / `atlas positions` | `GET /api/status`, `/api/pnl`, `/api/positions` |
| Overview 체결 | `atlas orders` | `GET /api/orders` |
| P1 Monitor FSM | `atlas status` | `WS /ws/fsm` |
| P1 Monitor 주문 | `atlas orders` | `WS /ws/orders` |
| P1 Control HALT | `atlas halt` | `POST /api/control/halt` + Telegram `/halt` |
| P1 Control Resume | `atlas resume` | `POST /api/control/resume` |
| P1 Test Backtest | `atlas backtest <file>` | `POST /api/backtest` |
| P1 Policy 설정 | `config.yaml` 직접 편집 | `GET/POST /api/config` |
| Market data 상태 | `atlas status` | `GET /api/status` |
| Health Safeguards | `atlas status` | `GET /api/health` |
| Health 긴급 제어 | `atlas halt` | Telegram `/halt` (화면 버튼 없음) |
| Health 감사 로그 | `atlas audit` | `GET /api/audit` |
| Strategy 파일 | 직접 편집 | `GET/POST /api/strategies/{name}` |
| P4 Portfolio | — (Phase 2B) | `GET /api/positions` + `daily_pnl` |
| Knowledge | — (Phase 3) | — |
| System | — (Phase 2) | Grafana + Prometheus |
| Notify | — (Phase 2) | `POST /api/config` (notify 섹션) |
| Rules | — (Phase 2) | `GET/POST /api/approvals`, `/api/rules` |
| 설계 4화면 | — (Phase 2+) | — |

## 11. 다음 단계

- [x] v1 방향 D — 구조 .md로 고정
- [x] v1 방향 A — 공통 외곽 프레임 설계
- [x] v1 방향 B — 화면 간 전환 흐름
- [x] v1 방향 C Phase 1~2 — P1 Trading + 5 화면 큰 테두리
- [x] **v2 — 카테고리 재편 (3 + 횡단)**
- [x] **v2.3 — §10 전체 재작성 (구현 도구 기준)**
- [x] **v2.2 — §12 프론트엔드 기술스택 확정**
- [x] **v2.1 — 전체 14화면 내부 레이아웃**
- [x] **v2.2 — 프론트엔드 기술스택 확정 + FastAPI 레이어 설계**
- [ ] Phase 2-0 구현 — FastAPI 서버 + Grafana 패널 + HTML 제어 + Telegram Bot
- [ ] Phase 2A 진입 — Path 6 Market Intelligence

---

## 12. 프론트엔드 기술스택 확정 (v2.2)

> 결정일: 2026-04-17
> 기준: 프론트엔드 경험 최소 + 백엔드 중심 + React 전환 경로 확보

### 12.1 전략: A+B 조합

| 구분 | 도구 | 역할 | 한계 |
|------|------|------|------|
| A | Telegram Bot | 긴급 제어 + 승인 (모바일) | 복잡한 폼 불가 |
| B-읽기 | Grafana | 모니터링/차트/수치 시각화 | 버튼 없음 |
| B-쓰기 | HTML + FastAPI | 제어/설정 화면 (버튼, 폼) | React보다 단순 |

### 12.2 화면별 구현 도구

| 화면 | 도구 | 이유 |
|------|------|------|
| Overview KPI/차트 | Grafana | 읽기 전용, SQL 직결 |
| P1 Trading Monitor (차트) | Grafana | OHLCV 시계열 |
| P1 Trading Control | HTML (버튼) + Telegram | HALT/Resume/Stop |
| P1 Trading Policy | HTML (폼) | config 편집 |
| P4 Portfolio 성과 | Grafana | 차트/수치 |
| Strategy Edit/Backtest | HTML (편집기/폼) | 파일 R/W + 실행 |
| Knowledge | Grafana (현황) | Phase 3까지 최소 |
| Market data | Grafana | 수집 현황 |
| Health | Grafana + HTML | Safeguards 표시 + HALT 버튼 |
| System | Grafana | EventBus/Docker/Scheduler |
| Notify | HTML (설정폼) | 채널 ON/OFF |
| Rules | HTML (승인버튼) + Telegram | ApprovalGate |
| 설계 4화면 | Phase 2+ 별도 | LiteGraph.js 등 |

### 12.3 FastAPI 엔드포인트 요약

```
읽기 (GET)
  /api/status  /api/health  /api/audit
  /api/positions  /api/pnl  /api/orders  /api/orders/live
  /api/config  /api/strategies  /api/strategies/{name}
  /api/backtest/{job_id}

쓰기 (POST)
  /api/control/halt  /api/control/resume  /api/control/stop
  /api/config  /api/strategies/{name}  /api/backtest

실시간 (WebSocket)
  /ws/fsm      ← FSM 상태 변화 push
  /ws/orders   ← 체결/거절 이벤트 push

합계: REST 14 + WS 2 = 16 엔드포인트
```

### 12.4 React 전환 경로

```
Phase 2-0 (지금)          Phase 2+ (필요 시)
─────────────────         ─────────────────
FastAPI API   ──────────▶ FastAPI API (무변경)
WebSocket     ──────────▶ WebSocket (무변경)
Grafana 패널  ──────────▶ React 차트 컴포넌트
HTML static/  ──────────▶ React build 결과물

전환 비용: 프론트엔드만 교체. 백엔드 재설계 없음.
전환 조건: Grafana+HTML 안정화 후 React 학습 or Claude Code 활용
```

### 12.5 핵심 규칙

```
1. HTML 로직 금지 — fetch()/WebSocket 호출과 표시만
2. 모든 API 응답 JSON — HTML/React 동일 재사용
3. 제어는 control_file.py 경유 — CLI와 동일 경로
4. 긴급 제어는 Telegram 우선 — 폰에서 /halt가 가장 빠름
```

---

## 10. 화면 내부 레이아웃 (v2 기준 전체)

> 최종 수정: 2026-04-17 (v2.1)
> 기준: 3카테고리 + 횡단 감시 (v2), 14화면 전수

---

### 10.1 거래 — Overview

**영역 구조 (4영역)**

| 영역 | 위치 | 내용 | Phase 1 |
|------|------|------|---------|
| KPI 카드 4개 | 상단 | 일간 P&L / 보유 포지션 / 오늘 체결 / 누적 수익률+Sharpe | `atlas pnl` + `atlas positions` |
| 포지션 현황 | 중좌 | 종목·수량·평균단가·손익 테이블 | `atlas positions` |
| 전략별 성과 | 중우 | 전략별 수익률 바 차트 | `atlas pnl` 파생 |
| 체결 내역 | 하단 | 시각·종목·방향·수량·가격·전략 테이블 (실시간) | `atlas orders` |

**v1 대비 변경**: Safeguards 4개 상태 → Header 띠로 이동. Kill switch → Health 화면으로 이동. "전체 KPI" → "거래 KPI"로 범위 축소.

---

### 10.2 거래 — P1 Trading

#### Monitor 탭

| 영역 | 위치 | 내용 | Phase 1 |
|------|------|------|---------|
| FSM 상태 + 노드 파이프라인 | 좌 | 종목별 FSM 상태 / DataIngest→SignalFusion→OrderGate→ExecEngine 점 상태 | `atlas status` |
| 실시간 차트 | 우 | 1분봉 + MA5/MA20. 종목 클릭 전환 | Phase 2 (Grafana) |
| 주문 로그 | 하단 | 시각·종목·방향·수량·가격·상태·사유 (실시간) | `atlas orders` |

#### Control 탭

| 영역 | 내용 | Phase 1 |
|------|------|---------|
| 시스템 제어 | HALT / Resume 버튼. AUTO ↔ MANUAL 모드 전환 | `atlas halt` / `atlas resume` |
| 포지션 조치 | 종목별 손절·청산. 전 포지션 청산 (더블 확인) | Phase 2 |
| 조치 이력 | 최근 제어 명령 이력 | PG audit_events |

#### Policy 탭

| 영역 | 내용 | Phase 1 |
|------|------|---------|
| 활성 전략 | 활성화된 전략 목록 | `config.yaml` |
| 리스크 파라미터 | max_cash_usage / max_position_pct / max_daily_loss / max_daily_trades / trading_hours / circuit_breaker | `config.yaml` |
| Watchlist | 수집·거래 종목 관리 | `watchlist.yaml` |
| Save | Validator + 4-layer 승인 + Audit 3 게이트 | Phase 2 |

#### Test 탭

| 영역 | 내용 | Phase 1 |
|------|------|---------|
| Backtest 실행 | 전략 선택 / 기간 / 초기 자본 | `atlas backtest <file>` |
| 성과 지표 | Sharpe / Return / MDD / Win Rate / Trades | CLI 출력 |
| Equity Curve | 자산 곡선 차트 | Phase 2 |

---

### 10.3 거래 — P4 Portfolio

| 영역 | 내용 | Phase 1 |
|------|------|---------|
| 포트폴리오 요약 | 총 자산 / 누적 수익률 / Sharpe | RiskGuard 간이 대체 |
| 종목별 비중 | 비중 바 차트 | Phase 2 |
| 전략별 성과 | 수익률 / MDD / HHI | Phase 2 |
| 리밸런싱 | 다음 실행 시각 + 실행 버튼 | Phase 2 |

---

### 10.4 거래 지원 — Strategy

#### Edit 탭

| 영역 | 위치 | 내용 |
|------|------|------|
| 전략 목록 | 좌 | strategies/*.py 목록. 선택 시 우측 편집기 로드. [+ 새 전략] |
| 코드 편집기 | 우상 | .py 소스 코드 편집. [저장] [→ Backtest 실행] 버튼 |
| 파라미터 | 우하 | fast_period / slow_period / entry_threshold / stop_loss_pct 등 |

#### Backtest 탭

| 영역 | 내용 |
|------|------|
| 실행 설정 | 전략 선택 / 기간 / 초기 자본 / 종목 |
| 성과 지표 | Sharpe / Return / MDD / Win Rate / Trades |
| Equity Curve | Phase 2. Phase 1은 수치만 |
| 연결 버튼 | [→ Edit 수정] [→ Optimize] |

#### Optimize 탭

| 영역 | 내용 |
|------|------|
| 파라미터 범위 | 각 파라미터 min/max/step 설정. 조합 수 표시 |
| Grid Search | [▶ Run Grid Search] 실행 |
| 최적 파라미터 Top 3 | Sharpe 기준 정렬 |
| Walk-Forward | 과적합 지수 표시 |
| 적용 버튼 | [#1 적용 → Edit] |

#### History 탭

| 영역 | 내용 |
|------|------|
| 전략별 버전 이력 | 각 전략의 v1.0/v0.9… 목록 |
| 버전 상세 | 선택 시 작성일 / Sharpe / 변경 내용 |
| 복원 버튼 | [이 버전으로 복원] |

---

### 10.5 거래 지원 — Knowledge

**서브탭 3개**: Build / Explore / Quality

| 서브탭 | 내용 | Phase |
|--------|------|-------|
| Build | 수집 소스(DART, 뉴스) / 수집 주기 / 파이프라인 상태 (마지막 실행 시각) | Phase 3 |
| Explore | 온톨로지 노드·엣지 수 / 지식 검색 / 인과 추론 결과 | Phase 3 |
| Quality | 중복 건수 / 이상 엔티티 목록 / 정제 실행 | Phase 3 |

---

### 10.6 거래 지원 — Market data

| 영역 | 내용 | Phase 1 |
|------|------|---------|
| 수집 상태 | KIS WS 연결 / KIS REST / 활성 종목 수 | `atlas status` |
| 수집 현황 | 오늘 수집 봉 수 / 마지막 수집 시각 / 저장 지연 | `atlas status` |
| OHLCV 미리보기 | 종목별 최신 가격 테이블 | `atlas status` |
| 수집 설정 | 종목 추가/제거 / 분봉 간격 / 일봉 수집 시각 | `config.yaml` |

---

### 10.7 감시 횡단 — Health

| 영역 | 내용 | Phase 1 |
|------|------|---------|
| Four Critical Safeguards | 중복주문방지·상태계좌일관성·이벤트내구성·명령제어보안 — 각 상태 점 | `atlas status` |
| 긴급 제어 | ⏸ HALT / ⛔ KILL ALL (더블 확인) | `atlas halt` |
| 노드 상태 맵 | 13개 인터페이스 노드 전체 헬스 점 | Phase 2 |
| 계좌 일관성 | 마지막 검증 시각 / DB 포지션 / KIS 잔고 / 미체결 주문 | 5분 자동 검증 |
| 감사 로그 | 최근 이벤트 이력 | PG audit_events |

**v1 W1 대비 변경**: Anomaly 통합 뷰 → Safeguards 중심으로 재편. 노드 맵 13개로 확장.

---

### 10.8 감시 횡단 — System

| 영역 | 내용 |
|------|------|
| EventBus 상태 | 처리량(events/min) / 적체 / dead letter / Redis Streams 연결 / 마지막 이벤트 |
| 저장소 연결 | PostgreSQL / TimescaleDB / Redis 연결 상태 / 디스크·메모리 사용량 |
| Docker 컨테이너 | atlas-core / postgres / redis / grafana 상태 + 기동 시각 |
| Scheduler | 계좌 검증(5분) / OHLCV 수집(1분) / 일봉 수집(15:35) / P&L 집계(15:45) 현황 |
| 6개 공유 저장소 | TimeSeries / Knowledge Graph / Strategy Registry / Position State / Event Log / Config 전체 상태 |

**신규 화면 (v1에 없음)**: v1 Operating Infra > System에서 독립. EventBus 가시성 + 저장소 통합.

---

### 10.9 감시 횡단 — Notify

| 영역 | 내용 |
|------|------|
| 채널 상태 | Telegram / Discord 연결 상태 / 마지막 발송 시각 |
| 알림 이력 | 체결·에러·검증 완료·시스템 시작 이력 (타임라인) |
| 채널 설정 | 체결 알림 ON/OFF / 에러 알림 / 일일 리포트 시각 / 승인 요청 채널 |

**신규 화면 (v1에 없음)**: v1 Operator.Notifier가 화면으로 독립.

---

### 10.10 감시 횡단 — Rules

| 영역 | 내용 |
|------|------|
| 승인 대기 (ApprovalGate) | 현재 승인 대기 목록 / 승인·거절 버튼 |
| 승인 이력 | 과거 승인·거절 이력 |
| Watchdog 규칙 | 규칙 목록 (조건 → 액션). 예: max_daily_loss > 3% → HALT |
| 규칙 관리 | [+ 규칙 추가] [규칙 테스트] |

**v1 W2+W3 대비 변경**: Rule Editor + Rule Test → Rules 단일 화면으로 통합. ApprovalGate 흡수.

---

### 10.11 Phase 1 ↔ CLI 전체 매핑 (v2 기준)

| 화면 | CLI 명령 | Phase |
|------|---------|-------|
| Overview KPI 전체 | `atlas status` | 1 |
| Overview 포지션 | `atlas positions` | 1 |
| Overview P&L | `atlas pnl` | 1 |
| Overview 체결 | `atlas orders` | 1 |
| P1 Monitor FSM | `atlas status` | 1 |
| P1 Monitor 주문 로그 | `atlas orders` | 1 |
| P1 Control HALT | `atlas halt` | 1 |
| P1 Control Resume | `atlas resume` | 1 |
| P1 Test Backtest | `atlas backtest <file>` | 1 |
| P1 Policy 설정 | `atlas config show` | 1 |
| Market data 상태 | `atlas status` | 1 |
| Health Safeguards | `atlas status` | 1 |
| Health HALT | `atlas halt` | 1 |
| Health 감사 로그 | `atlas audit` | 1 |
| P4 Portfolio | — | 2 (RiskGuard 간이 대체) |
| Strategy 전체 | — | 2 (Edit), 2 (Backtest/Optimize/History) |
| Knowledge 전체 | — | 3 |
| System 전체 | `atlas status` 일부 | 2 |
| Notify 전체 | — | 2 |
| Rules 전체 | — | 2 |
| 설계 4화면 전체 | — | 2+ |


---

## 13. Phase별 화면 구현 가이드 (v2.4 신규)

> 어떤 Phase에서 무엇을 만들고, 어떤 도구로 만드는지 전체 로드맵.

---

### 13.1 Phase 1 — CLI 전용, 화면 없음

| 화면 역할 | CLI 명령 | 비고 |
|----------|---------|------|
| Overview | `atlas status` / `atlas pnl` / `atlas positions` | — |
| P1 Monitor | `atlas status` / `atlas orders` | — |
| P1 Control | `atlas halt` / `atlas resume` / `atlas stop` | — |
| P1 Backtest | `atlas backtest <file>` | — |
| Health / Market data | `atlas status` | — |
| 감사 로그 | `atlas audit` | — |

합격 기준 5개 통과 → **Phase 2-0 진입**.

---

### 13.2 Phase 2-0 — UI 인프라 구축 (순서대로)

**순서**: ① FastAPI → ② Grafana 패널 → ③ HTML 제어화면 → ④ Telegram Bot

#### ① FastAPI 서버 (`atlas/api/`)

```
atlas/api/
├── main.py               ← FastAPI app, uvicorn 포트 8000
├── dependencies.py       ← DB 세션, 설정 의존성
├── routers/
│   ├── status.py         ← GET /api/status · /api/health · /api/audit
│   ├── trading.py        ← GET /api/positions · /api/pnl · /api/orders
│   ├── control.py        ← POST /api/control/halt|resume|stop
│   ├── config.py         ← GET/POST /api/config
│   ├── strategies.py     ← GET/POST /api/strategies/{name}
│   ├── backtest.py       ← POST /api/backtest  GET /api/backtest/{id}
│   ├── approvals.py      ← GET/POST /api/approvals/{id}/approve|reject
│   └── rules.py          ← GET/POST /api/rules
├── websockets/
│   ├── fsm_stream.py     ← WS /ws/fsm   — FSMState 변화 push
│   └── orders_stream.py  ← WS /ws/orders — 체결/거절 이벤트 push
└── static/               ← HTML 제어 화면 (React 전환 전)
    ├── index.html         ← 메인 레이아웃
    ├── control.html       ← HALT / Resume / Stop 버튼
    ├── policy.html        ← config.yaml 편집 폼
    ├── strategy.html      ← 전략 편집 + Backtest + History
    ├── notify.html        ← 채널 설정 ON/OFF
    └── rules.html         ← 규칙 목록 + 승인 보조
```

**3원칙**:
- HTML은 `fetch()` / `WebSocket` 호출과 표시만. 로직 없음.
- 제어 명령은 `control_file.py` 경유 — CLI와 동일 경로.
- 모든 응답 JSON — HTML/React 동일 엔드포인트 재사용.

#### ② Grafana 대시보드 (`grafana/dashboards/`)

| 파일 | 담당 화면 | 데이터 소스 |
|------|---------|-----------|
| `overview.json` | Overview KPI·포지션·체결·전략성과 | PostgreSQL |
| `p1_monitor.json` | P1 Monitor FSM·OHLCV·주문로그 | PostgreSQL + TimescaleDB |
| `market_data.json` | Market data 수집상태·OHLCV미리보기 | PostgreSQL |
| `health.json` | Health Safeguards·계좌일관성·감사로그 | PostgreSQL |
| `system.json` | System EventBus·Docker·Scheduler·저장소 | PostgreSQL + Prometheus |

**docker-compose 추가**: `grafana`, `prometheus`, `cadvisor`, `redis-exporter`

#### ③ HTML 제어 화면 구현 원칙

```
control.html:  HALT/Resume/Stop → POST /api/control/*
policy.html:   config 폼 → GET/POST /api/config
strategy.html: 파일 편집 → GET/POST /api/strategies/{name}
               백테스트 → POST /api/backtest
notify.html:   채널 설정 → POST /api/config (notify 섹션)
rules.html:    승인 목록 → GET /api/approvals/pending
               승인/거절 → POST /api/approvals/{id}/approve|reject
```

#### ④ Telegram Bot (`atlas/adapters/telegram/bot.py`)

| 명령 | 동작 | 우선순위 |
|------|------|---------|
| `/halt` | `POST /api/control/halt` | **긴급 제어 1순위** |
| `/resume` | `POST /api/control/resume` | — |
| `/stop` | `POST /api/control/stop` | — |
| `/status` | `GET /api/status` 응답 | — |
| `/positions` | `GET /api/positions` 응답 | — |
| `/pnl` | `GET /api/pnl` 응답 | — |
| `/approve {id}` | `POST /api/approvals/{id}/approve` | ApprovalGate |
| `/reject {id}` | `POST /api/approvals/{id}/reject` | ApprovalGate |

push 알림: 체결 / 에러(error+critical) / 일일 리포트(15:50)

#### Phase 2-0 완료 기준

| 항목 | 확인 방법 |
|------|---------|
| FastAPI 기동 | `curl http://localhost:8000/api/status` 200 응답 |
| Grafana 패널 5개 | 브라우저 접속 + 데이터 표시 |
| HTML 제어 화면 | HALT 버튼 클릭 → `atlas status` 확인 |
| Telegram Bot | `/status` 명령 응답 + 체결 알림 수신 |
| WS 스트림 | FSM 상태 변화 실시간 수신 |

---

### 13.3 Phase 2A~2D — 기능 확장

| Phase | 추가 항목 | 화면 변화 |
|-------|---------|---------|
| 2A | Path 6 Market Intelligence | Market data 화면 강화 (수급/호가/VI) |
| 2B | Path 4 Portfolio | P4 Portfolio Grafana 대시보드 완성 |
| 2C | Screener + WatchlistManager | Market data 화면에 종목 선정 UI 추가 |
| 2D | 실전 전환 | Health 화면 LIVE 환경 경고 강화 |

---

### 13.4 React 전환 (선택적, 시기 미정)

```
전환 방법:
  1. React 프로젝트 생성 (Vite + TypeScript 권장)
  2. FastAPI API 그대로 사용 — 백엔드 무변경
  3. atlas/api/static/ → React build 결과물로 교체
  4. Grafana 패널 중 인터랙션 필요한 것만 순차 React 교체

전환 비용:
  - 백엔드 재설계 없음
  - Grafana → React 차트 컴포넌트 교체
  - HTML 파일 → React 컴포넌트 재작성

전환 조건:
  - Grafana + HTML 운영 안정화 완료
  - React 학습 완료 또는 Claude Code 활용 결정
```
