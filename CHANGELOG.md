# Changelog

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
