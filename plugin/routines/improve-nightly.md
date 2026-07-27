# G2G nightly improve — routine template

Register with the scheduler (e.g. `/schedule "nightly at 02:00" <the
Instructions block below>`). The routine runs Claude in a fresh clone of
the repository; platform fact: whether marketplace-installed plugins are
available in that clone is UNCONFIRMED, so the instructions verify and
fall back to the repo's own plugin directory rather than assuming.

## Instructions (use as the routine prompt)

You are a scheduled G2G improvement tick running in a fresh clone.

1. Preflight: confirm `.claude/settings.json` exists and contains a
   Stop hook (repos that track it are covered; otherwise copy
   `plugin/hooks/hooks.json` to `.claude/settings.json` — plugin-shipped
   hooks do not fire under isolated setting sources).
2. If the `/g2g:improve` command is available, run:
   `/g2g:improve --wait`
3. If it is NOT available but the repo contains `plugin/commands/
   improve-cycle.md` (this repo ships its plugin in-tree), run the
   launcher's spawn directly and wait for it. Create the run root
   unpredictably and owner-only (never a bare `date`-derived /tmp
   path — that is symlink-plantable and world-readable) and put the
   worktree inside it:
   - `RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/g2g-improve-XXXXXXXX")`
     (mode 0700 by construction)
   - `WT="$RUNDIR/worktree"`
   - `git worktree add "$WT" -b "g2g/improve-$(basename "$RUNDIR")" main`
   - `mkdir -p "$WT/.claude" && cp plugin/hooks/hooks.json
     "$WT/.claude/settings.json"` (skip the copy if the file
     materialized)
   - Cycle model: read `.claude/g2g.json` → `models.improveCycle`,
     defaulting to `sonnet` when the file or field is absent — same
     resolution as the `/g2g:improve` launcher, so a nightly tick costs
     the same as an interactively-launched one. As in the launcher,
     `models.improveCycle` does not support `inherit` (a spawned
     headless process has no session to inherit from, and a routine has
     no invoking model at all): if the resolved value is exactly
     `inherit`, STOP and report the misconfiguration — never spawn on
     the machine's CLI default.
   - from inside the worktree (`cd "$WT"`):
     `claude -p "/g2g:improve-cycle" --plugin-dir "$PWD/plugin"
     --setting-sources project --permission-mode acceptEdits
     --allowedTools "Agent,Bash,Read,Write,Edit,Glob,Grep"
     --max-turns 50 --max-budget-usd 25 --model <cycleModel>`
   (the cycle's instructions come from the clone's own plugin dir — no
   inlined drift; this step runs in the foreground and blocks until
   the cycle exits, so no pid/log sidecar is needed)
4. If neither is possible, STOP and report "g2g plugin unavailable in
   routine environment" — do not improvise the cycle.
5. Report: the PR URL (or the honest failure/empty-cycle outcome), the
   caps used, and which findings were addressed.
