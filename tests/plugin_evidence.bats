#!/usr/bin/env bats

# Tests for plugin/scripts/g2g-evidence.sh (status mode)

EVIDENCE="$BATS_TEST_DIRNAME/../plugin/scripts/g2g-evidence.sh"

make_spec() {
    # make_spec <path> <tasks-json-array> [verifier-json]
    local path="$1" tasks="$2" verifier="${3:-null}"
    jq -n --argjson tasks "$tasks" --argjson verifier "$verifier" '{
        project: "fixture",
        context: { verificationCommands: ["true"] },
        tasks: $tasks
    } + (if $verifier != null then {verifier: $verifier} else {} end)' > "$path"
}

setup() {
    SPEC="$BATS_TEST_TMPDIR/spec.json"
    make_spec "$SPEC" '[
        {"id":"T-001","title":"First","status":"complete","passes":true},
        {"id":"T-002","title":"Second","status":"in_progress","passes":false},
        {"id":"T-003","title":"Third","status":"pending","passes":false},
        {"id":"T-004","title":"Fourth","status":"blocked","passes":false}
    ]'
}

@test "evidence: prints frozen header and footer" {
    run "$EVIDENCE" "$SPEC"
    [[ "$status" -eq 0 ]]
    [[ "${lines[0]}" == "=== G2G EVIDENCE ===" ]]
    # last-line check without negative indices (macOS default bash is 3.2)
    last_line=$(echo "$output" | tail -n 1)
    [[ "$last_line" == "=== END G2G EVIDENCE ===" ]]
}

@test "evidence: counts by state" {
    run "$EVIDENCE" "$SPEC"
    [[ "$output" == *"tasks: 4 total | 1 passed | 1 in_progress | 1 pending | 1 blocked"* ]]
}

@test "evidence: one line per task when total <= 12" {
    run "$EVIDENCE" "$SPEC"
    [[ "$output" == *"T-001 [passed] First"* ]]
    [[ "$output" == *"T-002 [in_progress] Second"* ]]
    [[ "$output" == *"T-004 [blocked] Fourth"* ]]
}

@test "evidence: omits passed task lines when total > 12" {
    BIG="$BATS_TEST_TMPDIR/big.json"
    tasks=$(jq -n '[range(0;13) | {id: ("T-" + (. | tostring)), title: "t", status: (if . < 11 then "complete" else "pending" end), passes: (. < 11)}]')
    make_spec "$BIG" "$tasks"
    run "$EVIDENCE" "$BIG"
    [[ "$output" == *"passed tasks omitted: 11"* ]]
    [[ "$output" != *"T-3 [passed]"* ]]
    [[ "$output" == *"T-12 [pending]"* ]]
}

@test "evidence: verifier PENDING when absent, PASS when set" {
    run "$EVIDENCE" "$SPEC"
    [[ "$output" == *"verifier: PENDING"* ]]
    make_spec "$SPEC" '[{"id":"T-001","title":"First","status":"complete","passes":true}]' '{"verdict":"PASS"}'
    run "$EVIDENCE" "$SPEC"
    [[ "$output" == *"verifier: PASS"* ]]
}

@test "evidence: exit 2 on missing or invalid spec" {
    run "$EVIDENCE" "$BATS_TEST_TMPDIR/nope.json"
    [[ "$status" -eq 2 ]]
    echo "not json" > "$BATS_TEST_TMPDIR/bad.json"
    run "$EVIDENCE" "$BATS_TEST_TMPDIR/bad.json"
    [[ "$status" -eq 2 ]]
}

@test "evidence: exit 3 when verificationCommands missing or empty" {
    jq '.context.verificationCommands = []' "$SPEC" > "$BATS_TEST_TMPDIR/empty.json"
    run "$EVIDENCE" "$BATS_TEST_TMPDIR/empty.json"
    [[ "$status" -eq 3 ]]
    jq 'del(.context)' "$SPEC" > "$BATS_TEST_TMPDIR/nocontext.json"
    run "$EVIDENCE" "$BATS_TEST_TMPDIR/nocontext.json"
    [[ "$status" -eq 3 ]]
}

@test "evidence --full: reports real exit codes and runs all commands" {
    FULLSPEC="$BATS_TEST_TMPDIR/full.json"
    jq -n '{
        project: "fixture",
        context: { verificationCommands: ["true", "false", "echo hi"] },
        tasks: [{"id":"T-001","title":"First","status":"complete","passes":true}]
    }' > "$FULLSPEC"
    run "$EVIDENCE" "$FULLSPEC" --full
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"verify: true -> exit 0"* ]]
    [[ "$output" == *"verify: false -> exit 1"* ]]
    [[ "$output" == *"verify: echo hi -> exit 0"* ]]
}

@test "evidence --full: verify lines appear before verifier line" {
    FULLSPEC="$BATS_TEST_TMPDIR/full.json"
    jq -n '{
        context: { verificationCommands: ["true"] },
        tasks: []
    }' > "$FULLSPEC"
    run "$EVIDENCE" "$FULLSPEC" --full
    verify_line=$(echo "$output" | grep -n "verify: true" | cut -d: -f1)
    verifier_line=$(echo "$output" | grep -n "verifier:" | cut -d: -f1)
    [[ "$verify_line" -lt "$verifier_line" ]]
}

@test "evidence: status mode runs no verification commands" {
    SLOWSPEC="$BATS_TEST_TMPDIR/slow.json"
    MARKER="$BATS_TEST_TMPDIR/ran-verify"
    jq -n --arg cmd "touch $MARKER" '{
        context: { verificationCommands: [$cmd] },
        tasks: []
    }' > "$SLOWSPEC"
    run "$EVIDENCE" "$SLOWSPEC"
    [[ ! -f "$MARKER" ]]
}

@test "evidence: exact full-output golden (status mode)" {
    GOLD="$BATS_TEST_TMPDIR/gold.json"
    make_spec "$GOLD" '[
        {"id":"T-001","title":"First","status":"complete","passes":true},
        {"id":"T-002","title":"Second","status":"pending","passes":false}
    ]' '{"verdict":"PASS"}'
    # GIT_DIR points at a non-repo so the head line is deterministic
    # regardless of where bats was invoked from.
    run env GIT_DIR="$BATS_TEST_TMPDIR/nogit" "$EVIDENCE" "$GOLD"
    expected="=== G2G EVIDENCE ===
spec: $GOLD
head: none
tasks: 2 total | 1 passed | 0 in_progress | 1 pending | 0 blocked
T-001 [passed] First
T-002 [pending] Second
verifier: PASS
verdict: incomplete [tasks 1/2]
=== END G2G EVIDENCE ==="
    [[ "$output" == "$expected" ]]
}

@test "evidence: status mode prints exactly one verdict line, incomplete for a not-all-passed spec" {
    run "$EVIDENCE" "$SPEC"
    [[ "$status" -eq 0 ]]
    verdict_lines=$(echo "$output" | grep -c '^verdict: ')
    [[ "$verdict_lines" -eq 1 ]]
    [[ "$output" == *"verdict: incomplete"* ]]
}

@test "evidence: example.json prints exactly one verdict line beginning 'verdict: incomplete'" {
    run "$EVIDENCE" "$BATS_TEST_DIRNAME/../specs/example.json"
    [[ "$status" -eq 0 ]]
    verdict_lines=$(echo "$output" | grep -c '^verdict: ')
    [[ "$verdict_lines" -eq 1 ]]
    verdict_line=$(echo "$output" | grep '^verdict: ')
    [[ "$verdict_line" == verdict:\ incomplete* ]]
}

@test "evidence: status mode with all-passed spec and verifier PASS yields complete (assumed)" {
    ALLPASS="$BATS_TEST_TMPDIR/allpass.json"
    make_spec "$ALLPASS" '[
        {"id":"T-001","title":"First","status":"complete","passes":true},
        {"id":"T-002","title":"Second","status":"complete","passes":true}
    ]' '{"verdict":"PASS"}'
    run "$EVIDENCE" "$ALLPASS"
    [[ "$output" == *"verdict: complete (assumed) [tasks 2/2; verify not run; verifier PASS]"* ]]
}

@test "evidence: --full with all-passed spec, all verify commands exit 0, verifier PASS yields complete (proven)" {
    FULLGOOD="$BATS_TEST_TMPDIR/fullgood.json"
    jq -n '{
        context: { verificationCommands: ["true", "true"] },
        tasks: [
            {"id":"T-001","title":"First","status":"complete","passes":true},
            {"id":"T-002","title":"Second","status":"complete","passes":true}
        ],
        verifier: {"verdict":"PASS"}
    }' > "$FULLGOOD"
    run "$EVIDENCE" "$FULLGOOD" --full
    [[ "$output" == *"verdict: complete (proven) [tasks 2/2; verify all exit 0; verifier PASS]"* ]]
}

@test "evidence: --full with one failing verification command on an otherwise all-passed spec yields incomplete" {
    FULLBAD="$BATS_TEST_TMPDIR/fullbad.json"
    jq -n '{
        context: { verificationCommands: ["true", "false"] },
        tasks: [
            {"id":"T-001","title":"First","status":"complete","passes":true},
            {"id":"T-002","title":"Second","status":"complete","passes":true}
        ],
        verifier: {"verdict":"PASS"}
    }' > "$FULLBAD"
    run "$EVIDENCE" "$FULLBAD" --full
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"verdict: incomplete"* ]]
    [[ "$output" != *"complete (proven)"* ]]
    [[ "$output" == *"verify: false -> exit 1"* ]]
}

@test "evidence: status mode can never yield '(proven)'" {
    ALLPASS="$BATS_TEST_TMPDIR/allpass2.json"
    make_spec "$ALLPASS" '[
        {"id":"T-001","title":"First","status":"complete","passes":true}
    ]' '{"verdict":"PASS"}'
    run "$EVIDENCE" "$ALLPASS"
    [[ "$output" != *"complete (proven)"* ]]
    run "$EVIDENCE" "$SPEC"
    [[ "$output" != *"complete (proven)"* ]]
}

@test "evidence: an empty tasks array never produces a 'verdict: complete' line" {
    EMPTY="$BATS_TEST_TMPDIR/empty.json"
    jq -n '{
        context: { verificationCommands: ["true"] },
        tasks: [],
        verifier: {"verdict":"PASS"}
    }' > "$EMPTY"
    run "$EVIDENCE" "$EMPTY"
    [[ "$output" != *"verdict: complete"* ]]
    [[ "$output" == *"verdict: incomplete"* ]]
    run "$EVIDENCE" "$EMPTY" --full
    [[ "$output" != *"verdict: complete"* ]]
    [[ "$output" == *"verdict: incomplete"* ]]
}

@test "evidence: 12-task spec prints one line per task with no omission line and a graded verdict" {
    TWELVE="$BATS_TEST_TMPDIR/twelve.json"
    tasks=$(jq -n '[range(0;12) | {id: ("T-" + (. | tostring)), title: "t", status: (if . < 10 then "complete" else "pending" end), passes: (. < 10)}]')
    make_spec "$TWELVE" "$tasks"
    run "$EVIDENCE" "$TWELVE"
    [[ "$output" != *"passed tasks omitted"* ]]
    [[ "$output" == *"T-0 [passed] t"* ]]
    [[ "$output" == *"T-9 [passed] t"* ]]
    [[ "$output" == *"T-10 [pending] t"* ]]
    [[ "$output" == *"T-11 [pending] t"* ]]
    [[ "$output" == *"verdict: incomplete [tasks 10/12]"* ]]
}

@test "evidence: head line binds the block to a commit and tracked-dirty count" {
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    cd "$REPO" || return 1
    git init -q -b main
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    echo x > tracked.txt
    git add tracked.txt
    git -c user.email=t@t -c user.name=t commit -qm add
    SPEC2="$REPO/spec.json"
    make_spec "$SPEC2" '[{"id":"T-001","title":"First","status":"pending","passes":false}]'
    run "$EVIDENCE" "$SPEC2"
    [[ "$status" -eq 0 ]]
    # spec.json itself is untracked, so tracked-dirty stays 0.
    [[ "$output" =~ head:\ [0-9a-f]+\ \(tracked-dirty:\ 0\) ]] || {
        echo "missing clean head line: $output"; return 1; }
    echo y > tracked.txt   # dirty a TRACKED file
    run "$EVIDENCE" "$SPEC2"
    [[ "$output" =~ head:\ [0-9a-f]+\ \(tracked-dirty:\ 1\) ]] || {
        echo "missing dirty head line: $output"; return 1; }
}

@test "evidence: head line degrades to none outside a git work tree" {
    run env GIT_DIR="$BATS_TEST_TMPDIR/nogit" "$EVIDENCE" "$SPEC"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"head: none"* ]]
}
