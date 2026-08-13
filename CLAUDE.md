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

Run after any change to shell scripts, templates, command/agent
markdown, or tests:

- All: `make check` (lint + manifest validation + bats)
- Tests: `make test` (requires bats-core and a bash >= 4:
  `brew install bats-core bash` — macOS system bash 3.2 silently
  swallows failing mid-test `[[ ]]` asserts, so the target refuses to
  run without an enforcing bash; F-060)
- Lint: `make lint` (requires shellcheck: `brew install shellcheck`)
- Behavioral: `make smoke` — real headless build against a throwaway
  sandbox; costs API dollars and minutes. Run as the merge gate for
  changes to `plugin/commands/` or `plugin/agents/`; never wire it
  into check. It gates the PROTOCOL, not the sandbox build's quality:
  terminal state reached, goal/lock/mutex cleaned up, branch pushed, no
  task abandoned in_progress. A run that ends PARTIAL because the
  verifier found a real bug exercised the protocol correctly and passes;
  add `SMOKE_REQUIRE_COMPLETE=1` to also demand a fully green build.
  `tests/smoke.sh --assert-only <preserved-dir>` re-checks a previous
  run's artifacts with no API spend.

# Project structure

```
g2g/
├── .claude-plugin/marketplace.json   # Marketplace catalog → ./plugin
├── plugin/
│   ├── .claude-plugin/plugin.json    # Plugin metadata (name, version)
│   ├── commands/                     # /g2g:* command procedures (markdown)
│   ├── agents/                       # g2g-builder, g2g-verifier definitions
│   ├── skills/                       # writing-g2g-specs, reviewing-codebase
│   ├── hooks/hooks.json              # Stop hook registration → g2g-stop.sh
│   ├── scripts/g2g-evidence.sh       # Deterministic evidence generator
│   ├── scripts/g2g-lock.sh           # Checkout-lock protocol (sole implementation)
│   ├── scripts/g2g-stop.sh           # Stop-hook goal enforcement (sole implementation)
│   ├── templates/                    # /g2g:init config starters (g2g-*.json)
│   ├── routines/                     # Scheduled-run templates
│   └── evals/                        # plugin-eval cases (status: its README)
├── specs/                            # Spec JSONs — must stay git-tracked
├── review-output/                    # Findings backlog — must stay git-tracked
├── docs/G2G_PLUGIN_REF.md            # Operator runbook
├── tests/                            # bats suites + enforcement canary (canary/)
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
  (0 ok / 2 invalid spec / 3 no verificationCommands); `g2g-stop.sh` keys
  its completion check on the verdict line and, for a proven-armed
  session, also compares the paired block's `head:` line against
  current repository state before allowing the stop (F-059). Change
  output format only with the tests, `g2g-stop.sh`, and build.md
  updated together.
- **The Stop hook is deterministic — never make it a prompt again.**
  `plugin/scripts/g2g-stop.sh` is the sole implementation of goal
  enforcement; `hooks.json` only registers it. `tests/plugin_stop.bats`
  pins the behaviour, and the direction of its uncertainty is the whole
  point: anything leaving *arming* in doubt allows the stop, and only a
  proven-armed session fails closed. The hook it replaced asked one small
  model to do both jobs and inverted that branch in production, blocking
  sessions that had armed nothing. Never reintroduce a model call here,
  and never copy the hook into a host repo — a vendored copy is one no
  plugin update can patch.
- **The lock script is the protocol.** `plugin/scripts/g2g-lock.sh` is
  the sole implementation of checkout-lock synchronization;
  `tests/plugin_lock.bats` pins its exit codes and outcome lines, and
  build.md/improve-cycle.md branch on them. The goal/lock/mutex trio
  is anchored to the enclosing git worktree root (via `git rev-parse
  --show-toplevel`, falling back to `$PWD` outside any repository) —
  `g2g-stop.sh` and build.md's goal-write step must resolve that same
  anchor, never the caller's working directory, or a build started
  from a subdirectory arms a goal the hook can't find. Never
  reintroduce lock logic as command prose; change the contract only
  with the tests and both commands updated together.
- **Templates are pinned by tests.** `tests/templates.bats` asserts the
  exact `defaultBudgets` values, the five `reviewFocus` categories, and
  `improve.enabled: false` in every `plugin/templates/*.json`.
- **The test harness proves its own enforcement.** The Makefile `test`
  target resolves a bash whose errexit actually fails mid-test `[[ ]]`
  asserts and requires `tests/canary/enforcement.bats` — a
  deliberately failing assert — to report `not ok` before trusting the
  suite. Never simplify the target back to bare `bats tests/`, and
  never "fix" the canary so it passes: a green it can't refute is the
  exact failure mode it exists to catch (F-060).
- **Safety invariants — never weaken:** branch-first and PR-gated (no
  writes to the default branch, nothing merges itself, one push at PR
  time); caps on every autonomous run (turns, hours, dollars — no
  unlimited mode); the improve flywheel is strictly opt-in
  (`improve.enabled` must be exactly `true`; enabling it is always a
  human edit — the gate is defense in depth for the finding-text
  injection boundary; see the trust caveat in plugin/README.md); no
  detached processes
  (nohup/disown/setsid) — every spawned tick keeps a pid sidecar and
  stays killable; credentials are environmental only — no API key is
  ever written to g2g.json, templates, settings, specs, or anything
  tracked (improve billing rides `G2G_IMPROVE_API_KEY`; see README
  "Billing").
- **`.g2g-goal`, `.g2g-goal.lock`, and `.g2g-goal.mutex/` are
  ephemeral** — gitignored runtime files; the goal is written by
  `/g2g:build`, the lock/mutex only ever by `g2g-lock.sh`. All are
  gone at every terminal state (`release-terminal`). Never commit
  them; never leave a terminal path that skips the release.
- **Version bumps: one per PR that changes the plugin.** Bump
  `plugin/.claude-plugin/plugin.json` whenever anything under `plugin/`
  changes installed behavior (commands, agents, skills, scripts, hooks,
  templates, routines, config schema) and add the matching
  `CHANGELOG.md` entry in the same commit; docs-only edits need
  neither. Bump exactly once per PR, never per commit — in a multi-task
  spec, assign the bump to ONE task and tell the other builders it is
  taken, or every fresh context reads this rule and bumps again.
- **Release tags are cut by CI, never by hand.** The `tag-release` job in
  `.github/workflows/ci.yml` runs on every push to the default branch and
  tags `g2g--v<version>` from `plugin/.claude-plugin/plugin.json`, with the
  tag body lifted from that version's `CHANGELOG.md` section. It is
  idempotent — a merge that bumps nothing finds its tag already present and
  exits 0 — and it FAILS when `plugin.json` names a version `CHANGELOG.md`
  has no heading for, which is what makes the paired-edit rule above
  enforced rather than remembered. Never create a release tag manually and
  never add a second tag scheme: the job is the only writer, and a
  hand-cut tag silently becomes the one it will not replace. Tagging was a
  manual post-merge step until 0.6.5 and lapsed for four straight releases
  (0.6.2–0.6.5 were tagged retroactively) — that is the failure this
  automation exists to prevent.
- **Post-verifier-PASS changes amend the spec record.** Any commit on a
  `g2g/*` build branch after the verifier PASS that changes behavior an
  acceptance criterion describes must, in the same change, amend that
  criterion to the as-shipped design and append an amendment note to the
  task's notes citing the superseding commit(s); the spec's `verifier`
  field is never rewritten — it remains the record of the PASS against
  the original criteria (F-061).
- **Merge `g2g/*` PRs, never squash them.** The rule above puts per-task
  commit SHAs in task notes; squashing makes every cited SHA unreachable
  from a fresh clone of the default branch, so the spec's own record
  stops resolving. Merge commits keep them, and
  `git log --first-parent` reads the default branch at one line per PR
  when the per-task commits are noise.
- **Every new write-capable command joins the checkout lock.** A new
  `/g2g:*` command that writes anything to the checkout must either
  hold the lock (acquire/refresh/release like `build.md`/`go.md`) or
  query it read-only before writing (`g2g-lock.sh status`, like
  `spec.md`/`review.md`/`dev.md` Phase A) — never write unconditionally
  as if no other g2g command could be running. See
  `plugin/README.md`'s "Concurrency model" section for the full
  protocol and which existing commands do which.
- Shell: bash, shellcheck-clean (`.shellcheckrc` at repo root). Tests:
  bats, one behavior per test, golden output where format is contractual.

# Specs

Specs use a `tasks[]` array (`id`, `title`, `description`,
`acceptanceCriteria`, `dependsOn`, `status`, `passes`, `attempts`,
`effort`, `notes`) plus `context.verificationCommands` (required for
`/g2g:build`) and a top-level `verifier` field the build writes on
PASS. Canonical example: [specs/example.json](specs/example.json);
full schema: the `writing-g2g-specs` skill in `plugin/skills/`.
