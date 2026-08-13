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
}

# Commit plugin.json at $1, with a CHANGELOG entry for it unless $2 is "no-changelog".
release_commit() {
    local version="$1" mode="${2:-with-changelog}"
    printf '{\n  "name": "g2g",\n  "version": "%s"\n}\n' "$version" > plugin/.claude-plugin/plugin.json
    if [[ "$mode" != "no-changelog" ]]; then
        printf '# Changelog\n\n## %s (2026-01-01)\n\nBody for %s.\n' "$version" "$version" > CHANGELOG.md
    elif [[ ! -f CHANGELOG.md ]]; then
        printf '# Changelog\n' > CHANGELOG.md
    fi
    git add -A
    git commit -q -m "release $version"
}

plain_commit() {
    echo "$1" > "note-$1.txt"
    git add -A
    git commit -q -m "$1"
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
    [[ "$output" == *"has no '## 0.1.0' heading"* ]] || { echo "$output"; return 1; }
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

@test "tag-release: pushes the tag to the remote" {
    release_commit 0.1.0
    git push -q origin HEAD:main
    run "$TAG_SH"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    run git ls-remote --tags origin
    [[ "$output" == *"g2g--v0.1.0"* ]] || { echo "$output"; return 1; }
}
