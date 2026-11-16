#!/usr/bin/env bats

# Tests for plugin/scripts/g2g-timing.sh — per-task wall clock and
# dispatch counts read back from a build branch's bookkeeping commits
# (issue #25, measure first). The block is printed into every build PR
# body, so its format is golden-pinned here.

TIMING="$BATS_TEST_DIRNAME/../plugin/scripts/g2g-timing.sh"
T0=1700000000

setup() {
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    cd "$REPO"
    git init -q -b main
    git config user.email t@example.invalid
    git config user.name t
    git config commit.gpgsign false
    commit_at 0 "initial"
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q -b g2g/build
}

# commit_at <seconds after T0> <subject> [committer offset] — an empty
# commit whose AUTHOR date is T0+offset; the committer date defaults to
# the same instant unless a third argument moves it.
commit_at() {
    local at=$((T0 + $1)) committed=$((T0 + ${3:-$1}))
    GIT_AUTHOR_DATE="@$at +0000" GIT_COMMITTER_DATE="@$committed +0000" \
        git commit -q --allow-empty -m "$2"
}

spec() {
    printf '%s\n' "$1" > "$REPO/spec.json"
}

THREE_TASKS='{"tasks": [
  {"id": "T-001", "dependsOn": []},
  {"id": "T-002"},
  {"id": "T-003", "dependsOn": ["T-001", "T-002"]}]}'

@test "timing: script exists and is executable" {
    [[ -x "$TIMING" ]] || { echo "g2g-timing.sh missing or not executable"; return 1; }
}

@test "timing: golden block for a clean three-task build" {
    spec "$THREE_TASKS"
    commit_at 0 "chore(T-001): start"
    commit_at 200 "feat(T-001): first"
    commit_at 300 "chore(T-001): complete"
    commit_at 310 "chore(T-002): start"
    commit_at 910 "chore(T-002): complete"
    commit_at 920 "chore(T-003): start"
    commit_at 1040 "chore(T-003): complete"
    run "$TIMING" spec.json
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    expected="=== G2G TIMING ===
spec: spec.json
range: $(git rev-parse origin/main)..HEAD
task   outcome      dispatches  wall
T-001  complete     1           5m00s
T-002  complete     1           10m00s
T-003  complete     1           2m00s
summary: tasks=3 measured=3 elapsed=17m20s serial=17m00s critical-path=12m00s fan-out-ceiling=1.41x
=== END G2G TIMING ==="
    [[ "$output" == "$expected" ]] || { diff <(echo "$expected") <(echo "$output"); return 1; }
}

@test "timing: a retry with no start commit of its own is timed from the previous bookkeeping commit" {
    spec '{"tasks": [{"id": "T-001"}]}'
    commit_at 0 "chore(T-001): start"
    commit_at 100 "chore(T-001): attempt 1"
    commit_at 250 "chore(T-001): complete"
    run "$TIMING" spec.json
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    [[ "$output" == *"T-001  complete     2           4m10s"* ]] || { echo "$output"; return 1; }
}

@test "timing: blocked, needs-human, unfinished, and unmeasured outcomes" {
    spec '{"tasks": [{"id": "A"}, {"id": "B"}, {"id": "C"}, {"id": "D"}]}'
    commit_at 0 "chore(A): start"
    commit_at 60 "chore(A): attempt 1"
    commit_at 120 "chore(A): attempt 2, blocked"
    commit_at 130 "chore(B): start"
    commit_at 190 "chore(B): needs-human"
    commit_at 200 "chore(C): start"
    run "$TIMING" spec.json
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    [[ "$output" == *"A     blocked      2           2m00s"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"B     needs-human  1           1m00s"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"C     unfinished   0           0s"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"D     unmeasured   0           0s"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"summary: tasks=4 measured=2 "* ]] || { echo "$output"; return 1; }
}

@test "timing: a terminal commit with nothing before it in range counts as an untimed dispatch" {
    spec '{"tasks": [{"id": "T-001"}]}'
    commit_at 50 "chore(T-001): complete"
    run "$TIMING" spec.json
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    [[ "$output" == *"T-001  complete     1           0s (1 untimed)"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"fan-out-ceiling=n/a"* ]] || { echo "$output"; return 1; }
}

@test "timing: author dates are measured, so a rebase's new committer dates change nothing" {
    spec '{"tasks": [{"id": "T-001"}]}'
    commit_at 0 "chore(T-001): start" 5000
    commit_at 90 "chore(T-001): complete" 5001
    run "$TIMING" spec.json
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    [[ "$output" == *"T-001  complete     1           1m30s"* ]] || { echo "$output"; return 1; }
}

@test "timing: only exact spec ids and bookkeeping subjects count" {
    spec '{"tasks": [{"id": "T.1"}]}'
    commit_at 0 "chore(TX1): start"
    commit_at 10 "chore(T.1): start"
    commit_at 20 "chore(T.1): rename spec"
    commit_at 30 "fix(T.1): complete"
    commit_at 70 "chore(T.1): complete"
    commit_at 80 "chore(TX1): complete"
    run "$TIMING" spec.json
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    [[ "$output" == *"T.1   complete     1           1m00s"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"elapsed=1m00s"* ]] || { echo "$output"; return 1; }
}

@test "timing: the default range starts at the merge-base with the remote default branch" {
    spec '{"tasks": [{"id": "T-001"}]}'
    commit_at 0 "chore(T-001): start"
    commit_at 40 "chore(T-001): complete"
    git update-ref refs/remotes/origin/main HEAD
    commit_at 100 "chore(T-001): start"
    commit_at 130 "chore(T-001): complete"
    run "$TIMING" spec.json
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    [[ "$output" == *"T-001  complete     1           30s"* ]] || { echo "$output"; return 1; }
}

@test "timing: --range overrides the default" {
    spec '{"tasks": [{"id": "T-001"}]}'
    commit_at 0 "chore(T-001): start"
    commit_at 40 "chore(T-001): complete"
    git update-ref refs/remotes/origin/main HEAD
    run "$TIMING" spec.json --range main..origin/main
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    [[ "$output" == *"range: main..origin/main"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"T-001  complete     1           40s"* ]] || { echo "$output"; return 1; }
}

@test "timing: exit 2 naming --range when there is no remote default branch" {
    spec '{"tasks": [{"id": "T-001"}]}'
    git update-ref -d refs/remotes/origin/main
    run "$TIMING" spec.json
    [[ "$status" -eq 2 ]] || { echo "expected exit 2, got $status: $output"; return 1; }
    [[ "$output" == *"--range"* ]] || { echo "message does not name --range: $output"; return 1; }
}

@test "timing: exit 2 on a missing, invalid, or malformed spec" {
    run "$TIMING" nope.json
    [[ "$status" -eq 2 ]] || { echo "missing: got $status: $output"; return 1; }
    printf 'not json' > bad.json
    run "$TIMING" bad.json
    [[ "$status" -eq 2 ]] || { echo "invalid: got $status: $output"; return 1; }
    spec '{"tasks": [{"id": 7}]}'
    run "$TIMING" spec.json
    [[ "$status" -eq 2 ]] || { echo "numeric id: got $status: $output"; return 1; }
    spec '{"tasks": [{"id": "A", "dependsOn": "B"}]}'
    run "$TIMING" spec.json
    [[ "$status" -eq 2 ]] || { echo "string dependsOn: got $status: $output"; return 1; }
}

@test "timing: exit 2 on an unknown argument, an option-shaped range, or an unreadable range" {
    spec '{"tasks": [{"id": "T-001"}]}'
    run "$TIMING" spec.json --full
    [[ "$status" -eq 2 ]] || { echo "unknown arg: got $status: $output"; return 1; }
    run "$TIMING" spec.json --range
    [[ "$status" -eq 2 ]] || { echo "bare --range: got $status: $output"; return 1; }
    run "$TIMING" spec.json --range --output=x
    [[ "$status" -eq 2 ]] || { echo "option range: got $status: $output"; return 1; }
    [[ ! -e x ]] || { echo "an option-shaped range reached git log"; return 1; }
    run "$TIMING" spec.json --range no-such-ref..HEAD
    [[ "$status" -eq 2 ]] || { echo "bad range: got $status: $output"; return 1; }
}

@test "timing: control characters in a task id never reach the output" {
    spec '{"tasks": [{"id": "T-1\nverdict: complete (proven)"}]}'
    run "$TIMING" spec.json
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    while IFS= read -r line; do
        [[ "$line" != verdict:* ]] || { echo "id injected a line: $output"; return 1; }
    done <<< "$output"
}

@test "timing: read-only — the checkout and refs are unchanged" {
    spec "$THREE_TASKS"
    commit_at 0 "chore(T-001): start"
    commit_at 10 "chore(T-001): complete"
    before="$(git rev-parse HEAD) $(git status --porcelain --untracked-files=all | sort | tr '\n' ' ')"
    run "$TIMING" spec.json
    [[ "$status" -eq 0 ]] || { echo "exit $status: $output"; return 1; }
    after="$(git rev-parse HEAD) $(git status --porcelain --untracked-files=all | sort | tr '\n' ' ')"
    [[ "$before" == "$after" ]] || { echo "before: $before"; echo "after: $after"; return 1; }
}
