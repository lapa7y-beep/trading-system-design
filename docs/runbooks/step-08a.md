# Step 08a — FSM 3상태 (IDLE/IN_POSITION/EXIT_PENDING)

## 1. 목적

TradingFSM을 2상태 stub에서 3상태(IDLE, IN_POSITION, EXIT_PENDING)로 확장. 기본 전이가 관찰된다.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 2
- 기여 방식: 모의투자 5일 incident-free — FSM이 정확해야 주문 흐름 제어 가능

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/architecture/fsm-design.md` — 상태 목록 섹션 (IDLE, IN_POSITION, EXIT_PENDING만) — 3상태 전이 규칙 (15분)
2. `docs/specs/domain-types-phase1.md` — FSMTransition 타입 — 타입 확인 (3분)

**이 Step에서 읽지 않는 문서**: FSM 나머지 7상태 (Step 8b), db-schema (Step 9)

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
git commit -m "Step 08a: FSM 3상태 (IDLE/IN_POSITION/EXIT_PENDING)

Observable change: (착수 전 상세화)
Fitness criteria:  2
Port changes:      none
Tests added:       tests/step_08a/test_*.py"
```
