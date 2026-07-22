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

@test "safety: build acquires the checkout lock atomically before arming" {
    # A double-arm race is prevented by an atomic fail-if-exists create,
    # not a check-then-write. The lock stays separate from .g2g-goal.
    grep -qiE 'noclobber|atomic' "$PLUGIN_DIR/commands/build.md"
    grep -q '.g2g-goal.lock' "$PLUGIN_DIR/commands/build.md"
}

@test "safety: improve-cycle wrapper does not delete build.md's goal/lock" {
    # The wrapper must not disarm a nested build by deleting .g2g-goal it
    # does not own; build.md owns the .g2g-goal/.g2g-goal.lock lifecycle.
    grep -q 'Do NOT delete `.g2g-goal`' "$PLUGIN_DIR/commands/improve-cycle.md"
}

@test "models: routing pins agree with the config contract" {
    grep -q 'models.builder' "$PLUGIN_DIR/commands/build.md"
    grep -q 'models.verifier' "$PLUGIN_DIR/commands/build.md"
    grep -q '^model: sonnet' "$PLUGIN_DIR/commands/go.md"
    grep -q '^model: haiku' "$PLUGIN_DIR/commands/status.md"
}

@test "metadata: plugin and marketplace names agree" {
    plugin_name=$(jq -r '.name' "$PLUGIN_DIR/.claude-plugin/plugin.json")
    market_entry=$(jq -r '.plugins[0].name' "$REPO_DIR/.claude-plugin/marketplace.json")
    [[ "$plugin_name" == "$market_entry" ]]
    [[ "$(jq -r '.plugins[0].source' "$REPO_DIR/.claude-plugin/marketplace.json")" == "./plugin" ]]
}
