# Changelog

## 0.3.0 (unreleased)

Architecture: the build task loop can now run on the native
dynamic-workflow runtime. Also carries the completion-gate hardening
and housekeeping authored alongside it.

### Added
- `/g2g:build-wf` (experimental): the `/g2g:build` build with its task
  loop executed by `plugin/workflows/g2g-build.js` (the `g2g:build-loop`
  workflow) — dependency-ordered selection, TURN_CAP/HOURS_CAP
  enforcement, builder-report handling, attempts/blocked bookkeeping,
  and the per-turn heartbeat refresh + tree check all enforced in code
  instead of per-turn orchestrator discipline. Requires Claude Code
  >= 2.1.154 with dynamic workflows enabled; refuses (pointing at
  `/g2g:build`) where the runtime is unavailable.
- Structural tests pinning the workflow contracts (script parses as an
  ES module, meta name agrees with the wrapper, builder schema fields
  agree with the agent definition, P1 verifier-gate semantics kept).
- This changelog.

### Changed
- The armed goal condition additionally requires a VERIFIER REPORT
  block delivered as real Agent tool output — completion can no longer
  be reached by spec edits alone.
- Evidence blocks carry a `head:` line binding them to a commit and
  tracked-dirty count.
- The Stop-hook evaluator is now asymmetric: bystander uncertainty
  (about arming) stays fail-open; the arming session's uncertainty
  (about the condition) fails closed. (The patch's switch of the hook
  model pin to the `haiku` alias was reverted before landing: the
  hook evaluator API rejects aliases, which would silently degrade
  the completion gate to an error-and-continue.)
- Phase 4 verifier dispatch is preceded by a heartbeat refresh.
- Template `models.builder` stays `"sonnet"` (0.2.7's cost
  alignment), now pinned by tests alongside the `artifactPaths`
  absence.

### Fixed
- `g2g-lock.sh`: a stat TOCTOU under mutex contention could crash a
  locker with an unclassified exit (`set -u` on GNU `stat -f` output);
  mtimes are now validated numerically.
- Housekeeping: templates/`.claude/g2g.json` drop the unconsumed
  `artifactPaths`; `verify-starter.sh` shellchecked; stale issue/spike
  references removed; `/g2g:init` discloses the hook's standing cost;
  marketplace metadata added to `plugin.json`.

### Unchanged by design
- `/g2g:build` remains the stable engine; the verifier gate (subagent-
  delivered VERIFIER REPORT required), checkout lock, evidence script,
  PR ceremony, and all safety guardrails are shared by both engines.

## 0.2.7 (2026-07-27)

First improve-flywheel release: fixes selected, built, and
adversarially reviewed by the plugin's own improve cycle (PR #3).

### Changed
- Phase 5 (terminal stop) holds checkout ownership through the push:
  refresh-ownership → push/PR → release-terminal on both outcomes;
  nonzero refresh routes to the non-mutating OWNERSHIP LOST path.
- `models.improveCycle` routes the entire spawned improve tick; it
  rejects `inherit` at both spawn sites (a separate headless process
  has no session to inherit from) and validates the value against a
  strict token allowlist before it reaches the spawn command line,
  passed only as a quoted variable.
- `defaultBudgets.improveTurns` default guidance raised to 70 from
  live tick data (the review vet step costs turns).

## 0.2.6 (2026-07-24)

Review-quality mechanisms adopted from advisor-skill patterns: an
orchestrator vet step (cited code read before a finding gets an id),
`confidence` on findings with a low-confidence candidacy gate,
`rejected-<date>` persistence for false positives, and
effort-tiebroken selection.

## 0.2.5 and earlier

See git history.
