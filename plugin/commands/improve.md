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
   `g2g-improve-`, FIRST classify its layout — the two coexist during
   any upgrade across 0.2.5, so never assume one. The worktree path's
   OWN basename decides:
   - **Current layout (0.2.5+):** basename is exactly `worktree` AND its
     parent's basename matches `g2g-improve-*`. Then `<RUNDIR>` = that
     parent — the `mktemp -d` run root from Launch step 2 — and the
     SIDECARS live inside it, next to (never inside) the worktree, where
     they would trip build.md's clean-tree preflight: pid at
     `<RUNDIR>/tick.pid`, log at `<RUNDIR>/tick.log`. Its cleanup removes
     the run root whole (`rm -rf "<RUNDIR>"`) — it holds only the
     worktree and those sidecars.
   - **Legacy layout (pre-0.2.5):** the path's OWN basename matches
     `g2g-improve-*` (the worktree IS the timestamped dir, with no
     `worktree` child). Its sidecars sit BESIDE it: pid at `<path>.pid`,
     log at `<path>.log`. There is NO run root to recurse into — its
     cleanup is `git worktree remove <path>` then
     `rm -f "<path>.pid" "<path>.log"` ONLY. Its parent is the shared
     temp base (`/tmp` or `$TMPDIR`); treating that as a run root and
     `rm -rf`-ing it would destroy unrelated user data.
   HARD GUARD: only ever `rm -rf` a directory that is a validated
   `g2g-improve-*` run root of the expected shape — its basename matches
   `g2g-improve-*`, it is not `/tmp` or `$TMPDIR` itself, and its
   children are a SUBSET of the documented contents: `worktree`,
   `tick.pid`, `tick.log`, `selected.json` (the worktree child may
   already be absent when `git worktree remove` ran first — that is the
   normal cleanup order, not an anomaly). Any child outside that set
   means the directory is not certainly ours: report it and STOP the
   launch — never delete anything you could not classify. A matching
   entry that fits NEITHER layout above (unexpected shape) is likewise
   reported and STOPS the launch.
   Then, using that layout's pid-sidecar path:
   - pid sidecar exists and its PID is alive (`kill -0`): a tick is
     RUNNING — report path/branch/pid and STOP.
   - pid sidecar exists, process dead: a CRASHED tick — report the
     path and branch, tell the human to inspect it and remove it (current:
     `git worktree remove --force <path>` then `rm -rf "<RUNDIR>"`;
     legacy: `git worktree remove --force <path>` then
     `rm -f "<path>.pid" "<path>.log"`) when done, and STOP. Never remove
     it yourself.
   - no pid sidecar: the cycle finished — if `git -C <path> status
     --porcelain` is empty, remove it with that layout's cleanup (current:
     `git worktree remove <path>` then `rm -rf "<RUNDIR>"`; legacy:
     `git worktree remove <path>` then `rm -f "<path>.pid" "<path>.log"`)
     — its work is pushed or it did nothing — and continue; otherwise
     report the leftover state and STOP.
2. `gh pr list --state open --json headRefName`: any open PR on a
   `g2g/improve-*` branch → report it and STOP (the previous cycle's
   PR awaits human review; don't pile on). If gh fails, warn that this
   check was skipped and continue.

## Launch
1. Caps: `.claude/g2g.json` → `defaultBudgets.improveTurns` (else 50)
   and `defaultBudgets.improveUsd` (else 25). (`improveHours` is
   approximated by the turn cap — no wall-clock flag exists.)
   Cycle model: `.claude/g2g.json` → `models.improveCycle`, defaulting
   to `sonnet` when the file or field is absent. `models.improveCycle`
   does not support `inherit`: a spawned headless process has no
   session to inherit from — a spawn without `--model` silently selects
   the machine's CLI default (possibly the most expensive tier), and
   passing `inherit` literally fails the spawn. If the resolved value
   is exactly `inherit`, FAIL the launch now with that explanation and
   tell the operator to set an explicit model or remove the field for
   the `sonnet` default. This is distinct from
   `models.builder`/`models.verifier`, which only route dispatches
   *within* the cycle (subagent dispatches, where `inherit` is real
   inheritance) — `models.improveCycle` is what the whole spawned
   process (orchestrator + review subagents + spec generation, plus any
   builder/verifier dispatch that doesn't itself set a model) runs on.
2. Create the run root unpredictably and owner-only, then the
   worktree inside it (never a bare `date`-derived /tmp path — that
   is a symlink-plantable, world-readable location):
   `RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/g2g-improve-XXXXXXXX")`
   (mode 0700 by construction); `ID=$(basename "$RUNDIR")`;
   `WT="$RUNDIR/worktree"`;
   `git worktree add "$WT" -b "g2g/improve-$ID" <default-branch>`.
   Any failure here fails the tick — report the git error verbatim.
3. Stop-hook carry (plugin hooks are inert under
   `--setting-sources project`): if `$WT/.claude/settings.json` does
   not exist, `mkdir -p "$WT/.claude" && cp
   "${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json" "$WT/.claude/settings.json"`.
4. Spawn from inside $WT, as one Bash command run through your Bash
   tool's background facility — NEVER nohup/disown/setsid (orphaned
   background runs are the incident class this design exists to
   prevent; the child must stay harness-visible and killable). Pid and
   log are SIDECARS in `$RUNDIR`, next to the worktree, never inside
   it:
   `cd "$WT" && claude -p "<SPAWN_PROMPT>"
   --plugin-dir "${CLAUDE_PLUGIN_ROOT}" --setting-sources project
   --permission-mode acceptEdits
   --allowedTools "Agent,Bash,Read,Write,Edit,Glob,Grep"
   --max-turns <improveTurns> --max-budget-usd <improveUsd>
   --model <cycleModel>
   --output-format stream-json --verbose
   > "$RUNDIR/tick.log" 2>&1 & echo $! > "$RUNDIR/tick.pid"`
   where `<SPAWN_PROMPT>` is `/g2g:improve-cycle` and `<cycleModel>` is
   the `models.improveCycle` value resolved and validated in step 1
   (`inherit` never reaches this point — step 1 fails the launch on
   it).
5. Without `--wait`: report the worktree path, branch, PID, log path
   (`$RUNDIR/tick.log`), and caps, plus how to watch it
   (`tail -f "$RUNDIR/tick.log"`, `/g2g:status`) and how to kill it
   (`kill <pid>`). The spawned
   tick is a plain `&` child and SURVIVES the end of the session that
   launched it (spike verdict: CHILD-SURVIVES) — its lifetime is
   bounded only by its caps, so the pid sidecar is the mandatory kill
   switch: the tick must stay killable (`kill <pid>`) and visible to
   `/g2g:status` at all times. From `/loop`, the session persists
   between ticks either way.
   With `--wait`: poll `kill -0 <pid>` with short sleeps until it
   exits, then report the log's final result, the PR URL if one was
   created, and apply the finished-worktree rule from Busy checks 1
   (remove the worktree and run root only if the pid sidecar is gone
   and the worktree status is clean).
