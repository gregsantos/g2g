---
description: Codebase review — parallel category subagents merged into the tracked findings backlog
argument-hint: '[--diff-base <ref>] [--full] [--focus <cat1,cat2>] [--target <path>]'
---
# /g2g:review — codebase analysis

Run a structured, read-only codebase review: $ARGUMENTS

You change NOTHING except two artifacts: `review-output/findings.json`
(the tracked backlog — source of truth) and
`review-output/REVIEW_REPORT.md` (derived, regenerated every run). You
never commit and never create branches — inspect the results, commit
them yourself, or let an improve cycle carry them inside its fix PR.

/g2g:review participates in the checkout-lock protocol as a read-only
observer only (F-065): before writing `review-output/findings.json` it
queries `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh status`, the
helper's non-mutating liveness check — see the Concurrency liveness
check below — and never acquires, refreshes, releases, or
creates/deletes `.g2g-goal`, `.g2g-goal.lock`, or `.g2g-goal.mutex`; it
is a polite neighbor to the lock, never an owner of it. Unlike
/g2g:spec and /g2g:dev Phase A, /g2g:review REFUSES outright on a live
owner: findings.json is produced by a read-modify-write merge of the
tracked backlog (every open finding is revalidated against a moving
baseline), and two runs analyzing against a baseline that moved cannot
be reconciled by any file lock — concurrent review is unsupported by
decision, and this refusal is how that decision is enforced.

See `plugin/README.md`'s "Concurrency model" section for the full
normative description of the checkout-lock protocol and how
/g2g:review's refusal fits alongside the other commands' behavior.

## Concurrency liveness check (F-065, read-only)
0. Before dispatching any subagent or touching
   `review-output/findings.json`, run
   `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh status` — takes no owner
   token, never creates, refreshes, reclaims, or deletes the lock,
   goal, or mutex. Branch ONLY on its exit code:
   - Exit 0 (`no-lock`) — proceed to Scope resolution / Procedure
     step 1.
   - Exit 4 (`live-owner`) — REFUSE. Report the owner token and
     heartbeat the helper printed, state the one-line justification
     above (concurrent review is unsupported), and STOP. Change
     nothing, dispatch no subagents.
   - Exit 9 (`stale-debris`) — report the owner token, heartbeat, and
     age the helper printed, note that this is stale debris (not a
     live owner) and that a future build's `acquire` will reclaim it
     automatically, then proceed. Do not refuse and do not reclaim it
     yourself.
   - Exit 7 or 8 — the lock state cannot be safely judged (malformed
     state or an operational failure). Report the helper's output
     verbatim and REFUSE out of caution — a review cannot rule out a
     live owner it cannot see. Change nothing, dispatch no subagents.

## Scope resolution
1. Categories: `--focus` (comma-separated) if given; else
   `.claude/g2g.json` → `reviewFocus` if non-empty; else all five:
   security, bug, code-quality, test-coverage, architecture.
2. Targets: `--target <path>` if given; else `.claude/g2g.json` →
   `sourceDirs` if non-empty; else infer the repo's primary source
   files from its layout and CLAUDE.md — and state the inference in
   your report.
3. Diff scope — resolve the base ref in this precedence:
   a. `--full` forces a full sweep: ignore any recorded
      `lastReviewedSha`, use no diff base, review all of step 2's
      targets. Use this (or a periodic full-sweep tick) to catch
      drift the incremental path can miss.
   b. `--diff-base <ref>`: explicit base — use `<ref>`.
   c. Otherwise, **incremental default**: if
      `review-output/findings.json` exists and its
      `scope.lastReviewedSha` is a non-empty sha still resolvable
      (`git cat-file -e <sha>` exits 0), default to that sha as the
      diff base. If no resolvable `lastReviewedSha` exists, fall back
      to a full sweep (no diff base).
   With a diff base resolved, restrict targets to files in
   `git diff --name-only <base>...HEAD` that also fall under step 2's
   targets, and record the base in the findings `scope.diffBase`
   (empty string on a full sweep). A diff-scoped run narrows only the
   files newly analyzed for NEW findings; it never narrows revalidation
   — every existing open finding is re-checked regardless of whether
   its file is in the diff (see step 5).

## Procedure
1. Read `${CLAUDE_PLUGIN_ROOT}/skills/reviewing-codebase/SKILL.md` — it
   defines the findings schema (including `addressed`), the severity
   rubric, per-category analysis techniques, anti-patterns, and the
   accumulation/dedup rules. Follow it exactly.
2. Load the existing backlog if `review-output/findings.json` exists:
   note the highest existing finding id, every existing finding's
   title/file/category (dedup context), and every `addressed` value
   (these must survive untouched).
3. Dispatch ONE subagent per category — all in a single message so they
   run in parallel. Each subagent is read-only (instruct it: analysis
   only, no Write/Edit, no state changes) and receives: its category;
   that category's section from the skill's "Category Analysis
   Techniques"; the "Severity Rubric" table with its calibration rules
   and the "Confidence calibration rules"; the anti-patterns list; the
   resolved target file list; the titles of existing findings in its
   category (do not re-report these — this list includes rejected
   findings, which stay rejected); recon context — 2–5 lines of decided
   tradeoffs and conventions from CLAUDE.md and any docs/ decision
   records, so documented, intentional behavior is not reported as a
   finding; and this output contract — final message is a RAW JSON
   ARRAY of finding objects (no prose, no markdown fences, no `id` and
   no `addressed` fields: the orchestrator assigns both), each with
   category/severity/confidence/file/line?/title/description/suggestion/effort/references?.
   If a subagent returns anything unparseable, re-dispatch it once;
   twice unparseable = drop that category and say so in the report.
4. Vet every NEW finding before it gets an id — subagents over-report.
   Open each cited location yourself and confirm the symptom is there
   and is what the finding claims. Expect three failure classes:
   by-design behavior reported as a defect (intentional patterns,
   documented tradeoffs, framework conventions); mis-attributed
   evidence (real symptom, wrong file or line — correct it); and
   duplicates across subagents (same root cause — keep one). A finding
   that fails vetting still enters the backlog, but with
   `addressed: "rejected-<today>"` and the rejection reason appended to
   its description, so no future review re-reports it. Downgrade
   `confidence` where the evidence read weaker than claimed; never
   upgrade it without reading the code.
5. Merge per the skill's "Accumulation and Deduplication Rules": drop
   duplicates of existing findings and cross-category duplicates (same
   root cause); assign sequential ids continuing from the highest
   existing; new findings get `"addressed": null`; existing findings
   keep their `addressed` values; recompute `summary` over ALL
   findings. Revalidate every existing OPEN finding (`addressed` null
   or absent) whether or not its file falls in the diff scope — a
   diff-scoped run narrows only where NEW findings are hunted, never
   which open findings get re-checked; mark ones whose symptom is gone
   `"stale-<date>"` per the skill. Never clear a non-null `addressed`.
6. Write `review-output/findings.json` (create the directory if
   needed) using the skill's file structure — project (repo name),
   reviewDate (today), scope {target, diffBase, focus,
   lastReviewedSha}, summary, findings. Set `scope.lastReviewedSha` to
   the current HEAD sha (`git rev-parse HEAD`) so the next review can
   default to incremental diff scope; write it on EVERY run (full or
   incremental). Validate with real commands and show the output:
   `jq -e '.summary.total == (.findings | length)'
   review-output/findings.json` must print `true`.
7. Regenerate `review-output/REVIEW_REPORT.md` from the merged
   findings: title + reviewDate + scope line; a summary table (counts
   by severity); then one section per severity in rubric order, each
   finding rendered as `### F-xxx [severity] title` with file:line,
   description, suggestion, and `addressed` status; end with an "Open
   vs addressed" count line.
8. Report: new findings vs pre-existing (counts by severity), findings
   vetted out as rejected (with the one-line reason each), the top
   findings by severity, the scope actually used, and both artifact
   paths. If `git check-ignore review-output/findings.json` exits 0,
   WARN prominently: an ignored backlog vanishes in worktrees and
   fresh clones and defeats the improve loop (plugin README, "Artifact
   tracking").
