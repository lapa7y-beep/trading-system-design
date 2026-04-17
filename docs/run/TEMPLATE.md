# Step NN — <한 줄 제목>

## 1. 목적

<이 Step이 만드는 관찰 가능한 변화. 1~3문장.>

## 2. 합격 기준 매핑

- Phase 1 합격기준: <번호와 내용>
- 기여 방식: <어떻게 기여하는가>

## 3. 착수 전 체크리스트

- [ ] 이전 Step(N-1)의 테스트 전부 통과
- [ ] <Step 고유의 전제조건>
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `<파일경로>` — `<섹션명>` — <왜 읽는가> (N분)
2. ...

**이 Step에서 읽지 않는 문서**: <명시적 제외>

## 5. 작업 단계

1. <구체적 파일 생성/수정>
2. ...
N. 테스트 실행: `pytest tests/step_NN/ -v`

## 6. 완료 조건 (전부 통과해야 커밋)

- [ ] 관찰 기준: <구체적 관찰>
- [ ] 테스트: `pytest tests/step_NN/ -v` 녹색
- [ ] Port 불변: Port 시그니처 변경 없음
- [ ] seam-map.md: 해당 Stub 행 갱신 완료
- [ ] PROGRESS.md: 체크박스 + Daily Log

## 7. 커밋

```
git add -A
git commit -m "Step NN: <제목>

Observable change: <관찰 변화>
Fitness criteria:  <합격기준 번호>
Port changes:      none
Tests added:       tests/step_NN/test_*.py"
```
