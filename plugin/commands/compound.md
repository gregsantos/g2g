---
description: Turn a completed, verified build (or an addressed review finding) into exactly one grounded learning under docs/learnings/
argument-hint: '[<spec-path>|F-NNN]'
model: sonnet
---
# /g2g:compound — capture a grounded learning

Capture exactly one grounded learning from a settled source: $ARGUMENTS

/g2g:compound writes to the checkout — a new file, or an in-place edit
to an existing file, under `docs/learnings/` — so it participates in
the checkout-lock protocol exactly like `/g2g:build` and `/g2g:go`: it
acquires `.g2g-goal.lock` via
`${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh` — the sole implementation
of the synchronization protocol — before its first write, refreshes
the heartbeat at phase boundaries, and releases with
`release-terminal <owner-token>` on every terminal path this run
reaches after a successful acquire, abort paths included. Never
create, mutate, or delete `.g2g-goal`, `.g2g-goal.lock`, or
`.g2g-goal.mutex` by hand, and never reimplement any of that logic
inline: run the helper and branch only on its documented exit codes.
This command arms no `.g2g-goal` of its own (it needs no Stop-hook
enforcement — a capture run is short and bounded by its own procedure),
which is why it can safely use `release-terminal`: the only
`.g2g-goal` that can exist once this run holds the lock is either
absent, or dead orphaned debris from a past aborted run that nothing
still needs — see `plugin/README.md`'s "Concurrency model" section for
the full normative description of the protocol and why builds, `go`,
and this command are the mutating participants while `spec`, `review`,
and `dev` Phase A only observe it read-only.

Read `${CLAUDE_PLUGIN_ROOT}/skills/writing-g2g-learnings/SKILL.md`
before step 3 acts on anything — it is the CONTRACT for the store: the
L-ID allocation rule, the two-track frontmatter schema, the body
section template, the overlap rule, and the capture preconditions this
command enforces. Follow it exactly; this file only sequences when
each part of that contract is applied.

This command never writes `CLAUDE.md`, `plugin/README.md`, or any
other instruction file — a command that edits the repo's own operating
contract as a side effect is out of scope here. The only paths it may
create or modify are under `docs/learnings/`.

Procedure — deviations are failures:

0. Checkout lock: choose an OWNER TOKEN (opaque, single-line, unique to
   this run — e.g. `g2g-$$-<epoch seconds>`) and run, from the repo
   root, BEFORE step 1 resolves anything or step 5 writes anything:
   `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh acquire <owner-token>`
   Remember the owner token — every later helper call (refresh,
   release-terminal) needs it. Branch ONLY on the exit code:
   - Exit 0 (`acquired` or `reclaimed ...`) — you hold the lock.
     Proceed to step 1.
   - Exit 4 (`live-owner`) — another g2g command is LIVE in this
     checkout right now. ABORT immediately, change NOTHING, and report
     the heartbeat and owner the helper printed. Do NOT call
     `release-terminal` on this path — acquisition itself failed, so
     any lock in place belongs to someone else.
   - Exit 2, 6, 7, or 8 — the lock state cannot be safely judged (bad
     owner token, mutex stuck, malformed state, or an operational
     failure). ABORT, print the helper's output verbatim, change
     NOTHING, and do NOT call `release-terminal` — same reason as
     exit 4: acquisition-failure paths never release a lock that was
     never yours.
0a. LOCK RELEASE ON EVERY TERMINAL PATH: from this point — a successful
    step 0 acquire — until step 7's own release, every terminal path
    this run takes MUST release the lock before reporting the outcome,
    including step 1's resolution-failure abort, step 2's precondition
    refusal, step 5's write failure, and step 6's unresolvable
    adjudication. On any such path, run:
    `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh release-terminal <owner-token>`
    — the same call step 7 documents — before reporting the abort or
    refusal. Exit 0 (`released-terminal`) confirms the pair is clear.
    Exit 5 (`ownership-lost`) there means the lock already stopped
    being yours while you were aborting anyway: report it and stop
    without touching anything further. This is IN ADDITION to step 7's
    own release on the success and adjudication-complete paths — it
    does not replace or narrow it.
1. Resolve the source of truth from `$ARGUMENTS`:
   a. Argument matches `F-[0-9]+` (an F-ID): the source is that finding
      object in `review-output/findings.json`, plus the commit(s) or PR
      that addressed it.
   b. Argument is a path: the source is the spec JSON at that path —
      its `context`, every task's `notes` and cited commit SHAs, and
      the top-level `verifier` field.
   c. No argument: resolve the most recently modified file (by mtime)
      matching `specs/*.json` whose top-level `verifier` field is
      non-null. If no such spec exists, this is a refusal (step 2), not
      a fallback search — never substitute a finding or an in-progress
      spec for a missing verified one.
   If the resolved path does not exist, or does not parse as JSON, or
   the F-NNN is not present in `review-output/findings.json`: this is
   an abort per step 0a — release the lock, report what could not be
   resolved, and stop. There is nothing to capture from.
2. Precondition check — refuse, do not warn:
   - Spec source: the spec's top-level `verifier` field is null,
     absent, or does not record a `PASS` verdict. STATE EXPLICITLY IN
     YOUR REPORT that a spec with no verifier verdict is a refusal to
     capture, not a warning — an in-progress or unverified build has
     settled nothing yet to compound.
   - Finding source: the finding's `addressed` field is null, absent,
     rejected (`rejected-<date>`), or stale (`stale-<date>`) rather
     than a merged PR number or a commit that actually landed the fix.
   Either failure is an abort per step 0a: release the lock, report the
   refusal and the exact field/value that failed the gate, and stop.
   Change nothing under `docs/learnings/`. Only a spec whose `verifier`
   records `PASS`, or a finding whose `addressed` field names the work
   that fixed it, passes this gate and proceeds to step 2a.
2a. Heartbeat before the reading/writing work in steps 3–6: run
    `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh refresh <owner-token>`
    Branch on its exit code:
    - Exit 0 (`refreshed`) — still the owner, proceed to step 3.
    - Exit 5, 6, 7, or 8 — ownership is lost or the lock state cannot
      be judged. Report the helper's outcome verbatim, change nothing
      further under `docs/learnings/`, do NOT call `release-terminal`
      (the lock is no longer yours to release), and stop. Flag the run
      as possibly contested for a human to re-run.
3. Read the source record in full — never the conversation, and never
   assert a behavior from memory:
   - Spec source: read every task's `acceptanceCriteria` and `notes`
     and any commit SHAs they cite, the top-level `verifier` block, and
     `context`. Before writing any sentence in the learning body that
     asserts a behavior, open and read the defining source line — the
     actual file/line the change touched — first; a task's notes
     describe what happened, they are not a substitute for reading the
     code that makes it true today.
   - Finding source: read the finding object in
     `review-output/findings.json` in full, plus every commit or PR
     that addressed it. When the fix landed through a merged PR,
     prefer the PR number over a bare commit SHA when citing it in body
     prose — a PR number survives a squash-merge, a bare SHA does not.
     Reserve commit SHAs for the optional `commits` frontmatter field,
     which `g2g-learning-check.sh` verifies mechanically.
4. Overlap check, per the writing-g2g-learnings skill's "overlap rule":
   search `docs/learnings/` for existing entries sharing the
   candidate's `area` or any of its `tags`, and read each candidate
   match in full before judging.
   - High overlap (same root cause, same convention, same
     file/component): update that learning IN PLACE — extend its body,
     bump its `date` — instead of minting a new L-ID.
   - No high-overlap match: proceed to allocate a new L-ID (highest
     existing + 1) in step 5.
5. Write EXACTLY ONE learning — either one new file under
   `docs/learnings/<area>/<slug>.md`, or one in-place update from
   step 4's decision. Never write more than one file, and never a batch
   of several candidate learnings in one run — that is exactly how
   drafting scaffold (a stray "Learning 2" heading) leaks into a
   written doc, per the skill. Follow the skill's frontmatter schema
   (the shared fields plus the correct track's required fields —
   never both tracks, never a placeholder value for an omitted field),
   the L-ID rule, the area/severity enums, and the body section
   template. State in your working notes, and again in step 8's
   report, that exactly one file changed this run.
5a. Heartbeat before step 6's grounding check: run
    `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh refresh <owner-token>`
    and branch on its exit code exactly as step 2a — exit 0 proceeds to
    step 6; exit 5, 6, 7, or 8 reports the outcome, changes nothing
    further, calls no release, and stops, flagging the run as possibly
    contested.
6. Ground the write: run
   `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-learning-check.sh <path-to-the-file-you-wrote-or-updated>`
   as the ENTIRE command — never hand-write or paraphrase its output.
   Branch on the exit code:
   - Exit 0 — clean. Proceed to step 7.
   - Exit 2 — frontmatter missing or invalid. This is a correctness bug
     in what you just wrote, not one of the three adjudication
     resolutions below: fix the frontmatter and re-run the SAME check
     command before doing anything else.
   - Exit 3 — no learning files found at all (only reachable if
     step 5's write silently failed). Treat this as a write failure:
     go to step 0a's abort path.
   - Exit 4 — at least one flag needs adjudication. Read every flag
     line the script printed. For EACH flag, resolve it with EXACTLY
     ONE of these three resolutions — never an automatic pass, and
     never an automatic rewrite without reading what was flagged:
     1. **Fix the claim** — the flagged path, SHA, or link is wrong, or
        the prose overstated it; correct the body so it matches what is
        actually true and grounded, then continue to the re-run below.
     2. **Annotate as historical** — the claim was true at capture time
        but the checker cannot verify it against the current tree for
        a documented reason (e.g., a path that existed only before a
        fix); add a short parenthetical stating this explicitly next
        to the claim in the body, then continue to the re-run below.
     3. **Confirm intentional** — the flag is a known, documented
        limitation of the checker itself (e.g., a SHA reported
        `head-only` because this repo has no origin remote configured,
        per `g2g-learning-check.sh`'s own caveat) and the claim needs no
        edit; record in step 8's report exactly which flag this is and
        why it is being confirmed rather than changed, so the
        confirmation is visible, not silent.
     After every flag from this run has been fixed, annotated, or
     confirmed, re-run the exact same check command. Repeat this step —
     re-run after every body edit — until the script exits 0, or every
     single remaining flag has been explicitly confirmed intentional
     and recorded in your notes for step 8. Never stop on a nonzero
     exit with an unresolved flag and no recorded resolution.
7. Release the checkout lock: run
   `${CLAUDE_PLUGIN_ROOT}/scripts/g2g-lock.sh release-terminal <owner-token>`
   on every path that reaches this step — the success path (step 6
   clean, or every flag confirmed) and any prior step's abort per
   step 0a. Report its outcome. Exit 0 (`released-terminal`) confirms
   the goal/lock pair is clear. Exit 5 (`ownership-lost`) means the
   lock stopped being yours already — nothing further to delete;
   report it and continue to step 8. NEVER run this on step 0's
   acquisition-failure path — there the lock belongs to someone else.
8. Report: which source was resolved (spec path or F-NNN) and, if no
   argument was given, which default-resolution rule picked it; the
   single learning file written or updated, its L-ID, and an explicit
   statement that exactly one file changed this run; the overlap
   decision (new entry vs. in-place update) and why; the final
   `g2g-learning-check.sh` exit code and, for every exit-4 flag, which
   of the three resolutions closed it; and the lock release outcome.
   If you could not complete the capture, say exactly what blocked it
   — a refusal at step 2, an unresolved flag, a lost lock — and never
   claim a learning was captured when it was not.
