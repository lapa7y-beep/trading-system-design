# System Overview

> 상태: 🔨 draft
> 최종 수정: 2026-04-14

## 1. 설계 방식: HR-DAG

횡적계층 + 종적DAG + 재귀전개. 시스템 전체를 DAG로 표현하되 횡적으로 계층을 나누고 종적으로 데이터 흐름을 따르며, 각 노드는 재귀적으로 내부 구조를 전개할 수 있다.

## 2. 줌 레벨

- ~~L0, L1~~ — 폐기
- **L2 (경로그룹)** — 5개 Path + 6개 공유저장소, 접힌 상태
- **L3 (경로내부)** — 38개 노드 + 취약점 방어, 펼친 상태

## 3. 5개 고립 경로

경로 간 직접 엣지 금지. 공유저장소를 통한 간접 연결만 허용.

| # | 경로 | 핵심 흐름 |
|---|------|-----------|
| 1 | 실시간매매 | 시세수신 → 신호생성 → 주문관리 → KIS실행 |
| 2 | 지식구축 | 외부수집 → 파싱 → 온톨로지 → LLM인과추론 → 검색 |
| 3 | 전략개발 | 수집 → 생성 → 저장 → 백테스트 → 최적화 |
| 4 | 포트폴리오 | 자산배분 → 리밸런싱 → 성과추적 |
| 5 | 감시운영 | 모니터링 → 알림 → 로그 → 장애대응 |

## 4. 6개 공유 저장소

| 저장소 | 역할 |
|--------|------|
| PostgreSQL | 영구 데이터 |
| Redis | 캐시, 실시간 상태 |
| EventBus | 비동기 이벤트 |
| ConfigStore | 설정 중앙관리 |
| AuditLog | 감사 추적 |
| FileStorage | 파일 데이터 |

## 5. 역할 분리

- **전략엔진 = 뇌** — 결정적, 백테스트 가능
- **KIS MCP = 손** — 실행만, 판단 안 함
- **LLM = 참모** — 판단 주체 아님, 보조 정보

## 6. Hexagonal Architecture

6개 Port (Python ABC). YAML 한 줄로 Adapter 교체 가능.

BrokerPort / MarketDataPort / StrategyPort / NotifierPort / StoragePort / ClockPort

→ 상세: hexagonal-ports.md (예정)

## 7. 4대 방어장치

1. **중복주문 방지** — intent_id 멱등성
2. **상태-계좌 일관성** — 3-tier truth, 10초 reconciliation
3. **이벤트 내구성** — WAL 패턴
4. **명령 제어 보안** — whitelist + RBAC + replay 방지 + 감사로그

→ 상세: safeguards.md (예정)

## 8. 노드 & 엣지

**노드 카테고리:** Core / Port / Adapter / Strategy / Infrastructure

**실행 모드:** batch / poll / stream / event / stateful-service

**엣지 역할:** DataPipe(DAG참여) / EventNotify / Command / ConfigRef / AuditTrace(DAG불참여)

→ 상세: specs/node-blueprint.md, specs/edge-types.md (예정)
