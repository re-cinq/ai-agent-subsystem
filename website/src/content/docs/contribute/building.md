---
title: Building
description: Build the two binaries and the shared library with dub, and statically link the D runtime.
---

The monorepo is a single dub project with three sub-packages: the `agentcore` library and the
`controller` and `supervisor` executables.

## Prerequisites

- **dub** — the D package manager and build tool.
- **A D compiler** — `dmd` works out of the box; **LDC** (`ldc2`) is used for optimized release
  builds and for fully-static (musl) builds.

## Build

From the repository root:

```sh
dub build :controller           # -> controller/ai-agent-controller
dub build :supervisor           # -> supervisor/ai-agent-supervisor
dub build :controller --build=static --compiler=ldc2   # optimized release
```

The executables depend on `ai-agent-subsystem:agentcore`, which dub resolves locally as a
sub-package — no separate install step.

## Static linking

The goal is binaries that ship with **no D runtime dependency**. The default build already achieves
this: the D runtime (druntime + Phobos) is linked statically, and only the system C library remains
dynamic — and any glibc-based image (which the [injected runtime](/concepts/agent-runtime/) already
requires) provides it.

Verify:

```sh
ldd controller/ai-agent-controller
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
attribute metadata) is unit-tested with D's built-in `unittest` blocks:

```sh
dub test :agentcore
```
