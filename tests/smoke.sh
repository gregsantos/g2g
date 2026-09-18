#!/usr/bin/env bash
# Behavioral smoke test: run a real headless g2g build against a throwaway
# sandbox repo and assert on the artifacts it must produce. Costs real API
# dollars (~$1-5) and several minutes — run via `make smoke` (the
# /g2g:build engine) or `make smoke-wf` (the experimental /g2g:build-wf
# engine), deliberately NOT part of `make check` (which is this repo's
# verificationCommands and re-runs constantly during builds).
#
# Both engines share this one script — the sandbox, the invocation shape,
# and every assertion — so "smoke parity" between them holds by
# construction rather than by keeping two files in step. The engine changes
# only the slash command, the allowed-tool list (build-wf needs Workflow),
# and one extra assertion: that the Workflow tool actually ran the shipped
# build-loop workflow, so the wrapper cannot pass by emulating the loop in
# prose (build-wf.md forbids exactly that).
#
#   smoke.sh [--engine build|build-wf]      run a build, then assert
#   smoke.sh --assert-only <preserved-dir>  re-run just the assertions
#
# --assert-only re-checks a sandbox a previous run left behind, with no API
# spend. Use it when a run failed and you have changed the assertions, or
# to inspect a partial. It reads the engine from <preserved-dir>/engine,
# which every run writes; a preserved dir from before that file existed is
# treated as a build-engine run, and a file holding anything but a known
# engine fails rather than silently dropping the build-wf assertions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/../plugin"

usage() {
    echo "usage: smoke.sh [--engine build|build-wf]"
    echo "       smoke.sh --assert-only <preserved-work-dir>"
}

ENGINE="build"
ENGINE_FLAG=""
ASSERT_ONLY=""
ASSERT_ONLY_SET=0   # whether the flag appeared — tracked apart from its value
while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            ENGINE="$2"; ENGINE_FLAG="$2"; shift 2 ;;
        --assert-only)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            ASSERT_ONLY="$2"; ASSERT_ONLY_SET=1; shift 2 ;;
        *)
            usage; exit 2 ;;
    esac
done
case "$ENGINE" in
    build|build-wf) ;;
    *) usage; exit 2 ;;
esac

# Every decision below keys on ASSERT_ONLY_SET, never on the value being
# non-empty: `--assert-only "$DIR"` with DIR unset must be a usage error,
# not a fresh $20 build.
if (( ASSERT_ONLY_SET )); then
    [[ -n "$ASSERT_ONLY" && -d "$ASSERT_ONLY" ]] || { usage; exit 2; }
    # The engine is whatever the preserved run recorded; a flag that
    # contradicted it would have to be ignored, so the combination is
    # refused rather than resolved silently.
    [[ -z "$ENGINE_FLAG" ]] || { usage; exit 2; }
    WORK="$ASSERT_ONLY"
else
    WORK="$(mktemp -d /tmp/g2g-smoke-XXXXXX)"
fi
SB="$WORK/sandbox"

fail() {
    echo "SMOKE FAIL: $1"
    echo "sandbox preserved for inspection at: $WORK (run log: $WORK/run.log," \
         "stream-json — one event per line; e.g. jq -r '.message.content[]?.text? // empty' run.log)"
    exit 1
}

# --assert-only: the engine is read back from the file the run wrote. A
# missing file is a preserved dir from before the file existed (build
# engine); a present file with anything but a known engine is a corrupted
# record and FAILS — silently falling back would skip the Workflow gate
# and report PASS on the shared checks alone.
if (( ASSERT_ONLY_SET )); then
    if [[ -f "$WORK/engine" ]]; then
        ENGINE="$(tr -d '[:space:]' < "$WORK/engine")"
        case "$ENGINE" in
            build|build-wf) ;;
            *) fail "engine file $WORK/engine holds '$ENGINE' — expected build or build-wf; refusing to guess which assertions apply" ;;
        esac
    else
        ENGINE="build"
    fi
fi

deregister_sandbox_plugin() {
    # Make this a one-shot cleanup when invoked by the EXIT trap.
    trap - EXIT
    ( cd "$SB" && claude plugin uninstall g2g@g2g -s project --keep-data ) \
        > /dev/null 2>&1 \
        || echo "smoke: warn — could not deregister project-scope plugin row for $SB"
}

# Per-engine invocation. Everything not listed here is identical for both.
#
# The outer --max-turns has to clear the inner cap with room to spare: the
# lock protocol's per-turn choreography made 25 hit the outer guillotine
# after the build succeeded but before terminal cleanup, and 40 only ever
# had to cover an inner TURN_CAP of 4. The sandbox now runs at TURN_CAP 8
# so the verifier -> fix -> re-verify loop is reachable (see
# make_sandbox.sh), so the outer budget is 80. build-wf spends far fewer
# outer turns in Phase 3 (the whole loop is one Workflow call) but runs
# build.md's Phases 1, 2, 4, and 5 verbatim in the main transcript, so it
# gets the same budget rather than a tighter one — a cap hit before
# terminal cleanup wastes the whole run, and the cap is a guillotine, not a
# target. Override with SMOKE_MAX_TURNS when tuning.
BASE_TOOLS="Agent,Bash,Read,Write,Edit,Glob,Grep"
MAX_TURNS="${SMOKE_MAX_TURNS:-80}"
case "$ENGINE" in
    build)
        COMMAND="/g2g:build"
        ALLOWED_TOOLS="$BASE_TOOLS" ;;
    build-wf)
        COMMAND="/g2g:build-wf"
        ALLOWED_TOOLS="$BASE_TOOLS,Workflow" ;;
esac

if (( ! ASSERT_ONLY_SET )); then
    bash "$SCRIPT_DIR/make_sandbox.sh" "$SB" > /dev/null
    git init -q --bare "$WORK/origin.git"
    git -C "$SB" remote add origin "$WORK/origin.git"
    git -C "$SB" push -q -u origin main
    echo "$ENGINE" > "$WORK/engine"
fi

if (( ! ASSERT_ONLY_SET )); then
echo "smoke: building specs/sandbox.json headlessly with $COMMAND (caps: $MAX_TURNS turns / \$20, several minutes)..."
# PR creation is expected to fail here (origin is a local bare repo, not
# GitHub), so the claude exit code is not the signal — the artifacts are.
# stream-json (which print mode only allows with --verbose) makes the run
# log one JSON event per line, so the assertions below can see which tools
# the orchestrator actually invoked rather than trusting its prose.
trap deregister_sandbox_plugin EXIT
(
    cd "$SB" && claude -p "$COMMAND specs/sandbox.json" \
        --plugin-dir "$PLUGIN_DIR" \
        --permission-mode acceptEdits \
        --allowedTools "$ALLOWED_TOOLS" \
        --setting-sources project \
        --output-format stream-json \
        --verbose \
        --max-turns "$MAX_TURNS" \
        --max-budget-usd 20 \
        > "$WORK/run.log" 2>&1
) || true

# The run above resolves $SB's .claude/settings.json enabledPlugins entry,
# which auto-registers a project-scope row for $SB in the global plugin
# registry (~/.claude/plugins/installed_plugins.json). That row has no
# functional effect on this or any other run (the build loads the plugin via
# --plugin-dir), but nothing prunes it once $SB is deleted below, so it's
# cleaned up here rather than left to accumulate across runs. --assert-only
# never invokes claude, so a preserved PARTIAL sandbox doesn't need the row.
deregister_sandbox_plugin
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

# --- engine invariant: build-wf must have run the loop on the runtime --------
#
# build-wf.md's whole point is that the task loop is enforced by
# plugin/workflows/g2g-build.js, not by orchestrator prose; it tells the
# model to STOP and point at /g2g:build when the runtime is unavailable,
# never to emulate the loop by hand. The artifact checks above cannot tell
# the two apart — an emulated loop produces the same branch and spec — so
# the run log is checked for a real Workflow launch of the shipped loop:
#
#   1. NO Workflow tool_use anywhere carries an inline `script` or a
#      `scriptPath` — either is the model running its own loop, and it is
#      rejected even when a legitimate named launch also exists.
#   2. At least one Workflow tool_use names the shipped workflow EXACTLY
#      (`g2g:build-loop`, as observed in the first live run) and carries
#      every arg g2g-build.js validates before dispatching an agent, each
#      non-null and non-empty and `tasks` a non-empty array; a request
#      failing that throws at invocation and ran nothing.
#   3. That request hands the loop at least one sandbox task the loop
#      would actually dispatch — a port of g2g-build.js's nextEligible():
#      an id from the spec, not blocked, `passes` not true, every
#      dependsOn id passed — and a turnCap the loop's first turn clears
#      (the script increments before `turn >= turnCap`, so 1 returns
#      cap-turns untouched). Otherwise the loop returns complete/blocked/
#      cap-turns with zero dispatches — which is how a wrapper that built
#      (or half-built) by hand first and launched the workflow afterwards
#      would look. At least one eligible task, not all: a
#      `--continue-branch` resume legitimately hands over a mix.
#   4. That request has a paired tool_result (same tool_use id) that is
#      not an error. The live result is "Workflow launched in background";
#      the loop's OUTCOME arrives later as a task notification that never
#      enters the event stream, so launch success is the most the log can
#      prove — completion is what the artifact checks above are for.
#
# At least one qualifying launch, not exactly one: a re-invocation is not
# a protocol failure, and an exact count would flake.
#
# If this fires with zero invocations on a run that otherwise looks
# terminal, the likeliest cause is the Workflow tool being unavailable to
# the headless session (runtime disabled, or the plugin's workflows/ dir
# not loaded) and build-wf refusing as designed — the gate has caught the
# engine not being exercised, which is what it is for, not a harness bug.
WORKFLOW_NAME="g2g:build-loop"
# Mirrors the required-arg list in plugin/workflows/g2g-build.js;
# tests/smoke_harness.bats pins the two lists equal.
WORKFLOW_REQUIRED_ARGS=(specPath ownerToken pluginRoot branch turnCap hoursCap buildStart tasks)

# stderr shares run.log with the event stream, so non-JSON lines are
# skipped rather than aborting jq.
run_events() {
    jq -cR 'fromjson? // empty' "$WORK/run.log" 2>/dev/null
}
workflow_tool_uses() {
    run_events | jq -c 'select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and .name == "Workflow")
        | {id: .id, input: (.input // {})}'
}
succeeded_tool_result_ids() {
    run_events | jq -r 'select(.type == "user")
        | .message.content[]?
        | select(.type == "tool_result" and ((.is_error // false) == false))
        | .tool_use_id'
}
count_lines() { grep -c . || true; }

if [[ "$ENGINE" == "build-wf" ]]; then
    WF_ALL=$(workflow_tool_uses | count_lines)
    WF_INLINE=$(workflow_tool_uses \
        | jq -c 'select(((.input.script // "") != "") or ((.input.scriptPath // "") != ""))' \
        | count_lines)
    REQUIRED_JSON=$(printf '%s\n' "${WORKFLOW_REQUIRED_ARGS[@]}" | jq -R . | jq -sc .)
    SPEC_TASK_IDS=$(jq -c '[.tasks[].id]' "$SPEC")
    # Named exactly, with every required arg set the way g2g-build.js
    # checks (not undefined, null, or "") and tasks a non-empty array.
    named_launches() {
        workflow_tool_uses \
            | jq -c --arg name "$WORKFLOW_NAME" --argjson required "$REQUIRED_JSON" '
                select(.input.name == $name)
                | select((.input.args // null) | type == "object")
                | select([.input.args[$required[]] | . != null and . != ""] | all)
                | select(.input.args.tasks | type == "array" and length > 0)'
    }
    WF_NAMED=$(named_launches | count_lines)
    # ...and handing the loop at least one task it would dispatch. The
    # eligibility predicate mirrors nextEligible() in g2g-build.js.
    eligible_launches() {
        named_launches \
            | jq -c --argjson spec_ids "$SPEC_TASK_IDS" '
                (.input.args.tasks | map(select(.passes == true) | .id)) as $passed
                | select(any(.input.args.tasks[];
                    (.id as $id | $spec_ids | index($id) != null)
                    and .status != "blocked"
                    and .passes != true
                    and ((.dependsOn // []) | all(. as $dep | $passed | index($dep) != null))))'
    }
    WF_ELIGIBLE=$(eligible_launches | count_lines)
    WF_DISPATCHABLE_IDS=$(eligible_launches \
        | jq -r 'select((.input.args.turnCap | type == "number") and .input.args.turnCap >= 2) | .id')
    WF_DISPATCHABLE=$(printf '%s\n' "$WF_DISPATCHABLE_IDS" | count_lines)
    WF_LAUNCHED=$(comm -12 \
        <(printf '%s\n' "$WF_DISPATCHABLE_IDS" | grep . | sort -u) \
        <(succeeded_tool_result_ids | sort -u) | count_lines)

    [[ "$WF_ALL" -gt 0 ]] \
        || fail "the Workflow tool never ran — /g2g:build-wf either refused (runtime unavailable) or emulated the loop in prose"
    [[ "$WF_INLINE" -eq 0 ]] \
        || fail "Workflow ran ${WF_INLINE}x with an inline script or scriptPath — the loop was emulated, not the shipped g2g-build.js (a valid named launch does not excuse it)"
    [[ "$WF_NAMED" -gt 0 ]] \
        || fail "Workflow ran ${WF_ALL}x but never as $WORKFLOW_NAME by exact name with every required arg set (${WORKFLOW_REQUIRED_ARGS[*]}; tasks non-empty)"
    [[ "$WF_ELIGIBLE" -gt 0 ]] \
        || fail "$WORKFLOW_NAME was requested ${WF_NAMED}x but with no eligible sandbox task in its tasks arg (spec id, not blocked, not passed, dependencies passed) — the loop had nothing to dispatch, so the build was done by hand before the launch"
    [[ "$WF_DISPATCHABLE" -gt 0 ]] \
        || fail "$WORKFLOW_NAME was requested ${WF_ELIGIBLE}x with eligible work but a turn cap below 2 — the loop returns cap-turns before its first dispatch"
    [[ "$WF_LAUNCHED" -gt 0 ]] \
        || fail "$WORKFLOW_NAME was requested ${WF_DISPATCHABLE}x with dispatchable work but no request has a paired non-error tool_result — the launch failed, so whatever built the branch was not the workflow"
    echo "smoke: workflow: $WORKFLOW_NAME launched ${WF_LAUNCHED}x (Workflow tool_use total: $WF_ALL)"
fi

# --- run summary: turns and cost from the final result event ----------------
#
# Printed before the COMPLETE path deletes the work dir, so every run leaves
# the number the outer --max-turns is tuned against. Informational only.
RESULT_EVENT=$(run_events | jq -c 'select(.type == "result")' | tail -1)
if [[ -n "$RESULT_EVENT" ]]; then
    echo "smoke: run: $(jq -r '
        "\(.num_turns // "?") turns, $\(if .total_cost_usd == null then "?" else ((.total_cost_usd * 100 | round) / 100) end), \(((.duration_ms // 0) / 1000) | floor)s"' \
        <<< "$RESULT_EVENT")"
else
    echo "smoke: run: no result event in run.log (turns/cost unavailable)"
fi

# --- outcome: reported, and gated only on request ----------------------------

TASKS_TOTAL=$(jq -r '.tasks | length' "$SPEC")
TASKS_PASSED=$(jq -r '[.tasks[] | select(.passes == true)] | length' "$SPEC")
VERDICT=$(jq -r '.verifier.verdict // "PENDING"' "$SPEC")

if [[ "$TASKS_PASSED" == "$TASKS_TOTAL" && "$VERDICT" == "PASS" ]]; then
    OUTCOME="COMPLETE"
else
    OUTCOME="PARTIAL"
fi

echo "smoke: engine=$ENGINE outcome=$OUTCOME (tasks $TASKS_PASSED/$TASKS_TOTAL passed, verifier $VERDICT)"

if [[ "${SMOKE_REQUIRE_COMPLETE:-0}" == "1" && "$OUTCOME" != "COMPLETE" ]]; then
    fail "SMOKE_REQUIRE_COMPLETE=1 but the build ended $OUTCOME"
fi

echo "smoke: PASS (protocol invariants held)"
[[ "$OUTCOME" == "COMPLETE" ]] \
    || echo "smoke: note — partial build preserved for inspection at: $WORK"
[[ "$OUTCOME" != "COMPLETE" ]] || rm -rf "$WORK"
