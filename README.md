# g2g

A Claude Code plugin for goal-driven autonomous builds: specs become
verifier-gated pull requests through fresh-context builder subagents,
independent adversarial verification, and deterministic completion
evidence produced by a real script run — never a self-reported
completion marker.

- **Plugin guide** (commands, config, guardrails): [plugin/README.md](plugin/README.md)
- **Operator runbook** (run, watch, recover, tune): [docs/G2G_PLUGIN_REF.md](docs/G2G_PLUGIN_REF.md)

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
| `/g2g:review [--diff-base <ref>] [--focus <cats>] [--target <path>]` | Read-only review into the tracked findings backlog |
| `/g2g:improve [--wait]` | One bounded improve tick: review → fix-spec → build → PR (strictly opt-in) |
| `/g2g:status` | Read-only dashboard: goal, spec progress, open `g2g/*` PRs, worktrees |

## How it works

`/g2g:build` orchestrates, never edits. Each task gets a fresh-context
**builder** subagent that makes exactly one commit; task state
(`status`, `passes`, `attempts`) is written back into the spec JSON and
committed every turn. When all tasks pass, an adversarial **verifier**
subagent (defaults to FAIL when uncertain) checks the whole branch diff
against the spec before a PR opens. Completion is enforced by a Stop
hook reading an ephemeral `.g2g-goal` file: the session cannot end
until the evidence script — a real command execution, not assistant
text — shows every task passed and the verifier's PASS, or a turn/time
cap routes the build to a draft partial PR. Nothing merges itself.

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
  `/g2g:init` installs it; commit the result.
- `specs/` and `review-output/` must be git-tracked: worktrees and
  fresh clones only materialize tracked files.
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
│   ├── templates/                    # /g2g:init config starters
│   └── routines/                     # Scheduled-run templates
├── specs/                            # Spec JSONs (tracked)
├── review-output/                    # Findings backlog + report (tracked)
├── docs/G2G_PLUGIN_REF.md            # Operator runbook
└── tests/                            # bats tests for scripts + templates
```

## Development

```bash
make check   # shellcheck + bats (brew install bats-core shellcheck)
```

## License

[MIT](LICENSE)
