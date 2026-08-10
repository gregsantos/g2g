Score 1.0 only if ALL of the following hold for the response; otherwise
score proportionally to how many hold:

1. Scenario 1: the response states T-003's `attempts` becomes 2, and
   because `attempts >= 2` it sets `status: blocked` on T-003 with the
   failure reason recorded in `notes` (Phase 3 step 8), commits the
   spec change, and — since no other eligible task remains and the
   turn cap has NOT been hit (turn 9 < TURN_CAP 10) — goes to Phase 5
   per step 4's "no eligible task" rule rather than dispatching another
   builder this turn.

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
