Read `plugin/skills/writing-g2g-specs/SKILL.md` — the shipped
spec-writing skill in this repository — and apply it as written to
produce a G2G spec JSON for the feature below. The spec's schema, task
fields and their initial values, and acceptance-criteria standards all
come from that file, not from memory and not from this prompt: this
case exists to detect regressions in the shipped skill. Output ONLY
the JSON (no prose, no code fences):

Feature: a bash script `greeting.sh` currently prints "hello". Add a
`--version` flag that prints "greeting 1.0.0" and exits 0, and make
unknown flags print a usage message to stderr and exit 2. The default
behavior must not change. The repo's verification command is
`bash verify.sh`.
