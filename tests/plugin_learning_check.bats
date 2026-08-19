#!/usr/bin/env bats

# Tests for plugin/scripts/g2g-learning-check.sh — the deterministic
# grounding validator for docs/learnings/. Every fixture lives in its own
# temporary git repo (never under the real docs/learnings/) so tests never
# depend on, or pollute, this repo's own learnings store.

CHECK="$BATS_TEST_DIRNAME/../plugin/scripts/g2g-learning-check.sh"

setup() {
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/docs/learnings/scripts" "$REPO/plugin/scripts"
    cd "$REPO" || return 1
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    echo "x" > plugin/scripts/real.sh
    git add -A
    git -c user.email=t@t -c user.name=t commit -q -m "add real.sh"
    ON_DEFAULT_SHA="$(git rev-parse HEAD)"

    # Wire an origin remote whose HEAD is main, so the script can actually
    # distinguish "reachable from the upstream default branch" from
    # "reachable only from HEAD" — without an origin every resolvable SHA
    # is conservatively head-only, which would collapse both cases.
    BARE="$BATS_TEST_TMPDIR/origin.git"
    git init -q --bare "$BARE"
    git remote add origin "$BARE"
    git push -q origin main
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

    # A commit that exists only on a feature branch off HEAD — never
    # pushed to origin/main — for the head-only case.
    git checkout -q -b feature
    echo "y" >> plugin/scripts/real.sh
    git add -A
    git -c user.email=t@t -c user.name=t commit -q -m "feature only commit"
    HEAD_ONLY_SHA="$(git rev-parse HEAD)"
    git checkout -q main
}

write_good_knowledge() {
    # write_good_knowledge <path>
    cat > "$1" <<EOF
---
id: L-001
title: Something learned
date: 2026-08-18
track: knowledge
area: scripts
severity: medium
tags: [foo, bar]
---

# L-001: Something learned

## Context
Some context that triggered capture.

## Decision
Do the thing going forward.

## Rationale
Because of reasons grounded in the tree.

## Evidence
See \`plugin/scripts/real.sh\` and commit $ON_DEFAULT_SHA.

## Implication
This must stay true.
EOF
}

write_good_bug() {
    # write_good_bug <path>
    cat > "$1" <<EOF
---
id: L-002
title: A fixed defect
date: 2026-08-18
track: bug
area: scripts
severity: high
tags: [foo]
symptoms: something broke in production
rootCause: the actual mechanism, cited below
resolution: fixed by the cited commit
---

# L-002: A fixed defect

## Context
What triggered the investigation.

## Root Cause
See \`plugin/scripts/real.sh\`, fixed in $ON_DEFAULT_SHA.

## Resolution
What changed and where.

## Evidence
\`plugin/scripts/real.sh\` and $ON_DEFAULT_SHA.

## Implication
What must stay true going forward.
EOF
}

@test "learning-check: a fully grounded knowledge-track file exits 0" {
    write_good_knowledge "docs/learnings/scripts/good.md"
    run "$CHECK" docs/learnings/scripts/good.md
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"summary: 1 files | 0 invalid | 0 flagged | 1 clean"* ]]
}

@test "learning-check: a fully grounded bug-track file exits 0" {
    write_good_bug "docs/learnings/scripts/good-bug.md"
    run "$CHECK" docs/learnings/scripts/good-bug.md
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "learning-check: exit 2 when the given path does not exist" {
    run "$CHECK" docs/learnings/scripts/nope.md
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"learning file not found"* ]]
}

@test "learning-check: exit 2 when frontmatter is missing a required field" {
    cat > docs/learnings/scripts/bad.md <<'EOF'
---
id: L-004
title: Missing severity
date: 2026-08-18
track: knowledge
area: scripts
tags: [foo]
---

# L-004: Missing severity

## Context
x

## Decision
y

## Rationale
z

## Evidence
n/a

## Implication
n/a
EOF
    run "$CHECK" docs/learnings/scripts/bad.md
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"frontmatter: INVALID"*"severity"* ]]
}

@test "learning-check: exit 2 on a bad enum value, a malformed date, and a missing closing delimiter" {
    cat > docs/learnings/scripts/bad-enum.md <<'EOF'
---
id: L-005
title: Bad area enum
date: 2026-08-18
track: knowledge
area: not-a-real-area
severity: medium
tags: [foo]
---

## Decision
x

## Rationale
y

## Evidence
n/a

## Implication
n/a
EOF
    run "$CHECK" docs/learnings/scripts/bad-enum.md
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"area not in enum"* ]]

    cat > docs/learnings/scripts/bad-date.md <<'EOF'
---
id: L-006
title: Bad date
date: 08/18/2026
track: knowledge
area: scripts
severity: medium
tags: [foo]
---

## Decision
x

## Rationale
y

## Evidence
n/a

## Implication
n/a
EOF
    run "$CHECK" docs/learnings/scripts/bad-date.md
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"date is not YYYY-MM-DD"* ]]

    printf -- '---\nid: L-007\ntitle: No closing delimiter\ndate: 2026-08-18\ntrack: knowledge\narea: scripts\nseverity: medium\ntags: [foo]\n' > docs/learnings/scripts/no-close.md
    run "$CHECK" docs/learnings/scripts/no-close.md
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"missing closing --- delimiter"* ]]
}

@test "learning-check: exit 2 when a knowledge-track file carries bug-only fields" {
    cat > docs/learnings/scripts/wrong-track.md <<'EOF'
---
id: L-008
title: Knowledge with bug fields
date: 2026-08-18
track: knowledge
area: scripts
severity: medium
tags: [foo]
symptoms: should not be here
---

## Decision
x

## Rationale
y

## Evidence
n/a

## Implication
n/a
EOF
    run "$CHECK" docs/learnings/scripts/wrong-track.md
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"knowledge track must omit symptoms/rootCause/resolution"* ]]
}

@test "learning-check: exit 3 when no learning files exist under docs/learnings" {
    rm -rf docs/learnings
    mkdir -p docs/learnings
    run "$CHECK"
    [[ "$status" -eq 3 ]]
    [[ "$output" == *"no learning files found to check"* ]]
}

@test "learning-check: exit 4 when a cited repo-relative path does not exist" {
    write_good_knowledge "docs/learnings/scripts/missing-path.md"
    sed -i.bak 's#plugin/scripts/real.sh#plugin/scripts/does-not-exist.sh#' docs/learnings/scripts/missing-path.md
    run "$CHECK" docs/learnings/scripts/missing-path.md
    [[ "$status" -eq 4 ]]
    [[ "$output" == *"path: \`plugin/scripts/does-not-exist.sh\` -> FLAG missing"* ]]
}

@test "learning-check: a SHA reachable only from HEAD gets a distinct flag from a SHA that resolves nowhere" {
    write_good_knowledge "docs/learnings/scripts/shas.md"
    {
        echo ""
        echo "## More evidence"
        echo "Head-only: $HEAD_ONLY_SHA. Unresolved: deadbeef1234."
    } >> docs/learnings/scripts/shas.md
    run "$CHECK" docs/learnings/scripts/shas.md
    [[ "$status" -eq 4 ]]
    [[ "$output" == *"sha: $HEAD_ONLY_SHA -> FLAG head-only (resolves but is not reachable from the upstream default branch)"* ]]
    [[ "$output" == *"sha: deadbeef1234 -> FLAG unresolved (does not resolve to a commit)"* ]]
    # The two labels must be textually distinct from each other.
    [[ "$output" != *"deadbeef1234 -> FLAG head-only"* ]]
    [[ "$output" != *"$HEAD_ONLY_SHA -> FLAG unresolved"* ]]
}

@test "learning-check: a SHA on the default branch resolves ok, not flagged" {
    write_good_knowledge "docs/learnings/scripts/ondefault.md"
    run "$CHECK" docs/learnings/scripts/ondefault.md
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"sha: $ON_DEFAULT_SHA -> ok (reachable from origin/main)"* ]]
}

@test "learning-check: drafting scaffold raises a flag for mustache, bare TODO, and Learning <digit>" {
    write_good_knowledge "docs/learnings/scripts/scaffold.md"
    {
        echo ""
        echo "## Scaffold leftovers"
        echo "{{ placeholder }}"
        echo "a bare TODO right here"
        echo "Learning 2 draft heading text"
    } >> docs/learnings/scripts/scaffold.md
    run "$CHECK" docs/learnings/scripts/scaffold.md
    [[ "$status" -eq 4 ]]
    [[ "$output" == *"scaffold: FLAG mustache {{"* ]]
    [[ "$output" == *"scaffold: FLAG bare TODO"* ]]
    [[ "$output" == *'scaffold: FLAG "Learning <digit>" placeholder'* ]]
}

@test "learning-check: a broken relative markdown link raises a flag" {
    write_good_knowledge "docs/learnings/scripts/link.md"
    {
        echo ""
        echo "## More"
        echo "[broken](../does-not-exist.md)"
    } >> docs/learnings/scripts/link.md
    run "$CHECK" docs/learnings/scripts/link.md
    [[ "$status" -eq 4 ]]
    [[ "$output" == *"link: ../does-not-exist.md -> FLAG missing"* ]]
}

@test "learning-check: exact header and summary line, golden-output style" {
    write_good_knowledge "docs/learnings/scripts/golden.md"
    run "$CHECK" docs/learnings/scripts/golden.md
    [[ "$status" -eq 0 ]]
    [[ "${lines[0]}" == "=== G2G LEARNING CHECK ===" ]]
    last_line=$(echo "$output" | tail -n 1)
    [[ "$last_line" == "=== END G2G LEARNING CHECK ===" ]]
    [[ "$output" == *"summary: 1 files | 0 invalid | 0 flagged | 1 clean"* ]]
}

@test "learning-check: never edits the input file, even on a flagged run" {
    write_good_knowledge "docs/learnings/scripts/untouched.md"
    {
        echo ""
        echo "## More"
        echo "{{ scaffold }}"
        echo "[broken](../nope.md)"
    } >> docs/learnings/scripts/untouched.md
    before_sum="$(cksum docs/learnings/scripts/untouched.md)"
    run "$CHECK" docs/learnings/scripts/untouched.md
    [[ "$status" -eq 4 ]]
    after_sum="$(cksum docs/learnings/scripts/untouched.md)"
    [[ "$before_sum" == "$after_sum" ]]
}

@test "learning-check: no argument validates every file under docs/learnings" {
    write_good_knowledge "docs/learnings/scripts/one.md"
    write_good_bug "docs/learnings/scripts/two.md"
    run "$CHECK"
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"summary: 2 files | 0 invalid | 0 flagged | 2 clean"* ]]
}

@test "learning-check: a directory argument with clean learnings exits 0" {
    write_good_knowledge "docs/learnings/scripts/one.md"
    write_good_bug "docs/learnings/scripts/two.md"
    run "$CHECK" docs/learnings/scripts
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"summary: 2 files | 0 invalid | 0 flagged | 2 clean"* ]]
}

@test "learning-check: a directory argument with no learning files exits 3" {
    mkdir -p docs/learnings/scripts/empty-subdir
    run "$CHECK" docs/learnings/scripts/empty-subdir
    [[ "$status" -eq 3 ]]
    [[ "$output" == *"no learning files found to check"* ]]
}

@test "learning-check: docs/learnings/ itself as a directory argument behaves like no argument" {
    write_good_knowledge "docs/learnings/scripts/one.md"
    write_good_bug "docs/learnings/scripts/two.md"
    run "$CHECK" docs/learnings
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"summary: 2 files | 0 invalid | 0 flagged | 2 clean"* ]]
}

@test "learning-check: an absolute path in backticks does not raise a flag" {
    write_good_knowledge "docs/learnings/scripts/abs-path.md"
    {
        echo ""
        echo "## More evidence"
        echo "System toolchain: \`/opt/homebrew/bin/bash\`."
    } >> docs/learnings/scripts/abs-path.md
    run "$CHECK" docs/learnings/scripts/abs-path.md
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" != *"/opt/homebrew/bin/bash"*"FLAG"* ]]
    [[ "$output" != *"path: \`/opt/homebrew/bin/bash\`"* ]]
}

@test "learning-check: contains no model or network invocation" {
    run grep -Ei 'claude|curl|wget|http' "$CHECK"
    # The only match allowed is the case-pattern that SKIPS http(s) links
    # when resolving relative markdown targets — not a functional call site.
    [[ "$status" -eq 0 ]]
    while IFS= read -r matched_line; do
        [[ -n "$matched_line" ]] || continue
        [[ "$matched_line" == *'http://*|https://*|mailto:*'* ]] \
            || { echo "unexpected network/model reference: $matched_line"; return 1; }
    done <<< "$output"
}

@test "learning-check: is executable with a bash shebang" {
    [[ -x "$CHECK" ]]
    first_line="$(sed -n '1p' "$CHECK")"
    [[ "$first_line" == "#!/usr/bin/env bash" ]]
}
