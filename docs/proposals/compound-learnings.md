# Proposal: a compound learnings store for g2g

**Status:** proposed. Spec written at [`specs/compound-learnings.json`](../../specs/compound-learnings.json);
nothing implemented yet.

**Origin:** an audit of the `compound-engineering` plugin's `ce-compound` and
`ce-compound-refresh` skills, asking which of their strategies g2g should own
natively rather than reach for a second plugin to get.

## The gap

g2g accumulates **findings** and nothing else. `review-output/findings.json`
carries 67 of them with stable ids, a read-modify-write merge, dedup across
categories, revalidation of open findings, and a `stale-<date>` /
`rejected-<date>` lifecycle. That is a mature record of *what was broken*.

There is no record of *what we now know*. So the durable rationale behind
hard-won invariants ends up inlined in `CLAUDE.md` — F-059's head-binding
argument, F-060's account of macOS bash 3.2 swallowing mid-test asserts,
F-061's amendment rule. That placement has four costs:

1. It is always-loaded, in every session, whether or not anyone is near
   the code it describes.
2. It is unindexed — you cannot ask "what have we learned about the Stop
   hook?" and get an answer.
3. It is unversioned against the code it describes. Nothing detects when
   a cited path moves or a cited SHA stops resolving.
4. It only grows. `CLAUDE.md` is the path of least resistance for every
   future F-NNN with a durable "why", and each one makes every session
   more expensive.

Meanwhile a completed build produces a *structured, verifier-adjudicated
record* — acceptance criteria, per-task notes carrying commit SHAs, the
verifier verdict, a deterministic evidence run — and that record is
discarded the moment the PR merges.

**The framing this proposal adopts: findings say what was broken;
learnings say what we now know and why it must stay that way.**

## What g2g takes from ce-compound

| Strategy | Why it transfers |
|---|---|
| **Two-track frontmatter with enums** (bug vs knowledge) | Retrievability is the entire point of a knowledge store. A defect that was fixed and a convention that must survive turnover are different shapes and need different required fields. Enums get re-cut for g2g's domain — commands, agents, scripts, hooks, templates, tests, evals, ci, config, docs. |
| **Grounding validation** | The crown jewel, and the piece most aligned with g2g's existing culture. A doc entering the store becomes trusted knowledge future agents act on *without re-verifying*, so its claims get checked against the tree first. g2g already refuses self-reported completion markers in favor of a real script run; the same posture applied to documentation. |
| **Merge-state claims verify against remote, not the local tree** | Directly load-bearing here. F-061 puts per-task commit SHAs in task notes, and the merge-never-squash rule exists because squashing makes those SHAs unreachable. A learning citing a HEAD-only SHA is one squash away from citing nothing — so that gets its own distinct flag, separate from a SHA that resolves nowhere. |
| **One learning per run** | Batching several learnings through one run is precisely how drafting scaffold ("Learning 3", `{{…}}`) leaks into written docs. |
| **Preconditions before capture** | g2g's version is stronger than CE's: a spec with no verifier verdict is a refusal, not a warning. |
| **Overlap check before creating** | Two docs covering the same ground eventually contradict each other, which is worse than one longer doc. |

## What g2g takes from ce-compound-refresh

Deferred to a follow-up spec, but the schema in T-001 must anticipate it:
the five-outcome maintenance model (Keep / Update / Consolidate / Replace /
Delete), **prefer no-write Keep** (no review breadcrumbs), **match docs to
reality, not the reverse**, **delete don't archive** (git history is the
archive), the retrieval-value test, canonical-doc identification, **age
alone is not a staleness signal**, and **contradiction is a strong Replace
signal**. g2g's variant of that last one: a learning contradicting
`CLAUDE.md`, `plugin/README.md`, or a pinned bats assertion is urgent, not
routine drift.

Note how much of this g2g already implements for findings — `/g2g:review`'s
accumulation rules are the same machinery pointed at a different record.

## What g2g deliberately does not take

- **Session-history archaeology.** CE spends most of its budget
  reconstructing what happened from transcripts because it has no
  structured record. g2g has one. Reading the spec is cheaper and
  better-grounded than excavating a session.
- **The seven-persona research subagent fleet.** Overkill when the
  evidence arrives pre-structured and verifier-adjudicated.
- **`CONCEPTS.md`.** `CLAUDE.md` and `plugin/README.md` already carry
  g2g's vocabulary. A third store is the accretion problem this proposal
  exists to fix.
- **`mode:headless` / `depth:` token parsing.** g2g commands are already
  numbered procedures with explicit phases; CE's mode negotiation solves a
  problem g2g's command surface does not have.
- **Auto-invoke on "that worked".** Every autonomous run in g2g is capped
  in turns, hours, and dollars. A capture step that fires itself inside a
  build spends the build's budget on documentation. Builds *flag* that a
  learning is due; a human runs the capture.

## Shape

Four new or changed surfaces, all inside `plugin/`:

- **`plugin/skills/writing-g2g-learnings/SKILL.md`** — the schema and rules
  contract, mirroring how `writing-g2g-specs` contracts the spec format.
  Lazy-loaded, so the detail costs almost nothing resident. This is where
  the bulk of the ported content lives.
- **`plugin/scripts/g2g-learning-check.sh`** — deterministic grounding
  validator, in the spirit of `g2g-evidence.sh`: frozen output format,
  pinned exit codes, no model call, no writes, no auto-resolution. It
  reports flags; the caller adjudicates with one of exactly three
  resolutions — fix, annotate as historical, or confirm intentional.
- **`plugin/commands/compound.md`** — `/g2g:compound [<spec-path>|F-NNN]`.
  Writes to the checkout, so it joins the checkout-lock protocol as a
  lock *holder*, alongside `build.md` and `go.md`.
- **`docs/learnings/`** — tracked store, stable `L-NNN` ids allocated as
  highest-plus-one and never reused, mirroring the existing F-ID
  convention.

## The migration is conservative

Seeding `L-001`/`L-002`/`L-003` from F-059/F-060/F-061 must not weaken
`CLAUDE.md`. Every prohibition and every one-line rationale **stays** —
those are always-loaded safety rules, and relocating a "never do X" into a
lazily-loaded doc is the one outcome this work must not produce. Only the
long-form incident record moves, and each affected bullet gains an L-ID
citation next to its existing F-ID citation. The test is mechanical: every
"never" and "must" sentence present before the migration is present after
it, and `CLAUDE.md` is no longer than it was.

## Deferred to a follow-up spec

- `/g2g:compound --refresh` — the maintenance pass over the store.
  Deliberately second: a refresh command has nothing to maintain until the
  store holds real docs, and its overlap/supersession analysis is much
  easier to specify against actual entries than against a hypothesis.
- **Learning-due flagging** in `build.md` and `improve-cycle.md` terminal
  paths, surfaced by `/g2g:status`. Held back because `build.md` is 30k of
  load-bearing procedure with parsed report contracts, and it deserves its
  own task and its own verifier pass rather than riding along with the
  foundation.
