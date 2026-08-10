Read `plugin/commands/build.md` — the shipped `/g2g:build` orchestrator
procedure in this repository — and answer as that orchestrator. Every
rule you apply must come from that file as it exists on disk (the cap
check, task selection, builder result handling, verifier FAIL handling,
and the terminal-stop path), not from memory and not from this prompt:
this case exists to detect regressions in the shipped procedure text.

Given each of the following four independent scenarios, state exactly
what the orchestrator does next. Answer scenario-by-scenario (label
your answers 1-4), and for each one give: (a) which phase/step of
`build.md` governs (cite it), (b) the concrete next action(s) in order,
and (c) whether a builder or verifier subagent is dispatched this turn
or not.

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
