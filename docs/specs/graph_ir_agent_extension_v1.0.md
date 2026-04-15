# HR-DAG Trading System — Graph IR Agent Extension

> Version 1.0 | April 2026 | Design Phase

---

## 1. Purpose

Graph IR(Single Source of Truth) 스키마를 확장하여 LangGraph 기반 agent 노드를 수용한다. 이 문서는 `boundary_definition_v1.0.md`에서 정의한 LLM Engagement Level(L0/L1/L2)을 구현 레벨로 구체화한다.

### 1.1 Scope

| 항목 | 내용 |
|------|------|
| 추가 대상 | `runMode: agent`, `agent_spec` 블록, `LLMPort` 인터페이스 |
| 영향 문서 | System Manifest, Node Blueprint, ATLAS, Isolated Path Design |
| 선행 문서 | `boundary_definition_v1.0.md` — L0/L1/L2 분류 및 Constrained Agent 원칙 |

### 1.2 Design Decisions

| Decision | Rationale |
|----------|-----------|
| LangGraph 단독 선정 | State 영속화 + conditional branching + 실패 복구 네이티브 지원. 비교 평가: LlamaIndex, Haystack, MS Agent FW, CrewAI 탈락 |
| LlamaIndex 보조 병용 | Knowledge Pipeline 내 RAG 검색을 LangGraph 노드의 tool로 호출 |
| LLMPort 신설 (7번째 포트) | Plug & Play 원칙 준수. LLM provider 교체 시 core 코드 변경 0줄 |
| Task Router 도입 | 노드별 최적 모델 분기. 비용/품질/속도 균형 |
| Path 1, 5 agent 금지 | Realtime Trading: 지연시간 critical. Watchdog: 감시자 비결정성 금지 |

---

## 2. runMode Extension

### 2.1 Before (5종)

```
batch | poll | stream | event | stateful-service
```

### 2.2 After (6종)

```
batch | poll | stream | event | stateful-service | agent
```

### 2.3 Judgment Criteria

> **"이 노드가 LLM을 호출하고, 그 결과에 따라 다음 행동이 달라지는가?"**
> Yes → `runMode: agent` / No → 기존 runMode 유지

### 2.4 agent vs Deterministic

| 속성 | deterministic (기존 5종) | agent (신규) |
|------|--------------------------|------|
| 실행 흐름 | 사전 정의, 재현 가능 | LLM 응답에 따라 분기 |
| 상태 관리 | 애플리케이션 레벨 | LangGraph checkpointer 자동 |
| 실패 복구 | 재시작 또는 재시도 | checkpoint에서 resume |
| 내부 구현 | Python async | LangGraph StateGraph |
| LLM 의존 | 없음 | 필수 (LLMPort 경유) |

---

## 3. agent_spec — Node Blueprint Extension

`runMode: agent`인 노드에만 필수로 포함되는 메타데이터 블록.

### 3.1 Schema

```yaml
agent_spec:
  framework:            # enum: [langgraph]. 현재 langgraph만 허용
  state_schema:         # LangGraph state 타입 정의
    <field_name>:
      type:             # str | int | float | bool | list[str] | list[dict] | dict
      default:          # 초기값
      description:      # 설명
  checkpointer:         # enum: [postgresql, sqlite, memory]
  max_iterations:       # int, 1~20, default 5. 무한루프 방지
  entry_point:          # StateGraph 시작 노드 이름
  terminal_conditions:  # list[str]. 종료 조건식. 하나라도 충족 시 종료
  llm_task:             # Task Router 모델 매핑 키
  graph_nodes:          # StateGraph 내부 노드 목록
    - name:             # 노드명
      description:      # 설명
      calls_llm:        # bool. LLMPort 호출 여부
  graph_edges:          # StateGraph 내부 엣지 목록
    - from:             # 출발 노드
      to:               # 도착 노드 (__end__ = 종료)
      condition:        # 조건부 엣지의 조건식 (없으면 무조건)
```

### 3.2 Example: CausalReasoner

```yaml
node_id: knowledge_causal_reasoner
path: knowledge_building
runMode: agent
category: Core

ports:
  input:
    - name: knowledge_graph_snapshot
      type: DataPipe
    - name: external_sources
      type: DataPipe
  output:
    - name: causal_chain
      type: DataPipe
      schema: "list[CausalLink]"
    - name: audit_event
      type: EventNotify

agent_spec:
  framework: langgraph
  state_schema:
    sources_collected:
      type: "list[str]"
      default: []
      description: "수집 완료된 소스 ID 목록"
    reasoning_chain:
      type: "list[dict]"
      default: []
      description: "추론 단계별 기록 [{step, premise, conclusion, confidence}]"
    confidence:
      type: float
      default: 0.0
      description: "현재 추론 체인의 종합 확신도 (0.0~1.0)"
    iteration_count:
      type: int
      default: 0
      description: "현재 반복 횟수"
  checkpointer: postgresql
  max_iterations: 5
  entry_point: evaluate_sources
  terminal_conditions:
    - "confidence >= 0.8"
    - "iteration_count >= max_iterations"
  llm_task: causal_reasoning
  graph_nodes:
    - name: evaluate_sources
      description: "수집된 소스의 관련성과 신뢰도 평가"
      calls_llm: true
    - name: build_reasoning
      description: "인과관계 추론 단계 수행"
      calls_llm: true
    - name: assess_confidence
      description: "추론 체인의 확신도 평가"
      calls_llm: false
    - name: search_additional
      description: "확신도 부족 시 추가 소스 탐색"
      calls_llm: false
  graph_edges:
    - from: evaluate_sources
      to: build_reasoning
    - from: build_reasoning
      to: assess_confidence
    - from: assess_confidence
      to: __end__
      condition: "confidence >= 0.8 or iteration_count >= max_iterations"
    - from: assess_confidence
      to: search_additional
      condition: "confidence < 0.8 and iteration_count < max_iterations"
    - from: search_additional
      to: evaluate_sources
```

---

## 4. LLMPort — 7th Port Interface

### 4.1 Port Registry (Updated)

| # | Port | 역할 | 도입 시점 |
|---|------|------|-----------|
| 1 | BrokerPort | 주문 실행, 잔고 조회 | v0 |
| 2 | MarketDataPort | 시세 수신 | v0 |
| 3 | NotifierPort | 알림 전송 | v0 |
| 4 | StoragePort | 데이터 영속화 | v0 |
| 5 | ClockPort | 시장 시간 판단 | v0 |
| 6 | StrategyPort | 전략 실행 | v0 |
| 7 | **LLMPort** | **LLM 추론 호출 (agent 노드 전용)** | **v1.0** |

### 4.2 Interface Definition

```yaml
port_id: llm_port
type: abstract_interface

methods:
  invoke:
    input:
      messages: "list[dict]"         # [{role: str, content: str}]
      temperature: float             # default 0.3
      max_tokens: int                # default 2048
      response_format: str           # "text" | "json"
    output:
      content: str
      usage: { prompt_tokens: int, completion_tokens: int }
      model: str
      latency_ms: int

  stream:
    input:
      messages: "list[dict]"
    output:
      AsyncIterator[str]

constraints:
  - "core/ 및 strategy/ 에서 직접 import 금지"
  - "agent_spec이 있는 노드의 내부 구현에서만 사용"
  - "Path 1 (Realtime Trading) 사용 금지"
  - "Path 5 (Watchdog & Operations) 사용 금지"
```

### 4.3 Adapters

| Adapter | Provider | Config Keys | Use Case |
|---------|----------|-------------|----------|
| claude_api | Anthropic | api_key, model | 고품질 추론 (causal, idea, judgment) |
| openai_api | OpenAI | api_key, model | 대체 provider |
| local_gemma | Local MLX | base_url, model | 비용 제로 반복 작업 |
| litellm_proxy | LiteLLM | base_url, api_key | 통합 라우팅 + fallback |

### 4.4 Task Router

```yaml
# settings.yaml
llm:
  default_adapter: litellm_proxy
  task_routing:
    causal_reasoning:     { adapter: claude_api,  model: claude-sonnet-4-6, temperature: 0.2 }
    ontology_mapping:     { adapter: local_gemma, model: gemma-4-e4b-it-4bit, temperature: 0.1 }
    knowledge_qa:         { adapter: claude_api,  model: claude-haiku-4-5, temperature: 0.3 }
    idea_generation:      { adapter: claude_api,  model: claude-sonnet-4-6, temperature: 0.7 }
    result_interpretation:{ adapter: local_gemma, model: gemma-4-e4b-it-4bit, temperature: 0.2 }
    composite_judgment:   { adapter: claude_api,  model: claude-sonnet-4-6, temperature: 0.3 }
  fallback:
    claude_api: openai_api
    local_gemma: claude_api
    litellm_proxy: claude_api
```

---

## 5. Agent Node Registry

### 5.1 Confirmed Agent Nodes (6)

| # | node_id | Path | LLM Level | llm_task | Recommended Model | Rationale |
|---|---------|------|-----------|----------|--------------------|-----------|
| 1 | knowledge_ontology_mapper | Knowledge Building | L2 | ontology_mapping | Local Gemma4 | 반복적 엔티티 추출, 비용 민감 |
| 2 | knowledge_causal_reasoner | Knowledge Building | L2 | causal_reasoning | Claude Sonnet | multi-hop 인과추론, 품질 최우선 |
| 3 | knowledge_qa | Knowledge Building | L1 | knowledge_qa | Claude Haiku | RAG 응답 종합, 빠른 응답 |
| 4 | strategy_idea_generator | Strategy Development | L1 | idea_generation | Claude Sonnet | 창의적 전략 제안 |
| 5 | strategy_result_interpreter | Strategy Development | L1 | result_interpretation | Local Gemma4 | 백테스트 수치 해석, 빈번 호출 |
| 6 | portfolio_composite_judge | Portfolio Management | L1 | composite_judgment | Claude Sonnet | 수치+지식 종합 판단 |

### 5.2 Excluded Paths (Immutable)

| Path | 전체 runMode | 근거 |
|------|-------------|------|
| Path 1: Realtime Trading | deterministic only | 지연시간 critical, 결과 재현성 필수. 돈이 오가는 경로에 LLM 금지 |
| Path 5: Watchdog & Operations | deterministic only | 감시자가 비결정적이면 안전 보장 불가 |

### 5.3 Mapping to Boundary Definition

| boundary_definition L-Level | runMode 매핑 |
|------|------|
| L0 (No LLM) | batch / poll / stream / event / stateful-service |
| L1 (LLM Assist) | agent (with deterministic fallback required) |
| L2 (LLM Core) | agent (고립경로가 다른 Path 보호) |

---

## 6. Validation Rules

`runMode: agent` 도입에 따라 Validation Engine에 추가하는 규칙.

| Rule ID | Description | Severity |
|---------|-------------|----------|
| V-AGENT-001 | `runMode: agent`인 노드는 `agent_spec` 필수 | error |
| V-AGENT-002 | `agent_spec.framework`는 허용된 값만 가능 (`langgraph`) | error |
| V-AGENT-003 | `agent_spec.terminal_conditions` 비어있으면 무한루프 위험 | error |
| V-AGENT-004 | `agent_spec.max_iterations` 미설정 또는 0이면 무한루프 위험 | warning |
| V-AGENT-005 | Path 1 (Realtime Trading) 노드는 `runMode: agent` 금지 | error |
| V-AGENT-006 | Path 5 (Watchdog) 노드는 `runMode: agent` 금지 | error |
| V-AGENT-007 | `llm_task`는 `settings.yaml`의 `task_routing`에 정의 필요 | warning |
| V-AGENT-008 | `graph_nodes` 중 `calls_llm: true`인 노드 최소 1개 | warning |
| V-PORT-001 | `LLMPort` 참조는 `runMode: agent` 노드에서만 허용 | error |

---

## 7. State & Audit Design

### 7.1 LLM Conversation Persistence

| 저장 대상 | 저장소 | 접근 범위 |
|-----------|--------|-----------|
| StateGraph 전체 state (대화이력, 추론체인, confidence) | PostgreSQL checkpointer | 해당 agent 노드 내부만 |
| LLM 호출 메타데이터 (모델명, 토큰수, 지연시간) | AuditLogger via EventNotify | Watchdog Path에서 읽기 |

### 7.2 Shared Store Impact

agent 노드의 LLM 대화 이력은 Shared Store가 **아닌** checkpointer 내부에 캡슐화. Shared Store는 Path 간 데이터 교환 용도이므로 LLM 내부 state가 흘러들어가면 안 됨. 기존 6개 Shared Store에 변경 없음.

### 7.3 Cross-Path Audit Edge

```
agent 노드 --[EventNotify]--> Watchdog Path / AuditLogger
                                 ↓
                           Report DB (Shared Store)
                                 ↓
                    Channel 2: 외부 LLM(Claude Code)이 소비
```

이 흐름은 `boundary_definition_v1.0.md` Section 6의 Watchdog 3-Channel Architecture와 정합.

---

## 8. Implementation Architecture

### 8.1 Node Internal Structure

```
HR-DAG Node (runMode: agent)
  └── LangGraph StateGraph (orchestration + state)
        ├── Node: call_llm → LLMPort.invoke()
        ├── Node: evaluate → deterministic logic
        ├── Node: search_more → external tool call
        ├── Tool: LlamaIndex QueryEngine (RAG, Knowledge Pipeline only)
        ├── Checkpointer: PostgreSQL
        └── Conditional edges: confidence-based branching
```

### 8.2 LLM Connection Stack

```
LangGraph Node
  → LLMPort.invoke()
    → Adapter (selected by Task Router)
      → LiteLLM Proxy (:4000) ─── or ─── Direct API call
           ├── Local Gemma4 (MLX :8080)
           ├── Claude Sonnet (Anthropic API)
           └── Claude Haiku (Anthropic API)
```

### 8.3 Plug & Play Verification

| 교체 시나리오 | 변경 범위 | core/ 변경 |
|--------------|-----------|------------|
| Claude → OpenAI 전환 | settings.yaml adapter 1줄 | 0줄 |
| 로컬 모델 → Claude 전환 | settings.yaml adapter 1줄 | 0줄 |
| LangGraph → 다른 프레임워크 | agent 노드 내부 구현 교체 | 0줄 (Port Interface 유지) |
| 특정 노드의 모델 변경 | settings.yaml task_routing 1줄 | 0줄 |

---

## 9. Downstream Document Updates

이 스펙이 확정되면 다음 문서에 반영 필요.

| Document | Change Required | Method |
|----------|----------------|--------|
| System Manifest | 각 노드에 `runMode` 필드 추가, agent 표시 | Manual |
| ATLAS | LLMPort 패턴, LangGraph 통합 섹션 추가 | Manual |
| Isolated Path Design | Path별 agent/deterministic 경계 명시 | Manual |
| Node Blueprint | `agent_spec` 블록 자동 포함 | Doc Generator |
| Validation Report | V-AGENT-* 규칙 적용 결과 | Validation Engine |

---

*End of Document — Graph IR Agent Extension v1.0*
*Depends on: boundary_definition_v1.0.md*
*Next Step: System Manifest에 runMode 필드 반영*
