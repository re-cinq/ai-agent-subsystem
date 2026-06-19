---
title: Repository layout
description: How the D monorepo is organized — two binaries and a shared library.
---

The repository is a single **dub** monorepo (root `dub.json` with `targetType: none` and three
`subPackages`), following the spirit of
[ogm-server](https://gitlab.com/GISCollective/backend/ogm-server): reusable code in a local package,
thin executables on top.

```
ai-agent-subsystem/
├── dub.json                       # root: targetType none, lists the sub-packages
├── packages/
│   └── agentcore/                 # shared library sub-package
│       └── source/agentcore/      # types, schema (UDAs), crds, prompt, reconcile, jobs, env
├── controller/                    # binary 1 sub-package: the operator
│   └── source/app.d
├── supervisor/                    # binary 2 sub-package: the in-pod supervisor
│   └── source/app.d
├── deploy/                        # CRDs, RBAC, NetworkPolicy, controller manifest, namespace
└── website/                       # this documentation site (Astro Starlight)
```

Unit tests live inline in the `agentcore` modules as D `unittest` blocks; run them with
`dub test :agentcore`.

## Mapping to the concepts

| Artifact | Produced by | Documented in |
| --- | --- | --- |
| `agentcore` (lib) | `packages/agentcore/` | [Architecture](/concepts/architecture/) |
| `ai-agent-controller` | `controller/` | [Controller lifecycle](/concepts/controller-lifecycle/) |
| `ai-agent-supervisor` | `supervisor/` | [Agent runtime](/concepts/agent-runtime/) |
| CRDs / RBAC | `deploy/` | [Reference](/reference/crd-agent/) |

:::note
Bootstrapped so far: the CRD model (with attribute metadata), prompt templating, the pure reconcile
state machine, and thin binaries that link the library. The Kubernetes client, Job builder, and the
supervisor's process handling are next — see the [roadmap](/contribute/roadmap/).
:::
