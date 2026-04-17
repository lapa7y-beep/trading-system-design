# Step 06 — RiskGuard 포지션 한도 1체크

## 1. 목적

RiskGuard return True를 실제 포지션 한도 체크로 교체. 첫 주문 거부 발생 가능.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 2
- 기여 방식: 모의투자 5일 무사고 — 리스크 체크 없으면 무사고 불가

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/what/architecture/path1-phase1.md` — §2.4 RiskGuard, §5 Pre-Order Check 상세 — 리스크 체크 항목 중 포지션 한도만 (10분)
2. `docs/what/specs/error-handling-phase1.md` — §3.4 RiskGuard — RiskGuard 에러 처리 규칙 (5분)

**이 Step에서 읽지 않는 문서**: RiskGuard 나머지 6체크 (Step 10a/10b)

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
git commit -m "Step 06: RiskGuard 포지션 한도 1체크

Observable change: (착수 전 상세화)
Fitness criteria:  2
Port changes:      none
Tests added:       tests/step_06/test_*.py"
```
