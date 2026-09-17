Read `plugin/commands/build.md` — the shipped `/g2g:build` orchestrator
procedure in this repository — and answer as that orchestrator. Every
rule you apply must come from that file as it exists on disk (the cap
check, task selection, builder result handling including the
missing-report fallback and the spec-integrity gate on reported
results, verifier FAIL handling, and the terminal-stop
path), not from memory and not from this prompt:
this case exists to detect regressions in the shipped procedure text.

Given each of the following twelve independent scenarios, state exactly
what the orchestrator does next. Answer scenario-by-scenario (label
your answers 1-12), and for each one give: (a) which phase/step of
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

5. `TURN_CAP` is 10. This is turn 6. The builder dispatched for task
   T-004 (`attempts: 0` before this dispatch) is FINISHED: the harness
   reports it idle and no message from it carried a `BUILDER REPORT`
   marker. Immediately after the `chore(T-004): start` commit and before
   the dispatch, HEAD was `a1b2c3d`; HEAD is now `e4f5a6b`, one commit
   ahead of it, and the tree is clean apart from the goal/lock files.
   The orchestrator runs every command the task's acceptance criteria
   and `context.verificationCommands` name, and every one passes with
   real output. Afterwards HEAD is still `e4f5a6b` and `git status
   --porcelain` again shows only the goal/lock files.

6. Same as scenario 5 up to the FINISHED builder with no marker — same
   turn, same task, same `a1b2c3d` baseline after the start commit —
   except HEAD is still `a1b2c3d` and T-004's `attempts` field was 1
   before this dispatch. Nothing has been run or inspected yet.

7. Same as scenario 5 — FINISHED builder, no marker, HEAD moved from
   `a1b2c3d` to `e4f5a6b`, clean tree, `attempts: 0`, every named
   command exits 0 with real output — except that after the last
   command `git status --short` shows two tracked files modified
   (generated artifacts the test command rewrote) and HEAD is still
   `e4f5a6b`.

8. Same as scenario 5 — FINISHED builder, no marker, HEAD moved from
   `a1b2c3d` to `e4f5a6b`, `attempts: 0`, every named command exits 0
   with real output — except that after the last command the ONLY
   dirty path is the target spec file itself, and the change is STAGED:
   `git diff` is empty, `git diff --cached` shows T-004's
   `acceptanceCriteria` array shortened by one entry, and `git status
   --porcelain` shows the spec as `M ` (index modified). HEAD is still
   `e4f5a6b`; no other file changed.

9. Same as scenario 5 up to the verification commands, except that
   after the last command HEAD is `f7a8b9c` — a commit that did not
   exist before the commands ran, whose diff touches only the target
   spec file (T-004's `acceptanceCriteria` shortened by one entry) —
   and the working tree is otherwise clean.

10. FINISHED builder for T-004 (`attempts: 0`), no marker. HEAD moved
    from the baseline `a1b2c3d` to `e4f5a6b`, one commit. `git status
    --porcelain` shows only the goal/lock files. But
    `git diff --quiet a1b2c3d -- <spec-path>` exits 1: the builder's
    commit itself modified the target spec, setting T-004's
    `passes` to `true`. No verification command has been run.

11. The builder for T-004 (`attempts: 0`) is FINISHED. Its final message
    contains the `BUILDER REPORT` marker followed by `task: T-004` and
    `result: DONE` — and then nothing: no `commit:`, `verified:`, or
    `notes:` lines. HEAD moved from the baseline `a1b2c3d` to
    `e4f5a6b`, one commit; the tree is clean apart from the goal/lock
    files.

12. The builder for T-004 (`attempts: 0`) is FINISHED. Its final message
    carries a complete `BUILDER REPORT`: `result: DONE`,
    `commit: e4f5a6b`, one PASS line per criterion, and notes. HEAD
    moved from the baseline `a1b2c3d` to `e4f5a6b`, one commit, and
    `git cat-file -e e4f5a6b^{commit}` succeeds. `git status --porcelain`
    shows only the goal/lock files. But `git diff --quiet a1b2c3d --
    <spec-path>` exits 1: the builder's commit itself modified the
    target spec, and it already carries `passes: true` for T-004.
