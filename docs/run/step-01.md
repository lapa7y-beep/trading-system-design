# Step 01 — 6파일 분리

## 1. 목적

walking_skeleton.py 단일 파일을 core/nodes/ 6파일 + core/orchestrator.py로 분리. 로직 변경 없이 구조만 재배치.

## 2. 합격 기준 매핑

- Phase 1 합격기준: (기반)
- 기여 방식: Step 2 (Port 추상화)의 전제

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/what/specs/project-structure-phase1.md` — §2 전체 디렉토리 트리, §10 구현 착수 순서 — 폴더 구조 확인 (10분)
2. `docs/how/seam-map.md` — §1 Filter 테이블 — 6 Filter → 6파일 매핑 (3분)

**이 Step에서 읽지 않는 문서**: port-signatures (Step 2), domain-types 상세 (Step 0 완료)

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
git commit -m "Step 01: 6파일 분리

Observable change: (착수 전 상세화)
Fitness criteria:  (기반)
Port changes:      none
Tests added:       tests/step_01/test_*.py"
```
