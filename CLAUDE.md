This codebase will outlive you. Every shortcut you take becomes
someone else's burden. Every hack compounds into technical debt
that slows the whole team down.

You are not just writing code. You are shaping the future of this
project. The patterns you establish will be copied. The corners
you cut will be cut again.

Fight entropy. Leave the codebase better than you found it.

# What this repo is

g2g is a Claude Code plugin for goal-driven autonomous builds:
spec → fresh-context builders → adversarial verifier → PR, with
completion enforced by deterministic evidence (a real script run) and
a Stop hook, never a self-reported marker. The plugin lives in
`plugin/`; this repo is its source and distribution (the marketplace
catalog at `.claude-plugin/marketplace.json` installs `./plugin`).

Full command/config/guardrail reference: [plugin/README.md](plugin/README.md).
Operator runbook: [docs/G2G_PLUGIN_REF.md](docs/G2G_PLUGIN_REF.md).

# Validation

Run after any change to shell scripts, templates, or tests:

- Both: `make check`
- Tests: `make test` (requires bats-core: `brew install bats-core`)
- Lint: `make lint` (requires shellcheck: `brew install shellcheck`)

# Project structure

```
g2g/
├── .claude-plugin/marketplace.json   # Marketplace catalog → ./plugin
├── plugin/
│   ├── .claude-plugin/plugin.json    # Plugin metadata (name, version)
│   ├── commands/                     # /g2g:* command procedures (markdown)
│   ├── agents/                       # g2g-builder, g2g-verifier definitions
│   ├── skills/                       # writing-g2g-specs, reviewing-codebase
│   ├── hooks/hooks.json              # Stop hook — goal enforcement
│   ├── scripts/g2g-evidence.sh       # Deterministic evidence generator
│   ├── templates/                    # /g2g:init config starters (g2g-*.json)
│   └── routines/                     # Scheduled-run templates
├── specs/                            # Spec JSONs — must stay git-tracked
├── review-output/                    # Findings backlog — must stay git-tracked
├── docs/G2G_PLUGIN_REF.md            # Operator runbook
├── tests/                            # bats: evidence script + templates
└── .claude/                          # This repo's own g2g.json + settings.json
```

# Conventions for editing the plugin

- **Commands are procedures.** Files in `plugin/commands/` are executable
  instructions, not documentation — keep steps numbered, imperative, and
  unambiguous; state abort conditions explicitly ("deviations are
  failures"). A command's frontmatter `description` and `argument-hint`
  must match its behavior.
- **Report contracts are load-bearing.** The orchestrator parses builder
  and verifier results by seeking the `BUILDER REPORT` / `VERIFIER
  REPORT` marker lines; never change those markers or their fields
  without updating `plugin/commands/build.md` in the same change.
- **The evidence script's output is frozen.** `tests/plugin_evidence.bats`
  pins `g2g-evidence.sh`'s header, footer, summary line, and exit codes
  (0 ok / 2 invalid spec / 3 no verificationCommands); the Stop-hook
  goal condition in build.md keys on the summary line. Change output
  format only with the tests and build.md updated together.
- **Templates are pinned by tests.** `tests/templates.bats` asserts the
  exact `defaultBudgets` values, the five `reviewFocus` categories, and
  `improve.enabled: false` in every `plugin/templates/*.json`.
- **Safety invariants — never weaken:** branch-first and PR-gated (no
  writes to the default branch, nothing merges itself, one push at PR
  time); caps on every autonomous run (turns, hours, dollars — no
  unlimited mode); the improve flywheel is strictly opt-in
  (`improve.enabled` must be exactly `true`; enabling it is always a
  human edit — see backlog finding F-001, "Review-finding text flows
  unsanitized into builder-executed criteria": hardened in PR #1, gate
  kept as defense in depth); no detached processes
  (nohup/disown/setsid) — every spawned tick keeps a pid sidecar and
  stays killable.
- **`.g2g-goal` is ephemeral** — gitignored, written by `/g2g:build`,
  deleted at every terminal state. Never commit it; never leave a
  terminal path that skips deleting it.
- **Version bumps:** update `plugin/.claude-plugin/plugin.json` when
  command behavior, config schema, or templates change.
- Shell: bash, shellcheck-clean (`.shellcheckrc` at repo root). Tests:
  bats, one behavior per test, golden output where format is contractual.

# Specs

Specs use a `tasks[]` array (`id`, `title`, `description`,
`acceptanceCriteria`, `dependsOn`, `status`, `passes`, `attempts`,
`effort`, `notes`) plus `context.verificationCommands` (required for
`/g2g:build`) and a top-level `verifier` field the build writes on
PASS. Canonical example: [specs/example.json](specs/example.json);
full schema: the `writing-g2g-specs` skill in `plugin/skills/`.

# Git

- Write clear, imperative commit messages: "Add user authentication"
  not "Added auth".
- Keep commits atomic: one logical change per commit.
- Never commit secrets, API keys, or credentials.
