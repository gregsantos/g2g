Using the g2g plugin's writing-g2g-specs skill, produce a G2G spec JSON
for this feature, and output ONLY the JSON (no prose, no code fences):

Feature: a bash script `greeting.sh` currently prints "hello". Add a
`--version` flag that prints "greeting 1.0.0" and exits 0, and make
unknown flags print a usage message to stderr and exit 2. The default
behavior must not change. The repo's verification command is
`bash verify.sh`.
