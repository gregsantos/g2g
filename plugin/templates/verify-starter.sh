#!/usr/bin/env bash
# verify-starter.sh — starter verification script for a greenfield G2G project.
#
# G2G runs this script as a verification command (`bash verify.sh`). It must
# exit 0 when the project is in a good state and non-zero when a check fails, so
# the loop can tell success from failure.
#
# Replace the example assertions below with real checks for YOUR project, e.g.:
#   - build the project and assert it compiles
#   - run your test suite (pytest / npm test / go test / ...)
#   - lint or type-check the source
# Keep each check exiting non-zero on failure; `set -e` will stop on the first one.
set -euo pipefail

# Example 1: assert an expected source directory exists.
if [[ ! -d "src" ]]; then
  echo "verify: expected source directory 'src/' not found" >&2
  exit 1
fi

# Example 2: run a real check here and let its exit code propagate.
# Replace this echo with your build/test/lint command.
echo "verify: running project checks (replace this with real commands)"

# Example 3: assert a required file is present.
if [[ ! -f "README.md" ]]; then
  echo "verify: expected README.md not found" >&2
  exit 1
fi

echo "verify: all checks passed"
