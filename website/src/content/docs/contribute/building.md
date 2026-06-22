---
title: Building
description: Build the two binaries and the shared library with dub, and statically link the D runtime.
---

The monorepo is a single dub project; every sub-package lives under `packages/`: the `agentcore`
library and the `controller`, `supervisor`, and `crdgen` executables.

## Prerequisites

- **dub** — the D package manager and build tool.
- **A D compiler** — `dmd` works out of the box; **LDC** (`ldc2`) is used for optimized release
  builds and for fully-static (musl) builds.

## Build

From the repository root:

```sh
dub build :controller           # -> packages/controller/ai-agent-controller
dub build :supervisor           # -> packages/supervisor/ai-agent-supervisor
dub build :crdgen               # -> packages/crdgen/ai-agent-crdgen
dub build :controller --build=static --compiler=ldc2   # optimized release
```

The executables depend on `ai-agent-subsystem:agentcore`, which dub resolves locally as a
sub-package — no separate install step.

## Generating the CRDs

The CRD manifests in `deploy/crds` are **generated from the annotated structs** in
`packages/agentcore/source/agentcore/crds` — not hand-written. The `crdgen` tool introspects the
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
`supervisor` (which uses vibe's HTTP client to post to output sinks) link them; only the
`controller` stays lean.
:::

## Static linking

The goal is binaries that ship with **no D runtime dependency**. The default build already achieves
this: the D runtime (druntime + Phobos) is linked statically, and only the system C library remains
dynamic — and any glibc-based image (which the [injected runtime](/concepts/agent-runtime/) already
requires) provides it.

Verify:

```sh
ldd packages/controller/ai-agent-controller
# libm.so.6, libgcc_s.so.1, libc.so.6, ld-linux — and no libphobos / libdruntime
```

For a **fully static** binary with no libc dependency at all, build with LDC against **musl** (the
release/CI target):

```sh
dub build :controller --build=static --compiler=ldc2 --d-version=... # musl toolchain
```

This requires a musl-enabled LDC (or installed static glibc archives) and is wired up in CI rather
than assumed on every dev machine.

## Tests

The pure logic in `agentcore` (prompt rendering, the reconcile state machine, the CRD model and its
attribute metadata) is unit-tested with D's built-in `unittest` blocks, asserting via
[fluent-asserts](https://code.dlang.org/packages/fluent-asserts) (`value.should.equal(…)`). It is
scoped to a `unittest` dub configuration, so the shipped binaries link none of it:

```sh
dub test :agentcore
```

The supervisor's end-to-end behaviour — streaming, file/http sinks, signal forwarding, exit-code
passthrough, and robustness against an agent that leaves a child holding stdout — is covered by an
integration suite that runs the real binary against a configurable **mock agent** (`ai-agent-mock`):

```sh
./scripts/itest-supervisor.sh
```
