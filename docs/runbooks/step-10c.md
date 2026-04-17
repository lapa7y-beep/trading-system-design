# Step 10c — CLI start/stop/status 3명령

## 1. 목적

atlas CLI의 start, stop, status 3명령 구현.

## 2. 합격 기준 매핑

- Phase 1 합격기준: (기반)
- 기여 방식: halt (Step 10d)의 전제

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/architecture/cli-design.md` — §1~5 (설계 원칙~핵심 명령 상세) — CLI 명령 목록과 동작 정의 (15분)
2. `docs/architecture/boot-shutdown-phase1.md` — §2 Boot 시퀀스, §4 Graceful Shutdown — start/stop 시퀀스 상세 (15분)

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
git commit -m "Step 10c: CLI start/stop/status 3명령

Observable change: (착수 전 상세화)
Fitness criteria:  (기반)
Port changes:      none
Tests added:       tests/step_10c/test_*.py"
```
