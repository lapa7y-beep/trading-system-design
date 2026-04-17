# Step 04 — IndicatorCalculator 실제 (pandas-ta SMA)

## 1. 목적

Indicator stub을 pandas-ta SMA(20) 실제 계산으로 교체.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 1
- 기여 방식: Sharpe > 1.0 — 실제 지표가 있어야 전략 동작

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/architecture/path1-phase1.md` — §2.2 IndicatorCalculator — 지표 계산 로직 설계 (10분)

**이 Step에서 읽지 않는 문서**: fsm-design (Step 8), db-schema (Step 9), cli-design (Step 10)

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
git commit -m "Step 04: IndicatorCalculator 실제 (pandas-ta SMA)

Observable change: (착수 전 상세화)
Fitness criteria:  1
Port changes:      none
Tests added:       tests/step_04/test_*.py"
```
