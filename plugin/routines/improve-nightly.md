# G2G nightly improve — routine template

Register with the scheduler (e.g. `/schedule "nightly at 02:00" <the
Instructions block below>`). The routine runs Claude in a fresh clone of
the repository; platform fact: whether marketplace-installed plugins are
available in that clone is UNCONFIRMED, so the instructions verify and
fall back to the repo's own plugin directory rather than assuming.

## Instructions (use as the routine prompt)

You are a scheduled G2G improvement tick running in a fresh clone.

1. Preflight: confirm `.claude/settings.json` declares the g2g plugin
   under `enabledPlugins` (with its marketplace under
   `extraKnownMarketplaces`), which is what loads the plugin — and with
   it the plugin's own Stop hook — under `--setting-sources project`.
   Never copy the hook into the repo: it ships with the plugin so fixes
   arrive on update, and the spawn below also passes `--plugin-dir`.
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
   - Copy nothing into `$WT/.claude/` — the worktree is a checkout, so
     the repo's own declarations are already present, and the spawn
     passes `--plugin-dir`
   - Cycle model: read `.claude/g2g.json` → `models.improveCycle`,
     defaulting to `sonnet` when the file or field is absent — same
     resolution as the `/g2g:improve` launcher, so a nightly tick costs
     the same as an interactively-launched one. As in the launcher,
     `models.improveCycle` does not support `inherit` (a spawned
     headless process has no session to inherit from, and a routine has
     no invoking model at all): if the resolved value is exactly
     `inherit`, STOP and report the misconfiguration — never spawn on
     the machine's CLI default. Every other value must be a JSON
     string matching `^[A-Za-z0-9][A-Za-z0-9._-]*$` — it crosses into
     the spawn command line, so any other type or shape (null, number,
     array, empty, whitespace, metacharacters) STOPS the run with the
     offending value quoted, never interpolated. Set `CYCLE_MODEL` to
     the validated value.
   - `ID=$(basename "$RUNDIR")`
   - LAUNCH RECORD — before starting the child, print (into this
     routine's own durable output — its report/log is the only
     storage that survives the clone; never a tracked file, never a
     `git add`/`commit`/`push`) the improve-cycle launch entry, the
     same shape `plugin/commands/improve.md`'s LAUNCH RECORD step
     writes: `{"tickId": "$ID", "date": "<today, YYYY-MM-DD>",
     "outcome": "launched", "reason": "tick spawned; terminal record
     pending", "pr": null, "turns": null, "selected": [], "addressed":
     []}`. Retain this record verbatim for step 5's report — it is the
     only trace of this tick if the child is killed before it can
     print a terminal entry of its own.
   - from inside the worktree (`cd "$WT"`), run the capped child and
     retain its exit status — this step runs in the foreground and
     blocks until the child exits, so no pid/log sidecar is needed:
     `claude -p "/g2g:improve-cycle" --plugin-dir "$PWD/plugin"
     --setting-sources project --permission-mode acceptEdits
     --allowedTools "Agent,Bash,Read,Write,Edit,Glob,Grep"
     --max-turns 50 --max-budget-usd 25 --model "$CYCLE_MODEL"
     ; CHILD_EXIT=$?`
     (always the quoted variable expansion of the validated value,
     never raw config text substituted into the command). Retain
     `$CHILD_EXIT` and note whether the child's own output printed a
     terminal ledger entry (the JSON shape from improve-cycle.md's
     Cleanup, `outcome` one of `complete|partial|empty|abort`) — step
     5 needs both to report honestly.
   - billing, same rule as improve.md's launcher: when
     `G2G_IMPROVE_API_KEY` is set and non-empty in the routine's
     environment, prefix the command above with
     `ANTHROPIC_API_KEY="$G2G_IMPROVE_API_KEY" ` (quoted variable
     expansion only; never print the value) and note the billing mode
     in the report; with no key variables set, the run uses the
     environment's logged-in credentials. Cloud/scheduled environments
     (routines, managed agents, CI) typically have NO logged-in
     account: configure `G2G_IMPROVE_API_KEY` (or `ANTHROPIC_API_KEY`)
     as an environment secret there, or the spawn has no credentials
     and fails at the first model call.
   (the cycle's instructions come from the clone's own plugin dir — no
   inlined drift)
4. If neither is possible, STOP and report "g2g plugin unavailable in
   routine environment" — do not improvise the cycle.
5. Report: the PR URL (or the honest failure/empty-cycle outcome), the
   caps used, which findings were selected, and which were addressed.
   If step 3's fallback ran, this report is the ONLY durable record of
   the tick: the machine-local tick journal lives in the clone's git
   common dir and is DESTROYED with the clone. Print BOTH of the
   following into this report — never into a tracked file and never
   via any push:
   - the launch record printed in step 3, verbatim;
   - the terminal record: if the child's own output printed a terminal
     ledger entry (the JSON shape from improve-cycle.md's Cleanup,
     `outcome` one of `complete|partial|empty|abort`), quote that
     entry verbatim, exactly as before; otherwise — `$CHILD_EXIT`
     nonzero from the outer `--max-turns`/`--max-budget-usd` cap, a
     crash, or any other exit with no terminal entry in the child's
     output — synthesize and print a killed-or-crashed entry instead:
     `{"tickId": "$ID", "date": "<today, YYYY-MM-DD>", "outcome":
     "killed-or-crashed", "reason": "child exited with status
     $CHILD_EXIT and printed no terminal ledger entry", "pr": null,
     "turns": null, "selected": [], "addressed": []}`.
   PR-producing ticks are still recorded in the tracked
   `review-output/ticks.json` via reconciliation, but a fresh-clone
   environment cannot carry journal entries forward across runs, so
   the launch record plus the terminal-or-synthesized record printed
   here are what keep a cap-killed or crashed scheduled tick from
   vanishing.
