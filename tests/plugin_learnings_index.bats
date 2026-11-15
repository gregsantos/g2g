#!/usr/bin/env bats

# Tests for plugin/scripts/g2g-learnings-index.sh — the builder-facing
# index of docs/learnings/ (issue #20, F-006). Every fixture lives in its
# own temporary git repo so tests never depend on this repo's own store.

INDEX="$BATS_TEST_DIRNAME/../plugin/scripts/g2g-learnings-index.sh"

setup() {
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/docs/learnings/scripts" "$REPO/docs/learnings/hooks"
    cd "$REPO" || return 1
    git init -q -b main
}

write_knowledge() {
    # write_knowledge <path> <id> <title> <tags-line>
    cat > "$1" <<EOF
---
id: $2
title: $3
date: 2026-08-18
track: knowledge
area: scripts
severity: medium
$4
---

# $2: $3

Body text that must never appear in the index.
EOF
}

@test "learnings-index: exact golden output for a valid store, sorted by path" {
    write_knowledge docs/learnings/scripts/b.md L-002 "Second thing" "tags: [x, y]"
    write_knowledge docs/learnings/scripts/a.md L-001 "First thing" "tags: [foo]"
    run "$INDEX"
    [ "$status" -eq 0 ]
    expected="=== G2G LEARNINGS INDEX ===
L-001 | scripts | medium | foo | docs/learnings/scripts/a.md | First thing
L-002 | scripts | medium | x,y | docs/learnings/scripts/b.md | Second thing
summary: 2 indexed | 0 skipped
=== END G2G LEARNINGS INDEX ==="
    [ "$output" = "$expected" ]
}

@test "learnings-index: block-list tags are joined in the same canonical form" {
    write_knowledge docs/learnings/scripts/a.md L-001 "Block tags" "tags:
  - alpha
  - beta"
    run "$INDEX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"L-001 | scripts | medium | alpha,beta | docs/learnings/scripts/a.md | Block tags"* ]]
}

@test "learnings-index: never prints a learning body" {
    write_knowledge docs/learnings/scripts/a.md L-001 "First thing" "tags: [foo]"
    run "$INDEX"
    [ "$status" -eq 0 ]
    [[ "$output" != *"must never appear"* ]]
}

@test "learnings-index: an invalid learning is skipped and named, never indexed" {
    write_knowledge docs/learnings/scripts/good.md L-001 "Good" "tags: [foo]"
    write_knowledge docs/learnings/scripts/bad.md L-9 "Bad id" "tags: [foo]"
    printf 'no frontmatter here\n' > docs/learnings/hooks/raw.md
    run "$INDEX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped: docs/learnings/scripts/bad.md (invalid frontmatter: id does not match L-NNN: L-9)"* ]]
    [[ "$output" == *"skipped: docs/learnings/hooks/raw.md (invalid frontmatter: missing opening --- delimiter)"* ]]
    [[ "$output" != *"| Bad id"* ]]
    [[ "$output" == *"summary: 1 indexed | 2 skipped"* ]]
}

@test "learnings-index: agrees with g2g-learning-check about what is invalid" {
    # Both scripts source one parser; a learning the checker rejects must
    # be the learning the index skips, for the same reason.
    write_knowledge docs/learnings/scripts/bad.md L-001 "Bad area" "tags: [foo]"
    sed -i.bak 's/^area: scripts$/area: nowhere/' docs/learnings/scripts/bad.md
    rm -f docs/learnings/scripts/bad.md.bak
    run "$BATS_TEST_DIRNAME/../plugin/scripts/g2g-learning-check.sh" docs/learnings/scripts/bad.md
    [ "$status" -eq 2 ]
    [[ "$output" == *"frontmatter: INVALID area not in enum: nowhere"* ]]
    run "$INDEX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(invalid frontmatter: area not in enum: nowhere)"* ]]
}

@test "learnings-index: an absent or empty store is an empty index, exit 0" {
    rm -rf docs/learnings
    run "$INDEX"
    [ "$status" -eq 0 ]
    expected="=== G2G LEARNINGS INDEX ===
summary: 0 indexed | 0 skipped
=== END G2G LEARNINGS INDEX ==="
    [ "$output" = "$expected" ]
}

@test "learnings-index: anchors to the worktree root when run from a subdirectory" {
    write_knowledge docs/learnings/scripts/a.md L-001 "First thing" "tags: [foo]"
    mkdir -p deep/er
    cd deep/er
    run "$INDEX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"| docs/learnings/scripts/a.md | First thing"* ]]
}

@test "learnings-index: exit 2 when the given directory does not exist" {
    run "$INDEX" no/such/dir
    [ "$status" -eq 2 ]
    [[ "$output" == *"learnings directory not found: no/such/dir"* ]]
}

@test "learnings-index: a control character in a title is flattened to a space" {
    printf -- '---\nid: L-001\ntitle: Real\rL-999 | hooks | high | x | forged.md | Forged\ndate: 2026-08-18\ntrack: knowledge\narea: scripts\nseverity: low\ntags: [foo]\n---\nbody\n' \
        > docs/learnings/scripts/a.md
    run "$INDEX"
    [ "$status" -eq 0 ]
    # Frontmatter is read line by line, so a value can never carry a
    # newline; a carriage return would still overwrite the line on a
    # terminal and pass for a second entry. It must arrive as a space.
    [[ "$output" != *$'\r'* ]]
    [[ "$output" == *"| Real L-999 | hooks | high | x | forged.md | Forged"* ]]
    [[ "$output" == *"summary: 1 indexed | 0 skipped"* ]]
}

@test "learnings-index: contains no model or network invocation and writes nothing" {
    ! grep -Eq '\b(claude|curl|wget|nc)\b' "$INDEX" "$BATS_TEST_DIRNAME/../plugin/scripts/lib/g2g-learning-frontmatter.sh"
    write_knowledge docs/learnings/scripts/a.md L-001 "First thing" "tags: [foo]"
    before="$(find . -path ./.git -prune -o -type f -print | sort)"
    run "$INDEX"
    [ "$status" -eq 0 ]
    after="$(find . -path ./.git -prune -o -type f -print | sort)"
    [ "$before" = "$after" ]
}

@test "learnings-index: is executable with a bash shebang" {
    [ -x "$INDEX" ]
    [ "$(head -1 "$INDEX")" = "#!/usr/bin/env bash" ]
}
