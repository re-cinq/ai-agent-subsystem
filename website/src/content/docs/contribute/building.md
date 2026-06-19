---
title: Building
description: Build the statically linked binaries with dub and LDC.
---

Both binaries are built with **LDC** (the LLVM D compiler) and statically linked so they ship as
self-contained executables with **no runtime dependencies**.

## Prerequisites

- LDC (provides `ldc2`)
- dub

## Build

```sh
# the shared library is pulled in as a sub-package dependency
dub build :controller --compiler=ldc2 --build=release
dub build :supervisor --compiler=ldc2 --build=release
```

## Static linking

Static linking is configured per target in `dub.json` via link flags passed to LDC, for example:

```json
{
  "buildTypes": {
    "static": {
      "dflags-ldc": ["-static"],
      "buildOptions": ["releaseMode", "optimize", "inline"]
    }
  }
}
```

Build the fully static variant with:

```sh
dub build :controller --compiler=ldc2 --build=static
```

Verify there are no dynamic dependencies:

```sh
ldd ./controller   # expect: "not a dynamic executable"
```

## Tests

The pure logic in `agentcore` (reconcile, prompt rendering, job building) is unit-tested with
injected I/O:

```sh
dub test :agentcore --compiler=ldc2
```

:::note
Exact target names and flags are finalized in the implementation phase; this page documents the
intended build flow.
:::
