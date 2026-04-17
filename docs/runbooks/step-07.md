# Step 07 — MockBrokerAdapter + OrderExecutor 실제

## 1. 목적

FakeBroker를 MockBrokerAdapter로 교체. OrderExecutor가 submit_order()를 호출하여 체결 응답 수신.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 2
- 기여 방식: 모의투자 5일 무사고 — 체결 시뮬레이션 필요

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/specs/adapter-spec-phase1.md` — §5.1 MockBrokerAdapter — Mock 체결 시뮬레이션 명세 (10분)
2. `docs/architecture/path1-phase1.md` — §2.5 OrderExecutor — 주문 실행 로직 (10분)
3. `docs/specs/error-handling-phase1.md` — §3.5 OrderExecutor, §4.2 BrokerPort — 에러 처리 규칙 (5분)
4. `docs/specs/domain-types-phase1.md` — §3.5 Order (Order, Fill, OrderAck) — 타입 확인 (5분)

**이 Step에서 읽지 않는 문서**: fsm-design (Step 8), db-schema (Step 9)

## 5. 작업 단계

> Step 착수 직전에 상세화. §4 참조 문서 정독 후 구체적 파일 수정 목록 작성.

## 6. 완료 조건

- [ ] 관찰 기준: (착수 전 상세화)
- [ ] 테스트: `pytest tests/ -v` 전체 녹색
- [ ] Port 불변: Port 시그니처 변경 없음
- [ ] seam-map.md: 해당 Stub 행 갱신 완료
- [ ] PROGRESS.md: 체크박스 + Daily Log

## 7. 커밋

```bash
git add -A
git commit -m "Step 07: MockBrokerAdapter + OrderExecutor 실제

Observable change: (착수 전 상세화)
Fitness criteria:  2
Port changes:      none
Tests added:       tests/step_07/test_*.py"
```
