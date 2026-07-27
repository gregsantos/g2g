---
description: Experimental — goal-driven build with the task loop on the dynamic-workflow runtime; caps and sequencing enforced in code
argument-hint: <path/to/spec.json> [--continue-branch]
---
# /g2g:build-wf — workflow-backed orchestrator (experimental)

Run the G2G build for the spec at: $ARGUMENTS

Same guarantees as `/g2g:build` — one fresh-context builder per task,
adversarial verifier gate, branch-first, PR-gated, capped, NEVER merges,
no attribution lines anywhere — but the task loop, cap accounting, and
builder-report handling are enforced deterministically by the
`g2g:build-loop` workflow (`plugin/workflows/g2g-build.js`) instead of
per-turn orchestrator discipline. You are still the orchestrator for
everything around the loop, and you NEVER edit source files yourself.

REQUIREMENT: this command needs the dynamic-workflow runtime (Claude
Code >= 2.1.154, workflows not disabled). If the Workflow tool or the
`g2g:build-loop` workflow is unavailable, STOP and tell the user to run
`/g2g:build` instead — do NOT emulate the loop by hand; the whole point
of this command is that the loop is not prose-enforced.

Composition rule (same as dev.md): a slash command cannot invoke another
slash command — where a phase below says "execute build.md's Phase N",
Read `${CLAUDE_PLUGIN_ROOT}/commands/build.md` and execute that phase's
procedure as written, with only the modifications listed here.

## Phase 1 — Preflight
Execute build.md's Phase 1 exactly (lock acquisition with an OWNER
TOKEN, clean-tree check with the exact-path exemptions, work branch /
`--continue-branch` handling, spec commit and gitignored-spec refusal,
evidence-script validation, TURN_CAP / HOURS_CAP / BUILD_START
computation — including its LOCK RELEASE ON PREFLIGHT ABORT rule).
Additionally read `.claude/g2g.json` → `models.builder` (default
`sonnet` when the file or field is absent) for Phase 3's args.

## Phase 2 — Arm the goal
Execute build.md's Phase 2 (ownership-checked refresh first, write
`.g2g-goal`, then the MANDATORY read-back that binds this session), but
write this MODIFIED condition instead of build.md's — with
`<spec-path>`, `<N>`, and `<owner-token>` filled in:

   "The most recent G2G EVIDENCE block in the transcript was produced by
   running `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-evidence.sh <spec-path> --full`
   as a real command execution (visible as tool output in the transcript),
   not authored as plain assistant text, shows the tasks summary line
   reporting all tasks passed — <N> total | <N> passed — with zero
   in_progress/pending/blocked, every verify line exiting 0, and verifier:
   PASS, AND the transcript also shows, after this condition was armed, a
   VERIFIER REPORT block with a verdict line of PASS delivered as the
   final message of a dispatched g2g:g2g-verifier subagent (visible as
   Agent tool output in the transcript, not authored as plain assistant
   text) — or the transcript shows, as real tool output of the
   g2g:build-loop workflow run, a returned result whose outcome field is
   cap-turns, cap-hours, blocked, ownership-lost, or error — or shows the
   exact line 'G2G OWNERSHIP LOST <owner-token>' printed BY ITSELF as a
   standalone terminal marker after this condition was armed — the quoted
   occurrence of that text inside this condition (including this
   read-back) does NOT count."

   (Differences from build.md's condition, deliberate: the per-turn
   `G2G TURN k/CAP` clauses are gone because the workflow enforces both
   caps in code and reports a terminal outcome as tool output — there is
   no turn line for an evaluator to miss. The completion clause,
   including the P1 requirement of a subagent-delivered VERIFIER REPORT,
   is unchanged.)

## Phase 3 — Run the task loop
Invoke the `g2g:build-loop` workflow via the Workflow tool with `args`
set to this object (values from Phases 1–2; `tasks` and `context` read
fresh from the spec file so `--continue-branch` resumes naturally —
tasks with `passes: true` are skipped by the loop's own selection):

   { "specPath": <spec-path>, "ownerToken": <owner-token>,
     "pluginRoot": ${CLAUDE_PLUGIN_ROOT}, "branch": <work-branch>,
     "turnCap": <TURN_CAP>, "hoursCap": <HOURS_CAP>,
     "buildStart": <BUILD_START>, "builderModel": <models.builder>,
     "context": <spec context block>, "tasks": <spec tasks array> }

Wait for the workflow result. While it runs you dispatch NOTHING
yourself — builders, spec commits, and heartbeat refreshes all happen
inside the loop. Then branch on `result.outcome`:

- `complete` — every task passed; go to Phase 4.
- `blocked`, `cap-turns`, `cap-hours`, or `error` — terminal partial;
  go to Phase 5, including `result.detail` and the `result.tasks`
  summary in the PR body.
- `ownership-lost` — execute build.md's OWNERSHIP LOST path verbatim:
  print `G2G OWNERSHIP LOST <owner-token>` BY ITSELF, mutate nothing on
  disk, push nothing, and report `result.detail` (the lock helper's
  outcome line) plus which tasks had completed. This run is over.

## Phase 4 — Verifier gate (semantics unchanged from /g2g:build)
Execute build.md's Phase 4 — REVERIFY_CAP, the heartbeat refresh and
turn line before the verifier dispatch, `models.verifier` routing,
VERIFIER REPORT seeking, fix-builder dispatch on FAIL, verdict written
to the spec on PASS, rebase/push-once/PR — with one modification: skip
its per-finding turn-line/cap checks (step 3's `k >= TURN_CAP` gating);
the main loop's caps were already enforced in code, and fix rounds here
are bounded by REVERIFY_CAP and the finding count instead. Everything
else applies verbatim, including `release-terminal` on both the
conflict and clean-PR paths.

## Phase 5 — Terminal stop
Execute build.md's Phase 5 verbatim (draft partial PR labeled
`g2g:partial`, honest outstanding-work list, no attribution lines,
`release-terminal <owner-token>` before finishing), appending the
workflow result's task summary and `detail` so the PR records exactly
where and why the loop stopped.
