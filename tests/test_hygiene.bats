#!/usr/bin/env bats

# Tests for the test suite itself. A bare '! command' that is not a
# test's last statement can never fail: bash's errexit ignores the
# status of a '!' pipeline. Two such asserts shipped (D9, found by the
# 2026-09-26 case study) and passed with the file they guard broken.

SCANNER="$BATS_TEST_DIRNAME/lib/find-vacuous-negations.awk"

@test "hygiene: the scanner flags a mid-test bare negation and nothing enforced" {
    fixture="$BATS_TEST_TMPDIR/fixture.bats"
    # printf, not a heredoc: a heredoc's column-0 '@test' lines would be
    # scanned as real tests by the suite-wide check below.
    printf '%s\n' \
        '@test "vacuous" {' \
        '    ! grep -q needle haystack' \
        '    true' \
        '}' \
        '@test "guarded" {' \
        '    ! grep -q needle haystack \' \
        '        || { echo "found"; return 1; }' \
        '    true' \
        '}' \
        '@test "last statement" {' \
        '    true' \
        '    ! grep -q needle haystack' \
        '}' > "$fixture"
    run awk -f "$SCANNER" "$fixture"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "$fixture:2:     ! grep -q needle haystack" ]] || {
        echo "unexpected scanner output: $output"
        return 1
    }
}

@test "hygiene: no test file has a vacuous mid-test negation" {
    run awk -f "$SCANNER" "$BATS_TEST_DIRNAME"/*.bats
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]] || {
        echo "vacuous negations (guard with '|| { echo ...; return 1; }'):"
        echo "$output"
        return 1
    }
}
