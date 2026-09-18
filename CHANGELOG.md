# Changelog

## 0.7.6 (2026-09-17)

Closes the gap between a build's proven evidence and its pull request
(F-038). The Stop hook's completion check required three things after
arming — a paired `complete (proven)` evidence block, a head line matching
the current tree, and a dispatched verifier PASS — and `/g2g:build` Phase 4
step 6 satisfies all three, while the push, the `gh pr create`, and the
`release-terminal` that deletes `.g2g-goal` are all step 7. A turn
boundary between the two let the hook allow the session to end with no PR
opened and the goal still on disk.

### Changed
- `plugin/scripts/g2g-stop.sh` adds a fourth completion requirement: a
  `gh pr create` tool call — matched word-bounded anywhere in the command,
  since build.md chains a `PROJECT_NAME` capture in front of it — paired
  by tool-use id to a result carrying a pull-request URL, after the arming
  point. A complete build with no PR now blocks with a reason that points
  at Phase 4 step 7 and the release that must follow. A URL in assistant
  prose, a URL paired to a command that is not `gh pr create`, a `gh pr
  create` whose result carries no URL (gh failed), or a PR opened before
  arming do not satisfy it. Every existing allow and block behaviour is
  unchanged and its tests carry a PR record where they model a finished
  build; six new tests pin the gate.
- `/g2g:build` Phase 4 step 7 gains the failure path Phase 5 already had:
  if `git push` or `gh pr create` fails, report it verbatim and CONTINUE
  to `release-terminal`, so a failed push still has a legal way out of the
  armed goal. It also states that the turn must not end between step 6 and
  the release, and why.
- `plugin/README.md`, `CLAUDE.md`, and build.md's Phase 2 description of
  what allows a stop name the new requirement; the hook's escalation
  text now also points a complete-but-unreleased build at Phase 4 step 7
  rather than only at the partial path. Resumed builds
  (`--continue-branch`) satisfy the gate too: `gh pr create` on a branch
  whose PR already exists prints that PR's URL. `/g2g:build-wf` runs
  build.md's Phase 4 and 5 verbatim in the main transcript, so its PR
  call pairs the same way.

## 0.7.5 (2026-09-17)

Gives the slug derivation an explicit charset and a single executable
home (F-035). `/g2g:build`, `/g2g:spec`, and `/g2g:go` derived branch
names and spec filenames from an informal "lowercase, hyphenated form"
rule with no character whitelist, and `/g2g:build` interpolated the
spec's `project` field verbatim into a commit message and PR titles. A
project value carrying `..`, `/`, a `.lock` suffix, a leading `-`, or
shell metacharacters could yield an unexpected ref or, if the executing
agent composed the git/gh command as a shell string, argument injection.
The improve path names its project safely; `-f <file>` and bare prompts
did not.

### Added
- `plugin/scripts/g2g-slug.sh` — the sole implementation of the slug
  rule: ASCII-lowercase, every run of characters outside `[a-z0-9]`
  becomes one hyphen, leading/trailing hyphens trimmed, cut to 60
  characters. The output always matches
  `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`, which git accepts as a ref component
  and every filesystem as a file name. `g2g-slug.sh <text>` slugs a
  string; `g2g-slug.sh --spec <path>` slugs the spec's `.project` so the
  untrusted value never enters a command line the orchestrator composes.
  Exit 2 on a missing argument, an unreadable spec, a missing or
  non-string project field, or an input with nothing slug-worthy in it.
  Runs under the macOS system bash 3.2. Pinned by
  `tests/plugin_slug.bats`, including a hostile-input set checked with
  `git check-ref-format`, and a test that the helper reproduces the branch
  name `tests/smoke.sh` expects for the sandbox spec.

### Changed
- `/g2g:build` Phase 1 step 3 derives the branch slug via
  `g2g-slug.sh --spec <spec-path>` and aborts on exit 2; it also captures
  `PROJECT_NAME` (control characters stripped) inside the same Bash
  command that uses it and passes it as one quoted argument wherever the
  project name enters a commit message or PR title (the spec commit, the
  clean PR, the conflicts PR, the partial PR) — never carried across
  tool calls and pasted into the command text.
- `/g2g:spec` step 4 writes the draft spec to a `mktemp -d` directory
  outside the checkout, derives the slug with `g2g-slug.sh --spec` on
  that file, checks for a collision, and moves it into `specs/` — the
  project name is read from JSON and never pasted into a shell argument
  (Codex adversarial review of PR #35: a double-quoted paste lets Bash
  expand `$(…)` and backticks before the helper runs). `/g2g:go` step 1
  shows the single-quoted-literal form for its model-composed summary and
  restricts the summary to a charset that cannot end the literal early. A
  pin in `tests/commands.bats` fails if any command shows a double-quoted
  `g2g-slug.sh "…"` template. `/g2g:improve-cycle` no longer
  says to adjust "the slug" by hand, since it follows from the project
  name. Every existing tracked spec's project field slugs to its current
  filename under the helper except the two whose filenames never followed
  the old rule either (`example.json`, `compound-learnings.json`), both
  long complete.
- Slug collisions (two names, one slug) are unchanged: `/g2g:spec`'s
  overwrite guard and `/g2g:build`'s branch-exists abort already refuse
  them.

## 0.7.4 (2026-09-17)

Enforces the spec dependency graph at runtime (F-037). `/g2g:build`
selects the next task by requiring every `dependsOn` id to have
`passes: true`, but nothing checked that those ids exist or that the
graph is acyclic — a spec with a dangling dependency or a cycle left every
task unselectable, and the build fell straight through to a partial PR
having built zero tasks, with no diagnostic saying why. The acyclic /
existing-id rule lived only in authoring guidance.

### Changed
- `plugin/scripts/g2g-evidence.sh` now validates the dependency graph
  before printing anything, on the documented exit 2 (invalid spec):
  `dependsOn` must be an array of strings on every task (absent or null
  reads as empty), every id must name a task in the same spec, and the
  graph must be acyclic. The message names the offending task and id
  (`task T-002 depends on unknown task id T-009`) or the tasks on the
  cycle (`dependsOn cycle among tasks: T-001, T-002`). `/g2g:build`
  Phase 1 step 5 already aborts on exit 2, so the check reaches every
  preflight with no orchestrator change; the diagnostic reaches the
  operator through the script's stderr in the tool output. Both
  diagnostics strip control characters from the ids they echo, like every
  other spec string that reaches the transcript: the gate exits before the
  real verdict line prints, so an id carrying a newline-separated
  `verdict: complete (proven)` would otherwise have been the block's only
  verdict and the Stop hook accepted it (found by Codex adversarial review
  of PR #33; pinned by a Stop-hook test that feeds the real script's
  output to the hook). Header, footer, verdict line, and the 0/2/3
  exit-code contract are unchanged.
- `plugin/skills/writing-g2g-specs/SKILL.md` notes that the dependsOn
  discipline is now enforced by the evidence script.

## 0.7.3 (2026-09-17)

Closes the gap #31 found while landing #29: `/g2g:build` Phase 3 step 8
committed the spec as bookkeeping immediately after a *reported* `DONE` or
`FAILED`, with nothing between the builder's return and that commit
checking whether the builder had modified the spec. A builder that edited
the spec against `g2g-builder.md` rule 6 and then reported normally had
its mutation committed as `chore(<id>): complete` or `attempt N` — and in
the DONE case alongside `passes: true` — while the NO-REPORT FALLBACK
already restored the spec and scored the same builder FAILED. Reporting
was the less-guarded route into step 8.

### Changed
- `plugin/commands/build.md` — Phase 3 step 8 opens with an entry gate
  that applies step 7 (d)'s SPEC RESTORE rule on EVERY entry, a reported
  DONE or FAILED as much as a fallback verdict: if the spec differs from
  the DISPATCH BASELINE in the index or the working tree, restore it from
  the baseline, confirm, and score the attempt FAILED regardless of the
  reported result — the verdict the fallback's precondition (a) already
  gives a spec-touching builder whose report is missing — with notes
  recording the spec mutation, the reported result and `commit:`, and the
  sha(s) between baseline and HEAD. The restore mechanics stay defined
  once, in step 7 (d); step 5 now names steps 7 and 8 as the baseline's
  consumers. Not covered here: the `/g2g:build-wf` workflow
  (`plugin/workflows/g2g-build.js`) writes spec bookkeeping through its
  own writer agents and still needs the equivalent check.
- `plugin/commands/build.md` — BLOCKING WAIT gains a POST-WAIT REFRESH:
  once a builder or verifier is FINISHED, the orchestrator runs the
  OWNERSHIP-CHECKED REFRESH again before scoring anything it produced or
  writing anything, and a nonzero exit routes to OWNERSHIP LOST. The
  heartbeat was refreshed only at the start of a turn, and the wait is
  inside the turn, so a build that outlasted the lock's stale threshold
  let a concurrent build reclaim the checkout — and the SPEC RESTORE above
  would then have rewritten the replacement build's spec from this build's
  stale baseline (found by the PR #32 adversarial review). Phase 3 step 7
  and Phase 4 step 2 reference it; OWNERSHIP LOST names it as an entry.
- `plugin/evals/build-orchestration-decisions` — scenario 12 (a usable
  reported DONE whose commit modified the spec with `passes: true`
  already set), scenario 13 (a usable DONE whose post-wait refresh
  exits 5), and scenario 14 (the same with no report at all — the
  fallback must not run before the refresh), each with its grading
  criterion.

## 0.7.2 (2026-09-17)

Fixes how `/g2g:build` scores a builder whose `BUILDER REPORT` never
arrives (#29). Phase 3 step 7 treated a missing marker as a FAILED attempt
and consulted the builder's commit only when a report had already arrived,
so a reporting failure — an API error mid-report, a killed process, harness
delivery latency — was scored as a work failure, and two of them blocked a
task whose correct commit was already on the branch.

### Changed
- `plugin/commands/build.md` — Phase 3 step 7 now defines when the marker
  is "never found" (the builder is FINISHED with no marker in any
  message), treats a block that is not USABLE — `result:` unreadable, or
  a DONE whose `commit:` does not resolve, the shape a message truncated
  inside the block produces — as a missing report rather than a FAILED
  attempt or a trusted DONE, and adds the NO-REPORT FALLBACK: compare HEAD to the baseline taken
  after the `chore(<task-id>): start` commit. Unchanged → FAILED as
  before. Moved → the orchestrator verifies the new commit against the
  task's acceptance criteria read-only, with real command output; every
  PASS scores DONE with `attempts` unchanged, while any FAIL, a criterion
  it cannot establish, a dirty tree, or HEAD/tree drift after the
  verification commands ran (the same drift the evidence script refuses
  a proven verdict on) scores FAILED and increments `attempts` as before.
  The fallback's tree exemptions are the goal/lock/mutex trio and the
  SURFACED-FOREIGN list only — never the spec, which step 5 committed
  before dispatch; preflight's freshly-generated-spec allowance does not
  carry into the fallback, so a verification command that rewrites
  criteria or flags is drift, not bookkeeping to commit. "Clean" covers
  staged, unstaged, and untracked paths alike. On drift the orchestrator
  repairs only the spec — index and working tree, from the dispatch
  baseline via `git restore --source=<baseline> --staged --worktree`,
  never `git checkout --` (which restores from the index) — on EVERY
  fallback outcome, including a builder commit that itself touched the
  spec and the HEAD-unchanged case, and touches nothing else; a commit
  made during verification is recorded, not undone.
  The cleanliness check names `git status --porcelain
  --untracked-files=all` explicitly, since a host's
  `status.showUntrackedFiles=no` would otherwise hide the very files it
  exists to catch.
- `plugin/commands/build.md` — every spec bookkeeping commit (steps 5 and
  8) is now explicitly limited to the spec path (`git commit ... --
  <spec-path>`, never `-a`), so a path some other writer staged cannot
  ride into the orchestrator's commit.
  Notes record the missing report, the sha, and
  per-criterion PASS/FAIL lines so a fallback DONE is auditable like a
  reported one.
- `plugin/commands/build.md` — step 8 names both routes into DONE and
  FAILED.
- `plugin/evals/build-orchestration-decisions/` — scenarios 5 through 11
  exercise the missing-report branch (HEAD moved / HEAD unchanged /
  verification passed but modified tracked files / verification staged a
  spec mutation / verification committed a spec mutation / the builder's
  own commit modified the spec / a block truncated right after
  `result: DONE`).

### Added
- `tests/commands.bats` — five tests pinning the fallback: the branch-tip
  check precedes FAILED, the baseline is post-start-commit (never a
  commit-message grep, which matches the orchestrator's own commit),
  uncertainty still scores toward failure with the orchestrator read-only,
  HEAD/tree are rechecked after the verification commands run, and repair
  is spec-only from the baseline with spec-only bookkeeping commits.

The Stop hook is unchanged: completion still requires a `VERIFIER REPORT`
PASS from a dispatched verifier, independent of per-task `passes`.


## 0.7.1 (2026-08-26)

Fixes the subagent-dispatch contract in `/g2g:build` (#19). The procedure
required dispatching builders and the verifier SYNCHRONOUSLY, which no
harness with an asynchronous Agent tool can honor. The orchestrator's turn
ended mid-build, the armed Stop hook correctly blocked, and the run spun —
burning a turn against `TURN_CAP` per cycle and filling the transcript with
`Condition not met:` blocks that read like failures.

### Changed
- `plugin/commands/build.md` — new `## BLOCKING WAIT` section states the
  real invariant (never end your turn while a subagent runs) and names the
  mechanism that achieves it on an async dispatch: arm a bounded watch on
  the branch tip, then hold the turn open with a blocking read on THAT
  watch, re-blocking if it times out. All four dispatch/wait steps cite it.
- `plugin/commands/build.md` — a subagent that dies before emitting its
  report marker is now explicitly the malformed/FAILED case, so an API
  error or killed process is one failed attempt rather than an abandoned
  run.

### Added
- `plugin/commands/build.md` — a hazard note: never block on, Read, or
  tail a subagent's own task id or output file. For a local agent that
  file is the full subagent JSONL transcript, and pulling it into the
  orchestrator overflows the context window and loses the build.
- `tests/commands.bats` — five tests pinning the corrected contract,
  including one asserting the stale `SYNCHRONOUSLY` claim cannot return.

The Stop hook is unchanged and was never at fault: it blocked precisely
because the goal was armed and unmet.


## 0.7.0 (2026-08-18)

Compound learnings store: a tracked `docs/learnings/` store with stable
`L-NNN` ids, a two-track (`bug` / `knowledge`) frontmatter schema, a
deterministic grounding validator, and a `/g2g:compound` command that
turns one completed build or one addressed finding into exactly one
grounded learning. `CLAUDE.md` now cites `L-NNN` ids for long-form
incident detail instead of carrying it inline, with every prohibition
and one-line rationale kept in place.

### Added
- `plugin/skills/writing-g2g-learnings/SKILL.md` — the CONTRACT for the
  learnings store: L-ID allocation, the two-track frontmatter schema,
  the body section template, the overlap rule, capture preconditions,
  and the five maintenance outcomes for a future refresh pass.
- `plugin/scripts/g2g-learning-check.sh` — the deterministic grounding
  validator for `docs/learnings/`: verifies frontmatter against the
  schema, that every cited path exists and every cited commit SHA
  resolves and is reachable from the upstream default branch, and that
  no drafting scaffold survived into the file. Exit 0 clean / 2
  invalid frontmatter / 3 no learning files found / 4 flags needing
  adjudication.
- `plugin/commands/compound.md` (`/g2g:compound [<spec-path>|F-NNN]`) —
  turns one verifier-`PASS` spec or one addressed finding into exactly
  one grounded learning, refusing rather than warning on an unsettled
  source. Joins the checkout-lock protocol (acquire/refresh/
  release-terminal), documented in `plugin/README.md`'s Concurrency
  model as a lock-holding command alongside `/g2g:build` and
  `/g2g:go`.
- `docs/learnings/` seeded with three learnings: L-001 (evidence
  head-binding, F-059), L-002 (bash 3.2 assert-enforcement canary,
  F-060), and L-003 (post-verifier-PASS spec amendment, F-061).

### Changed
- `CLAUDE.md` bullets that cite F-059, F-060, and F-061 now also cite
  the corresponding L-ID, and gained one pointer line naming
  `docs/learnings/` and `/g2g:compound`.
- `plugin/README.md` documents `/g2g:compound` in the Commands table
  and adds a "Compound learnings" section, plus item 8 in the
  Concurrency model section.

## 0.6.5 (2026-08-13)

Concurrency safety, phase 1 (F-065, F-066): every write-capable command
now honors the checkout lock, the lock helper gained a read-only
liveness query, the build's crash-stash no longer absorbs foreign
files, and the concurrency model is documented normatively. No new
isolation capability — safety only.

### Added
- `/g2g:go` now participates in the checkout-lock protocol (F-066,
  T-001): it acquires via `g2g-lock.sh acquire` before creating its
  branch, refreshes the heartbeat at phase boundaries (before
  verification, commit, and push), and releases with
  `release-preflight` on every terminal path reached after a
  successful acquire — never `release-terminal`, since `/g2g:go` arms
  no `.g2g-goal` and must never delete a foreign build's goal/lock
  pair. A live `/g2g:build` or another live `/g2g:go` makes a new
  `/g2g:go` abort with the helper's live-owner outcome.
- `plugin/scripts/g2g-lock.sh` gained a strictly non-mutating `status`
  subcommand (T-003): reports `no-lock` (exit 0), `live-owner` (exit
  4), or `stale-debris` (exit 9), with the owner token, heartbeat, and
  age where applicable, and never creates, refreshes, reclaims, or
  deletes the lock, goal, or mutex.
- `/g2g:spec`, `/g2g:review`, and `/g2g:dev` Phase A now query that
  `status` subcommand before writing (T-004): `/g2g:spec` and
  `/g2g:dev` Phase A warn prominently on a live owner and proceed
  anyway (each only ever writes a fresh file under its own slug);
  `/g2g:review` REFUSES outright on a live owner, since
  `review-output/findings.json` is produced by a read-modify-write
  merge against a moving baseline that two concurrent runs can never
  reconcile through a file lock — concurrent review remains
  unsupported by decision. All three report the owner and heartbeat,
  and treat stale debris as reportable rather than blocking.
- `plugin/README.md` gained a "Concurrency model" section (T-005): the
  single normative description of how builds serialize per checkout,
  why the lock is anchored to the enclosing worktree root (so separate
  worktrees are independent), why the supported way to run several
  builds at once is one worktree per build with a session started
  inside it (no new configuration — there is no `isolateBuilds` option
  and none is planned), how `/g2g:improve` already isolates every tick
  in its own worktree, and how `/g2g:go`, `/g2g:spec`/`/g2g:review`/
  `/g2g:dev` Phase A, and `/g2g:status` each participate. Command files
  gained additive pointer lines to that section — no existing
  procedural instruction was changed. `CLAUDE.md`'s plugin conventions
  gained a bullet requiring every new write-capable command to hold
  the lock or query it read-only before writing.

### Fixed
- `plugin/commands/build.md` Phase 3 step 3 (T-002) now states a
  probable-builder-debris predicate before stashing untracked or
  modified paths as `g2g-crash-<task-id>`: foreign untracked paths
  (e.g. a concurrent `/g2g:review`'s `findings.json` writes) are
  surfaced and carried as a remembered exclusion rather than stashed,
  foreign tracked modifications route to Phase 5 as a terminal partial
  instead of being silently absorbed, and genuine builder debris is
  still stashed exactly as before.

## 0.6.4 (2026-08-12)

Lock path anchoring (fixes F-064): the checkout-lock protocol now
agrees on a single anchor for the goal/lock/mutex trio regardless of
the working directory a build is started from.

### Fixed
- `plugin/scripts/g2g-lock.sh` gained `resolve_anchor()` — `git
  rev-parse --show-toplevel`, falling back to `$PWD` on any failure,
  empty output, or non-directory result — and the goal, lock, and
  mutex paths are now built from that anchor instead of the caller's
  `$PWD`. A build started from a repository subdirectory now sees the
  same lock as one started at the root, so a live owner is detected
  and the second build aborts as before; per-worktree independence,
  the CWD fallback outside any repository, and behavior when already
  at the worktree root are all unchanged.
- `plugin/scripts/g2g-stop.sh` gained a matching `resolve_anchor()`
  and now resolves the goal file, the ownership-lost lock read, and
  its head-binding `git -C` calls at that same anchor, so the Stop
  hook and the lock helper agree on where the goal lives no matter
  which subdirectory the session started from — closing a real gap:
  `CLAUDE_PROJECT_DIR`, `$(pwd)`, and the hook payload's `.cwd` were
  all confirmed to resolve to the session's starting subdirectory, not
  the worktree root. `plugin/commands/build.md`'s Phase 2 goal-write
  step now names the enclosing worktree root explicitly instead of the
  ambiguous "repo root". The hook's fail-open direction when
  resolution is uncertain is unchanged.
- `plugin/README.md`'s one-build-per-checkout passage and
  `CLAUDE.md`'s "The lock script is the protocol" convention now state
  the guarantee correctly: serialization is anchored to the enclosing
  worktree root and holds regardless of the caller's working
  directory, and is a per-worktree guarantee — separate worktrees
  remain independent by design, which is what allows concurrent builds
  and worktree-isolated improve ticks.

## 0.6.3 (2026-08-12)

Record-integrity follow-ups from PR #11's review cycle (F-061, F-063):
a spec-reconciliation convention for post-verifier branch changes, and
durable launch/ledger records for every nightly routine tick.

### Added
- Spec-reconciliation rule (fixes F-061): `build.md` now states, right
  after the verifier-PASS recording step, that any LATER commit on the
  build branch (adversarial-review fixes, human review feedback, other
  follow-ups) which changes behavior an acceptance criterion describes
  must, in the same change, amend that criterion to the as-shipped
  design and append an amendment note to the task's `notes` citing the
  superseding commit(s) — the spec's `verifier` field is never
  rewritten and stays the record of the original PASS. `CLAUDE.md`'s
  "Conventions for editing the plugin" section carries the same rule.
  `/g2g:status` gained a read-only step that flags specs whose branch
  has commits after the commit that recorded the verifier's PASS
  (never on the default branch, and never when that anchor commit or
  the default branch can't be determined), so a silent
  divergence like PR #11's (three criteria superseded by review fixes
  with no spec amendment) surfaces instead of requiring manual review.
- Launch records for every nightly routine tick (fixes F-063):
  `plugin/routines/improve-nightly.md` now retains a launch-plus-
  terminal (or synthesized) record for its own report on BOTH paths —
  the `/g2g:improve --wait` path (step 2), whose launch and terminal
  records land only in the ephemeral clone's journal and log, and the
  fallback path (step 3), which starts the capped improve-cycle child
  directly (skipping `improve.md`'s launcher-side "launched" journal
  write). Both paths retain their launch record before the child's
  outcome is known and synthesize a killed-or-crashed ledger entry
  when the child dies without printing a terminal entry — so a
  turn/budget kill before Cleanup no longer leaves zero record on
  either path in an ephemeral clone whose journal dies with it.

## 0.6.2 (2026-08-09)

### Added
- Per-tick ledger (fixes F-008): every `/g2g:improve-cycle` terminal
  path (success, empty, abort, partial) journals one entry
  (`{tickId, date, outcome, reason, pr, turns, selected, addressed}`)
  to a machine-local JSONL journal in the main checkout's git common
  dir — durable without touching the tracked tree, so failed and
  empty ticks are recorded, not just successes. Each PR-producing
  cycle's Phase I-5 reconciliation then folds unreconciled journal
  entries (matched by `tickId`) plus its own entry into the tracked
  `review-output/ticks.json`, inside the same single sanctioned
  reconciliation commit that marks findings `addressed`. `selected`
  and `addressed` are separate fields so partial work stays visible
  for budget tuning. `/g2g:status` gained a read-only step
  summarizing the tracked ledger's last 5 entries plus the count of
  journal entries awaiting reconciliation, reporting absence or a
  parse failure honestly otherwise. Documented in the README's
  improve/flywheel section.
- Eval hill-climb groundwork (fixes F-014): `plugin/evals/` grown to
  five area-tagged cases whose prompts exercise the shipped
  command/skill files (fixture data inline, behavioral contract read
  from disk — never a pasted copy of the rules), proportional graders
  pinned by `tests/plugin_evals.bats`; committed score ledger
  `plugin/evals/results.json` with per-run `scores` plus `commit` and
  `harness` fields so accept/reject/retest decisions can test gains
  against observed spread; sealed holdout convention places holdout
  cases outside the repository (in-repo cases are readable by any
  builder and cannot be sealed); the hill-climbing loop itself is
  documented in the README and operator runbook and stays inert until
  the eval harness is available.

## 0.6.1 (2026-08-09)

### Added
- Improve-scoped Console-key billing: when `G2G_IMPROVE_API_KEY` is
  set in the launching environment, `/g2g:improve` (and the nightly
  routine) spawn the headless tick with
  `ANTHROPIC_API_KEY="$G2G_IMPROVE_API_KEY"`, so the tick alone bills
  to that key while interactive sessions stay on the logged-in
  account. Precedence, reported as a `billing:` line at every launch:
  `G2G_IMPROVE_API_KEY` (improve-scoped) → inherited
  `ANTHROPIC_API_KEY` (native CLI behavior, now documented) →
  logged-in Claude Code account. The key value is only ever passed as
  a quoted variable expansion and is never printed. Documented across
  the surfaces an operator actually reads: README gains a "Billing"
  section under Running headless (linked from the improve-flywheel
  section), the operator runbook's "Run an improve tick" covers it,
  `/g2g:init`'s next-steps card names the optional setup, and the
  nightly routine template warns that cloud/scheduled environments
  (routines, managed agents, CI) have no logged-in account and need
  the key as an environment secret. Entirely optional and purely
  environmental — no key is ever written to any file the plugin
  manages.

## 0.6.0 (2026-08-08)

Closes the head-binding gap in completion evidence: a build could rebase
or otherwise move HEAD after the final `--full` evidence run, so the
`(proven)` token certified a commit the push had since moved past
(F-059).

### Changed
- `build.md` Phase 4 reorders steps 5-6: the branch now rebases onto the
  default branch BEFORE the final `--full` evidence run, not after, so
  the evidence step's `(proven)` verdict certifies the rebased tree that
  is actually pushed rather than a pre-rebase snapshot. Step 7 (push +
  `gh pr create` + release-terminal) is unchanged apart from following
  the reordered steps.
- `g2g-stop.sh`'s completion check, for a proven-armed session, now also
  extracts the paired evidence block's `head:` line — short HEAD plus
  tracked-dirty count, derived exactly as `g2g-evidence.sh` derives them
  — and compares it against current repository state; any mismatch or
  missing head line blocks the stop, naming the drift and the
  `g2g-evidence.sh <spec> --full` re-run remedy. This closes the window
  where a session could stop successfully on an evidence block whose
  certified HEAD no longer matches the tree actually on disk (F-059).
- `CLAUDE.md`'s evidence-output convention bullet and `plugin/README.md`
  / `docs/G2G_PLUGIN_REF.md`'s completion-evidence guardrail sections
  now name the head-line comparison alongside the verdict-line keying.

## 0.5.1 (2026-08-08)

### Fixed
- `g2g-evidence.sh` exits 2 (invalid spec) with a clear message when
  `.tasks` is missing, null, not an array, contains a non-object
  entry, or contains a task whose `id`/`title`/`status` is neither a
  string nor null (those fields are string-concatenated into the
  block). Previously the unguarded jq iteration died with an
  undocumented exit 5 and a cryptic stderr — for field-level cases
  after the header had already printed — so `/g2g:status` failed
  opaquely on a hand-written or partial spec (F-019; field-type gate
  added after Codex adversarial review). Null `title`/`status` were
  already rendered gracefully and are now pinned by a test.

### Added
- `make test` now resolves a bash whose errexit actually enforces
  failing `[[ ]]` asserts mid-test — macOS system bash 3.2 silently
  swallows them, so under it only each test's final assert counts and
  a bats green over-reports (F-060). Candidates: `G2G_BATS_BASH`,
  `bash` on PATH, then Homebrew/MacPorts locations. Enforcement is
  proven end-to-end each run by `tests/canary/enforcement.bats`, a
  deliberately failing mid-test assert that must report `not ok`. No
  enforcing bash is a hard failure with a named remedy (`brew install
  bash`) — a green that cannot enforce its asserts must never feed
  `make check`, this repo's build verificationCommand and completion
  evidence. CI (ubuntu) was never affected.

## 0.5.0 (2026-08-07)

Closes the failed-verify gap in completion evidence: a `--full` run
whose verification command failed could previously still read as
complete, because the Stop hook derived completion from the
always-present task-counts line rather than from verification results.

### Added
- `g2g-evidence.sh` now ends every block with exactly one graded,
  machine-stable `verdict:` line: `complete (proven)` only from a real
  `--full` run where every verification command exited 0 on an
  all-passed spec with `verifier: PASS`; `complete (assumed)` when the
  claim rests on spec bookkeeping alone (status mode never runs
  verification commands, so it can never earn `(proven)`); `incomplete`
  otherwise, naming the first failing fact (F-045, F-043).
- Pinned the F-043 12-task boundary: no per-task omission line at
  exactly 12 tasks, alongside the existing 13-task omission test.

### Changed
- `g2g-stop.sh`'s completion check now keys on the paired `--full`
  evidence block containing a line beginning `verdict: complete
  (proven)`, instead of re-deriving completion from the counts line and
  the `in_progress`/`pending`/`blocked` substrings. This closes the
  failed-verify gap: a failing verification command can no longer
  coexist with a passing completion check (F-045).
- `build.md` Phase 2 and `CLAUDE.md`'s evidence-output invariant updated
  to describe the verdict line instead of the summary line.

### Hardened (post-review, same release)
- `g2g-evidence.sh` validates `context.verificationCommands` as an array
  of non-empty single-line strings (exit 2 otherwise) — a malformed
  value previously skipped the verify loop silently and could earn
  `(proven)` without running anything — and `(proven)` additionally
  requires every declared command to have actually executed in this run.
- `g2g-evidence.sh` strips control characters from spec-controlled text
  (task ids/titles, verifier verdict) so it can never fabricate a
  verdict-shaped line inside the block.
- `g2g-stop.sh` accepts only a paired block with exactly one verdict
  line (conflicting verdicts are treated as forged), and pairs only a
  command that is exactly its own sibling `g2g-evidence.sh <spec>
  --full` invocation, anchored start to end — a second review round
  showed end-only anchoring was bypassable via a forging prefix plus a
  commented-out invocation, so chained prefixes, comments, and
  lookalike scripts at other paths now all fail to pair. The script and
  spec paths may be wrapped in matching single or double quotes
  (defensive quoting is legitimate and required for paths with spaces);
  mismatched quotes do not pair.
- `g2g-evidence.sh` forfeits `(proven)` when the repository head, the
  tracked-file state, or the spec's own completion facts changed while
  the verification commands ran — a command that rewrites state while
  exiting 0 can no longer have its post-run state blessed by the run
  that mutated it. The verdict names the drift. (A third review round;
  the wider design follow-up — binding the token to the final rebased
  HEAD with a hook-side comparison — is deferred and tracked for the
  review backlog.)
- Rewrote two `A && B || C` guards in `g2g-stop.sh` as explicit
  conditionals (shellcheck SC2015, flagged by CI).

### Verified
- `make check` passing, including the new 12-task boundary and
  verdict-grade tests.

## 0.4.1 (2026-08-03)

Escalates the Stop hook's block reason after repeated blocks. Real use
surfaced a gap: an unsatisfiable goal (missing spec, wedged build, or
one armed by hand for testing) made the hook repeat the same demand
until Claude Code's own consecutive-block cap overrode it.

### Changed
- The hook now counts its own prior blocks and, after three with no
  terminal state, keeps the specific diagnosis and adds the legitimate
  exits: finish Phase 5 (push, then release-terminal), or state the
  goal is unreachable and delete `.g2g-goal`.
- The count reads `stop_hook_summary` records, which the harness
  writes, so an assistant turn quoting an earlier reason cannot inflate
  it, and keying on `hookErrors` keeps other Stop hooks a session may
  have registered out of the count.
- `stop_hook_active` remains deliberately not honored as an allow
  signal — blocking is the mechanism that keeps an autonomous build
  running; the loop is already bounded externally by
  `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`.

### Verified
- `make check` 112/112; validated against a real transcript carrying 11
  blocks.

## 0.4.0 (2026-07-29)

Replaces the LLM-evaluated Stop hook with a deterministic script. The
prior hook asked one small model to do two jobs — a cheap precondition
check (did this session arm a goal?) and an expensive completion
check — and its safe-default branch inverted in a real session: the
evaluator reached the correct finding ("no goal was armed") and blocked
anyway.

### Changed
- `plugin/scripts/g2g-stop.sh` decides mechanically: arming and
  terminal state collapse to a `.g2g-goal` file test; provenance
  becomes a structural check that the evidence block sits in a
  tool_result paired by tool_use_id to a tool_use that actually ran
  `g2g-evidence.sh --full`, which a model cannot forge. Caps come from
  the goal file, and the wall-clock cap is computed by the hook itself.
- `.g2g-goal` is now JSON; `build-wf.md`'s duplicate completion prose is
  deleted in favor of deferring to `build.md`, so one schema and one
  hook serve both build paths.
- `/g2g:init` writes `extraKnownMarketplaces` + `enabledPlugins`
  declarations instead of copying `hooks.json`, and offers to remove
  legacy copied hooks — a vendored hook is one no plugin update can
  patch.
- The smoke gate now checks the protocol (terminal state reached,
  goal/lock/mutex cleaned up, branch pushed, nothing abandoned
  in_progress) instead of asserting `verifier.verdict == PASS`, which
  conflated "the plugin worked" with "the throwaway build wrote good
  code"; `SMOKE_REQUIRE_COMPLETE=1` restores the strict check. The
  sandbox `TURN_CAP` rises to 8 so the verifier → fix → re-verify loop
  is reachable; `tests/smoke.sh --assert-only <dir>` re-checks a
  preserved run with no API spend.

### Fixed
- The README's claim that plugin hooks "do not fire at all" under
  `--setting-sources project` was wrong — the plugin was not being
  loaded, since `enabledPlugins` lives in user settings, which that
  flag excludes.

### Verified
- `make check` 108/108; the hook replayed against a real smoke-build
  transcript; two live headless builds, in one of which the hook
  correctly caught an interrupted verifier dispatch and forced the
  build to a clean terminal state instead of stopping mid-flight.

## 0.3.1 (2026-07-27)

First live run of `/g2g:build-wf` (controlled sandbox test) caught two
workflow-runtime contract violations in the shipped script — exactly
the offline-unverifiable API surface its authoring notes flagged.

### Fixed
- `g2g-build.js` called `Date.now()` (start time, `elapsedMs`, the
  HOURS_CAP deadline check) — the dynamic-workflow runtime bans it
  (breaks resume) and throws at invocation. The script now never reads
  a clock itself: the turnkeeper agent reports `date +%s` each turn
  (a tool result, deterministic on replay), and cap checks use the
  last keeper reading — at most one turn stale, negligible against an
  hours-scale cap.
- `meta.description` was built by string concatenation; the runtime
  requires `meta` to be a pure literal.
- New test pin: no workflow script may call `Date.now()`,
  `Math.random()`, or argless `new Date()`.
- Docs: headless `/g2g:build-wf` runs need `Workflow` in
  `--allowedTools` (the documented flag set predates the command) and
  more outer `--max-turns` headroom than `/g2g:build` (48 observed on
  the 2-task sandbox vs smoke's 40; start at 60).

### Verified live (controlled sandbox tests)
- Full pass: workflow-driven loop → verifier PASS → Stop gate cleared
  → goal/lock released → branch pushed (48 turns, ~$4.2).
- Forced cap-hit (TURN_CAP=2): exactly one builder dispatched,
  `cap-turns` returned, wrapper routed to the partial path, and the
  0.2.7 Phase 5 ordering held under a real `gh pr create` failure —
  release-terminal still ran on the failure path (22 turns, ~$1.9).

## 0.3.0 (2026-07-27)

Architecture: the build task loop can now run on the native
dynamic-workflow runtime. Also carries the completion-gate hardening
and housekeeping authored alongside it.

### Added
- `/g2g:build-wf` (experimental): the `/g2g:build` build with its task
  loop executed by `plugin/workflows/g2g-build.js` (the `g2g:build-loop`
  workflow) — dependency-ordered selection, TURN_CAP/HOURS_CAP
  enforcement, builder-report handling, attempts/blocked bookkeeping,
  and the per-turn heartbeat refresh + tree check all enforced in code
  instead of per-turn orchestrator discipline. Requires Claude Code
  >= 2.1.154 with dynamic workflows enabled; refuses (pointing at
  `/g2g:build`) where the runtime is unavailable.
- Structural tests pinning the workflow contracts (script parses as an
  ES module, meta name agrees with the wrapper, builder schema fields
  agree with the agent definition, P1 verifier-gate semantics kept).
- This changelog.

### Changed
- The armed goal condition additionally requires a VERIFIER REPORT
  block delivered as real Agent tool output — completion can no longer
  be reached by spec edits alone.
- Evidence blocks carry a `head:` line binding them to a commit and
  tracked-dirty count.
- The Stop-hook evaluator is now asymmetric: bystander uncertainty
  (about arming) stays fail-open; the arming session's uncertainty
  (about the condition) fails closed. (The patch's switch of the hook
  model pin to the `haiku` alias was reverted before landing: the
  hook evaluator API rejects aliases, which would silently degrade
  the completion gate to an error-and-continue.)
- Phase 4 verifier dispatch is preceded by a heartbeat refresh.
- Template `models.builder` stays `"sonnet"` (0.2.7's cost
  alignment), now pinned by tests alongside the `artifactPaths`
  absence.

### Fixed
- `g2g-lock.sh`: a stat TOCTOU under mutex contention could crash a
  locker with an unclassified exit (`set -u` on GNU `stat -f` output);
  mtimes are now validated numerically.
- Housekeeping: templates/`.claude/g2g.json` drop the unconsumed
  `artifactPaths`; `verify-starter.sh` shellchecked; stale issue/spike
  references removed; `/g2g:init` discloses the hook's standing cost;
  marketplace metadata added to `plugin.json`.

### Unchanged by design
- `/g2g:build` remains the stable engine; the verifier gate (subagent-
  delivered VERIFIER REPORT required), checkout lock, evidence script,
  PR ceremony, and all safety guardrails are shared by both engines.

## 0.2.7 (2026-07-27)

First improve-flywheel release: fixes selected, built, and
adversarially reviewed by the plugin's own improve cycle (PR #3).

### Changed
- Phase 5 (terminal stop) holds checkout ownership through the push:
  refresh-ownership → push/PR → release-terminal on both outcomes;
  nonzero refresh routes to the non-mutating OWNERSHIP LOST path.
- `models.improveCycle` routes the entire spawned improve tick; it
  rejects `inherit` at both spawn sites (a separate headless process
  has no session to inherit from) and validates the value against a
  strict token allowlist before it reaches the spawn command line,
  passed only as a quoted variable.
- `defaultBudgets.improveTurns` default guidance raised to 70 from
  live tick data (the review vet step costs turns).

## 0.2.6 (2026-07-24)

Review-quality mechanisms adopted from advisor-skill patterns: an
orchestrator vet step (cited code read before a finding gets an id),
`confidence` on findings with a low-confidence candidacy gate,
`rejected-<date>` persistence for false positives, and
effort-tiebroken selection.

## 0.2.5 and earlier

See git history.
