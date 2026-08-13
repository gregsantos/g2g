# Proposal: a concurrency model for the g2g command surface

**Status:** proposed, awaiting independent review. Nothing here is implemented
except where noted as shipped.

**Origin:** the operator question "can I run two `/g2g:build` and a `/g2g:spec`
in different sessions without conflicting?" — answered no, then audited.

## The audit

| Command | Worktree? | Lock? | Mutates |
|---|---|---|---|
| `/g2g:improve` | **yes** — `git worktree add` per tick | via improve-cycle | its own worktree |
| `/g2g:improve-cycle` | runs inside improve's worktree | **yes** | that worktree |
| `/g2g:build` | no | **yes** | branch, refs, tree, spec |
| `/g2g:build-wf` | no | yes — delegates to build.md Phase 1 | same |
| `/g2g:dev` | no | Phase B only, via build.md | spec (Phase A), then same |
| `/g2g:go` | no | **no** | branch, refs, tree |
| `/g2g:review` | no | **no** | `review-output/*` (tracked) |
| `/g2g:spec` | no | **no** | `specs/<slug>.json` |
| `/g2g:status` | reads `git worktree list` | n/a | nothing |

Three defects fell out, filed as findings:

- **F-064** *(shipped, PR #14)* — the lock's paths were CWD-relative, so
  one-build-per-checkout was bypassable from a subdirectory. Reproduced: with a
  live root lock held, `acquire` from `sub/dir/` returned exit 0 instead of 4 and
  created a second lock. Now anchored to the enclosing worktree root, with the
  Stop hook and the goal writer resolving the same anchor. A probe during that
  build established that `CLAUDE_PROJECT_DIR`, `$(pwd)`, and the hook payload's
  `.cwd` all resolve to a session's starting **subdirectory**, so the hole was
  reachable in practice.
- **F-066** — `/g2g:go` runs `git checkout -b` with no lock check. A live build
  keeps the tree clean between turns, so `go`'s clean-tree preflight passes
  mid-build and the branch switch moves HEAD; the build's next commit lands on
  `go`'s branch.
- **F-065** — a live build's crash-stash absorbs files written by unlocked
  commands into `g2g-crash-<task-id>` under a misleading label. For `/g2g:review`
  the swept file is the tracked backlog other sessions read.

## The central distinction

Two isolation needs get conflated, and conflating them is where a concurrency
design goes wrong:

**Ref/HEAD/tree mutators** — `build`, `build-wf`, `dev` Phase B, `go`,
`improve-cycle`. A worktree genuinely isolates these. `/g2g:improve` already
proves the pattern in production.

**Shared-artifact writers** — `review`, `spec`. A worktree makes these *worse*.
`/g2g:review`'s entire product is the merged `review-output/findings.json`; run it
in an isolated worktree and the result is stranded on a branch nobody merges, and
two concurrent reviews produce two divergent backlogs. What these need is
serialized access to a shared resource, not isolation from it.

There is also a genuinely serial resource inside the backlog: **`F-0NN` id
allocation**. Two concurrent reviews would both claim the next id. No amount of
worktree isolation fixes that; it needs allocation under a lock, or ids that
cannot collide by construction.

## Phase 1 — safety (specced, buildable now)

`specs/concurrency-safety.json`, four tasks:

1. `/g2g:go` becomes a lock participant (F-066).
2. The build's crash-stash surfaces foreign paths instead of absorbing them
   (F-065).
3. `spec`, `review`, and `dev` Phase A check read-only for a live owner before
   writing, and `spec` stops silently overwriting an existing slug.
4. The README carries the model normatively; CLAUDE.md gains a bullet so the next
   command added cannot silently reintroduce the gap. One version bump.

Phase 1 adds **no capability**. It makes today's concurrent usage safe and
legible: mutators synchronize, writers announce themselves, and the rules are
written down once.

## Phase 2 — capability (design, needs a decision)

### 2a. Opt-in worktree-isolated builds

Today two builds in one checkout serialize: the second aborts with exit 4. That
is correct but limiting. Worktree-per-build would let N builds run at once,
reusing improve's proven `git worktree add "$WT" -b <branch> <default-branch>`
pattern.

**Why opt-in, not default:** a fresh worktree means a fresh checkout, and the
spec's `verificationCommands` run in it. In this repo (markdown + bash) that is
nearly free. In a host repo with a heavy install step, every build would pay a
full dependency install — and `make check`-equivalents that depend on installed
state would fail outright in a bare worktree.

Proposed shape: `.claude/g2g.json` → `concurrency.isolateBuilds` (default
`false`). When true, `/g2g:build` creates its own worktree and runs there; when
false, today's in-place serialization stands.

**Open questions for review:**
- Where does the worktree live, and who removes it? `/g2g:improve` already owns
  reclaim/cleanup logic for crashed ticks — reuse it, or keep them separate?
- The PR is opened from the worktree's branch. Does anything in the PR flow
  assume the main checkout?
- Does the Stop hook's head-binding (evidence `head:` vs repo state at stop time)
  behave correctly when the armed session's anchor is a worktree that a cleanup
  step may have already removed? This is the sharpest risk in 2a.
- `/g2g:status` currently reports improve ticks from `git worktree list`; it would
  need to distinguish build worktrees from improve worktrees.

### 2b. Serialized backlog writes

For `/g2g:review` (and anything else that merges into
`review-output/findings.json`):

- **Option A — artifact lock.** A second named lock (e.g. `.g2g-review.lock`)
  through the same helper, held only across the read-merge-write. Cheap, reuses a
  tested protocol, but requires the helper to take a lock *name* — a contract
  change to the one script CLAUDE.md marks as the sole implementation.
- **Option B — collision-proof ids.** Replace `F-0NN` with ids that cannot
  collide (content hash, or a per-run prefix). No lock needed; costs the
  human-friendly sequential numbering the whole backlog and every commit message
  currently uses.
- **Option C — accept it.** Document that concurrent reviews are unsupported and
  have the Phase 1 liveness check refuse. Zero code, zero capability.

I lean **A** for a small helper change plus **C** as the interim, but this is the
decision I most want a second opinion on — B is a one-way door on the id scheme,
and A widens the contract of the most safety-critical script in the plugin.

## What I would *not* do

- Give `/g2g:review` or `/g2g:spec` a worktree. It inverts their purpose.
- Make worktree-isolated builds the default. It moves a cost onto every host repo
  to buy concurrency most single-operator runs never use.
- Put the lock in the git *common* dir to "fix" cross-worktree contention. That
  would serialize worktrees and break both concurrent builds and improve ticks —
  the opposite of the goal.

## Review asks

1. Is the mutator/shared-writer split the right primary axis, or is there a
   cleaner decomposition?
2. Phase 1 T-002's predicate — distinguishing crashed-builder debris from a
   foreign writer's file — is heuristic by nature. Is "surface, don't absorb"
   with an imperfect predicate the right call, or is there a way to make it
   exact (e.g. the build recording what it touched)?
3. Phase 2b: A, B, or C?
4. Does Phase 2a's Stop-hook/worktree-lifetime interaction have a failure mode
   worth blocking on before any of this is built?
