---
description: Show G2G state — active goal, spec progress, open g2g/* PRs, worktrees
model: haiku
---
# /g2g:status

Report G2G state, read-only (change nothing):

1. Goal: check for a `.g2g-goal` file in the repo root. If it exists,
   read it as JSON and report the active goal as its fields — spec path,
   task total, turn and hours caps, build start, owner token. If it does
   not parse as JSON it is a pre-0.4.0 prose goal from a build armed
   before the upgrade; print it verbatim and say so. If absent, report
   "None active".
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
   contains `g2g-improve-`, locate its pid sidecar by layout — the same
   `<RUNDIR>` derivation as improve.md's Busy checks, since the two
   layouts coexist across a 0.2.5 upgrade. Current (0.2.5+): the worktree
   is `<RUNDIR>/worktree`, so `<RUNDIR>` is its PARENT directory (the
   `mktemp -d` run root) and the sidecars are `<RUNDIR>/tick.pid` and
   `<RUNDIR>/tick.log` — check `<RUNDIR>/tick.pid`, never `<path>.pid`.
   Legacy (pre-0.2.5): the path's own basename is `g2g-improve-*`, so the
   pid sits beside it at `<path>.pid`. Report path, branch, and state —
   RUNNING (pid sidecar present, process alive via `kill -0`), CRASHED
   (pid sidecar present, process dead — needs human inspection), or
   FINISHED (no pid sidecar; removable if clean).
6. Tick ledger: if `review-output/ticks.json` exists and parses as a
   JSON array, summarize its last 5 entries (most recently appended
   last) — for each: `date`, `outcome`, `pr`, `turns`, and `findings`
   count (length of that entry's `findings` array). If the file is
   absent, report "no review-output/ticks.json (no improve cycles have
   completed yet)". If it exists but fails to parse as JSON or is not
   an array, report that honestly instead of guessing its contents.
Summarize in a short table. No recommendations unless something is stuck
(blocked tasks, draft partial PRs, conflicts).
