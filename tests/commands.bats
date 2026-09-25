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

@test "safety: every slug-deriving command calls the slug helper instead of restating the rule" {
    # F-035: the branch name and spec filename used to be derived from an
    # informal "lowercase, hyphenated form" rule with no charset, so a
    # project value carrying `..`, `/`, or shell metacharacters could reach
    # `git checkout -b` and `gh pr create`. The derivation now lives in one
    # executable helper (tests/plugin_slug.bats proves its semantics);
    # the commands' job is only to call it.
    for cmd in build spec go; do
        grep -q 'g2g-slug.sh' "$PLUGIN_DIR/commands/$cmd.md" \
            || { echo "$cmd.md does not call g2g-slug.sh"; return 1; }
    done
    [[ -x "$PLUGIN_DIR/scripts/g2g-slug.sh" ]] || { echo "g2g-slug.sh is not executable"; return 1; }
    # `! cmd` never trips bats' errexit, so negative guards must be
    # explicit if-blocks to actually enforce anything.
    for cmd in build spec; do
        if grep -q 'lowercase, hyphenated form' "$PLUGIN_DIR/commands/$cmd.md"; then
            echo "$cmd.md still restates the slug rule in prose"; return 1
        fi
    done
}

@test "safety: no command pastes slug input into a double-quoted shell argument" {
    # Codex review of PR #35: `g2g-slug.sh "<project>"` invites the model
    # to paste requirement-derived text into shell source, where $(...)
    # and backticks expand BEFORE the helper sanitizes anything. spec.md
    # must use the --spec form (the name is read from the JSON it just
    # wrote); go.md's model-composed summary must be a single-quoted
    # literal, which Bash never expands.
    grep -q 'g2g-slug.sh --spec' "$PLUGIN_DIR/commands/spec.md" \
        || { echo "spec.md does not derive its slug from the written JSON via --spec"; return 1; }
    grep -q "g2g-slug.sh '" "$PLUGIN_DIR/commands/go.md" \
        || { echo "go.md does not show the single-quoted literal form"; return 1; }
    for cmd in build spec go improve-cycle dev; do
        if grep -q 'g2g-slug.sh "' "$PLUGIN_DIR/commands/$cmd.md"; then
            echo "$cmd.md pastes slug input into a double-quoted argument"; return 1
        fi
    done
}

@test "safety: build passes the project name to git and gh as one argument, never pasted into the command" {
    # The project field is spec-controlled text. Every place it enters a
    # commit message or PR title must read it into a variable (control
    # characters stripped) and pass "$VAR" as a single argument.
    grep -q 'PROJECT_NAME' "$PLUGIN_DIR/commands/build.md" \
        || { echo "build.md has no PROJECT_NAME capture"; return 1; }
    grep -q 'gsub("\[\[:cntrl:\]\]"' "$PLUGIN_DIR/commands/build.md" \
        || { echo "build.md does not strip control characters from the project name"; return 1; }
    if grep -q 'title "g2g: <project>' "$PLUGIN_DIR/commands/build.md"; then
        echo "build.md still interpolates <project> verbatim into a PR title"; return 1
    fi
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
    for k in result commit verified mutation notes; do
        grep -q "$k" "$PLUGIN_DIR/workflows/g2g-build.js" \
            || { echo "builder schema lost field: $k"; return 1; }
        grep -q "$k" "$PLUGIN_DIR/agents/g2g-builder.md" \
            || { echo "agent contract lost field: $k"; return 1; }
    done
    # Builders read the contract file at runtime — one source of truth.
    grep -q 'agents/g2g-builder.md' "$PLUGIN_DIR/workflows/g2g-build.js"
}

@test "workflow: builderSchema's mutation and decision fields are optional; required fields unchanged, result enum gains NEEDS_DECISION" {
    grep -q "required: \['result', 'commit', 'verified', 'notes'\]" "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q "result: { type: 'string', enum: \['DONE', 'FAILED', 'NEEDS_DECISION'\] }" "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q "mutation: { type: 'string' }" "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q "decision: { type: 'string' }" "$PLUGIN_DIR/workflows/g2g-build.js"
}

@test "workflow: the complete-writer agent copies the builder's mutation line into notes" {
    grep -q 'report.mutation' "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q "'not reported'" "$PLUGIN_DIR/workflows/g2g-build.js"
}

@test "workflow: writerSchema gains an optional head field, and the start writer reports HEAD" {
    grep -q "head: { type: 'string' }" "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q 'git rev-parse HEAD.*report the exact output as head' "$PLUGIN_DIR/workflows/g2g-build.js"
}

@test "workflow: a NEEDS_DECISION report is checked against the DISPATCH BASELINE before scoring" {
    grep -q "report.result === 'NEEDS_DECISION'" "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q 'needs-decision check' "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q "task.status = 'blocked'" "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q "notesText = \`needs-human: " "$PLUGIN_DIR/workflows/g2g-build.js"
    # A failed check falls through to the exact same FAILED scoring path
    # as a malformed DONE — never a separate, looser one.
    grep -q "report.result = 'FAILED'" "$PLUGIN_DIR/workflows/g2g-build.js"
    grep -q 'NEEDS_DECISION arrived with changes' "$PLUGIN_DIR/workflows/g2g-build.js"
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

@test "compound: has frontmatter with description and argument-hint matching its behavior" {
    [[ -f "$PLUGIN_DIR/commands/compound.md" ]] \
        || { echo "plugin/commands/compound.md does not exist"; return 1; }
    run sed -n '1p' "$PLUGIN_DIR/commands/compound.md"
    [[ "$output" == "---" ]] || { echo "compound.md missing opening frontmatter delimiter"; return 1; }
    run grep -c '^description:' "$PLUGIN_DIR/commands/compound.md"
    [[ "$output" -ge 1 ]] || { echo "compound.md missing description"; return 1; }
    run grep -c '^argument-hint:' "$PLUGIN_DIR/commands/compound.md"
    [[ "$output" -ge 1 ]] || { echo "compound.md missing argument-hint"; return 1; }
    # The argument-hint must name both accepted argument shapes the body
    # describes: a spec path or an F-NNN finding id.
    grep -q 'spec-path' "$PLUGIN_DIR/commands/compound.md"
    grep -q 'F-NNN' "$PLUGIN_DIR/commands/compound.md"
    # The description must match the capture behavior the body specifies
    # — not a generic label.
    grep -qi 'learning' "$PLUGIN_DIR/commands/compound.md"
}

@test "safety: compound acquires the checkout lock before its first write" {
    acquire_line=$(grep -n 'g2g-lock.sh acquire' "$PLUGIN_DIR/commands/compound.md" | head -1 | cut -d: -f1)
    write_line=$(grep -n 'Write EXACTLY ONE learning' "$PLUGIN_DIR/commands/compound.md" | head -1 | cut -d: -f1)
    [[ -n "$acquire_line" && -n "$write_line" ]] \
        || { echo "compound.md missing acquire or write-step line (acquire=$acquire_line write=$write_line)"; return 1; }
    [[ "$acquire_line" -lt "$write_line" ]] \
        || { echo "compound.md must acquire the lock before writing the learning"; return 1; }
    grep -q 'live-owner' "$PLUGIN_DIR/commands/compound.md"
}

@test "safety: compound releases the lock with release-terminal on every terminal path, abort paths included" {
    # Unlike go.md, compound arms no .g2g-goal of its own but the task
    # contract requires release-terminal specifically (never
    # release-preflight) on every terminal path reached after a
    # successful acquire.
    count=$(grep -c 'release-terminal' "$PLUGIN_DIR/commands/compound.md")
    [[ "$count" -ge 3 ]] || { echo "only $count release-terminal calls in compound.md (need 3+)"; return 1; }
    grep -qi "every terminal path" "$PLUGIN_DIR/commands/compound.md"
    grep -qi "abort paths included" "$PLUGIN_DIR/commands/compound.md"
    grep -qi "acquisition itself failed\|acquisition-failure path" "$PLUGIN_DIR/commands/compound.md"
    if grep -qE '\brelease-preflight <owner-token>' "$PLUGIN_DIR/commands/compound.md"; then
        echo "compound.md must not use release-preflight — the task contract requires release-terminal"
        return 1
    fi
}

@test "safety: compound states a null verifier is a refusal, not a warning" {
    refusal_clause=$(grep -A3 -i "top-level .verifier. field is null" "$PLUGIN_DIR/commands/compound.md")
    echo "$refusal_clause" | grep -qi 'refusal' \
        || { echo "compound.md does not state that a missing verifier verdict is a refusal"; return 1; }
    grep -qi 'not a warning\|not.*warning' "$PLUGIN_DIR/commands/compound.md"
}

@test "safety: compound runs g2g-learning-check.sh and names all three adjudication resolutions" {
    grep -q '\${CLAUDE_PLUGIN_ROOT}/scripts/g2g-learning-check.sh' "$PLUGIN_DIR/commands/compound.md"
    grep -qi 'Fix the claim' "$PLUGIN_DIR/commands/compound.md"
    grep -qi 'Annotate as historical' "$PLUGIN_DIR/commands/compound.md"
    grep -qi 'Confirm intentional' "$PLUGIN_DIR/commands/compound.md"
    grep -qi 'never an automatic pass' "$PLUGIN_DIR/commands/compound.md"
}

@test "safety: compound re-runs the grounding check until clean or every flag is confirmed" {
    grep -qi 're-run the exact same check command\|re-run the SAME check command' "$PLUGIN_DIR/commands/compound.md"
    grep -qi 'until the script exits 0, or every' "$PLUGIN_DIR/commands/compound.md"
}

@test "contract: compound writes exactly one learning file per invocation and says so" {
    grep -qi 'EXACTLY ONE learning' "$PLUGIN_DIR/commands/compound.md"
    grep -qi 'exactly one file changed' "$PLUGIN_DIR/commands/compound.md"
}

@test "safety: compound forbids writing CLAUDE.md, plugin/README.md, or any instruction file" {
    grep -q 'CLAUDE.md' "$PLUGIN_DIR/commands/compound.md"
    grep -qi 'plugin/README.md' "$PLUGIN_DIR/commands/compound.md"
    grep -qi 'never writes.*CLAUDE.md\|out of scope here' "$PLUGIN_DIR/commands/compound.md"
}

@test "contract: compound reads the defining source line and prefers a PR number over a SHA" {
    grep -qi 'defining source line' "$PLUGIN_DIR/commands/compound.md"
    grep -qi 'prefer.*PR number\|cite the PR number' "$PLUGIN_DIR/commands/compound.md"
}

# Issue #19: build.md used to require SYNCHRONOUS subagent dispatch, which
# no harness with an async Agent tool can honor. The orchestrator's turn
# then ended mid-build, the armed Stop hook correctly blocked, and the run
# spun — burning a turn against TURN_CAP per cycle. These pin the corrected
# contract so the stale claim cannot come back.

@test "contract: build.md does not claim subagent dispatch is synchronous" {
    # The invariant is "do not end your turn", not "the tool is synchronous".
    ! grep -q 'SYNCHRONOUSLY' "$PLUGIN_DIR/commands/build.md"
}

@test "contract: build.md documents the BLOCKING WAIT section" {
    grep -q '^## BLOCKING WAIT' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'must not end your turn while a subagent runs' "$PLUGIN_DIR/commands/build.md"
}

@test "contract: every subagent dispatch in build.md cites BLOCKING WAIT" {
    # Two dispatches (builder, verifier) and two waits must all point at it,
    # plus the section heading itself: five references in total.
    run grep -c 'BLOCKING WAIT' "$PLUGIN_DIR/commands/build.md"
    [[ "$output" -ge 5 ]] || { echo "only $output BLOCKING WAIT references"; return 1; }
}

@test "safety: build.md forbids reading a subagent's own output file" {
    # Reading it overflows the orchestrator context and loses the build.
    grep -qi 'NEVER block on, Read, or tail the SUBAGENT' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'JSONL transcript' "$PLUGIN_DIR/commands/build.md"
}

@test "contract: build.md treats a subagent that dies without a report as a scored case, not an abandoned run" {
    grep -qi 'dies without\|died without' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'not a reason to abandon' "$PLUGIN_DIR/commands/build.md"
}

# Issue #29: a builder whose BUILDER REPORT never arrived was scored a
# FAILED attempt even when its commit was already on the branch — the
# commit was consulted only on a reported DONE — so a reporting failure
# counted as a work failure and two of them blocked the task. Step 7 now
# consults the branch tip first; these pin the fallback's shape.

@test "contract: build.md scores a missing BUILDER REPORT by the branch tip, not straight to FAILED" {
    grep -q 'NO-REPORT FALLBACK' "$PLUGIN_DIR/commands/build.md"
    grep -q 'HEAD unchanged' "$PLUGIN_DIR/commands/build.md"
    grep -q 'HEAD moved' "$PLUGIN_DIR/commands/build.md"
    # A block truncated after the marker (the incident's own shape) is a
    # missing report too, not a FAILED attempt.
    grep -q 'report as absent and apply the NO-REPORT FALLBACK' "$PLUGIN_DIR/commands/build.md"
    # A DONE whose commit: is unreadable is a missing report too: step 8's
    # DONE path checks that commit and cannot with no sha to check.
    grep -q 'for DONE, `commit:` reads' "$PLUGIN_DIR/commands/build.md"
    grep -q 'cannot with no sha to' "$PLUGIN_DIR/commands/build.md"
}

@test "contract: the no-report baseline is HEAD after the start commit, never a message grep" {
    # The orchestrator's own `chore(<task-id>): start` carries the task id,
    # so a commit-message grep would match the orchestrator's commit.
    grep -q 'AFTER step 5' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'never grep commit messages' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: the no-report fallback keeps uncertainty scored as failure and the orchestrator read-only" {
    grep -q 'silence plus no commit is still a failed attempt' "$PLUGIN_DIR/commands/build.md"
    grep -q 'cannot establish with real output counts' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'never edit a file and never fix a shortfall' "$PLUGIN_DIR/commands/build.md"
    grep -q 'committed wrong work, or work' "$PLUGIN_DIR/commands/build.md"
    grep -q 'you could not judge, is a genuine failed attempt' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: the no-report fallback rechecks HEAD and tree cleanliness after verifying" {
    # A verification command that regenerates tracked files and exits 0
    # describes the modified checkout, not the commit; g2g-evidence.sh
    # refuses a proven verdict on the same drift, and so must the fallback.
    grep -q 'Postcondition: after the last command, HEAD still equals the TIP' "$PLUGIN_DIR/commands/build.md"
    grep -q 'regardless of how the commands exited' "$PLUGIN_DIR/commands/build.md"
    # Preflight exempts a freshly generated spec; the fallback must not
    # inherit that, since step 5 committed the spec before dispatch and a
    # spec mutated by a verification command would be committed as
    # bookkeeping in step 8. CLEAN must also cover untracked paths: a
    # test file never git-added makes the tree pass and the commit fail.
    grep -q 'never the spec: step 5 committed it' "$PLUGIN_DIR/commands/build.md"
    grep -q 'the spec byte-for-byte what step 5 committed' "$PLUGIN_DIR/commands/build.md"
    grep -q 'staged, unstaged, and untracked alike' "$PLUGIN_DIR/commands/build.md"
    # Plain `git status --porcelain` honors status.showUntrackedFiles=no,
    # which hides exactly the files CLEAN exists to catch.
    grep -q 'git status --porcelain --untracked-files=all' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: the no-report fallback repairs only the spec, from the baseline, and commits only the spec" {
    # `git checkout -- <path>` restores from the INDEX, so a staged
    # mutation survives it and rides into the bookkeeping commit. The
    # restore must come from the dispatch baseline for index and worktree
    # both, and every bookkeeping commit must be limited to the spec path
    # so nothing else a verification command staged is swept in.
    grep -q 'git restore --source=<baseline> --staged --worktree -- <spec-path>' "$PLUGIN_DIR/commands/build.md"
    grep -q 'SPEC RESTORE rule' "$PLUGIN_DIR/commands/build.md"
    # The restore must run on every fallback outcome, not only after a
    # drifted verification: a builder commit that touched the spec fails
    # the PREcondition with a clean status, and step 8 would otherwise
    # write attempts into the mutated spec.
    grep -q 'on ANY' "$PLUGIN_DIR/commands/build.md"
    grep -q 'fallback outcome ((a), (c), or HEAD unchanged)' "$PLUGIN_DIR/commands/build.md"
    grep -q 'is NOT this: it restores from the index' "$PLUGIN_DIR/commands/build.md"
    grep -q 'Touch nothing else: no reset, no' "$PLUGIN_DIR/commands/build.md"
    grep -q 'BOOKKEEPING COMMIT' "$PLUGIN_DIR/commands/build.md"
    grep -qF -- '-- <spec-path>` — never `-a`' "$PLUGIN_DIR/commands/build.md"
    # Both step-8 branches must commit that way.
    run grep -c 'BOOKKEEPING COMMIT' "$PLUGIN_DIR/commands/build.md"
    [[ "$output" -ge 3 ]] || { echo "only $output BOOKKEEPING COMMIT references"; return 1; }
}

# Issue #31: the REPORTED DONE/FAILED paths reached step 8 with no check
# that the builder left the spec alone, so a builder that edited the spec
# against g2g-builder.md rule 6 and then reported normally had its
# mutation committed as bookkeeping — while the NO-REPORT FALLBACK already
# restored the spec and scored the attempt FAILED. Reporting must not be
# the less-guarded route into step 8.

@test "safety: step 8 applies the SPEC RESTORE rule on every entry, reported or fallback" {
    grep -q 'every entry into this step' "$PLUGIN_DIR/commands/build.md"
    grep -q 'as much as a fallback verdict' "$PLUGIN_DIR/commands/build.md"
    # The restore mechanics stay defined ONCE, in step 7 (d); step 8 must
    # reference that rule, not restate a second copy that can drift.
    grep -q 'apply the SPEC RESTORE rule (step 7 d)' "$PLUGIN_DIR/commands/build.md"
    # Step 5's baseline is now consumed by step 8 too, and the text must
    # say so or a reader of step 8 has no idea where <baseline> came from.
    grep -q 'DISPATCH BASELINE steps 7 and 8 compare' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: a reported builder that modified the spec scores FAILED regardless of its result line" {
    # Option 2 from #31: a builder that broke rule 6 has an untrustworthy
    # report on the other rules too, and this is the only verdict
    # consistent with the fallback's precondition (a), which already
    # scores a spec-touching builder FAILED without verifying.
    grep -q 'FAILED regardless of its reported result' "$PLUGIN_DIR/commands/build.md"
    grep -q 'broke rule 6' "$PLUGIN_DIR/commands/build.md"
    # Notes must carry the reported result and sha as recovery context.
    grep -q 'the result and `commit:` it reported' "$PLUGIN_DIR/commands/build.md"
}

# PR #32 adversarial review (high): the heartbeat refreshes only at the
# start of a turn, and a builder or verifier wait is inside the turn, so
# a wait longer than the lock's stale threshold lets another build
# reclaim the checkout and advance the spec. Step 8's restore would then
# rewrite the replacement build's spec from this build's baseline. The
# refresh must therefore run again after the wait, before anything the
# subagent produced is scored and before anything is written.

@test "safety: every subagent wait ends with an ownership-checked refresh before scoring or writing" {
    grep -q 'POST-WAIT REFRESH' "$PLUGIN_DIR/commands/build.md"
    grep -q 'anything the subagent produced and before writing anything' "$PLUGIN_DIR/commands/build.md"
    # Defined once, in BLOCKING WAIT, which applies to every dispatch;
    # step 7 and Phase 4 step 2 must reference it, not restate it.
    run grep -c 'POST-WAIT REFRESH' "$PLUGIN_DIR/commands/build.md"
    [[ "$output" -ge 3 ]] || { echo "only $output POST-WAIT REFRESH references"; return 1; }
    # OWNERSHIP LOST must acknowledge this new entry so its
    # "reached only from" claim stays true.
    grep -q 'the POST-WAIT REFRESH' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: BLOCKING WAIT hands off to scoring only from the post-wait refresh, never from step 4" {
    # PR #32 re-review: step 4 ended "then score it by that step", a
    # handoff that reached step 7's fallback and step 8's restore before
    # step 5's refresh ran. Step 4 must end at detecting FINISHED; step 5
    # is the sole handoff, after exit 0.
    ! grep -q 'then score it by that step' "$PLUGIN_DIR/commands/build.md"
    grep -q 'the ONLY handoff out of this section' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: g2g-verifier.md frontmatter narrows tools to exactly Read, Grep, Glob, Bash" {
    # T-001: the tools allowlist is layer one of the read-only-verifier
    # enforcement — it must name exactly these four tools, no Edit,
    # Write, or NotebookEdit that would let the verifier mutate the
    # checkout through a direct tool call.
    run sed -n '1,10p' "$PLUGIN_DIR/agents/g2g-verifier.md"
    [[ "$output" == *$'\ntools: Read, Grep, Glob, Bash\n'* ]] \
        || { echo "tools line missing or not exact in g2g-verifier.md frontmatter"; return 1; }
    ! grep -qE '^tools:.*(Edit|Write|NotebookEdit)' "$PLUGIN_DIR/agents/g2g-verifier.md"
}

@test "safety: build.md Phase 4 records a PRE-VERIFY SNAPSHOT before the verifier dispatch" {
    # Layer two of the read-only-verifier enforcement (T-001): Bash
    # remains on the verifier's tools list and can still write files, so
    # the allowlist alone proves nothing — this snapshot-and-compare is
    # the actual check.
    grep -q 'PRE-VERIFY SNAPSHOT' "$PLUGIN_DIR/commands/build.md"
    grep -q 'git rev-parse HEAD' "$PLUGIN_DIR/commands/build.md"
    grep -q 'git status --porcelain --untracked-files=all' "$PLUGIN_DIR/commands/build.md"
    # Phase 4 step 1 must record it before dispatch, and reference the
    # goal/lock/mutex trio as the filtered exemption.
    grep -q 'goal/lock/mutex trio' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: build.md Phase 4 compares the snapshot after POST-WAIT REFRESH and before the verdict" {
    grep -q 'take the same snapshot' "$PLUGIN_DIR/commands/build.md"
    grep -q 'PRE-VERIFY SNAPSHOT from step 1' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'verifier changed the checkout' "$PLUGIN_DIR/commands/build.md"
    # Any drift must ignore the verdict (PASS included), write nothing to
    # the spec, revert nothing, and route to Phase 5 naming the drift.
    grep -qi 'ignore its verdict entirely' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'write nothing to the spec, revert nothing' "$PLUGIN_DIR/commands/build.md"
    grep -q 'straight to Phase 5' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'naming the drift' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: build-wf.md contains no copy of the PRE-VERIFY SNAPSHOT check" {
    # build-wf.md executes build.md's Phase 4 by reference (F-046-style
    # composition), so the snapshot check must reach it automatically —
    # never be duplicated as prose here.
    ! grep -q 'PRE-VERIFY SNAPSHOT' "$PLUGIN_DIR/commands/build-wf.md"
    grep -q "build.md's Phase 4" "$PLUGIN_DIR/commands/build-wf.md"
}

# T-002: mutation proof for new tests. A test that would still pass
# against broken code is not evidence; rule 9 requires break/FAIL/
# restore/PASS before the single commit, reported via a new `mutation:`
# field that is additive (never a hard gate) end to end.

@test "contract: g2g-builder.md rule 9 requires break, FAIL, restore, PASS before the single commit" {
    grep -q '^9\. Mutation proof' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -q 'before your' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -q 'run that test and show it FAIL' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -q 'restore the code' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -q 'run it again and show it PASS' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -qi 'must be fixed before you commit' "$PLUGIN_DIR/agents/g2g-builder.md"
}

@test "contract: the BUILDER REPORT template has mutation: between verified: and notes:" {
    v_line=$(grep -n '^verified:' "$PLUGIN_DIR/agents/g2g-builder.md" | tail -1 | cut -d: -f1)
    m_line=$(grep -n '^mutation:' "$PLUGIN_DIR/agents/g2g-builder.md" | tail -1 | cut -d: -f1)
    n_line=$(grep -n '^notes:' "$PLUGIN_DIR/agents/g2g-builder.md" | tail -1 | cut -d: -f1)
    [[ -n "$v_line" && -n "$m_line" && -n "$n_line" ]] || { echo "missing one of verified:/mutation:/notes:"; return 1; }
    [[ "$v_line" -lt "$m_line" ]] || { echo "mutation: is not after verified:"; return 1; }
    [[ "$m_line" -lt "$n_line" ]] || { echo "mutation: is not before notes:"; return 1; }
}

@test "contract: build.md step 7 names mutation:, step 8 copies it or defaults to not reported, and never fails on absence alone" {
    grep -q '`mutation:`' "$PLUGIN_DIR/commands/build.md"
    grep -q 'never scored FAILED by itself' "$PLUGIN_DIR/commands/build.md"
    grep -q 'mutation: not reported"' "$PLUGIN_DIR/commands/build.md" || grep -q '`mutation: not reported`' "$PLUGIN_DIR/commands/build.md"
    grep -q 'mutation: not reported (BUILDER REPORT never arrived)' "$PLUGIN_DIR/commands/build.md"
}

@test "contract: g2g-verifier.md sends missing mutation evidence to flags, never findings" {
    grep -q '^6\. Mutation evidence check' "$PLUGIN_DIR/agents/g2g-verifier.md"
    grep -qi 'never a finding' "$PLUGIN_DIR/agents/g2g-verifier.md"
    grep -q 'under `flags:`' "$PLUGIN_DIR/agents/g2g-verifier.md"
    grep -q 'still a FAIL finding under step 3' "$PLUGIN_DIR/agents/g2g-verifier.md"
}

@test "contract: the VERIFIER REPORT template has flags: after commands:" {
    c_line=$(grep -n '^commands:' "$PLUGIN_DIR/agents/g2g-verifier.md" | tail -1 | cut -d: -f1)
    f_line=$(grep -n '^flags:' "$PLUGIN_DIR/agents/g2g-verifier.md" | tail -1 | cut -d: -f1)
    [[ -n "$c_line" && -n "$f_line" ]] || { echo "missing commands: or flags:"; return 1; }
    [[ "$c_line" -lt "$f_line" ]] || { echo "flags: is not after commands:"; return 1; }
}

@test "contract: build.md Phase 4 reads the verifier's flags: field and folds it into the Flags subsection of every PR body (T-003)" {
    grep -q '`flags:`' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'treated as none' "$PLUGIN_DIR/commands/build.md"
    # T-003 moved the verifier's flags lines out of the inline body summary
    # and into the dedicated ### Flags subsection of the Needs your
    # attention section — pinned below, not the old inline phrasing.
    grep -q '### Flags' "$PLUGIN_DIR/commands/build.md"
    grep -q 'Needs your attention' "$PLUGIN_DIR/commands/build.md"
}

# T-003: a NEEDS_DECISION exit for a task that cannot be completed without a
# human choice, and FLAG lines for anything a builder could not check that
# lies outside the acceptance criteria. Both surface in the PR body's
# "Needs your attention" section instead of being invisible.

@test "contract: g2g-builder.md allows NEEDS_DECISION, defines decision:, and requires commit: none plus an untouched tree" {
    grep -q 'result: DONE | FAILED | NEEDS_DECISION' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -q '^10\. NEEDS_DECISION' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -q '`commit: none`' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -qi 'leave the tree exactly as you found it' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -q '^decision:' "$PLUGIN_DIR/agents/g2g-builder.md"
    # Never a substitute for FAILED.
    grep -qi 'never a substitute for FAILED' "$PLUGIN_DIR/agents/g2g-builder.md"
}

@test "contract: the BUILDER REPORT template has decision: between mutation: and notes:" {
    m_line=$(grep -n '^mutation:' "$PLUGIN_DIR/agents/g2g-builder.md" | tail -1 | cut -d: -f1)
    d_line=$(grep -n '^decision:' "$PLUGIN_DIR/agents/g2g-builder.md" | tail -1 | cut -d: -f1)
    n_line=$(grep -n '^notes:' "$PLUGIN_DIR/agents/g2g-builder.md" | tail -1 | cut -d: -f1)
    [[ -n "$m_line" && -n "$d_line" && -n "$n_line" ]] || { echo "missing one of mutation:/decision:/notes:"; return 1; }
    [[ "$m_line" -lt "$d_line" ]] || { echo "decision: is not after mutation:"; return 1; }
    [[ "$d_line" -lt "$n_line" ]] || { echo "decision: is not before notes:"; return 1; }
}

@test "contract: g2g-builder.md has the FLAG rule; an unverifiable criterion is FAILED, never a FLAG" {
    grep -q '^11\. FLAG lines' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -q '`FLAG: `' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -qi 'a FLAG never substitutes for a criterion' "$PLUGIN_DIR/agents/g2g-builder.md"
    grep -qi 'you could not verify with real.*output is FAILED, never a FLAG' "$PLUGIN_DIR/agents/g2g-builder.md"
}

@test "contract: build.md Phase 3 step 7 counts a NEEDS_DECISION report as usable" {
    grep -q 'reads as `DONE`, `FAILED`, or `NEEDS_DECISION`' "$PLUGIN_DIR/commands/build.md"
    grep -q 'for NEEDS_DECISION, `commit:` reads exactly `none`' "$PLUGIN_DIR/commands/build.md"
}

@test "contract: build.md step 8 checks HEAD and tree itself before honoring a NEEDS_DECISION" {
    grep -q 'Then, on result NEEDS_DECISION' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'never trust the builder.s own claim' "$PLUGIN_DIR/commands/build.md"
    grep -q 'HEAD still equals the DISPATCH BASELINE and the tree is CLEAN' "$PLUGIN_DIR/commands/build.md"
    grep -q 'set status: blocked, leave `attempts` UNCHANGED' "$PLUGIN_DIR/commands/build.md"
    grep -q 'notes to `needs-human: `' "$PLUGIN_DIR/commands/build.md"
    # The entry gate still runs first, and a NEEDS_DECISION it overrules
    # (spec was dirtied) falls to FAILED, never to the blocked path.
    grep -qi 'A NEEDS_DECISION this gate overruled' "$PLUGIN_DIR/commands/build.md"
    grep -q "a reported NEEDS_DECISION this step's own" "$PLUGIN_DIR/commands/build.md"
}

@test "contract: every gh pr create in build.md passes the body with --body-file from a mktemp -d file" {
    # 'gh pr create --title "g2g: ...' is the real invocation shape at all
    # three call sites (Phase 4 steps 5 and 7, Phase 5 step 2); the generic
    # PR BODY COMPOSITION description uses a `<title>` placeholder instead,
    # so this pattern counts real invocations only.
    invocations=$(grep -c 'gh pr create --title "g2g:' "$PLUGIN_DIR/commands/build.md")
    with_body_file=$(grep -c 'gh pr create --title "g2g:.*--body-file' "$PLUGIN_DIR/commands/build.md")
    [[ "$invocations" -eq 3 ]] || { echo "expected 3 gh pr create invocations, found $invocations"; return 1; }
    [[ "$invocations" -eq "$with_body_file" ]] || { echo "not every gh pr create invocation uses --body-file"; return 1; }
    grep -q 'PR BODY COMPOSITION' "$PLUGIN_DIR/commands/build.md"
    grep -q 'mktemp -d' "$PLUGIN_DIR/commands/build.md"
}

@test "contract: the PR body gains a Needs your attention section with Decisions for you and Flags subsections" {
    grep -q '## Needs your attention' "$PLUGIN_DIR/commands/build.md"
    grep -q '### Decisions for you' "$PLUGIN_DIR/commands/build.md"
    grep -q '### Flags' "$PLUGIN_DIR/commands/build.md"
    grep -qi 'OMITTED ENTIRELY when both parts below are' "$PLUGIN_DIR/commands/build.md"
}

@test "contract: status.md reports needs-human tasks and gains no write instruction" {
    grep -qi 'needs-human' "$PLUGIN_DIR/commands/status.md"
    grep -q 'read-only (change nothing)' "$PLUGIN_DIR/commands/status.md"
    # The needs-human step itself must read only — never write, commit, or
    # edit the spec on a human's behalf.
    needs_human_block=$(sed -n '/Needs-human tasks (read-only/,/never through this command\./p' "$PLUGIN_DIR/commands/status.md")
    [[ -n "$needs_human_block" ]] || { echo "no Needs-human tasks step found"; return 1; }
    echo "$needs_human_block" | grep -qi 'a human answers' \
        || { echo "needs-human step does not say a human answers, not this command"; return 1; }
    echo "$needs_human_block" | grep -qiE '\bwrite\b|\bcommit\b|\bmodify\b' \
        && { echo "needs-human step picked up a write instruction"; return 1; }
    true
}

@test "contract: writing-g2g-specs SKILL.md documents the needs-human convention and its recovery path" {
    grep -qi 'needs-human' "$PLUGIN_DIR/skills/writing-g2g-specs/SKILL.md"
    grep -q '\-\-continue-branch' "$PLUGIN_DIR/skills/writing-g2g-specs/SKILL.md"
    grep -qi 'status back to' "$PLUGIN_DIR/skills/writing-g2g-specs/SKILL.md"
    # The status field's documented values gain no new entry.
    grep -q 'in_progress.*complete.*blocked' "$PLUGIN_DIR/skills/writing-g2g-specs/SKILL.md"
}

@test "contract: plugin/README.md and G2G_PLUGIN_REF.md document NEEDS_DECISION and FLAG lines" {
    grep -q 'NEEDS_DECISION' "$REPO_DIR/plugin/README.md"
    grep -qi 'FLAG' "$REPO_DIR/plugin/README.md"
    grep -q 'NEEDS_DECISION' "$REPO_DIR/docs/G2G_PLUGIN_REF.md"
    grep -qi 'FLAG' "$REPO_DIR/docs/G2G_PLUGIN_REF.md"
}
