You are producing the report for `/g2g:status`, which is read-only and
changes nothing. Per its rules: report the goal file's fields verbatim
when one exists (or "None active" when absent); report spec task
counts from the evidence script's counts line; list open PRs filtered
to `g2g/*` branches exactly as returned; report the tick ledger honestly,
including the exact fallback wording when it is absent; and make no
recommendations unless something is actually stuck (blocked tasks,
draft partial PRs, conflicts).

Using ONLY the raw data below — do not infer, guess, or add any field,
task, PR, or history entry not shown here — produce the status report.

1. `.g2g-goal` (repo root) contains exactly:
   `{"version": 1, "ownerToken": "g2g-4821-1737830000", "specPath":
   "specs/widget-cleanup.json", "taskTotal": 6, "turnCap": 12,
   "hoursCap": 2, "buildStart": "2026-08-09T14:00:00Z"}`

2. Running `g2g-evidence.sh specs/widget-cleanup.json` prints exactly:
   ```
   tasks: 6 total | 4 passed | 0 in_progress | 1 pending | 1 blocked
   verdict: incomplete [tasks 4/6]
   ```

3. `gh pr list --state open --json headRefName,title,url,isDraft`
   filtered to `g2g/*` branches returns exactly:
   `[{"headRefName":"g2g/widget-cleanup","title":"g2g: widget-cleanup",
   "url":"https://github.com/acme/widgets/pull/42","isDraft":false}]`

4. `git branch --list 'g2g/*'` shows only `g2g/widget-cleanup`.
   `git worktree list` shows only the main worktree — no entries
   containing "g2g".

5. `review-output/ticks.json` does not exist on disk.

Produce the status summary now.
