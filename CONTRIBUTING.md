# Contributing

This is a [dub](https://dub.pm) monorepo: every D package lives under `packages/`, the docs site
under `website/`. This file is the map; the
[building guide](https://re-cinq.github.io/ai-agent-subsystem/contribute/building/) on the docs
site is the terrain — static-linking rationale, per-script details, and the cluster setup live
there.

## Toolchain

| Tool | Version | Needed for |
| --- | --- | --- |
| D compiler | DMD 2.111 (dev loop, CI) or LDC 1.40 (what ships; frontend 2.110) | everything under `packages/` |
| dub | 1.40+ (bundled with the compiler) | builds and tests |
| GNU make | any | the targets below |
| Node.js | 22 (`.nvmrc` in `website/` and `packages/agent-contracts/`) | contracts package, docs site |
| Docker + Buildx | recent | container tests, images |
| kubectl + kind or minikube | recent | controller integration tests only |
| python3 | 3.x | `scripts/pin-image-digests.sh` (release tooling) only |

`dub.json` declares `toolchainRequirements` (frontend >= 2.094 — the oldest CI-proven compiler,
debian:bullseye's LDC 1.24), so an unsupported compiler fails fast with a clear message instead of
a page of template errors.

## Everyday commands

`make` (or `make help`) lists every target. The ones you will actually use:

```sh
make test    # unit tests for all six packages that have them
make build   # all runtime + codegen binaries
make itest   # host-level integration tests - no cluster, no docker, runs in seconds
make drift   # fail if generated CRDs / TS contracts drifted from the D model
make regen   # regenerate deploy/crds and packages/agent-contracts/src/types.generated.ts
make hooks   # install the pre-push hook that runs the drift checks
```

> Bare `dub test` at the repo root is a silent no-op (the root package is `targetType: none` and
> exits 0 without running anything). Always go through `make test` or name a package:
> `dub test :agentcore`.

A green `make test build drift itest` locally reproduces the main CI job — CI runs these same
targets with the same pinned compiler.

## Generated code

`deploy/crds/` and `packages/agent-contracts/src/types.generated.ts` are both generated from the
annotated structs in `packages/agentcore/source/agentcore/crds/`. If you touch those structs, run
`make regen` and commit the output; `make drift` (and CI) fails otherwise. `make hooks` installs a
pre-push hook so you find out before CI does. Skip it once with `git push --no-verify`.

Editing the structs usually also affects the TypeScript package's tests: `make contracts` runs its
vitest suite, which enforces 100% coverage — the same gate CI applies.

## Integration-test tiers

| Tier | Command | Needs |
| --- | --- | --- |
| Host | `make itest` | nothing beyond the D toolchain |
| Cross-distro containers | `make ctest` (or the individual `scripts/ctest-*.sh`) | docker |
| Controller on a cluster | `make itest-controller` | kind or minikube, kubectl, docker |

The ctest scripts take env overrides (`TARGETS`, `BUILDER_IMAGE`, `CONTAINER_ENGINE=podman`, ...);
each script's header documents its knobs. CI's container workflows call these same scripts, so a
local pass means CI parity.

## Pull requests

- Conventional-commit style titles (`fix(output): ...`, `docs(changelog): ...`), squash-merged.
- Add a CHANGELOG.md entry under `Unreleased` for anything user-visible.
- CI must be green before merge.
