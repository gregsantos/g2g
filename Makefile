.PHONY: test lint check

test:
	bats tests/

lint:
	shellcheck -x -s bash plugin/scripts/g2g-evidence.sh tests/make_sandbox.sh

check: lint test
