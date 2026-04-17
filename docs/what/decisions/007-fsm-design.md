# ADR-007: 이중 레벨 FSM 설계 (종목군 + 개별 종목)

> **목적**: 거래 상태 관리를 종목군 레벨과 개별 종목 레벨의 이중 FSM으로 설계한 결정을 기록한다.
> **층**: What
> **상태**: stable
> **최종 수정**: 2026-04-16
> **연계 문서**: 이 결정의 상세 구현 설계: `docs/what/architecture/fsm-design.md`

## 결정

종목군 FSM + 개별 종목 FSM 이중 레벨로 운용한다.  
두 FSM은 독립 운용하며, 개별 종목이 전이 시점에 군 상태를 참조만 한다. 군이 개별을 직접 제어하지 않는다.

---

## 종목군 FSM — 5개 상태

| 상태 | 의미 | 진입 조건 |
|------|------|-----------|
| INACTIVE | 비활성 | 초기 또는 CLOSED 후 재등록 |
| ACTIVE | 시나리오 진행 중 | 시나리오 승인 시 |
| SUSPENDED | VI·CB·수동 동결 | VI/CB 이벤트 또는 수동 명령 |
| CLOSING | 군 전체 청산 진행 | 포트폴리오 한도 초과 등 |
| CLOSED | 시나리오 완료 | 산하 종목 전체 DONE |

### 종목군 정의 방식 (2가지)
- **시나리오 기반 군**: LLM 초안 생성 → 사람 승인 시 자동 생성. 시나리오가 대상 종목 목록을 포함.
- **수동 그룹**: 사람이 임의 정의. 이름·구성 자유.

---

## 개별 종목 FSM — 13개 상태

포지션 키 = `(종목코드 + 증권사)` — KIS와 Kiwoom 독립 인스턴스.

| 상태 | 의미 |
|------|------|
| IDLE | 관심종목 등록, 아무 조건 없음 |
| WATCHING | 진입 조건 감시 중 |
| SCENARIO_RUNNING | 시나리오 경로 실행 중 |
| PENDING_APPROVAL | Telegram 승인 대기 (타임아웃 시 자동 취소 → IDLE) |
| ORDER_PLACED | 주문 전송, 체결 대기 (idempotency key 필수) |
| PARTIAL_FILLED | 부분 체결, 잔여 수량 대기 |
| HOLDING | 포지션 보유, 청산 조건 감시 |
| RECONCILING | 잔고 불일치 조사 중 (30초 대사에서 감지) |
| EXITING | 청산 주문 진행 중 |
| DONE | 완료, 재등록 가능 |
| ERROR | 복구 불가, 수동 개입 필요 |
| SUSPENDED | 군 SUSPENDED 참조 후 자체 동결 |

### 핵심 전이 규칙
- 모든 전이 전 군 FSM 상태를 확인. 군이 SUSPENDED/CLOSING이면 신규 진입 전이 차단.
- `PENDING_APPROVAL` 타임아웃(N초) → 자동 취소 후 IDLE 복귀.
- `ORDER_PLACED` 체결통보 N초 미수신 → KIS/Kiwoom 잔고 조회 폴링 fallback.
- `HOLDING` → 30초 대사에서 불일치 감지 시 → `RECONCILING` 자동 전이.
- 종목당 활성 시나리오 1개 mutex.

---

## 취약점 대응 요약 (17개 → 설계 반영)

| 취약점 | 대응 |
|--------|------|
| A3 상태 비영속성 | DB 영속화 필수 (모든 전이 즉시 저장) |
| A4 상태-잔고 불일치 | RECONCILING 상태 + 30초 대사 |
| A5 부분 체결 | PARTIAL_FILLED 상태 추가 |
| B2 VI·CB 미처리 | SUSPENDED 상태 + 시장감시 연동 |
| B4 장마감 미처리 | 15:30 이벤트 → SUSPENDED 자동 전이 |
| C1 승인 타임아웃 | PENDING_APPROVAL + 타임아웃 자동 취소 |
| C2 체결통보 유실 | N초 미수신 → 폴링 fallback |
| C5 중복 주문 | idempotency key + ORDER_PLACED 상태에서 재진입 차단 |
| D2 외부 개입 | RECONCILING + 대사 불일치 처리 |
| D4 복수 시나리오 충돌 | 종목당 1개 mutex |
| E1 ERROR 없음 | ERROR 상태 추가 |

---

## 설계 원칙

```
포지션 키     = (종목코드 + 증권사)
시나리오 mutex = 종목당 활성 시나리오 1개
DB 영속화     = 전이마다 즉시 저장 (PostgreSQL)
Redis 캐시    = 빠른 상태 조회용 (PG와 이중 운용)
이벤트 소싱   = 모든 전이를 감사 로그로 추적
```
