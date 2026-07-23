---
description: One bounded improve cycle — review, select, fix-spec, mini-build, PR. Internal; run headlessly in a g2g/improve-* worktree by /g2g:improve.
---
# /g2g:improve-cycle — the improve unit of work

You are running ONE bounded improvement cycle, headlessly, inside a
dedicated git worktree (or a routine's fresh clone) prepared by
/g2g:improve. Hard caps (--max-turns, --max-budget-usd) are already on
this process.

## Guard — before anything else
The current branch must match `g2g/improve-*` and `git status` must be
clean. If either fails — you are in someone's real checkout, or on a
default branch — ABORT immediately with a clear message and change
NOTHING. Do not create a branch to fix this; the launcher owns setup.

Compute `RUNDIR="$(dirname "$(pwd)")"` once, now — the launcher's
`mktemp -d` run root (unpredictable, owner-only) one level above this
worktree. Every sidecar this cycle writes (selected-findings scratch
file, and the pid sidecar the launcher already wrote) lives directly
under `$RUNDIR`, never inside the worktree.

Then check `.claude/g2g.json` → `improve.enabled`. Unless it is exactly
`true`, ABORT: the improve flywheel is strictly opt-in (review-finding
text flows into spec criteria executed by Bash-capable builders,
backlog finding F-001). This check repeats the launcher's gate on
purpose — a routine or manual spawn can reach this command without
going through `/g2g:improve`.

## Phase I-1 — Review
Execute the full procedure in `${CLAUDE_PLUGIN_ROOT}/commands/review.md`
(Read it), no arguments — config-driven scope. Result: an updated
`review-output/findings.json` and report, uncommitted.

## Phase I-2 — Select
1. N = `.claude/g2g.json` → `defaultBudgets.improveFindings`, else 3.
1a. Reopen findings orphaned by rejected PRs: for each finding whose
   `addressed` is a PR number, check that PR's state
   (`gh pr view <number> --json state,mergedAt`). CLOSED without merge
   means the fix was rejected and never landed — reset that finding's
   `addressed` to null (it re-enters candidacy below) and note the
   reopen in the backlog commit message. MERGED or still OPEN findings
   keep their value. If gh fails, skip this step with a warning —
   never reset `addressed` without confirming the PR's state.
2. Candidates: findings with `addressed` null-or-absent and severity !=
   info, ordered critical → high → medium → low (ties: lower id first).
3. PR-overlap filter: `gh pr list --state open --json number,headRefName`;
   for each open `g2g/*` PR, `gh pr diff <number> --name-only`; drop
   any candidate whose `file` appears in any of those diffs (someone is
   already touching it). If gh fails (no GitHub remote), say so and
   skip this filter.
4. Revalidate each remaining candidate against the working tree: the
   cited file exists and the described symptom is still present at the
   cited location (read it). A candidate that fails revalidation is
   dropped AND marked in the backlog: `addressed: "stale-<today>"` —
   humans fix things too, and the next cycle must not re-chew it.
5. Take the top N. If ZERO remain: write the backlog only if step 4
   changed it, run the Cleanup section, and end with "improve: no
   actionable findings this cycle" — a successful empty cycle, not an
   error.

## Phase I-3 — Fix-spec
1. Write the selected findings (full objects, unmodified) to the
   sidecar scratch file `"$RUNDIR/selected.json"` (i.e.
   `<mktemp-run-root>/selected.json`, OUTSIDE the worktree — and under
   the launcher's owner-only run root, not the world-writable base of
   `/tmp` — so build.md's clean-tree preflight never sees it), shaped
   `{"findings": [...]}` — deleted in Cleanup.
2. Execute `${CLAUDE_PLUGIN_ROOT}/commands/spec.md`'s full procedure
   (Read it) with the input
   `--from-findings "$RUNDIR/selected.json"`. Name the spec's
   `project` field "Improve <today YYYY-MM-DD>"; if
   `specs/improve-<date>.json` already exists, append `-<HHMM>` to the
   project name and slug.
3. Commit the review artifacts NOW:
   `git add review-output && git commit -m "chore: review backlog for improve cycle"`
   — build.md's preflight requires a clean tree apart from the target
   spec file, and the backlog state that selected these findings
   belongs in the PR diff.
4. If spec generation aborts, run Cleanup and report the abort
   honestly. Never build without a validated spec.

## Phase I-4 — Build
Execute `${CLAUDE_PLUGIN_ROOT}/commands/build.md` (Read it) exactly, as
the orchestrator, with the generated spec path as its argument. You are
already on the `g2g/improve-*` branch — build.md keeps you on it and
commits the fresh spec via its Phase 1 step 3a. Every build.md rule
applies unchanged: caps, `.g2g-goal` lifecycle, script-produced
evidence, builder/verifier dispatches, single push at PR time, draft
partial PR on terminal stops, never merge, no attribution lines.

## Phase I-5 — Backlog reconciliation (ONLY if build.md reported a created PR)
1. In `review-output/findings.json`, set `addressed` to the PR number
   for every finding cited by tasks that were COMPLETED (status complete
   / passes true) (task descriptions carry "fixes F-xxx" per the
   fix-spec rules).
2. Commit: `chore: mark findings addressed by PR #<number>`.
3. Push that ONE commit to the same, already-open PR branch
   (`git push`). This is the improve cycle's single sanctioned post-PR
   push — the backlog update must land inside the PR that it
   references. Nothing else is ever pushed after it.
If no PR exists (gh unavailable, partial stop), skip all three steps
and say so — the findings stay open for the next cycle.

## Cleanup — every terminal path (success, empty, abort, partial)
1. Delete `"$RUNDIR/selected.json"` if present. For `.g2g-goal` /
   `.g2g-goal.lock`, never judge ownership or delete by hand — the lock
   helper `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh` is the sole
   implementation of build.md's ownership rules; route every case
   through it:
   - Both files absent (the usual case — build.md's terminal paths
     already released the pair): nothing to do.
   - The build THIS cycle ran armed a goal but crashed or aborted
     before its terminal release: run
     `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh release-terminal
     <that build's owner token>` — an abort after arming must not
     leave this session's Stop hook armed with no terminal path.
     Exit 5 means the pair is no longer that build's: delete neither
     file and report the anomaly.
   - Leftovers this cycle never armed (debris from an older run):
     reclaim-then-release with a fresh token —
     `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh acquire <fresh-token>`,
     and on exit 0 immediately
     `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh release-terminal
     <fresh-token>`. The helper reclaims
     only stale or malformed debris; exit 4 on the acquire means a
     LIVE foreign build owns this worktree (which the launcher's
     isolation should make impossible) — delete neither file and
     report the anomaly. Do NOT delete `.g2g-goal` alone while leaving
     a foreign live lock: that would disarm another build's goal.
   - Any exit 6/7/8 from the helper: fail closed — delete nothing,
     report the helper's output.
2. Remove the pid sidecar `"$RUNDIR/tick.pid"` LAST, if present
   (foreground and routine runs have none) — its absence tells the
   launcher's next tick this cycle ended.
3. Final message: what happened (PR URL, partial, empty, or abort),
   which findings were addressed/stale-marked, and that the worktree
   can be removed with `git worktree remove <path>` and the now-empty
   run root with `rm -rf "$RUNDIR"` once the PR is merged or the work
   inspected.
