# ADR-010: LLM 역할 정의 + 대화 저장·관리 + Code Generator

> 상태: stable  
> 날짜: 2026-04-16  
> 결정자: jdw

---

## 1. LLM 역할 정의 — 핵심

### 철도 관제 비유

> LLM = 관제사 + 감시카메라  
> FSM = 신호 시스템 (레일)  
> jdw = 최고 책임자 (최종 승인)

### 역할 3분리

| 역할 | 주체 | 내용 |
|------|------|------|
| 활성화 판단 | LLM | 시나리오를 FSM에 넘길지 말지 결정 |
| 경로 실행 | FSM | 정해진 상태 전이 그대로 실행, LLM 개입 없음 |
| 감시·보고 | LLM | 전체 FSM 상태 파악 → jdw에게 보고·제안 |

### 핵심 경계

```
LLM이 결정하는 것:
  - 시나리오를 FSM에 넘길지 말지 (활성화 여부)
  - 시나리오 시작·중단 판단
  - 이상 징후 감지 후 jdw 보고

FSM이 실행하는 것:
  - 활성화된 시나리오의 상태 전이
  - 주문 실행, 청산, 포지션 관리
  - 경로 내 모든 결정론적 동작

LLM이 절대 하지 않는 것:
  - FSM 경로 중간에 개입
  - 실시간 주문 판단
  - 시나리오 경로 자체를 임의 변경
```

### 외부에서 보이는 모습

jdw 입장에서는 대화 기반 Agent처럼 보인다.
하지만 매매 실행 엔진 내부는 LLM이 아니라 FSM이 제어한다.
LLM은 FSM의 문지기이자 감시자이지, FSM 내부 동작을 제어하지 않는다.

---

## 2. LLM 내부 대화 저장·관리

### 결정

LangGraph StateGraph + PostgreSQL checkpointer로 LLM 대화 이력·추론·activation 이력을 저장한다.

### 적용 범위

| 적용 | 미적용 |
|------|--------|
| Knowledge Building — CausalReasoningNode | Realtime Trading Path |
| Strategy Development — ScenarioGeneratorNode | Portfolio Management |
| 감시·보고 LLM (상태 요약, 이상 감지) | Watchdog Path |

### 저장 내용

```
thread_id         대화 세션 식별자
messages          LLM 전체 대화 이력
intermediate_steps  tool call 결과, 중간 추론
activation_log    어떤 시나리오를 FSM에 넘겼는지 이력
monitoring_log    상태 감시 보고 이력
context           종목·시나리오 컨텍스트
```

### Phase

Phase 3 구현 시 함께 진행. 스냅샷 구조이므로 즉시 구현 가능.

---

## 3. Code Generator

### 전제 조건

노드 내부 명세(메서드, 파라미터, 인터페이스)가 완전히 확정된 후에만 의미 있다.
현재 트리구조 v4까지 진행했으나 노드 명세 미완성. Graph IR YAML도 구버전.

### 구조

```
PathCanvas (LiteGraph.js) → Graph IR YAML → Code Generator → Python 코드
```

### 생성 범위

- 생성: 클래스 스켈레톤, 포트 연결, asyncio 실행 패턴
- 미생성: 비즈니스 로직 (전략 계산, 리스크 규칙)

### Phase

구현 단계 2번. 노드 명세 완전 확정 후 시작.
