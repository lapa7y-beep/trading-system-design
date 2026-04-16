#!/usr/bin/env bash
# ============================================================================
# ATLAS — 통폐합 후 이슈 3건 + 수치 수정 정리
# 저장소 루트 (trading-system-design/) 에서 실행
# ============================================================================
set -euo pipefail

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Issue 1: port_interface_path1_v2.0.md → archive"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -f "docs/port_interface_path1_v2.0.md" ]]; then
    git mv docs/port_interface_path1_v2.0.md docs/archive/phase2plus/
    echo "  [ok] → docs/archive/phase2plus/"
else
    echo "  [skip] 파일 없음"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Issue 2: node_blueprint_path1_v1.0.md → archive"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -f "docs/blueprints/node_blueprint_path1_v1.0.md" ]]; then
    git mv docs/blueprints/node_blueprint_path1_v1.0.md docs/archive/phase2plus/
    echo "  [ok] → docs/archive/phase2plus/"
else
    echo "  [skip] 파일 없음"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Issue 3: 통폐합 도구 파일 → archive"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for f in CONSOLIDATION_COMMANDS.md consolidate.sh; do
    if [[ -f "$f" ]]; then
        git mv "$f" docs/archive/patches/
        echo "  [ok] $f → docs/archive/patches/"
    else
        echo "  [skip] $f 없음"
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Issue 4: INDEX.md + path1-phase1.md Edges 수치 수정"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# INDEX.md: "약 12" → "14"
if [[ -f "INDEX.md" ]]; then
    sed -i '' 's/| Edges | \*\*약 12\*\*/| Edges | **14**/' INDEX.md
    echo "  [ok] INDEX.md: Edges 약 12 → 14"
fi

# path1-phase1.md: 섹션 제목 "약 12개" → "14개"
if [[ -f "docs/architecture/path1-phase1.md" ]]; then
    sed -i '' 's/엣지 (약 12개)/엣지 (14개)/' docs/architecture/path1-phase1.md
    echo "  [ok] path1-phase1.md: 약 12개 → 14개"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "검증"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# archive에 이동된 파일 수
echo "  archive/phase2plus 파일 수: $(ls docs/archive/phase2plus/ 2>/dev/null | wc -l | tr -d ' ')"
echo "  archive/patches 파일 수:    $(ls docs/archive/patches/ 2>/dev/null | wc -l | tr -d ' ')"

# 활성 영역에 Phase 2+ 전용 파일이 남아있지 않은지
STALE=$(find docs/ -maxdepth 2 -name "port_interface_path*" -not -path "*/archive/*" 2>/dev/null)
if [[ -z "$STALE" ]]; then
    echo "  [ok] 활성 영역에 port_interface 잔류 파일 없음"
else
    echo "  [warn] 잔류 파일 발견: $STALE"
fi

BLUEPRINT=$(find docs/blueprints/ -name "*.md" 2>/dev/null)
if [[ -z "$BLUEPRINT" ]]; then
    echo "  [ok] docs/blueprints/ 비어있음 (Phase 1은 path1-phase1.md 사용)"
else
    echo "  [warn] blueprints 잔류: $BLUEPRINT"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "완료 — 아래 명령어로 커밋하세요:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "git add -A && git status"
