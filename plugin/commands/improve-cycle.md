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
2. Candidates: findings with `addressed` null-or-absent, severity !=
   info, and confidence != low (absent confidence = medium — legacy
   findings stay eligible; low-confidence findings need investigation,
   not an autonomous fix, and stay open for a human). Order critical →
   high → medium → low; within a severity, smaller `effort` first
   (small → medium → large — a verifiable small fix is a better use of
   a capped build than a sprawling one); remaining ties: lower id
   first.
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
2. Reconcile the tick ledger into the tracked
   `review-output/ticks.json`. The ledger entry shape (used both here
   and in the journal below) is:
   `{"tickId": "<this run's RUNDIR basename, else
   improve-<launch ISO 8601 timestamp>>", "date": "<today,
   YYYY-MM-DD>", "outcome": "<build.md's terminal state, e.g.
   complete|partial>", "reason": "<one line: why the tick ended in
   that state>", "pr": <PR number or null>, "turns": <turns build.md's
   final report used>, "selected": [<finding ids selected in Phase
   I-2, possibly none addressed>], "addressed": [<ids marked addressed
   in step 1 — subset of selected>]}`. `selected` and `addressed` are
   recorded SEPARATELY on purpose: a tick that selected three findings
   and addressed one is a data point budget tuning needs, and an
   entry listing only successes would hide it.
   Read `review-output/ticks.json`. If it is absent, start from a new
   empty JSON array `[]`. If it exists and parses as a JSON array, use
   it as the base. If it exists but does NOT parse as a JSON array
   (malformed JSON, or valid JSON of another type), this is a BLOCKING
   ledger error: leave the file byte-for-byte unchanged, skip steps 2a
   and 2b entirely, and report that the tracked ledger needs human
   recovery — never substitute an empty or reconstructed array for a
   malformed tracked file, because the committed history it held (which
   may include ticks from other machines whose journals this machine
   has never seen) would be overwritten by a partial local view. This
   tick's entry is not lost: the Cleanup journal append still records
   it, and reconciliation resumes on the first tick after a human
   repairs the ledger. On this branch, step 3's commit carries the
   `findings.json` update alone. Otherwise:
   a. Fold in prior unreconciled ticks: read the machine-local journal
      `"$(git rev-parse --path-format=absolute --git-common-dir)/g2g-ticks.jsonl"`
      (one JSON entry per line; the common git dir belongs to the main
      checkout, is shared by every worktree, survives worktree
      removal, and is never tracked). The journal holds two record
      kinds per tick: a `launched` record written by the launcher at
      spawn (carrying extra `rundir`/`pid` fields) and a terminal
      record written by Cleanup. Group lines by `tickId`, then for
      each `tickId` not already present in the array, in journal
      order:
      - a terminal record exists → append it (drop `rundir`/`pid` if
        present; ticks.json entries keep the eight-field shape);
      - ONLY a `launched` record exists → check its `pid` with
        `kill -0`: alive means the tick is still running — skip it;
        dead or missing means the tick was killed by the outer
        cap/budget, crashed, or was manually killed before its Cleanup
        could write a terminal record — append
        `{"tickId", "date" (the launch record's), "outcome":
        "killed-or-crashed", "reason": "launched but no terminal
        record — outer cap kill, crash, or manual kill", "pr": null,
        "turns": null, "selected": [], "addressed": []}`.
      A missing journal file or an unparsable journal line is reported
      and skipped, never fatal.
   b. Append this tick's own entry (shape above), then write the
      array back to `review-output/ticks.json`.
3. Commit both files together in ONE commit:
   `git add review-output && git commit -m "chore: mark findings addressed by PR #<number>"`
   — the ticks.json ledger entries ride inside this SAME reconciliation
   commit, never a separate one.
4. Push that ONE commit to the same, already-open PR branch
   (`git push`). This is the improve cycle's single sanctioned post-PR
   push — the backlog update (including the new ledger entries) must
   land inside the PR that it references. Nothing else is ever pushed
   after it.
If no PR exists (gh unavailable, partial stop), skip all four steps —
write nothing to `review-output/findings.json` or `ticks.json`, and
push nothing. The findings stay open for the next cycle. The tick is
still durably recorded: the Cleanup section's journal append runs on
every terminal path, and the next PR-producing tick's step 2a folds it
into the tracked ledger.

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
2. Journal this tick — EVERY terminal path (success, empty, abort,
   partial), no exceptions: append exactly one JSON line, the ledger
   entry shape from Phase I-5 step 2 (`tickId`, `date`, `outcome`,
   `reason`, `pr` — null when none, `turns`, `selected`, `addressed`),
   best-effort filled from whatever this cycle actually did, to
   `"$(git rev-parse --path-format=absolute --git-common-dir)/g2g-ticks.jsonl"`.
   The common git dir is the main checkout's, shared across worktrees
   and never tracked, so this write is durable without touching the
   tracked tree or adding any push. This journal is what keeps the
   ledger honest: without it, only PR-producing ticks would ever be
   durably recorded and the tracked ledger would be a success-biased
   sample — the failed and empty ticks are exactly the ones budget
   tuning needs to see. A PR tick's entry is also already in
   `ticks.json` (Phase I-5 step 2b); the matching `tickId` is what
   stops the next reconciliation from double-counting it. If the
   append itself fails (unwritable common dir), print the entry in the
   final message and say the journal write failed.
3. Remove the pid sidecar `"$RUNDIR/tick.pid"` LAST, if present
   (foreground and routine runs have none) — its absence tells the
   launcher's next tick this cycle ended.
4. Final message: what happened (PR URL, partial, empty, or abort),
   which findings were selected and which were addressed/stale-marked,
   the journaled ledger entry (echo the JSON line from step 2), and
   that the worktree can be removed with `git worktree remove <path>`
   and the now-empty run root with `rm -rf "$RUNDIR"` once the PR is
   merged or the work inspected.
