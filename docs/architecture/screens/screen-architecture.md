# ATLAS Screen Architecture

> 상태: draft v1.3
> 최종 수정: 2026-04-17
> 목적: 전체 화면 구조의 고정점(anchor). 외곽 프레임·흐름·세부 디자인은 이 문서를 기준으로 작업.

---

## 1. 본질 — 4 최상위 카테고리

ATLAS 콘솔은 4개의 최상위 카테고리로 구성된다.

```
ATLAS Console
│
├── 🔍 Watchdog       ← 메타 감시 (모든 카테고리 위)
├── 🎨 Design         ← 시스템 자체를 만드는 일
├── 🌐 Ontology       ← 독립 지식 자산
└── ⚡ Operating      ← 설계의 결과물을 돌리는 일
```

### 경계 판정 기준

| 질문 | Watchdog | Design | Ontology | Operating |
|------|----------|--------|----------|-----------|
| 실시간 데이터를 다루는가? | 감시만 | ❌ | ❌ | ✅ 핵심 |
| 사용자가 '만드는' 행위인가? | ❌ | ✅ 핵심 | 구축만 | ❌ |
| 독립 자산으로 축적되는가? | 로그만 | ❌ | ✅ 핵심 | ❌ |
| 시스템이 꺼져도 의미 있는가? | 로그 | 설계도 | ✅ 지식 | ❌ |
| 모든 카테고리를 감시하는가? | ✅ 핵심 | ❌ | ❌ | ❌ |

### 인과 관계

```
Design → Code Generator → Operating
Ontology ← Build ← 외부 데이터
Ontology → Consume → Operating (트레이딩 결정 보조)
                   → Design (전략 설계 보조)
Watchdog → 모든 카테고리 감시 → 이상 시 Master pause/kill
```

---

## 2. 화면 목록 — 17개

### 2.1 🔍 Watchdog (3개 + Header 띠)

| ID | 화면 | 역할 |
|----|------|------|
| W1 | Health Dashboard | 전 컴포넌트 헬스맵 + Anomaly 통합 |
| W2 | Rule Editor | 감시 룰 편집 |
| W3 | Rule Test | 룰 검증 (dry-run) |

### 2.2 🎨 Design (4개)

| ID | 화면 | 역할 |
|----|------|------|
| D1 | PathCanvas | Graph IR 시각 편집 (L2-L3 fold/unfold) + 실시간 Validator |
| D2 | Code Generator | IR → Python 코드 생성 + 최종 Validator |
| D3 | Strategy Editor | 전략 .py 코드 작성 |
| D4 | Docs Editor | 설계 문서 편집 (Git 자동 commit) |

### 2.3 🌐 Ontology (3개)

| ID | 화면 | 역할 |
|----|------|------|
| O1 | Schema | 온톨로지 노드/엣지 타입 정의 |
| O2 | Explore | 그래프 탐색/검색/인과추론 |
| O3 | Quality | 지식 품질 검증/정제 |

### 2.4 ⚡ Operating (7개)

| ID | 화면 | 역할 | 탭 구조 |
|----|------|------|---------|
| Op0 | Overview | 진입점. 헬스맵 + 손익 + 포지션 요약 | 없음 (단일) |
| Op1 | P1 Trading | 실시간 매매 | Monitor / Control / Policy / Test |
| Op2 | P4 Portfolio | 포트폴리오 관리 | Monitor / Control / Policy / Test |
| Op3 | Ontology Build | 지식 파이프라인 운영 | Monitor / Control / Policy / Test |
| Op4 | Market Data | 시세 수집 인프라 | Monitor / Control / Policy / Test |
| Op5 | Notify | 알림 채널 관리 | Monitor / Control / Policy / Test |
| Op6 | System | 시스템 인프라 | Monitor / Control / Policy / Test |

### 2.5 4탭 역할 (Operating Path/Infra 공통)

| 탭 | 성격 | 예시 |
|----|------|------|
| Monitor | 읽기 전용, 실시간 상태 | FSM 상태도, 체결 로그, 시세 차트 |
| Control | 즉시 실행 쓰기 | halt/resume, 수동 주문, 강제 청산 |
| Policy | 사전 정책 쓰기 | 리스크 한도, 스케줄, 파라미터 |
| Test | 검증 | 백테스트 실행, dry-run, 시뮬레이션 |

### 2.6 수치 요약

```
Watchdog:   3개 + Header 띠
Design:     4개
Ontology:   3개
Operating:  7개 (1 Overview + 6 Path/Infra × 4탭)
총 화면:    17개
```

---

## 3. 관계 — 데이터 흐름과 설계 원칙

### 3.1 5 Paths → 4 카테고리 재배치

| Path | 카테고리 | 근거 |
|------|----------|------|
| Path 1 Realtime Trading | Operating (Op1) | 실시간 매매 |
| Path 2 Knowledge Building | Ontology (O1-O3) + Operating (Op3) | 구축=Ontology, 운영=Operating |
| Path 3 Strategy Development | Design (D1-D4) | 만들기 |
| Path 4 Portfolio Management | Operating (Op2) | 돌리기 |
| Path 5 Watchdog & Operations | Watchdog (W1-W3) | 감시 |
| Path 6 Market Intelligence | Operating (Op4) | 인프라 |

### 3.2 5개 설계 원칙

1. **데이터의 시간성 = 카테고리** — 실시간→Operating, 자산→Ontology, 만들기→Design, 항상→Watchdog
2. **마우스 동선 = 사용 빈도** — Master 버튼 1-click, Overview 진입점, Path 탭 1-click, 드문 작업 2-click
3. **일관성 = 학습 비용 감소** — Operating 7화면 모두 4탭 통일
4. **읽기와 쓰기를 분리한다** — Monitor↔Control 탭 분리로 실수 방지
5. **Code Generator가 Design과 Operating을 잇는다** — 설계의 산출물이 운영의 입력이 되는 유일한 게이트

### 3.3 Global Header 띠

어느 화면에 있든 항상 표시:

```
[≡] Logo · Env(LIVE/PAPER/SIM) · Clock · Safeguards 🟢🟢🟢🟢 · [Pause] [Reconcile] [Kill]
```

- 환경 Pill: LIVE=red, PAPER=amber, SIM=gray
- Safeguards: 이상 시 해당 점 빨간색 점멸
- Master 버튼 3개: 모든 카테고리에서 즉시 접근

---

## 4. 외곽 프레임 (방향 A)

### 4.1 전체 레이아웃

```
┌──────────────────────────────────────────────────────────────┐
│ [≡] ATLAS · [PAPER ◆] · 09:15:32 KST · ●●●● · [⏸][🔄][🛑] │  ← Header (48px)
├────────┬─────────────────────────────────────────────────────┤
│        │                                                     │
│  🔍    │                                                     │
│  W1    │                                                     │
│  W2    │              Workspace                              │
│  W3    │              (화면 본문)                              │
│  ──    │                                                     │
│  🎨    │                                                     │
│  D1~D4 │                                                     │
│  ──    │                                                     │
│  🌐    │                                                     │
│  O1~O3 │                                                     │
│  ──    │                                                     │
│  ⚡    │                                                     │
│  Op0~6 │                                                     │
│        │                                                     │
├────────┴─────────────────────────────────────────────────────┤
│ WS: ● connected · Build: v0.1.0 · Last save: 2s ago         │  ← Footer (24px)
└──────────────────────────────────────────────────────────────┘
         ↑
    Sidebar (200px, collapsible → 48px 아이콘)
```

### 4.2 결정 사항 (A-1 ~ A-4)

| ID | 결정 | 내용 |
|----|------|------|
| A-1 | Sidebar 방식 | 4 카테고리 아코디언. 활성 카테고리만 화면 목록 펼침 |
| A-2 | 카테고리 전환 | Sidebar 카테고리 아이콘 클릭. 전환 시 해당 카테고리 첫 화면 자동 진입 |
| A-3 | 탭 표시 위치 | Workspace 상단 (화면 제목 아래). Operating Path/Infra만 |
| A-4 | Footer 정보 | WS 연결 상태 + 빌드 버전 + 마지막 저장 시각 |

---

## 5. 화면 전환 흐름 (방향 B)

### 5.1 7가지 핵심 시나리오

| # | 시나리오 | 진입 | 경로 | 종착 |
|---|---------|------|------|------|
| 1 | 아침 점검 | Op0 Overview | Health map 확인 → 빨간 카드 클릭 | Op1 Trading Monitor |
| 2 | 비상 대응 | 어디든 | Header ●빨강 클릭 → W1 Health | 해당 Path Control 탭 |
| 3 | 전략 배포 | D3 Strategy Editor | 저장 → D2 Code Generator → 검증 통과 | Op1 Trading Policy 탭 |
| 4 | 리스크 한도 변경 | Op1 Policy 탭 | 파라미터 수정 → Validator → Save | 동일 화면 (toast 확인) |
| 5 | 지식 참조 | Op1 Monitor 탭 | 종목 카드 🔍 클릭 → O2 Explore | 사이드 노트로 복귀 |
| 6 | 설계 변경 | D1 PathCanvas | 노드 추가/수정 → Validator 통과 → 저장 | Git commit 완료 |
| 7 | 시스템 시작 | 브라우저 열기 | 로딩 → 마지막 화면 복원 | 이전 세션 상태 |

### 5.2 4가지 전환 패턴

| 패턴 | 트리거 | 전환 방식 | 예시 |
|------|--------|----------|------|
| Click-Navigate | 사용자 의도적 클릭 | Sidebar 또는 카드 링크 | Op0 → Op1 |
| Alert-Jump | 시스템 이상 감지 | Header 점멸 → 1-click | 어디든 → W1 |
| Flow-Suggest | 작업 완료 후 자동 제안 | Toast + 링크 버튼 | D2 → Op1 (배포 후) |
| Context-Pass | 컨텍스트 전달 이동 | URL 파라미터 | Op1 → O2 (?symbol=005930) |

### 5.3 6가지 공통 설계 원칙

1. **대기 없음 / 즉시 표시** — 스피너 대신 점진적 채움. 연결은 백그라운드.
2. **시스템이 다음 단계 제시** — 카테고리 횡단 시 자동 제안.
3. **3 게이트 보안** — 정책 변경은 Validator + 4-layer 승인 + Audit 통과 필수.
4. **컨텍스트 전달 = URL 파라미터** — 화면 간 이동 시 `?entity=X`로 대상 자동 세팅.
5. **사이드 노트 = 일시 참조** — Ontology 참조 결과를 Operating에 일시 패널로 표시.
6. **Watchdog는 항상 위에서** — 어느 화면이든 Header 띠로 1-click 비상 접근.

### 5.4 카테고리 간 이동 규칙

| 횡단 방향 | 성격 | UX 장치 |
|-----------|------|---------|
| Operating ↔ Operating | 내부 이동 | Sidebar 클릭 또는 Overview Health map 카드 |
| Operating → Watchdog | 감시 상세 | Header Safeguards 점 또는 Sidebar 빨간 점 |
| Design → Operating | 배포 | Code Generator 통과 후 자동 제안 toast |
| Operating → Ontology | 참조 | 카드의 🔍 아이콘 클릭 (URL 컨텍스트 전달) |
| Ontology → Operating | 복귀 | 기본 복귀 또는 사이드 노트 담기 |
| → Design | 사용자 의도만 | Sidebar 통해 수동 이동 |

### 5.5 세션 컨텍스트 규칙

- **localStorage 유지**: 마지막 화면, Sidebar 상태, 탭 상태, UI 토글
- **세션 메모리만**: 사이드 노트, 작성 중 편집, Validator 진행 상태
- **저장 안 함 (매번 실시간)**: 환경(LIVE/PAPER/SIM), 4 Safeguards 상태

---

## 6. 화면 내부 레이아웃 (방향 C) — Operating 중심

> Phase 1 범위에서 실제 구현하는 UI는 CLI이지만, 향후 Phase 2에서 화면을 붙일 때 설계를 재작업하지 않도록 레이아웃을 미리 확정한다.
> 이 섹션은 **Phase 1과 직접 연관되는 Operating 카테고리 화면**만 다룬다.

### 6.1 Op0 — Operating Overview

시스템 진입 시 첫 화면. 전체 상태를 한 눈에 파악.

```
┌─────────────────────────────────────────────────────────────┐
│ Operating Overview                                          │
├───────────────────────────┬─────────────────────────────────┤
│                           │                                 │
│   Health Map              │   Today's P&L                   │
│   ┌─────┐ ┌─────┐        │   ┌─────────────────────────┐   │
│   │ P1  │ │ P4  │        │   │  +124,500 (+0.62%)      │   │
│   │ 🟢  │ │ 🟢  │        │   │  ~~~~~~~~~~~~ (차트)     │   │
│   └─────┘ └─────┘        │   └─────────────────────────┘   │
│   ┌─────┐ ┌─────┐        │                                 │
│   │ Mkt │ │ Sys │        │   Quick Stats                   │
│   │ 🟢  │ │ 🟡  │        │   포지션: 2 종목                 │
│   └─────┘ └─────┘        │   오늘 체결: 3건                 │
│                           │   미체결: 0건                    │
│   카드 클릭 → 해당 화면    │   FSM: IN_POSITION×2, IDLE×1   │
│                           │                                 │
├───────────────────────────┴─────────────────────────────────┤
│                                                             │
│   Positions Table                                           │
│   ┌─────────┬──────┬────────┬──────────┬────────┬────────┐  │
│   │ 종목    │ 수량  │ 평균가  │ 현재가    │ 손익   │ FSM   │  │
│   ├─────────┼──────┼────────┼──────────┼────────┼────────┤  │
│   │ 005930  │  10  │ 72,100 │ 72,350   │ +2,500│ IN_POS │  │
│   │ 000660  │   5  │ 185,000│ 184,200  │ -4,000│ IN_POS │  │
│   └─────────┴──────┴────────┴──────────┴────────┴────────┘  │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│   Recent Events (audit_events 최신 10건)                     │
│   09:15:32 [info]  order_filled 005930 BUY 10@72,100        │
│   09:15:30 [info]  risk_check_passed 005930                 │
│   09:15:28 [info]  signal_generated 005930 BUY              │
│   ...                                                       │
└─────────────────────────────────────────────────────────────┘
```

**영역 구조 (4영역)**:

| 영역 | 위치 | 크기 비율 | 데이터 소스 | 갱신 주기 |
|------|------|----------|-----------|----------|
| Health Map | 좌상 | 30% × 50% | 각 Path 노드 상태 | 30초 폴링 |
| P&L + Quick Stats | 우상 | 70% × 50% | daily_pnl + positions | 틱마다 (시세 연동) |
| Positions Table | 중앙 | 100% × 25% | positions + market_ohlcv | 틱마다 |
| Recent Events | 하단 | 100% × 25% | audit_events | 실시간 (append) |

**상호작용**:
- Health Map 카드 클릭 → 해당 Operating 화면으로 이동 (Click-Navigate)
- Positions 행 클릭 → Op1 Trading Monitor 탭으로 이동 (?symbol=XXX)
- Events 행 클릭 → correlation_id 기반 체인 추적 팝업

---

### 6.2 Op1 — P1 Trading

Phase 1의 핵심 운영 화면. 6노드(MDR/IC/SE/RG/OE/FSM)의 실시간 상태와 제어.

#### Monitor 탭

```
┌─────────────────────────────────────────────────────────────┐
│ P1 Trading > Monitor                                        │
├────────────────────────┬────────────────────────────────────┤
│                        │                                    │
│   FSM State Map        │   Live Chart                       │
│   ┌────────────────┐   │   ┌────────────────────────────┐   │
│   │ 005930: IN_POS │   │   │  005930 — 1분봉 + MA5/20  │   │
│   │ 000660: IN_POS │   │   │  ~~~~~~~~~~~~~~~~~~~~~~~~  │   │
│   │ 035720: IDLE   │   │   │  (candlestick + overlay)   │   │
│   └────────────────┘   │   └────────────────────────────┘   │
│                        │                                    │
│   Node Pipeline        │   종목 선택 시 차트 전환             │
│   MDR → IC → SE →      │                                    │
│   RG → OE → FSM        │                                    │
│   (각 노드 상태 점)      │                                    │
│                        │                                    │
├────────────────────────┴────────────────────────────────────┤
│                                                             │
│   Order Log (최신 주문 + 체결 실시간)                          │
│   ┌──────┬──────┬────┬──────┬──────┬────────┬────────────┐  │
│   │ 시각  │ 종목 │ 방향│ 수량  │ 가격 │ 상태   │ 사유       │  │
│   ├──────┼──────┼────┼──────┼──────┼────────┼────────────┤  │
│   │09:15 │005930│ BUY│  10  │72,100│ FILLED │ma5>ma20    │  │
│   │09:10 │035720│ BUY│   5  │45,000│REJECTED│cash_limit  │  │
│   └──────┴──────┴────┴──────┴──────┴────────┴────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**영역 구조 (4영역)**:

| 영역 | 위치 | 데이터 소스 | Phase 1 구현 |
|------|------|-----------|-------------|
| FSM State Map | 좌상 | positions.fsm_state | `atlas status` 대응 |
| Live Chart | 우상 | market_ohlcv + IndicatorCalculator | Phase 2 (Grafana) |
| Node Pipeline | 좌하 | 각 노드 heartbeat | Phase 2 |
| Order Log | 하단 | order_tracker + trades | `atlas orders` 대응 |

#### Control 탭

```
┌─────────────────────────────────────────────────────────────┐
│ P1 Trading > Control                                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   System Control          Manual Order (Phase 2 MANUAL)     │
│   ┌────────────────┐      ┌─────────────────────────────┐   │
│   │ [⏸ Halt]       │      │ 종목: [005930    ▼]         │   │
│   │ [▶ Resume]     │      │ 방향: [매수 ◉] [매도 ○]     │   │
│   │ [🛑 Stop]      │      │ 수량: [10      ]            │   │
│   └────────────────┘      │ 가격: [72,100  ] 시장가 □    │   │
│                            │ [주문 실행]                  │   │
│   Mode: AUTO ◉             └─────────────────────────────┘   │
│         MANUAL ○                                            │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│   Position Actions                                          │
│   005930 [손절 청산] [전량 청산]                               │
│   000660 [손절 청산] [전량 청산]                               │
│                                                             │
│   Master: [전 포지션 청산] ← Double Confirm                  │
└─────────────────────────────────────────────────────────────┘
```

**Phase 1 대응**: `atlas halt`, `atlas resume`, `atlas stop` CLI 명령이 이 탭의 System Control 영역에 해당.

#### Policy 탭

```
┌─────────────────────────────────────────────────────────────┐
│ P1 Trading > Policy                                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Watchlist (종목 목록)      Risk Parameters                 │
│   ┌────────────────┐        ┌──────────────────────────┐    │
│   │ ☑ 005930 삼성  │        │ max_cash_usage:    95%   │    │
│   │ ☑ 000660 하이닉│        │ max_position_pct:  20%   │    │
│   │ ☑ 035720 카카오│        │ max_daily_loss:    -2%   │    │
│   │ [+ 추가]       │        │ max_daily_trades:  40    │    │
│   └────────────────┘        │ trading_hours: 09:00~15:20│   │
│                              │ circuit_breaker: 3/60s   │    │
│   Active Strategy            └──────────────────────────┘    │
│   ┌────────────────┐                                        │
│   │ ma_crossover   │        [Save] ← Validator 통과 후 활성  │
│   │ v1.0           │        [Reset to Default]              │
│   │ SMA(5,20)      │                                        │
│   └────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
```

**Phase 1 대응**: `config/watchlist.yaml` + `config/config.yaml` 수동 편집이 이 탭에 해당.

#### Test 탭

```
┌─────────────────────────────────────────────────────────────┐
│ P1 Trading > Test                                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Backtest Runner                                           │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ Strategy: [ma_crossover.py ▼]                       │   │
│   │ Period:   [2024-01-01] ~ [2025-12-31]               │   │
│   │ Symbols:  [005930, 000660]                          │   │
│   │ Capital:  [100,000,000 KRW]                         │   │
│   │                                                     │   │
│   │ [▶ Run Backtest]                                    │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                             │
│   Results                                                   │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ Sharpe: 1.24 ✓   Return: +18.4%   MDD: -8.7%      │   │
│   │ Trades: 47        Win Rate: 58.5%                   │   │
│   │                                                     │   │
│   │ Equity Curve: ~~~~~~~~~~~~~~~~~~~~~~~~~~~           │   │
│   │ (차트)                                               │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**Phase 1 대응**: `atlas backtest strategies/ma_crossover.py --period ...` CLI 명령이 이 탭에 해당.

---

### 6.3 Op4 — P4 Portfolio (Phase 2)

> Phase 1에서는 RiskGuard 내장 간이 체크로 대체. 화면 레이아웃만 확정.

#### Monitor 탭

```
┌─────────────────────────────────────────────────────────────┐
│ P4 Portfolio > Monitor                                      │
├─────────────────────────┬───────────────────────────────────┤
│                         │                                   │
│   Equity Curve          │   Allocation Pie                  │
│   (누적 자산 곡선)       │   (전략별/종목별 비중)              │
│                         │                                   │
├─────────────────────────┴───────────────────────────────────┤
│                                                             │
│   Performance Table                                         │
│   전략별: 수익률, 샤프, MDD, 승률                              │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│   Risk Exposure                                             │
│   종목 집중도(HHI), 섹터 비중, 일일 손실 현황                   │
└─────────────────────────────────────────────────────────────┘
```

---

### 6.4 Op4 — Market Data (Phase 1 부분)

#### Monitor 탭

```
┌─────────────────────────────────────────────────────────────┐
│ Market Data > Monitor                                       │
├─────────────────────────┬───────────────────────────────────┤
│                         │                                   │
│   Connection Status     │   Collection Stats                │
│   WS: 🟢 CONNECTED     │   오늘 수집: 1,250 봉              │
│   REST: 🟢 OK           │   마지막 수집: 09:15:00            │
│   Symbols: 3/3 active  │   다음 수집: 09:16:00              │
│                         │                                   │
├─────────────────────────┴───────────────────────────────────┤
│                                                             │
│   OHLCV Table (최근 수집 데이터 미리보기)                      │
│   symbol | ts       | open   | high   | low    | close     │
│   005930 | 09:15:00 | 72,100 | 72,350 | 72,050 | 72,300    │
│   ...                                                       │
└─────────────────────────────────────────────────────────────┘
```

**Phase 1 대응**: `atlas status`의 시세 연결 상태 부분에 해당.

---

### 6.5 Phase 1 화면 ↔ CLI 매핑 요약

| 화면 영역 | CLI 명령 | Phase |
|----------|---------|-------|
| Op0 전체 | `atlas status` | 1 |
| Op0 Positions | `atlas positions` | 1 |
| Op0 P&L | `atlas pnl` | 1 |
| Op0 Events | `atlas audit` | 1 |
| Op1 Control > Halt/Resume | `atlas halt` / `atlas resume` | 1 |
| Op1 Control > Stop | `atlas stop` | 1 |
| Op1 Test > Backtest | `atlas backtest <file>` | 1 |
| Op1 Policy > Config | `atlas config show` | 1 |
| Op1 Monitor > Orders | `atlas orders` | 1 |
| Op4 Market Data | `atlas status` (시세 부분) | 1 |

---

## 7. 변경 이력

| 일자 | 버전 | 변경 | 근거 |
|------|------|------|------|
| 2026-04-16 | v1.0 | 초안 — 4 카테고리, 17 화면 목록 | 방향 D 완료 |
| 2026-04-16 | v1.1 | 외곽 프레임 추가 | 방향 A 완료 |
| 2026-04-16 | v1.2 | 화면 전환 흐름 추가 | 방향 B 완료 |
| 2026-04-17 | v1.3 | Operating 화면 내부 레이아웃 + CLI 매핑 | 방향 C 완료 (Phase 1 범위) |

---

## 8. 다음 단계

- [x] 방향 D — 구조 .md로 고정
- [x] 방향 A — 공통 외곽 프레임 설계
- [x] 방향 B — 화면 간 전환 흐름
- [x] 방향 C — Operating 화면 내부 레이아웃 (Phase 1 범위)
- [ ] 방향 C 확장 — Watchdog, Design, Ontology 화면 레이아웃 (Phase 2 진입 시)

---

*End of Document — Screen Architecture v1.3*
*4 카테고리 | 17 화면 | 외곽 프레임 | 전환 흐름 7시나리오 | Operating 레이아웃 5화면*
