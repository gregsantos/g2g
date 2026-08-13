#!/usr/bin/env bats
#
# Behavioural contract for plugin/scripts/g2g-stop.sh — the deterministic
# Stop hook. These are the tests that matter most in this repo: the bug this
# script replaced was a *branch* error, not a parsing error. An LLM evaluator
# reached the correct finding ("no goal was armed in this session") and then
# blocked the stop anyway. So every fail-open path below is pinned
# individually, because each one is a way that failure could return.
#
# Contract: exit 0 with empty stdout = allow the stop. Exit 0 with a
# {"decision":"block"} object = block it. The hook never exits nonzero.

setup() {
    REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    HOOK="$REPO_DIR/plugin/scripts/g2g-stop.sh"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    # A real git work tree, so the hook's head-binding check (T-001) has a
    # genuine short HEAD sha and tracked-dirty count to compare fixtures
    # against -- exactly the state g2g-evidence.sh would have stamped.
    git -C "$WORK" init -q
    git -C "$WORK" config user.email "g2g-test@example.com"
    git -C "$WORK" config user.name "g2g test"
    echo "seed" > "$WORK/seed.txt"
    git -C "$WORK" add seed.txt
    git -C "$WORK" commit -q -m "seed"
    WORK_HEAD_SHA="$(git -C "$WORK" rev-parse --short HEAD)"
    WORK_HEAD_DIRTY="$(git -C "$WORK" status --porcelain --untracked-files=no | wc -l | tr -d '[:space:]')"
    WORK_HEAD_LINE="head: $WORK_HEAD_SHA (tracked-dirty: $WORK_HEAD_DIRTY)"
    TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
    TOKEN="g2g-test-12345"
    NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Write a goal file. Args: token specPath turnCap hoursCap buildStart
write_goal() {
    cat > "$WORK/.g2g-goal" <<EOF
{"version": 1, "ownerToken": "$1", "specPath": "$2",
 "taskTotal": 2, "turnCap": $3, "hoursCap": $4, "buildStart": "$5"}
EOF
}

# Run the hook with a payload pointing at $WORK and $TRANSCRIPT.
run_hook() {
    local transcript="${1:-$TRANSCRIPT}"
    run env -u CLAUDE_PROJECT_DIR bash -c \
        "printf '%s' '{\"cwd\":\"$WORK\",\"transcript_path\":\"$transcript\",\"stop_hook_active\":false}' | bash '$HOOK'"
}

# Run the hook with a payload whose cwd is some OTHER directory (a
# subdirectory of the worktree, or a directory outside any repository) --
# exercises the anchor resolution (F-064) the plain run_hook above cannot,
# since that always starts already at the worktree root.
run_hook_from_cwd() {
    local cwd="$1" transcript="${2:-$TRANSCRIPT}"
    run env -u CLAUDE_PROJECT_DIR bash -c \
        "printf '%s' '{\"cwd\":\"$cwd\",\"transcript_path\":\"$transcript\",\"stop_hook_active\":false}' | bash '$HOOK'"
}

assert_allowed() {
    [[ "$status" -eq 0 ]] || { echo "hook exited $status, expected 0"; return 1; }
    [[ -z "$output" ]] || { echo "expected allow (no output), got: $output"; return 1; }
}

assert_blocked() {
    [[ "$status" -eq 0 ]] || { echo "hook exited $status, expected 0"; return 1; }
    [[ "$output" == *'"decision":"block"'* ]] \
        || { echo "expected a block decision, got: $output"; return 1; }
}

# --- transcript builders -----------------------------------------------------

# An assistant tool_use whose input carries the owner token: this is the act
# that binds a session to a goal.
arming_record() {
    cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_arm","name":"Write","input":{"file_path":"$WORK/.g2g-goal","content":"{\\"ownerToken\\": \\"$TOKEN\\"}"}}]}}
EOF
}

# A real evidence run: the tool_use records the command, the paired
# tool_result carries the output. Args: specPath summaryLine [verdictLine] [headLine]
# verdictLine defaults to the graded token a real g2g-evidence.sh --full
# run prints when every task passed, every verify command exited 0, and
# the spec's verifier field is PASS (see g2g-evidence.sh, T-001).
# headLine defaults to WORK_HEAD_LINE (this test repo's real, current HEAD
# and tracked-dirty state, per T-001's head-binding check) so a proven block
# is honest by default; pass "" for no head line at all, or an arbitrary
# string to simulate a tree that has since moved.
# The command uses the hook's own sibling evidence script — the only
# path the hook pairs, so a lookalike script elsewhere cannot vouch.
evidence_records() {
    local verdict="${3:-verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]}"
    local head_line="${4-$WORK_HEAD_LINE}"
    local head_segment=""
    if [[ -n "$head_line" ]]; then
        head_segment="\n$head_line"
    fi
    cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"$REPO_DIR/plugin/scripts/g2g-evidence.sh $1 --full"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"=== G2G EVIDENCE ===\ntasks: $2$head_segment\nverify: ./verify.sh -> exit 0\nverifier: PASS\n$verdict"}]}]}}
EOF
}

verifier_pass_record() {
    cat <<EOF
{"type":"user","timestamp":"$NOW","toolUseResult":{"agentType":"g2g:g2g-verifier","status":"completed","content":[{"type":"text","text":"Checked everything.\nVERIFIER REPORT\nverdict: PASS\nchecked: 2 tasks"}]},"message":{"content":[{"type":"tool_result","tool_use_id":"tu_v","content":"ok"}]}}
EOF
}

complete_transcript() {
    { arming_record
      evidence_records "specs/x.json" "2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked"
      verifier_pass_record
    } > "$TRANSCRIPT"
}

# --- fail-open paths (arming in doubt) ---------------------------------------

@test "stop: no goal file allows the stop" {
    # The reported bug: a session in an unrelated directory. Nothing to
    # enforce, so this must cost one file test and allow.
    echo '{"type":"assistant"}' > "$TRANSCRIPT"
    run_hook
    assert_allowed
}

@test "stop: goal armed by another session allows the stop (bystander)" {
    write_goal "SOMEONE-ELSES-TOKEN" "specs/x.json" 40 6 "$NOW"
    complete_transcript
    run_hook
    assert_allowed
}

@test "stop: a goal this session never armed allows the stop" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    # Transcript has activity but never carries the token in a tool_use input.
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"busy working"}]}}' > "$TRANSCRIPT"
    run_hook
    assert_allowed
}

@test "stop: reading the goal file is not arming it" {
    # A bystander running /g2g:status sees the token in a tool RESULT and in
    # its own prose. Neither may bind it to someone else's build.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    cat > "$TRANSCRIPT" <<EOF
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_r","content":[{"type":"text","text":"{\\"ownerToken\\": \\"$TOKEN\\"}"}]}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"The active goal token is $TOKEN"}]}}
EOF
    run_hook
    assert_allowed
}

@test "stop: unparsable goal JSON allows the stop" {
    # A legacy prose .g2g-goal from a build in flight across the upgrade.
    printf 'The most recent G2G EVIDENCE block...\n' > "$WORK/.g2g-goal"
    complete_transcript
    run_hook
    assert_allowed
}

@test "stop: unreadable transcript allows the stop" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    run_hook "$BATS_TEST_TMPDIR/does-not-exist.jsonl"
    assert_allowed
}

@test "stop: goal JSON without an owner token allows the stop" {
    echo '{"version": 1, "specPath": "specs/x.json"}' > "$WORK/.g2g-goal"
    complete_transcript
    run_hook
    assert_allowed
}

# --- escape hatches (armed, but the run is over) -----------------------------

@test "stop: elapsed hours cap allows the stop without any turn line" {
    # The hours cap is computed from buildStart, so a forgotten turn line
    # can never make the caps unreachable.
    write_goal "$TOKEN" "specs/x.json" 40 1 "2020-01-01T00:00:00Z"
    arming_record > "$TRANSCRIPT"
    run_hook
    assert_allowed
}

@test "stop: reaching the turn cap allows the stop" {
    write_goal "$TOKEN" "specs/x.json" 3 6 "$NOW"
    { arming_record
      echo '{"type":"assistant","message":{"content":[{"type":"text","text":"G2G TURN 3/3 (build started X, now Y)"}]}}'
    } > "$TRANSCRIPT"
    run_hook
    assert_allowed
}

@test "stop: a turn below the cap does not allow the stop" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      echo '{"type":"assistant","message":{"content":[{"type":"text","text":"G2G TURN 2/40 (build started X, now Y)"}]}}'
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
}

@test "stop: the ownership-lost marker allows the stop when the lock is foreign" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    printf '2026-07-29T00:00:00Z\nA-DIFFERENT-BUILDS-TOKEN\n' > "$WORK/.g2g-goal.lock"
    { arming_record
      echo '{"type":"assistant","message":{"content":[{"type":"text","text":"G2G OWNERSHIP LOST '"$TOKEN"'"}]}}'
    } > "$TRANSCRIPT"
    run_hook
    assert_allowed
}

@test "stop: the goal read-back cannot be mistaken for the ownership marker" {
    # The token appears inside the printed goal JSON. Whole-line matching is
    # what keeps that from reading as a standalone terminal marker.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    printf '2026-07-29T00:00:00Z\n%s\n' "$TOKEN" > "$WORK/.g2g-goal.lock"
    { arming_record
      echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{\"ownerToken\": \"'"$TOKEN"'\"} — G2G OWNERSHIP LOST '"$TOKEN"' appears here only as quoted prose"}]}}'
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
}

@test "stop: a failed release-terminal allows the stop" {
    # That path ends the run by procedure and deletes nothing; without this
    # the goal would block until the hours cap.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_l","content":[{"type":"text","text":"g2g-lock: malformed-state detail=empty-token-line"}]}]}}'
    } > "$TRANSCRIPT"
    run_hook
    assert_allowed
}

# --- completion (armed, fail-closed) ----------------------------------------

@test "stop: a genuinely complete build allows the stop" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    complete_transcript
    run_hook
    assert_allowed
}

# --- worktree anchor resolution (F-064) --------------------------------------
#
# g2g-lock.sh anchors the goal/lock/mutex trio on the enclosing worktree root
# (`git rev-parse --show-toplevel`) rather than the caller's CWD, so a build
# started from a subdirectory shares one lock with a build started at the
# root. The Stop hook must resolve the SAME anchor from CLAUDE_PROJECT_DIR /
# the payload's cwd, or a subdirectory session arms a goal the hook can never
# see -- turning a closed lock hole into an unenforced goal. Empirically,
# CLAUDE_PROJECT_DIR and the payload cwd are both just the directory the
# session started FROM, never resolved to a repository root (see
# g2g-stop.sh's resolve_anchor comment for how that was verified), so this is
# a real fix, not a defensive no-op.

@test "stop: a goal armed at the worktree root blocks the stop when the session starts in a subdirectory" {
    # Distinguishing test: an incomplete build (armed, no evidence yet) BLOCKS
    # when the goal is correctly located at the worktree root. If the hook
    # instead looked for .g2g-goal inside the subdirectory (unresolved
    # anchor), it would take the "no goal file" fast path and ALLOW -- the
    # same outcome a correct resolution produces for a genuinely absent goal,
    # so only an incomplete build can tell the two apart.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    mkdir -p "$WORK/nested/deep"
    arming_record > "$TRANSCRIPT"
    run_hook_from_cwd "$WORK/nested/deep"
    assert_blocked
    [[ "$output" == *"EVIDENCE"* ]] \
        || { echo "block reason does not name the missing evidence: $output"; return 1; }
}

@test "stop: an unresolvable anchor (no enclosing repository) still allows the stop" {
    # resolve_anchor's `git rev-parse --show-toplevel` fails outside any git
    # repository; the fallback to the starting directory itself is today's
    # (pre-F-064) behavior and must never become a block -- arming
    # uncertainty always allows, even when the anchor computation itself
    # cannot resolve a worktree root.
    outside_any_repo="$BATS_TEST_TMPDIR/not-a-repo"
    mkdir -p "$outside_any_repo"
    run_hook_from_cwd "$outside_any_repo"
    assert_allowed
}

# --- head binding (T-001 / F-059) -------------------------------------------
#
# build.md's final --full evidence run can happen before the rebase-and-push
# that produces the PR's actual shipped tree, so a proven verdict alone only
# proves a token was earned for SOME tree. These pin the hook comparing the
# paired block's head line against the repository state at stop time.

@test "stop: a proven block whose head line matches the current tree allows the stop" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      evidence_records "specs/x.json" "2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked"
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_allowed
}

@test "stop: a proven block with a stale head sha blocks the stop" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      evidence_records "specs/x.json" "2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked" \
          "verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]" \
          "head: deadbee (tracked-dirty: $WORK_HEAD_DIRTY)"
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"stale"* ]] \
        || { echo "block reason does not name the stale head: $output"; return 1; }
    [[ "$output" == *"deadbee"* && "$output" == *"$WORK_HEAD_SHA"* ]] \
        || { echo "block reason does not name what moved: $output"; return 1; }
    [[ "$output" == *"g2g-evidence.sh specs/x.json --full"* ]] \
        || { echo "block reason does not name the --full re-run remedy: $output"; return 1; }
}

@test "stop: a proven block with a stale tracked-dirty count blocks the stop" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      evidence_records "specs/x.json" "2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked" \
          "verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]" \
          "head: $WORK_HEAD_SHA (tracked-dirty: 999)"
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"stale"* ]] \
        || { echo "block reason does not name the stale dirty count: $output"; return 1; }
    [[ "$output" == *"tracked-dirty 999"* ]] \
        || { echo "block reason does not name what moved: $output"; return 1; }
    [[ "$output" == *"g2g-evidence.sh specs/x.json --full"* ]] \
        || { echo "block reason does not name the --full re-run remedy: $output"; return 1; }
}

@test "stop: a proven block carrying no head line blocks the stop" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      evidence_records "specs/x.json" "2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked" \
          "verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]" \
          ""
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"no head line"* ]] \
        || { echo "block reason does not name the missing head line: $output"; return 1; }
    [[ "$output" == *"g2g-evidence.sh specs/x.json --full"* ]] \
        || { echo "block reason does not name the --full re-run remedy: $output"; return 1; }
}

@test "stop: armed with no evidence blocks and names what is missing" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    arming_record > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"EVIDENCE"* ]] || { echo "block reason does not name the missing evidence: $output"; return 1; }
}

@test "stop: evidence for a different spec does not satisfy this goal" {
    write_goal "$TOKEN" "specs/mine.json" 40 6 "$NOW"
    { arming_record
      evidence_records "specs/other.json" "2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked"
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
}

@test "stop: tasks still unpassed blocks the stop" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      evidence_records "specs/x.json" "2 total | 1 passed | 0 in_progress | 1 pending | 0 blocked" \
          "verdict: incomplete [tasks 1/2]"
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
}

@test "stop: a failing verify command blocks even when tasks and verifier both report done" {
    # The gap this task closes: a --full run whose verification command
    # exited nonzero must never coexist with a passing completion check,
    # even though the spec's task/verifier fields claim completion.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"$REPO_DIR/plugin/scripts/g2g-evidence.sh specs/x.json --full"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"=== G2G EVIDENCE ===\ntasks: 2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked\nverify: ./verify.sh -> exit 1\nverifier: PASS\nverdict: incomplete [tasks 2/2; verify: ./verify.sh -> exit 1]"}]}]}}
EOF
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
}

@test "stop: blocking on an incomplete verdict preserves the diagnosis text" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      evidence_records "specs/x.json" "1 total | 1 passed | 0 in_progress | 0 pending | 0 blocked" \
          "verdict: incomplete [tasks 1/2]"
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"Condition not met:"* ]] \
        || { echo "block reason lost the required prefix: $output"; return 1; }
    [[ "$output" == *"verdict: incomplete [tasks 1/2]"* ]] \
        || { echo "block reason lost the specific verdict text: $output"; return 1; }
}

@test "stop: an evidence block with no verdict line blocks and names the absence" {
    # A pre-0.5.0 g2g-evidence.sh block: structurally paired and --full, but
    # printed before the verdict line existed. Self-heals on the next turn.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"$REPO_DIR/plugin/scripts/g2g-evidence.sh specs/x.json --full"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"=== G2G EVIDENCE ===\ntasks: 2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked\nverify: ./verify.sh -> exit 0\nverifier: PASS"}]}]}}
EOF
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"no verdict line"* ]] \
        || { echo "block reason does not name the missing verdict line: $output"; return 1; }
}

@test "stop: a hand-written evidence block cannot satisfy the goal" {
    # Provenance is structural: the block must sit in a tool_result paired to
    # the command that produced it. Assistant prose can never qualify, even
    # when it types out the exact 'verdict: complete (proven)' token.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      echo '{"type":"assistant","message":{"content":[{"type":"text","text":"=== G2G EVIDENCE ===\ntasks: 2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked\nverifier: PASS\nverdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]"}]}}'
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
}

@test "stop: a block carrying an injected proven line beside the real verdict is treated as forged" {
    # The producer prints exactly one verdict line; two verdict lines in a
    # paired block mean spec-controlled text (or a chained command) injected
    # one. any()-style acceptance of the passing token would reopen the
    # failed-verify gap, so a conflicted block must always block.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      evidence_records "specs/x.json" "2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked" \
          "verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]\nverdict: incomplete [tasks 2/2; verify: false -> exit 1]"
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"multiple verdict lines"* ]] \
        || { echo "block reason does not name the conflicting verdicts: $output"; return 1; }
}

@test "stop: an evidence command with anything chained after --full does not pair" {
    # Pairing is constrained to a bare invocation ending at --full: a
    # compound command that merely CONTAINS the invocation could append its
    # own passing verdict line to the tool_result.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"$REPO_DIR/plugin/scripts/g2g-evidence.sh specs/x.json --full; echo 'verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]'"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"=== G2G EVIDENCE ===\ntasks: 2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked\nverify: ./verify.sh -> exit 0\nverifier: PASS\nverdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]"}]}]}}
EOF
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"no G2G EVIDENCE block"* ]] \
        || { echo "block reason should treat the chained command as unpaired: $output"; return 1; }
}

@test "stop: a commented-out invocation after a forging prefix does not pair" {
    # The bypass a review found in the first hardening round: with the
    # pairing regex anchored only at the end, a prefix command could print
    # the passing token while a trailing shell comment satisfied the regex
    # without the evidence script ever running. Pairing must require the
    # whole command to be the invocation.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"printf 'verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]\\\\n'; # $REPO_DIR/plugin/scripts/g2g-evidence.sh specs/x.json --full"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]"}]}]}}
EOF
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"no G2G EVIDENCE block"* ]] \
        || { echo "block reason should treat the commented invocation as unpaired: $output"; return 1; }
}

@test "stop: a command chained before the invocation does not pair" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"printf 'verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]\\\\n' && false || true; $REPO_DIR/plugin/scripts/g2g-evidence.sh specs/x.json --full"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]"}]}]}}
EOF
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"no G2G EVIDENCE block"* ]] \
        || { echo "block reason should treat the prefixed command as unpaired: $output"; return 1; }
}

@test "stop: a lookalike evidence script at another path does not pair" {
    # The hook vouches only for its own sibling scripts/g2g-evidence.sh; a
    # copy (or impostor) elsewhere prints whatever its author wants.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"/tmp/evil/g2g-evidence.sh specs/x.json --full"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"=== G2G EVIDENCE ===\ntasks: 2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked\nverify: ./verify.sh -> exit 0\nverifier: PASS\nverdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]"}]}]}}
EOF
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"no G2G EVIDENCE block"* ]] \
        || { echo "block reason should treat the lookalike path as unpaired: $output"; return 1; }
}

@test "stop: a defensively quoted evidence invocation still pairs" {
    # Quoting the script and spec paths is shell-safe and legitimate (and
    # required if either path contains spaces); classifying such a run as
    # NO-EVIDENCE would block an honest build until its caps.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"bash \\"$REPO_DIR/plugin/scripts/g2g-evidence.sh\\" \\"specs/x.json\\" --full"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"=== G2G EVIDENCE ===\ntasks: 2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked\n$WORK_HEAD_LINE\nverify: ./verify.sh -> exit 0\nverifier: PASS\nverdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]"}]}]}}
EOF
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_allowed
}

@test "stop: mismatched quotes around the invocation do not pair" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"\\"$REPO_DIR/plugin/scripts/g2g-evidence.sh' specs/x.json --full"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]"}]}]}}
EOF
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
}

@test "stop: evidence without --full cannot satisfy the goal" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    cat > "$TRANSCRIPT" <<EOF
$(arming_record)
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"$REPO_DIR/plugin/scripts/g2g-evidence.sh specs/x.json"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"tasks: 2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked\nverifier: PASS"}]}]}}
$(verifier_pass_record)
EOF
    run_hook
    assert_blocked
}

@test "stop: complete evidence without a verifier dispatch blocks the stop" {
    # verifier: PASS in the evidence block is read from the spec JSON, which
    # the orchestrator writes. The subagent's own report is the real gate.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      evidence_records "specs/x.json" "2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked"
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"VERIFIER REPORT"* ]] \
        || { echo "block reason does not name the missing verifier report: $output"; return 1; }
}

@test "stop: a verifier PASS in assistant prose cannot satisfy the goal" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      evidence_records "specs/x.json" "2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked"
      echo '{"type":"assistant","message":{"content":[{"type":"text","text":"VERIFIER REPORT\nverdict: PASS"}]}}'
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
}

# --- escalation after repeated blocks ---------------------------------------
#
# A goal can be genuinely unreachable. Repeating "no evidence block" until the
# harness's own consecutive-block cap overrides us wastes turns and tells the
# session nothing it can act on.

# Emit a harness-written stop_hook_summary record carrying a block from THIS
# hook. Args: reason-text
prior_block_record() {
    cat <<EOF
{"type":"system","subtype":"stop_hook_summary","hookCount":1,"hookErrors":["$1"],"timestamp":"$NOW"}
EOF
}

@test "stop: the first blocks stay terse — no escalation yet" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      prior_block_record "Condition not met: no G2G EVIDENCE block."
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" != *"blocked"*"stops without reaching a terminal state"* ]] \
        || { echo "escalated too early: $output"; return 1; }
}

@test "stop: repeated blocks escalate to naming the legitimate exits" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      prior_block_record "Condition not met: no G2G EVIDENCE block."
      prior_block_record "Condition not met: no G2G EVIDENCE block."
      prior_block_record "Condition not met: no G2G EVIDENCE block."
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"stops without reaching a terminal state"* ]] \
        || { echo "did not escalate after 3 prior blocks: $output"; return 1; }
    [[ "$output" == *"release-terminal"* ]] \
        || { echo "escalation does not name the terminal release: $output"; return 1; }
    [[ "$output" == *"delete .g2g-goal"* ]] \
        || { echo "escalation does not name the unreachable-goal exit: $output"; return 1; }
}

@test "stop: escalation still names the original missing element" {
    # Escalating must not replace the diagnosis — a session that can finish
    # needs to know what is still missing.
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      prior_block_record "Condition not met: x"
      prior_block_record "Condition not met: x"
      prior_block_record "Condition not met: x"
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"EVIDENCE"* ]] \
        || { echo "escalation lost the specific reason: $output"; return 1; }
}

@test "stop: another plugin's Stop hook errors do not count toward escalation" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    { arming_record
      echo '{"type":"system","subtype":"stop_hook_summary","hookErrors":["some other plugin: review gate failed"],"timestamp":"'"$NOW"'"}'
      echo '{"type":"system","subtype":"stop_hook_summary","hookErrors":["some other plugin: review gate failed"],"timestamp":"'"$NOW"'"}'
      echo '{"type":"system","subtype":"stop_hook_summary","hookErrors":["some other plugin: review gate failed"],"timestamp":"'"$NOW"'"}'
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" != *"stops without reaching a terminal state"* ]] \
        || { echo "counted another plugin's hook errors: $output"; return 1; }
}

# --- shape ------------------------------------------------------------------

@test "stop: the hook never exits nonzero and emits valid JSON when blocking" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    arming_record > "$TRANSCRIPT"
    run_hook
    [[ "$status" -eq 0 ]]
    run bash -c "printf '%s' '$output' | jq -e '.decision == \"block\" and (.reason | type == \"string\")'"
    [[ "$status" -eq 0 ]] || { echo "block output is not the expected JSON shape"; return 1; }
}
