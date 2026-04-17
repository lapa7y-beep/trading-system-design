# Step 08b — FSM 나머지 (10상태 23전이 완전)

## 1. 목적

FSM을 10상태 23전이 완전체로 확장. ERROR, RECONCILING, HALTED 등 모든 상태 포함.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 2, 5
- 기여 방식: 모의투자 incident-free + 크래시 복구 — ERROR/RECONCILING 상태 필수

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/architecture/fsm-design.md` — 전체 정독 — 10상태 23전이 전체 규칙 (30분)

**이 Step에서 읽지 않는 문서**: db-schema (Step 9), cli-design (Step 10)

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
git commit -m "Step 08b: FSM 나머지 (10상태 23전이 완전)

Observable change: (착수 전 상세화)
Fitness criteria:  2, 5
Port changes:      none
Tests added:       tests/step_08b/test_*.py"
```
