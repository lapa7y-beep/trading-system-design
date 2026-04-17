# Step 00 — Walking Skeleton

## 1. 목적

6 Filter(MarketDataReceiver→IndicatorCalculator→StrategyEngine→RiskGuard→OrderExecutor→TradingFSM)를 pass-through stub으로 관통. "봉 1개→BUY 1번→로그 1줄→FSM IDLE 복귀".

## 2. 합격 기준 매핑

- Phase 1 합격기준: (기반)
- 기여 방식: 이후 Step 3~11의 출발점

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료
- [ ] Python 3.11+ 설치 / pytest 설치 / mkdir -p core tests/step_00

## 4. 참조 문서 (읽을 순서)

1. `docs/decisions/012-implementation-methodology.md` — §4 어휘, §6 Step 0 행 — 방법론 이해 (5분)
2. `docs/architecture/path1-phase1.md` — §2 6노드 설계 — 각 노드의 입출력만 — 6 Filter 이름과 역할 (10분)
3. `docs/architecture/system-overview.md` — 전체 — 시스템 전체 그림 파악 (5분)
4. `docs/specs/domain-types-phase1.md` — §3.1~3.5 (Primitives~Order) — Bar, Signal, Order, Fill 4타입만 (5분)

**이 Step에서 읽지 않는 문서**: port-signatures (Step 2), fsm-design (Step 8), db-schema (Step 9), cli-design (Step 10)

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
git commit -m "Step 00: Walking Skeleton

Observable change: (착수 전 상세화)
Fitness criteria:  (기반)
Port changes:      none
Tests added:       tests/step_00/test_*.py"
```
