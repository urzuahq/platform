SHELL := /bin/bash
.DEFAULT_GOAL := ci

.PHONY: ci scripts-test shellcheck

scripts-test:
	ci/scripts/ci-gate.test.sh

shellcheck:
	shellcheck ci/scripts/*.sh

ci: shellcheck scripts-test
