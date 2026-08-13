# g2g — Native G2G Plugin

A native Claude Code plugin for goal-driven autonomous builds:
fresh-context builder subagents, independent adversarial verification,
and deterministic completion evidence produced by a real script run —
never a self-reported completion marker.

## Install

```
/plugin marketplace add <this-repo-path-or-url>
/plugin install g2g@g2g
```

## New repo quickstart

New to the plugin in a fresh repo? Three steps:

1. Install (above).
2. `/g2g:init` — interactive onboarding: detects your stack, confirms
   the verification suite, and writes `.claude/g2g.json` plus safety
   plumbing (every write confirmed first; nothing outside `.claude/`
   except an optional, confirmed `verify.sh` on the greenfield path;
   never commits).
3. `/g2g:dev "first feature"` — generate a spec, then build it.

## Commands

| Command | Description |
|---|---|
| `/g2g:init` | Interactive onboarding for a new repo: detect the stack, confirm the verification suite, write `.claude/g2g.json` and safety plumbing (never commits) |
| `/g2g:go "<task>" [--pr]` | One-off task: branch-first, implement, verify, commit; `--pr` opens a PR |
| `/g2g:build <spec.json> [--continue-branch]` | Goal-driven build from a spec: fresh builder per task, verifier-gated PR; `--continue-branch` resumes an existing `g2g/*` branch |
| `/g2g:build-wf <spec.json> [--continue-branch]` | Experimental: same build with the task loop on the dynamic-workflow runtime — caps, sequencing, and report handling enforced in code (requires Claude Code >= 2.1.154 with workflows enabled) |
| `/g2g:status` | Read-only dashboard: active goal, spec progress, open `g2g/*` PRs, worktrees |
| `/g2g:spec "<prompt>" \| -f <file> \| --from-findings [path]` | Generate a validated spec JSON in `specs/` (no commit — review, then build) |
| `/g2g:dev "<prompt>" [--review]` | Full pipeline: generate spec → build it; `--review` pauses for spec approval |
| `/g2g:review [--diff-base <ref>] [--full] [--focus <cats>] [--target <path>]` | Read-only codebase review — parallel category subagents merged into the tracked findings backlog |
| `/g2g:improve [--wait]` | One bounded improve tick: headless review → fix-spec → build → PR in a fresh worktree; `--wait` blocks until done |
| `/g2g:improve-cycle` | Internal — the unit of work `/g2g:improve` spawns; refuses to run outside a `g2g/improve-*` worktree |

## The workflow-backed build loop (experimental)

`/g2g:build-wf` runs the same build as `/g2g:build` with the task loop
moved onto the native dynamic-workflow runtime
(`plugin/workflows/g2g-build.js`, invoked as the `g2g:build-loop`
workflow). What changes and what doesn't:

- **In code instead of prose:** dependency-ordered task selection,
  TURN_CAP/HOURS_CAP enforcement (counters and a deadline, not a
  `G2G TURN` transcript line an evaluator must spot), builder-report
  handling (schema-validated structured output instead of marker-block
  seeking), `attempts >= 2 -> blocked` bookkeeping, and the per-turn
  heartbeat refresh + tree check (a scripted step no phase can skip).
- **Unchanged:** preflight and the checkout lock, the `.g2g-goal`
  Stop-hook gate (the goal file and the hook are identical on both build
  paths since 0.4.0 — the hook reads fields, so there is no
  workflow-specific condition to write; the turn-cap clause simply never
  fires here because the workflow prints no turn lines), the adversarial
  verifier gate and REVERIFY_CAP, spec state committed on every
  transition (so `--continue-branch` and human inspection work
  identically), single push at PR time, draft partial PRs, never merges.
- **Builders read their contract from `agents/g2g-builder.md` at
  runtime** — the rules live in one place and cannot drift between the
  two engines.

Requirements: Claude Code >= 2.1.154 with dynamic workflows enabled
(`disableWorkflows` unset). Headless runs must add `Workflow` to the
invocation's `--allowedTools` (the "Running headless" flag set predates
this command) and need MORE outer `--max-turns` headroom than
`/g2g:build` — the controlled sandbox run (2 tasks) used 48 outer
turns where `/g2g:build`'s smoke fits in 40; start at 60 and size up
with task count. Where the runtime is unavailable the command
refuses and points at `/g2g:build`, which remains the stable engine.
Until the workflow path has accumulated the same live mileage, treat it
as experimental: run `make smoke` against it before relying on it
unattended.

## Spec generation & the dev pipeline

`/g2g:spec` writes `specs/<slug>.json` from one input source — inline
text, `-f <requirements-file>`, or `--from-findings [findings.json]`
(fix-spec from a review backlog; default path
`review-output/findings.json`). Every generated spec is validated with
the plugin's evidence script before the command reports success, and
`context.verificationCommands` is sourced from `.claude/g2g.json` or
the repo's documented test commands — if neither exists the command
aborts rather than emit an unbuildable spec. The spec is left
uncommitted for human review; `/g2g:build`'s preflight commits a fresh
spec as the first commit on its `g2g/*` work branch (and refuses
gitignored specs — see Artifact tracking below).

`/g2g:dev` chains the two: spec generation, an optional `--review`
pause for human approval, then the full build engine. Headless example
(same flag requirements as the build invocation below):

    claude -p "/g2g:dev Add feature X" \
      --plugin-dir /path/to/g2g/plugin \
      --permission-mode acceptEdits \
      --allowedTools "Agent,Bash,Read,Write,Edit,Glob,Grep" \
      --setting-sources project \
      --max-turns 40 \
      --max-budget-usd 20

Do not pass `--review` headlessly — with no one to approve, the session
ends after spec generation (safe, but probably not what you wanted).

The spec-writing guidance ships as a plugin skill
(`plugin/skills/writing-g2g-specs/`), which both commands follow.

## Review & the improve flywheel

> Operator runbook — running, watching, recovering, and tuning the
> flywheel: [docs/G2G_PLUGIN_REF.md](../docs/G2G_PLUGIN_REF.md).
> Ticks bill to your logged-in account unless you opt in to a
> Console key — see [Billing](#billing-which-credentials-a-headless-run-uses).

`/g2g:review` writes `review-output/findings.json` (the tracked
backlog; schema in `plugin/skills/reviewing-codebase/`) and a
regenerated `REVIEW_REPORT.md`, never committing. New subagent findings
are vetted by the orchestrator (cited code read and confirmed) before
they get an id. Each finding carries a `confidence` level (`low` means
investigate, never auto-fix) and `addressed`: `null` while open, the
fix PR's number once an improve cycle delivers one, `stale-<date>` when
revalidation finds it already fixed, or `rejected-<date>` when vetting
shows it was a false positive (kept in the backlog so it is never
re-reported).

`/g2g:improve` runs one bounded cycle — review → select top-N open
findings (default 3, `defaultBudgets.improveFindings`) → fix-spec →
mini-build → PR — always headless in a fresh, unpredictable, owner-only
`mktemp -d` run root (`/tmp/g2g-improve-<random>/worktree`, mode 0700)
on a `g2g/improve-<random>` branch, never in your checkout. Caps
come from `defaultBudgets.improveTurns`/`improveUsd` (50 / $25
defaults). A tick skips itself if a previous tick is running or its PR
is still open; a crashed tick is surfaced for human inspection, never
auto-deleted. The backlog update marking findings `addressed` is
committed and pushed into the same open PR as a single documented
follow-up commit — the one exception to single-push.

Every tick — including empty cycles, aborts, no-PR partials, and
ticks killed by the outer cap — is durably recorded on the launching
machine. Two writers cover the two failure geometries: the LAUNCHER
appends a `launched` record (with pid and run root) at spawn time,
from outside the capped child process — so a tick the outer
`--max-turns`/`--max-budget-usd` guillotine kills before its own
Cleanup runs still leaves a trace, and reconciliation folds
launched-but-dead ticks as `killed-or-crashed`; the tick's Cleanup
appends the terminal record on every terminal path. Both write
JSON-line entries to a machine-local journal in the main checkout's
git common dir (`$(git rev-parse --git-common-dir)/g2g-ticks.jsonl` —
shared across worktrees, survives worktree removal, never tracked).
One honest limitation: an ephemeral fresh-clone environment (a
scheduled cloud routine, CI) destroys its journal with the clone, so
a no-PR tick there has no journal to fall back on — the nightly
routine template covers this itself: before starting the capped
child it prints its own `launched` record into the routine's run
report (the durable output that survives the clone), then in that
same report either quotes the child's terminal ledger entry verbatim
or, when the child exits without printing one (a `--max-turns`/
`--max-budget-usd` cap kill or a crash), synthesizes and prints a
`killed-or-crashed` entry naming the exit status — so every scheduled
tick leaves a launch-plus-terminal (or synthesized) record without
needing a PR.
Each entry: `{"tickId": "<run id>", "date": "<YYYY-MM-DD>",
"outcome": "<terminal state>", "reason": "<why it ended that way>",
"pr": <PR number or null>, "turns": <the tick's turn count>,
"selected": [<finding ids selected>], "addressed": [<ids actually
marked addressed — subset of selected>]}`. `selected` and `addressed`
are separate fields so failed and partial work stays visible — a
ledger of successes only would systematically hide the costly ticks
budget tuning needs to see. Each PR-producing cycle then reconciles
the journal into the tracked ledger `review-output/ticks.json` (a JSON
array, created on first use) inside its SAME single reconciliation
commit — never a separate commit or push: it folds in every journal
entry whose `tickId` the tracked ledger lacks, then appends its own
entry. A tracked ledger that exists but no longer parses as a JSON
array is never overwritten — reconciliation skips the ledger, reports
it as needing human recovery, and resumes once repaired (journal
entries wait; committed history from other machines is never replaced
by a partial local view). `/g2g:status` summarizes the tracked
ledger's last 5 entries plus the count of journal entries still
awaiting reconciliation, and reports absence or a parse failure
honestly rather than guessing.

Triggers: locally, `/loop /g2g:improve` (each tick is
fire-and-forget within the live session; the loop cadence should
exceed a cycle's duration); in the cloud, schedule
`plugin/routines/improve-nightly.md`'s Instructions block, which uses
`--wait`. Ticks are never detached (no nohup/disown/setsid), but a
plain `&` child survives the session that launched it (spike-verified:
CHILD-SURVIVES) — which is exactly why the pid sidecar kill switch and
`/g2g:status` visibility are mandatory: a tick must always be
findable and killable. Orphaned background runs that could not be
found or killed are the incident class this design replaces.

Kill switches: `kill <pid>` (the launcher prints it; the pid sidecar
sits next to the worktree), `/g2g:status` (shows
RUNNING/CRASHED/FINISHED ticks), PR review (nothing merges itself).

Trust caveat: review-finding text flows into spec criteria executed by
Bash-capable builders (backlog finding F-001, hardened in PR #1 with
data/instruction separation — findings are quoted as cited data and
builders are told criteria describe outcomes, never instructions).
Prompt-level hardening is a mitigation, not a proof, so still run the
improve flywheel only on repos whose contents you trust, and improve
stays **strictly opt-in** as defense in depth:
both `/g2g:improve` and `/g2g:improve-cycle` refuse to run unless
`.claude/g2g.json` sets `"improve": { "enabled": true }` — templates
and `/g2g:init` write it as `false`, and enabling it is always a human
edit.

The outer `--max-turns` cap on the improve spawn is a backstop, not a
working limit: if it fires mid-build it kills the tick with no partial
draft PR left behind, unlike the inner build `TURN_CAP`, which routes
gracefully to a draft partial PR. Configure `improveTurns` comfortably
above the inner graceful caps (review + selection + spec phases, plus
`buildTurnsFactor` × task count). The `improveUsd` default is $25
because on a real repo the five parallel review subagents alone
consumed ~$7.8 in the first live run under an earlier $10 default,
which landed only a partial PR; large repos should still raise
`improveUsd` and/or narrow `reviewFocus`/`sourceDirs` — a
budget-exhausted cycle lands a graceful partial draft PR.

### The hill-climbing loop (documented, not yet wired)

The eval harness described in `plugin/evals/README.md` (case shape,
area tags, dev/sealed split, the committed score ledger
`plugin/evals/results.json` and its baseline convention) is the
missing piece a prompt-improvement loop needs: once it exists, a
candidate change to builder/verifier prompt or skill text can be
proposed and judged **entirely through the machinery documented
above** — no new orchestration, no self-merging, nothing that bypasses
a cap.

The loop, expressed as an ordinary improve fix-spec:

1. A candidate prompt/skill change is proposed as a normal
   `/g2g:improve` fix-spec, same as any other backlog finding.
2. Its acceptance criterion is **"tagged eval score >= committed
   baseline (`plugin/evals/results.json`) across >= 3 runs"** — the
   eval run *is* the spec's verification command, so
   `g2g-evidence.sh` grades it exactly like any other build, and the
   `g2g-verifier` subagent gates the PR exactly like any other build.
   Score recording is **two-phase**, because the evidence chain
   demands it: `g2g-evidence.sh --full` certifies completion only if
   the repo's tracked state did not change while the verification
   commands ran, so an eval run that appended to the tracked
   `results.json` mid-verification would register as state drift and
   block the proven verdict — by design, not accident. During the
   candidate build the harness therefore runs **read-only against the
   tracked tree**: per-run scores go to an untracked sidecar (the
   run's `$RUNDIR`, or the git-common-dir journal pattern the tick
   ledger uses), where the verifier and the human can read them.
3. The human reviewing the PR performs the final selection: merge,
   request changes, or close. Nothing merges itself; the guardrails in
   [Guardrails](#guardrails) (PR-gated, caps everywhere, opt-in
   `improve.enabled`) apply unchanged — this is a build whose
   verification command happens to be an eval, not a new code path.
   **Accepting a candidate is what writes the ledger**: at the merge
   gate the human appends the measured entry (per-run `scores`, the
   candidate `commit` it measured, `harness`, `model`) to
   `plugin/evals/results.json` in a separate, explicitly authorized
   append-only commit — never inside the candidate's own diff. This
   append-only recording of a measurement is the ONE sanctioned
   exception to optimizer/metric separation below; everything else
   under `plugin/evals/` stays human-initiated and out of any
   candidate diff.

This is **inert today**: the eval harness that would actually run
cases and produce a score is early access and not wired into this
repo (`plugin/evals/README.md`), so no fix-spec can satisfy the
acceptance criterion above until it lands. There is also a
generational boundary to respect once it does: a merged prompt
improvement changes files on disk, but a tick already in flight has
already loaded its prompts for that run — the improvement only takes
effect for ticks started after the plugin version bump that ships it
(see `plugin/.claude-plugin/plugin.json`'s `version` field), never
retroactively for the run that produced it.

Four rules govern how a candidate is judged, distilled from
karpathy/autoresearch's recon on prompt hill-climbing:

- **Regression floor first, objective second.** The suite's primary
  job is catching regressions, not chasing gains. A claimed
  improvement must exceed the *observed spread* across the required
  >= 3 runs — noise between runs at the same prompt is not a signal.
  Score every candidate into exactly one of three verdicts —
  **accept**, **reject**, or **retest with more runs** (when the gain
  is within the observed spread and neither clearly holds nor clearly
  fails) — never a bare greedy "score went up, accept."
- **The simplicity asymmetry.** Equal score with less prose is an
  accept. An epsilon gain that adds substantial prose is a reject.
  Prompt hill-climbing's dominant failure mode is monotonic bloat —
  every accepted change adding a caveat, a reminder, an extra
  paragraph — so a tie-breaker that favors brevity is load-bearing,
  not optional politeness.
- **Optimizer/metric separation.** A single candidate never changes
  both `plugin/evals/` and command/skill prose in the same fix-spec —
  changing the ruler and the thing it measures together is how a loop
  learns to satisfy its own grader instead of actually improving.
  Eval-suite changes (new cases, reworded graders, dev/sealed
  reclassification) are always human-initiated, never proposed by the
  loop itself. The single exception is the merge-gate score recording
  from step 3 above: an **append-only** `results.json` entry that
  records a measurement (never edits or removes prior entries, never
  touches cases or graders), made by the human in its own commit
  referencing the measured candidate commit.
- **Target-surface split.** The human-edited layer —
  `plugin/commands/build.md`, `plugin/commands/improve-cycle.md`, the
  Stop hook (`plugin/scripts/g2g-stop.sh`), and the evidence/lock
  scripts (`plugin/scripts/g2g-evidence.sh`,
  `plugin/scripts/g2g-lock.sh`) — is out of the loop's target surface
  entirely; per CLAUDE.md these are frozen contracts and orchestration
  prose, not tunable parameters. The loop's candidates target only the
  narrower builder/verifier prompt and skill surface (agent
  definitions in `plugin/agents/`, skill text in `plugin/skills/`).
  Sealed holdout cases (`plugin/evals/README.md`'s dev/sealed split)
  live **outside the repository** in an operator-owned store and are
  run only by the human at the merge gate. Location is the boundary,
  not prose: anything committed under `plugin/evals/` is readable by
  every builder, so an in-repo case can never be sealed — a candidate
  could read the exact prompt and grader it will be judged on, which
  is precisely the overfitting the holdout exists to catch.

## Config

Optional `.claude/g2g.json` in the host repo (see [`.claude/g2g.json`](../.claude/g2g.json) here for an example). Field status below — `verificationCommands`, `defaultBudgets`, `reviewFocus`, `sourceDirs`, and `models` are all live:

- `verificationCommands` — **live now**: `/g2g:go` reads this to verify a one-off task, if the file exists and defines it (falls back to the repo's documented test/lint commands otherwise). `/g2g:spec` (and therefore `/g2g:dev`, which chains it) also reads this field as the priority source for a generated spec's `context.verificationCommands`, before falling back to the repo's documented test commands. **Not** read by `/g2g:build` — that command sources its verification commands from the spec's `context.verificationCommands` instead (already populated by `/g2g:spec` from this field, if present), see Spec format below.
- `defaultBudgets` — **live now**: `buildTurnsFactor`/`buildHours` set `/g2g:build`'s TURN_CAP factor and wall-clock cap (defaults 2 / 2h); `improveTurns`/`improveUsd` cap the improve spawn (defaults 50 / $25); `improveFindings` sets findings-per-cycle (default 3). `improveHours` is documented-only: no wall-clock CLI flag exists, the turn cap approximates it.
- `improve.enabled` — **live now**: hard opt-in gate for the improve flywheel (see Trust caveat above). Defaults to `false` in every template; `/g2g:improve` and `/g2g:improve-cycle` refuse to run unless it is exactly `true`.
- `reviewFocus` — **live now**: the categories `/g2g:review` fans out across when `--focus` isn't given.
- `sourceDirs` — **live now**: the default review targets when `--target` isn't given.
- `models` — **live now** for `builder`, `verifier`, and `improveCycle`: `/g2g:build` dispatches builder subagents with `models.builder` (falls back to `sonnet` when the field is absent — tasks are pre-decomposed with explicit criteria, a Sonnet-shaped job; every shipped template sets `builder: "sonnet"` explicitly, matching this default) and the verifier with `models.verifier` (default `inherit` — adversarial judgment stays on the session model). `"inherit"` means use the invoking session's model. `models.improveCycle` (default `sonnet`) is passed as `--model` on the `claude -p` process the `/g2g:improve` launcher (and the nightly routine) spawns — it does not support `inherit`, and both spawn sites fail the launch on it: a separate headless process has no session to inherit from (unlike `models.verifier`, a subagent dispatch inside the session, where inheritance is real), and omitting the flag would silently select the machine's CLI default; set an explicit model or omit the field for the `sonnet` default. The value crosses into the spawn command line, so both spawn sites validate it against a strict token pattern (`^[A-Za-z0-9][A-Za-z0-9._-]*$`) and pass it only as a quoted variable — anything else fails the launch rather than being interpolated — it routes the *entire* headless cycle (orchestrator, parallel review subagents, spec generation, and any builder/verifier dispatch inside it that doesn't set its own model), separately from the per-dispatch `models.builder`/`models.verifier` fields above. `models.go` is not read: `/g2g:go` hardcodes `model: sonnet` in its frontmatter (go.md); `/g2g:status` likewise pins `haiku`.
- Artifact locations are fixed at `specs/` and `review-output/` in v1. (An `artifactPaths` override was previously documented as reserved; it has been dropped from the templates until a command actually reads it — a config field with no consumer only invites misconfiguration.)

## Spec format

Specs use the `tasks[]` schema (see [`specs/example.json`](../specs/example.json)):
`id`, `title`, `description`, `acceptanceCriteria`, `dependsOn`, `status`,
`passes`, `effort`, `notes`. A top-level `context` block is also part of
the schema:

- **`context.verificationCommands`** (array of strings) — **required for
  `/g2g:build`**: the commands it runs to verify the build. Read by
  `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-evidence.sh` directly from the
  spec (build.md Phase 1 step 5), which exits 3 and aborts the build if
  this is missing or empty — no independent verification, no evidence
  chain. This is a field on the spec JSON itself, distinct from
  `.claude/g2g.json`'s `verificationCommands` field above, which
  `/g2g:build` never reads.

`/g2g:build` also reads and writes two more fields not covered
elsewhere:

- **`attempts`** (per task, integer) — orchestrator-managed retry
  counter; a task moves to `status: blocked` once `attempts` reaches 2
  without a `DONE` builder report.
- **`verifier`** (top-level, `{verdict, date, summary}`) — written once
  the `g2g-verifier` subagent returns `PASS` at completion; absent (or
  `null` in `specs/example.json`, which was never built) until then.

## Artifact tracking

`specs/*.json` and `review-output/findings.json` must be **git-tracked**,
not gitignored — worktrees and fresh clones only materialize tracked
files, so an ignored spec or backlog silently vanishes exactly where
headless builds run. If a host repo's `.gitignore` covers them, drop
those ignore rules and commit the existing files once (`/g2g:init`'s
artifact-tracking check reports the exact rules to remove).

This repo tracks `specs/`, `review-output/`, and
`.claude/settings.json` for that reason.

## Concurrency model

This section is the single normative description of how g2g serializes
writes to a checkout. Command files (`build.md`, `go.md`, `spec.md`,
`review.md`, `dev.md`) point back here rather than restating it; if you
change the model, change it here first.

1. **Builds serialize per checkout by design.** `/g2g:build` acquires
   `.g2g-goal.lock` via `plugin/scripts/g2g-lock.sh acquire` before
   Phase 1 does anything else, and holds it until a terminal state
   releases it. If a second `/g2g:build` (or a `/g2g:go`, see 5 below)
   targets the same checkout while one is already live, `acquire`
   returns the helper's live-owner outcome (exit 4) and the second run
   aborts immediately, reporting the live owner and heartbeat. This is
   the protocol working as designed, not a bug or a race to retry past.
2. **The lock is anchored to the enclosing worktree root, not the
   caller's working directory** (PR #14, F-064): `g2g-lock.sh` resolves
   `git rev-parse --show-toplevel` (falling back to `$PWD` outside any
   repository) and builds the `.g2g-goal` / `.g2g-goal.lock` /
   `.g2g-goal.mutex` trio from that anchor. Serialization holds no
   matter which subdirectory a session was started from — so separate
   **worktrees** of the same repository each have their own lock and
   never contend with one another.
3. **The supported way to run several builds at once is therefore one
   worktree per build, with a session started inside it** — e.g.
   `git worktree add ../myrepo-taskA <branch>`, then a separate Claude
   Code session whose cwd is inside that worktree, running
   `/g2g:build` there. This needs **no new configuration**: there is no
   `isolateBuilds` setting or equivalent, and none is planned. The
   pattern is entirely operator-created worktrees plus the ordinary
   lock behavior in 1–2 above; each worktree just happens to be its own
   serialization domain.
4. `/g2g:improve` already isolates every tick this way, automatically:
   each tick gets its own unpredictable `mktemp -d` worktree (see
   [Review & the improve flywheel](#review--the-improve-flywheel)), so
   improve ticks never contend with each other or with an interactive
   build running in the main checkout.
5. `/g2g:go` participates in the same lock as `/g2g:build` (F-066): it
   acquires before creating its branch, refreshes the heartbeat at
   phase boundaries, and releases with `release-preflight` — never
   `release-terminal`, since `/g2g:go` arms no `.g2g-goal` and must
   never delete a foreign build's goal/lock pair. A live `/g2g:build`
   or another live `/g2g:go` in the same checkout makes a new
   `/g2g:go` abort with the same live-owner outcome as 1.
6. `/g2g:spec`, `/g2g:review`, and `/g2g:dev` Phase A query the lock
   **read-only** before writing, via `g2g-lock.sh status` (F-065) — a
   strictly non-mutating check that never creates, refreshes, reclaims,
   or deletes the lock, goal, or mutex, and reports `no-lock`,
   `live-owner`, or `stale-debris` (plus owner token, heartbeat, and
   age where applicable). `/g2g:spec` and `/g2g:dev` Phase A warn
   prominently on a live owner and proceed anyway — each only ever
   writes a fresh file under its own new slug, so it cannot corrupt
   another build's in-flight artifacts. `/g2g:review` **refuses**
   outright on a live owner: `review-output/findings.json` is produced
   by a read-modify-write merge against a moving baseline (every open
   finding is revalidated), which two concurrent runs can never
   reconcile through a file lock — concurrent review is unsupported by
   decision, and this refusal is how that decision is enforced.
7. `/g2g:status` is read-only and always safe to run concurrently with
   anything — it never touches the lock, the goal file, or any tracked
   artifact.

**Not supported, and not planned:** concurrent builds within a single
checkout (behavior 1 above is exactly what prevents this); an
`isolateBuilds` configuration option or anything like it (behavior 3's
worktree pattern needs none); and any serialized or lock-protected
merge of `review-output/findings.json` across concurrent `/g2g:review`
runs (behavior 6's refusal is the whole mitigation — there is no merge
algorithm backing it).

## Guardrails

- **PR-gated, branch-first, never merges** — every writing command
  refuses the default branch; only `g2g/*` branches are ever pushed, and
  only at PR time.
- **Graded completion evidence** — every `g2g-evidence.sh` run ends its
  block with exactly one machine-stable `verdict:` line naming its
  grade: `complete (proven)` only from a real `--full` run in which
  every verification command exited 0 on an all-passed spec with
  `verifier: PASS`, with the repository head, tracked-file state, and
  the spec's completion facts unchanged across the run (a verification
  command that mutates state forfeits the grade); `complete (assumed)`
  when the claim rests on spec
  bookkeeping alone (status mode, which never runs verification
  commands and so can never earn `(proven)`); `incomplete` otherwise,
  naming the first failing fact. The Stop hook's completion check keys
  on this token: it requires the transcript's evidence block — the one
  it can pair by tool-use id to a command that is exactly the plugin's
  own evidence-script `--full` invocation, start to end, nothing
  chained before or after it — to carry exactly one verdict line,
  reading `verdict: complete (proven)`; a block with more than one
  verdict line is treated as forged. A failing verification
  command in that run makes the token unreachable, so it can never
  coexist with a passing completion check. For a proven-armed session,
  the hook additionally re-derives the short HEAD and tracked-dirty
  state exactly as the evidence script derives them and compares that
  against the paired block's `head:` line; any mismatch or missing
  head line blocks the stop, naming the drift and the
  `g2g-evidence.sh <spec> --full` re-run remedy (F-059) — this is what
  lets Phase 4 rebase onto the default branch before running the final
  evidence, so the proven token certifies the tree that is actually
  pushed rather than a pre-rebase snapshot.
- **Caps everywhere** — every goal carries turn and wall-clock caps as
  data the Stop hook enforces itself; headless spawns add a dollar cap.
  There is no unlimited mode. The wall-clock cap is computed from the
  goal's `buildStart` and needs nothing from the transcript, so it holds
  even if everything else about a run has gone wrong.
- **POSIX shell required** — the evidence script needs `bash`; pure
  Windows without git-bash/WSL is unsupported in v1.
- **`.g2g-goal` and `.g2g-goal.lock`** are ephemeral, gitignored runtime
  files that `/g2g:build` writes and deletes itself — hosts should
  gitignore both and never commit them. The lock (plus its transient
  `.g2g-goal.mutex/` directory, gitignored the same way) is managed
  exclusively by `plugin/scripts/g2g-lock.sh`, the executable,
  behaviorally-tested implementation of the checkout-lock protocol:
  atomic acquisition, heartbeat refresh, stale-debris reclaim, and
  ownership-checked release. See
  [Concurrency model](#concurrency-model) above for the full
  serialization guarantee, the worktree anchoring, and which commands
  participate versus which only observe. Host migration note: repos
  onboarded before 0.2.5 have no ignore rules for `.g2g-goal.lock` /
  `.g2g-goal.mutex/`; add them alongside `.g2g-goal`. Builds still run
  without the rules — preflight treats these paths as expected
  untracked files, not dirt — but ignoring them keeps them out of
  `git status` noise.

## Running headless / unattended

Proven invocation shape (e.g. from `/loop` or a cloud routine):

```bash
claude -p "/g2g:build specs/feature.json" \
  --plugin-dir /path/to/g2g/plugin \
  --permission-mode acceptEdits \
  --allowedTools "Agent,Bash,Read,Write,Edit,Glob,Grep" \
  --setting-sources project \
  --max-turns 40 \
  --max-budget-usd 20
```

- `--allowedTools` is required alongside `acceptEdits` (which only auto-approves `Edit`/`Write`) — otherwise `Bash` calls get rejected until the session dies (the full list including `Agent` was validated in recorded end-to-end spike runs).
- `--setting-sources project` excludes the invoking user's personal settings — a real incident had a user-level `git push` approval gate silently deny a build's push.
- `--max-budget-usd` is what backs the "headless spawns add a dollar cap" guardrail above — the recorded end-to-end spike runs predate this flag being added to the invocation and ran without it; include it for any new headless spawn.
- `--plugin-dir` is what loads the plugin, and with it the Stop hook. It is **not** optional: `--setting-sources project` excludes your personal settings, so a plugin enabled only in `~/.claude/settings.json` is not loaded at all in that session — no `/g2g:*` commands and no hook. The alternative to passing `--plugin-dir` is declaring the plugin in the repo's own `.claude/settings.json`, which `/g2g:init` sets up (see [New repo quickstart](#new-repo-quickstart)). Either is sufficient; this file's invocation uses `--plugin-dir`.

### Cloud sandbox / managed agent / CI: what a fresh clone needs

Nothing g2g-specific has to be added for `/g2g:build`, `/g2g:spec`, or
`/g2g:go` to run in an environment with no browser login. Those commands
run *inside* the session — builders and verifiers are in-session
subagents that ride the session's own credentials — so authenticating
the session authenticates everything they do. Only `/g2g:improve`
spawns a separate `claude -p` child, which is why it alone carries
explicit key resolution (next section).

For a fresh clone in a cloud sandbox, managed agent, or CI runner:

1. **Credentials** — provide `ANTHROPIC_API_KEY` as an environment
   secret before launching the session. Headless mode prefers an API
   key over the stored login, so no browser flow is needed and the
   whole run bills to that key.
2. **Plugin loading** — either the repo's own `.claude/settings.json`
   declares the marketplace and enables the plugin (what
   `/g2g:init` sets up), or the invocation passes `--plugin-dir`.
   Remember that `--setting-sources project` excludes user settings, so
   a plugin enabled only in `~/.claude/settings.json` does not load.
3. **A spec** — `/g2g:build` requires a tracked spec with
   `context.verificationCommands` and refuses to run without one.
   `.claude/g2g.json` is optional; budgets and models fall back to
   defaults when it is absent.
4. **Invocation** — use the proven shape above, unchanged.

`G2G_IMPROVE_API_KEY` stays optional in these environments: set it only
when improve ticks should bill to a *separate* Console key; otherwise
improve inherits the same `ANTHROPIC_API_KEY` as everything else.

### Billing: which credentials a headless run uses

A spawned `claude -p` inherits credentials from its environment, and in headless mode an API key always wins over the stored login. `/g2g:improve` (and the nightly routine) resolve this explicitly, in precedence order, and report the chosen mode at launch:

1. **`G2G_IMPROVE_API_KEY`** set in the launching environment → the tick alone is spawned with `ANTHROPIC_API_KEY="$G2G_IMPROVE_API_KEY"` and bills to that Console key. Improve-scoped by design: your interactive sessions and other commands stay on whatever they were using. Export it once (e.g. from a keychain: `export G2G_IMPROVE_API_KEY=$(security find-generic-password -s g2g-console-key -w)`) and it applies in every repo that uses the plugin.
2. **`ANTHROPIC_API_KEY`** already exported → inherited as-is; the tick (and any other headless child of that shell) bills to it. The right choice when one default Console key should cover everything.
3. **Neither** → the tick uses the logged-in Claude Code account (subscription), today's default.

All of this is optional — with no variables set, nothing changes. The place it stops being optional is an environment with no logged-in account at all: a scheduled cloud routine, a managed agent, or CI must provide `G2G_IMPROVE_API_KEY` (or `ANTHROPIC_API_KEY`) as an environment secret, or the spawned run has no credentials.

Never commit a key: keep it in your shell environment, OS keychain, or `~/.claude` user settings — not in `.claude/g2g.json`, tracked settings, or specs. `--max-budget-usd` caps the tick identically in every mode; what changes is who gets billed.

  Earlier versions of this README claimed the plugin's own Stop hook "does not fire at all" under `--setting-sources project` and told you to copy the hook into each repo. That was wrong — the symptom was the plugin not being *loaded*, not the hook not firing — and the advice was actively harmful: a copied hook cannot be patched, so a repo onboarded before 0.4.0 keeps running the hook it was given no matter what the plugin ships later. Verified against CC 2.1.220 with a project-scoped marketplace install, no `--plugin-dir`: the plugin's own command hook fires with `${CLAUDE_PLUGIN_ROOT}` interpolated. `/g2g:init` now removes legacy copies rather than creating them.

The hook is **session-scoped**: it enforces only goals armed by the same session, which it establishes by finding the goal's `ownerToken` inside one of that session's own tool-call inputs. Sessions that never armed a goal — ordinary interactive sessions, or a session running concurrently while another build has a live `.g2g-goal` — stop immediately, so an armed goal can never conscript a bystander into completing it.

Uncertainty is asymmetric by design, and since 0.4.0 that asymmetry is enforced mechanically rather than by instructing a model. Anything that leaves *arming* in doubt — no goal file, unparsable goal JSON, an unreadable transcript, a foreign owner token, no `jq` — allows the stop (fail-open, protecting bystanders). Only once arming is proven does uncertainty about whether the *condition is met* block the stop (fail-closed, protecting the build). The escape hatches never depend on the transcript: the hours cap is computed from `buildStart` in the goal file, so a build cannot wedge even if transcript parsing breaks.

Cost is no longer a consideration: sessions with no `.g2g-goal` exit on a single file test, and there is no per-Stop model call anywhere. Before 0.4.0 the hook ran a small-model evaluation at every Stop in every repo where it was installed.

A blocked stop is how an autonomous build keeps working — the reason is fed back and the orchestrator continues — so the hook deliberately does **not** treat `stop_hook_active` as permission to allow. Honouring it would let any armed build stop after a single nudge; in a recorded smoke run it was a block that caught an interrupted verifier dispatch and forced the build through Phase 5 instead of abandoning it mid-flight. What the hook does instead, since 0.4.1, is escalate: after three blocks with no terminal state it keeps the specific diagnosis but adds the legitimate exits — finish Phase 5, or say the goal is unreachable and delete `.g2g-goal`. Claude Code independently caps consecutive blocks (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, default 9), so an unsatisfiable goal can never pin a session indefinitely.
