# HR-DAG Trading System — Boundary Definition & LLM Role Matrix

> Version 1.0 | April 2026 | Design Phase

---

## 1. Boundary Overview

### 1.1 Internal LLM vs External LLM

| 구분 | Internal LLM (내부) | External LLM (외부) |
|------|---------------------|---------------------|
| 역할 | 시스템 내부에서 런타임 데이터 처리 | 시스템 외부에서 설계/구현/유지보수 |
| 동작 시점 | Runtime — 시스템 실행 중 | Dev-time — 시스템 정지 상태 |
| 위치 | DAG 그래프 안의 노드로 존재 | DAG 그래프 밖에서 Graph IR을 편집 |
| 권한 | Shared Store Read/Write + System Read-Only | Graph IR + Code + Config 전체 Write |
| 통신 | Port Interface 통해 다른 노드와 통신 | Jdw와 대화 + 보고서 읽기 |
| 장애 시 | Deterministic fallback으로 전환 | 시스템 운영에 영향 없음 |
| 비유 | 공장 안의 기계 (눈과 입) | 공장을 설계하고 기계를 설치하는 엔지니어 (손과 머리) |

**접점 원칙**: 내부 LLM과 외부 LLM 사이의 유일한 접점은 Shared Store에 저장된 Watchdog 보고서. 직접 통신 채널 없음.

---

## 2. Constrained Agent Principle

내부 LLM은 제한된 Agent. 권한 모델:

> **Shared Store에 대한 Read-Write + 시스템에 대한 Read-Only = Constrained Agent**

### 2.1 허용된 행동

| 행동 | 대상 | 예시 |
|------|------|------|
| Shared Store 읽기 | 모든 Path의 상태/메트릭/로그 | 오늘 Realtime Path의 체결 건수 조회 |
| Shared Store 쓰기 | 분석 결과, 보고서, Knowledge 데이터 | 인과관계 트리플 저장 |
| 보고서 생성 | Shared Store에 문서로 저장 | 일일/주간 운영 보고서 작성 |
| 알림 발송 | Discord/Telegram으로 발송 | 이상 감지 시 Jdw에게 알림 |
| Jdw와 대화 | 점검 응답, 상태 보고 | "오늘 모의투자 수익률은?" 응답 |
| Knowledge 처리 | Knowledge Path 내부에서만 | 뉴스 파싱, 온톨로지 구축 |

### 2.2 금지된 행동 (구조적 금지)

| 금지 행동 | 이유 | 대안 |
|-----------|------|------|
| 코드 수정 | 검증 안 된 코드가 실전 매매에 영향 | 보고서에 문제 기록 → 외부 LLM이 수정 |
| 설정(YAML) 변경 | 런타임 설정 변경은 예측 불가 | 변경 필요성을 보고서에 기록 |
| 전략 활성화/비활성화 | 전략 변경은 사람(Jdw)만 결정 | 전략 성과 분석 보고서 제공 |
| 노드 시작/중지 | 시스템 상태 변경 권한 없음 | Circuit Breaker 같은 사전 정의 로직만 |
| Path 간 직접 개입 | 고립경로 원칙 위반 | Shared Store 경유만 허용 |
| 주문 실행 로직 변경 | 돈이 걸린 영역은 deterministic만 | RiskGuard 파라미터 제안만 가능 |

---

## 3. LLM Engagement Levels

| Level | 이름 | 정의 | Fallback 요구사항 |
|-------|------|------|-------------------|
| L0 | No LLM | 순수 Python 로직. LLM 개입 절대 불가 | 해당 없음 |
| L1 | LLM Assist | LLM이 분석/제안하지만 최종 판단은 deterministic | 필수 — LLM API 장애 시 기존값 유지 |
| L2 | LLM Core | LLM이 핵심 노동력. LLM 없으면 노드 동작 불가 | 불필요 — 고립경로가 다른 Path 보호 |

---

## 4. Path × LLM Role Matrix

### Path 1: Realtime Trading

| 노드 | Level | 내부 LLM 역할 | Fallback |
|------|-------|---------------|----------|
| 시세 수신 | L0 | (없음) | 해당 없음 |
| 기술지표 계산 | L0 | (없음) | 해당 없음 |
| 전략 판단 | L0 | (없음) — deterministic만 | 해당 없음 |
| 주문 실행 | L0 | (없음) | 해당 없음 |
| TradingFSM | L0 | (없음) | 해당 없음 |
| RiskGuard | L0 | (없음) | 해당 없음 |
| 체결 요약 | L1 | 체결 결과 자연어 요약 | 원시 데이터 그대로 저장 |

> **원칙**: 돈이 오가는 경로에 LLM은 거의 개입하지 않는다.

### Path 2: Knowledge Building

| 노드 | Level | 내부 LLM 역할 | Fallback |
|------|-------|---------------|----------|
| 외부 수집 | L0 | 크롤러/API 호출만 | 해당 없음 |
| 파싱 | L2 | 비정형 텍스트에서 엔티티/관계 추출 | Path 정지 |
| 온톨로지 구축 | L2 | 인과관계 추론, 트리플 생성 | Path 정지 |
| 신뢰도 평가 | L1 | 관계의 신뢰도 점수 부여 | 기본 신뢰도(0.5) 부여 |
| TTL 관리 | L1 | 폐기 후보 선별, 예외 플래깅 | TTL 만료 자동 폐기만 |

> **원칙**: LLM이 가장 활발한 경로. 정지돼도 다른 Path는 기존 Knowledge DB로 계속 동작.

### Path 3: Strategy Development

| 노드 | Level | 내부 LLM 역할 | Fallback |
|------|-------|---------------|----------|
| 전략 생성 | L1 | 새 전략 아이디어 제안 | 기존 전략 풀에서 선택 |
| 백테스트 엔진 | L0 | (없음) — 순수 수치 계산 | 해당 없음 |
| 결과 해석 | L1 | 백테스트 결과 해석, 과적합 감지 | 원시 통계치만 제공 |
| 파라미터 최적화 | L0 | (없음) — 그리드/베이지안 | 해당 없음 |
| 전략 등록 | L0 | (없음) — CRUD만 | 해당 없음 |

> **원칙**: 전략을 실전에 배포할지 결정하는 것은 Jdw만 할 수 있다.

### Path 4: Portfolio Management

| 노드 | Level | 내부 LLM 역할 | Fallback |
|------|-------|---------------|----------|
| 포지션 추적 | L0 | (없음) — 실시간 재고 관리 | 해당 없음 |
| 리밸런싱 | L0 | (없음) — 목표 비중 기반 계산 | 해당 없음 |
| 리스크 리포트 | L1 | 리스크 지표 해석 및 요약 | 원시 수치만 표시 |
| 성과 분석 | L1 | 수익률/MDD 분석 요약 | 기본 통계 제공 |

> **원칙**: 포트폴리오 계산은 전부 deterministic. LLM은 결과를 요약하는 보조 역할만.

### Path 5: Watchdog & Operations

| 노드 | Level | 내부 LLM 역할 | Fallback |
|------|-------|---------------|----------|
| 메트릭 수집 | L0 | (없음) — Prometheus/StatsD | 해당 없음 |
| 이상 감지 | L1 | 로그 패턴 분석, 이상 감지 | 임계치 기반 단순 감지 |
| 보고서 작성 | L2 | 일일/주간 보고서 자동 작성 | Path 정지 (보고서 없이도 시스템 동작) |
| Jdw 대화 | L2 | Jdw와 실시간 점검 대화 | 정형 데이터 API 응답만 |
| 알림 발송 | L0 | (없음) — 템플릿 기반 발송 | 해당 없음 |
| 헬스체크 | L0 | (없음) — ping/pong 점검 | 해당 없음 |

> **원칙**: Watchdog 3채널 — (1) Jdw 실시간 대화 (2) 보고서 자동 생성 (3) 외부 LLM이 소비

---

## 5. Ontology Lifecycle

| 단계 | Level | 처리 Path | 내부 LLM 역할 | DAG 순환 해결 |
|------|-------|-----------|---------------|---------------|
| 1. 생성/수집 | L0~L2 | Knowledge Building | 크롤링(L0) + 텍스트 파싱(L2) | — |
| 2. 정제/활용 | L1~L2 | Knowledge + Strategy + Realtime | 중복제거/모순검출(L2), 질의응답(L1) | Shared Store 경유 읽기 |
| 3. 저장 | L0 | Shared Store (Knowledge DB) | (없음) — DB Write만 | — |
| 4. 갱신 | L2 | Knowledge Building | 기존 관계 유효성 재평가 | Shared Store → 다음 주기 수집 |
| 5. 폐기 | L0~L1 | Knowledge Building | TTL 만료 자동(L0) + 예외 플래깅(L1) | — |

> **순환 해결**: Shared Store를 경유한 간접 루프로 DAG 원칙 유지.

---

## 6. Watchdog 3-Channel Architecture

### Channel 1: Jdw 실시간 대화
- 채널: Discord / Telegram
- 양방향 — Jdw가 질문하고 내부 LLM이 응답
- 제한: Jdw가 "이거 고쳐"라고 해도 직접 수정 불가, 보고서에 기록만

### Channel 2: 정기/이벤트 보고서
- 저장소: Shared Store (Report DB)
- 단방향 — 내부 LLM이 작성, Jdw/외부 LLM이 읽기
- 범위: 전 Path 상태 — 실제 운영, 모의투자, 전략 개발, 시스템 헬스, Knowledge DB

### Channel 3: 외부 LLM 소비
- 소비자: 외부 LLM (Claude Code)
- 흐름: 보고서 읽기 → 문제 파악 → 코드 수정 → 테스트 → 배포
- 핵심: Jdw가 대화에서 발견한 문제도 보고서로 문서화되어 이 채널로 흐른다

---

## 7. Summary Matrix

| Path | L0 | L1 | L2 | Total | LLM비율 |
|------|----|----|-------|-------|---------|
| 1. Realtime Trading | 6 | 1 | 0 | 7 | 14% |
| 2. Knowledge Building | 1 | 2 | 2 | 5 | 80% |
| 3. Strategy Development | 3 | 2 | 0 | 5 | 40% |
| 4. Portfolio Management | 2 | 2 | 0 | 4 | 50% |
| 5. Watchdog & Operations | 3 | 1 | 2 | 6 | 50% |
| **Total** | **15** | **8** | **4** | **27** | **44%** |

> 전체 27개 노드 중 15개(56%)가 L0(No LLM). 돈이 오가는 Realtime Trading Path는 거의 전체가 L0. LLM이 죽어도 매매는 계속된다.

---

## 8. Design Implications for Port Interface

- **L0 노드**: LLM 관련 Port 불필요. 순수 데이터 I/O Port만 정의.
- **L1 노드**: LLMPort (Optional) + FallbackPort (Required).
- **L2 노드**: LLMPort (Required). 고립경로가 다른 Path 보호.
- **Watchdog 노드**: ReadOnlySystemPort (Required). 읽기만 가능.
- **Report 노드**: ReportWritePort (Write to Report DB only).

---

*End of Document — Boundary Definition v1.0*
*Next Step: Port Interface Design based on this boundary*
