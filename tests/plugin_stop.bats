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
# tool_result carries the output. Args: specPath summaryLine [verdictLine]
# verdictLine defaults to the graded token a real g2g-evidence.sh --full
# run prints when every task passed, every verify command exited 0, and
# the spec's verifier field is PASS (see g2g-evidence.sh, T-001).
evidence_records() {
    local verdict="${3:-verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]}"
    cat <<EOF
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"/plug/scripts/g2g-evidence.sh $1 --full"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"=== G2G EVIDENCE ===\ntasks: $2\nverify: ./verify.sh -> exit 0\nverifier: PASS\n$verdict"}]}]}}
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
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"/plug/scripts/g2g-evidence.sh specs/x.json --full"}}]}}
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
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"/plug/scripts/g2g-evidence.sh specs/x.json --full"}}]}}
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
{"type":"assistant","timestamp":"$NOW","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"/plug/scripts/g2g-evidence.sh specs/x.json --full; echo 'verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]'"}}]}}
{"type":"user","timestamp":"$NOW","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ev","content":[{"type":"text","text":"=== G2G EVIDENCE ===\ntasks: 2 total | 2 passed | 0 in_progress | 0 pending | 0 blocked\nverify: ./verify.sh -> exit 0\nverifier: PASS\nverdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]"}]}]}}
EOF
      verifier_pass_record
    } > "$TRANSCRIPT"
    run_hook
    assert_blocked
    [[ "$output" == *"no G2G EVIDENCE block"* ]] \
        || { echo "block reason should treat the chained command as unpaired: $output"; return 1; }
}

@test "stop: evidence without --full cannot satisfy the goal" {
    write_goal "$TOKEN" "specs/x.json" 40 6 "$NOW"
    cat > "$TRANSCRIPT" <<EOF
$(arming_record)
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_ev","name":"Bash","input":{"command":"/plug/scripts/g2g-evidence.sh specs/x.json"}}]}}
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
