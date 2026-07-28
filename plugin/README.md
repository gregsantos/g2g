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
  Stop-hook gate (the armed condition keeps the subagent-delivered
  VERIFIER REPORT requirement; only the turn-line cap clauses are
  replaced by the workflow's terminal-outcome report), the adversarial
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

## Guardrails

- **PR-gated, branch-first, never merges** — every writing command
  refuses the default branch; only `g2g/*` branches are ever pushed, and
  only at PR time.
- **Caps everywhere** — every goal carries turn and wall-clock stop
  clauses; headless spawns add a dollar cap. There is no unlimited mode.
- **POSIX shell required** — the evidence script needs `bash`; pure
  Windows without git-bash/WSL is unsupported in v1.
- **`.g2g-goal` and `.g2g-goal.lock`** are ephemeral, gitignored runtime
  files that `/g2g:build` writes and deletes itself — hosts should
  gitignore both and never commit them. The lock (plus its transient
  `.g2g-goal.mutex/` directory, gitignored the same way) is managed
  exclusively by `plugin/scripts/g2g-lock.sh`, the executable,
  behaviorally-tested implementation of the one-build-per-checkout
  protocol: atomic acquisition, heartbeat refresh, stale-debris
  reclaim, and ownership-checked release, all serialized so two
  concurrent builds can never both hold the checkout. Host migration
  note: repos onboarded before 0.2.5 have no ignore rules for
  `.g2g-goal.lock` / `.g2g-goal.mutex/`; add them alongside
  `.g2g-goal`. Builds still run without the rules — preflight treats
  these paths as expected untracked files, not dirt — but ignoring
  them keeps them out of `git status` noise.

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
- **Caveat:** under `--setting-sources project` the plugin's own Stop hook does not fire at all (re-confirmed 2026-07-20) — the host repo needs the hook duplicated into its own `.claude/settings.json`. **`/g2g:init` installs (or merges) this hook for you as part of onboarding** — run it once per repo and commit the result. Manual fallback, verbatim from [`plugin/hooks/hooks.json`](hooks/hooks.json) (this repo tracks such a copy at `.claude/settings.json`, so fresh clones and worktrees of g2g already have it):

  ```bash
  cp plugin/hooks/hooks.json .claude/settings.json
  ```

The hook is **session-scoped**: it enforces only goals armed by the same session (the transcript must show that session writing `.g2g-goal` and reading it back). Sessions that never armed a goal — interactive sessions, or sessions running concurrently while another session's build has a live `.g2g-goal` — are allowed to stop immediately, so an armed goal can never conscript a bystander session into completing it. The evaluator's uncertainty handling is asymmetric by design: uncertainty about whether a goal was *armed* resolves to allowing the stop (fail-open, protecting bystanders), but within the arming session uncertainty about whether the *condition is met* resolves to not met (fail-closed, protecting the build). Note also that once this hook is installed in a repo's `.claude/settings.json` it runs a small-model evaluation at every session Stop in that repo — cheap per call (the no-goal case short-circuits), but a standing cost worth knowing about.

Interactive sessions need none of this setup — the plugin's hook fires normally there.
