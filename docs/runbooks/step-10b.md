# Step 10b — RiskGuard 변동성/유동성 체크

## 1. 목적

RiskGuard에 변동성 체크와 유동성 체크 추가. 7체크 전부 완성.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 2
- 기여 방식: 모의투자 5일 incident-free — 시장 상황 기반 거부 필요

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/architecture/path1-phase1.md` — RiskGuard 노드 섹션 — 변동성/유동성 체크 항목 — 체크 로직 상세 (10분)

**이 Step에서 읽지 않는 문서**: cli-design (Step 10c/d), backtesting (Step 11)

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
git commit -m "Step 10b: RiskGuard 변동성/유동성 체크

Observable change: (착수 전 상세화)
Fitness criteria:  2
Port changes:      none
Tests added:       tests/step_10b/test_*.py"
```
