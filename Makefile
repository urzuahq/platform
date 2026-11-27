SHELL := /bin/bash
.DEFAULT_GOAL := ci

export PYTHON ?= python3

.PHONY: ci scripts-test shellcheck

scripts-test:
	ci/scripts/ci-gate.test.sh
	ci/scripts/workflow-lint.test.sh
	ci/scripts/pyyaml-pin.test.sh
	ci/scripts/tool-pins.test.sh

shellcheck:
	shellcheck ci/scripts/*.sh

ci: shellcheck scripts-test
