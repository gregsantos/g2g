---
description: One-off G2G task — branch-first, implement, verify, commit; --pr to open a PR
argument-hint: '"<what to do>" [--pr]'
model: sonnet
---
# /g2g:go — one-off task

Execute this one-off task autonomously: $ARGUMENTS

/g2g:go participates in the checkout-lock protocol (F-066): it competes
with /g2g:build and other /g2g:go runs for the same working tree, so it
acquires the lock via `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh` — the
sole implementation of the synchronization protocol — before step 1
creates any branch, refreshes the heartbeat at phase boundaries, and
releases with `release-preflight` on every terminal path reached after a
successful acquire. Unlike /g2g:build, /g2g:go arms no `.g2g-goal` and
needs no Stop-hook enforcement, so it must NEVER call `release-terminal`
— that call deletes the goal/lock pair outright, and a foreign
`.g2g-goal` belonging to a live /g2g:build must never be touched by a
one-off task. Never create, mutate, or delete `.g2g-goal.lock` or
`.g2g-goal.mutex` by hand, and never compute staleness in prose — branch
only on the helper's documented exit codes.

See `plugin/README.md`'s "Concurrency model" section for the full
normative description of the checkout-lock protocol and how /g2g:go
fits into it alongside /g2g:build and the other commands.

Procedure — deviations are failures:
0. Checkout lock: choose an OWNER TOKEN (opaque, single-line, unique to
   this run — e.g. `g2g-$$-<epoch seconds>`) and run, from the repo
   root, BEFORE step 1 creates any branch:
   `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh acquire <owner-token>`
   Remember the owner token — every later helper call in this procedure
   (refresh, release-preflight) needs it. Branch ONLY on the exit code:
   - Exit 0 (`acquired` or `reclaimed ...`) — you hold the lock. Proceed
     to step 1.
   - Exit 4 (`live-owner`) — another build is LIVE in this checkout
     right now. ABORT immediately, change NOTHING, and report the
     heartbeat and owner the helper printed.
   - Exit 2, 6, 7, or 8 — the lock state cannot be safely judged (bad
     owner token, mutex stuck, malformed state, or an operational
     failure). ABORT, print the helper's output verbatim, and change
     NOTHING.
   Do NOT run any release call on this step's abort paths — acquisition
   itself failed, so any lock in place belongs to someone else, not to
   this run.
0a. LOCK RELEASE ON PREFLIGHT ABORT: from this point — a successful step
    0 acquire — until step 5a's own release, every terminal path this
    run takes must release the lock before reporting the abort,
    including step 1's preflight aborts (dirty tree, or being on the
    default branch) and step 2's abandonment of the task (cannot be
    completed, blocked, or otherwise given up on). On any such abort,
    run:
    `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh release-preflight <owner-token>`
    — the same call step 5a documents — before reporting the abort.
    Exit 5 (`ownership-lost`) there means the lock already stopped
    being yours while you were aborting anyway: report it and abort
    without touching anything further. Without this, a preflight abort
    or an abandoned task leaves the lock LIVE and blocks every
    subsequent /g2g:build, /g2g:go, and /g2g:review in this checkout
    for the full stale threshold — before this discipline, /g2g:go took
    no lock at all, so this would otherwise be a regression the
    checkout-lock protocol introduces. This is IN ADDITION to step 5a's
    enumerated release paths (verification, commit, push, PR creation,
    and success) — it does not replace or narrow them. Step 0's
    instruction not to run any release call on ITS OWN abort paths is
    unchanged and stays scoped to acquisition failure specifically
    (exit 4, 2, 6, 7, or 8): there the lock belongs to someone else and
    must never be touched; this note covers only paths reached AFTER a
    successful acquire.
1. Preflight: `git status` must be clean; you must NOT be on the default
   branch when committing. Create `g2g/go-<slug>` (slug: lowercase task
   summary, hyphenated, ≤5 words) from the current HEAD.
2. Implement the task fully. No stubs. Follow repo conventions (CLAUDE.md).
   Never weaken tests, lint, or CI.
2a. Heartbeat before verification: run
    `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh refresh <owner-token>`
    The lock's default staleness threshold is 3600 seconds and a go run
    is NOT reliably short — implement/verify/fix cycles can exceed it,
    after which another build may legitimately reclaim the checkout.
    Branch on the exit code:
    - Exit 0 (`refreshed`) — still the owner, proceed to step 3.
    - Exit 5 (`ownership-lost`) — another build reclaimed the checkout
      as stale. Report the reclaim, write and delete NOTHING further,
      push nothing, and flag the branch as possibly contested for a
      human to salvage. Do not call release-preflight here — the lock
      is no longer yours to release.
    - Exit 6, 7, or 8 — treat identically to exit 5: report the
      helper's output verbatim, write and delete nothing further, push
      nothing, and flag the branch as possibly contested.
3. Verify: if `.claude/g2g.json` exists and has `verificationCommands`,
   run them all and show real output. Otherwise run the repo's documented
   test/lint commands. Failures = fix and re-verify, don't report success.
3a. Heartbeat before commit: run
    `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh refresh <owner-token>`
    and branch on its exit code exactly as step 2a — exit 0 proceeds to
    step 4; exit 5, 6, 7, or 8 reports the reclaim/failure, changes and
    pushes nothing further, and flags the branch as possibly contested.
4. Commit `feat: <summary>` (or `fix:`/`chore:` as appropriate). No
   attribution lines in the commit message. If `--pr` will be used, the PR
   title and body must also contain no attribution lines (no 'Generated
   with Claude Code', no Co-Authored-By trailers). DO NOT push.
4a. Heartbeat before push: if `--pr` was passed, run
    `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh refresh <owner-token>`
    and branch on its exit code exactly as step 2a — exit 0 proceeds to
    step 5; exit 5, 6, 7, or 8 reports the reclaim/failure, changes and
    pushes nothing further, and flags the branch as possibly contested.
    If `--pr` was not passed, skip this step.
5. Only if `--pr` was passed: push the branch once (`git push -u origin
   <branch>`) and `gh pr create` with a body summarizing what/why/how
   verified. Never merge.
5a. Release the checkout lock: on every path that reaches this step —
    the success path, and the failure paths of verification (step 3),
    commit (step 4), push, and PR creation (step 5) — run
    `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh release-preflight <owner-token>`
    and report its outcome. This is `release-preflight`, the lock-only
    release the helper's own usage block documents as "remove the owned
    lock only (preserves any .g2g-goal this run never armed)" — NEVER
    `release-terminal`, because /g2g:go never arms a goal and must
    never delete a foreign build's `.g2g-goal`. Exit 5
    (`ownership-lost`) means the lock already stopped being yours —
    nothing further to delete; report it and continue to step 6. NEVER
    run this release on step 0's acquisition-failure path — there the
    lock belongs to someone else.
6. Report: branch name, commit sha, verification output summary, PR URL if
   created. If you could not complete the task, say exactly what's missing —
   never claim partial work as done.
