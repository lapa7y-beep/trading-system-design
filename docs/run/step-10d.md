# Step 10d — CLI halt 30초 블록

## 1. 목적

atlas halt 명령 구현. 30초 내 미체결 주문 취소 + FSM SUSPENDED 전이.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 4
- 기여 방식: atlas halt 30초 블록 — Phase 1 합격기준 4번

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/what/architecture/cli-design.md` — §5.2 atlas halt — halt 동작 정의 (10분)
2. `docs/what/architecture/boot-shutdown-phase1.md` — §5 Emergency Halt 시퀀스 — halt 시퀀스 상세 + 타임아웃 (10분)
3. `docs/what/architecture/fsm-design.md` — §3 — SUSPENDED 상태 — SUSPENDED 전이 규칙 (5분)

**이 Step에서 읽지 않는 문서**: backtesting (Step 11)

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
git commit -m "Step 10d: CLI halt 30초 블록

Observable change: (착수 전 상세화)
Fitness criteria:  4
Port changes:      none
Tests added:       tests/step_10d/test_*.py"
```
