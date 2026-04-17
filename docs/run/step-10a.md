# Step 10a — RiskGuard 손실한도 (일일/포지션별)

## 1. 목적

RiskGuard에 일일 손실한도와 포지션별 손실한도 2체크 추가.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 2
- 기여 방식: 모의투자 5일 무사고 — 손실 제한 필수

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/what/architecture/path1-phase1.md` — §5 Pre-Order Check 상세 — 손실한도 항목 — 체크 로직 상세 (10분)
2. `docs/what/specs/config-schema-phase1.md` — §5 리스크 관리 — 설정 키 확인 (5분)

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
git commit -m "Step 10a: RiskGuard 손실한도 (일일/포지션별)

Observable change: (착수 전 상세화)
Fitness criteria:  2
Port changes:      none
Tests added:       tests/step_10a/test_*.py"
```
