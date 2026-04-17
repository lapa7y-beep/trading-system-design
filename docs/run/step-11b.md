# Step 11b — 모의투자 5일 검증

## 1. 목적

KIS Paper Trading 환경에서 5영업일 연속 실행. 합격기준 2~5번 동시 검증.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 2,3,4,5
- 기여 방식: 모의투자 5일 무사고, P&L 자동기록, halt 검증, 크래시 복구

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/what/decisions/011-phase1-scope.md` — §5 합격 기준 전체 — 5개 기준 최종 확인 (10분)
2. `docs/what/specs/test-strategy-phase1.md` — §5 합격 기준 테스트 전체 — 자동화 테스트 코드 (15분)
3. `docs/what/specs/error-handling-phase1.md` — §11 KIS 에러 코드 매핑 — 실제 KIS 에러 대응 확인 (10분)
4. `docs/what/specs/design-validation-report.md` — 전체 — 5차 검증 결과 최종 확인 (10분)

**이 Step에서 읽지 않는 문서**: 없음 — Phase 1 최종 검증 Step

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
git commit -m "Step 11b: 모의투자 5일 검증

Observable change: (착수 전 상세화)
Fitness criteria:  2,3,4,5
Port changes:      none
Tests added:       tests/step_11b/test_*.py"
```
