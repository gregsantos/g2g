---
id: L-001
title: Proven evidence must be bound to the tree that actually ships
date: 2026-08-18
track: bug
area: hooks
severity: high
tags: [checkout-lock, evidence-script, stop-hook, head-binding]
sourceFinding: F-059
commits: [2151921, f2304fe, 29d850d]
symptoms: A proven-armed Stop hook could allow a stop whose pushed HEAD differed from the tree the evidence run had certified.
rootCause: build.md ran the final --full evidence BEFORE the rebase-and-push steps, and g2g-stop.sh trusted the resulting proven token without re-checking it against current repository state.
resolution: build.md now rebases before the final evidence run, and g2g-stop.sh compares the evidence block's head line against current short HEAD/tracked-dirty before allowing a proven-armed stop (PR #7).
---

# L-001: Proven evidence must be bound to the tree that actually ships

## Context
`plugin/commands/build.md` Phase 4 used to run the final
`g2g-evidence.sh <spec> --full` (producing a `verdict: complete
(proven)` token) BEFORE rebasing onto the default branch and pushing.
`plugin/scripts/g2g-stop.sh` gated the Stop hook purely on that
verdict token, so the PR's actual shipped HEAD (post-rebase) could
differ from the tree the token had certified, and the hook had no way
to notice. Reachable only after a verifier PASS, so real but not
urgent — flagged as F-059 during the third Codex adversarial review
round on PR #4 (summarized in `CHANGELOG.md` under 0.5.0 "Hardened").

## Root Cause
A `proven` verdict token said "this spec's goal was satisfied for some
tree at evidence-run time" — it carried no binding to which tree. Once
build.md reordered its own steps so the rebase happened after the
final evidence run, the certified tree and the pushed tree could
diverge, and `g2g-stop.sh` (`plugin/scripts/g2g-stop.sh`) trusted the
token at face value with no re-check against current repository state.

## Resolution
Fixed by PR #7 ("Evidence Head Binding"), landed as three commits:
- `f2304fe` reordered `plugin/commands/build.md` Phase 4 so the rebase
  onto the default branch happens BEFORE the final `--full` evidence
  run, so `proven` certifies the tree that actually ships.
- `2151921` made `g2g-stop.sh` extract the paired evidence block's
  `head:` line (see `plugin/scripts/g2g-stop.sh` around the "Head
  binding (F-059, hook side)" comment block, which recomputes
  `current_head_sha`/`current_head_dirty` via `git -C "$anchor"
  rev-parse --short HEAD` and `git status --porcelain
  --untracked-files=no`) and blocks a proven-armed stop on any mismatch
  against current short HEAD or tracked-dirty count, or a missing head
  line — naming the drift and the `--full` re-run remedy. Pinned by
  four new tests in `tests/plugin_stop.bats` (the "head binding (T-001
  / F-059)" block, e.g. "stop: a proven block whose head line matches
  the current tree allows the stop").
- `29d850d` documented the head-bound completion gate and bumped the
  version to 0.6.0.

## Evidence
`plugin/scripts/g2g-stop.sh` (head-binding block, `extract_head_sha`/
`extract_head_dirty`/`current_head_line` logic), `plugin/scripts/g2g-evidence.sh`
(emits the `head: <sha> (tracked-dirty: <n>)` line the hook compares
against), `tests/plugin_stop.bats` (head-binding test block), commits
`2151921`, `f2304fe`, `29d850d` (all reachable from origin/main).

## Implication
A completion token is only as trustworthy as the check that binds it
to a specific tree. Any future change to build.md's phase ordering, or
to what `g2g-evidence.sh` emits as its head line, must keep the
rebase-before-final-evidence ordering and the hook-side head comparison
in lockstep — reordering one without the other reopens exactly this
gap. Per `CLAUDE.md`, the evidence script's output format (including
this `head:` line) is frozen and changes only together with
`tests/plugin_evidence.bats`, `g2g-stop.sh`, and `build.md`.
