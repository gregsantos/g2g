Read `plugin/skills/reviewing-codebase/SKILL.md` — the shipped review
skill in this repository — and vet candidate findings per its rules:
the severity rubric, the confidence calibration rules, and the vetting
outcomes (accept as-is; correct in place with the reason noted, never
silently drop; reject with `addressed: "rejected-<date>"` and the
rejection reason appended). Every rule you apply must come from that
file as it exists on disk, not from memory and not from this prompt:
this case exists to detect regressions in the shipped calibration
rules.

Vet each of these four candidate findings. For each, state: accept
as-is, accept with a correction (name the field and its new value), or
reject — and give a one-line reason in every non-"accept as-is" case.

A. Category: security. Severity: critical. File:
   `plugin/scripts/g2g-lock.sh:112`. Title: "Owner token accepted
   without validation". Description: "The lock file's owner token is
   never checked against an allowlist." Suggestion: "Add an allowlist
   of valid owner token formats." You confirm by reading the code and
   CLAUDE.md that owner tokens are intentionally caller-generated
   opaque strings (e.g. `g2g-$$-<epoch>`) with no fixed format, and
   this is the documented, by-design contract for the lock protocol.

B. Category: code-quality. Severity: high. File:
   `plugin/commands/build.md`. Title: "Phase 3 is too long".
   Description: "This phase has many steps and could probably be
   cleaner." Suggestion: (none given). Confidence: not stated.

C. Category: test-coverage. Severity: medium. File:
   `tests/plugin_lock.bats:48`. Title: "No test for a heartbeat file
   with a missing second line". Description: "The heartbeat file
   format assumes two lines (timestamp, owner token); no existing test
   covers a lock file truncated to one line, which the parser reads as
   an empty owner token." Suggestion: "Add a case that writes a
   one-line lock file and asserts the acquire/refresh helper treats it
   as malformed rather than crashing." Confidence: high (you read the
   parser and the existing test file and confirmed the gap).

D. Category: bug. Severity: high. File: `plugin/scripts/g2g-stop.sh`.
   Title: "Stop hook may read a partially written goal file".
   Description: "Function names like `read_goal_fields` suggest no
   atomic-write guard, which could let the hook read a half-written
   JSON file." Suggestion: "Write the goal file to a temp path and
   rename it into place." Confidence: high (based on the function
   names alone; you did not read the write path in build.md or the
   parser in g2g-stop.sh).
