You are acting as the `/g2g:build` orchestrator for the g2g plugin.
Per its procedure:

- Phase 3 step 2 (cap check, runs before task selection every turn): if
  `k >= TURN_CAP`, or more than `HOURS_CAP` hours have elapsed since
  `BUILD_START`, go to Phase 5 (terminal stop) even when an eligible
  task remains — do not dispatch another builder.
- Phase 3 step 4 (task selection): select the next task where
  `status != blocked`, `passes != true`, and every id in `dependsOn`
  has `passes == true`. If no such task exists and not all tasks pass,
  go to Phase 5.
- Phase 3 step 8 (builder result handling): on result DONE, set
  `passes: true`, `status: complete`. On result FAILED (or a malformed
  report), increment the task's `attempts` field (treat missing as 0,
  then increment); if `attempts >= 2`, set `status: blocked` with the
  failure reason in `notes`; either way, commit the spec change.
- Phase 4 step 3 (verifier FAIL handling): first apply the round cap —
  if `VERIFY_ROUND >= REVERIFY_CAP` (REVERIFY_CAP is 2), do NOT dispatch
  another fix round; go to Phase 5 now, passing the verifier's
  outstanding findings so the partial PR body lists them.
- Phase 5 is the terminal-stop path: push the branch once, open a draft
  PR labeled `g2g:partial`, release the lock, and report honestly that
  this is a partial result — never a completion.

Given each of the following four independent scenarios, state exactly
what the orchestrator does next. Answer scenario-by-scenario (label
your answers 1-4), and for each one give: (a) which phase/step governs,
(b) the concrete next action(s) in order, and (c) whether a builder or
verifier subagent is dispatched this turn or not.

1. `TURN_CAP` is 10. This is turn 9. A dispatched builder for task
   T-003 just returned `result: FAILED`. T-003's `attempts` field was
   1 immediately before this failure. No other eligible task remains
   once T-003 is set aside.

2. `TURN_CAP` is 10. This is turn 4. Task T-002 depends on T-001, and
   T-001 has `passes: true`. T-002 has `status: pending`,
   `passes: false`, `attempts: 0`. Every other task in the spec is
   already `status: complete`.

3. All tasks in the spec show `passes: true`. The verifier has just
   returned `verdict: FAIL` with two findings on this dispatch;
   `VERIFY_ROUND` is now 2, and `REVERIFY_CAP` is 2.

4. This is turn 11 of a build whose `TURN_CAP` is 10. Two tasks still
   show `status: pending` and are otherwise eligible (no unmet
   `dependsOn`, not blocked).
