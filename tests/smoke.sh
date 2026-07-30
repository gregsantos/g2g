#!/usr/bin/env bash
# Behavioral smoke test: run a real headless /g2g:build against a throwaway
# sandbox repo and assert on the artifacts it must produce. Costs real API
# dollars (~$1-3) and several minutes — run via `make smoke`, deliberately
# NOT part of `make check` (which is this repo's verificationCommands and
# re-runs constantly during builds).
#
# `smoke.sh --assert-only <preserved-work-dir>` re-runs just the assertions
# against a sandbox a previous run left behind, with no API spend. Use it when
# a run failed and you have changed the assertions, or to inspect a partial.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/../plugin"

ASSERT_ONLY=""
if [[ "${1:-}" == "--assert-only" ]]; then
    ASSERT_ONLY="${2:-}"
    [[ -n "$ASSERT_ONLY" && -d "$ASSERT_ONLY" ]] \
        || { echo "usage: smoke.sh --assert-only <preserved-work-dir>"; exit 2; }
    WORK="$ASSERT_ONLY"
else
    WORK="$(mktemp -d /tmp/g2g-smoke-XXXXXX)"
fi
SB="$WORK/sandbox"

fail() {
    echo "SMOKE FAIL: $1"
    echo "sandbox preserved for inspection at: $WORK (run log: $WORK/run.log)"
    exit 1
}

if [[ -z "$ASSERT_ONLY" ]]; then
    bash "$SCRIPT_DIR/make_sandbox.sh" "$SB" > /dev/null
    git init -q --bare "$WORK/origin.git"
    git -C "$SB" remote add origin "$WORK/origin.git"
    git -C "$SB" push -q -u origin main
fi

if [[ -z "$ASSERT_ONLY" ]]; then
echo "smoke: building specs/sandbox.json headlessly (caps: 80 turns / \$20, several minutes)..."
# PR creation is expected to fail here (origin is a local bare repo, not
# GitHub), so the claude exit code is not the signal — the artifacts are.
# The outer cap has to clear the inner one with room to spare: the lock
# protocol's per-turn choreography made 25 hit the outer guillotine after
# the build succeeded but before terminal cleanup, and 40 only ever had to
# cover an inner TURN_CAP of 4. The sandbox now runs at TURN_CAP 8 so the
# verifier -> fix -> re-verify loop is reachable (see make_sandbox.sh), so
# the outer budget doubles with it.
(
    cd "$SB" && claude -p "/g2g:build specs/sandbox.json" \
        --plugin-dir "$PLUGIN_DIR" \
        --permission-mode acceptEdits \
        --allowedTools "Agent,Bash,Read,Write,Edit,Glob,Grep" \
        --setting-sources project \
        --max-turns 80 \
        --max-budget-usd 20 \
        > "$WORK/run.log" 2>&1
) || true
fi

SPEC="$SB/specs/sandbox.json"
BRANCH="g2g/sandbox-greeting"

# --- machinery invariants: these must hold on EVERY run ----------------------
#
# What this gate is for is the plugin's machinery, not the sandbox builders'
# code quality. A build that ends PARTIAL because the verifier found a real
# bug, or because a subagent dispatch was interrupted, has exercised the
# protocol correctly and must not be reported as a harness failure — both of
# those happened in real runs and both were legitimate. Conflating the two
# made this gate unpassable except when two throwaway tasks happened to come
# out clean on the first attempt, which is not something worth gating on.
#
# Every check below is about the protocol: did the run reach a terminal state
# and clean up after itself? Set SMOKE_REQUIRE_COMPLETE=1 to additionally
# demand a fully green build (all tasks passed and verifier PASS).

jq -e . "$SPEC" > /dev/null 2>&1 \
    || fail "specs/sandbox.json is missing or no longer parses"
jq -e 'all(.tasks[]; .status != "in_progress")' "$SPEC" > /dev/null \
    || fail "a task was left in_progress — the build abandoned work mid-task"
jq -e 'all(.tasks[]; .status != null)' "$SPEC" > /dev/null \
    || fail "a task has no status — spec bookkeeping did not survive the run"
[[ ! -f "$SB/.g2g-goal" ]] \
    || fail ".g2g-goal was not deleted at the terminal state"
[[ ! -f "$SB/.g2g-goal.lock" ]] \
    || fail ".g2g-goal.lock was not deleted at the terminal state"
[[ ! -d "$SB/.g2g-goal.mutex" ]] \
    || fail ".g2g-goal.mutex was left held at the terminal state"
git -C "$SB" rev-parse --verify "$BRANCH" > /dev/null 2>&1 \
    || fail "work branch $BRANCH was not created"
git -C "$WORK/origin.git" rev-parse --verify "$BRANCH" > /dev/null 2>&1 \
    || fail "work branch $BRANCH was not pushed to origin"
(cd "$SB" && git checkout -q "$BRANCH" && ./verify.sh > /dev/null) \
    || fail "verify.sh does not pass on the work branch"

# --- outcome: reported, and gated only on request ----------------------------

TASKS_TOTAL=$(jq -r '.tasks | length' "$SPEC")
TASKS_PASSED=$(jq -r '[.tasks[] | select(.passes == true)] | length' "$SPEC")
VERDICT=$(jq -r '.verifier.verdict // "PENDING"' "$SPEC")

if [[ "$TASKS_PASSED" == "$TASKS_TOTAL" && "$VERDICT" == "PASS" ]]; then
    OUTCOME="COMPLETE"
else
    OUTCOME="PARTIAL"
fi

echo "smoke: outcome=$OUTCOME (tasks $TASKS_PASSED/$TASKS_TOTAL passed, verifier $VERDICT)"

if [[ "${SMOKE_REQUIRE_COMPLETE:-0}" == "1" && "$OUTCOME" != "COMPLETE" ]]; then
    fail "SMOKE_REQUIRE_COMPLETE=1 but the build ended $OUTCOME"
fi

echo "smoke: PASS (protocol invariants held)"
[[ "$OUTCOME" == "COMPLETE" ]] \
    || echo "smoke: note — partial build preserved for inspection at: $WORK"
[[ "$OUTCOME" != "COMPLETE" ]] || rm -rf "$WORK"
