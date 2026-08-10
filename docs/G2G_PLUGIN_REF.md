# G2G Plugin Operator Reference — Review & Improve Flywheel

Task-oriented runbook for the native plugin's review/improve features.
The [plugin README](../plugin/README.md) is the overview (install,
commands table, config, guardrails); this document is the *how do I run, watch, recover, and tune it* companion.

The flywheel in one line:

```
/g2g:review → findings backlog → /g2g:improve tick → fix PR →
   human reviews & merges → backlog reconciled → next tick picks the next findings
```

Nothing in this loop ever merges anything. Humans merge; the flywheel
finds, fixes, and files PRs.

---

## 1. Run a review

Interactive, in your checkout (writes only the two artifacts, never
commits):

```
/g2g:review                            # config-driven scope
/g2g:review --focus bug,security      # subset of categories
/g2g:review --target src/lib          # override targets
/g2g:review --diff-base main          # only files changed since main
/g2g:review --full                     # force a full sweep (skip incremental)
```

Scope resolution: `--focus` → else `.claude/g2g.json` `reviewFocus` →
else all five categories (security, bug, code-quality, test-coverage,
architecture). Targets: `--target` → else `sourceDirs` → else inferred
from the repo layout (the report states the inference). Diff scope:
`--full` (force full sweep) → else `--diff-base <ref>` → else the
incremental default (`scope.lastReviewedSha` from a prior run, when
present and resolvable) → else full sweep.

What happens: one read-only subagent per category runs in parallel; the
orchestrator merges results into `review-output/findings.json`
(deduplicating by root cause, continuing ids from the highest existing)
and regenerates `review-output/REVIEW_REPORT.md`. A subagent that
returns malformed output is re-dispatched once, then dropped with a
note in the report.

**After a review:** skim the report, then commit the backlog yourself
(`git add review-output && git commit`) — or leave it uncommitted and
let the next improve cycle's own review regenerate and commit it inside
the fix PR. An *uncommitted* backlog does not survive into improve
worktrees; a *gitignored* one is worse (see §8).

## 2. The findings backlog

`review-output/findings.json` is the source of truth (schema:
`plugin/skills/reviewing-codebase/SKILL.md`). The lifecycle field is
`addressed`:

| Value | Meaning | Written by |
|---|---|---|
| `null` / absent | open — selectable by improve cycles | review |
| `<PR number>` | a fix PR delivered it | improve cycle, Phase I-5 |
| `"stale-<date>"` | revalidation found the symptom already gone | improve cycle, selection |
| `"rejected-<date>"` | vetting showed the finding was wrong (false positive, by-design) — kept, never re-reported | review, vet step |

A PR number only counts while its PR is open or merged: selection
(Phase I-2 step 1a) checks each addressed PR's state and **reopens**
(resets to `null`) any finding whose PR was closed without merging —
a rejected fix must not orphan its findings.

Rules worth knowing:

- Reviews **preserve** existing `addressed` values — never clear one by
  re-running a review. Don't hand-clear them either; open a new finding
  if a fix regressed.
- Selection (inside a tick) takes the top `improveFindings` (default 3)
  open, non-`info`, non-`low`-confidence findings ordered critical →
  high → medium → low; within a severity, smaller effort first, then
  lower id. (`low`-confidence findings stay open for human
  investigation — an autonomous builder never chases an unconfirmed
  symptom.)
- Findings whose `file` appears in any open `g2g/*` PR's diff are
  skipped (someone is already touching it). Requires `gh`; without it
  the filter is skipped with a warning.
- Each candidate is revalidated against the working tree before
  selection; vanished symptoms get `stale-<date>` so they're never
  re-chewed.
- Only findings cited by tasks that were **completed** get a PR number
  on a partial PR — the rest stay open for the next cycle.

## 3. Run an improve tick

Interactive (the launcher does everything; the work itself always runs
headless in a fresh worktree, never in your checkout):

```
/g2g:improve            # fire-and-forget: prints pid/log/kill info and returns
/g2g:improve --wait     # blocks until the tick finishes, reports the outcome
```

Headless (routines, scripts):

```bash
claude -p "/g2g:improve --wait" \
  --plugin-dir /path/to/g2g/plugin \
  --permission-mode acceptEdits \
  --allowedTools "Bash,Read,Glob,Grep" \
  --setting-sources project \
  --max-turns 25 --max-budget-usd 15
```

(The launcher itself needs only read tools; the inner cycle it spawns
carries its own full toolset and its own caps from
`defaultBudgets.improveTurns`/`improveUsd`.)

**Billing (optional).** By default a tick bills to whatever the
launching environment is logged in as — your Claude Code account. Two
optional env vars change that, resolved in this order and reported as
a `billing:` line at every launch: `G2G_IMPROVE_API_KEY` scopes a
Console API key to improve ticks alone (interactive sessions stay on
your subscription); a plain exported `ANTHROPIC_API_KEY` bills the
tick — and every other headless child of that shell — to that key. In
cloud environments with no logged-in account (a scheduled routine, a
managed agent, CI), set one of them as the environment's secret or
the spawn has no credentials at all. Keys live in env/keychain only —
never in `.claude/g2g.json` or anything tracked. Full precedence and
setup: README "Billing: which credentials a headless run uses".

What the launcher does, in order:

1. **Busy checks** — skips rather than stacks: a RUNNING tick, a
   CRASHED tick, or an open `g2g/improve-*` PR each stop the launch
   (see §4). A FINISHED clean worktree is auto-pruned and the launch
   proceeds.
2. Creates the run root unpredictably and owner-only with
   `mktemp -d` (`/tmp/g2g-improve-<random>`, mode 0700 — never a bare
   `date`-derived path, which is symlink-plantable and
   world-readable), then the worktree inside it
   (`<run-root>/worktree`) on branch `g2g/improve-<random>`, and
   copies the Stop-hook settings in if the repo doesn't track them.
3. Spawns `claude -p "/g2g:improve-cycle"` inside it, capped, with
   **sidecars in the run root, next to (never inside) the worktree**:
   `<run-root>/tick.pid` and `<run-root>/tick.log`.
4. Without `--wait`: prints path, branch, pid, log path, caps, and how
   to watch/kill. With `--wait`: polls the pid, then reports the
   outcome and prunes the finished worktree and run root.

Watch a running tick:

```bash
tail -f /tmp/g2g-improve-<random>/tick.log   # raw stream
/g2g:status                                   # tick state + open g2g PRs
```

Kill a running tick:

```bash
kill $(cat /tmp/g2g-improve-<random>/tick.pid)
```

A killed tick becomes a CRASHED tick on the next launcher run — its
work is preserved for inspection, never auto-deleted. The spawned tick
is a plain `&` child and **survives the session that launched it**
(spike-verified) — the pid sidecar is the kill switch, not session
exit.

## 4. Tick states & recovery

`/g2g:status` step 5 reports every `g2g-improve-` worktree as one
of:

- **RUNNING** — pid sidecar present, process alive. Watch or kill.
- **CRASHED** — pid sidecar present, process dead (killed, machine
  slept, hard failure). The launcher will refuse to start new ticks
  until you deal with it. Runbook:
  1. Read the log: `less /tmp/g2g-improve-<random>/tick.log`
  2. Inspect the work: `git -C /tmp/g2g-improve-<random>/worktree
     log --oneline` and `status`.
  3. Salvage if worthwhile (push the branch and open a PR manually, or
     cherry-pick commits), then remove:
     `git worktree remove --force /tmp/g2g-improve-<random>/worktree`
     and delete the run root (`rm -rf /tmp/g2g-improve-<random>`,
     which takes the `tick.pid`/`tick.log` sidecars with it).
- **FINISHED** — no pid sidecar (the cycle removes it as its last act).
  If the tree is clean, the next launcher run (or `--wait` teardown)
  removes the worktree and run root automatically.

## 5. Tick outcomes

Every cycle ends in exactly one of:

- **Full PR** — all selected findings fixed, verifier PASS, one push,
  PR opened, backlog reconciliation commit pushed into the same PR (the
  single sanctioned post-PR push). Review and merge it like any PR.
- **Partial draft PR** (`"… (partial)"`) — an inner cap or the budget
  ran out mid-build; completed tasks are in the PR, their findings
  marked `addressed`; unfinished tasks stay `pending`/`blocked` in the
  committed spec and their findings stay open. To resume: either let a
  future tick re-select the open findings (simplest), or check out the
  PR branch and run `/g2g:build specs/improve-<date>.json` to
  continue the committed spec by hand.
- **Empty cycle** — no actionable findings (all addressed, stale, info,
  low-confidence, or PR-overlapped). Success, not an error.
- **Abort** — guard failure or spec-generation failure, reported
  honestly with cleanup done.

If the *outer* `--max-turns`/`--max-budget-usd` kills the process
mid-build instead, there is **no PR at all** (the backstop is a
guillotine — see §7's sizing rules) and you'll find a CRASHED or
dirty-FINISHED worktree via §4.

## 6. Triggers

**Locally, recurring:** `/loop /g2g:improve` from an interactive
session. Pick a loop cadence longer than a full cycle (~15+ min on a
real repo); if ticks overlap anyway, the busy checks make the extra
invocation skip — nothing stacks. Each tick is fire-and-forget; the
loop session is just the scheduler.

**Cloud/scheduled:** register the Instructions block of
`plugin/routines/improve-nightly.md` with your scheduler (e.g.
`/schedule "nightly at 02:00" <instructions>`). It preflights the
Stop-hook settings, prefers `/g2g:improve --wait`, falls back to the
documented direct spawn if the plugin isn't installed in the fresh
clone, and STOPs honestly if neither is possible.

**One-off:** just run `/g2g:improve --wait` whenever you want a
single bounded improvement pass.

## 7. Budget & cap sizing (from live data)

Measured on this repo's first real tick, under an earlier `improveUsd:
10` default: the five parallel review subagents alone cost **~$7.8**,
leaving ~$2.2 for spec + build — the cycle landed a graceful partial
PR. That data is why the default is now **25**. Sizing guidance:

- `improveUsd` (default 25): adequate for real repos with the default
  five categories; lower it only if you also narrow
  `reviewFocus`/`sourceDirs` so review costs less.
- `improveTurns` (default 50): a toy 2-task cycle used 47 turns; the
  real tick used 22 (budget-bound). Keep this comfortably above
  review + selection + spec turns plus `buildTurnsFactor` × expected
  tasks — it is a backstop, and when it fires mid-build you get
  *nothing*, unlike the inner caps which route to a partial draft PR.
- `improveFindings` (default 3): fewer findings per tick = cheaper,
  more predictable cycles; the flywheel's cadence does the rest.
- `models.improveCycle` (default `sonnet`): the model the spawned
  `claude -p` cycle process itself runs on — orchestrator, review
  subagents, and spec generation all inherit it, so tick cost scales
  directly with this choice; raise it to a premium model only if you
  need stronger judgment there and are willing to pay the cycle's full
  turn count at that rate.
- **Incremental review (biggest lever):** the five parallel category
  subagents are what make review the dominant tick cost. After its
  first run, `/g2g:review` records `scope.lastReviewedSha` in
  `findings.json` and defaults later runs to `--diff-base
  <lastReviewedSha>` — the subagents analyze only files changed since
  the last review (open findings are still fully revalidated), so
  steady-state ticks cost a fraction of a full sweep. Force a full
  five-category sweep over all `sourceDirs` with `--full` (or a
  periodic full-sweep tick) to catch drift outside the diff — the
  tradeoff is completeness vs. cost.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Stop hook blocks a session that never armed a goal | A pre-0.4.0 prompt-type hook copied into `.claude/settings.json`. Its LLM evaluator could reach the right finding ("no goal was armed") and still block. The 0.4.0 hook cannot do this: with no `.g2g-goal` it exits on a file test | Run `/g2g:init`, which detects and offers to remove the legacy copied hook, or delete the `Stop` entry from `.claude/settings.json` by hand. The plugin's own hook needs no copy |
| Tick worktree commits abort / backlog "vanishes" in worktrees | `specs/*` or `review-output/` gitignored | Remove those ignore rules, commit the files once (README "Artifact tracking") |
| Headless run dies instantly, `Bash` rejected | Missing `--allowedTools` alongside `--permission-mode acceptEdits` | Use the proven invocation shape (README "Running headless") |
| Hook never fires headlessly | The plugin is not loaded: `--setting-sources project` excludes user settings, where `enabledPlugins` normally lives. Plugin hooks are NOT inert under that flag — an unloaded plugin has no hooks to fire | Pass `--plugin-dir <path-to>/plugin`, or declare the plugin in the repo's `.claude/settings.json` (`extraKnownMarketplaces` + `enabledPlugins`) as `/g2g:init` does. Never copy the hook |
| Same findings selected every cycle, no PRs | No `gh`/GitHub remote: PR creation fails, reconciliation skips, findings stay open | Give the environment `gh` auth + a GitHub remote, or triage the backlog by hand |
| Launcher refuses to run | RUNNING/CRASHED tick or an open `g2g/improve-*` PR | That's the design (skip, don't stack): finish/kill/inspect per §4, merge or close the PR |
| Tick ended, no PR, worktree dirty | Outer cap guillotined it mid-build | Salvage per §4; raise the outer caps per §7 |
| Build aborts: "live-owner" | Another `/g2g:build` holds `.g2g-goal.lock` in this checkout (heartbeat refreshed within the last hour) | Wait for it (or kill it); a dead build's lock goes stale and is reclaimed automatically by the next run |
| Build aborts: "mutex-stuck" / "malformed-state" | `.g2g-goal.mutex` is wedged past its recovery deadline, or the lock path is not a regular file — something outside `plugin/scripts/g2g-lock.sh` touched the lock names | Inspect the repo root by hand; remove the debris only once you've confirmed no build is running, then rerun |

## 9. Safety model (what protects you)

- **PR-gated:** only `g2g/*` branches are ever pushed; one push at PR
  time plus the single documented reconciliation follow-up; nothing
  merges itself; writing commands refuse the default branch.
- **Graded completion evidence:** `g2g-evidence.sh` grades every run
  with exactly one `verdict:` line: `complete (proven)` (a real
  `--full` run where every verification command exited 0, all tasks
  passed, `verifier: PASS`, and the repo head, tracked-file state, and
  spec completion facts did not change while the commands ran),
  `complete (assumed)` (status mode's
  spec-bookkeeping claim alone — verification commands never ran, so
  this grade can never be `(proven)`), or `incomplete` (naming the
  first failing fact). The Stop hook's completion check requires the
  paired `--full` evidence block to carry exactly one verdict line,
  reading `verdict: complete (proven)`, instead of re-deriving
  completion from the task counts and
  `in_progress`/`pending`/`blocked` substrings — so a failing
  verification command in that `--full` run now blocks completion
  outright; it can no longer coexist with an all-tasks-passed,
  verifier-PASS spec. Pairing accepts only a command that is exactly
  the plugin's own evidence-script invocation ending at `--full` —
  anchored start to end, so chained prefixes, shell comments, and
  lookalike scripts at other paths all fail to pair — and a block with
  multiple verdict lines is treated as forged, so neither a compound
  command nor spec-injected text can fabricate the token. For a
  proven-armed session, the hook also re-derives the short HEAD and
  tracked-dirty state exactly as the evidence script derives them and
  compares that against the paired block's `head:` line; any mismatch
  or missing head line blocks the stop, naming the drift and the
  `g2g-evidence.sh <spec> --full` re-run remedy (F-059). This is why
  Phase 4 rebases onto the default branch before running the final
  `--full` evidence — the proven token must certify the tree that is
  actually pushed, not a pre-rebase snapshot the rebase has since moved
  past.
- **Caps on every spawn:** `--max-turns` and `--max-budget-usd`, always;
  inner build caps route gracefully to partial PRs.
- **No orphans:** no `nohup`/`disown`/`setsid` anywhere; every tick has
  a pid sidecar, is visible in `/g2g:status`, and dies to `kill`.
- **Isolation:** the cycle refuses to run outside a `g2g/improve-*`
  worktree; your checkout is never the workspace.
- **Trust boundary (hardened, not proven):** review-finding text flows
  into spec criteria executed by Bash-capable builders (backlog finding
  F-001, hardened in PR #1 with data/instruction separation). Treat the
  prompt-level hardening as a mitigation: still run the flywheel only
  on repos whose contents you trust. The flywheel is strictly opt-in as
  defense in depth: both improve commands refuse to run unless
  `.claude/g2g.json` sets `"improve": { "enabled": true }`, and
  enabling it is always a human edit.

## 10. The hill-climbing loop (operator view)

Full rationale and the four judging rules live in the [plugin
README](../plugin/README.md#the-hill-climbing-loop-documented-not-yet-wired);
this is the condensed operator version — when to run it, what to
check before merging.

**Status: inert.** Nothing below fires until the entitlement-gated
eval harness referenced in `plugin/evals/README.md` is available. Do
not attempt to hand-run this loop early — there is no way to produce
a real score without the harness, and a fabricated one defeats the
whole point.

**When it's available, to propose a prompt/skill change:**

1. Write it as an ordinary improve fix-spec (same path as any other
   backlog finding) with acceptance criterion: tagged eval score is
   `>=` the committed baseline in `plugin/evals/results.json`, sampled
   across `>= 3` runs.
2. Run it through `/g2g:improve` like any other tick — the eval run
   *is* the verification command, so it goes through the normal
   `g2g-evidence.sh` grading and `g2g-verifier` gate. No separate
   invocation, no new flag.
3. Review the resulting PR yourself. You are the final selection step
   — nothing here merges itself.
4. Score recording is two-phase: the candidate's eval runs are
   read-only against the tracked tree (per-run scores land in an
   untracked sidecar the verifier and you can read — a tracked
   `results.json` write mid-verification would register as state
   drift and block the evidence verdict). If you accept the
   candidate, YOU append the measured entry (per-run `scores`,
   `commit`, `harness`, `model`) to `plugin/evals/results.json` in a
   separate append-only commit. That commit is the one sanctioned
   exception to optimizer/metric separation; it never edits prior
   entries and never touches cases or graders.

**Before merging, check:**

- The candidate touches only `plugin/agents/` or `plugin/skills/`
  prompt/skill text — never `plugin/commands/build.md`,
  `plugin/commands/improve-cycle.md`, `plugin/scripts/g2g-stop.sh`,
  `plugin/scripts/g2g-evidence.sh`, or `plugin/scripts/g2g-lock.sh` in
  the same PR. Those are the human-edited layer; changes there go
  through the normal PR process, not this loop.
- The candidate does not also touch `plugin/evals/` (new cases,
  reworded graders, a dev/sealed reclassification). Changing the
  ruler and the thing it measures in one PR is a same-fix-spec
  violation — reject and split it.
- The score gain, if any, exceeds the observed spread across the
  `>= 3` runs recorded for that PR. Within-spread deltas are not a
  gain — retest with more runs rather than accepting on noise. The
  ledger entry must carry the per-run `scores` array plus the
  candidate `commit` and `harness` fields (`plugin/evals/README.md`'s
  schema) — an entry that pre-averaged its runs cannot support this
  check; reject it as evidence.
- If the score is flat or within spread but the diff adds prose
  (extra caveats, reminders, paragraphs), reject: prompt
  hill-climbing's dominant failure mode is monotonic bloat, so ties
  favor the shorter prompt.
- Run the sealed holdout cases yourself before merging. Sealed cases
  live **outside the repository** in your own fixture store
  (`plugin/evals/README.md`'s dev/sealed split) — anything committed
  in-repo is readable by the candidate's builders and therefore
  cannot serve as a holdout. A clean dev-set score alone is not
  sufficient evidence.
- After merging, remember the generational boundary: the improvement
  applies to ticks started after the plugin version bump that ships
  it, never to the run that produced the PR.

