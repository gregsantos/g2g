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
| `/g2g:status` | Read-only dashboard: active goal, spec progress, open `g2g/*` PRs, worktrees |
| `/g2g:spec "<prompt>" \| -f <file> \| --from-findings [path]` | Generate a validated spec JSON in `specs/` (no commit — review, then build) |
| `/g2g:dev "<prompt>" [--review]` | Full pipeline: generate spec → build it; `--review` pauses for spec approval |
| `/g2g:review [--diff-base <ref>] [--focus <cats>] [--target <path>]` | Read-only codebase review — parallel category subagents merged into the tracked findings backlog |
| `/g2g:improve [--wait]` | One bounded improve tick: headless review → fix-spec → build → PR in a fresh worktree; `--wait` blocks until done |
| `/g2g:improve-cycle` | Internal — the unit of work `/g2g:improve` spawns; refuses to run outside a `g2g/improve-*` worktree |

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
regenerated `REVIEW_REPORT.md`, never committing. Each finding carries
`addressed`: `null` while open, the fix PR's number once an improve
cycle delivers one, or `stale-<date>` when revalidation finds it
already fixed.

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

Optional `.claude/g2g.json` in the host repo (see [`.claude/g2g.json`](../.claude/g2g.json) here for an example). Field status below — `verificationCommands`, `defaultBudgets`, `reviewFocus`, and `sourceDirs` are live; `models` and `artifactPaths` are deliberately reserved:

- `verificationCommands` — **live now**: `/g2g:go` reads this to verify a one-off task, if the file exists and defines it (falls back to the repo's documented test/lint commands otherwise). `/g2g:spec` (and therefore `/g2g:dev`, which chains it) also reads this field as the priority source for a generated spec's `context.verificationCommands`, before falling back to the repo's documented test commands. **Not** read by `/g2g:build` — that command sources its verification commands from the spec's `context.verificationCommands` instead (already populated by `/g2g:spec` from this field, if present), see Spec format below.
- `defaultBudgets` — **live now**: `buildTurnsFactor`/`buildHours` set `/g2g:build`'s TURN_CAP factor and wall-clock cap (defaults 2 / 2h); `improveTurns`/`improveUsd` cap the improve spawn (defaults 50 / $25); `improveFindings` sets findings-per-cycle (default 3). `improveHours` is documented-only: no wall-clock CLI flag exists, the turn cap approximates it.
- `improve.enabled` — **live now**: hard opt-in gate for the improve flywheel (see Trust caveat above). Defaults to `false` in every template; `/g2g:improve` and `/g2g:improve-cycle` refuse to run unless it is exactly `true`.
- `reviewFocus` — **live now**: the categories `/g2g:review` fans out across when `--focus` isn't given.
- `sourceDirs` — **live now**: the default review targets when `--target` isn't given.
- `models` — **live now** for `builder` and `verifier`: `/g2g:build` dispatches builder subagents with `models.builder` (default `sonnet` — tasks are pre-decomposed with explicit criteria, a Sonnet-shaped job) and the verifier with `models.verifier` (default `inherit` — adversarial judgment stays on the session model). `"inherit"` means use the invoking session's model. `models.go` is not read: `/g2g:go` hardcodes `model: sonnet` in its frontmatter (go.md); `/g2g:status` likewise pins `haiku`.
- `artifactPaths` — **reserved (deliberately — no consumer in v1)**: intended override for where specs and review output live, for non-standard layouts; no command reads this yet.

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
- **`.g2g-goal`** is an ephemeral, gitignored runtime file that
  `/g2g:build` writes and deletes itself — hosts should gitignore it
  and never commit it.

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

- `--allowedTools` is required alongside `acceptEdits` (which only auto-approves `Edit`/`Write`) — otherwise `Bash` calls get rejected until the session dies (Task 7; full list including `Agent` validated end-to-end in Task 11, Scenario A, ~line 707).
- `--setting-sources project` excludes the invoking user's personal settings — a real incident had a user-level `git push` approval gate silently deny a build's push.
- `--max-budget-usd` is what backs the "headless spawns add a dollar cap" guardrail above — the recorded end-to-end runs (Task 7, Task 11) predate this flag being added to the invocation and ran without it; include it for any new headless spawn.
- **Caveat:** under `--setting-sources project` the plugin's own Stop hook does not fire at all (re-confirmed 2026-07-20) — the host repo needs the hook duplicated into its own `.claude/settings.json`. **`/g2g:init` installs (or merges) this hook for you as part of onboarding** — run it once per repo and commit the result. Manual fallback, verbatim from [`plugin/hooks/hooks.json`](hooks/hooks.json) (this repo tracks such a copy at `.claude/settings.json`, so fresh clones and worktrees of g2g already have it):

  ```bash
  cp plugin/hooks/hooks.json .claude/settings.json
  ```

The hook is **session-scoped**: it enforces only goals armed by the same session (the transcript must show that session writing `.g2g-goal` and reading it back). Sessions that never armed a goal — interactive sessions, or sessions running concurrently while another session's build has a live `.g2g-goal` — are allowed to stop immediately, so an armed goal can never conscript a bystander session into completing it.

Interactive sessions need none of this setup — the plugin's hook fires normally there.
