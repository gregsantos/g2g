# g2g

A Claude Code plugin for goal-driven autonomous builds: specs become
verifier-gated pull requests through fresh-context builder subagents,
independent adversarial verification, and deterministic completion
evidence produced by a real script run — never a self-reported
completion marker.

- **Plugin guide** (commands, config, guardrails): [plugin/README.md](plugin/README.md)
- **Operator runbook** (run, watch, recover, tune): [docs/G2G_PLUGIN_REF.md](docs/G2G_PLUGIN_REF.md)

## Why g2g

Claude Code already ships primitives for autonomous work. `/goal` keeps a
session working until a condition is met; `/loop` re-runs a prompt on a
schedule; subagents give you fresh contexts; routines run scheduled work in
the cloud. For a task you're watching, or a simple recurring job, reach for
those first — g2g would be overkill.

g2g exists for the harder case: **start a multi-task build you won't babysit,
and be able to trust the PR at the end.** That needs four things the native
primitives don't provide together — untainted context per unit of work, a
completion signal that can't be faked, an independent check that tries to
break the result, and a hard ceiling that degrades to a reviewable partial
instead of spinning forever.

### How it compares

| | Native `/goal` / `/loop` | g2g |
|---|---|---|
| **Context** | One session context that grows every turn — earlier tasks' dead-ends and noise pile up (context rot), and long builds can exhaust the window | One **fresh builder subagent per task**, seeded only by its task card; the orchestrator and verifier never inherit build chatter |
| **Completion signal** | `/goal`'s condition is judged by a small model reading the **conversation** — it sees what the model *said*, not what the code *does* | A **real run of your `verificationCommands`** (exit codes + a frozen summary line) must appear as tool output in the transcript; the Stop gate keys on that artifact, not on narration |
| **Verification** | None built in — the same context that did the work decides it's done | A separate **adversarial verifier** that defaults to FAIL, reads the whole branch diff, re-runs your commands, and cannot edit the code it judges |
| **Over budget / failure** | `/goal` has no turn or cost cap — an unreachable condition loops until you notice and `/goal clear` | **Turn / hours / dollar caps**; hitting one converts the run into a **draft partial PR** (`g2g:partial`) with an honest outstanding-work list |
| **Safety** | Auto-mode flags risky actions, but nothing mandates a PR workflow | **Branch-first, PR-gated, never self-merges**; one push at PR time; no detached background processes |
| **Concurrency** | Single session, no coordination | A **checkout lock** (mutex + ownership token + stale reclaim) stops two builds corrupting one working copy |

### The dimensions that matter

- **Context rot.** A `/goal` run reasons about task 8 through the residue of
  tasks 1–7. A g2g builder reasons about task 8 from a clean window holding
  only its task card and the repository on disk, and makes exactly one commit.
  The verifier judges the *diff*, not the build's chat history. (Builders run
  one at a time in dependency order — the isolation is per-context, not
  parallelism.)
- **Token cost.** Native single-context work re-processes an ever-growing
  history every turn, so per-turn cost climbs and can hit the context ceiling.
  g2g's per-task contexts don't accumulate, cheaper models can be routed to
  cheaper roles, and the caps put a hard ceiling on spend. It isn't free —
  orchestration, a verifier pass, and subagent spawns cost tokens — so the
  trade is a small fixed overhead for **bounded, non-accumulating** cost. The
  win grows with build length.
- **Graceful degradation.** The failure mode of an unattended `/goal` is a
  silent loop. The failure mode of a g2g build is a draft PR you can open and
  read, listing exactly what got done and what is still blocked.
- **Completion you can trust.** g2g's evidence is a deterministic *artifact* —
  your commands, actually executed, with real exit codes. The Stop gate that
  reads it is still a small-model judge, but it is judging real tool output in
  the transcript (not the model's self-narration), and the verifier
  independently re-runs the commands — so "done" cannot be conjured by the
  model saying so.

**When not to use it:** interactive one-offs, or simple scheduled chores —
`/goal`, `/loop`, or a routine are simpler and lighter. g2g earns its structure
when the run is unattended, multi-step, and the cost of a false "done" is high.

## Install

Inside Claude Code:

```
/plugin marketplace add <this-repo-path-or-url>
/plugin install g2g@g2g
```

For headless or CI use, skip the marketplace and pass the plugin
directory (or a zip URL) directly:

```bash
claude -p "/g2g:go 'fix the failing lint rules'" --plugin-dir /path/to/g2g/plugin
```

## Quickstart

1. Install (above).
2. `/g2g:init` — interactive onboarding: detects your stack, confirms
   the verification suite, writes `.claude/g2g.json` and the Stop-hook
   safety plumbing. Every write is confirmed first; nothing is committed.
3. `/g2g:dev "first feature"` — generate a spec, then build it.

## Commands

| Command | Description |
|---|---|
| `/g2g:init` | Onboard a repo: detect stack, confirm verification suite, write config + safety plumbing |
| `/g2g:go "<task>" [--pr]` | One-off task: branch-first, implement, verify, commit |
| `/g2g:spec "<prompt>" \| -f <file> \| --from-findings` | Generate a validated spec JSON in `specs/` for review |
| `/g2g:build <spec.json> [--continue-branch]` | Goal-driven build: fresh builder per task, verifier-gated PR |
| `/g2g:dev "<prompt>" [--review]` | Pipeline: generate spec → build it |
| `/g2g:review [--diff-base <ref>] [--full] [--focus <cats>] [--target <path>]` | Read-only review into the tracked findings backlog |
| `/g2g:improve [--wait]` | One bounded improve tick: review → fix-spec → build → PR (strictly opt-in) |
| `/g2g:status` | Read-only dashboard: goal, spec progress, open `g2g/*` PRs, worktrees |

## How it works

`/g2g:build` orchestrates, never edits. Each task gets a fresh-context
**builder** subagent that makes exactly one commit; task state
(`status`, `passes`, `attempts`) is written back into the spec JSON and
committed every turn. When all tasks pass, an adversarial **verifier**
subagent (defaults to FAIL when uncertain) checks the whole branch diff
against the spec before a PR opens. Completion is enforced by a
session-scoped Stop hook tied to an ephemeral `.g2g-goal` file: the
session that armed the goal cannot end until the evidence script — a
real command execution, not assistant text — shows every task passed
and the verifier's PASS, or a turn/time cap routes the build to a draft
partial PR; other sessions in the repo are unaffected. Nothing merges
itself.

## Specs

Specs are JSON files with a `tasks[]` array (`id`, `title`,
`description`, `acceptanceCriteria`, `dependsOn`, `status`, `passes`)
and a `context.verificationCommands` array the evidence script runs.
See [specs/example.json](specs/example.json) and the
`writing-g2g-specs` plugin skill for the full schema.

## Headless / CI

The proven invocation shape:

```bash
claude -p "/g2g:build specs/feature.json" \
  --plugin-dir /path/to/g2g/plugin \
  --permission-mode acceptEdits \
  --allowedTools "Agent,Bash,Read,Write,Edit,Glob,Grep" \
  --setting-sources project \
  --max-turns 40 \
  --max-budget-usd 20
```

Notes:

- The CLI retries transient API errors itself and exits nonzero on
  failure — no wrapper loop is needed; use your CI runner's retry for
  whole-process failures.
- Under `--setting-sources project` plugin hooks are inert, so the host
  repo needs the Stop hook in its own `.claude/settings.json` —
  `/g2g:init` installs it; commit the result. Without it, an unattended
  run has no completion gate.
- `specs/` and `review-output/` must be git-tracked: worktrees and
  fresh clones only materialize tracked files.
- **Measuring actual cost.** `ANTHROPIC_API_KEY` outranks subscription
  OAuth in Claude Code's auth precedence and is used without prompting
  in `-p` mode, so a per-invocation
  `ANTHROPIC_API_KEY=... claude -p ...` (or `... make smoke`) bills
  just that child run to the Console key — the interactive session's
  subscription login is untouched. Note that the `total_cost_usd` in
  `json`/`stream-json` output is a client-side *estimate* under both
  auth modes; actual billed cost lives in the Console usage dashboard
  or the Usage & Cost API. Use a key from a dedicated Console
  workspace to see a run's spend in isolation, and pass it via the
  environment only — never inline in a command string that lands in
  `tick.log` or a commit. `--max-budget-usd` enforces identically
  under both auth modes.
- For scheduled improvement ticks, see
  [plugin/routines/improve-nightly.md](plugin/routines/improve-nightly.md);
  the improve flywheel additionally requires the explicit
  `"improve": { "enabled": true }` opt-in in `.claude/g2g.json`.

## Repository layout

```
g2g/
├── .claude-plugin/marketplace.json   # Marketplace catalog (installs ./plugin)
├── plugin/                           # The plugin
│   ├── .claude-plugin/plugin.json    # Plugin metadata
│   ├── commands/                     # /g2g:* command procedures
│   ├── agents/                       # g2g-builder, g2g-verifier
│   ├── skills/                       # writing-g2g-specs, reviewing-codebase
│   ├── hooks/hooks.json              # Stop hook (goal enforcement)
│   ├── scripts/g2g-evidence.sh       # Deterministic evidence generator
│   ├── scripts/g2g-lock.sh           # Checkout-lock protocol (sole implementation)
│   ├── templates/                    # /g2g:init config starters
│   ├── routines/                     # Scheduled-run templates
│   └── evals/                        # plugin-eval cases (harness in early access)
├── specs/                            # Spec JSONs (tracked)
├── review-output/                    # Findings backlog + report (tracked)
├── docs/G2G_PLUGIN_REF.md            # Operator runbook
└── tests/                            # bats tests for scripts + templates
```

## Development

```bash
make check   # shellcheck + manifest validation + bats (brew install bats-core shellcheck)
```

## License

[MIT](LICENSE)
