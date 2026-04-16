# LLM 역할 정의 및 대화 저장

> 상태: stable  
> 날짜: 2026-04-16  
> 연관 ADR: 010

---

## 1. LLM 역할 3분리

### 철도 관제 비유

```
LLM = 관제사 + 감시카메라   어느 열차를 출발시킬지 결정 + 전체 선로 감시
FSM = 신호 시스템 (레일)    출발 명령 받으면 정해진 레일 위를 달림
jdw = 최고 책임자           최종 승인
```

### 역할 정의

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

---

## 2. LLM 레벨 분류

| 레벨 | 이름 | 정의 | 적용 Path |
|------|------|------|----------|
| L0 | No LLM | 순수 Python 로직 | Path 1, 5, 6 전체 |
| L1 | LLM Assist | LLM이 분석·제안, 최종 판단은 deterministic | Path 2, 3, 4 일부 |
| L2 | LLM Core | LLM이 핵심. 고립경로가 다른 Path 보호 | Path 2 CausalReasoner 등 |

**Path 1 (Realtime Trading) 은 100% L0** — 돈이 오가는 경로에 LLM 개입 없음.

---

## 3. LLM 대화 저장 구조

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
thread_id          대화 세션 식별자
messages           LLM 전체 대화 이력
intermediate_steps tool call 결과, 중간 추론
activation_log     어떤 시나리오를 FSM에 넘겼는지 이력
monitoring_log     상태 감시 보고 이력
context            종목·시나리오 컨텍스트
```

### Phase

Phase 3 구현 시 함께 진행. 스냅샷 구조이므로 즉시 구현 가능.

---

## 4. Code Generator (연관)

Graph IR YAML → Python 코드 자동 생성 3단 구조.

```
PathCanvas (LiteGraph.js)
    ↓ 편집
Graph IR YAML (Single Source of Truth)
    ↓ 생성
Code Generator → Python 실행 코드
```

**전제 조건:** 노드 내부 명세 완전 확정 후 시작.  
현재 노드 명세 미완성 → 시작 불가.

→ 상세: `docs/decisions/010-llm-storage-code-generator.md`
