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

   Post-verifier staleness flag (read-only, informational only): first
   get the default branch — strip the `origin/` prefix from
   `git symbolic-ref --short refs/remotes/origin/HEAD` — and the
   current branch via `git branch --show-current`. If the
   symbolic-ref command errors (no `origin/HEAD`, e.g. a fresh clone
   or `git init`) or the current branch is empty (detached HEAD), the
   check is unavailable: report "staleness check unavailable" once
   and skip the flag for every spec — never guess which branch is
   default and never flag on a guess. If the current branch equals
   the default branch, also skip this flag entirely for every spec
   (this is the default branch, not staleness). Otherwise, for each
   spec whose top-level `verifier` field is non-null, run one command
   from the repo root:
   `git log --oneline "$(git log -1 --format=%H -- <spec-path>)..HEAD" -- . ":(exclude)<spec-path>"`
   (using that spec's own path in both places) and count the returned
   lines. This anchors on the commit that last touched the spec file —
   the PASS-recording `chore(<task>): complete`/verifier-write commit —
   and counts only commits strictly after it that touch paths other
   than the spec, so it cannot count commits made before the PASS was
   recorded. If no commit has ever touched the spec file, the inner
   lookup returns nothing, the range is invalid, and the command
   fails — treat that the same as an unavailable check: report
   "staleness check unavailable" for that spec and add no flag, never
   a guess. When the count is 1 or more, append "record may trail
   branch (N post-verifier commits)" to that spec's summary line,
   where N is the count. When the count is 0, add no flag. This flag
   changes nothing and recommends nothing beyond the flag text itself —
   a flagged spec counts as "stuck" for the no-recommendations rule
   below.
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
   last) — for each: `date`, `outcome`, `pr`, `turns`, and the
   selected/addressed counts (lengths of that entry's `selected` and
   `addressed` arrays). If the file is absent, report "no
   review-output/ticks.json (no improve cycles have completed yet)".
   If it exists but fails to parse as JSON or is not an array, report
   that honestly instead of guessing its contents. Then check the tick
   journal
   `"$(git rev-parse --path-format=absolute --git-common-dir)/g2g-ticks.jsonl"`
   (read-only). The journal holds up to TWO records per tick — a
   `launched` record (with `pid`) and a terminal record — so count
   TICKS, never raw lines: group records by `tickId`, drop every
   `tickId` already present in `review-output/ticks.json`, and
   classify each remaining tick with the same rules reconciliation
   uses (improve-cycle.md Phase I-5 step 2a):
   - a terminal record exists → completed, awaiting reconciliation;
   - launch record only, its `pid` alive per `kill -0` → RUNNING now
     (not awaiting anything — do not count it as unreconciled);
   - launch record only, pid dead or missing → killed-or-crashed,
     awaiting reconciliation.
   Report the completed-awaiting and killed-or-crashed-awaiting counts
   (and any RUNNING ticks alongside step 5's worktree view). When
   `ticks.json` is absent, phrase the two sources consistently: absent
   ledger plus a journal with unreconciled ticks means "no improve
   cycle has RECONCILED yet — N ticks recorded in the journal await
   the first PR-producing cycle", never "no improve cycles have
   completed yet" beside a nonzero journal count. A missing journal
   means no ticks have run on this machine; say so rather than
   guessing.
Summarize in a short table. No recommendations unless something is stuck
(blocked tasks, draft partial PRs, conflicts).
