---
description: Codex adversarial review (model-invocable) — challenges the implementation approach, design, and assumptions on an open g2g PR
argument-hint: '[--wait|--background] [--base <ref>] [--scope auto|working-tree|branch] [focus ...]'
allowed-tools: Read, Glob, Grep, Bash(node:*), Bash(git:*), Bash(ls:*), AskUserQuestion
---

NOTE: this is a repo-local command for g2g development, NOT part of the
shipped plugin. It requires the third-party `openai-codex` plugin to be
installed (`~/.claude/plugins/cache/openai-codex/...`); without it the
command reports failure and does nothing.

Project wrapper around the codex plugin's `/codex:adversarial-review`, without
`disable-model-invocation` so it can run as the standing PR-review step: after
`/g2g:build` or `/g2g:improve` opens a (never-merged) PR, run this against the
PR branch, then a human picks which findings to fix before merge.

This is a design-critique pass — it challenges whether the chosen approach is
right, what assumptions it depends on, and where the design fails under
real-world conditions. It is complementary to the g2g verifier (completion
gate), not a replacement.

Raw arguments: `$ARGUMENTS`

Constraints (do not weaken):
- Review-only. Do not fix issues, apply patches, or imply changes are coming.
- Return Codex's output verbatim, ordered by severity, paths/lines exactly as
  reported. Do not paraphrase, summarize, or add commentary around it.
- After presenting findings, STOP and ask which issues, if any, to fix.
  Auto-applying fixes — even obvious ones — is forbidden.
- If Codex was never successfully invoked, report the failure. Never substitute
  your own review.

Execution mode:
- `--wait` in arguments → foreground.
- `--background` in arguments → run the command below with `run_in_background: true`,
  then tell the user to check `/codex:status`; do not wait this turn.
- Neither → default to background for anything larger than 1–2 files.

Run (resolve the newest installed codex plugin — the version dir moves on
updates, so do not hardcode it):

```bash
CODEX_ROOT="$(ls -d "$HOME"/.claude/plugins/cache/openai-codex/codex/*/ | sort -V | tail -1)"
node "${CODEX_ROOT}scripts/codex-companion.mjs" adversarial-review "$ARGUMENTS"
```

The companion parses `--wait`/`--background` and supports working-tree review,
branch review, and `--base <ref>`; it does not support `--scope staged|unstaged`.
Free focus text after the flags is passed through — preserve the user's
arguments exactly.
