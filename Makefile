# pegasus-bazzite-configurator — developer convenience targets.
# These run on the dev host (e.g. Ubuntu); the deployment targets a real
# Bazzite machine. See docs/ for what each test proves.

SHELL := /bin/bash
SCRIPTS := scripts/deploy.sh scripts/validate.sh scripts/restore.sh scripts/uninstall.sh scripts/update.sh scripts/smoke-fedora-container.sh
LIBS := $(wildcard scripts/lib/*.sh)
TESTS := $(wildcard tests/*.sh)
# Lint the entrypoints (and tests/smoke) only: external-sources follows their
# `source` directives into the libraries, so the whole call graph is analysed
# without the false "unused" positives that linting a library in isolation
# produces.
LINT_TARGETS := $(SCRIPTS) $(TESTS)
FEDORA_TAG ?= 41

.PHONY: help lint syntax test smoke-fedora dry-run check all

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

syntax: ## bash -n on every script
	@for f in $(SCRIPTS) $(LIBS) $(TESTS); do bash -n "$$f" && echo "OK  $$f"; done

lint: ## Run ShellCheck (follows sources into lib/)
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 1; }
	shellcheck -x $(LINT_TARGETS)

test: ## Run the unit test suite
	bash tests/run-tests.sh

dry-run: ## Demo: dry-run against the example config (no changes)
	scripts/deploy.sh --config config/example-config.yaml --non-interactive --dry-run --allow-non-bazzite

smoke-fedora: ## Run the Fedora-container smoke test (needs podman/docker)
	scripts/smoke-fedora-container.sh $(FEDORA_TAG)

check: syntax lint test ## Fast local gate: syntax + lint + unit tests

all: check ## Alias for check
