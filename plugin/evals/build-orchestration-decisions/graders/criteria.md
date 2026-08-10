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

5. For every one of the four scenarios, the response names the
   specific governing phase/step (not merely the correct final action)
   — so a reader can audit the reasoning rather than a lucky guess at
   the outcome.
