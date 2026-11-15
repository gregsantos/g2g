#!/usr/bin/env bash
# g2g-learning-check.sh — deterministic grounding validator for docs/learnings/.
#
# A learning that enters the store becomes trusted knowledge a future agent
# acts on WITHOUT re-verifying, so every claim it makes is checked against
# the working tree before it compounds. This script REPORTS what it finds;
# it never edits a file, never calls a model, and never resolves a flag
# itself — a flagged run is not a failure of the learning (learnings
# legitimately cite deleted paths and pre-fix states). Adjudication is the
# caller's job. Same posture as g2g-evidence.sh and g2g-stop.sh: header
# line, per-item lines, a single summary line, frozen exit codes, no writes.
#
# Usage: g2g-learning-check.sh [path-to-learning.md|path-to-directory]
#   With a file argument, validates exactly that file.
#   With a directory argument, validates every *.md file found under it
#   (recursively) — same expansion the no-argument form uses.
#   With no argument, validates every *.md file under docs/learnings/.
#
# Mechanical checks per file:
#   (a) frontmatter parses and carries every required field for its
#       declared track, with enum values and a YYYY-MM-DD date.
#   (b) every repo-relative path cited in the body (backtick-quoted,
#       slash-bearing) exists in the working tree.
#   (c) every 7-40 char hex commit SHA cited in the body resolves, AND is
#       reachable from the upstream default branch — a SHA reachable only
#       from HEAD is a DISTINCT flag from one that does not resolve at all.
#   (d) no drafting scaffold remains: a `{{` mustache, a bare TODO, or the
#       literal pattern "Learning <digit>".
#   (e) every relative markdown link target resolves.
#
# Exit: 0 all checks clean; 2 a learning file is missing or its frontmatter
#       is invalid; 3 no learning files found to check; 4 at least one flag
#       raised requiring human adjudication.
set -uo pipefail

fail() { echo "g2g-learning-check: $2" >&2; exit "$1"; }

# shellcheck source=plugin/scripts/lib/g2g-learning-frontmatter.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/g2g-learning-frontmatter.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$REPO_ROOT" ]] || REPO_ROOT="$PWD"

TARGET="${1:-}"

FILES=()
if [[ -n "$TARGET" ]]; then
    if [[ -f "$TARGET" ]]; then
        FILES+=("$TARGET")
    elif [[ -d "$TARGET" ]]; then
        while IFS= read -r found_file; do
            [[ -n "$found_file" ]] || continue
            FILES+=("$found_file")
        done < <(find "$TARGET" -type f -name '*.md' 2>/dev/null | sort)
    else
        fail 2 "learning file not found: $TARGET"
    fi
else
    while IFS= read -r found_file; do
        [[ -n "$found_file" ]] || continue
        FILES+=("$found_file")
    done < <(find "$REPO_ROOT/docs/learnings" -type f -name '*.md' 2>/dev/null | sort)
fi
[[ ${#FILES[@]} -gt 0 ]] || fail 3 "no learning files found to check"

# Resolve the upstream default branch once. A SHA that resolves as a commit
# but cannot be checked against this is reported as head-only rather than
# silently passed — no upstream ref to compare against is the SAME kind of
# uncertainty as "not yet on the default branch" (F-061's merge-never-squash
# rationale: a local-only commit is one squash-merge away from unreachable).
UPSTREAM_REF=""
resolved_symref="$(git -C "$REPO_ROOT" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
if [[ -n "$resolved_symref" ]]; then
    UPSTREAM_REF="${resolved_symref#refs/remotes/}"
else
    for candidate in origin/main origin/master; do
        if git -C "$REPO_ROOT" rev-parse -q --verify "$candidate" >/dev/null 2>&1; then
            UPSTREAM_REF="$candidate"
            break
        fi
    done
fi

FILE_COUNT=0
INVALID_COUNT=0
FLAG_COUNT=0
CLEAN_COUNT=0

echo "=== G2G LEARNING CHECK ==="

for learning_file in "${FILES[@]}"; do
    FILE_COUNT=$((FILE_COUNT + 1))
    echo "file: $learning_file"

    file_invalid=0
    file_flags=0

    # (a) frontmatter — the shared parser is the one definition of the
    # schema (lib/g2g-learning-frontmatter.sh). Status 2 means there is
    # no body to read, so the remaining checks are skipped for this file.
    fm_status=0
    g2g_learning_frontmatter "$learning_file" || fm_status=$?
    if [[ "$fm_status" -ne 0 ]]; then
        echo "frontmatter: INVALID $fm_reason"
        INVALID_COUNT=$((INVALID_COUNT + 1))
        [[ "$fm_status" -ne 2 ]] || continue
        file_invalid=1
    else
        echo "frontmatter: ok (track=$fm_track, area=$fm_area)"
    fi

    body_start=$((fm_end + 1))
    body="$(sed -n "${body_start},\$p" "$learning_file")"
    learning_dir="$(dirname "$learning_file")"

    # (b) repo-relative paths cited in backticks.
    while IFS= read -r raw_token; do
        [[ -n "$raw_token" ]] || continue
        token="${raw_token#\`}"
        token="${token%\`}"
        [[ -n "$token" ]] || continue
        case "$token" in
            *://*|*'<'*|*'>'*|*' '*) continue ;;
        esac
        [[ "$token" == */* ]] || continue
        if [[ ! "$token" =~ ^[A-Za-z0-9._/-]+$ ]]; then
            continue
        fi
        # An absolute path (leading slash) is never repo-relative — it is
        # legitimately a system/toolchain path (e.g. `/opt/homebrew/bin/bash`)
        # and resolving it against REPO_ROOT would misreport it as a missing
        # repo path, pressuring authors to de-backtick real, verifiable paths.
        [[ "$token" == /* ]] && continue
        if [[ -e "$REPO_ROOT/$token" ]]; then
            echo "path: \`$token\` -> ok"
        else
            echo "path: \`$token\` -> FLAG missing (no such path in the working tree)"
            file_flags=$((file_flags + 1))
        fi
    done < <(printf '%s\n' "$body" | grep -oE "\`[^\`]+\`" | sort -u)

    # (c) commit SHAs: 7-40 hex chars, must contain at least one digit to
    # keep English words (all a-f letters) from being mistaken for a SHA.
    while IFS= read -r sha; do
        [[ -n "$sha" ]] || continue
        sha_lower="$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')"
        [[ "$sha_lower" =~ [0-9] ]] || continue
        resolved_full="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${sha_lower}^{commit}" 2>/dev/null || true)"
        if [[ -z "$resolved_full" ]]; then
            echo "sha: $sha -> FLAG unresolved (does not resolve to a commit)"
            file_flags=$((file_flags + 1))
            continue
        fi
        if [[ -n "$UPSTREAM_REF" ]] && git -C "$REPO_ROOT" merge-base --is-ancestor "$resolved_full" "$UPSTREAM_REF" 2>/dev/null; then
            echo "sha: $sha -> ok (reachable from $UPSTREAM_REF)"
        else
            echo "sha: $sha -> FLAG head-only (resolves but is not reachable from the upstream default branch)"
            file_flags=$((file_flags + 1))
        fi
    done < <(printf '%s\n' "$body" | grep -oiE '\b[0-9a-f]{7,40}\b' | sort -u)

    # (d) drafting scaffold left over from a batch-capture run.
    scaffold_line=0
    while IFS= read -r line_text; do
        scaffold_line=$((scaffold_line + 1))
        if [[ "$line_text" == *'{{'* ]]; then
            echo "scaffold: FLAG mustache {{ at body line $scaffold_line"
            file_flags=$((file_flags + 1))
        fi
        if [[ "$line_text" =~ (^|[^A-Za-z0-9_])TODO($|[^A-Za-z0-9_]) ]]; then
            echo "scaffold: FLAG bare TODO at body line $scaffold_line"
            file_flags=$((file_flags + 1))
        fi
        if [[ "$line_text" =~ Learning\ [0-9] ]]; then
            echo "scaffold: FLAG \"Learning <digit>\" placeholder at body line $scaffold_line"
            file_flags=$((file_flags + 1))
        fi
    done < <(printf '%s\n' "$body")

    # (e) relative markdown link targets.
    while IFS= read -r link_target; do
        [[ -n "$link_target" ]] || continue
        case "$link_target" in
            http://*|https://*|mailto:*|\#*) continue ;;
        esac
        target_path="${link_target%%#*}"
        [[ -n "$target_path" ]] || continue
        if [[ -e "$learning_dir/$target_path" || -e "$REPO_ROOT/$target_path" ]]; then
            echo "link: $link_target -> ok"
        else
            echo "link: $link_target -> FLAG missing (no such path in the working tree)"
            file_flags=$((file_flags + 1))
        fi
    done < <(printf '%s\n' "$body" | grep -oE '\]\([^)]+\)' | sed -E 's/^\]\(//; s/\)$//' | sort -u)

    FLAG_COUNT=$((FLAG_COUNT + file_flags))
    if [[ "$file_invalid" -eq 0 && "$file_flags" -eq 0 ]]; then
        CLEAN_COUNT=$((CLEAN_COUNT + 1))
    fi
done

echo "summary: $FILE_COUNT files | $INVALID_COUNT invalid | $FLAG_COUNT flagged | $CLEAN_COUNT clean"
echo "=== END G2G LEARNING CHECK ==="

if [[ "$INVALID_COUNT" -gt 0 ]]; then
    exit 2
elif [[ "$FLAG_COUNT" -gt 0 ]]; then
    exit 4
else
    exit 0
fi
