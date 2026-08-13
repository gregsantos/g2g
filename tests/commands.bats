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

@test "hooks: hooks.json is a Stop command hook invoking the plugin's script" {
    run jq -e '.hooks.Stop[0].hooks[0].type == "command"' "$PLUGIN_DIR/hooks/hooks.json"
    [[ "$status" -eq 0 ]] || { echo "Stop hook is no longer command-typed"; return 1; }
    run jq -r '.hooks.Stop[0].hooks[0].command' "$PLUGIN_DIR/hooks/hooks.json"
    [[ "$output" == *'${CLAUDE_PLUGIN_ROOT}/scripts/g2g-stop.sh'* ]] \
        || { echo "Stop hook does not invoke the plugin's own g2g-stop.sh"; return 1; }
    [[ -x "$PLUGIN_DIR/scripts/g2g-stop.sh" ]] \
        || { echo "g2g-stop.sh is missing or not executable"; return 1; }
}

@test "hooks: the Stop hook reaches no model — the precondition is mechanical" {
    # The 0.4.0 fix IS that arming is decided mechanically. Any model call
    # reintroduces the failure class where an evaluator finds "no goal was
    # armed" and blocks the stop anyway.
    run jq -e '[.hooks[][].hooks[].type] | index("prompt")' "$PLUGIN_DIR/hooks/hooks.json"
    [[ "$status" -ne 0 ]] || { echo "a prompt-type hook is back in hooks.json"; return 1; }
    ! grep -qE 'claude -p|claude --print' "$PLUGIN_DIR/scripts/g2g-stop.sh" \
        || { echo "g2g-stop.sh shells out to a model"; return 1; }
}

@test "hooks: tracked settings declares the plugin and vendors no hook" {
    # The hook must live only in the plugin. A copy in a host repo is a copy
    # no plugin update can ever patch — that is how the pre-0.4.0 defect
    # would have outlived its own fix.
    run jq -e '.enabledPlugins["g2g@g2g"] == true' "$REPO_DIR/.claude/settings.json"
    [[ "$status" -eq 0 ]] || { echo "settings.json no longer declares the g2g plugin"; return 1; }
    run jq -e 'has("hooks")' "$REPO_DIR/.claude/settings.json"
    [[ "$status" -ne 0 ]] \
        || { echo "settings.json vendors a hook again — the plugin's hook is the only copy"; return 1; }
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

@test "safety: turn-level tree check surfaces foreign paths instead of absorbing them" {
    # F-065 (stash half): a dirty path this build has no claim to (e.g. a
    # concurrent /g2g:review writing the tracked findings backlog with no
    # lock) must never be swept into this build's crash stash under a
    # misleading g2g-crash-<task-id> label. It must be surfaced, and the
    # two surfaced sub-cases must each have a defined next step: a foreign
    # untracked file is reported once and remembered so later turns don't
    # restash or re-report it, and a foreign tracked modification routes
    # to Phase 5 (terminal partial) rather than being stashed or ignored.
    tree_check=$(grep -A45 'Tree check' "$PLUGIN_DIR/commands/build.md")
    echo "$tree_check" | grep -qi 'PREDICATE' \
        || { echo "no stated predicate for probable builder debris"; return 1; }
    echo "$tree_check" | grep -qi 'surface' \
        || { echo "no instruction to surface a path outside the predicate"; return 1; }
    echo "$tree_check" | grep -q 'SURFACED-FOREIGN' \
        || { echo "no remembered-exclusion mechanism for a surfaced untracked path"; return 1; }
    echo "$tree_check" | grep -qi 'Phase 5' \
        || { echo "foreign tracked modification has no route to Phase 5"; return 1; }
    # Genuine builder debris must still be recoverable the same way as before.
    echo "$tree_check" | grep -q 'g2g-crash-<task-id>' \
        || { echo "genuine builder debris no longer stashed as g2g-crash-<task-id>"; return 1; }
    echo "$tree_check" | grep -qi "task card as recovery context" \
        || { echo "stash reference no longer passed to the next builder as recovery context"; return 1; }
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

@test "safety: completion requires a subagent-delivered VERIFIER REPORT" {
    # The evidence block's `verifier: PASS` line is read from the spec
    # JSON, which the orchestrator itself writes; without this requirement,
    # completion could be reached by spec edits alone. Since 0.4.0 the hook
    # enforces it by matching the dispatched subagent's own result record.
    grep -q 'g2g:g2g-verifier' "$PLUGIN_DIR/scripts/g2g-stop.sh"
    grep -q 'VERIFIER REPORT' "$PLUGIN_DIR/scripts/g2g-stop.sh"
    grep -q 'VERIFIER REPORT' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: verifier dispatch is preceded by an ownership-checked refresh" {
    # A verification pass can outlast the lock's stale threshold; an
    # unrefreshed heartbeat there lets a concurrent build reclaim the
    # checkout mid-verify.
    grep -A6 'Increment VERIFY_ROUND by 1' "$PLUGIN_DIR/commands/build.md" \
        | grep -q 'OWNERSHIP-CHECKED REFRESH'
}

@test "hooks: build.md documents the asymmetric uncertainty rule" {
    # Behavioural coverage lives in tests/plugin_stop.bats; this only keeps
    # the rule documented where a command author will read it, since the
    # direction of the asymmetry is what the pre-0.4.0 evaluator inverted.
    grep -qi 'asymmetric' "$PLUGIN_DIR/commands/build.md"
    grep -q 'foreign owner' "$PLUGIN_DIR/commands/build.md"
}

@test "contract: evidence head line is pinned by the evidence tests" {
    # build.md's audit trail relies on the head line binding evidence to
    # a tree state; if the script or its tests drop it, fail loudly here.
    grep -q '^    echo "head: ' "$PLUGIN_DIR/scripts/g2g-evidence.sh" \
        || grep -q 'head: \$HEAD_SHA' "$PLUGIN_DIR/scripts/g2g-evidence.sh"
    grep -q 'head: none' "$BATS_TEST_DIRNAME/plugin_evidence.bats"
}

@test "safety: ownership loss is a terminal allow path in build.md and the hook" {
    # The ownership-lost path deletes nothing, so without the hook honouring
    # its marker the goal would block the session until the turn/time caps —
    # which may be unreachable.
    grep -c 'G2G OWNERSHIP LOST' "$PLUGIN_DIR/commands/build.md" | grep -qE '^[2-9]'
    grep -q 'G2G OWNERSHIP LOST' "$PLUGIN_DIR/scripts/g2g-stop.sh"
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

@test "safety: go acquires the checkout lock before creating a branch" {
    # F-066: go used to create a branch in a shared checkout with no
    # synchronization. The acquire call must appear before the branch
    # creation instruction, not just be present somewhere in the file.
    acquire_line=$(grep -n 'g2g-lock.sh acquire' "$PLUGIN_DIR/commands/go.md" | head -1 | cut -d: -f1)
    branch_line=$(grep -n 'Create `g2g/go-<slug>`' "$PLUGIN_DIR/commands/go.md" | head -1 | cut -d: -f1)
    [[ -n "$acquire_line" && -n "$branch_line" ]] \
        || { echo "go.md missing acquire or branch-creation line (acquire=$acquire_line branch=$branch_line)"; return 1; }
    [[ "$acquire_line" -lt "$branch_line" ]] \
        || { echo "go.md must acquire the lock before creating the branch"; return 1; }
    grep -q 'live-owner' "$PLUGIN_DIR/commands/go.md"
}

@test "safety: go releases the lock on abort paths, never with release-terminal" {
    # go arms no .g2g-goal, so its release must be the lock-only form —
    # release-terminal would delete a foreign build's goal file.
    grep -q 'release-preflight' "$PLUGIN_DIR/commands/go.md"
    grep -qi 'failure paths of verification' "$PLUGIN_DIR/commands/go.md"
    grep -qi "acquisition itself failed\|acquisition-failure path" "$PLUGIN_DIR/commands/go.md"
    if grep -qE '\brelease-terminal <owner-token>' "$PLUGIN_DIR/commands/go.md"; then
        echo "go.md must never call release-terminal (would delete a foreign .g2g-goal)"
        return 1
    fi
}

@test "safety: go refreshes the heartbeat before push" {
    # A go run is not reliably short; without a pre-push refresh a stale
    # reclaim by another build could be pushed past silently.
    refresh_lines=$(grep -n 'g2g-lock.sh refresh' "$PLUGIN_DIR/commands/go.md" | cut -d: -f1)
    push_line=$(grep -n 'git push -u origin' "$PLUGIN_DIR/commands/go.md" | head -1 | cut -d: -f1)
    [[ -n "$refresh_lines" && -n "$push_line" ]] \
        || { echo "go.md missing refresh or push line"; return 1; }
    found_before_push=0
    for line in $refresh_lines; do
        if [[ "$line" -lt "$push_line" ]]; then
            found_before_push=1
        fi
    done
    [[ "$found_before_push" -eq 1 ]] \
        || { echo "go.md has no heartbeat refresh before the push"; return 1; }
    grep -q 'ownership-lost' "$PLUGIN_DIR/commands/go.md"
    grep -qi 'possibly contested' "$PLUGIN_DIR/commands/go.md"
}

@test "safety: go releases its lock on a step 1 preflight abort, not just step 3-5 failures" {
    # T-001 follow-up: step 0's acquire happens BEFORE step 1's preflight
    # (git-status/default-branch checks) and step 2's implementation, but
    # the original release instruction (step 5a) only enumerated the
    # failure paths of verification/commit/push/PR-creation. A dirty-tree
    # or default-branch abort at step 1 (or an abandoned step 2) is a
    # terminal path reached after a successful acquire with no release,
    # which would block every subsequent /g2g:build, /g2g:go, and
    # /g2g:review in the checkout as LIVE for the full stale threshold —
    # a regression versus pre-lock /g2g:go, which took no lock at all.
    # Model: build.md's LOCK RELEASE ON PREFLIGHT ABORT block.
    grep -q 'LOCK RELEASE ON PREFLIGHT ABORT' "$PLUGIN_DIR/commands/go.md"
    grep -qi "step 1's preflight aborts" "$PLUGIN_DIR/commands/go.md"
    grep -qi "step 2's abandonment" "$PLUGIN_DIR/commands/go.md"
    # The addition must not swallow step 0's own rule that acquisition
    # failure (exit 4/2/6/7/8) never releases — that lock is someone
    # else's.
    grep -qi "acquisition itself failed\|acquisition-failure path" "$PLUGIN_DIR/commands/go.md"
    grep -qi "acquisition failure specifically" "$PLUGIN_DIR/commands/go.md"
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
    # build-wf no longer writes its own goal condition; it defers to
    # build.md's Phase 2 so one goal schema and one hook serve both paths.
    grep -q "build.md's Phase 2" "$PLUGIN_DIR/commands/build-wf.md"
    ! grep -q 'The most recent G2G EVIDENCE block in the transcript' \
        "$PLUGIN_DIR/commands/build-wf.md" \
        || { echo "build-wf resurrected a duplicate prose goal condition"; return 1; }
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

@test "safety: spec.md still aborts on an existing slug, and the guard is not duplicated" {
    # spec.md step 4 already refuses to overwrite an existing spec file;
    # T-004 (F-065, writer half) must not add a second copy of that guard
    # while wiring in the new liveness check.
    grep -q 'never overwrite an existing spec' "$PLUGIN_DIR/commands/spec.md"
    count=$(grep -c 'never overwrite an existing spec' "$PLUGIN_DIR/commands/spec.md")
    [[ "$count" -eq 1 ]] \
        || { echo "expected exactly 1 overwrite-guard mention in spec.md, got $count"; return 1; }
}

@test "safety: spec.md queries the lock before writing its spec file, and warns-and-proceeds" {
    # F-065 (writer half): a read-only liveness check must run before the
    # write, and on a live owner spec.md's decision is WARN + proceed
    # (it only ever writes a fresh file under its own slug), not refuse.
    status_line=$(grep -n 'g2g-lock.sh status' "$PLUGIN_DIR/commands/spec.md" | head -1 | cut -d: -f1)
    write_line=$(grep -n 'Write `specs/<slug>.json`' "$PLUGIN_DIR/commands/spec.md" | head -1 | cut -d: -f1)
    [[ -n "$status_line" && -n "$write_line" ]] \
        || { echo "spec.md missing status query or write step (status=$status_line write=$write_line)"; return 1; }
    [[ "$status_line" -lt "$write_line" ]] \
        || { echo "spec.md must query lock liveness before writing the spec file"; return 1; }
    grep -q 'live-owner' "$PLUGIN_DIR/commands/spec.md"
    grep -qi 'WARN' "$PLUGIN_DIR/commands/spec.md"
    grep -q 'stale-debris' "$PLUGIN_DIR/commands/spec.md"
    grep -qi 'owner token' "$PLUGIN_DIR/commands/spec.md"
    grep -qi 'heartbeat' "$PLUGIN_DIR/commands/spec.md"
}

@test "safety: review.md queries the lock before writing, and refuses on a live owner" {
    # F-065 (writer half): review's product is a read-modify-write merge
    # of the tracked backlog, so concurrent review is unsupported by
    # decision — unlike spec.md/dev.md Phase A, a live owner must REFUSE,
    # not warn-and-proceed.
    status_line=$(grep -n 'g2g-lock.sh status' "$PLUGIN_DIR/commands/review.md" | head -1 | cut -d: -f1)
    write_line=$(grep -n 'Write `review-output/findings.json`' "$PLUGIN_DIR/commands/review.md" | head -1 | cut -d: -f1)
    [[ -n "$status_line" && -n "$write_line" ]] \
        || { echo "review.md missing status query or write step (status=$status_line write=$write_line)"; return 1; }
    [[ "$status_line" -lt "$write_line" ]] \
        || { echo "review.md must query lock liveness before writing the findings backlog"; return 1; }
    grep -qi 'REFUSE' "$PLUGIN_DIR/commands/review.md"
    grep -qi 'unsupported' "$PLUGIN_DIR/commands/review.md"
    grep -q 'live-owner' "$PLUGIN_DIR/commands/review.md"
    grep -q 'stale-debris' "$PLUGIN_DIR/commands/review.md"
    grep -qi 'owner token' "$PLUGIN_DIR/commands/review.md"
    grep -qi 'heartbeat' "$PLUGIN_DIR/commands/review.md"
}

@test "safety: dev.md Phase A instructs the pre-write liveness check, warn-and-proceed" {
    # dev.md Phase A executes spec.md's procedure verbatim, but T-004
    # requires dev.md to name the check explicitly too so a reader of
    # dev.md alone sees the behavior and its justification.
    phase_a=$(sed -n '/^## Phase A/,/^## Gate/p' "$PLUGIN_DIR/commands/dev.md")
    echo "$phase_a" | grep -q 'g2g-lock.sh status' \
        || { echo "dev.md Phase A does not mention the liveness query"; return 1; }
    echo "$phase_a" | grep -qi 'WARN' \
        || { echo "dev.md Phase A does not state the WARN-and-proceed choice"; return 1; }
    echo "$phase_a" | grep -qi 'live owner\|live-owner' \
        || { echo "dev.md Phase A does not name the live-owner case"; return 1; }
    echo "$phase_a" | grep -qi 'stale' \
        || { echo "dev.md Phase A does not name the stale-debris case"; return 1; }
}

@test "safety: dev.md Phase A's stale-debris branch names the owner token and heartbeat" {
    # T-004's criterion is "All three [spec.md, review.md, dev.md] report
    # the owner token and heartbeat when a lock is present." spec.md and
    # review.md already state this directly for stale-debris; dev.md
    # previously met it only indirectly, via delegation to spec.md's step
    # 3a. This pins that dev.md's own prose names both fields too.
    stale_clause=$(grep -A4 'on stale debris' "$PLUGIN_DIR/commands/dev.md")
    echo "$stale_clause" | grep -qi 'owner token' \
        || { echo "dev.md's stale-debris branch does not name the owner token"; return 1; }
    echo "$stale_clause" | grep -qi 'heartbeat' \
        || { echo "dev.md's stale-debris branch does not name the heartbeat"; return 1; }
}

@test "safety: spec.md, review.md, and dev.md's Phase A never mutate the checkout lock" {
    # T-003's status query is strictly non-mutating; these three commands
    # are polite neighbors, not lock owners, so none may acquire,
    # refresh, or release the lock, or hand-create/delete the goal/mutex.
    for f in spec.md review.md dev.md; do
        for token in 'g2g-lock.sh acquire' 'g2g-lock.sh refresh' 'release-preflight' 'release-terminal'; do
            if grep -qF "$token" "$PLUGIN_DIR/commands/$f"; then
                echo "$f must never call: $token"
                return 1
            fi
        done
    done
}
