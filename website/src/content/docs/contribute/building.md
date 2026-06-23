---
title: Building
description: Build the three binaries and the shared library with dub, and statically link the D runtime.
---

The monorepo is a single dub project; every sub-package lives under `packages/`: the `agentcore`
library and the `controller`, `initializer`, `supervisor`, and `crdgen` executables.

## Prerequisites

- **dub**: the D package manager and build tool.
- **A D compiler**: `dmd` works out of the box; **LDC** (`ldc2`) is used for optimized release
  builds and for fully-static (musl) builds.

## Build

From the repository root:

```sh
dub build :controller           # -> packages/controller/ai-agent-controller
dub build :initializer          # -> packages/initializer/ai-agent-init
dub build :supervisor           # -> packages/supervisor/ai-agent-supervisor
dub build :crdgen               # -> packages/crdgen/ai-agent-crdgen
dub build :controller --build=static --compiler=ldc2   # optimized release
```

The executables depend on `ai-agent-subsystem:agentcore`, which dub resolves locally as a
sub-package, no separate install step.

## Generating the CRDs

The CRD manifests in `deploy/crds` are **generated from the annotated structs** in
`packages/agentcore/source/agentcore/crds`, not hand-written. The `crdgen` tool introspects the
model (with `describe-d`) and emits the OpenAPI schemas (using `open-api`'s vocabulary):

```sh
dub build :crdgen
./packages/crdgen/ai-agent-crdgen write-structures deploy/crds
```

To change a CRD, edit the struct and its attributes (`@Description`, `@Json`, `@Required`,
`@Minimum`, `@PrinterColumn`, …) and regenerate. `scripts/check-crd-drift.sh` (run in CI)
regenerates into a temp dir and diffs against `deploy/crds`, failing if the committed manifests have
drifted from the D model.

:::note
vibe-d brings `libssl`/`libcrypto`/`libz`. The `ai-agent-crdgen` tool (via `open-api`) and the
`supervisor` (which uses vibe's HTTP client to post to output sinks) link them; the `controller` and
`initializer` stay lean (the initializer posts notifications via the `curl` CLI, so it needs no HTTP
library).
:::

## Static linking

The goal is binaries that ship with **no D runtime dependency**. The default build already achieves
this: the D runtime (druntime + Phobos) is linked statically, and only the system C library remains
dynamic, and any glibc-based image (which the [injected runtime](/concepts/agent-runtime/) already
requires) provides it.

Verify:

```sh
ldd packages/controller/ai-agent-controller
# libm.so.6, libgcc_s.so.1, libc.so.6, ld-linux, and no libphobos / libdruntime
```

This static-D-runtime, dynamic-glibc build is the **portable artifact**: built on an *old* glibc base
(e.g. `debian:bullseye`, glibc 2.31) with

```sh
DFLAGS="-link-defaultlib-shared=false -L-lz" dub build :initializer --compiler=ldc2
```

the binary runs unchanged on every glibc-based Kubernetes distro (Debian, Ubuntu, the RHEL family,
Amazon Linux) because it only needs a baseline glibc (and `libz`/`libgcc_s`, present everywhere).
**Alpine** is musl, not glibc, so a glibc binary can't run there; it is built natively on Alpine
instead. A fully-static musl binary is *not* used: LDC's musl static link drags in `libunwind` →
`liblzma` and is brittle, so the portable-glibc + native-Alpine split is the CI strategy (see
[Cross-distro init-container tests](#cross-distro-init-container-tests)).

## Tests

The pure logic in `agentcore` (prompt rendering, the reconcile state machine, the CRD model and its
attribute metadata) is unit-tested with D's built-in `unittest` blocks, asserting via
[fluent-asserts](https://code.dlang.org/packages/fluent-asserts) (`value.should.equal(…)`). It is
scoped to a `unittest` dub configuration, so the shipped binaries link none of it:

```sh
dub test :agentcore
```

The supervisor's end-to-end behaviour (streaming, file/http sinks, signal forwarding, exit-code
passthrough, and robustness against an agent that leaves a child holding stdout) is covered by an
integration suite that runs the real binary against a configurable **mock agent** (`ai-agent-mock`):

```sh
./scripts/itest-supervisor.sh
```

The **initializer**'s host suite runs the real `ai-agent-init` against a local repo, covering the
clone, idempotent re-runs, lifecycle notifications, and private-repo token auth (asserting the token
never leaks to a sink):

```sh
./scripts/itest-initializer.sh
```

### Cross-distro init-container tests

The init container self-bootstraps its prerequisites through the distro package manager, so it is
also exercised inside real **minimal images where `git` is absent**, proving it installs git via the
detected package manager and clones for real:

```sh
./scripts/ctest-initializer.sh                                                  # Debian/apt (default)
BUILDER_IMAGE=fedora:40 RUNTIME_IMAGE=fedora:40 ./scripts/ctest-initializer.sh  # dnf
```

CI runs this in the **Init container** workflow (`.github/workflows/init-container.yml`) across the
top Kubernetes base distros: Debian, Ubuntu, Rocky, and Amazon Linux (one shared glibc build) plus
Alpine (built natively on musl).

### Cross-distro supervisor tests

The supervisor runs inside the Station's (glibc) image, so its integration suite is also run inside
each glibc base distro. Because the supervisor links vibe-d (and so `libssl.so.3`), the stack is
built once on **Rocky 9**: the oldest glibc (2.34) and openssl 3 common to every glibc distro, and
fanned out, carrying the ldc runtime libs and installing `libssl3` where a base image lacks it.
Alpine is **not** a target: the supervisor requires glibc.

```sh
./scripts/ctest-supervisor.sh                          # all four glibc distros
TARGETS="debian:bookworm-slim" ./scripts/ctest-supervisor.sh   # a subset
```

CI runs this on Rocky, Amazon Linux, Debian, and Ubuntu in the **Supervisor container** workflow
(`.github/workflows/supervisor-container.yml`).
