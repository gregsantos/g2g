#!/usr/bin/env bash
# g2g-learnings-index.sh — the builder-facing index of docs/learnings/.
#
# A fresh-context builder has no memory of earlier builds; the learnings
# store is the curated, human-reviewed record of what earlier builds
# proved (F-006). This script turns that store into a one-line-per-entry
# index a builder can scan before its first edit and then open only the
# learnings whose area or tags touch its task. It reads frontmatter only —
# never a body — so the index stays small however large the store grows,
# and it carries repository facts, never any builder's reasoning.
#
# Same posture as g2g-evidence.sh and g2g-learning-check.sh: header line,
# per-item lines, one summary line, frozen exit codes, no writes, no model
# or network calls. Frontmatter is parsed and validated by the same
# library g2g-learning-check.sh uses, so a learning the checker would call
# invalid is SKIPPED here (and named), never indexed.
#
# Usage: g2g-learnings-index.sh [directory]
#   With no argument, indexes every *.md under docs/learnings/ at the
#   enclosing git worktree root (falling back to $PWD outside a repo).
#   With a directory argument, indexes every *.md found under it.
#
# Output (pinned by tests/plugin_learnings_index.bats):
#   === G2G LEARNINGS INDEX ===
#   <id> | <area> | <severity> | <tags,comma,joined> | <path> | <title>
#   skipped: <path> (invalid frontmatter: <reason>)
#   summary: <N> indexed | <M> skipped
#   === END G2G LEARNINGS INDEX ===
#   Paths are repo-relative when the file lies under the worktree root.
#   Control characters in any field are replaced with spaces, so a
#   learning cannot forge extra index lines.
#
# Exit: 0 index printed (an empty or absent store is a valid, empty
#       index — builders always get the same block shape); 2 the given
#       directory argument does not exist.
set -uo pipefail

fail() { echo "g2g-learnings-index: $2" >&2; exit "$1"; }

# shellcheck source=plugin/scripts/lib/g2g-learning-frontmatter.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/g2g-learning-frontmatter.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$REPO_ROOT" ]] || REPO_ROOT="$PWD"

if [[ $# -gt 0 ]]; then
    [[ -d "$1" ]] || fail 2 "learnings directory not found: $1"
    STORE="$1"
else
    STORE="$REPO_ROOT/docs/learnings"
fi

clean() { printf '%s' "$1" | tr '[:cntrl:]' ' '; }

# Tags arrive comma-joined but keep whatever spacing the file used
# ("[a, b]" vs a block list); emit one canonical "a,b" form.
tag_list() {
    local IFS=',' tag out=""
    for tag in $1; do
        tag="$(g2g_learning_fm_trim "$tag")"
        [[ -n "$tag" ]] || continue
        out="${out:+$out,}$tag"
    done
    printf '%s' "$out"
}

rel_path() {
    case "$1" in
        "$REPO_ROOT"/*) printf '%s' "${1#"$REPO_ROOT"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

INDEXED=0
SKIPPED=0

echo "=== G2G LEARNINGS INDEX ==="

if [[ -d "$STORE" ]]; then
    while IFS= read -r learning_file; do
        [[ -n "$learning_file" ]] || continue
        shown="$(clean "$(rel_path "$learning_file")")"
        if g2g_learning_frontmatter "$learning_file"; then
            echo "$(clean "$fm_id") | $(clean "$fm_area") | $(clean "$fm_severity") | $(clean "$(tag_list "$fm_tags")") | $shown | $(clean "$fm_title")"
            INDEXED=$((INDEXED + 1))
        else
            echo "skipped: $shown (invalid frontmatter: $(clean "$fm_reason"))"
            SKIPPED=$((SKIPPED + 1))
        fi
    done < <(find "$STORE" -type f -name '*.md' 2>/dev/null | sort)
fi

echo "summary: $INDEXED indexed | $SKIPPED skipped"
echo "=== END G2G LEARNINGS INDEX ==="
exit 0
