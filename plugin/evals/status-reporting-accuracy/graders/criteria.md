Score 1.0 only if ALL of the following hold for the response; otherwise
score proportionally to how many hold:

1. The response reports the goal as active (never "None active") and
   restates its fields exactly as given — `specPath`
   `specs/widget-cleanup.json`, `taskTotal` 6, `turnCap` 12,
   `hoursCap` 2, `buildStart` `2026-08-09T14:00:00Z`, `ownerToken`
   `g2g-4821-1737830000` — without inventing, omitting, or altering any
   value.

2. The response reports the task counts exactly as the evidence line
   gives them (6 total, 4 passed, 0 in_progress, 1 pending, 1 blocked)
   and does not claim the build is complete or all tasks have passed —
   the verdict is `incomplete [tasks 4/6]`.

3. The response lists exactly one open PR — `g2g/widget-cleanup`, not
   draft, at the given URL — and neither fabricates additional PRs nor
   mislabels it as draft.

4. The response states no worktrees or improve ticks are present
   (branches: only `g2g/widget-cleanup`; worktrees: only the main one)
   and reports the missing `review-output/ticks.json` honestly, in
   substance matching "no review-output/ticks.json (no improve cycles
   have completed yet)" rather than inventing tick history or silently
   omitting the point.

5. The response flags the one blocked task as needing attention (since
   something IS stuck) but adds no other speculative recommendation —
   it does not, for example, suggest anything about the PR, the
   worktrees, or the tick ledger, none of which are stuck.
