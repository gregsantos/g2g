Read `plugin/commands/status.md` — the shipped `/g2g:status` command in
this repository — and produce the status report it specifies, applied
to the fixture repository state below. Follow the command file as
written: what to report, the exact fallback wordings, and when
recommendations are (and are not) allowed all come from that file, not
from this prompt.

Using ONLY the raw fixture data below as the repository state — do not
infer, guess, or add any field, task, PR, or history entry not shown
here — produce the status report.

1. `.g2g-goal` (repo root) contains exactly:
   `{"version": 1, "ownerToken": "g2g-4821-1737830000", "specPath":
   "specs/widget-cleanup.json", "taskTotal": 6, "turnCap": 12,
   "hoursCap": 2, "buildStart": "2026-08-09T14:00:00Z"}`

2. Running `g2g-evidence.sh specs/widget-cleanup.json` prints exactly:
   ```
   tasks: 6 total | 4 passed | 0 in_progress | 1 pending | 1 blocked
   verdict: incomplete [tasks 4/6]
   ```
   (`specs/widget-cleanup.json` is the only spec file besides
   `example.json`.)

3. `gh pr list --state open --json headRefName,title,url,isDraft`
   filtered to `g2g/*` branches returns exactly:
   `[{"headRefName":"g2g/widget-cleanup","title":"g2g: widget-cleanup",
   "url":"https://github.com/acme/widgets/pull/42","isDraft":false}]`

4. `git branch --list 'g2g/*'` shows only `g2g/widget-cleanup`.
   `git worktree list` shows only the main worktree — no entries
   containing "g2g".

5. `review-output/ticks.json` does not exist on disk, and the tick
   journal in the git common dir does not exist either.

Produce the status summary now.
