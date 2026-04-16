# 주요 결정 이력

> 날짜: 2026-04-16  
> 목적: 어떤 시점에 무엇을 왜 결정했는지 추적

---

## 2026-04-16 (오늘)

### DB 스택 확정
Docker Compose 서비스 2개로 확정 (postgres+redis).  
이전에 ChromaDB·Neo4j 분리 구상이 있었으나 초기 운영 단순성 우선.  
→ ADR-006

### FSM 이중 레벨 설계 확정
취약점 17개 분석 후 종목군(5상태)+개별(13상태) 이중 구조로 확정.  
이전 단일 FSM에서 PARTIAL_FILLED, RECONCILING, SUSPENDED 상태 추가.  
→ ADR-007

### 데이터 수집 원칙 확정
"한정 기간만 제공되는 수치 데이터만 저장" 원칙 확정.  
재무제표·종목기본정보·공시 목록은 저장 안 함 (API 실시간 조회).  
→ ADR-008

### 정형·비정형 교차 검증 — 현재 구현 불가
데이터가 존재해야 의미 있으므로 Phase 5 이후로 연기.  
→ ADR-009

### LLM 역할 재정의
"대화 기반 Agent 아님"에서 정교화:
- 외부 인터페이스: jdw 입장에서 Agent처럼 보임
- 내부 실행: FSM이 제어, LLM은 활성화 판단 + 감시·보고만
- 철도 관제 비유 확정 (관제사+감시카메라 / 신호시스템 / 최고책임자)
→ ADR-010

### Code Generator — 현재 시작 불가
노드 내부 명세 미완성. 확정 후 구현 단계 2번에서 진행.  
→ ADR-010

### 백테스팅 프레임워크 확정
벡터(빠른 탐색) + 이벤트(정밀 검증) 이중 엔진.  
포트폴리오: 복수 전략 × 복수 종목 동시.  
실전 전환 기준: 모의 30일+ / 샤프 > 1.0 / MDD < 15%.

---

## 2026-04-15 (이전 채팅)

### 시스템 목표 재정의
43노드 완성형 동시 구축 → Phase 1→2→3 단계별 확장형으로 변경.

### Architecture Deep Review
6 Path 전체 재분석. 취약점 5개·누락 8개·분기 4개 발견.  
→ architecture_deep_review_v1.0.md

### Reinforcement Patch v2.0
17개 패치 확정. KISAPIGateway, ApprovalGate, Boot/Shutdown 시퀀스 등.  
→ architecture_reinforcement_patch_v2.0.md

### 구현 단계 진행 순서 확정
1. 초기 화면 설계 (S1 Dashboard + S7 Telegram)
2. Code Generator 설계
3. Phase별 상세 구현

---

## 2026-04-14~15 (이전 채팅들)

### 6개 Path Port Interface 완성
Port Interface Path 1~6 각각 작성 완료.  
총 36개 Port / 192개 메서드 / 86개 Domain Type.

### Node Blueprint 완성
43개 노드 내부 상세 (lifecycle, internal_logic, config, error_handling).

### Graph IR v1.0.yaml 완성
Single Source of Truth. 노드+엣지+스키마 전체 포함.

### LangGraph 도입 결정
Knowledge Building·Strategy Development Path의 LLM 노드 한정.  
PostgreSQL checkpointer로 상태 영속화.

### PathCanvas UI 결정
LiteGraph.js 기반 노드·엣지 시각적 편집. Graph IR과 연동.

---

## 2026-03 (초기)

### KIS MCP 도구 설치
kis-trade-mcp (Docker, 주문 실행) + kis-code-assistant-mcp (stdio, 코드 검색) 로컬 설치 완료.

### TrustGraph 평가
배경 지식 구축에는 적합, 실시간 매매 판단에는 부적합 결론.  
→ ADR-002 (TrustGraph 범위 제한)

### Hexagonal Architecture 채택
BrokerPort / MarketDataPort / StrategyPort 등 Port & Adapters 구조 확정.  
→ ADR-001
