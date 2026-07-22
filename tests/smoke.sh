#!/usr/bin/env bash
# Behavioral smoke test: run a real headless /g2g:build against a throwaway
# sandbox repo and assert on the artifacts it must produce. Costs real API
# dollars (~$1-3) and several minutes — run via `make smoke`, deliberately
# NOT part of `make check` (which is this repo's verificationCommands and
# re-runs constantly during builds).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/../plugin"
WORK="$(mktemp -d /tmp/g2g-smoke-XXXXXX)"
SB="$WORK/sandbox"

fail() {
    echo "SMOKE FAIL: $1"
    echo "sandbox preserved for inspection at: $WORK (run log: $WORK/run.log)"
    exit 1
}

bash "$SCRIPT_DIR/make_sandbox.sh" "$SB" > /dev/null
git init -q --bare "$WORK/origin.git"
git -C "$SB" remote add origin "$WORK/origin.git"
git -C "$SB" push -q -u origin main

echo "smoke: building specs/sandbox.json headlessly (caps: 25 turns / \$8, several minutes)..."
# PR creation is expected to fail here (origin is a local bare repo, not
# GitHub), so the claude exit code is not the signal — the artifacts are.
(
    cd "$SB" && claude -p "/g2g:build specs/sandbox.json" \
        --plugin-dir "$PLUGIN_DIR" \
        --permission-mode acceptEdits \
        --allowedTools "Agent,Bash,Read,Write,Edit,Glob,Grep" \
        --setting-sources project \
        --max-turns 25 \
        --max-budget-usd 8 \
        > "$WORK/run.log" 2>&1
) || true

SPEC="$SB/specs/sandbox.json"
BRANCH="g2g/sandbox-greeting"

jq -e 'all(.tasks[]; .passes == true and .status == "complete")' "$SPEC" > /dev/null \
    || fail "not all tasks passed in specs/sandbox.json"
jq -e '.verifier.verdict == "PASS"' "$SPEC" > /dev/null \
    || fail "verifier verdict is not PASS in specs/sandbox.json"
[[ ! -f "$SB/.g2g-goal" ]] \
    || fail ".g2g-goal was not deleted at the terminal state"
git -C "$SB" rev-parse --verify "$BRANCH" > /dev/null 2>&1 \
    || fail "work branch $BRANCH was not created"
git -C "$WORK/origin.git" rev-parse --verify "$BRANCH" > /dev/null 2>&1 \
    || fail "work branch $BRANCH was not pushed to origin"
(cd "$SB" && git checkout -q "$BRANCH" && ./verify.sh > /dev/null) \
    || fail "verify.sh does not pass on the work branch"

echo "smoke: PASS"
rm -rf "$WORK"
