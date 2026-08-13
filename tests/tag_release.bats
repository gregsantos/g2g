#!/usr/bin/env bats

# Behavioral tests for scripts/tag-release.sh — these build real git
# histories and EXECUTE the script, rather than grepping the workflow.
# The cases here are the ones HEAD-based tagging gets wrong: a batched
# push whose bump is not the tip, two jobs racing at different HEADs, and
# an existing tag pointing at the wrong commit.

TAG_SH="$BATS_TEST_DIRNAME/../scripts/tag-release.sh"

setup() {
    cd "$BATS_TEST_TMPDIR" || return 1
    rm -rf repo remote.git
    git init -q --bare remote.git
    git init -q repo
    cd repo || return 1
    git config user.email t@example.com
    git config user.name Tester
    git remote add origin ../remote.git
    mkdir -p plugin/.claude-plugin
    export TAG_RELEASE_REMOTE=origin
    # Stand in for the pre-automation history the real baseline tag marks.
    # Every version in these fixtures is introduced AFTER it, so it is in
    # scope; "respects the baseline" below covers the other side.
    plain_commit baseline
    export TAG_RELEASE_BASELINE
    TAG_RELEASE_BASELINE="$(git rev-parse HEAD)"
}

# Commit plugin.json at $1. $2 selects what CHANGELOG.md carries in the
# SAME commit: a matching entry (default), no entry at all, or a heading
# with an empty section.
release_commit() {
    local version="$1" mode="${2:-with-changelog}"
    printf '{\n  "name": "g2g",\n  "version": "%s"\n}\n' "$version" > plugin/.claude-plugin/plugin.json
    case "$mode" in
        no-changelog)
            [[ -f CHANGELOG.md ]] || printf '# Changelog\n' > CHANGELOG.md
            ;;
        empty-section)
            printf '# Changelog\n\n## %s (2026-01-01)\n\n' "$version" > CHANGELOG.md
            ;;
        *)
            printf '# Changelog\n\n## %s (2026-01-01)\n\nBody for %s.\n' "$version" "$version" > CHANGELOG.md
            ;;
    esac
    git add -A
    git commit -q -m "release $version"
}

# Rewrite the CHANGELOG section for $1 with body $2, in its own commit —
# i.e. the paired-edit rule broken by splitting the pair across commits.
changelog_commit() {
    printf '# Changelog\n\n## %s (2026-01-01)\n\n%s\n' "$1" "$2" > CHANGELOG.md
    git add -A
    git commit -q -m "changelog for $1"
}

plain_commit() {
    echo "$1" > "note-$1.txt"
    git add -A
    git commit -q -m "$1"
}

# A change to installed plugin behavior — the kind that requires a bump.
plugin_behavior_commit() {
    mkdir -p plugin/commands
    echo "$1" > plugin/commands/build.md
    git add -A
    git commit -q -m "plugin behavior $1"
}

# A docs-only change under plugin/, which explicitly needs no bump.
plugin_docs_commit() {
    echo "$1" > plugin/README.md
    git add -A
    git commit -q -m "plugin docs $1"
}

@test "tag-release: tags the version-introducing commit, not HEAD, on a batched push" {
    release_commit 0.1.0
    local bump; bump="$(git rev-parse HEAD)"
    plain_commit docs-a
    plain_commit docs-b

    run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$(git rev-list -n1 g2g--v0.1.0)" == "$bump" ]] || {
        echo "tagged $(git rev-list -n1 g2g--v0.1.0), expected $bump"; return 1
    }
}

@test "tag-release: a later docs-only run resolves the same target as the bump run" {
    release_commit 0.1.0
    local bump; bump="$(git rev-parse HEAD)"
    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || return 1
    local from_bump; from_bump="$(git rev-list -n1 g2g--v0.1.0)"
    git tag -d g2g--v0.1.0 >/dev/null

    # Second job sees a later HEAD — the docs commit — and must still land
    # on the bump. This is the race the HEAD-based version got wrong.
    plain_commit docs-a
    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$(git rev-list -n1 g2g--v0.1.0)" == "$from_bump" ]] || return 1
    [[ "$from_bump" == "$bump" ]] || return 1
}

@test "tag-release: exits 0 without rewriting when the tag already points at the right commit" {
    release_commit 0.1.0
    run "$TAG_SH"
    [[ "$status" -eq 0 ]] || return 1
    local first; first="$(git rev-parse g2g--v0.1.0)"

    run "$TAG_SH"
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"already released"* ]] || { echo "$output"; return 1; }
    # Same tag OBJECT, so the annotation was not recreated.
    [[ "$(git rev-parse g2g--v0.1.0)" == "$first" ]] || return 1
}

@test "tag-release: fails loudly when the tag exists on the wrong commit" {
    release_commit 0.1.0
    plain_commit docs-a
    git tag -a g2g--v0.1.0 HEAD -m "misplaced"   # tagged at the docs commit

    run "$TAG_SH"
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0"; return 1; }
    [[ "$output" == *"not the commit that introduced"* ]] || { echo "$output"; return 1; }
}

@test "tag-release: fails and creates no tag when CHANGELOG has no entry for the version" {
    release_commit 0.1.0 no-changelog

    run "$TAG_SH"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$output" == *"no non-empty '## 0.1.0' section"* ]] || { echo "$output"; return 1; }
    run git rev-parse -q --verify refs/tags/g2g--v0.1.0
    [[ "$status" -ne 0 ]] || { echo "a tag was created despite the failure"; return 1; }
}

@test "tag-release: a merge whose bump is on the branch tags the merge commit" {
    # Mirrors the real flow: the version first appears on first-parent AT
    # the merge, so the merge is the target even though the bump commit
    # itself is older on the second parent.
    release_commit 0.1.0
    git tag -a g2g--v0.1.0 HEAD -m seed >/dev/null
    git checkout -q -b feature
    release_commit 0.2.0
    git checkout -q -
    git merge -q --no-ff feature -m "Merge feature"
    local merge; merge="$(git rev-parse HEAD)"

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$(git rev-list -n1 g2g--v0.2.0)" == "$merge" ]] || {
        echo "tagged $(git rev-list -n1 g2g--v0.2.0), expected merge $merge"; return 1
    }
}

@test "tag-release: takes the tag body from the target commit, not the working tree" {
    release_commit 0.1.0
    changelog_commit 0.1.0 "Rewritten AFTER the bump landed."

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    local notes; notes="$(git tag -l --format='%(contents)' g2g--v0.1.0)"
    [[ "$notes" == *"Body for 0.1.0."* ]] || { echo "$notes"; return 1; }
    [[ "$notes" != *"Rewritten AFTER"* ]] || {
        echo "took notes from the working tree, not the target commit"; return 1
    }
}

@test "tag-release: fails when only a later commit adds the CHANGELOG entry" {
    # The batched push the same-commit guard is supposed to catch: the bump
    # commit carries no entry, a following commit adds one. Reading the
    # working tree would let this pass.
    release_commit 0.1.0 no-changelog
    changelog_commit 0.1.0 "Added a commit too late."

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    run git rev-parse -q --verify refs/tags/g2g--v0.1.0
    [[ "$status" -ne 0 ]] || { echo "a tag was created despite the failure"; return 1; }
}

@test "tag-release: fails when the target's CHANGELOG section is empty" {
    release_commit 0.1.0 empty-section

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"no non-empty '## 0.1.0' section"* ]] || { echo "$output"; return 1; }
}

@test "tag-release: keeps '###' subheadings in the annotation" {
    # git's default tag cleanup deletes lines starting with '#' as
    # commentary, which silently ate every subsection heading in the notes.
    release_commit 0.1.0
    changelog_commit 0.1.0 "$(printf '### Added\n- a thing')"
    release_commit 0.2.0
    printf '# Changelog\n\n## 0.2.0 (2026-01-01)\n\n### Added\n- a thing\n' > CHANGELOG.md
    git add -A && git commit -q --amend --no-edit

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    local notes; notes="$(git tag -l --format='%(contents)' g2g--v0.2.0)"
    [[ "$notes" == *"### Added"* ]] || { echo "subheading stripped: $notes"; return 1; }
}

@test "tag-release: warns without failing when an existing tag's annotation drifts" {
    # A wrong TARGET dies; a wrong BODY on the right target only warns,
    # because the tags predating this automation carry hand-written
    # summaries and a published tag is never rewritten.
    release_commit 0.1.0
    git tag -a g2g--v0.1.0 HEAD -m "hand-written summary"

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "expected success, got $status: $output"; return 1; }
    [[ "$output" == *"WARNING"* ]] || { echo "no warning emitted: $output"; return 1; }
    [[ "$output" == *"already released"* ]] || { echo "$output"; return 1; }
    [[ "$(git tag -l --format='%(contents)' g2g--v0.1.0)" == "hand-written summary" ]] || {
        echo "the published annotation was rewritten"; return 1
    }
}

@test "tag-release: tags BOTH versions when one push carries two bumps" {
    # Reading a single version off HEAD tagged only the newer one and never
    # revisited the older, losing that release permanently.
    release_commit 0.1.0
    local first; first="$(git rev-parse HEAD)"
    release_commit 0.2.0
    local second; second="$(git rev-parse HEAD)"

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$(git rev-list -n1 g2g--v0.1.0)" == "$first" ]] || {
        echo "0.1.0 untagged or misplaced"; return 1
    }
    [[ "$(git rev-list -n1 g2g--v0.2.0)" == "$second" ]] || {
        echo "0.2.0 untagged or misplaced"; return 1
    }
}

@test "tag-release: backfills a release an earlier run failed to tag" {
    # Simulates a canceled or failed tag job: 0.1.0 shipped untagged, then
    # 0.2.0 landed. A later run must reconcile BOTH, not just HEAD's.
    release_commit 0.1.0
    local missed; missed="$(git rev-parse HEAD)"
    plain_commit docs-a
    release_commit 0.2.0

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    run git rev-parse -q --verify refs/tags/g2g--v0.1.0
    [[ "$status" -eq 0 ]] || { echo "the missed release was never backfilled"; return 1; }
    [[ "$(git rev-list -n1 g2g--v0.1.0)" == "$missed" ]] || return 1
}

@test "tag-release: never tags a version introduced at or before the baseline" {
    # Pre-automation history contains versions that were never tagged and
    # must stay that way; without a baseline a first run would cut a pile of
    # retroactive tags.
    release_commit 0.1.0
    TAG_RELEASE_BASELINE="$(git rev-parse HEAD)"
    plain_commit docs-a

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"no version transitions since"* ]] || { echo "$output"; return 1; }
    run git rev-parse -q --verify refs/tags/g2g--v0.1.0
    [[ "$status" -ne 0 ]] || { echo "tagged a pre-baseline version"; return 1; }
}

@test "tag-release: fails when plugin behavior changed after the release with no bump" {
    # The silent case: tags are all correct, so the job used to exit 0 green
    # while the merged code was released nowhere.
    release_commit 0.1.0
    plugin_behavior_commit later

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"released nowhere"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"plugin/commands/build.md"* ]] || { echo "$output"; return 1; }
}

@test "tag-release: still cuts the due tag before failing on a missing bump" {
    # Ordering matters: withholding a tag that is legitimately due would
    # recreate the untagged-release failure while reporting a different one.
    release_commit 0.1.0
    local bump; bump="$(git rev-parse HEAD)"
    plugin_behavior_commit later

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -ne 0 ]] || return 1
    [[ "$(git rev-list -n1 g2g--v0.1.0)" == "$bump" ]] || {
        echo "the due tag was withheld"; return 1
    }
}

@test "tag-release: a docs-only change under plugin/ after the release needs no bump" {
    release_commit 0.1.0
    plugin_docs_commit later

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "docs-only edit demanded a bump: $output"; return 1; }
}

@test "tag-release: catches an installed file RENAMED into an excluded path" {
    # Git detects renames and reports only the destination, so moving a
    # command into plugin/evals/ looked like a docs-only change while
    # actually deleting installed behavior.
    mkdir -p plugin/commands
    echo original > plugin/commands/build.md
    git add -A && git commit -q -m "add a command"
    release_commit 0.1.0
    mkdir -p plugin/evals
    git mv plugin/commands/build.md plugin/evals/build.md
    git commit -q -m "move a command into evals"

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -ne 0 ]] || { echo "the rename bypassed the guard: $output"; return 1; }
    [[ "$output" == *"plugin/commands/build.md"* ]] || { echo "$output"; return 1; }
}

@test "tag-release: creates no tag when a version carries trailing junk" {
    # A packed "<version> <commit>" record split on the first space truncated
    # this to a valid-looking 0.2.0 and published g2g--v0.2.0 for a commit
    # whose manifest said something else.
    release_commit "0.2.0 junk"

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"not MAJOR.MINOR.PATCH"* ]] || { echo "$output"; return 1; }
    run git tag -l
    [[ -z "$output" ]] || { echo "created a tag despite the invalid version: $output"; return 1; }
}

@test "tag-release: creates no tag when an EARLIER version carries trailing junk" {
    # HEAD's version is clean, so only the per-transition check can catch
    # this. A packed "<version> <commit>" record split on the first space
    # truncated '0.2.0 junk' to a valid-looking '0.2.0' — whose CHANGELOG
    # heading still matched — and published g2g--v0.2.0 for a commit whose
    # manifest said something else.
    release_commit "0.2.0 junk"
    release_commit 0.3.0

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"not MAJOR.MINOR.PATCH"* ]] || { echo "$output"; return 1; }
    run git tag -l
    [[ -z "$output" ]] || { echo "created a tag from a truncated version: $output"; return 1; }
}

@test "tag-release: refuses a backwards version on a direct push, tagging nothing" {
    # The pre-merge gate only sees pull requests. A direct push lowering the
    # version must fail BEFORE any tag is published, since a release tag
    # cannot be taken back.
    release_commit 0.2.0
    release_commit 0.1.0

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"BACKWARDS"* ]] || { echo "$output"; return 1; }
    # Nothing at all, not even the legitimate earlier one: the sequence is
    # corrupt, so no tag in it can be trusted.
    run git tag -l
    [[ -z "$output" ]] || { echo "published a tag from a corrupt sequence: $output"; return 1; }
}

@test "tag-release: compares the first transition against the baseline's own version" {
    # The ordering check is anchored at the baseline, not merely between
    # transitions, or the first release after it could go backwards freely.
    release_commit 0.5.0
    TAG_RELEASE_BASELINE="$(git rev-parse HEAD)"
    release_commit 0.4.0

    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -ne 0 ]] || { echo "expected failure, got 0: $output"; return 1; }
    [[ "$output" == *"0.5.0 -> 0.4.0"* ]] || { echo "$output"; return 1; }
}

@test "tag-release: a baseline override recovers a wedged history" {
    # An invalid transition already on the default branch cannot be fixed by
    # any later commit: every run replays the same sequence and dies at the
    # same spot, wedging all future releases. The documented recovery is
    # moving TAG_RELEASE_BASELINE past the bad transition — versions at or
    # before it leave the job's scope, and everything after flows again.
    release_commit 0.5.0
    TAG_RELEASE_BASELINE="$(git rev-parse HEAD)"
    release_commit 0.4.0
    local bad; bad="$(git rev-parse HEAD)"
    plain_commit aftermath
    release_commit 0.6.0
    local good; good="$(git rev-parse HEAD)"

    # Wedged: the corrective 0.6.0 bump is in the sequence and does not help.
    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -ne 0 ]] || { echo "expected the wedge, got 0: $output"; return 1; }
    [[ "$output" == *"BACKWARDS"* ]] || { echo "$output"; return 1; }

    # Recovery: the baseline moves to the bad transition itself.
    TAG_RELEASE_BASELINE="$bad"
    TAG_RELEASE_DRY_RUN=1 run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "the baseline override did not recover: $output"; return 1; }
    [[ "$(git rev-list -n1 g2g--v0.6.0)" == "$good" ]] || { echo "0.6.0 was not tagged after recovery"; return 1; }
    run git rev-parse -q --verify refs/tags/g2g--v0.4.0
    [[ "$status" -ne 0 ]] || { echo "the skipped bad version must stay untagged"; return 1; }
}

@test "tag-release: pushes the tag to the remote" {
    release_commit 0.1.0
    git push -q origin HEAD:main
    run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    run git ls-remote --tags origin
    [[ "$output" == *"g2g--v0.1.0"* ]] || { echo "$output"; return 1; }
}
