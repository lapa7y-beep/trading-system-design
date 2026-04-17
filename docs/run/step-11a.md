# Step 11a — 백테스트 엔진 + Sharpe 계산

## 1. 목적

과거 1년 CSV 데이터로 백테스트 실행, Sharpe ratio 계산.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 1
- 기여 방식: Sharpe > 1.0 — Phase 1 합격기준 1번

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/what/pipelines/backtesting.md` — 전체 (§1~7) — 백테스트 파이프라인 설계 (20분)
2. `docs/what/specs/test-strategy-phase1.md` — §5.2 합격 기준 1 — 백테스트 샤프 — 테스트 코드 구조 (10분)
3. `docs/what/decisions/011-phase1-scope.md` — §5 합격 기준 — Sharpe > 1.0 기준 확인 (3분)

**이 Step에서 읽지 않는 문서**: 없음 — Phase 1 마지막 개발 Step

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
git commit -m "Step 11a: 백테스트 엔진 + Sharpe 계산

Observable change: (착수 전 상세화)
Fitness criteria:  1
Port changes:      none
Tests added:       tests/step_11a/test_*.py"
```
