#!/usr/bin/env bash
# ============================================================================
# ATLAS Phase 1 Consolidation — Archive Migration Script
# ============================================================================
# 작성일: 2026-04-16
# 목적: Phase 2+ 범위 문서를 docs/archive/ 하위로 이동
# 기준: docs/decisions/011-phase1-scope.md
#
# 사용법:
#   1. 저장소 루트에서 실행
#   2. 먼저 --dry-run 으로 실제 이동할 파일 확인
#   3. 문제없으면 인자 없이 실행
#
#   ./consolidate.sh --dry-run   # 미리보기
#   ./consolidate.sh             # 실제 이동
# ============================================================================

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "🔍 DRY-RUN MODE — 실제 이동하지 않음"
    echo ""
fi

# 저장소 루트 확인
if [[ ! -d ".git" ]]; then
    echo "❌ 이 스크립트는 git 저장소 루트에서 실행해야 합니다."
    exit 1
fi

# 현재 브랜치 확인
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "📍 현재 브랜치: $CURRENT_BRANCH"

if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    echo ""
    echo "⚠️  main/master 브랜치에서 실행 중입니다."
    echo "   권장: git checkout -b consolidation/phase1-2026-04-16"
    read -p "   계속하시겠습니까? [y/N]: " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
fi

# ---------------------------------------------------------------------------
# Step 1: Archive 폴더 생성
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Archive 폴더 구조 생성"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for dir in docs/archive/phase2plus docs/archive/phase3 docs/archive/patches; do
    if [[ -d "$dir" ]]; then
        echo "  [skip] $dir (이미 존재)"
    else
        if $DRY_RUN; then
            echo "  [dry]  mkdir -p $dir"
        else
            mkdir -p "$dir"
            echo "  [ok]   $dir"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Step 2: 이동 대상 파일 목록
# ---------------------------------------------------------------------------
# 형식: "원본 경로|대상 폴더|분류 사유"
# 원본 경로는 실제 저장소 구조에 맞게 조정 필요할 수 있음

declare -a MOVES=(
    # --- phase2plus (Phase 2 이후 복원 예정) ---
    "docs/port_interface_path3_v1.0.md|docs/archive/phase2plus/|Path 3 자동생성 연기"
    "docs/port_interface_path4_v1.0.md|docs/archive/phase2plus/|Path 4 Portfolio 연기"
    "docs/port_interface_path5_v1.0.md|docs/archive/phase2plus/|Path 5 Full Watchdog 연기"
    "docs/port_interface_path6_v1.0.md|docs/archive/phase2plus/|Path 6 MarketIntelligence 연기"
    "docs/blueprints/node_blueprint_path2to6_v1.0.md|docs/archive/phase2plus/|Path 2-6 blueprint 연기"
    "docs/specs/shared_store_ddl_v1.0.md|docs/archive/phase2plus/|34 테이블 전체 DDL (Phase 1은 6개)"
    "docs/specs/shared_domain_types_v1.0.md|docs/archive/phase2plus/|86 타입 전체 (Phase 1은 20개)"
    "docs/specs/edge_contract_definition_v1.0.md|docs/archive/phase2plus/|95 엣지 전체 (Phase 1은 14개)"
    "docs/specs/order_lifecycle_spec_v1.0.md|docs/archive/phase2plus/|24 주문유형 (Phase 1은 4개)"
    "docs/specs/system_manifest_v1.0.md|docs/archive/phase2plus/|43 노드 전체 Manifest"

    # --- phase3 (LLM·지식그래프 관련) ---
    "docs/port_interface_path2_v1.0.md|docs/archive/phase3/|Knowledge Building (LLM 전제)"
    "docs/specs/graph_ir_agent_extension_v1.0.md|docs/archive/phase3/|LangGraph 확장"
    "docs/boundary_definition_v1.0.md|docs/archive/phase3/|LLM-시스템 경계"
    "docs/decisions/009-cross-validation.md|docs/archive/phase3/|원본에 Phase 5+ 명시"
    "docs/decisions/010-llm-storage-code-generator.md|docs/archive/phase3/|LLM 저장 + Code Generator"
    "docs/specs/llm-role.md|docs/archive/phase3/|LLM 역할 정의"

    # --- patches (반영 완료된 델타) ---
    "docs/specs/architecture_deep_review_v1.0.md|docs/archive/patches/|분석 기록"
    "docs/specs/architecture_review_patch_v1.0.md|docs/archive/patches/|W1만 Phase 2 이월"
    "docs/specs/architecture_reinforcement_patch_v2.0.md|docs/archive/patches/|17 패치 중 선별 반영"
    "docs/specs/path_reinforcement_v1.0.md|docs/archive/patches/|R1만 Phase 1 반영"
    "docs/specs/session_summary_20260416.md|docs/archive/patches/|세션 기록"

    # --- 폐기된 graph_ir 원본 (placeholder) ---
    "graph_ir_v1.0.yaml|docs/archive/patches/|placeholder — graph_ir_phase1.yaml 로 대체"
)

# ---------------------------------------------------------------------------
# Step 3: 파일 존재 여부 확인
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: 이동 대상 파일 존재 여부 확인"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

declare -a VALID_MOVES=()
declare -a MISSING=()

for entry in "${MOVES[@]}"; do
    IFS='|' read -r src dst reason <<< "$entry"
    if [[ -f "$src" ]]; then
        VALID_MOVES+=("$entry")
        echo "  [found]   $src"
    else
        MISSING+=("$src")
        echo "  [missing] $src"
    fi
done

echo ""
echo "  존재 확인: ${#VALID_MOVES[@]} 개"
echo "  찾지 못함: ${#MISSING[@]} 개"

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ""
    echo "⚠️  찾지 못한 파일 목록 (저장소 구조가 예상과 다를 수 있음):"
    for m in "${MISSING[@]}"; do
        echo "     - $m"
    done
    echo ""
    echo "   → 실제 경로를 확인 후 스크립트 수정 필요"
fi

if [[ ${#VALID_MOVES[@]} -eq 0 ]]; then
    echo ""
    echo "❌ 이동할 파일이 없습니다. 경로를 확인하세요:"
    echo "   find . -name '*.md' | grep -E '(path[2-6]|blueprint|shared_|edge_contract|order_lifecycle|system_manifest|boundary|llm-role|agent_extension|review|reinforcement|session_summary)'"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: git mv 실행
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: git mv 실행"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! $DRY_RUN; then
    echo ""
    read -p "${#VALID_MOVES[@]} 개 파일을 이동합니다. 계속? [y/N]: " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && echo "취소됨" && exit 0
fi

MOVED=0
FAILED=0
for entry in "${VALID_MOVES[@]}"; do
    IFS='|' read -r src dst reason <<< "$entry"
    filename=$(basename "$src")

    if $DRY_RUN; then
        echo "  [dry]  git mv '$src' '$dst$filename'"
    else
        if git mv "$src" "$dst$filename" 2>/dev/null; then
            echo "  [ok]   $filename → $dst"
            MOVED=$((MOVED + 1))
        else
            echo "  [fail] $src"
            FAILED=$((FAILED + 1))
        fi
    fi
done

# ---------------------------------------------------------------------------
# Step 5: 결과 요약
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if $DRY_RUN; then
    echo "DRY-RUN 결과:"
    echo "  이동 예정:    ${#VALID_MOVES[@]} 파일"
    echo "  실패 예정:    ${#MISSING[@]} 파일 (원본 없음)"
    echo ""
    echo "실제 실행하려면 --dry-run 없이 다시 실행하세요."
else
    echo "실제 이동:"
    echo "  성공:         $MOVED 파일"
    echo "  실패:         $FAILED 파일"
    echo ""
    echo "다음 단계:"
    echo "  1. git status 로 변경 확인"
    echo "  2. docs/archive/README.md 가 폴더에 있는지 확인 (없으면 outputs/ 에서 복사)"
    echo "  3. Phase 1 신규 문서 복사:"
    echo "       - README.md (최상위, 재작성본)"
    echo "       - INDEX.md (최상위, 재작성본)"
    echo "       - graph_ir_phase1.yaml (최상위, 신규)"
    echo "       - docs/decisions/011-phase1-scope.md (신규)"
    echo "       - docs/architecture/path1-phase1.md (신규)"
    echo "       - docs/architecture/cli-design.md (신규)"
    echo "       - docs/specs/domain-types-phase1.md (신규)"
    echo "       - docs/specs/db-schema-phase1.sql (신규)"
    echo "       - docs/archive/README.md (신규)"
    echo "  4. git add . && git commit -m 'docs: Phase 1 scope consolidation'"
    echo "  5. git push origin consolidation/phase1-2026-04-16"
    echo "  6. PR 생성 → main 머지"
fi
