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
   and `defaultBudgets.improveUsd` (else 25). Both must be positive
   JSON numbers — any other type or shape FAILS the launch; they cross
   into the spawn command line. (`improveHours` is
   approximated by the turn cap — no wall-clock flag exists.)
   Cycle model: `.claude/g2g.json` → `models.improveCycle`, defaulting
   to `sonnet` when the file or field is absent. `models.improveCycle`
   does not support `inherit`: a spawned headless process has no
   session to inherit from — a spawn without `--model` silently selects
   the machine's CLI default (possibly the most expensive tier), and
   passing `inherit` literally fails the spawn. If the resolved value
   is exactly `inherit`, FAIL the launch now with that explanation and
   tell the operator to set an explicit model or remove the field for
   the `sonnet` default. Every other value is untrusted input crossing
   into a shell command: it must be a JSON string matching
   `^[A-Za-z0-9][A-Za-z0-9._-]*$` (alphanumeric start; no whitespace,
   quotes, leading dashes, or shell metacharacters — a value like
   `sonnet --max-budget-usd 1000` would otherwise smuggle extra CLI
   flags past the caps). Any other type or shape (null, number, array,
   empty, pattern miss): FAIL the launch quoting the offending value —
   never interpolate it. Set `CYCLE_MODEL` to the validated value for
   step 4. This is distinct from
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
3. No Stop-hook carry is needed, and copying one in is forbidden. The
   spawn below passes `--plugin-dir`, which loads the plugin and its own
   Stop hook even under `--setting-sources project` (verified against CC
   2.1.220; earlier versions of this file claimed otherwise). The hook
   must stay in the plugin so fixes reach every run — a copy in a
   worktree is a copy nothing can patch. Copy NOTHING into
   `$WT/.claude/`; the worktree is a checkout, so any declarations the
   repo tracks are already there.
4. Spawn from inside $WT, as one Bash command run through your Bash
   tool's background facility — NEVER nohup/disown/setsid (orphaned
   background runs are the incident class this design exists to
   prevent; the child must stay harness-visible and killable). Pid and
   log are SIDECARS in `$RUNDIR`, next to the worktree, never inside
   it.
   BILLING — resolve which credentials the tick will use, and say so
   before spawning. If `G2G_IMPROVE_API_KEY` is set and non-empty in
   the launching environment, prefix the spawn command with the env
   assignment `ANTHROPIC_API_KEY="$G2G_IMPROVE_API_KEY" ` immediately
   before `claude` — always the quoted variable expansion, never the
   value substituted into the command text, and never print or log
   the value itself — and report `billing: G2G_IMPROVE_API_KEY
   (Console key, improve-scoped)`. Otherwise, if `ANTHROPIC_API_KEY`
   is already present in the environment, add no prefix — the
   spawned CLI inherits and uses it (headless mode always prefers an
   API key over the stored login) — and report `billing: inherited
   ANTHROPIC_API_KEY`. Otherwise add no prefix and report `billing:
   logged-in Claude Code account`. This override applies only to this
   spawn; it never alters the launching session's own credentials.
   `cd "$WT" && claude -p "<SPAWN_PROMPT>"
   --plugin-dir "${CLAUDE_PLUGIN_ROOT}" --setting-sources project
   --permission-mode acceptEdits
   --allowedTools "Agent,Bash,Read,Write,Edit,Glob,Grep"
   --max-turns <improveTurns> --max-budget-usd <improveUsd>
   --model "$CYCLE_MODEL"
   --output-format stream-json --verbose
   > "$RUNDIR/tick.log" 2>&1 & echo $! > "$RUNDIR/tick.pid"`
   where `<SPAWN_PROMPT>` is `/g2g:improve-cycle` and `$CYCLE_MODEL`
   holds the value resolved AND validated in step 1 — always the
   quoted variable expansion, never a raw substitution of config text
   into the command (`inherit` and pattern misses never reach this
   point; step 1 fails the launch on them).
   LAUNCH RECORD — immediately after the spawn, from the launching
   session (which runs OUTSIDE the capped child), append one JSON line
   to the tick journal
   `"$(git rev-parse --path-format=absolute --git-common-dir)/g2g-ticks.jsonl"`:
   `{"tickId": "$ID", "date": "<today, YYYY-MM-DD>", "outcome":
   "launched", "reason": "tick spawned; terminal record pending",
   "pr": null, "turns": null, "selected": [], "addressed": [],
   "rundir": "$RUNDIR", "pid": <the pid just written to tick.pid>}`.
   This exists because the tick's own Cleanup is the terminal-record
   writer and the outer `--max-turns`/`--max-budget-usd` kill strikes
   BEFORE Cleanup can run: without a launch record written from
   outside the capped process, a capped or crashed tick would leave no
   durable trace and the ledger would quietly regain the success bias
   it exists to eliminate. Reconciliation (improve-cycle.md Phase I-5)
   pairs launch records with terminal records by `tickId` and folds
   unpaired-and-dead ones as `killed-or-crashed`. Launch-record
   persistence is MANDATORY — verify the append actually landed (the
   write exited 0 and `tail -n 1` of the journal shows this `tickId`).
   If it did not: the tick must not run unjournaled, because the
   launch record exists precisely for the tick that dies before its
   own Cleanup — an unjournaled tick killed by the outer cap would
   vanish, restoring the success bias the ledger exists to eliminate.
   Terminate the just-spawned child now (`kill <pid from tick.pid>`,
   then wait for it to exit), PRESERVE the worktree and `$RUNDIR`
   sidecars untouched for inspection, and abort the launch with the
   journal-write error reported verbatim (a full disk or unwritable
   git common dir is the concrete case). Never proceed past this
   point with a spawned tick and no durable launch record.
5. Without `--wait`: report the worktree path, branch, PID, log path
   (`$RUNDIR/tick.log`), caps, and the billing line from step 4, plus
   how to watch it
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
