# ADR-010: LLM 대화 저장·관리 및 Code Generator

> 상태: stable  
> 날짜: 2026-04-16  
> 결정자: jdw

---

## 1. LLM 내부 대화 저장·관리

### 결정

LLM이 관여하는 노드(Knowledge Building Path, Strategy Development Path)에 한해
**LangGraph StateGraph + PostgreSQL checkpointer**로 대화 이력과 중간 추론을 저장한다.

### 적용 범위

| 적용 | 미적용 |
|------|--------|
| Knowledge Building Path 내 CausalReasoningNode | Realtime Trading Path |
| Strategy Development Path 내 ScenarioGeneratorNode | Portfolio Management Path |
| AnalysisEngine (교차 검증 해석) | Watchdog Path |

### 저장 내용

```
LangGraph State (PostgreSQL 저장):
  - thread_id: 대화 세션 식별자
  - messages: LLM과의 전체 대화 이력
  - intermediate_steps: tool call 결과, 중간 추론
  - created_at / updated_at
  - context: 어떤 종목·시나리오에 대한 대화인지
```

### 재현성 보장

- 동일 thread_id로 resume 가능 (중단 후 재개)
- 어떤 추론 경로를 거쳤는지 감사 추적 가능
- 시나리오 생성 근거를 나중에 확인 가능

### 중요 경계

- **현 시스템은 대화 기반 Agent가 아니다**
- LLM은 advisor 역할 — 판단 주체가 아님
- Telegram(S7)은 운영 제어 인터페이스, 매매 판단 인터페이스가 아님
- 실시간 매매 경로에 LLM 개입 없음 (ADR-002와 동일)

---

## 2. Code Generator (Graph IR → Python 코드)

### 결정

**Graph IR YAML → Python 코드 자동 생성** 3단 구조를 유지한다.

```
PathCanvas (LiteGraph.js)
    ↓ 편집
Graph IR YAML (Single Source of Truth)
    ↓ 생성
Code Generator → Python 실행 코드
```

### Code Generator 역할

| 입력 | 출력 |
|------|------|
| graph_ir.yaml의 노드 정의 | Python 클래스 스켈레톤 |
| 노드의 port 연결 정보 | `__init__` 의존성 주입 코드 |
| runMode (batch/stream/event 등) | asyncio 실행 패턴 |
| LLM level (none/advisory) | LangGraph 연동 코드 (해당 시) |

### 노드·엣지 변경 시 코드 반영

```
1. PathCanvas에서 노드·엣지 수정
2. Graph IR YAML 자동 업데이트
3. Code Generator 재실행
4. 변경된 노드만 스켈레톤 재생성 (diff 기반)
5. 사람이 비즈니스 로직 부분만 채워넣음
```

**핵심 원칙**: 코드 Generator는 구조(포트, 연결, 실행 패턴)만 생성한다.
비즈니스 로직(전략 계산, 리스크 규칙)은 사람이 작성한다.

### Phase

구현 단계 진행 순서 2번 — 초기 화면 설계 완료 후 진행.
