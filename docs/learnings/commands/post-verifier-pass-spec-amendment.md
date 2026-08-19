---
id: L-003
title: A commit after verifier PASS must amend the spec record, never the verifier field
date: 2026-08-18
track: knowledge
area: commands
severity: medium
tags: [spec-reconciliation, verifier-pass, build-md, amendment-note]
sourceFinding: F-061
commits: [999211b]
---

# L-003: A commit after verifier PASS must amend the spec record, never the verifier field

## Context
`/g2g:build`'s flow ends at PR creation with the spec frozen at
verifier-PASS time, but a build branch does not always stop changing
there — adversarial-review fixes, human review feedback, or follow-up
commits can land afterward and supersede acceptance criteria the
verifier already passed. Observed concretely on PR #11: three criteria
(tick ledger fields, in-repo sealed case, score schema) were
deliberately superseded by review fixes, and the spec had to be
amended by hand because nothing in the protocol required or checked
that amendment — the divergence between the tracked spec and the
shipped design was silent by default. Filed as F-061.

## Decision
Any commit on a `g2g/*` build branch after the verifier PASS that
changes behavior an acceptance criterion describes must, in the SAME
change, amend that criterion to the as-shipped design and append an
amendment note to the task's `notes` field citing the superseding
commit(s). The spec's top-level `verifier` field is never rewritten —
it stays the fixed historical record of the PASS against the
ORIGINAL criteria, never the as-shipped ones. This is documented as
one bullet in `CLAUDE.md`'s "Conventions for editing the plugin"
("Post-verifier-PASS changes amend the spec record") and mirrored in
`plugin/commands/build.md`'s Phase 4 completion steps, right after
the verifier-PASS recording step.

## Rationale
Two things need to stay true simultaneously and only an explicit
convention keeps them from colliding: the spec must reflect what
actually shipped (so a reader of the tracked spec isn't misled about
current behavior), and the `verifier` field must stay an honest,
unaltered record of what was actually verified and when (so "verifier
PASS" never silently gets rewritten to cover work nobody re-verified).
Rewriting the criterion in place captures the first; leaving
`verifier` untouched and appending an amendment note captures the
second — an amendment note without touching `verifier` is what lets a
later reader tell "the criterion changed after PASS, here is why and
by which commit" apart from "the verifier actually re-checked this."
This is also why `g2g/*` PRs are merged, never squashed (see the
adjacent `CLAUDE.md` bullet): squashing would make every commit SHA an
amendment note cites unreachable from a fresh clone of the default
branch, breaking the very citations this rule depends on.

## Evidence
`CLAUDE.md` bullet "Post-verifier-PASS changes amend the spec record"
(cites F-061), `plugin/commands/build.md` Phase 4 (documents the same
rule at the completion steps, right after verifier-PASS recording),
commit `999211b` (adds both, reachable from origin/main).

## Implication
Any future tooling that inspects a spec's `verifier` field must keep
treating it as an append-never historical record, not a live status —
and any change to an acceptance criterion on a build branch after PASS
without a paired amendment note is itself a protocol violation to flag,
not a stylistic nit. `CLAUDE.md`'s note on candidate enforcement
(`/g2g:status` flagging specs whose branch trails its own head, or the
improve cycle refusing to mark findings addressed via a PR whose spec
trails its branch) remains unimplemented as of this writing — the rule
is currently documented, not mechanically enforced.
