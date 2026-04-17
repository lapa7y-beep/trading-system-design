# Step 02 — Port 추상화 도입

## 1. 목적

6 Port ABC 정의 + FakeAdapter + Orchestrator DI 구조 전환. ★ Phase 1 가장 중요한 구조 경계점. 이후 Port 시그니처 불변.

## 2. 합격 기준 매핑

- Phase 1 합격기준: (기반)
- 기여 방식: Plug & Play Principle의 물리적 구현

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료
- [ ] seam-classification §5 체크리스트 7항목 전부 통과

## 4. 참조 문서 (읽을 순서)

1. `docs/specs/port-signatures-phase1.md` — 전체 정독 (§1~6) — 6 Port 모든 메서드 시그니처 (30분)
2. `docs/specs/adapter-spec-phase1.md` — §1 설계 원칙, §2 전체 목록 — 12 Adapter 이름과 매핑 (15분)
3. `docs/specs/config-schema-phase1.md` — §1~2 파일 구조, 전체 스키마 — Enabling Point YAML 키 (15분)
4. `docs/references/seam-classification.md` — §4 매트릭스, §5 체크리스트 — Port 난이도와 사전 조건 (10분)
5. `docs/specs/domain-types-phase1.md` — 전체 20개 타입 — Port 시그니처에 나머지 타입 참조 (15분)

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
git commit -m "Step 02: Port 추상화 도입

Observable change: (착수 전 상세화)
Fitness criteria:  (기반)
Port changes:      none
Tests added:       tests/step_02/test_*.py"
```
