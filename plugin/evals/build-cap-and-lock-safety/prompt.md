You are acting as the `/g2g:build` orchestrator for the g2g plugin,
reasoning about its checkout-lock and ownership-safety rules (these are
frozen safety invariants, not stylistic preferences):

- OWNERSHIP LOST path (reached only when an ownership-checked heartbeat
  refresh exits nonzero): from that moment nothing on disk is safely
  yours. Write and delete NOTHING (no lock-helper release calls, no
  goal-file deletion, no further spec commits, no stash), push nothing,
  open no PR. Print the exact standalone line
  `G2G OWNERSHIP LOST <owner-token>` by itself, then report the
  helper's exact outcome line and which tasks had already completed
  before the stall.
- Phase 4 step 5 (post-verification rebase onto the default branch,
  before the final evidence run): on conflicts, STOP — run
  `g2g-lock.sh release-terminal <owner-token>`, then
  `git rebase --abort`, then push and open a draft PR titled
  "g2g: <project> (conflicts)" describing them. Never auto-resolve a
  conflict.
- Phase 5 step 2-3 (terminal partial-PR path): push the branch once and
  open the draft PR. If the push or `gh pr create` fails, report the
  failure verbatim with the branch/commit state for a human, then
  CONTINUE to step 3 regardless — `release-terminal` runs on BOTH the
  success and failure outcomes of step 2, mirroring Phase 4 step 7's
  push-then-release order.
- Preflight step 1 (lock acquire): exit 4 (`live-owner`) means another
  `/g2g:build` is LIVE in this checkout right now. ABORT immediately
  and change NOTHING; report the heartbeat and age the helper printed.

Given each of the following four independent scenarios, state exactly
what the orchestrator does, in order, and — just as importantly — what
it must NOT do. Answer scenario-by-scenario (label your answers 1-4).

1. Mid-Phase-3, the ownership-checked heartbeat refresh at the top of
   the turn exits 5 (`ownership-lost`). Three tasks had already been
   marked `passes: true` earlier in this build.

2. Phase 4 step 5's rebase onto the default branch produces a merge
   conflict.

3. In Phase 5, `git push -u origin <branch>` succeeds but the
   subsequent `gh pr create` call fails with an API error.

4. Preflight step 1's lock acquire call returns exit 4 (`live-owner`),
   printing a heartbeat timestamp from two minutes ago.
