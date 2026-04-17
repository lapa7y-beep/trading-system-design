# 거래 상태 머신 설계 (종목군 5상태 + 개별 13상태)

> **목적**: 종목군 FSM(5상태)과 개별 종목 FSM(13상태)의 전이 규칙, 취약점 대응, 구현 스택을 정의한다.
> **층**: What
> **상태**: stable
> **최종 수정**: 2026-04-16
> **구현 여정**: Step 08a(기본 4상태)와 Step 08b(13상태 완전)에서 구현. ADR-012 §6 참조.
> **관련 ADR**: 007
> **Phase 1 주의**: Phase 1은 **개별 종목 FSM 6상태만** 사용한다 (IDLE/ENTRY_PENDING/IN_POSITION/EXIT_PENDING/ERROR/SAFE_MODE). 종목군 FSM(레벨 1)과 개별 종목 FSM 13상태 중 나머지 7상태(WATCHING, SCENARIO_RUNNING, PENDING_APPROVAL, PARTIAL_FILLED, HOLDING, RECONCILING, EXITING)는 Phase 2 이후 활성화. Phase 1 FSM 상세는 [`path1-design.md`](path1-design.md) Section 2.6 참조.
> **연계 문서**: 이 설계의 배경 ADR: `docs/what/decisions/007-fsm-design.md`

## 1. 이중 레벨 구조

```
레벨 1 — 종목군 FSM   : 시나리오 단위 그룹 관리
레벨 2 — 개별 종목 FSM: 종목별 포지션 상태 관리

연동 원칙: 군이 개별을 직접 제어하지 않는다
           개별이 전이 시점에 군 상태를 참조만 한다
```

---

## 2. 레벨 1 — 종목군 FSM (5개 상태)

```
INACTIVE ──→ ACTIVE ←──→ SUSPENDED
                │
                ↓
            CLOSING ──→ CLOSED
```

| 상태 | 의미 | 진입 조건 |
|------|------|-----------|
| INACTIVE | 비활성 | 초기 또는 CLOSED 후 재등록 |
| ACTIVE | 시나리오 진행 중 | 사람 승인 후 |
| SUSPENDED | VI·CB·수동 동결 | VI/CB 이벤트 또는 수동 명령 |
| CLOSING | 군 전체 청산 진행 | 포트폴리오 한도 초과 등 |
| CLOSED | 시나리오 완료 | 산하 종목 전체 DONE |

### 종목군 정의 방식

- **시나리오 기반 (기본)**: LLM 초안 생성 → 사람 승인 시 자동 생성. 시나리오가 대상 종목 목록 포함.
- **수동 그룹 (허용)**: 사람이 임의 정의. 이름·구성 자유.

---

## 3. 레벨 2 — 개별 종목 FSM (13개 상태)

포지션 키 = `(종목코드 + 증권사)` — KIS와 Kiwoom 독립 인스턴스.

```
IDLE
  │ 진입 조건 감시 시작
  ↓
WATCHING
  │ 시나리오 트리거
  ↓
SCENARIO_RUNNING
  │ 사람 승인 요청
  ↓
PENDING_APPROVAL ──(타임아웃)──→ IDLE
  │ 승인
  ↓
ORDER_PLACED ──(체결통보 유실)──→ 폴링 fallback
  │ 부분 체결
  ↓
PARTIAL_FILLED
  │ 전량 체결
  ↓
HOLDING ←──→ RECONCILING
  │ 청산 조건 충족
  ↓
EXITING
  │
  ├──→ DONE      (정상 완료)
  ├──→ ERROR     (복구 불가, 수동 개입 필요)
  └──→ SUSPENDED (군 SUSPENDED 참조 후 자체 동결)
```

---

## 4. 핵심 전이 규칙

| 규칙 | 내용 |
|------|------|
| 군 상태 참조 | 모든 전이 전 군 FSM 상태 확인. 군이 SUSPENDED/CLOSING이면 신규 진입 차단 |
| 승인 타임아웃 | PENDING_APPROVAL → N초 초과 시 자동 취소 후 IDLE 복귀 |
| 체결통보 fallback | ORDER_PLACED → N초 체결통보 미수신 → KIS/Kiwoom 잔고 조회 폴링 |
| 불일치 감지 | HOLDING → 30초 대사에서 불일치 감지 시 → RECONCILING 자동 전이 |
| 시나리오 mutex | 종목당 활성 시나리오 1개. 동시 진입 차단 |
| DB 영속화 | 모든 전이 즉시 PostgreSQL 저장 |

---

## 5. 취약점 대응 (17개 → 설계 반영)

| 취약점 | 대응 |
|--------|------|
| 상태 비영속성 | DB 영속화 필수 (모든 전이 즉시 저장) |
| 상태-잔고 불일치 | RECONCILING 상태 + 30초 대사 |
| 부분 체결 미처리 | PARTIAL_FILLED 상태 추가 |
| VI·CB 미처리 | SUSPENDED 상태 + 시장감시 연동 |
| 장마감 미처리 | 15:30 이벤트 → SUSPENDED 자동 전이 |
| 승인 타임아웃 | PENDING_APPROVAL + 자동 취소 |
| 체결통보 유실 | N초 미수신 → 폴링 fallback |
| 중복 주문 | idempotency key + ORDER_PLACED 재진입 차단 |
| 복수 시나리오 충돌 | 종목당 1개 mutex |
| ERROR 상태 없음 | ERROR 상태 추가 |

---

## 6. 구현 스택

```python
# Python transitions 라이브러리 기반
# 상태: PostgreSQL 영속화
# 캐시: Redis (빠른 상태 조회, PG와 이중 운용)
# 이벤트: 모든 전이를 AuditStore 감사 로그로 추적
```
