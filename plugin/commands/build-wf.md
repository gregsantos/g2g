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
Execute build.md's Phase 2 exactly as written (ownership-checked refresh
first, write the `.g2g-goal` JSON with the Write tool, then the MANDATORY
read-back). The goal file is DATA, identical in shape here — there is no
workflow-specific variant to write, because the Stop hook evaluates
fields rather than prose.

One thing to know about how the caps clear on this path: the workflow
enforces both caps in code and never prints per-turn `G2G TURN` lines, so
the hook's turn-cap clause never fires here. The hours cap still does —
the hook computes elapsed wall-clock time from `buildStart` itself — and
every terminal route below (Phase 4, Phase 5, OWNERSHIP LOST) either
deletes the goal file via `release-terminal` or prints the ownership-lost
marker. Write `turnCap` into the goal anyway, with the real value: it
costs nothing, and it keeps one goal-file schema across both build paths.

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
