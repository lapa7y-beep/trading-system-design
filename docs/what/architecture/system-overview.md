# ATLAS 전체 아키텍처 개요 (5 Path, HR-DAG)

> **목적**: 5개 고립 경로(Path)와 6개 공유 저장소로 구성된 전체 시스템 구조를 개요한다. Phase 1은 Path 1만 활성.
> **층**: What

> **구현 여정**: 전체 아키텍처의 점진적 구현 순서는 ADR-012 §6(17 Step) 참조.
> 상태: stable  
> 날짜: 2026-04-16  
> 연관 ADR: 010
>
> **Phase 1 주의**: 이 문서는 전체 비전(5 Path, 45 노드)을 기술한다. Phase 1 활성 범위는 **Path 1의 6노드만**이다. Phase 1 상세는 [`path1-phase1.md`](path1-phase1.md) 참조. 아래 수치(Section 7)는 전체 완성 시 목표이며 현재 활성 수치가 아니다.

---

## 1. 시스템 성격

KIS(한국투자증권) + Kiwoom Open API 기반 **반자동 트레이딩 시스템**.

```
외부 인터페이스 — jdw 입장에서는 대화 기반 Agent처럼 보임
내부 실행 엔진 — FSM이 제어, LLM은 FSM 내부에 개입하지 않음
최종 승인      — 항상 사람(jdw)이 결정
```

---

## 2. LLM 역할 3분리

```
LLM = 관제사 + 감시카메라
FSM = 신호 시스템 (레일)
jdw = 최고 책임자 (최종 승인)
```

| 역할 | 주체 | 내용 |
|------|------|------|
| 활성화 판단 | LLM | 시나리오를 FSM에 넘길지 말지 결정 |
| 경로 실행 | FSM | 정해진 상태 전이 그대로 실행, LLM 개입 없음 |
| 감시·보고 | LLM | 전체 FSM 상태 파악 → jdw에게 보고·제안 |

**LLM이 절대 하지 않는 것:**
- FSM 경로 중간 개입
- 실시간 주문 판단
- 시나리오 경로 자체를 임의 변경

---

## 3. 5개 고립 경로 (Isolated Paths)

경로 간 직접 연결 없음. 6개 Shared Store를 통한 간접 연결만 허용.

| Path | 이름 | 핵심 흐름 | LLM |
|------|------|----------|-----|
| 1 | Realtime Trading | 시세→신호→FSM→주문→체결 | L0 (없음) |
| 2 | Knowledge Building | 수집→파싱→온톨로지→인과추론 | L1/L2 |
| 3 | Strategy Development | 생성→백테스트→최적화→배포 | L1 |
| 4 | Portfolio Management | 배분→리스크→성과 | L0/L1 |
| 5 | Watchdog & Operations | 감시→알림→명령→로그 | L0/L1 |

**Path 1은 100% L0** — 돈이 오가는 경로에 LLM 개입 없음.

---

## 4. 6개 Shared Store

| Store | 주요 데이터 | 주 Writer |
|-------|-----------|----------|
| MarketDataStore | OHLCV, 시세 스냅샷 | Path 1 |
| PortfolioStore | 포지션, 체결, 손익 | Path 1, 4 |
| ConfigStore | 리스크 한도, 파라미터 | 외부 |
| KnowledgeStore | 온톨로지, 인과관계 | Path 2 |
| StrategyStore | 전략 코드, 백테스트 결과 | Path 3 |
| WatchlistStore | 관심종목, 상태 이력 | Path 1A |
| MarketIntelStore | MarketContext, 수급, 호가 | Path 6 |
| AuditStore | 감사 로그 (불변) | Path 5 |

---

## 5. 전략 구조

```
StrategyPort (인터페이스) — 교체 가능한 추상화
  구현체 1: 시나리오 전략 — LLM 초안 → 사람 승인 → FSM 경로 실행
  구현체 2: 단순 지표 전략 — 이동평균·RSI 등 수치 기반
  구현체 3: 복합 전략 — 정형+비정형 데이터 결합

신호 = 트리거만, 실제 경로는 시나리오가 결정
```

---

## 6. 증권사 구조

```
BrokerPort (추상화)
  ├── KISMCPAdapter     — KIS 주문 실행 (운영 기본)
  ├── KISRestAdapter    — KIS REST 직접 (fallback)
  ├── KiwoomAdapter     — Kiwoom REST
  └── MockBrokerAdapter — 백테스트·모의투자

포지션 키 = (종목코드 + 증권사)
settings.yaml broker: 한 줄로 전환
```

---

## 7. 전체 수치 (전체 비전 — Phase 1 활성 수치 아님)

> **Phase 1 활성 수치**: 6 Nodes / 6 Ports / 14 Edges / 3 Shared Stores / 20 Domain Types
> → 상세는 [`graph_ir_phase1.yaml`](../../graph_ir_phase1.yaml) 및 [`INDEX.md`](../../INDEX.md) 참조

```
전체 비전 (Phase 2~3 완료 시):
Paths:          5개 고립 경로 + Path 6 (Market Intelligence)
Nodes:          45개 (43 + ApprovalGate + MarketContextBuilder)
Ports:          36개 / 192 메서드
Edges:          95개
Shared Stores:  8개
Domain Types:   96개
```
