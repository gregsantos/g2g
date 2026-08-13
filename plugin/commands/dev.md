---
description: G2G dev pipeline — generate a spec, then build it; --review pauses for approval
argument-hint: '"<what to build>" [--review]'
---
# /g2g:dev — spec → build pipeline

Run the full G2G pipeline for: $ARGUMENTS

Two phases: Phase A generates and validates a spec exactly as /g2g:spec
does; Phase B executes /g2g:build's procedure on the result. You are
one session throughout — in Phase B you become the build ORCHESTRATOR
with everything that implies (you never edit source files; builders
build). A slash command cannot invoke another slash command — you compose
them by reading the command files below and executing their procedures.

## Phase A — spec
1. Strip `--review` from the arguments if present and remember it. The
   remaining arguments are the spec input (same three source forms as
   /g2g:spec: bare/-p text, -f <file>, --from-findings [path]).
2. Read `${CLAUDE_PLUGIN_ROOT}/commands/spec.md` and execute its full
   procedure on that input — every rule applies (single input source,
   the skill, verificationCommands sourcing, no overwrite, evidence-
   script validation, tracking check, no commit). Skip only its closing
   "next step" suggestion; this pipeline continues below instead. This
   INCLUDES spec.md's concurrency liveness check (its step 3a): before
   writing the spec file, query
   `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh status` — read-only, no
   owner token, never acquires/refreshes/releases/creates/deletes the
   lock, goal, or mutex — and on a live owner WARN prominently (naming
   the owner token and heartbeat) and PROCEED anyway, because Phase A
   only ever writes a fresh file under its own slug; on stale debris,
   report the age and note a future build's acquire will reclaim it,
   and proceed. Also report the owner token and heartbeat the helper
   printed for the stale-debris case, exactly as spec.md's step 3a
   does.
3. If spec generation aborted for any reason: STOP and report the abort
   reason. Never proceed to build without a validated spec file.

See `plugin/README.md`'s "Concurrency model" section for the full
normative description of the checkout-lock protocol this Phase A
liveness check and Phase B's acquire/release both participate in.

## Gate — only when --review was passed
Present the spec (project, task table, verificationCommands) and END
YOUR TURN asking for approval. Proceed only after the user approves; if
they request changes, edit the spec file, re-run the evidence-script
validation, and ask again. Without --review, proceed immediately.
(--review is meaningless in a headless run — no one can answer; the
session will simply end after Phase A with the spec written and
reported, which is the correct, safe outcome.)

## Phase B — build
Read `${CLAUDE_PLUGIN_ROOT}/commands/build.md` and execute it exactly as
written, as the orchestrator, with Phase A's spec path as its argument.
Its preflight handles the work branch and commits the still-uncommitted
spec file (Phase 1 step 3a). Every rule applies unchanged: the caps, the
`.g2g-goal` lifecycle, evidence blocks produced by really running the
script, builder and verifier dispatches, single push at PR time, draft
partial PRs on terminal stops, never merging, no attribution lines.

Final report: the spec path and how it was produced, then the build
outcome exactly as build.md's terminal phase reports it.
