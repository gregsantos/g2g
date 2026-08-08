.PHONY: test lint validate check smoke

# macOS system bash 3.2 has an errexit defect: a failing bare '[[ ]]'
# mid-test does not fail the test, so under it only each test's final
# assert is enforced and a bats green over-reports (F-060). Resolve a
# bash that enforces (G2G_BATS_BASH override, then PATH, then Homebrew/
# MacPorts locations), prove enforcement end-to-end with the canary
# file (which must FAIL), then run the suite under that bash. No
# enforcing bash is a hard failure: a green that cannot enforce its
# asserts must never feed 'make check' — this repo's own build
# verificationCommand and completion evidence.
test:
	@BATS_BASH=""; \
	for b in "$${G2G_BATS_BASH:-}" bash /opt/homebrew/bin/bash /usr/local/bin/bash /opt/local/bin/bash; do \
		[ -n "$$b" ] || continue; \
		command -v "$$b" >/dev/null 2>&1 || continue; \
		if ! "$$b" -ec '[[ 1 -eq 2 ]]; true' 2>/dev/null; then BATS_BASH="$$b"; break; fi; \
	done; \
	if [ -z "$$BATS_BASH" ]; then \
		echo "FAIL: no bash on this machine enforces failing '[[ ]]' asserts mid-test" >&2; \
		echo "      (macOS system bash 3.2 errexit defect, F-060). A bats green under" >&2; \
		echo "      such a bash is untrustworthy. Fix: brew install bash, or point" >&2; \
		echo "      G2G_BATS_BASH at a bash >= 4." >&2; \
		exit 1; \
	fi; \
	echo "bats bash: $$BATS_BASH ($$("$$BATS_BASH" -c 'echo $$BASH_VERSION'))"; \
	if "$$BATS_BASH" "$$(command -v bats)" tests/canary/enforcement.bats >/dev/null 2>&1; then \
		echo "FAIL: enforcement canary reported green — a deliberately failing" >&2; \
		echo "      mid-test assert was swallowed (F-060). Refusing to trust the suite." >&2; \
		exit 1; \
	fi; \
	"$$BATS_BASH" "$$(command -v bats)" tests/

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
