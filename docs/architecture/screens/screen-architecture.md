# ATLAS Screen Architecture v2

> 상태: confirmed
> 레이아웃: v2.1 (전체 14화면 내부 레이아웃 추가)
> 최종 수정: 2026-04-17 (v2.1)
> 변경 사유: 4 카테고리 → 3 카테고리 + 횡단 감시. Path 쌍 기반 재분류.

---

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

### 5.1 Header (상단 고정)

```
┌──────────────────────────────────────────────────────────────────┐
│ [ATLAS]  [LIVE ▾]     [감시 띠: ● ● ● ●]     [⏸ HALT]  [설정] │
└──────────────────────────────────────────────────────────────────┘
```

- ATLAS 로고 → 현재 카테고리 홈
- 환경 표시 (LIVE/PAPER/SIM) — 색상으로 구분
- 감시 띠 — Safeguards 4개 상태 표시. 클릭 → 감시 상세 진입
- HALT 버튼 — 전체 거래 중지. 항상 1-click
- 설정 — 사용자 설정, 테마

### 5.2 Sidebar (좌측)

```
┌────────────┐
│ ◆ 거래      │ ← 1-click 카테고리
│   Overview  │
│   Trading   │
│   Portfolio │
│            │
│ ◆ 거래 지원  │
│   Strategy  │
│   Knowledge │
│   Mkt data  │
│            │
│ ◆ 설계      │
│   Canvas    │
│   CodeGen   │
│   Validator │
│   Docs      │
└────────────┘
```

감시는 Sidebar에 없음 — Header 띠에서 접근.

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

## 6. 공통 설계 원칙 (v1에서 유지, 일부 수정)

1. **대기 없음 / 즉시 표시** — 스피너 대신 점진적 채움. 연결은 백그라운드.
2. **시스템이 다음 단계 제시** — 카테고리 횡단 시 자동 제안.
3. **3 게이트 보안** — 정책 변경은 Validator + 4-layer 승인 + Audit 통과 필수.
4. **컨텍스트 전달 = URL 파라미터** — 화면 간 이동 시 `?entity=X`로 대상 자동 세팅.
5. **감시는 항상 위에서** — Header 띠로 1-click 비상 접근. 어느 화면이든.
6. **거래 지원 참조 = 사이드 노트** — Knowledge 조회 결과를 거래 화면에 일시 패널로 표시.

---

## 7. 카테고리 간 이동 규칙

| 횡단 방향 | 성격 | UX 장치 |
|-----------|------|---------|
| 거래 ↔ 거래 | 내부 이동 | Sidebar 클릭 또는 Overview 카드 |
| 거래 → 감시 | 비상 확인 | Header 감시 띠 클릭 |
| 거래 → 거래 지원 | 참조 | 카드의 🔍 아이콘 (사이드 노트) 또는 Sidebar |
| 거래 지원 → 거래 | 전략 적용 | 전략 활성화 후 자동 제안 toast |
| 설계 → 거래/거래 지원 | 배포 | Code Generator 완료 후 자동 제안 toast |
| → 설계 | 수동만 | Sidebar 통해 수동 이동. 자동 트리거 없음. |

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
- [ ] v2 방향 C — 나머지 화면 큰 테두리 (Overview, P4 Portfolio, Strategy 통합, Knowledge, 감시 4화면)
- [ ] v2 방향 C — 설계 카테고리 4화면 상세
- [ ] Phase 매핑 — 각 화면의 구현 Phase 명시

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

