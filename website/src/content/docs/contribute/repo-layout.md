---
title: Repository layout
description: How the D monorepo is organized — two binaries and a shared library.
---

The repository is a single **dub** monorepo, following the structure of
[ogm-server](https://gitlab.com/GISCollective/backend/ogm-server): services at the top level,
reusable code in local sub-packages.

```
ai-agent-subsystem/
├── README.md
├── dub.json                 # root package + sub-packages
├── source/                  # entrypoints for the two binaries
│   ├── controller/          # binary 1: the operator
│   └── supervisor/          # binary 2: the in-pod supervisor
├── packages/
│   └── agentcore/           # shared library (types, k8s client, reconcile, job builder)
├── deploy/                  # CRDs, RBAC, controller manifest, namespace
├── tests/                   # unit tests for agentcore
└── website/                 # this documentation site (Astro Starlight)
```

## Mapping to the concepts

| Artifact | Produced by | Documented in |
| --- | --- | --- |
| `agentcore` | `packages/agentcore` | [Architecture](/ai-agent-subsystem/concepts/architecture/) |
| `controller` binary | `source/controller` | [Controller lifecycle](/ai-agent-subsystem/concepts/controller-lifecycle/) |
| `supervisor` binary | `source/supervisor` | [Agent runtime](/ai-agent-subsystem/concepts/agent-runtime/) |
| CRDs / RBAC | `deploy/` | [Reference](/ai-agent-subsystem/reference/crd-agent/) |

:::note
The D sources are produced by the implementation phase these docs specify. This page describes the
intended layout so contributors know where things will live.
:::
