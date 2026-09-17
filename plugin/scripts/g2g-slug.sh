#!/usr/bin/env bash
# g2g-slug.sh — the sole implementation of the G2G slug derivation.
#
# Turns a spec's `project` field (or a short task summary) into the token
# that names a build branch (`g2g/<slug>`, `g2g/go-<slug>`) and a spec
# file (`specs/<slug>.json`). The input is untrusted text: a project name
# arrives from a prompt, a requirements file, or review-finding text, and
# used to reach `git checkout -b` and `gh pr create` under an informal
# "lowercase, hyphenated form" rule with no charset (F-035). Every
# /g2g:* command that needs a slug calls this; none restates the rule.
#
# Usage: g2g-slug.sh <text>
#        g2g-slug.sh --spec <spec.json>    slug of the spec's .project field
#
# Rule (deterministic, locale-independent):
#   1. ASCII-lowercase;
#   2. every run of characters outside [a-z0-9] becomes ONE hyphen
#      (so non-ASCII letters, punctuation, whitespace, control characters,
#      `/`, `.`, `$`, quotes — all collapse to `-`);
#   3. leading and trailing hyphens are trimmed;
#   4. the result is cut to 60 characters and trimmed again.
# The output therefore always matches ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$,
# which git accepts as a ref component (no `..`, no `@{`, no `.lock`
# suffix, no leading `-`) and every filesystem accepts as a file name.
#
# Exit: 0 slug printed on stdout; 2 usage error, unreadable spec, missing
#       or non-string project field, or nothing slug-worthy in the input.
set -euo pipefail

fail() { echo "g2g-slug: $2" >&2; exit "$1"; }

MAX_LENGTH=60

case "${1:-}" in
    "")
        fail 2 "usage: g2g-slug.sh <text> | g2g-slug.sh --spec <spec.json>"
        ;;
    --spec)
        SPEC="${2:-}"
        [[ -n "$SPEC" && -f "$SPEC" ]] || fail 2 "spec not found: ${SPEC:-<missing>}"
        TEXT=$(jq -er '.project | select(type == "string")' "$SPEC" 2>/dev/null) \
            || fail 2 "spec has no string .project field: $SPEC"
        ;;
    *)
        [[ $# -eq 1 ]] || fail 2 "usage: g2g-slug.sh <text> | g2g-slug.sh --spec <spec.json>"
        TEXT="$1"
        ;;
esac

# LC_ALL=C keeps tr byte-oriented so a multibyte letter is two or three
# "other" bytes that collapse into the same single hyphen everywhere.
SLUG=$(printf '%s' "$TEXT" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -cs 'a-z0-9' '-' \
    | sed -e 's/^-*//' -e 's/-*$//')
SLUG=${SLUG:0:$MAX_LENGTH}
SLUG=${SLUG%"${SLUG##*[!-]}"}

[[ -n "$SLUG" ]] || fail 2 "no slug characters in input (nothing in [a-z0-9] after lowercasing): $TEXT"
printf '%s\n' "$SLUG"
