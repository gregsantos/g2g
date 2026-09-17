Score 1.0 only if ALL of the following hold for the response; otherwise
score proportionally to how many hold:

1. Scenario 1: the response states T-003's `attempts` becomes 2, and
   because `attempts >= 2` it sets `status: blocked` on T-003 with the
   failure reason recorded in `notes` (Phase 3 step 8), commits the
   spec change, and then ENDS the current turn with Phase 3 step 9's
   evidence-script run — the mandatory end-of-turn step is never
   skipped, and no re-routing happens mid-turn. Phase 5 is reached on
   the NEXT turn: turn 10 prints the turn line and Phase 3 step 2's
   cap check fires first (`k` = 10 `>= TURN_CAP` 10), routing to
   Phase 5 before task selection is even consulted. A response that
   jumps to Phase 5 in the same turn, skips the step-9 evidence run,
   or attributes the routing to step 4's no-eligible-task rule instead
   of the step-2 cap check does not satisfy this criterion. No builder
   is dispatched in either turn.

2. Scenario 2: the response identifies T-002 as the next eligible task
   (its sole dependency T-001 already has `passes: true`) and states
   the orchestrator sets T-002 to `status: in_progress`, commits that
   change, and dispatches exactly one `g2g:g2g-builder` subagent for
   T-002 this turn (Phase 3 steps 4-6).

3. Scenario 3: the response states that because `VERIFY_ROUND` (2) is
   `>= REVERIFY_CAP` (2), the orchestrator does NOT dispatch another
   fix round; it goes to Phase 5 now, carrying the verifier's
   outstanding findings so the partial PR body lists them (Phase 4
   step 3).

4. Scenario 4: the response states the turn cap has been exceeded
   (`k` = 11 `>= TURN_CAP` 10) and routes to Phase 5 (terminal stop)
   even though pending, otherwise-eligible tasks remain, explicitly
   stating no further builder is dispatched (Phase 3 step 2).

5. Scenario 5: the response applies Phase 3 step 7's NO-REPORT FALLBACK
   instead of scoring the missing marker as FAILED: it compares HEAD to
   the baseline taken after the `chore(T-004): start` commit, sees it
   moved, verifies the new commit against T-004's acceptance criteria
   READ-ONLY (running the named commands, editing nothing), confirms the
   postcondition (step 7 c) held — HEAD still `e4f5a6b`, tree still
   CLEAN — and only then, every criterion having passed with real
   output, scores DONE via step 8:
   `passes: true`, `status: complete`, `attempts` still 0, and notes
   recording that the report never arrived, the commit sha, and one
   PASS line per criterion naming the command used. It then commits the
   spec change and ends the turn with step 9's evidence run. A response
   that increments `attempts`, re-dispatches a builder to obtain the
   report, edits source to fix anything, scores DONE without checking
   the post-verification state, or sets `passes: true` without the
   provenance note does not satisfy this criterion. No builder is
   dispatched beyond the one that already ran.

6. Scenario 6: the response states HEAD is unchanged from the baseline,
   so the fallback scores the attempt FAILED exactly as step 8 writes
   it: `attempts` becomes 2, `attempts >= 2` sets `status: blocked` with
   the reason in notes, the spec change is committed, and the turn ends
   with step 9's evidence run. A response that verifies acceptance
   criteria here, treats silence with no commit as inconclusive, or
   leaves `attempts` at 1 does not satisfy this criterion.

7. Scenario 7: the response states that the fallback's post-verification
   recheck fails — the tree is no longer clean beyond the paths step 3
   exempts, so the passing results describe a modified checkout rather
   than commit `e4f5a6b` — and therefore scores FAILED via step 8, not
   DONE: `attempts` becomes 1, `passes` stays false, notes record the
   missing report, the sha, and the drift, the spec change is committed,
   and the turn ends with step 9's evidence run. A response that records
   DONE because every command exited 0, or that edits, reverts, or
   stashes the modified files itself this turn, does not satisfy this
   criterion.

8. Scenario 8: the response states that the spec is NOT among the
   fallback's exemptions — step 5 committed it before dispatch, so the
   preflight allowance for a freshly generated spec does not apply — so
   the postcondition (step 7 c) fails and the verification scores FAIL
   regardless of the commands' exit codes. It restores the spec from the
   DISPATCH BASELINE `a1b2c3d` into BOTH the index and the working tree
   (`git restore --source=a1b2c3d --staged --worktree -- <spec-path>`,
   step 7 d), confirms with `git diff --quiet` against the baseline for
   worktree and `--cached`, and only then writes the FAILED bookkeeping
   (`attempts` becomes 1, `passes` stays false, notes record the missing
   report, the sha, and the staged spec drift) as a spec-path-only
   BOOKKEEPING COMMIT, then ends the turn with step 9's evidence run. A
   response that uses `git checkout -- <spec-path>` (which restores from
   the index, so the staged mutation survives), treats the dirty spec as
   exempt under Phase 1 step 2 / Phase 3 step 3, scores DONE, or commits
   with `-a` or without the spec pathspec does not satisfy this
   criterion.

9. Scenario 9: the response states that HEAD moving during verification
   fails the postcondition (step 7 c) — the results describe a checkout
   that is no longer the TIP `e4f5a6b` — so the verification scores FAIL
   regardless of exit codes. It does NOT reset, revert, or otherwise undo
   `f7a8b9c` (step 7 d: touch nothing but the spec; record the foreign
   sha in notes and leave the commit for the tree check and the
   verifier); it restores the spec from the DISPATCH BASELINE `a1b2c3d`
   into index and working tree — not from the current HEAD, which now
   carries the mutation — confirms, then writes the FAILED bookkeeping
   (`attempts` becomes 1) as a spec-path-only BOOKKEEPING COMMIT and ends
   the turn with step 9's evidence run. A response that restores from
   HEAD, resets the branch to `e4f5a6b`, or scores DONE does not satisfy
   this criterion.

10. Scenario 10: the response states that the tree is NOT CLEAN despite
    the clean status — CLEAN also requires the spec to match the
    DISPATCH BASELINE (step 7's definitions) — so the PREcondition
    (step 7 a) fails and no verification command is run. It does not
    trust the `passes: true` the builder wrote. It applies the SPEC
    RESTORE rule (step 7 d) even though nothing was verified: restores
    the spec from `a1b2c3d` into index and working tree, confirms, then
    writes the FAILED bookkeeping (`attempts` becomes 1, `passes` false,
    notes recording the missing report, the sha `e4f5a6b`, and that the
    builder's commit modified the spec) as a spec-path-only BOOKKEEPING
    COMMIT, and ends the turn with step 9's evidence run. A response
    that runs verification, scores DONE, leaves `passes: true` in place,
    or writes `attempts` into the spec as the builder left it does not
    satisfy this criterion.

11. Scenario 11: the response states the report is NOT USABLE — step 7
    requires a DONE to carry a `commit:` that resolves, and none arrived
    — so it does NOT take step 8's reported-DONE path on the strength of
    `result: DONE`, and does NOT score it FAILED as malformed either: it
    treats the report as absent and applies the NO-REPORT FALLBACK,
    judging the TIP `e4f5a6b` by the (a)-(f) procedure (precondition,
    read-only verification, postcondition) before any DONE or FAILED is
    recorded. A response that sets `passes: true` because `result: DONE`
    was readable, or that increments `attempts` without judging the
    commit, does not satisfy this criterion.

12. Scenario 12: the response does NOT take step 8's reported-DONE path
    on the strength of a usable report: step 8's entry gate runs the
    SPEC RESTORE rule (step 7 d) on EVERY entry, reported or fallback,
    and `git diff --quiet a1b2c3d -- <spec-path>` exiting 1 means the
    builder modified the spec against g2g-builder.md rule 6. It restores
    the spec from the DISPATCH BASELINE `a1b2c3d` into index and working
    tree (`git restore --source=a1b2c3d --staged --worktree --
    <spec-path>`), confirms both `git diff --quiet` forms exit 0, and
    scores the attempt FAILED regardless of `result: DONE`: `attempts`
    becomes 1, `passes` stays false, notes record that the builder
    modified the spec, the reported DONE and sha `e4f5a6b`, and the
    commit between baseline and HEAD. It writes that as a spec-path-only
    BOOKKEEPING COMMIT and ends the turn with step 9's evidence run. A
    response that sets `passes: true` because the report was usable,
    keeps the builder's `passes: true` in place, restores with
    `git checkout -- <spec-path>`, verifies the commit and scores DONE on
    the criteria alone, or commits with `-a` does not satisfy this
    criterion.

13. Scenario 13: the response routes to OWNERSHIP LOST on the refresh's
    exit 5 (BLOCKING WAIT step 5, the POST-WAIT REFRESH) BEFORE reading
    the report, running step 8's entry gate, or restoring the spec — the
    spec difference from `a1b2c3d` is the reclaiming build's progress,
    not builder corruption, and is not this build's to repair. It writes
    and deletes NOTHING (no `git restore`, no bookkeeping commit, no goal
    or lock release, no push), prints the exact standalone line
    `G2G OWNERSHIP LOST <owner-token>`, reports the helper's outcome line
    and which tasks had completed before the stall, and treats the run as
    a failed terminal state. A response that scores the report DONE or
    FAILED, restores the spec from the baseline, commits anything, or
    reaches OWNERSHIP LOST only at the next turn's step 1 refresh does
    not satisfy this criterion.

14. For every one of the thirteen scenarios, the response names the
   specific governing phase/step (not merely the correct final action)
   — so a reader can audit the reasoning rather than a lucky guess at
   the outcome.
