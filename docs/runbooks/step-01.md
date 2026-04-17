# Step 01 — 6파일 분리

## 1. 목적

`walking_skeleton.py` 단일 파일을 `atlas/nodes/` 6파일 + `atlas/orchestrator.py`로 분리. 로직 변경 없이 구조만 재배치. 모든 기존 테스트가 그대로 통과해야 한다.

## 2. 합격 기준 매핑

- Phase 1 합격기준: (구조적 경계점 — 직접 기여 없음)
- 기여 방식: Step 2(Port 추상화)의 전제. 파일이 분리되어야 Port/Adapter를 개별 적용 가능.

## 3. 착수 전 체크리스트

- [ ] Step 00 테스트 전부 통과 (`pytest tests/step_00/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/specs/project-structure-phase1.md` — 폴더 구조 섹션 (5분)
   - `atlas/nodes/`, `atlas/orchestrator.py` 경로 확인
2. `docs/references/seam-map.md` — §1 Filter 테이블 (2분)
   - 6 Filter → 6파일 매핑 확인

**이 Step에서 읽지 않는 문서**: ports-phase1.md (Step 2), domain-types 상세 (Step 0에서 완료)

## 5. 작업 단계

1. 디렉토리 생성: `mkdir -p atlas/nodes`
2. `walking_skeleton.py`에서 각 함수/클래스를 개별 파일로 이동:
   - `atlas/nodes/market_data.py` — `market_data()` + Bar
   - `atlas/nodes/indicator.py` — `indicator()`
   - `atlas/nodes/strategy.py` — `strategy()` + Signal
   - `atlas/nodes/risk_guard.py` — `risk_guard()`
   - `atlas/nodes/order_executor.py` — `order_executor()` + Order, Fill
   - `atlas/nodes/trading_fsm.py` — `TradingFSM`
3. `atlas/orchestrator.py` 생성 — `run_once()`만 남기고 import로 연결
4. `atlas/walking_skeleton.py` 삭제 (또는 `orchestrator.py`로 rename)
5. 테스트 수정: import 경로만 변경
6. `pytest tests/step_00/ -v` 통과 확인

## 6. 완료 조건

- [ ] `pytest tests/step_00/ -v` 결과 2 passed (기존 테스트 그대로 통과)
- [ ] `python -m atlas.orchestrator` 실행 시 Step 0와 동일 출력
- [ ] `atlas/nodes/` 디렉토리에 6개 .py 파일 존재
- [ ] `atlas/walking_skeleton.py` 삭제됨 (또는 orchestrator로 대체됨)
- [ ] Port 변경: 해당 없음
- [ ] PROGRESS.md: Step 01 체크

## 7. 커밋

```bash
git add -A
git commit -m "Step 01: Split walking_skeleton.py into 6 node files + orchestrator

Observable change: (structural — behavior unchanged)
Fitness criteria:  (foundation)
Port changes:      none (Ports introduced in Step 02)
Tests added:       none (existing tests pass with updated imports)"
```
