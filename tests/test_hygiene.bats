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
        '@test "guarded inline" {' \
        '    ! grep -q needle haystack \' \
        '        || { echo "found"; return 1; }' \
        '    true' \
        '}' \
        '@test "guarded block" {' \
        '    ! grep -q needle haystack || {' \
        '        echo "found"' \
        '        return 1' \
        '    }' \
        '    true' \
        '}' \
        '@test "operator only in a comment" {' \
        '    ! grep -q needle haystack # use || return 1 to enforce this' \
        '    true' \
        '}' \
        '@test "operator only in quoted text" {' \
        '    ! grep -q "a||b; return 1" haystack' \
        '    true' \
        '}' \
        '@test "a guard that cannot fail" {' \
        '    ! grep -q needle haystack || true' \
        '    true' \
        '}' \
        '@test "a guard that only prints" {' \
        '    ! grep -q needle haystack || echo fail' \
        '    true' \
        '}' \
        '@test "a guard that masks its failure" {' \
        '    ! grep -q needle haystack || { false || true; }' \
        '    true' \
        '}' \
        '@test "last statement" {' \
        '    true' \
        '    ! grep -q needle haystack' \
        '}' > "$fixture"
    expected="$fixture:2:     ! grep -q needle haystack
$fixture:18:     ! grep -q needle haystack # use || return 1 to enforce this
$fixture:22:     ! grep -q \"a||b; return 1\" haystack
$fixture:26:     ! grep -q needle haystack || true
$fixture:30:     ! grep -q needle haystack || echo fail
$fixture:34:     ! grep -q needle haystack || { false || true; }"
    run awk -f "$SCANNER" "$fixture"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "$expected" ]] || {
        echo "unexpected scanner output:"
        echo "$output"
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
