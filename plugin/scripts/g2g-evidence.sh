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

task_line='.tasks[] | (.id + " [" + (if .passes == true then "passed" else .status end) + "] " + .title)'
if [[ "$TOTAL" -le 12 ]]; then
    jq -r "$task_line" "$SPEC"
else
    echo "passed tasks omitted: $PASSED"
    jq -r ".tasks[] | select(.passes != true) | (.id + \" [\" + .status + \"] \" + .title)" "$SPEC"
fi

VERIFY_ALL_OK=1
FIRST_FAIL_CMD=""
FIRST_FAIL_CODE=""
if [[ "$MODE" == "--full" ]]; then
    while IFS= read -r cmd; do
        code=0
        bash -c "$cmd" >/dev/null 2>&1 || code=$?
        echo "verify: $cmd -> exit $code"
        if [[ "$code" -ne 0 && "$VERIFY_ALL_OK" -eq 1 ]]; then
            VERIFY_ALL_OK=0
            FIRST_FAIL_CMD="$cmd"
            FIRST_FAIL_CODE="$code"
        fi
    done < <(jq -r '.context.verificationCommands[]' "$SPEC")
fi

VERIFIER_VERDICT=$(jq -r '.verifier.verdict // "PENDING"' "$SPEC")
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
