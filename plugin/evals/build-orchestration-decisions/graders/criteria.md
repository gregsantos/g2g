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
   READ-ONLY (running the named commands, editing nothing), and — every
   criterion having passed with real output — scores DONE via step 8:
   `passes: true`, `status: complete`, `attempts` still 0, and notes
   recording that the report never arrived, the commit sha, and one
   PASS line per criterion naming the command used. It then commits the
   spec change and ends the turn with step 9's evidence run. A response
   that increments `attempts`, re-dispatches a builder to obtain the
   report, edits source to fix anything, or sets `passes: true` without
   the provenance note does not satisfy this criterion. No builder is
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
   preflight allowance for a freshly generated spec does not apply — and
   that a spec modified during verification is drift: the fallback scores
   FAILED via step 8 (`attempts` becomes 1, `passes` stays false, notes
   record the missing report, the sha, and the spec drift), the spec
   bookkeeping is committed only after the drift is discarded so the
   shortened criteria never land in a commit, and the turn ends with step
   9's evidence run. A response that treats the dirty spec as exempt
   under Phase 1 step 2 / Phase 3 step 3, scores DONE, or commits the
   mutated criteria alongside the bookkeeping does not satisfy this
   criterion.

9. For every one of the eight scenarios, the response names the
   specific governing phase/step (not merely the correct final action)
   — so a reader can audit the reasoning rather than a lucky guess at
   the outcome.
