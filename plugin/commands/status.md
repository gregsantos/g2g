---
description: Show G2G state — active goal, spec progress, open g2g/* PRs, worktrees
model: haiku
---
# /g2g:status

Report G2G state, read-only (change nothing):

1. Goal: check for a `.g2g-goal` file in the repo root. If it exists,
   print its condition as the active goal. If absent, report "None
   active".
2. Specs: for each specs/*.json (skip example.json), run
   `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-evidence.sh <spec>` and show the
   counts line. Note: exit 3 means the spec lacks verificationCommands —
   report it as "unbuildable (no verificationCommands)".
3. PRs: `gh pr list --state open --json headRefName,title,url,isDraft`
   filtered to branches starting with g2g/ (report "gh unavailable" if
   the command fails; don't guess).
4. Branches/worktrees: `git branch --list 'g2g/*'` and
   `git worktree list` entries containing "g2g".
5. Improve ticks: for each `git worktree list` entry whose path
   contains `g2g-improve-`, locate its pid sidecar by layout (the two
   coexist across a 0.2.4 upgrade) — current (0.2.4+): basename
   `worktree` under a `g2g-improve-*` run root → pid at
   `<parent>/tick.pid`; legacy (pre-0.2.4): the path's own basename is
   `g2g-improve-*` → pid at `<path>.pid`. Report path, branch, and
   state — RUNNING (pid sidecar present, process alive via `kill -0`),
   CRASHED (pid sidecar present, process dead — needs human inspection),
   or FINISHED (no pid sidecar; removable if clean).
Summarize in a short table. No recommendations unless something is stuck
(blocked tasks, draft partial PRs, conflicts).
