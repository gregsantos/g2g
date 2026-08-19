---
id: L-002
title: The bats suite must run under a bash whose errexit actually fails mid-test asserts
date: 2026-08-18
track: bug
area: tests
severity: medium
tags: [bats, bash-3.2, enforcement-canary, make-check]
sourceFinding: F-060
commits: [522ef45]
symptoms: Deliberately-red bats tests reported ok under local make test/make check on macOS system bash.
rootCause: bash 3.2's errexit does not propagate a failing bare [[ ]] compound command unless it is the last command executed, and the bats suite asserts almost exclusively with mid-test [[ ]] lines.
resolution: The Makefile test target now resolves an enforcing bash, proves enforcement via tests/canary/enforcement.bats, and hard-fails if no enforcing bash is found (PR #6, commit 522ef45).
---

# L-002: The bats suite must run under a bash whose errexit actually fails mid-test asserts

## Context
macOS system bash (3.2 — the only bash present on a stock Mac, and
what `bats` resolves via the environment unless told otherwise) has an
errexit defect: a failing bare `[[ ]]` compound command does NOT
trigger `set -e` unless it is the LAST command in the script
(`/bin/bash -ec '[[ 1 -eq 2 ]]; echo survived'` prints `survived` and
exits 0). The bats suite asserts almost exclusively with mid-test
`[[ ]]` lines, so on such a machine only each test's final command was
enforced and every earlier assert was decorative — during an earlier
fix (F-019) deliberately-red tests reported `ok` locally. CI runs
Ubuntu bash where `[[ ]]` trips errexit correctly, so PR-gated runs
stayed sound; the exposure was local `make test`/`make check` green,
including g2g builds' own `verificationCommands` (`make check`),
overstating what was actually verified.

## Root Cause
bash 3.2's `set -e`/`errexit` implementation does not propagate a
failing status out of a compound `[[ ... ]]` command unless that
command is the final one executed under `-e`. Every runtime plugin
script (`plugin/scripts/*.sh`, `tests/smoke.sh`) was audited and found
unaffected — each bare `[[ ]]` there already carries an explicit
handler — but the bats test suite relies on bare mid-test `[[ ]]`
asserts throughout, which is exactly the pattern the defect swallows.

## Resolution
The Makefile `test` target (`Makefile`, `test:` recipe) now resolves
an enforcing bash by trying, in order, `G2G_BATS_BASH`, then `bash` on
`PATH`, then common Homebrew/MacPorts locations
(/opt/homebrew/bin/bash, /usr/local/bin/bash,
/opt/local/bin/bash), picking the first candidate whose `-ec '[[ 1
-eq 2 ]]; true'` actually fails. It then proves enforcement
end-to-end by running `tests/canary/enforcement.bats` — a
deliberately failing mid-test `[[ 1 -eq 2 ]]` assert
(`tests/canary/enforcement.bats`) — and hard-fails the whole target if
that canary reports `ok` (meaning even the resolved bash is
swallowing). Only after the canary reports `not ok` does the target
run the real suite (`bats tests/`) under that same bash. No enforcing
bash on the machine is a hard failure with a named remedy (`brew
install bash`, or point `G2G_BATS_BASH` at a bash >= 4), rather than a
silent decorative-assert run. Landed in `522ef45` ("harden:
enforce-capable bash gate + canary; field-type spec guard (Codex
review)"), from Codex's escalation of the earlier 0.5.1 stopgap
warning, in response to PR #6's review.

## Evidence
`Makefile` `test:` target (bash resolution loop, canary invocation,
hard-fail branch), `tests/canary/enforcement.bats` (the deliberately
failing assert), commit `522ef45` (reachable from origin/main).
Verified locally with brew-installed bash 5.3: previously-swallowed
asserts now fail correctly.

## Implication
Never simplify the `test` target back to a bare `bats tests/` call,
and never "fix" the canary so it reports `ok` — a green the canary
cannot refute is the exact failure mode it exists to catch. Any new
bats assertion style added to the suite should still be written as
plain `[[ ... ]]` (not worked around with `[ ... ]` or `case`/`grep -q`
substitutes) precisely because the canary now guarantees that style is
safe under the bash the target actually selects.
