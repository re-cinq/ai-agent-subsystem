# AGENTS.md — ai-agent-subsystem

## Context loading order

Before changing code, read in this order:

1. `README.md` — overview, data model (AgentDefinition → Station → Agent), architecture diagram
2. `CONTRIBUTING.md` — toolchain requirements, make targets, integration-test tiers, PR conventions
3. `dub.json` — root monorepo config; sub-packages listed here
4. `packages/<name>/dub.json` — per-package config and dependencies
5. `deploy/crds/` — generated CRDs (do not edit directly; regenerate with `make regen`)
6. `.github/workflows/ci.yml` — what CI runs and in which order

## Tech stack

- **Language**: D (DMD 2.111 in dev/CI, LDC 1.40 for production binaries), statically linked
- **Package manager**: [dub](https://dub.pm) (`dub.json` at root and per package)
- **TypeScript package**: `packages/agent-contracts` — generated types + client; uses Node.js 22 and vitest
- **Go module**: `packages/agent-contracts-go` — generated types + client; `make contracts-go`
- **Java library**: `packages/agent-contracts-java` — generated fabric8 types + client for Spring apps; JDK 17+, Maven, JUnit 5
- **Python package**: `packages/agent-contracts-python` — generated Pydantic models + client; pytest
- **Rust crate**: `packages/agent-contracts-rust` — generated kube-rs types + client; cargo
- **.NET package**: `packages/agent-contracts-dotnet` — generated types + client on KubernetesClient; .NET 10 SDK, xUnit v3
- **Runtime platform**: Kubernetes (v1.27+); state lives in CRDs, not a database
- **Docs site**: `website/` — Astro Starlight, deployed to GitHub Pages

## Monorepo layout

```
packages/
  agentcore/   # shared library: CRD types, k8s client, reconciler, job builder
  controller/  # Kubernetes operator binary
  supervisor/  # runs inside Agent job pods, streams output
  initializer/ # init container: clones repos, installs agent CLI
  crdgen/      # dev tool: generates deploy/crds from D structs
  tsgen/       # dev tool: generates every contract package's types (emit, emit-go, emit-java, emit-python, emit-rust, emit-csharp)
  agent-contracts/      # @re-cinq/agent-contracts npm package
  agent-contracts-go/   # Go contracts module
  agent-contracts-java/ # com.re-cinq:agent-contracts Java library
  agent-contracts-python/ # re-cinq-agent-contracts Python package
  agent-contracts-rust/   # agent-contracts Rust crate
  agent-contracts-dotnet/ # ReCinq.AgentContracts .NET package
  mockagent/   # test double for the agent process
  itest/       # integration-test harness
deploy/        # Kubernetes manifests (CRDs, RBAC, controller Deployment, kustomization)
scripts/       # drift checks, integration-test runners, container build helpers
website/       # documentation site
```

## Workflow commands

### Build

```sh
make build          # all runtime and codegen binaries (uses dub)
make regen          # regenerate deploy/crds and every contract package's types
```

### Test

```sh
make test           # D unit tests for all six packages (agentcore, controller, supervisor,
                    # initializer, crdgen, tsgen) — runs dub test :pkg for each
make itest          # host-level integration tests (no cluster, no docker, fast)
make contracts      # vitest 100%-coverage gate for @re-cinq/agent-contracts
make contracts-go   # go vet + gofmt + go test for packages/agent-contracts-go
make contracts-java # mvn verify for packages/agent-contracts-java (JUnit + 100% jacoco gate on the client)
make contracts-python  # pytest for packages/agent-contracts-python (100% gate on the client)
make contracts-rust    # rustfmt + clippy + cargo test for packages/agent-contracts-rust
make contracts-dotnet  # dotnet test for packages/agent-contracts-dotnet (100% gate on the client)

# Single package:
dub test :agentcore
```

### Lint / type-check

```sh
make drift          # fail if generated CRDs or TS contracts have drifted from the D model
cd packages/agent-contracts && npm run typecheck
```

### Integration tests (heavier)

```sh
make itest-controller   # needs kind or minikube + docker
make ctest              # cross-distro container tests; needs docker
```

### Deploy

Release images are cosign-signed and published to `ghcr.io/re-cinq`. Install the latest release:

```sh
kubectl apply -f https://github.com/re-cinq/ai-agent-subsystem/releases/latest/download/install.yaml
```

Build and push your own images only when needed (air-gapped or private registry):

```sh
REGISTRY=your-registry.example.com/your-project TAG=v0.x.y
docker build -f deploy/Dockerfile.controller -t "$REGISTRY/ai-agent-controller:$TAG" .
docker build -f scripts/container/Dockerfile.agent -t "$REGISTRY/ai-agent:$TAG" .
docker push "$REGISTRY/ai-agent-controller:$TAG"
docker push "$REGISTRY/ai-agent:$TAG"
( cd deploy && kustomize edit set image ghcr.io/re-cinq/ai-agent-controller="$REGISTRY/ai-agent-controller:$TAG" )
kubectl apply -k deploy
```

## Commit conventions

- Conventional Commits style: `type(scope): short description`
  - Common types: `fix`, `feat`, `docs`, `chore`, `test`, `refactor`, `ci`
  - Common scopes: `controller`, `supervisor`, `initializer`, `agentcore`, `contracts`, `deploy`, `ci`
- Titles are squash-merged, so the PR title becomes the commit message — keep it under 72 chars
- Add a `CHANGELOG.md` entry under `## Unreleased` for anything user-visible

## PR requirements

- CI must be green: `make test build drift itest` + the `agent-contracts` and `website` jobs
- Titles follow conventional-commit style (see above)
- CHANGELOG.md updated for user-visible changes
- If you modify `packages/agentcore/source/agentcore/crds/`, run `make regen` and commit the output;
  `make drift` will fail in CI otherwise
- The pre-push hook (`make hooks`) runs drift checks locally before push

## Generated code — do not edit directly

| Generated file | Regenerate with |
| --- | --- |
| `deploy/crds/*.yaml` | `make regen` |
| `deploy/helm/ai-agent-subsystem/crds/*.yaml` | `make regen` (copy of `deploy/crds`) |
| `packages/agent-contracts/src/types.generated.ts` | `make regen` |
| `packages/agent-contracts-go/types.generated.go` | `make regen` |
| `packages/agent-contracts-java/src/main/java/com/recinq/agentcontracts/types/*.java` | `make regen` |
| `packages/agent-contracts-python/src/agent_contracts/types_generated.py` | `make regen` |
| `packages/agent-contracts-rust/src/types.rs` | `make regen` |
| `packages/agent-contracts-dotnet/src/ReCinq.AgentContracts/Types.g.cs` | `make regen` |

## Compliance constraints

- Images are cosign-signed with SPDX SBOMs and SLSA provenance on every tagged release
- Production binaries are statically linked (LDC) with no runtime dependencies
- Controller runs as non-root (UID 1000) with `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, and all capabilities dropped
- NetworkPolicy restricts pod egress; see `deploy/rbac/networkpolicy.yaml`
- Pinned image digests in `deploy/controller.yaml`, `deploy/kustomization.yaml` and `deploy/helm/ai-agent-subsystem/values.yaml` are kept current by `scripts/pin-image-digests.sh` on each release — never use floating tags in deploy manifests
