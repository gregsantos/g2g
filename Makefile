.PHONY: test lint validate check smoke

# macOS system bash 3.2 has an errexit defect: a failing bare '[[ ]]'
# mid-test does not fail the test, so only each test's final assert is
# enforced and a local green over-reports. CI (ubuntu) is unaffected.
# Tracked as F-060; do not escalate to a hard failure — make check is
# this repo's build verificationCommand.
test:
	@if bash -ec '[[ 1 -eq 2 ]]; true' 2>/dev/null; then \
		echo "WARNING: this bash swallows failing '[[ ]]' asserts mid-test (bash 3.2 errexit bug)."; \
		echo "         Only each test's FINAL assert is enforced locally; CI remains authoritative."; \
		echo "         Fix: brew install bash (bats uses the first bash on PATH). Tracked: F-060."; \
	fi
	bats tests/

lint:
	shellcheck -x -s bash plugin/scripts/g2g-evidence.sh plugin/scripts/g2g-lock.sh plugin/scripts/g2g-stop.sh plugin/templates/verify-starter.sh tests/make_sandbox.sh tests/smoke.sh

validate:
	claude plugin validate plugin
	claude plugin validate .

check: lint validate test

# Behavioral smoke: real headless build against a throwaway sandbox.
# Costs API dollars and minutes — run as the merge gate for changes to
# plugin/commands/ or plugin/agents/; intentionally NOT part of check.
smoke:
	bash tests/smoke.sh
