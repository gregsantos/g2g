---
description: Launch one bounded, headless, worktree-isolated improve cycle (review → fix-spec → build → PR)
argument-hint: '[--wait]'
---
# /g2g:improve — improve-cycle launcher

Launch one improvement tick: $ARGUMENTS

You are a LAUNCHER. The work happens in a fresh git worktree, in a
separate capped headless claude process. You never review or build
anything yourself, and the cycle never runs in this session's checkout —
a tick that cannot get its worktree FAILS with the error; there is no
fallback.

## Opt-in gate — improve never runs by default
0. Read `.claude/g2g.json` → `improve.enabled`. Unless it is exactly
   `true`, STOP without launching anything and explain: the improve
   flywheel feeds review-finding text into spec criteria executed by
   Bash-capable builders (backlog finding F-001), so it must be
   explicitly enabled — and only on repos whose contents you trust.
   To enable it, set `"improve": { "enabled": true }` in
   `.claude/g2g.json` and re-run. Never enable it yourself; that edit
   is the user's.

## Busy checks — skip rather than stack
1. For each `git worktree list` entry whose path contains
   `g2g-improve-` (runtime files are SIDECARS: pid at `<path>.pid`,
   log at `<path>.log` — never inside the worktree, where they would
   trip build.md's clean-tree preflight):
   - `<path>.pid` exists and its PID is alive (`kill -0`): a tick is
     RUNNING — report path/branch/pid and STOP.
   - pid sidecar exists, process dead: a CRASHED tick — report the
     path and branch, tell the human to inspect it and remove it with
     `git worktree remove --force <path>` (plus the sidecars) when
     done, and STOP. Never remove it yourself.
   - no pid sidecar: the cycle finished — if `git -C <path> status
     --porcelain` is empty, run `git worktree remove <path>` and
     delete the leftover `<path>.log` (its work is pushed or it did
     nothing) and continue; otherwise report the leftover state and
     STOP.
2. `gh pr list --state open --json headRefName`: any open PR on a
   `g2g/improve-*` branch → report it and STOP (the previous cycle's
   PR awaits human review; don't pile on). If gh fails, warn that this
   check was skipped and continue.

## Launch
1. Caps: `.claude/g2g.json` → `defaultBudgets.improveTurns` (else 50)
   and `defaultBudgets.improveUsd` (else 25). (`improveHours` is
   approximated by the turn cap — no wall-clock flag exists.)
2. `TS=$(date +%Y%m%d-%H%M%S)`; `WT=/tmp/g2g-improve-$TS`;
   `git worktree add "$WT" -b "g2g/improve-$TS" <default-branch>`.
   Any failure here fails the tick — report the git error verbatim.
3. Stop-hook carry (plugin hooks are inert under
   `--setting-sources project`): if `$WT/.claude/settings.json` does
   not exist, `mkdir -p "$WT/.claude" && cp
   "${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json" "$WT/.claude/settings.json"`.
4. Spawn from inside $WT, as one Bash command run through your Bash
   tool's background facility — NEVER nohup/disown/setsid (orphaned
   background runs are the incident class this design exists to
   prevent; the child must stay harness-visible and killable). Pid and
   log are SIDECARS next to the worktree, never inside it:
   `cd "$WT" && claude -p "<SPAWN_PROMPT>"
   --plugin-dir "${CLAUDE_PLUGIN_ROOT}" --setting-sources project
   --permission-mode acceptEdits
   --allowedTools "Agent,Bash,Read,Write,Edit,Glob,Grep"
   --max-turns <improveTurns> --max-budget-usd <improveUsd>
   --output-format stream-json --verbose
   > "$WT.log" 2>&1 & echo $! > "$WT.pid"`
   where `<SPAWN_PROMPT>` is `/g2g:improve-cycle`.
5. Without `--wait`: report the worktree path, branch, PID, log path
   (`$WT.log`), and caps, plus how to watch it (`tail -f "$WT.log"`,
   `/g2g:status`) and how to kill it (`kill <pid>`). The spawned
   tick is a plain `&` child and SURVIVES the end of the session that
   launched it (spike verdict: CHILD-SURVIVES) — its lifetime is
   bounded only by its caps, so the pid sidecar is the mandatory kill
   switch: the tick must stay killable (`kill <pid>`) and visible to
   `/g2g:status` at all times. From `/loop`, the session persists
   between ticks either way.
   With `--wait`: poll `kill -0 <pid>` with short sleeps until it
   exits, then report the log's final result, the PR URL if one was
   created, and apply the finished-worktree rule from Busy checks 1
   (remove the worktree and log only if the pid sidecar is gone and
   the worktree status is clean).
