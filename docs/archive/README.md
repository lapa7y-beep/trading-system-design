# Archive — Phase 2+ 범위 문서

이 폴더에는 **Phase 1 범위 밖**이지만 설계 가치가 있어 보관하는 문서들이 모여 있다.

**폐기가 아니다.** Phase 2 이후 해당 경로/기능을 활성화할 때 다시 꺼내서 참고한다.

**기준 문서**: [`../decisions/011-phase1-scope.md`](../decisions/011-phase1-scope.md)

---

## 폴더 구조

```
archive/
├── README.md          — 이 파일
├── phase2plus/        — Phase 2 이후 일반
├── phase3/            — Phase 3 (LLM·지식그래프) 전용
└── patches/           — 반영 완료된 델타 문서
```

---

## phase2plus/

**언제 다시 볼까**: Phase 1 합격 기준 통과 후 Phase 2 시작할 때.

| 파일 | 원래 위치 | Phase 2 사용 용도 |
|------|---------|----------------|
| `port_interface_path3_v1.0.md` | `docs/` | Strategy Development 경로 설계 재개 시 |
| `port_interface_path4_v1.0.md` | `docs/` | Portfolio Management 도입 시 |
| `port_interface_path5_v1.0.md` | `docs/` | Full Watchdog 체계 도입 시 |
| `port_interface_path6_v1.0.md` | `docs/` | Market Intelligence (MarketContext, VI, CB) 도입 시 |
| `node_blueprint_path2to6_v1.0.md` | `docs/blueprints/` | 위 Path들의 노드 청사진 |
| `node_blueprint_path1_v1.0_rest.md` | `docs/blueprints/` | Screener/WatchlistManager 등 Path 1의 연기된 7노드 |
| `shared_store_ddl_v1.0.md` | `docs/specs/` | 34테이블 중 Phase 1 6개 제외 28개 DDL |
| `shared_domain_types_v1.0.md` | `docs/specs/` | 86타입 중 Phase 1 20개 제외 66개 |
| `edge_contract_definition_v1.0.md` | `docs/specs/` | 95 엣지 전체 계약 |
| `order_lifecycle_spec_v1.0.md` | `docs/specs/` | 24 주문유형/정정/취소/예약 |
| `system_manifest_v1.0.md` | `docs/specs/` | 43노드 전체 Manifest |

---

## phase3/

**언제 다시 볼까**: Phase 3 진입 시 (전략 자동생성·지식그래프 활성화).

| 파일 | 이유 |
|------|------|
| `port_interface_path2_v1.0.md` | Knowledge Building — LLM·온톨로지 전제 |
| `graph_ir_agent_extension_v1.0.md` | LangGraph agent 확장 |
| `009-cross-validation.md` | 원본에 "Phase 5 이후" 명시됨 |
| `010-llm-storage-code-generator.md` | LLM 저장 방식 + Code Generator |
| `llm-role.md` | LLM의 시스템 내 역할 정의 |
| `boundary_definition_v1.0.md` | LLM-시스템 경계 (Phase 3+에서만 의미) |

---

## patches/

**이 폴더의 문서는 모두 "반영 완료"이거나 "선별 반영 후 기록용"이다.**

| 파일 | 상태 |
|------|------|
| `architecture_deep_review_v1.0.md` | 분석 기록 — 주요 지적사항은 `011-phase1-scope.md`와 개별 문서에 반영됨 |
| `architecture_review_patch_v1.0.md` | W1(Redis 분리) Phase 2로 이월 — 나머지는 Phase 1에 불필요 |
| `architecture_reinforcement_patch_v2.0.md` | 17 패치 중 Phase 1 해당분(Four Critical Safeguards 일부)만 채택 |
| `path_reinforcement_v1.0.md` | R1(TradingContext 개념)만 Phase 1 반영 — 나머지 R2~R6 연기 |
| `session_summary_20260416.md` | 세션 기록 |

**주의**: 새 패치 문서를 만들지 말 것. 변경이 필요하면 **원본을 직접 수정하고 git diff로 추적**한다. Patch 문서가 쌓이는 패턴이 Phase 1 통폐합 이전의 문제였다.

---

## Archive에서 파일을 꺼낼 때

1. Phase 2 진입 승인 (합격 기준 5개 통과 확인)
2. 해당 Phase 2 범위 확정 문서를 먼저 작성 (`012-phase2-scope.md` 등)
3. archive에서 필요한 문서 `git mv`로 복원
4. 복원된 문서는 Phase 2 범위에 맞춰 **개정** (그대로 사용 금지)
5. 개정 이력을 원본 문서 상단 "변경 이력"에 기록

---

## Archive 원칙

- **삭제 없음** — 공부한 내용은 전부 자산이다
- **재작성 없음** — Archive 문서는 "그 시점의 사고 기록"으로 보존
- **새 버전은 원래 위치에** — Phase 2에 다시 쓸 때는 원본을 복원 후 수정

---

*Last updated: 2026-04-16*
