#!/usr/bin/env bats

# Behavioral tests for scripts/check-version-bump.sh in --base (pull
# request) mode. The --since half is exercised through tag-release.sh in
# tests/tag_release.bats, where it actually runs.
#
# This is the pre-merge half of CLAUDE.md's one-bump-per-PR rule: a branch
# that changes installed plugin behavior must bump the version and add the
# matching CHANGELOG section. Blocking it here beats reporting it from the
# tag job after the merge has already reddened the default branch.

BUMP_SH="$BATS_TEST_DIRNAME/../scripts/check-version-bump.sh"

setup() {
    cd "$BATS_TEST_TMPDIR" || return 1
    rm -rf repo
    git init -q repo
    cd repo || return 1
    git config user.email t@example.com
    git config user.name Tester
    mkdir -p plugin/.claude-plugin plugin/commands
    write_version 0.1.0
    printf '# Changelog\n\n## 0.1.0 (2026-01-01)\n\nBody for 0.1.0.\n' > CHANGELOG.md
    echo base > plugin/commands/build.md
    echo base > plugin/README.md
    git add -A
    git commit -q -m "base"
    git branch -q base-ref
    git checkout -q -b feature
}

write_version() {
    printf '{\n  "name": "g2g",\n  "version": "%s"\n}\n' "$1" > plugin/.claude-plugin/plugin.json
}

# Bump the version and add its CHANGELOG section, as the rule requires.
bump_to() {
    write_version "$1"
    printf '# Changelog\n\n## %s (2026-01-01)\n\nBody for %s.\n\n## 0.1.0 (2026-01-01)\n\nBody for 0.1.0.\n' "$1" "$1" > CHANGELOG.md
}

@test "check-version-bump: fails when plugin behavior changes with no bump" {
    echo changed > plugin/commands/build.md
    git commit -qam "change a command"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"leaves the version at 0.1.0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"plugin/commands/build.md"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: passes when the behavior change carries a bump" {
    echo changed > plugin/commands/build.md
    bump_to 0.2.0
    git commit -qam "change a command and bump"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"0.1.0 -> 0.2.0"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: passes for a docs-only edit under plugin/" {
    echo changed > plugin/README.md
    git commit -qam "edit plugin docs"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -eq 0 ]] || { echo "docs-only edit demanded a bump: $output"; return 1; }
    [[ "$output" == *"no release-sensitive plugin changes"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: passes for a branch that touches nothing under plugin/" {
    echo note > note.txt
    git add -A && git commit -qm "repo infrastructure only"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: fails when the bump has no CHANGELOG section" {
    echo changed > plugin/commands/build.md
    write_version 0.2.0
    git commit -qam "bump without notes"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"no non-empty '## 0.2.0' section"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: a behavior change reverted within the branch needs no bump" {
    # The net diff is what ships, so a change made and undone requires
    # nothing — flagging it would be a false positive that a pointless
    # version bump is the only way to silence.
    echo changed > plugin/commands/build.md
    git commit -qam "change a command"
    echo base > plugin/commands/build.md
    git commit -qam "revert it"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: treats a new plugin subdirectory as release-sensitive" {
    # The path rule is an EXCLUDE list on purpose: a directory added later
    # must be covered by default, or the guard silently stops applying.
    mkdir -p plugin/brand-new
    echo thing > plugin/brand-new/thing.json
    git add -A && git commit -qm "add a new plugin directory"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -ne 0 ]] || { echo "a new plugin dir escaped the guard: $output"; return 1; }
    [[ "$output" == *"plugin/brand-new/thing.json"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: rejects a version that goes backwards" {
    # 0.0.9 differs from the base, so a mere inequality check called it a
    # bump. It would merge and then wedge the tag job.
    echo changed > plugin/commands/build.md
    bump_to 0.0.9
    git commit -qam "downgrade"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"BACKWARDS"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: rejects reuse of an already-released version" {
    # Forward from the base, but that version's tag exists and is never
    # moved, so the new code would have no release of its own.
    git tag -a g2g--v0.2.0 base-ref -m "already released"
    echo changed > plugin/commands/build.md
    bump_to 0.2.0
    git commit -qam "reuse a released version"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"already released"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: two open branches claiming one version clash only after the first tag exists" {
    # Two branches bump to 0.2.0. While both are unmerged no tag exists, so
    # PR mode cannot see the clash — the first run passing is the documented
    # limit of a pre-merge check, not a bug. Once the first branch merges
    # and its tag is cut, a re-run on the second fails; without an
    # up-to-date-branches rule nothing forces that re-run, and the tag job's
    # --since check is the post-merge backstop.
    echo one > plugin/commands/build.md
    bump_to 0.2.0
    git commit -qam "first claimant"
    git checkout -q -b rival base-ref
    echo two > plugin/commands/build.md
    bump_to 0.2.0
    git commit -qam "second claimant"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -eq 0 ]] || { echo "no tag exists yet; the clash must be invisible here: $output"; return 1; }

    # The first claimant merges and the tag job cuts its release.
    git tag -a g2g--v0.2.0 feature -m "0.2.0"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -ne 0 ]] || { echo "expected failure once the tag exists, got 0: $output"; return 1; }
    [[ "$output" == *"already released"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: rejects a version that is not MAJOR.MINOR.PATCH" {
    echo changed > plugin/commands/build.md
    write_version 0.2
    printf '# Changelog\n\n## 0.2 (2026-01-01)\n\nBody for 0.2.\n' > CHANGELOG.md
    git commit -qam "malformed version"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"not MAJOR.MINOR.PATCH"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: rejects a leading-zero version component" {
    echo changed > plugin/commands/build.md
    bump_to 0.02.0
    git commit -qam "leading zero"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"not MAJOR.MINOR.PATCH"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: still accepts an ordinary forward bump across components" {
    # Guards the comparison itself: 0.10.0 > 0.9.0 numerically but not
    # lexically, so a string compare would reject a legitimate release.
    write_version 0.9.0
    printf '# Changelog\n\n## 0.9.0 (2026-01-01)\n\nBody.\n' > CHANGELOG.md
    git add -A && git commit -qm "base at 0.9.0"
    git branch -qf base-ref HEAD
    echo changed > plugin/commands/build.md
    bump_to 0.10.0
    git commit -qam "bump to 0.10.0"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -eq 0 ]] || { echo "rejected a legitimate bump: $output"; return 1; }
}

@test "check-version-bump: catches an installed file RENAMED into an excluded path" {
    # Rename detection reports only the destination, so this looked like a
    # docs-only edit while deleting an installed command.
    mkdir -p plugin/evals
    git mv plugin/commands/build.md plugin/evals/build.md
    git commit -qam "move a command into evals"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -ne 0 ]] || { echo "the rename bypassed the guard: $output"; return 1; }
    [[ "$output" == *"plugin/commands/build.md"* ]] || { echo "$output"; return 1; }
}

@test "check-version-bump: excludes a docs path git would quote" {
    # Without -z, git renders a path containing a newline as
    # "plugin/evals/c\nd.md" — surrounding quotes and all — which no longer
    # matches the plugin/evals/ exclude prefix, so a docs-only file gets
    # classified as installed behavior and demands a pointless bump. Reading
    # NUL-delimited entries keeps the real pathname intact.
    mkdir -p plugin/evals
    touch "$(printf 'plugin/evals/c\nd.md')"
    git add -A && git commit -qm "add a docs file git has to quote"

    run "$BUMP_SH" --base base-ref
    [[ "$status" -eq 0 ]] || { echo "a quoted docs path was misclassified: $output"; return 1; }
}

@test "check-version-bump: rejects an unusable mode or ref" {
    run "$BUMP_SH" --base no-such-ref
    [[ "$status" -eq 2 ]] || { echo "expected exit 2, got $status: $output"; return 1; }

    run "$BUMP_SH"
    [[ "$status" -eq 2 ]] || { echo "expected exit 2, got $status: $output"; return 1; }
}
