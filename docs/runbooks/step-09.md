# Step 09 — DB 영속화 (PostgreSQL)

## 1. 목적

InMemoryStorageAdapter → PostgresStorageAdapter + StdoutAuditAdapter → PostgresAuditAdapter.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 3
- 기여 방식: P&L 자동 기록 — DB 없으면 기록 불가

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/specs/db-schema-phase1.sql` — 전체 (DDL) — 테이블 구조와 인덱스 (20분)
2. `docs/decisions/006-db-stack.md` — 전체 — PostgreSQL 선정 근거 (5분)
3. `docs/architecture/db-stack.md` — §1~2 확정 스택, 저장 원칙 — 저장 범위 확인 (10분)
4. `docs/specs/adapter-spec-phase1.md` — §6.1 PostgresStorageAdapter, §9.1 PostgresAuditAdapter — Adapter 구현 명세 (10분)

**이 Step에서 읽지 않는 문서**: cli-design (Step 10), backtesting (Step 11)

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
git commit -m "Step 09: DB 영속화 (PostgreSQL)

Observable change: (착수 전 상세화)
Fitness criteria:  3
Port changes:      none
Tests added:       tests/step_09/test_*.py"
```
