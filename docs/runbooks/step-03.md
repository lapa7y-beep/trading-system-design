# Step 03 — CSVReplayAdapter

## 1. 목적

FakeMarketData를 CSVReplayAdapter로 교체. 실제 KOSPI 봉(CSV)이 파이프라인에 흐른다.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 1
- 기여 방식: Sharpe > 1.0 — CSV 봉이 있어야 백테스트 가능

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/pipelines/data-collection.md` — §1 정형 데이터 수집 파이프라인 — CSV 파일 포맷·컬럼 확인 (10분)
2. `docs/specs/adapter-spec-phase1.md` — §4.3 CSVReplayAdapter — Adapter 구현 명세 (5분)
3. `docs/specs/domain-types-phase1.md` — §3.3 Market Data (Bar 타입) — 필드 확인 (3분)

**이 Step에서 읽지 않는 문서**: fsm-design (Step 8), db-schema (Step 9)

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
git commit -m "Step 03: CSVReplayAdapter

Observable change: (착수 전 상세화)
Fitness criteria:  1
Port changes:      none
Tests added:       tests/step_03/test_*.py"
```
