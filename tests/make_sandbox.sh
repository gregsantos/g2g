#!/usr/bin/env bash
# Creates a throwaway sandbox repo for supervised g2g plugin smoke tests.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:-/tmp/g2g-sandbox}"
rm -rf "$DIR"
mkdir -p "$DIR/specs"
cd "$DIR"
git init -q -b main

cat > greeting.sh <<'EOF'
#!/usr/bin/env bash
# Prints a greeting. Tasks in specs/sandbox.json extend this file.
echo "hello"
EOF
chmod +x greeting.sh

cat > verify.sh <<'EOF'
#!/usr/bin/env bash
# Verification: greeting.sh must support default and --shout modes as tasks complete.
set -euo pipefail
[[ "$(./greeting.sh)" == "hello" ]] || { echo "FAIL: default greeting"; exit 1; }
if grep -q 'shout' greeting.sh 2>/dev/null; then
    [[ "$(./greeting.sh --shout)" == "HELLO" ]] || { echo "FAIL: shout mode"; exit 1; }
fi
echo "verify OK"
EOF
chmod +x verify.sh

cat > specs/sandbox.json <<'EOF'
{
  "project": "Sandbox greeting",
  "context": {
    "currentState": "greeting.sh prints hello",
    "targetState": "greeting.sh supports --shout and --name flags",
    "constraints": ["bash only", "no new files except tests"],
    "verificationCommands": ["./verify.sh"]
  },
  "tasks": [
    {
      "id": "T-001",
      "title": "Add --shout flag",
      "description": "greeting.sh --shout prints HELLO (uppercase).",
      "acceptanceCriteria": ["./greeting.sh --shout outputs HELLO", "./greeting.sh still outputs hello"],
      "dependsOn": [],
      "status": "pending",
      "passes": false,
      "effort": "small",
      "notes": ""
    },
    {
      "id": "T-002",
      "title": "Add --name flag",
      "description": "greeting.sh --name X prints hello X. Combined with --shout prints HELLO X.",
      "acceptanceCriteria": ["./greeting.sh --name Sam outputs 'hello Sam'"],
      "dependsOn": ["T-001"],
      "status": "pending",
      "passes": false,
      "effort": "small",
      "notes": ""
    }
  ]
}
EOF

mkdir -p .claude review-output

cat > .claude/g2g.json <<'EOF'
{
  "verificationCommands": ["./verify.sh"]
}
EOF

# Duplicate the plugin's Stop hook into project settings: plugin-shipped
# hooks do not fire under --setting-sources project, which is the shape
# every supervised smoke run here uses (see plugin/README.md, "Running
# headless / unattended"). Copying hooks.json keeps a single source for
# the hook prompt and its pinned model ID.
cp "$SCRIPT_DIR/../plugin/hooks/hooks.json" .claude/settings.json

cat > review-output/findings.json <<'EOF'
{
  "project": "Sandbox greeting",
  "reviewDate": "2026-07-20",
  "scope": {
    "target": "greeting.sh",
    "diffBase": "",
    "focus": ["bug", "test-coverage"]
  },
  "summary": { "total": 3, "critical": 0, "high": 0, "medium": 1, "low": 1, "info": 1 },
  "findings": [
    {
      "id": "F-001",
      "category": "bug",
      "severity": "medium",
      "file": "greeting.sh",
      "line": 3,
      "title": "Unknown flags are silently ignored",
      "description": "greeting.sh ignores unrecognized flags and prints the default greeting anyway, hiding user errors.",
      "suggestion": "Print a usage message to stderr and exit 2 when an unknown flag is passed.",
      "effort": "small"
    },
    {
      "id": "F-002",
      "category": "test-coverage",
      "severity": "low",
      "file": "verify.sh",
      "title": "verify.sh does not cover flag error handling",
      "description": "verify.sh only checks the default and shout greetings; a regression in flag handling would still pass verification.",
      "suggestion": "Add a check that an unknown flag exits non-zero once that behavior exists.",
      "effort": "small"
    },
    {
      "id": "F-003",
      "category": "code-quality",
      "severity": "info",
      "file": "greeting.sh",
      "title": "Greeting logic is simple and readable",
      "description": "The current structure is easy to extend; keep flag parsing in one place as flags are added.",
      "suggestion": "No action needed.",
      "effort": "small"
    }
  ]
}
EOF

cat > requirements.md <<'EOF'
# Greeting requirements

- `greeting.sh` must support a `--version` flag that prints `greeting 1.0.0` and exits 0.
- Unknown flags must print a usage message to stderr and exit 2.
- The default behavior (prints `hello`) must not change.
EOF

git add -A && git commit -qm "init: sandbox project with 2-task spec"
echo "$DIR"
