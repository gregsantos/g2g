#!/usr/bin/env bats

# Structural invariants for the command/agent markdown layer and hook
# plumbing. The procedures are prose, so make check cannot execute them —
# these tests pin the cross-file contracts that other files parse or copy,
# so a regression in one file fails loudly instead of breaking a build at
# runtime.

PLUGIN_DIR="$BATS_TEST_DIRNAME/../plugin"
REPO_DIR="$BATS_TEST_DIRNAME/.."

@test "commands: every command has frontmatter with a description" {
    for f in "$PLUGIN_DIR"/commands/*.md; do
        run sed -n '1p' "$f"
        [[ "$output" == "---" ]] || { echo "missing frontmatter: $f"; return 1; }
        run grep -c '^description:' "$f"
        [[ "$output" -ge 1 ]] || { echo "missing description: $f"; return 1; }
    done
}

@test "contract: report markers agree between orchestrator and agents" {
    grep -q 'BUILDER REPORT' "$PLUGIN_DIR/commands/build.md"
    grep -q 'BUILDER REPORT' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -q 'VERIFIER REPORT' "$PLUGIN_DIR/commands/build.md"
    grep -q 'VERIFIER REPORT' "$PLUGIN_DIR/agents/g2g-verifier.md"
}

@test "contract: evidence block markers agree between script and build.md" {
    grep -q '=== G2G EVIDENCE ===' "$PLUGIN_DIR/scripts/g2g-evidence.sh"
    grep -q 'G2G EVIDENCE' "$PLUGIN_DIR/commands/build.md"
}

@test "contract: composed commands reference procedures that exist" {
    # dev.md re-executes spec.md and build.md; improve-cycle.md re-executes
    # review.md, spec.md, and build.md. If one is renamed, these break first.
    for name in spec build; do
        grep -q "commands/$name.md\|$name.md" "$PLUGIN_DIR/commands/dev.md"
        [[ -f "$PLUGIN_DIR/commands/$name.md" ]]
    done
    for name in review spec build; do
        grep -q "$name.md" "$PLUGIN_DIR/commands/improve-cycle.md"
        [[ -f "$PLUGIN_DIR/commands/$name.md" ]]
    done
}

@test "hooks: hooks.json is valid, session-scoped, and Stop-typed" {
    run jq -e '.hooks.Stop[0].hooks[0].type == "prompt"' "$PLUGIN_DIR/hooks/hooks.json"
    [[ "$status" -eq 0 ]]
    run jq -r '.hooks.Stop[0].hooks[0].prompt' "$PLUGIN_DIR/hooks/hooks.json"
    [[ "$output" == *".g2g-goal"* ]] || { echo "prompt lost .g2g-goal reference"; return 1; }
    [[ "$output" == *"THIS session"* ]] || { echo "prompt lost session-scoping clause"; return 1; }
}

@test "hooks: tracked settings copy is in sync with plugin hooks.json" {
    run diff "$PLUGIN_DIR/hooks/hooks.json" "$REPO_DIR/.claude/settings.json"
    [[ "$status" -eq 0 ]] || { echo "settings.json drifted from hooks.json — re-copy it"; return 1; }
}

@test "gate: improve opt-in is enforced in both improve commands" {
    grep -q 'improve.enabled' "$PLUGIN_DIR/commands/improve.md"
    grep -q 'improve.enabled' "$PLUGIN_DIR/commands/improve-cycle.md"
}

@test "contract: improve launcher and status agree on the tick pid sidecar" {
    # improve.md writes the pid sidecar; status.md reads it. If the path
    # token drifts, status silently reports running ticks as FINISHED.
    grep -q 'tick.pid' "$PLUGIN_DIR/commands/improve.md"
    grep -q 'tick.pid' "$PLUGIN_DIR/commands/status.md"
}

@test "safety: improve and status handle legacy + run-root sidecar layouts" {
    # A legacy flat worktree makes RUNDIR=/tmp; without layout handling,
    # cleanup would rm -rf the shared temp base. Both files must branch on
    # layout, and the recursive delete must be gated on a validated run root.
    for f in improve status; do
        grep -qi 'legacy' "$PLUGIN_DIR/commands/$f.md" \
            || { echo "$f.md lost legacy-layout handling"; return 1; }
    done
    grep -qi 'run root' "$PLUGIN_DIR/commands/improve.md"
}

@test "safety: build acquires the checkout lock via the lock helper" {
    # One-build-per-checkout is enforced by the executable helper
    # (tests/plugin_lock.bats proves its semantics); build.md's job is
    # only to call it first and branch on the exit codes.
    grep -q 'g2g-lock.sh acquire' "$PLUGIN_DIR/commands/build.md"
    grep -q '.g2g-goal.lock' "$PLUGIN_DIR/commands/build.md"
    [[ -x "$PLUGIN_DIR/scripts/g2g-lock.sh" ]] || { echo "g2g-lock.sh is not executable"; return 1; }
}

@test "safety: build releases its lock on preflight aborts after acquisition" {
    # Without this, one failed preflight blocks all retries as LIVE for
    # the full stale threshold.
    grep -q 'LOCK RELEASE ON PREFLIGHT ABORT' "$PLUGIN_DIR/commands/build.md"
    grep -q 'release-preflight' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: every terminal path releases the pair through the helper" {
    # Phase 4 step 5 (conflicts), step 6 (clean PR), and Phase 5
    # (partial) must each remove the goal/lock pair via release-terminal,
    # never by hand-deleting the files.
    count=$(grep -c 'release-terminal' "$PLUGIN_DIR/commands/build.md")
    [[ "$count" -ge 3 ]] || { echo "only $count release-terminal calls (need 3+)"; return 1; }
    # `! cmd` never trips bats' errexit, so negative guards must be
    # explicit if-blocks to actually enforce anything.
    if grep -qE '^ *[Dd]elete `.g2g-goal`' "$PLUGIN_DIR/commands/build.md"; then
        echo "build.md reintroduced hand-deletion of the goal file"
        return 1
    fi
}

@test "safety: Phase 5 holds ownership through the push, then releases" {
    # Control-flow pin, not a mention count: within the Phase 5 section,
    # the ownership check (refresh) must precede the push, and
    # release-terminal must come after the push — a release-before-push
    # window lets a reclaiming build advance the branch before this
    # session publishes it.
    section=$(sed -n '/^## Phase 5/,/^## /p' "$PLUGIN_DIR/commands/build.md")
    refresh_line=$(printf '%s\n' "$section" | grep -n 'g2g-lock.sh refresh' | head -1 | cut -d: -f1)
    push_line=$(printf '%s\n' "$section" | grep -n 'git push -u origin' | head -1 | cut -d: -f1)
    release_line=$(printf '%s\n' "$section" | grep -n 'release-terminal' | head -1 | cut -d: -f1)
    [[ -n "$refresh_line" && -n "$push_line" && -n "$release_line" ]] \
        || { echo "Phase 5 missing refresh/push/release (got: refresh=$refresh_line push=$push_line release=$release_line)"; return 1; }
    [[ "$refresh_line" -lt "$push_line" ]] \
        || { echo "Phase 5 must confirm ownership (refresh) before pushing"; return 1; }
    [[ "$push_line" -lt "$release_line" ]] \
        || { echo "Phase 5 must push before release-terminal (release-before-push publishes contested state)"; return 1; }
    # The failure path must still reach the release: the push step has to
    # route to it explicitly, and nonzero refresh must route to the
    # non-mutating OWNERSHIP LOST path.
    printf '%s\n' "$section" | grep -q 'OWNERSHIP LOST' \
        || { echo "Phase 5 refresh failure must route to OWNERSHIP LOST"; return 1; }
    printf '%s\n' "$section" | grep -qi 'BOTH the success and failure' \
        || { echo "Phase 5 release must run on both push outcomes"; return 1; }
}

@test "safety: improveCycle model value is validated and quoted at both spawn sites" {
    # The config value crosses into the spawn command line: both spawn
    # sites must pin the strict allowlist pattern and pass the value only
    # as a quoted variable expansion — raw interpolation of config text
    # after the caps could smuggle extra CLI flags past the budget.
    pattern='^[A-Za-z0-9][A-Za-z0-9._-]*$'
    for f in commands/improve.md routines/improve-nightly.md; do
        grep -qF "$pattern" "$PLUGIN_DIR/$f" \
            || { echo "$f missing the model allowlist pattern"; return 1; }
        grep -qF -- '--model "$CYCLE_MODEL"' "$PLUGIN_DIR/$f" \
            || { echo "$f does not pass the model as a quoted variable"; return 1; }
    done
    # Behavioral: the pinned allowlist itself must reject injection
    # shapes and accept real model slugs.
    for bad in 'sonnet --max-budget-usd 1000' '-opus' 'son;net' '' 'a b' '$(id)' 'a"b'; do
        if [[ "$bad" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            echo "allowlist accepts unsafe value: '$bad'"
            return 1
        fi
    done
    for good in sonnet opus haiku claude-fable-5 us.anthropic.claude-sonnet-5 gpt-5.4; do
        [[ "$good" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || { echo "allowlist rejects real slug: $good"; return 1; }
    done
}

@test "contract: improveCycle rejects 'inherit' at both spawn sites" {
    # A spawned headless process has no session to inherit from: passing
    # 'inherit' literally fails the claude -p spawn, and omitting --model
    # silently selects the machine's CLI default. Both spawn sites must
    # therefore reject the value outright, never reinterpret it.
    for f in commands/improve.md routines/improve-nightly.md; do
        grep -q 'models.improveCycle' "$PLUGIN_DIR/$f" \
            || { echo "$f no longer resolves models.improveCycle"; return 1; }
        grep -q 'does not support `inherit`' "$PLUGIN_DIR/$f" \
            || { echo "$f does not reject inherit for models.improveCycle"; return 1; }
        if grep -Eqi '(omit|drop)[^.]*--model' "$PLUGIN_DIR/$f"; then
            echo "$f reintroduced omit---model semantics for inherit (selects CLI default)"
            return 1
        fi
    done
}

@test "safety: clean-tree preflight exempts the goal/lock pair" {
    # Host repos without the .gitignore rule show the just-created lock
    # as untracked; treating that as dirt would abort every build there.
    grep -A8 'git status.*clean' "$PLUGIN_DIR/commands/build.md" | grep -q '.g2g-goal.lock'
}

@test "safety: turn-level tree check exempts the goal/lock pair" {
    # After arming, both files exist every turn on non-ignoring hosts;
    # without the exclusion a healthy build is misclassified as a builder
    # crash each turn (and default git stash cannot even clear untracked).
    grep -B2 -A6 'Tree check' "$PLUGIN_DIR/commands/build.md" | grep -q '.g2g-goal.lock'
}

@test "safety: heartbeat refresh is ownership-checked with a terminal path" {
    # An unconditional heartbeat overwrite would steal a reclaimed lock
    # back and leave two builds running. Refresh must go through the
    # helper's token check and route ownership loss to a non-mutating
    # terminal path.
    grep -q 'OWNERSHIP-CHECKED REFRESH' "$PLUGIN_DIR/commands/build.md"
    grep -q 'g2g-lock.sh refresh' "$PLUGIN_DIR/commands/build.md"
    grep -q 'OWNERSHIP LOST' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: synchronization semantics live only in the lock helper" {
    # The mutex serialization, TOCTOU-safe reclaim, and atomic creation
    # are implemented (and behaviorally tested) in g2g-lock.sh. The
    # command prose must call the helper, never reconstruct that logic —
    # a prose reimplementation is exactly the drift this design removes.
    grep -q '.g2g-goal.mutex' "$PLUGIN_DIR/scripts/g2g-lock.sh"
    grep -q 'g2g-lock.sh' "$PLUGIN_DIR/commands/build.md"
    grep -q 'g2g-lock.sh' "$PLUGIN_DIR/commands/improve-cycle.md"
    # `! cmd` never trips bats' errexit — the anti-drift guards must be
    # explicit if-blocks to actually enforce anything.
    for token in noclobber mkdir rmdir; do
        if grep -qi "$token" "$PLUGIN_DIR/commands/build.md"; then
            echo "build.md reintroduced inline lock logic: $token"
            return 1
        fi
    done
}

@test "contract: lock helper exit codes agree between script and build.md" {
    # build.md branches on these outcomes; if the script's contract
    # moves, the procedure must move with it.
    for outcome in live-owner ownership-lost mutex-stuck malformed-state operational-error; do
        grep -q "$outcome" "$PLUGIN_DIR/scripts/g2g-lock.sh" \
            || { echo "script lost outcome: $outcome"; return 1; }
        grep -q "$outcome" "$PLUGIN_DIR/commands/build.md" \
            || { echo "build.md lost outcome: $outcome"; return 1; }
    done
}

@test "safety: goal condition requires a subagent-delivered VERIFIER REPORT" {
    # The evidence block's `verifier: PASS` line is read from the spec
    # JSON, which the orchestrator itself writes; without this clause,
    # completion could be reached by spec edits alone.
    grep -q 'VERIFIER REPORT block with a verdict line of PASS' \
        "$PLUGIN_DIR/commands/build.md"
}

@test "safety: verifier dispatch is preceded by an ownership-checked refresh" {
    # A verification pass can outlast the lock's stale threshold; an
    # unrefreshed heartbeat there lets a concurrent build reclaim the
    # checkout mid-verify.
    grep -A6 'Increment VERIFY_ROUND by 1' "$PLUGIN_DIR/commands/build.md" \
        | grep -q 'OWNERSHIP-CHECKED REFRESH'
}

@test "hooks: arming-session uncertainty about the condition fails closed" {
    # Bystander uncertainty (about ARMING) stays fail-open; the arming
    # session's uncertainty (about the CONDITION) must block the stop.
    run jq -r '.hooks.Stop[0].hooks[0].prompt' "$PLUGIN_DIR/hooks/hooks.json"
    [[ "$output" == *"uncertainty about whether the condition is met resolves to NOT met"* ]] \
        || { echo "prompt lost the arming-session fail-closed clause"; return 1; }
}

@test "contract: evidence head line is pinned by the evidence tests" {
    # build.md's audit trail relies on the head line binding evidence to
    # a tree state; if the script or its tests drop it, fail loudly here.
    grep -q '^    echo "head: ' "$PLUGIN_DIR/scripts/g2g-evidence.sh" \
        || grep -q 'head: \$HEAD_SHA' "$PLUGIN_DIR/scripts/g2g-evidence.sh"
    grep -q 'head: none' "$BATS_TEST_DIRNAME/plugin_evidence.bats"
}

@test "safety: ownership loss is a terminal clause of the armed goal" {
    # The ownership-lost path deletes nothing, so without its own clause
    # in the goal condition the Stop hook would block the session until
    # the turn/time caps — which may be unreachable.
    grep -c 'G2G OWNERSHIP LOST' "$PLUGIN_DIR/commands/build.md" | grep -qE '^[2-9]'
}

@test "safety: run-root delete guard tolerates documented sidecars" {
    # A normal run root contains tick.log (and while running tick.pid /
    # selected.json), and has no worktree child after git worktree remove.
    # A single-child-only guard would forbid its own documented cleanup.
    grep -q 'SUBSET' "$PLUGIN_DIR/commands/improve.md"
    grep -q 'selected.json' "$PLUGIN_DIR/commands/improve.md"
}

@test "safety: improve-cycle wrapper does not delete build.md's goal/lock" {
    # The wrapper routes cleanup through the lock helper's ownership
    # rules: it may release its own build's pair, but never deletes
    # .g2g-goal out from under a foreign live lock.
    grep -q 'Do NOT delete `.g2g-goal`' "$PLUGIN_DIR/commands/improve-cycle.md"
    grep -q 'owner token' "$PLUGIN_DIR/commands/improve-cycle.md"
    grep -q 'release-terminal' "$PLUGIN_DIR/commands/improve-cycle.md"
}

@test "models: routing pins agree with the config contract" {
    grep -q 'models.builder' "$PLUGIN_DIR/commands/build.md"
    grep -q 'models.verifier' "$PLUGIN_DIR/commands/build.md"
    grep -q '^model: sonnet' "$PLUGIN_DIR/commands/go.md"
    grep -q '^model: haiku' "$PLUGIN_DIR/commands/status.md"
}

@test "workflow: build-loop script parses as JavaScript" {
    command -v node >/dev/null 2>&1 || skip "node not installed"
    # Workflow scripts use the runtime's documented shape: an exported
    # meta block plus a body with top-level await/return, which the
    # runtime executes as a function. Reproduce that for node --check:
    # drop the export block and wrap the body in an async function.
    WRAPPED="$BATS_TEST_TMPDIR/g2g-build-wrapped.js"
    {
        echo 'async function __wf(agent, pipeline, args) {'
        sed '/^export const meta/,/^}/d' "$PLUGIN_DIR/workflows/g2g-build.js"
        echo '}'
    } > "$WRAPPED"
    run node --check "$WRAPPED"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "workflow: meta name agrees between the script and its wrapper" {
    grep -q "name: 'build-loop'" "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q 'build-loop' "$PLUGIN_DIR/commands/build-wf.md"
}

@test "workflow: builder schema fields agree with the agent contract" {
    # The structured result replaces BUILDER REPORT parsing; its fields
    # must track the report block in agents/g2g-builder.md.
    for k in result commit verified notes; do
        grep -q "$k" "$PLUGIN_DIR/workflows/g2g-build.js" \
            || { echo "builder schema lost field: $k"; return 1; }
        grep -q "$k" "$PLUGIN_DIR/agents/g2g-builder.md" \
            || { echo "agent contract lost field: $k"; return 1; }
    done
    # Builders read the contract file at runtime — one source of truth.
    grep -q 'agents/g2g-builder.md' "$PLUGIN_DIR/workflows/g2g-build.js"
}

@test "workflow: caps and ownership loss are enforced in code" {
    grep -q 'turnCap' "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q 'deadlineMs' "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q "ownership-lost" "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q 'g2g-lock.sh refresh' "$PLUGIN_DIR/workflows/g2g-build.js"
}

@test "safety: build-wf keeps the P1 verifier gate and terminal release" {
    grep -q 'VERIFIER REPORT block with a verdict line of PASS' \
        "$PLUGIN_DIR/commands/build-wf.md"
    grep -q 'release-terminal' "$PLUGIN_DIR/commands/build-wf.md"
    grep -qi 'NEVER merges' "$PLUGIN_DIR/commands/build-wf.md"
}

@test "safety: build-wf refuses to emulate the loop without the runtime" {
    grep -qi 'do NOT emulate the loop' "$PLUGIN_DIR/commands/build-wf.md"
}

@test "contract: build-wf composes phases from build.md" {
    grep -q 'build.md' "$PLUGIN_DIR/commands/build-wf.md"
    [[ -f "$PLUGIN_DIR/commands/build.md" ]]
    grep -q 'G2G OWNERSHIP LOST' "$PLUGIN_DIR/commands/build-wf.md"
}

@test "metadata: plugin and marketplace names agree" {
    plugin_name=$(jq -r '.name' "$PLUGIN_DIR/.claude-plugin/plugin.json")
    market_entry=$(jq -r '.plugins[0].name' "$REPO_DIR/.claude-plugin/marketplace.json")
    [[ "$plugin_name" == "$market_entry" ]]
    [[ "$(jq -r '.plugins[0].source' "$REPO_DIR/.claude-plugin/marketplace.json")" == "./plugin" ]]
}

@test "workflow: scripts never call runtime-banned nondeterministic APIs" {
    # The dynamic-workflow runtime throws on Date.now(), Math.random(),
    # and argless new Date() (they would break resume) — a script using
    # them fails at its first live invocation, exactly how the shipped
    # 0.3.0 script failed its controlled test. Wall-clock time must come
    # from an agent tool result (the turnkeeper's `now`).
    for f in "$PLUGIN_DIR"/workflows/*.js; do
        if grep -nE 'Date\.now\(|Math\.random\(|new Date\(\)' "$f"; then
            echo "runtime-banned nondeterministic API in $f"
            return 1
        fi
    done
}
