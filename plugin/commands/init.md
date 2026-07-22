---
description: Onboard a repo to the g2g plugin — detect the stack, confirm the verification suite, write .claude/g2g.json and safety plumbing
argument-hint: '(no arguments)'
---
# /g2g:init — onboarding

Onboard the current repo to the g2g plugin: $ARGUMENTS

This command writes at most three files, EVERY one only after showing
you the content and getting your confirmation: `.claude/g2g.json`,
`.claude/settings.json` (copy or Stop-hook merge), and — greenfield path
only — a `verify.sh` at the repo root. It never edits `.gitignore` or
any other file (gitignore problems are reported with the exact fix, not
applied), never commits, never creates branches, and never pushes — you
review what it wrote and commit it yourself. Nothing is guessed
silently.

## Procedure — deviations are failures

1. **Detect the stack and harvest candidate commands.** Inspect the repo
   root and classify it:
   - `package.json` → Node (template `g2g-node.json`).
   - `pyproject.toml` → Python (template `g2g-python.json`).
   - `Cargo.toml` → Rust — **no dedicated template exists**; take the
     custom-commands path (step 2's second option) and build the config
     off `g2g-bash.json`'s shape, never guessing Rust commands.
   - `Makefile` (no package manifest) → Make/bash (template
     `g2g-bash.json`).
   - Shell scripts only, no manifest → plain bash (template
     `g2g-bash.json`).
   - Empty or near-empty directory (no source, no manifest) → greenfield
     (template `g2g-greenfield.json`).

   Then harvest CANDIDATE test/lint commands (do not run or assume them
   yet) from: `package.json` `scripts`, `Makefile` targets,
   `pyproject.toml`/tool config, CI configs (`.github/workflows/*`,
   `.gitlab-ci.yml`, etc.), and repo docs (`README`, `CONTRIBUTING`,
   `CLAUDE.md`). Note the detected `sourceDirs` (e.g. `src`, or `.` for a
   flat bash repo) from the same evidence.

2. **Ask the user to confirm the verification suite BEFORE writing
   anything.** Present the detected stack and harvested candidates, then
   offer exactly these choices and WAIT for an answer — never guess
   silently:
   - Use the detected commands as-is — offer this ONLY when detection
     found at least one candidate command. A manifest with no test/lint
     scripts detects NOTHING; do not present an as-is option that would
     accept an empty suite.
   - Type a custom command (or commands) to use instead — this is also
     the path for any detected stack with no matching template (e.g.
     Rust/`Cargo.toml`): confirm the commands with the user rather than
     guessing.
   - Greenfield / empty dir only: scaffold a starter `verify.sh` by
     copying `${CLAUDE_PLUGIN_ROOT}/templates/verify-starter.sh` to
     `verify.sh` at the repo root, and set the verification command to
     `bash verify.sh`. Ask before writing `verify.sh`; it is the one
     file this command may create outside `.claude/`.

   The confirmed suite MUST contain at least one non-empty command —
   `verificationCommands: []` would make `/g2g:spec` abort later, the
   exact dead end this command exists to prevent. If the user declines
   every option, STOP without writing anything and say why.

3. **Write `.claude/g2g.json`** from the matching template in
   `${CLAUDE_PLUGIN_ROOT}/templates/`, applying the confirmed
   `verificationCommands` and the detected `sourceDirs`, and these
   defaults under `defaultBudgets`: `buildTurnsFactor` 2, `buildHours`
   2, `improveTurns` 50, `improveUsd` 25, `improveFindings` 3; plus all
   five `reviewFocus` categories (`code-quality`, `test-coverage`,
   `architecture`, `security`, `bug`); and `improve.enabled` false —
   the improve flywheel is strictly opt-in (review-finding text flows
   into Bash-capable builders, backlog finding F-001), so leave it disabled and
   tell the user how to enable it later if they trust the repo's
   contents. Confirm the exact contents with
   the user before writing. **NEVER overwrite an existing
   `.claude/g2g.json` without explicit confirmation** — if one is
   present, show a diff of what would change and proceed only if the
   user approves; otherwise leave it untouched.

4. **Safety plumbing.**
   - **Stop-hook settings** — explain WHY first: the plugin's own Stop
     hook does not fire under `--setting-sources project` (how headless
     builds run), so the host repo needs the hook duplicated into its
     own `.claude/settings.json` (plugin README, "Running headless /
     unattended"). Then:
     - `.claude/settings.json` ABSENT: show what will be written (a copy
       of `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json`), ASK, and copy on
       approval.
     - PRESENT and already containing the plugin's Stop hook (compare
       against the `Stop` entry in `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json`):
       say so and leave it untouched.
     - PRESENT but MISSING the Stop hook (ordinary existing settings):
       do NOT leave it silently — headless builds in this repo would run
       unprotected. Show a diff of the existing file versus the file
       with the Stop hook entry merged in (preserving everything already
       there), ASK, and apply the merge only on approval. If declined,
       WARN prominently that unattended runs here have no Stop-hook
       safety net.
   - **Artifact tracking check (advisory only — never edit files):**
     test each of these four paths INDIVIDUALLY with
     `git check-ignore -q <path>`:
     `specs/g2g-init-ignore-probe.json` (a deliberately untracked
     sentinel — never probe `specs/example.json`, whose historical
     `!specs/example.json` allow-rule would mask a `specs/*` ignore
     that still eats every NEW spec), `review-output/findings.json`,
     `.claude/g2g.json`, `.claude/settings.json`. Only when `-q`
     exits 0 (that path IS ignored), run `git check-ignore -v <path>`
     on it to display the responsible rule in the warning. Never treat
     a negated (`!`) allow-rule as a problem or suggest removing one —
     negations are what KEEP these files tracked. The warnings: ignored
     `specs/`/`review-output/` silently vanish in worktrees and fresh
     clones and defeat the improve loop (plugin README, "Artifact
     tracking"); an ignored `.claude/` is worse — this command's own
     config and safety hook would vanish the same way, making
     initialization an illusion. Print the exact ignore rule(s) to
     remove and the `git add` to run, but do NOT modify `.gitignore` —
     that edit is the user's.
   - WARN (do NOT fail) on any of: not a git repo, no `gh` auth
     (`gh auth status`), or no `origin` remote (`git remote get-url
     origin`). These block PR-time steps later but not initialization.

5. **Next-steps card.** Finish by printing these four, one line each:
   - `/g2g:go "<task>"` — quick one-off task.
   - `/g2g:dev "<feature>"` — generate a spec, then build a feature.
   - `/g2g:review` — build the tracked findings backlog.
   - `/g2g:improve` — bounded autopilot: review → fix-spec → build → PR.

6. **Scope statement.** State plainly which of the three permitted
   files (`.claude/g2g.json`, `.claude/settings.json`, greenfield
   `verify.sh`) were actually written, each with the user's recorded
   confirmation; that nothing else changed (`.gitignore` advice was
   advisory only); and that nothing was committed — the user reviews
   and commits the new files themselves.
