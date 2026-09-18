#!/usr/bin/env bats

# Pins for the smoke harness itself (tests/smoke.sh + the Makefile smoke
# targets) — everything about it that can be checked WITHOUT a real
# headless build. The two engines (/g2g:build and /g2g:build-wf) share one
# script so parity holds by construction; these tests pin the engine
# switch, the invocation each engine gets, and the --assert-only checks
# that gate a preserved run. The real behavioral runs cost API dollars and
# stay behind `make smoke` / `make smoke-wf`, never `make check`.

REPO_DIR="$BATS_TEST_DIRNAME/.."
SMOKE="$BATS_TEST_DIRNAME/smoke.sh"

setup() {
    # Hermetic: a throwaway HOME, no user or system git config (so no
    # signing, hooks, or identity leak in), and an explicit identity because
    # make_sandbox.sh commits and CI runners may have none.
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME="g2g-test" GIT_AUTHOR_EMAIL="g2g-test@example.com"
    export GIT_COMMITTER_NAME="g2g-test" GIT_COMMITTER_EMAIL="g2g-test@example.com"
    # EVERY test runs with `claude` stubbed. The usage-error tests below
    # rely on smoke.sh exiting before it reaches the headless build; if
    # that early exit ever regresses, this stub is what keeps `make check`
    # from launching a real build and spending API dollars.
    install_fake_claude
}

# A fake `claude` on PATH that records the headless build invocation (first
# arg -p) and ignores the plugin-deregistration call.
install_fake_claude() {
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    FAKE_ARGS="$BATS_TEST_TMPDIR/claude-args"
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" ]]; then
    printf '%s\n' "$@" > "$SMOKE_FAKE_ARGS"
fi
exit 0
EOF
    chmod +x "$FAKE_BIN/claude"
    export SMOKE_FAKE_ARGS="$FAKE_ARGS"
    export PATH="$FAKE_BIN:$PATH"
}

# ---------------------------------------------------------------------------
# Makefile wiring
# ---------------------------------------------------------------------------

@test "makefile: check never depends on a smoke target" {
    run grep -E '^check:' "$REPO_DIR/Makefile"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *smoke* ]] || { echo "check: pulls in a smoke target: $output"; return 1; }
}

@test "makefile: smoke-wf runs smoke.sh with the build-wf engine" {
    run sed -n '/^smoke-wf:/,/^$/p' "$REPO_DIR/Makefile"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"tests/smoke.sh"* ]]
    [[ "$output" == *"--engine build-wf"* ]]
}

@test "makefile: smoke still runs the build engine by default" {
    run sed -n '/^smoke:/,/^$/p' "$REPO_DIR/Makefile"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"tests/smoke.sh"* ]]
    [[ "$output" != *"--engine"* ]]
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

@test "smoke: an unknown engine is a usage error (exit 2)" {
    run bash "$SMOKE" --engine bogus
    [[ "$status" -eq 2 ]]
    [[ "$output" == *usage* ]]
    [[ "$output" == *build-wf* ]]
}

@test "smoke: --engine with no value is a usage error (exit 2)" {
    run bash "$SMOKE" --engine
    [[ "$status" -eq 2 ]]
    [[ "$output" == *usage* ]]
}

@test "smoke: an unknown flag is a usage error (exit 2)" {
    run bash "$SMOKE" --bogus
    [[ "$status" -eq 2 ]]
    [[ "$output" == *usage* ]]
}

@test "smoke: --assert-only with an empty path is a usage error and never invokes claude" {
    # An unset or empty shell variable ("--assert-only \"\$DIR\"") must not
    # degrade into a fresh $20 run — that is the one thing this flag exists
    # to avoid. (F-058 adversarial review.)
    run bash "$SMOKE" --assert-only ""
    [[ "$status" -eq 2 ]]
    [[ "$output" == *usage* ]]
    [[ ! -f "$FAKE_ARGS" ]] || { echo "claude was invoked: $(cat "$FAKE_ARGS")"; return 1; }
    [[ "$output" != *"building specs/sandbox.json"* ]]
}

@test "smoke: --assert-only with a missing directory is a usage error and never invokes claude" {
    run bash "$SMOKE" --assert-only "$BATS_TEST_TMPDIR/does-not-exist"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *usage* ]]
    [[ ! -f "$FAKE_ARGS" ]]
}

@test "smoke: --engine combined with --assert-only is a usage error (exit 2)" {
    # The engine of a preserved run is recorded in its work dir; a flag
    # that contradicted it would be silently ignored, so it is refused.
    mkdir -p "$BATS_TEST_TMPDIR/preserved"
    run bash "$SMOKE" --assert-only "$BATS_TEST_TMPDIR/preserved" --engine build-wf
    [[ "$status" -eq 2 ]]
    [[ "$output" == *usage* ]]
}

# ---------------------------------------------------------------------------
# The invocation each engine gets. The fake `claude` from setup() records the
# args it was called with; the run then fails at the artifact assertions
# (nothing built), which is expected — the invocation is what these check.
# ---------------------------------------------------------------------------

# The failing run preserves its work dir under /tmp; remove it so the
# suite leaves nothing behind.
cleanup_preserved_work() {
    local preserved
    preserved=$(printf '%s\n' "$1" | sed -n 's/^sandbox preserved for inspection at: \([^ ]*\).*/\1/p' | head -1)
    [[ -n "$preserved" && "$preserved" == /tmp/g2g-smoke-* ]] && rm -rf "$preserved"
    return 0
}

# Prints the value that followed FLAG in the recorded args.
recorded_arg() {
    awk -v flag="$1" '$0 == flag { getline; print; exit }' "$FAKE_ARGS"
}

@test "smoke: the build-wf engine invokes /g2g:build-wf with Workflow allowed" {
    run bash "$SMOKE" --engine build-wf
    cleanup_preserved_work "$output"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"SMOKE FAIL"* ]]
    [[ -f "$FAKE_ARGS" ]] || { echo "fake claude was never invoked with -p"; return 1; }
    [[ "$(recorded_arg -p)" == "/g2g:build-wf specs/sandbox.json" ]]
    tools="$(recorded_arg --allowedTools)"
    [[ ",$tools," == *",Workflow,"* ]] || { echo "Workflow missing from --allowedTools: $tools"; return 1; }
    [[ ",$tools," == *",Agent,"* ]]
}

@test "smoke: the build engine invokes /g2g:build without Workflow" {
    run bash "$SMOKE"
    cleanup_preserved_work "$output"
    [[ "$status" -eq 1 ]]
    [[ -f "$FAKE_ARGS" ]] || { echo "fake claude was never invoked with -p"; return 1; }
    [[ "$(recorded_arg -p)" == "/g2g:build specs/sandbox.json" ]]
    tools="$(recorded_arg --allowedTools)"
    [[ ",$tools," != *",Workflow,"* ]] || { echo "Workflow leaked into the build engine's --allowedTools"; return 1; }
}

@test "smoke: both engines run with stream-json output so tool use is inspectable" {
    for engine in build build-wf; do
        rm -f "$FAKE_ARGS"
        run bash "$SMOKE" --engine "$engine"
        cleanup_preserved_work "$output"
        [[ "$(recorded_arg --output-format)" == "stream-json" ]] || { echo "$engine: no stream-json"; return 1; }
        grep -qx -- '--verbose' "$FAKE_ARGS" || { echo "$engine: stream-json in print mode needs --verbose"; return 1; }
    done
}

@test "smoke: the run records its engine in the work dir for --assert-only" {
    run bash "$SMOKE" --engine build-wf
    preserved=$(printf '%s\n' "$output" | sed -n 's/^sandbox preserved for inspection at: \([^ ]*\).*/\1/p' | head -1)
    # Read, then clean up, THEN assert — an assert that fails first would
    # leak the preserved dir under /tmp.
    engine_recorded="$(cat "$preserved/engine" 2>/dev/null || true)"
    cleanup_preserved_work "$output"
    [[ -n "$preserved" ]] || { echo "no preserved work dir in: $output"; return 1; }
    [[ "$engine_recorded" == "build-wf" ]]
}

# ---------------------------------------------------------------------------
# --assert-only against a synthetic preserved run. The fixture is a real
# sandbox (make_sandbox.sh) with the work branch created and pushed, every
# task out of in_progress, and no runtime files — i.e. the protocol
# invariants hold. passes stays false so the outcome is PARTIAL and the
# script preserves rather than deletes the fixture.
# ---------------------------------------------------------------------------

make_preserved_run() {
    WORK="$BATS_TEST_TMPDIR/work"
    SB="$WORK/sandbox"
    mkdir -p "$WORK"
    bash "$BATS_TEST_DIRNAME/make_sandbox.sh" "$SB" > /dev/null
    git init -q --bare "$WORK/origin.git"
    git -C "$SB" remote add origin "$WORK/origin.git"
    git -C "$SB" push -q -u origin main
    git -C "$SB" checkout -q -b g2g/sandbox-greeting
    jq '.tasks |= map(.status = "blocked")' "$SB/specs/sandbox.json" > "$SB/specs/sandbox.json.tmp"
    mv "$SB/specs/sandbox.json.tmp" "$SB/specs/sandbox.json"
    git -C "$SB" add -A
    git -C "$SB" commit -q -m "chore: blocked"
    git -C "$SB" push -q -u origin g2g/sandbox-greeting
    git -C "$SB" checkout -q main
    : > "$WORK/run.log"
}

# One stream-json assistant event carrying a Workflow tool_use with the
# given input object (and optional tool_use id, default toolu_x).
workflow_event() {
    jq -cn --argjson input "$1" --arg id "${2:-toolu_x}" \
        '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", id:$id, name:"Workflow", input:$input}]}}'
}

# The paired stream-json user event carrying that tool_use's result. The
# live run's result was "Workflow launched in background. Task ID: ..." with
# is_error false; the workflow's OUTCOME arrives later as a task notification
# that never enters the event stream, so this is what the gate can see.
workflow_result() {
    jq -cn --arg id "${1:-toolu_x}" --argjson is_error "${2:-false}" \
        '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:$id, is_error:$is_error, content:"Workflow launched in background. Task ID: wzp6qqv2s"}]}}'
}

# The args the shipped workflow validates before spending any agent (the
# required-arg list in plugin/workflows/g2g-build.js); a request missing one
# throws at invocation and dispatches nothing.
LOOP_ARGS='{"specPath":"specs/sandbox.json","ownerToken":"g2g-1-1","pluginRoot":"/p","branch":"g2g/sandbox-greeting","turnCap":8,"hoursCap":2,"buildStart":"2026-09-17T00:00:00Z","builderModel":"sonnet","context":{},"tasks":[{"id":"T-001"}]}'

# The final stream-json event of a headless run.
result_event() {
    jq -cn '{type:"result", subtype:"success", is_error:false, duration_ms:104000, num_turns:59, total_cost_usd:4.2134}'
}

@test "assert-only: build-wf passes when g2g:build-loop was launched by name with a non-error result" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        echo "some stderr noise that is not JSON"
        jq -cn '{type:"system", subtype:"init"}'
        workflow_event "{\"name\":\"g2g:build-loop\",\"args\":$LOOP_ARGS}"
        workflow_result toolu_x false
        result_event
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"smoke: PASS"* ]]
    [[ "$output" == *"workflow: g2g:build-loop launched 1x"* ]]
}

@test "assert-only: the run's turns and cost are reported from the final result event" {
    # Printed BEFORE the COMPLETE path deletes the log, so every run leaves a
    # number to tune the outer cap against.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "{\"name\":\"g2g:build-loop\",\"args\":$LOOP_ARGS}"
        workflow_result
        result_event
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"smoke: run: 59 turns"* ]]
    [[ "$output" == *"\$4.21"* ]]
    [[ "$output" == *"104s"* ]]
}

@test "assert-only: a log with no result event still passes and says the run summary is unavailable" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "{\"name\":\"g2g:build-loop\",\"args\":$LOOP_ARGS}"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"smoke: run: no result event"* ]]
}

@test "assert-only: build-wf fails when the named launch returned an error result" {
    # A failed launch followed by a hand-emulated loop produces the same
    # artifacts; the gate must read the tool_result, not just the request.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "{\"name\":\"g2g:build-loop\",\"args\":$LOOP_ARGS}"
        workflow_result toolu_x true
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no request has a paired non-error tool_result"* ]]
}

@test "assert-only: build-wf fails when the named launch has no paired result at all" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    workflow_event "{\"name\":\"g2g:build-loop\",\"args\":$LOOP_ARGS}" > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no request has a paired non-error tool_result"* ]]
}

@test "assert-only: build-wf fails when a result is paired to a different tool_use id" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "{\"name\":\"g2g:build-loop\",\"args\":$LOOP_ARGS}" toolu_a
        workflow_result toolu_b false
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no request has a paired non-error tool_result"* ]]
}

@test "assert-only: build-wf fails when the workflow name merely contains build-loop" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "{\"name\":\"my-build-loop-clone\",\"args\":$LOOP_ARGS}"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"never as g2g:build-loop by exact name"* ]]
}

@test "assert-only: build-wf fails when the request omits an arg the workflow requires" {
    # g2g-build.js throws before dispatching any agent when a required arg is
    # missing, so such a request cannot have run the loop.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event '{"name":"g2g:build-loop","args":{"specPath":"specs/sandbox.json"}}'
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"never as g2g:build-loop by exact name"* ]]
}

@test "assert-only: build-wf fails when a required arg is present but null or empty" {
    # g2g-build.js rejects undefined, null, and "" alike; has() alone
    # accepted null.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {ownerToken:null})}')" toolu_a
        workflow_result toolu_a false
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {branch:""})}')" toolu_b
        workflow_result toolu_b false
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"never as g2g:build-loop by exact name"* ]]
}

@test "assert-only: build-wf fails when the launch carries an empty tasks array" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {tasks:[]})}')"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"never as g2g:build-loop by exact name"* ]]
}

@test "assert-only: build-wf fails when the launch hands the workflow only already-passed tasks" {
    # The emulate-first bypass: build by hand, then launch the shipped loop
    # with every task already passes:true so it returns complete having
    # dispatched nothing. A launch must carry at least one pending sandbox
    # task or the loop had nothing to do.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {tasks:[{id:"T-001",status:"complete",passes:true},{id:"T-002",status:"complete",passes:true}]})}')"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no eligible sandbox task"* ]]
}

@test "assert-only: build-wf fails when the launch's tasks are not the sandbox spec's tasks" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {tasks:[{id:"T-999",passes:false}]})}')"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no eligible sandbox task"* ]]
}

@test "assert-only: build-wf fails when every pending task is blocked or waits on a failed dependency" {
    # Emulated partial build: T-001 blocked, T-002 pending but dependent on
    # it. Both have passes:false, yet g2g-build.js's nextEligible() selects
    # neither and returns blocked with zero dispatches.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {tasks:[{id:"T-001",status:"blocked",passes:false,dependsOn:[]},{id:"T-002",status:"pending",passes:false,dependsOn:["T-001"]}]})}')"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no eligible sandbox task"* ]]
}

@test "assert-only: build-wf fails when the launch's turn cap cannot admit a first dispatch" {
    # The loop increments turn before checking `turn >= turnCap`, so a cap
    # of 1 returns cap-turns before any agent runs.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {turnCap:1})}')"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"turn cap"* ]]
}

@test "assert-only: build-wf fails when the launch's buildStart is not a parseable timestamp" {
    # g2g-build.js throws on an unparseable buildStart before any agent runs
    # — e.g. a wrapper that pasted the placeholder "BUILD_START" verbatim.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {buildStart:"BUILD_START"})}')"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"buildStart"* ]]
}

@test "assert-only: build-wf fails when the launch's hours cap is negative" {
    # deadline = buildStart + hoursCap h; the first cap check compares the
    # start clock against it, so a negative cap returns cap-hours untouched.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {hoursCap:-1})}')"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"hoursCap"* ]]
}

@test "assert-only: build-wf passes a launch whose eligible task depends on an already-passed one" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {tasks:[{id:"T-001",status:"complete",passes:true,dependsOn:[]},{id:"T-002",status:"pending",passes:false,dependsOn:["T-001"]}]})}')"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "assert-only: build-wf passes a resume-shaped launch with one passed and one pending task" {
    # --continue-branch hands the loop a mix; at least one pending task is
    # the requirement, not all of them.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "$(jq -cn --argjson a "$LOOP_ARGS" '{name:"g2g:build-loop", args:($a + {tasks:[{id:"T-001",passes:true},{id:"T-002",passes:false}]})}')"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "assert-only: build-wf fails when a valid named launch is accompanied by an inline-script call" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "{\"name\":\"g2g:build-loop\",\"args\":$LOOP_ARGS}" toolu_a
        workflow_result toolu_a false
        workflow_event '{"script":"export const meta = {name: \"x\"}; return 1"}' toolu_b
        workflow_result toolu_b false
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"inline script"* ]]
}

@test "assert-only: build-wf fails when a valid named launch is accompanied by a scriptPath call" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "{\"name\":\"g2g:build-loop\",\"args\":$LOOP_ARGS}" toolu_a
        workflow_result toolu_a false
        workflow_event '{"scriptPath":"/somewhere/build-loop-copy.js","args":{}}' toolu_b
        workflow_result toolu_b false
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"inline script"* ]]
}

@test "assert-only: build-wf fails when the Workflow tool never ran" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        jq -cn '{type:"system", subtype:"init"}'
        jq -cn '{type:"assistant", message:{content:[{type:"tool_use", id:"t", name:"Agent", input:{}}]}}'
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"SMOKE FAIL"* ]]
    [[ "$output" == *"Workflow tool never ran"* ]]
}

@test "assert-only: build-wf fails when Workflow ran only with an inline script" {
    # An inline script is the wrapper emulating the loop — exactly what
    # build-wf.md forbids. Running Workflow is not enough; it must run the
    # shipped build-loop workflow by name.
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event '{"script":"export const meta = {name: \"x\"}; return 1"}'
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"SMOKE FAIL"* ]]
    [[ "$output" == *"inline script"* ]]
}

@test "assert-only: build-wf fails when the named workflow also carries an inline script" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "{\"name\":\"g2g:build-loop\",\"script\":\"return 1\",\"args\":$LOOP_ARGS}"
        workflow_result
    } > "$WORK/run.log"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"inline script"* ]]
}

@test "contract: the args smoke.sh requires of a build-loop request are exactly the ones g2g-build.js validates" {
    # Both lists must move together: a key required by the script but not
    # by the gate lets a doomed request pass; a key required by the gate but
    # not by the script fails a legitimate launch.
    smoke_keys=$(sed -n 's/^WORKFLOW_REQUIRED_ARGS=(\(.*\))$/\1/p' "$SMOKE" | tr ' ' '\n' | sort)
    [[ -n "$smoke_keys" ]] || { echo "WORKFLOW_REQUIRED_ARGS not found in smoke.sh"; return 1; }
    js_keys=$(sed -n "/^for (const key of \[/,/\]) {/p" "$REPO_DIR/plugin/workflows/g2g-build.js" \
        | grep -o "'[A-Za-z]*'" | tr -d "'" | sort)
    [[ -n "$js_keys" ]] || { echo "required-arg loop not found in g2g-build.js"; return 1; }
    [[ "$smoke_keys" == "$js_keys" ]] || { echo "smoke.sh: $smoke_keys"; echo "g2g-build.js: $js_keys"; return 1; }
}

@test "assert-only: the build engine does not require a Workflow invocation" {
    make_preserved_run
    echo "build" > "$WORK/engine"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"smoke: PASS"* ]]
}

@test "assert-only: a present but invalid engine file fails instead of skipping the Workflow gate" {
    make_preserved_run
    echo "build_wf" > "$WORK/engine"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"SMOKE FAIL"* ]]
    [[ "$output" == *"engine file"* ]]
}

@test "assert-only: an empty engine file fails instead of skipping the Workflow gate" {
    make_preserved_run
    : > "$WORK/engine"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"engine file"* ]]
}

@test "assert-only: a preserved run with no engine file is treated as the build engine" {
    make_preserved_run
    rm -f "$WORK/engine"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"smoke: PASS"* ]]
}

@test "assert-only: protocol invariants still gate every engine" {
    make_preserved_run
    echo "build-wf" > "$WORK/engine"
    {
        workflow_event "{\"name\":\"g2g:build-loop\",\"args\":$LOOP_ARGS}"
        workflow_result
    } > "$WORK/run.log"
    touch "$SB/.g2g-goal"
    run bash "$SMOKE" --assert-only "$WORK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *".g2g-goal was not deleted"* ]]
}
