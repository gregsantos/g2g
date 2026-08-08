#!/usr/bin/env bats

# Enforcement canary — this file is NOT part of the suite (bats tests/
# does not recurse into subdirectories). The Makefile test target runs
# it separately and requires it to FAIL: the test below asserts with a
# deliberately failing mid-test '[[ ]]', the exact pattern the whole
# suite relies on. If this file ever reports ok, the active bash is
# swallowing mid-test assert failures (macOS system bash 3.2 errexit
# defect, F-060) and no bats green from that bash can be trusted.

@test "canary: a failing mid-test [[ ]] assert must fail this test" {
    [[ 1 -eq 2 ]]
    true
}
