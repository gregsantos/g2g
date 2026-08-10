You are vetting candidate findings for `/g2g:review`, per the
`reviewing-codebase` skill's rules (quoted below). Vetting happens
before a finding gets an id: open each cited location, confirm the
symptom is real and matches the claim, and apply these calibration
rules.

Severity rubric (excerpt):
- `critical` requires demonstrated exploitability or a data-loss path.
- `high` is a security gap, likely bug, or missing critical error
  handling.
- `medium` is a code smell, moderate risk, or a coverage gap in an
  important path.
- When uncertain between two levels, pick the LOWER one.
- A finding without a clear `suggestion` should not be `high` or
  `critical`.

Confidence calibration rules:
- `confidence` measures certainty the symptom is real, not severity.
- `high` confidence requires having read the cited code and confirmed
  the symptom.
- Anything inferred from patterns or names WITHOUT reading the
  surrounding code is at most `medium` confidence.
- `low` confidence is legitimate — record the smell rather than
  dropping or inflating it.

Vetting outcomes: a finding that turns out to document intentional,
by-design behavior gets `addressed: "rejected-<date>"` with the
rejection reason appended to its description; a finding whose
severity or confidence was miscalibrated gets corrected in place
(downgraded, never silently dropped) with the reason noted; a
well-formed finding is accepted as-is.

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
