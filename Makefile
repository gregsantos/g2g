.PHONY: test lint validate check smoke

test:
	bats tests/

lint:
	shellcheck -x -s bash plugin/scripts/g2g-evidence.sh plugin/scripts/g2g-lock.sh plugin/templates/verify-starter.sh tests/make_sandbox.sh tests/smoke.sh

validate:
	claude plugin validate plugin
	claude plugin validate .

check: lint validate test

# Behavioral smoke: real headless build against a throwaway sandbox.
# Costs API dollars and minutes — run as the merge gate for changes to
# plugin/commands/ or plugin/agents/; intentionally NOT part of check.
smoke:
	bash tests/smoke.sh
