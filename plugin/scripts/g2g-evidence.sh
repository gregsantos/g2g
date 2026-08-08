#!/usr/bin/env bash
# g2g-evidence.sh — deterministic evidence block for the G2G goal evaluator.
# Usage: g2g-evidence.sh <spec.json> [--full]
# Exit: 0 evidence printed; 2 missing/invalid spec; 3 no verificationCommands.
set -euo pipefail

SPEC="${1:-}"
MODE="${2:-}"

fail() { echo "g2g-evidence: $2" >&2; exit "$1"; }

[[ -n "$SPEC" && -f "$SPEC" ]] || fail 2 "spec not found: ${SPEC:-<missing>}"
jq empty "$SPEC" 2>/dev/null || fail 2 "spec is not valid JSON: $SPEC"

# The task counts and per-task lines below iterate .tasks unguarded; a
# missing/null/non-array value (or a non-object entry) is a malformed
# spec, and without this gate jq's runtime error would kill the script
# with an undocumented exit 5 under set -e (F-019).
jq -e '.tasks | type == "array" and all(.[]?; type == "object")' "$SPEC" >/dev/null \
    || fail 2 "tasks must be an array of task objects: $SPEC"

# verificationCommands must be an array of non-empty single-line strings.
# A malformed value is an invalid spec (exit 2), not an empty one: a bare
# length check passes a string, and jq's failed iteration inside process
# substitution is invisible to set -e — the verify loop would run zero
# times and 'proven' could be earned without running anything. A command
# containing control characters could also inject verdict-shaped lines
# into the block, so both die here before any output is printed.
jq -e '(.context.verificationCommands // [])
       | type == "array"
         and all(.[]?; type == "string" and length > 0 and (test("[[:cntrl:]]") | not))' \
    "$SPEC" >/dev/null \
    || fail 2 "context.verificationCommands must be an array of non-empty single-line command strings: $SPEC"
VERIFY_COUNT=$(jq '(.context.verificationCommands // []) | length' "$SPEC")
[[ "$VERIFY_COUNT" -gt 0 ]] || fail 3 "context.verificationCommands is missing or empty — builds are unverifiable without it"

TOTAL=$(jq '.tasks | length' "$SPEC")
PASSED=$(jq '[.tasks[] | select(.passes == true)] | length' "$SPEC")
IN_PROGRESS=$(jq '[.tasks[] | select(.passes != true and .status == "in_progress")] | length' "$SPEC")
PENDING=$(jq '[.tasks[] | select(.passes != true and .status == "pending")] | length' "$SPEC")
BLOCKED=$(jq '[.tasks[] | select(.passes != true and .status == "blocked")] | length' "$SPEC")

echo "=== G2G EVIDENCE ==="
echo "spec: $SPEC"
# Bind the evidence to a tree state so the block attests WHAT was
# verified, not just that something was. Outside a git work tree (or
# before the first commit) the line degrades to "head: none" so the
# frozen format stays deterministic everywhere the script runs.
HEAD_SHA=$(git rev-parse --short HEAD 2>/dev/null || true)
if [[ -n "$HEAD_SHA" ]]; then
    DIRTY=$(git status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d '[:space:]')
    echo "head: $HEAD_SHA (tracked-dirty: $DIRTY)"
else
    echo "head: none"
fi
echo "tasks: $TOTAL total | $PASSED passed | $IN_PROGRESS in_progress | $PENDING pending | $BLOCKED blocked"

# Task ids, statuses, and titles come from the spec JSON; gsub strips
# control characters so spec-controlled text can never fabricate a line
# of the block (e.g. an embedded "\nverdict: ..." inside a title).
task_line='.tasks[] | (.id + " [" + (if .passes == true then "passed" else .status end) + "] " + .title) | gsub("[[:cntrl:]]"; " ")'
if [[ "$TOTAL" -le 12 ]]; then
    jq -r "$task_line" "$SPEC"
else
    echo "passed tasks omitted: $PASSED"
    jq -r '.tasks[] | select(.passes != true) | (.id + " [" + .status + "] " + .title) | gsub("[[:cntrl:]]"; " ")' "$SPEC"
fi

VERIFY_ALL_OK=1
VERIFY_EXECUTED=0
FIRST_FAIL_CMD=""
FIRST_FAIL_CODE=""
VERIFIER_PRE=$(jq -r '(.verifier.verdict // "PENDING") | tostring' "$SPEC" 2>/dev/null || echo "unreadable")
if [[ "$MODE" == "--full" ]]; then
    while IFS= read -r cmd; do
        code=0
        bash -c "$cmd" >/dev/null 2>&1 || code=$?
        echo "verify: $cmd -> exit $code"
        VERIFY_EXECUTED=$((VERIFY_EXECUTED + 1))
        if [[ "$code" -ne 0 && "$VERIFY_ALL_OK" -eq 1 ]]; then
            VERIFY_ALL_OK=0
            FIRST_FAIL_CMD="$cmd"
            FIRST_FAIL_CODE="$code"
        fi
    done < <(jq -r '.context.verificationCommands[]' "$SPEC")
fi

# 'proven' must describe the state that was verified. Verification commands
# are arbitrary shell: one may rewrite tracked files, move HEAD, or edit the
# spec's own completion facts while still exiting 0 — and this script read
# those facts BEFORE running anything. Any drift across the run forfeits
# 'proven'; the verdict names it instead of blessing the post-run state.
STATE_DRIFT=""
if [[ "$MODE" == "--full" ]]; then
    HEAD_AFTER=$(git rev-parse --short HEAD 2>/dev/null || true)
    if [[ "$HEAD_AFTER" != "$HEAD_SHA" ]]; then
        STATE_DRIFT="head ${HEAD_SHA:-none} -> ${HEAD_AFTER:-none}"
    elif [[ -n "$HEAD_SHA" ]]; then
        DIRTY_AFTER=$(git status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d '[:space:]')
        if [[ "$DIRTY_AFTER" != "$DIRTY" ]]; then
            STATE_DRIFT="tracked-dirty $DIRTY -> $DIRTY_AFTER"
        fi
    fi
    if [[ -z "$STATE_DRIFT" ]]; then
        TOTAL_AFTER=$(jq '.tasks | length' "$SPEC" 2>/dev/null || echo "unreadable")
        PASSED_AFTER=$(jq '[.tasks[] | select(.passes == true)] | length' "$SPEC" 2>/dev/null || echo "unreadable")
        VERIFIER_AFTER=$(jq -r '(.verifier.verdict // "PENDING") | tostring' "$SPEC" 2>/dev/null || echo "unreadable")
        if [[ "$TOTAL_AFTER" != "$TOTAL" || "$PASSED_AFTER" != "$PASSED" ]]; then
            STATE_DRIFT="task counts"
        elif [[ "$VERIFIER_AFTER" != "$VERIFIER_PRE" ]]; then
            STATE_DRIFT="verifier field"
        fi
    fi
fi

VERIFIER_VERDICT=$(jq -r '(.verifier.verdict // "PENDING") | tostring | gsub("[[:cntrl:]]"; " ")' "$SPEC")
echo "verifier: $VERIFIER_VERDICT"

# Graded, machine-stable verdict line (F-045/F-043). 'proven' requires
# this very run to have executed every verification command and seen
# every one exit 0; 'assumed' rests solely on spec bookkeeping (status
# mode never runs verification commands, so it can never earn 'proven').
ALL_TASKS_PASS=0
if [[ "$TOTAL" -ge 1 && "$PASSED" -eq "$TOTAL" ]]; then
    ALL_TASKS_PASS=1
fi

if [[ "$MODE" == "--full" ]]; then
    if [[ "$ALL_TASKS_PASS" -ne 1 ]]; then
        echo "verdict: incomplete [tasks $PASSED/$TOTAL]"
    elif [[ "$VERIFY_ALL_OK" -ne 1 ]]; then
        echo "verdict: incomplete [tasks $PASSED/$TOTAL; verify: $FIRST_FAIL_CMD -> exit $FIRST_FAIL_CODE]"
    elif [[ "$VERIFY_EXECUTED" -ne "$VERIFY_COUNT" ]]; then
        # Belt-and-braces: 'proven' asserts every DECLARED command ran in
        # this process, so a command enumeration that dies mid-stream
        # (invisible to set -e inside process substitution) must not
        # leave a clean-looking loop counted as full verification.
        echo "verdict: incomplete [tasks $PASSED/$TOTAL; verify: executed $VERIFY_EXECUTED/$VERIFY_COUNT commands]"
    elif [[ -n "$STATE_DRIFT" ]]; then
        echo "verdict: incomplete [tasks $PASSED/$TOTAL; state changed during verify: $STATE_DRIFT]"
    elif [[ "$VERIFIER_VERDICT" != "PASS" ]]; then
        echo "verdict: incomplete [tasks $PASSED/$TOTAL; verify all exit 0; verifier $VERIFIER_VERDICT]"
    else
        echo "verdict: complete (proven) [tasks $PASSED/$TOTAL; verify all exit 0; verifier PASS]"
    fi
else
    if [[ "$ALL_TASKS_PASS" -ne 1 ]]; then
        echo "verdict: incomplete [tasks $PASSED/$TOTAL]"
    elif [[ "$VERIFIER_VERDICT" != "PASS" ]]; then
        echo "verdict: incomplete [tasks $PASSED/$TOTAL; verifier $VERIFIER_VERDICT]"
    else
        echo "verdict: complete (assumed) [tasks $PASSED/$TOTAL; verify not run; verifier PASS]"
    fi
fi

echo "=== END G2G EVIDENCE ==="
