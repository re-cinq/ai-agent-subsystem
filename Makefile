# Developer entry points. `make` lists targets; CONTRIBUTING.md has the full story.
# CI runs these same targets, so a green `make test build drift itest` locally
# reproduces the main CI job.

TEST_PACKAGES := agentcore controller supervisor initializer crdgen tsgen
BUILD_PACKAGES := controller supervisor initializer crdgen tsgen

.DEFAULT_GOAL := help

.PHONY: help
help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-18s %s\n", $$1, $$2}'

.PHONY: test
test: ## Unit tests for every package that has them
	@set -e; for pkg in $(TEST_PACKAGES); do echo ">> dub test :$$pkg"; dub test :$$pkg; done

.PHONY: build
build: ## Build all runtime and codegen binaries
	@set -e; for pkg in $(BUILD_PACKAGES); do echo ">> dub build :$$pkg"; dub build :$$pkg; done

.PHONY: itest
itest: ## Host-level integration tests (no cluster, no docker)
	./scripts/itest-supervisor.sh
	./scripts/itest-initializer.sh

.PHONY: itest-controller
itest-controller: ## Controller integration tests (needs kind/minikube + docker)
	./scripts/itest-controller.sh

.PHONY: ctest
ctest: ## Cross-distro container tests (needs docker)
	./scripts/ctest-supervisor.sh
	./scripts/ctest-initializer.sh
	./scripts/ctest-init-portable.sh

.PHONY: regen
regen: ## Regenerate deploy/crds and the TypeScript contracts from the D model
	dub build :crdgen
	./packages/crdgen/ai-agent-crdgen write-structures deploy/crds
	dub run :tsgen -c application -q -- emit packages/agent-contracts/src/types.generated.ts

.PHONY: drift
drift: ## Fail if generated CRDs or TS contracts drifted from the D model
	./scripts/check-crd-drift.sh
	./scripts/check-contracts-drift.sh

.PHONY: contracts
contracts: ## Test and build the @re-cinq/agent-contracts npm package (100% coverage gate)
	cd packages/agent-contracts && npm ci && npm run test:coverage && npm run build

.PHONY: docs
docs: ## Build the documentation site
	cd website && npm ci && npm run build

.PHONY: hooks
hooks: ## Install the git pre-push hook (runs the drift checks)
	git config core.hooksPath .githooks
	@echo "pre-push hook installed (core.hooksPath -> .githooks)"
