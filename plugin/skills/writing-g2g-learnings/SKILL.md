---
name: writing-g2g-learnings
description: Creates and maintains grounded learnings in docs/learnings/ — durable knowledge distilled from a completed g2g build or an addressed review finding. Use when capturing what a build proved, writing up why an invariant must stay in place, or checking whether a new learning overlaps an existing one. Triggers on "capture a learning", "compound this", "write up what we learned", or when /g2g:compound needs the schema.
---

# Writing G2G Learnings

A learning is durable knowledge, not a task record: findings
(`review-output/findings.json`) say what was broken and whether it got
fixed; learnings say what we now know and why it must stay that way. A
learning earns a place in the store only when it is grounded — every
claim in it must be checkable against the working tree by
`g2g-learning-check.sh`, never taken on trust. Write it as if the agent
reading it next has never seen this build — because it hasn't.

## Store layout and the L-ID convention

```
docs/learnings/<area>/<slug>.md
```

`<area>` is one of the area enum values below; `<slug>` is a short
kebab-case name for the entry (`evidence-head-binding.md`, not
`learning-1.md`). One file per learning, one learning per file.

Ids are `L-001`, `L-002`, … — allocated as the highest existing L-ID
plus one, and never reused. This mirrors the F-ID convention already
in force for `review-output/findings.json`: that store continues ids
"from the highest existing id" and, when an entry turns out to be
wrong, marks it rather than deleting it so the id stays meaningful in
context. Learnings follow the same increment rule; the difference is
what happens when an entry stops being true (see "Delete, don't
archive" below — learnings are deleted outright, findings are marked
`rejected-<date>` and kept, because a finding's dedup context has
value a learning's does not).

## Two-track frontmatter schema

Every learning is exactly one of two tracks. Both share one required
field set for retrieval; each track adds its own required fields on
top.

### Shared required fields (both tracks)

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | `L-NNN`, zero-padded, per the allocation rule above |
| `title` | string | Short, specific — names the invariant or defect, not the ticket |
| `date` | string | `YYYY-MM-DD`, the capture date |
| `track` | string | `bug` \| `knowledge` |
| `area` | string | `commands` \| `agents` \| `scripts` \| `hooks` \| `templates` \| `tests` \| `evals` \| `ci` \| `config` \| `docs` |
| `severity` | string | `critical` \| `high` \| `medium` \| `low` — for `bug`, the defect's impact; for `knowledge`, the cost of forgetting this rule |
| `tags` | string[] | Free-form, kebab-case, domain-specific (`checkout-lock`, `version-bump`, `evidence-script`) — not framework boilerplate |

Optional shared fields, fill in when they apply: `sourceFinding`
(`F-NNN`, when this learning grew out of a review finding),
`commits` (array of 7–40 char hex SHAs the body cites as evidence —
prefer citing a merged PR number in body prose and reserve this field
for the SHAs `g2g-learning-check.sh` should verify), `relatedLearnings`
(array of `L-NNN`).

### Bug-track-only required fields

| Field | Type | Description |
|-------|------|-------------|
| `symptoms` | string | One line — what was observed before the fix |
| `rootCause` | string | One line — the actual mechanism, not the symptom |
| `resolution` | string | One line — what changed, citing the fixing commit or PR |

The knowledge track requires none of these three. A knowledge-track
entry records a convention, architectural decision, or workflow rule
that must survive turnover — there is no defect to diagnose, so there
is no symptom, root cause, or resolution to fill in. Do not invent
placeholder values for them; omit the fields entirely.

## Body section template

Frontmatter carries the retrieval-index facts; the body carries the
prose a human or agent actually reads. Both tracks share `Context`,
`Evidence`, and `Implication`; the middle section differs by track.

```markdown
# L-NNN: <Title>

## Context
<What triggered capture — the build, the finding, the symptom that
prompted the investigation. One paragraph.>

## Root Cause          <!-- bug track -->
<The actual mechanism. Cite the defining source line or commit — read
it before asserting it, never recall it from memory.>

## Resolution           <!-- bug track -->
<What changed and where. Prefer a PR number over a bare commit SHA
when citing merged work; a PR number survives a squash, a bare SHA
does not.>

## Decision             <!-- knowledge track -->
<The rule or convention, stated as an instruction a future agent can
follow without re-deriving it.>

## Rationale            <!-- knowledge track -->
<Why this and not the obvious alternative. This is the part that gets
lost when only the rule survives and the reasoning doesn't.>

## Evidence
<Repo-relative paths, commit SHAs, PR numbers, or test names that
ground the claims above. g2g-learning-check.sh verifies every path
exists and every SHA resolves — an ungrounded claim here is exactly
what the check exists to catch.>

## Implication
<What this means going forward — the thing that must stay true, and
what breaks if someone changes it without reading this first.>
```

Keep the unused track's headers out of the actual file — the comments
above mark which headers belong to which track, they are not both
present in one document.

## Capture preconditions

Capture only after the fact is settled, never while it is still in
motion:

- The source is a build with a non-null `verifier` verdict recording
  `PASS`, or a finding whose `addressed` field is a merged PR number —
  not an in-progress build, not an open finding, not a hunch.
- Every claim in the body must be grounded in the working tree at
  capture time: a path that exists, a SHA that resolves, a test name
  that is really there. `g2g-learning-check.sh` enforces this
  mechanically; write nothing you expect it to flag as unverifiable.
- No speculative knowledge. "We suspect," "probably," and "seems to"
  describe an open question, not a learning — if it isn't settled,
  it isn't ready to compound.
- **One learning per capture run.** A single `/g2g:compound` invocation
  writes exactly one learning file. Batching several through one run
  is exactly how drafting scaffold — a literal "Learning 2", "Learning
  3" heading left over from enumerating candidates — leaks into a
  written doc; nothing catches it because the run "succeeded." One run,
  one file, nothing to mislabel.

## The overlap rule

Before creating a new learning, search `docs/learnings/` for existing
entries sharing the new entry's `area` or any of its `tags`. When
overlap is high — same root cause, same convention, same
file/component — update the existing learning in place (extend its
body, bump its `date`) instead of adding a near-duplicate entry next
to it. Only allocate a new L-ID when the candidate is genuinely
distinct from everything already stored.

## Delete, don't archive

There is no `_archived/` directory. When a learning stops describing
reality — the convention it recorded was replaced, the invariant it
protected no longer exists — delete the file. Git history is the
archive: `git log --diff-filter=D -- docs/learnings/` recovers any
learning ever removed, with full context, at no ongoing cost to the
live store. A learning does not need a tombstone; the store needs to
stay small enough that reading it is still less work than rediscovering
the fact it recorded.

## The five maintenance outcomes

Reserved for the follow-up refresh command, not built by this skill's
consumer command — documented here because the schema above is what
that command will read and write. Reviewing an existing learning
against the current tree resolves to exactly one of five outcomes,
each with a one-line default action:

| Outcome | Default action |
|---------|-----------------|
| Keep | Still accurate and current — writes nothing. No touched date, no review breadcrumb, no comment; an unmodified file is the correct outcome and the visible proof of it. |
| Update | Accurate but incomplete or drifted in a detail — edit the body/frontmatter in place, bump `date`. |
| Consolidate | Overlaps heavily with another learning — merge into the entry with more retrieval value, delete the redundant file. |
| Replace | The claim was superseded by a later, different design — rewrite the same L-ID citing the superseding commit/PR; do not mint a new id for a rewrite of the same fact. |
| Delete | No longer describes reality and nothing in it is worth preserving — remove the file (see "Delete, don't archive"). |

`Keep` is the only outcome that touches nothing. Any other outcome
produces a diff; a refresh pass that "reviewed" ten learnings and
changed none of them should show ten `Keep`s in its report, not ten
silent no-op edits.

## The retrieval-value test

Two learnings should stay separate only if someone retrieving one of
them by `area` or `tag` would still need the other to have the full
picture — a distinct root cause, a distinct decision, a distinct
"why." If the second entry adds nothing beyond restating or narrowing
the first, consolidate rather than keep both. Age alone is never a
staleness signal: a learning captured a year ago about an invariant
that still holds is still correct today, and gets no less trustworthy
for being old. What makes a learning stale is disagreement with the
current tree or current docs, not the calendar.

## Urgent vs. routine drift

Most drift found during maintenance is routine — schedule it for the
next refresh pass. One kind is not: a learning that contradicts
CLAUDE.md, `plugin/README.md`, or a pinned bats assertion is urgent.
Those three are the places other agents take as settled truth without
re-verifying; a learning that disagrees with one of them means either
the learning is wrong (fix it now) or the always-loaded doc is wrong
(surface it immediately) — either way, it cannot wait for a routine
cycle.
