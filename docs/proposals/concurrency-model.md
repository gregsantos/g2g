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

Stated as lock granularity rather than command taxonomy: **needs the checkout
exclusively** vs. **needs one file serialized**. Two isolation needs get
conflated, and conflating them is where a concurrency
design goes wrong:

**Ref/HEAD/tree mutators** — `build`, `build-wf`, `dev` Phase B, `go`,
`improve-cycle`. A worktree genuinely isolates these. `/g2g:improve` already
proves the pattern in production.

**Shared-artifact writers** — `review`, `spec`. A worktree makes these *worse*.
`/g2g:review`'s entire product is the merged `review-output/findings.json`; run it
in an isolated worktree and the result is stranded on a branch nobody merges, and
two concurrent reviews produce two divergent backlogs. What these need is
serialized access to a shared resource, not isolation from it.

Do not generalize the writer class beyond `findings.json` — it has exactly one
genuinely contended member. `/g2g:spec` writes a fresh file under its own slug;
its only hazards are slug collision and being swept by the crash-stash, both
Phase 1 items. Treating "shared writers" as a class invites per-artifact locking
machinery that only one artifact needs.

There is also a genuinely serial resource inside the backlog, and it is bigger
than it first looks. `F-0NN` id allocation is serial, but so is the **entire
review run**: dedup against existing findings, revalidation of every open
finding, summary recompute, `lastReviewedSha`. That is a read-modify-write
spanning minutes to an hour, not a file write.

## Phase 1 — safety (specced, buildable now)

`specs/concurrency-safety.json`, five tasks:

1. `/g2g:go` becomes a lock participant (F-066) — including a heartbeat refresh at
   phase boundaries, because the stale threshold is 3600s and a `go` run is not
   reliably short, plus defined exit-5 (reclaimed) handling.
2. The build's crash-stash surfaces foreign paths instead of absorbing them
   (F-065), with the post-surface behavior specified per case: a foreign
   *untracked* file is reported once and remembered as an exclusion; a foreign
   *tracked* modification routes to a terminal partial, because the checkout's
   single-writer premise is broken and the rebase would fail anyway.
3. `g2g-lock.sh` gains a read-only `status` query. Staleness is computed inside
   the helper from the lock's mtime, so a caller reading owner + heartbeat
   *cannot* tell a live owner from crash debris — without this, a command that
   refuses would refuse on debris until some build happens to reclaim it.
4. `spec`, `review`, and `dev` Phase A query `status` before writing. `review`
   **refuses** on a live owner; the other two warn and may proceed. `spec`'s
   overwrite guard already exists — the gap is that no test pins it.
5. The README carries the model normatively; CLAUDE.md gains a bullet so the next
   command added cannot silently reintroduce the gap. One version bump.

Phase 1 adds **no capability**. It makes today's concurrent usage safe and
legible: mutators synchronize, writers announce themselves, and the rules are
written down once.

## Phase 2 — decided against, not deferred

Both Phase 2 proposals were overturned by independent review (Fable 5,
build-with-changes verdict). Recording the reasoning, because "we chose not to"
is worth more to the next reader than an open question.

### 2a. Worktree-isolated builds — do not build as shaped

The original proposal was `concurrency.isolateBuilds`: opt-in, default off, the
session creates a worktree and builds inside it. That shape is **structurally
broken**, not merely risky.

The Stop hook anchors to the *session's* starting directory —
`CLAUDE_PROJECT_DIR`, else the payload's `cwd`, else `PWD` (`g2g-stop.sh:88-122`).
It does not follow wherever a Bash call `cd`s to. So an in-session build in a
worktree it created has exactly two places to arm its goal, and both fail:

- **Arm at the worktree root** → the hook looks in the main checkout, finds no
  goal, and allows the stop. An armed build with *zero* enforcement.
- **Arm at the main checkout root** → evidence and `head:` are computed in the
  worktree, so F-059's head-binding (`g2g-stop.sh:330-354`) mismatches
  permanently. Wedged until the hours cap.

There is no third location. The worktree-*lifetime* concern I originally flagged
as the sharpest risk turns out to be the benign one: if cleanup removes the
worktree before the stop, anchor resolution falls back, finds no goal, and
fail-opens — the same sanctioned exit as deleting `.g2g-goal`.

**What works today with zero code:** the operator creates the worktree and starts
a session *inside* it. The lock and the hook are already per-worktree after
PR #14, so N concurrent builds already work. Phase 1 T-005 documents this as the
supported pattern. If isolated builds are ever wanted from a single session, the
only sound shape is improve-style — a *spawned* headless build whose cwd is the
worktree — and only then is opt-in/default-off the right default, because the
host-repo install cost is real.

### 2b. Serialized backlog writes — option C: concurrent review is unsupported

I originally leaned toward option A (an artifact lock through the existing
helper). That was wrong, for a reason worth stating: **a lock held across the
read-modify-write does not fix lost updates here.** The second review's *analysis*
was performed against a baseline that moved while it ran — dedup decisions,
revalidations, and the summary were all computed against stale state. Re-merging
under a lock is model judgment, not a lock primitive.

To actually be correct, the lock would have to be held for the whole review run
(minutes to an hour), making `/g2g:review` a full lock participant with heartbeat
obligations — not the small helper change I proposed. Option B (collision-proof
ids) is a one-way door on the id scheme and still doesn't fix merge divergence.

So: **C**, enforced by Phase 1 T-004's refusal path. If real demand appears, the
correct shape is per-run finding files folded by a separate merge step, not a file
lock. And the helper's contract should only ever widen read-only first — which is
exactly what T-003's `status` query is.

## What I would *not* do

- Give `/g2g:review` or `/g2g:spec` a worktree. It inverts their purpose.
- Make worktree-isolated builds the default. It moves a cost onto every host repo
  to buy concurrency most single-operator runs never use.
- Put the lock in the git *common* dir to "fix" cross-worktree contention. That
  would serialize worktrees and break both concurrent builds and improve ticks —
  the opposite of the goal.

## Review outcome

Independently reviewed by a Fable 5 session with a fresh context, read-only.
**Verdict: build-with-changes** on Phase 1; reconsider Phase 2a rather than defer
it. All five spec defects it raised are folded into
`specs/concurrency-safety.json`; two were factual errors I had shipped into the
spec and are worth naming:

- T-003 (now T-004) claimed `/g2g:spec` lacked a slug-collision guard. It has had
  one since the initial commit (`spec.md` step 4), so the criterion was vacuously
  true and would have confused a fresh-context builder. The real gap is the
  missing test.
- T-001 sent a builder hunting for "the release form that removes only the lock,
  and if no such form exists, state that". `release-preflight` **is** that form,
  documented in the helper's own usage block. Dead text costing discovery time.

The other three: T-005's "reference the README rather than restating" could lead a
builder to prune `build.md`'s procedural lock text, which `tests/commands.bats`
pins with 43 assertions — now constrained to additive pointers only; T-002's
post-surface behavior was undefined, and the tracked-modification case would
re-trip the tree check every turn and break the rebase; and T-004's liveness check
by raw file read cannot distinguish live from stale, which is why `status` became
its own task.

**On T-002's predicate:** exactness is not achievable, and the reason belongs in
the record. The one writer that cannot report a manifest is precisely the crashed
builder, and a pre-declared file list does not bind an agent that wandered. The
orchestrator does guarantee a clean tree at every dispatch, so "dirty at crash" is
exact in *time* but not in *authorship*. Surface-don't-absorb with a stated,
imperfect predicate is the right call.

## Postscript: the hazard bit us in-session

While the review ran, the reviewing session checked out a different branch in this
shared checkout. A commit intended for `chore/backlog-reconcile-f067` landed on
`g2g/lock-path-anchoring` instead, and the subsequent push pushed the still-empty
branch. Recovered by cherry-pick; nothing lost.

That is **F-066's exact mechanism** — an unsynchronized actor moving HEAD under
another session's work in a shared checkout — reproduced accidentally, against us,
by a session explicitly told to be read-only. It is also a scope note: Phase 1
addresses *commands*, but subagents and reviewers dispatched into a live checkout
are the same class of actor and are covered by no lock at all.
