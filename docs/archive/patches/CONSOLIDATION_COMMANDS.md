# ATLAS Phase 1 통폐합 — Git 명령어 모음

> 저장소 루트에서 순서대로 실행하세요.
> **중요**: 각 단계 끝에 `git status`로 확인하면서 진행하세요.

---

## 사전 준비

```bash
# 저장소 루트로 이동 (실제 경로로 바꾸세요)
cd ~/myProject/trading-system-design

# 현재 상태 확인
git status
git log --oneline -5

# 안전하게 브랜치 생성
git checkout -b consolidation/phase1-2026-04-16

# 현재 저장소의 실제 파일 구조 확인 (이게 스크립트와 다르면 경로 조정 필요)
find . -type f -name "*.md" | grep -v node_modules | grep -v .git | sort
find . -type f -name "*.yaml" | grep -v node_modules | grep -v .git | sort
```

---

## Step 1: Archive 폴더 생성

```bash
mkdir -p docs/archive/phase2plus
mkdir -p docs/archive/phase3
mkdir -p docs/archive/patches
```

---

## Step 2: Phase 2+ 로 이동 (경로 확인 후 실행)

**먼저 아래 파일들이 저장소에 있는지 확인:**

```bash
ls -la \
  docs/port_interface_path3_v1.0.md \
  docs/port_interface_path4_v1.0.md \
  docs/port_interface_path5_v1.0.md \
  docs/port_interface_path6_v1.0.md \
  docs/blueprints/node_blueprint_path2to6_v1.0.md \
  docs/specs/shared_store_ddl_v1.0.md \
  docs/specs/shared_domain_types_v1.0.md \
  docs/specs/edge_contract_definition_v1.0.md \
  docs/specs/order_lifecycle_spec_v1.0.md \
  docs/specs/system_manifest_v1.0.md \
  2>&1 | grep -v "^ls:"
```

**실제 경로를 확인 후:**

```bash
# Path 2~6 Port Interfaces
git mv docs/port_interface_path3_v1.0.md docs/archive/phase2plus/
git mv docs/port_interface_path4_v1.0.md docs/archive/phase2plus/
git mv docs/port_interface_path5_v1.0.md docs/archive/phase2plus/
git mv docs/port_interface_path6_v1.0.md docs/archive/phase2plus/

# Blueprint 전체 (Path 2-6)
git mv docs/blueprints/node_blueprint_path2to6_v1.0.md docs/archive/phase2plus/

# 전체 스펙 (축약판이 Phase 1 신규 문서에 있음)
git mv docs/specs/shared_store_ddl_v1.0.md docs/archive/phase2plus/
git mv docs/specs/shared_domain_types_v1.0.md docs/archive/phase2plus/
git mv docs/specs/edge_contract_definition_v1.0.md docs/archive/phase2plus/
git mv docs/specs/order_lifecycle_spec_v1.0.md docs/archive/phase2plus/
git mv docs/specs/system_manifest_v1.0.md docs/archive/phase2plus/
```

---

## Step 3: Phase 3 로 이동 (LLM·지식그래프)

```bash
git mv docs/port_interface_path2_v1.0.md docs/archive/phase3/
git mv docs/specs/graph_ir_agent_extension_v1.0.md docs/archive/phase3/
git mv docs/boundary_definition_v1.0.md docs/archive/phase3/
git mv docs/decisions/009-cross-validation.md docs/archive/phase3/
git mv docs/decisions/010-llm-storage-code-generator.md docs/archive/phase3/
git mv docs/specs/llm-role.md docs/archive/phase3/
```

---

## Step 4: Patches 로 이동 (반영 완료 델타)

```bash
git mv docs/specs/architecture_deep_review_v1.0.md docs/archive/patches/
git mv docs/specs/architecture_review_patch_v1.0.md docs/archive/patches/
git mv docs/specs/architecture_reinforcement_patch_v2.0.md docs/archive/patches/
git mv docs/specs/path_reinforcement_v1.0.md docs/archive/patches/
git mv docs/specs/session_summary_20260416.md docs/archive/patches/

# 폐기된 placeholder graph_ir
git mv graph_ir_v1.0.yaml docs/archive/patches/
```

---

## Step 5: Path 1 Blueprint 는 특별 처리 (분할)

기존 `node_blueprint_path1_v1.0.md`는 Phase 1 노드 6개 + Phase 2+ 노드 7개가 섞여 있습니다.

**옵션 A (간단)**: 일단 archive로 옮기고, `path1-phase1.md`를 메인으로 사용

```bash
git mv docs/blueprints/node_blueprint_path1_v1.0.md docs/archive/phase2plus/
```

**옵션 B (정확)**: 수동으로 Phase 1 노드 6개 부분만 추출해서 `docs/blueprints/path1-phase1-blueprint.md` 로 저장 후 원본은 archive

→ 옵션 A 권장. 구현 시 Phase 1 디테일은 `path1-phase1.md`에 모두 있음.

---

## Step 6: 여기서 중간 커밋 (권장)

```bash
git status
git commit -m "docs: move Phase 2+ documents to archive

Per docs/decisions/011-phase1-scope.md, move out-of-Phase-1 documents to:
- docs/archive/phase2plus/ (Path 3-6, full specs)
- docs/archive/phase3/ (LLM, knowledge graph)
- docs/archive/patches/ (completed delta documents)

No files deleted. All preserved for Phase 2+ restoration."
```

---

## Step 7: 신규 Phase 1 문서 배치

출력 폴더(`atlas-phase1/`)의 9개 파일을 저장소에 복사. **원본 위치는 신규이므로 `git add`**.

```bash
# 출력 폴더가 ~/Downloads/atlas-phase1 에 있다고 가정
SRC=~/Downloads/atlas-phase1

# 최상위
cp $SRC/README.md ./README.md
cp $SRC/INDEX.md ./INDEX.md
cp $SRC/graph_ir_phase1.yaml ./graph_ir_phase1.yaml

# docs/
cp $SRC/docs/decisions/011-phase1-scope.md     docs/decisions/
cp $SRC/docs/architecture/path1-phase1.md      docs/architecture/
cp $SRC/docs/architecture/cli-design.md        docs/architecture/
cp $SRC/docs/specs/domain-types-phase1.md      docs/specs/
cp $SRC/docs/specs/db-schema-phase1.sql        docs/specs/
cp $SRC/docs/archive/README.md                 docs/archive/

# 확인
git status
```

> **주의**: 기존 `README.md`와 `INDEX.md`가 있으면 `cp`는 덮어씁니다. 기존 것을 보관하고 싶으면 먼저 `git mv README.md docs/archive/patches/README_pre_phase1.md` 하세요.

---

## Step 8: 최종 커밋

```bash
git add .
git diff --cached --stat

git commit -m "docs: add Phase 1 consolidated design

New active documents (Phase 1 scope):
- README.md (rewritten, Phase 1 centered)
- INDEX.md (rewritten, new structure)
- graph_ir_phase1.yaml (Single Source of Truth, was placeholder)
- docs/decisions/011-phase1-scope.md (scope confirmation)
- docs/architecture/path1-phase1.md (6-node detail design)
- docs/architecture/cli-design.md (atlas CLI, replaces Telegram)
- docs/specs/domain-types-phase1.md (20 Pydantic types)
- docs/specs/db-schema-phase1.sql (6 tables, executable DDL)
- docs/archive/README.md (archive rationale)

Phase 1 scope: MockBroker + single strategy E2E + paper trading.
Active node count reduced from 45 (claimed) to 6 (verified).
Active edge count reduced from 95 to 14."
```

---

## Step 9: Push & PR

```bash
git push -u origin consolidation/phase1-2026-04-16
```

GitHub 웹에서 PR 생성 → main 머지.

---

## 검증 (머지 전 또는 후)

```bash
# 활성 문서가 예상 수치와 일치하는지
python3 -c "
import yaml
g = yaml.safe_load(open('graph_ir_phase1.yaml'))
print('Nodes:', len(g['nodes']), '(expected 6)')
print('Edges:', len(g['edges']), '(expected 14)')
print('Ports:', len(g['ports']), '(expected 6)')
print('Stores:', len(g['shared_stores']), '(expected 3)')
"

# Archive 문서가 의도대로 이동됐는지
ls docs/archive/phase2plus/ | wc -l    # 기대: 10 내외
ls docs/archive/phase3/ | wc -l         # 기대: 6 내외
ls docs/archive/patches/ | wc -l        # 기대: 6 내외

# 활성 문서에 Phase 2+ 용어가 남아있지 않은지 (교차 검증)
grep -rn -iE "screener|watchlistmanager|langgraph|telegram|approvalgate" \
    --include="*.md" docs/ README.md INDEX.md \
    | grep -v "docs/archive/" \
    | grep -v "Phase 2" \
    | grep -v "Phase 3" \
    | grep -v "제외" \
    | grep -v "연기" \
    | grep -v "Phase 1 제외" \
    | grep -v "deferred"
# 이 grep의 결과가 비어있어야 함 (용어가 "제외" 문맥 외엔 안 나와야 함)
```

---

## 롤백 (문제 시)

```bash
# 커밋하기 전이라면
git checkout .

# 커밋 후, push 전이라면
git reset --hard HEAD~1

# push 후, PR 머지 전이라면
git push --force-with-lease origin consolidation/phase1-2026-04-16

# 머지 후면 revert PR
git revert <commit-sha>
```

---

## 트러블슈팅

**Q. `git mv` 가 "does not exist" 에러**
→ 원본 파일 경로가 다릅니다. `find . -name "파일명"` 으로 실제 위치 확인 후 경로 수정.

**Q. 일부 파일이 저장소에 애초에 없음**
→ 무시. 이 문서 리스트는 이전 대화에서 언급된 것 기준이라, 실제로 만들지 않은 파일이 섞여있을 수 있습니다. 없는 건 건너뛰면 됩니다.

**Q. 파일 이름이 버전 suffix 없이 있음 (예: `port_interface_path2.md`)**
→ 저장소 실제 이름으로 명령어 수정. 핵심은 **파일을 archive로 옮기는 것**이지 이름 매칭이 아닙니다.

**Q. 경로가 `docs/` 가 아닌 다른 구조** (예: `architecture/design/`)
→ `find` 로 실제 경로 찾은 뒤 명령어 경로 대체.

---

*End of Git Commands — Phase 1 Consolidation*
