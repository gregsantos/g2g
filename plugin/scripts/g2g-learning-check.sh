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
# Usage: g2g-learning-check.sh [path-to-learning.md]
#   With an argument, validates exactly that file.
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

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$REPO_ROOT" ]] || REPO_ROOT="$PWD"

TARGET="${1:-}"

FILES=()
if [[ -n "$TARGET" ]]; then
    [[ -f "$TARGET" ]] || fail 2 "learning file not found: $TARGET"
    FILES+=("$TARGET")
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

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

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

    if [[ ! -f "$learning_file" ]]; then
        echo "frontmatter: INVALID file disappeared before it could be read: $learning_file"
        INVALID_COUNT=$((INVALID_COUNT + 1))
        continue
    fi

    first_line="$(sed -n '1p' "$learning_file")"
    if [[ "$first_line" != "---" ]]; then
        echo "frontmatter: INVALID missing opening --- delimiter"
        INVALID_COUNT=$((INVALID_COUNT + 1))
        continue
    fi

    fm_end="$(awk 'NR>1 && $0=="---"{print NR; exit}' "$learning_file")"
    if [[ -z "$fm_end" ]]; then
        echo "frontmatter: INVALID missing closing --- delimiter"
        INVALID_COUNT=$((INVALID_COUNT + 1))
        continue
    fi

    # Reset per-file frontmatter fields.
    fm_id="" fm_title="" fm_date="" fm_track="" fm_area="" fm_severity=""
    fm_tags="" fm_symptoms="" fm_rootcause="" fm_resolution=""
    reason=""
    last_list_key=""

    while IFS= read -r fm_line; do
        if [[ "$fm_line" =~ ^([A-Za-z][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="$(trim "${BASH_REMATCH[2]}")"
            last_list_key="$key"
            case "$key" in
                id) fm_id="$value" ;;
                title) fm_title="$value" ;;
                date) fm_date="$value" ;;
                track) fm_track="$value" ;;
                area) fm_area="$value" ;;
                severity) fm_severity="$value" ;;
                tags)
                    value="${value#\[}"; value="${value%\]}"
                    fm_tags="$value"
                    ;;
                symptoms) fm_symptoms="$value" ;;
                rootCause) fm_rootcause="$value" ;;
                resolution) fm_resolution="$value" ;;
                *) ;;
            esac
        elif [[ "$fm_line" =~ ^[[:space:]]*-[[:space:]]+(.*)$ ]]; then
            item="$(trim "${BASH_REMATCH[1]}")"
            case "$last_list_key" in
                tags)
                    if [[ -n "$fm_tags" ]]; then fm_tags="$fm_tags,$item"; else fm_tags="$item"; fi
                    ;;
                *) ;;
            esac
        fi
    done < <(sed -n "2,$((fm_end - 1))p" "$learning_file")

    [[ -n "$fm_id" ]] || reason="missing required field: id"
    [[ -n "$reason" || "$fm_id" =~ ^L-[0-9]{3,}$ ]] || reason="id does not match L-NNN: $fm_id"
    [[ -n "$reason" || -n "$fm_title" ]] || reason="missing required field: title"
    [[ -n "$reason" || -n "$fm_date" ]] || reason="missing required field: date"
    [[ -n "$reason" || "$fm_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || reason="date is not YYYY-MM-DD: $fm_date"
    [[ -n "$reason" || -n "$fm_track" ]] || reason="missing required field: track"
    [[ -n "$reason" || "$fm_track" == "bug" || "$fm_track" == "knowledge" ]] || reason="track must be bug or knowledge: $fm_track"
    [[ -n "$reason" || -n "$fm_area" ]] || reason="missing required field: area"
    if [[ -z "$reason" ]]; then
        case "$fm_area" in
            commands|agents|scripts|hooks|templates|tests|evals|ci|config|docs) ;;
            *) reason="area not in enum: $fm_area" ;;
        esac
    fi
    [[ -n "$reason" || -n "$fm_severity" ]] || reason="missing required field: severity"
    if [[ -z "$reason" ]]; then
        case "$fm_severity" in
            critical|high|medium|low) ;;
            *) reason="severity not in enum: $fm_severity" ;;
        esac
    fi
    [[ -n "$reason" || -n "$fm_tags" ]] || reason="missing required field: tags (must be non-empty)"

    if [[ -z "$reason" ]]; then
        if [[ "$fm_track" == "bug" ]]; then
            [[ -n "$fm_symptoms" ]] || reason="bug track missing required field: symptoms"
            [[ -n "$reason" || -n "$fm_rootcause" ]] || reason="bug track missing required field: rootCause"
            [[ -n "$reason" || -n "$fm_resolution" ]] || reason="bug track missing required field: resolution"
        elif [[ "$fm_track" == "knowledge" ]]; then
            if [[ -n "$fm_symptoms" || -n "$fm_rootcause" || -n "$fm_resolution" ]]; then
                reason="knowledge track must omit symptoms/rootCause/resolution"
            fi
        fi
    fi

    if [[ -n "$reason" ]]; then
        echo "frontmatter: INVALID $reason"
        INVALID_COUNT=$((INVALID_COUNT + 1))
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
