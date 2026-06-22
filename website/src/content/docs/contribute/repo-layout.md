---
title: Repository layout
description: How the D monorepo is organized — three binaries and a shared library.
---

The repository is a single **dub** monorepo (root `dub.json` with `targetType: none`; every
sub-package lives under `packages/`): reusable code in a shared library, thin executables on top.

```
ai-agent-subsystem/
├── dub.json                       # root: targetType none, lists the sub-packages
├── packages/
│   ├── agentcore/                 # shared library
│   │   └── source/agentcore/      # types, schema (UDAs), crds, prompt, reconcile, jobs, env
│   ├── controller/                # binary: the operator
│   ├── initializer/               # binary: the in-pod init container (ai-agent-init)
│   ├── supervisor/                # binary: the in-pod supervisor
│   ├── crdgen/                    # dev/CI tool: generates deploy/crds from the structs
│   ├── mockagent/                 # test-only: configurable mock agent (ai-agent-mock)
│   └── itest/                     # test-only: supervisor integration suite (ai-agent-itest)
├── deploy/                        # CRDs (generated), RBAC, NetworkPolicy, controller manifest
├── scripts/                       # drift check + supervisor/initializer integration tests
│   └── container/                 # init-container test image + cross-distro runner
└── website/                       # this documentation site (Astro Starlight)
```

Unit tests live inline in the `agentcore` modules as D `unittest` blocks (`dub test :agentcore`); the
supervisor's end-to-end behaviour is covered by an integration suite
(`./scripts/itest-supervisor.sh`) that runs the real binary against the `mockagent`.

## Mapping to the concepts

| Artifact | Produced by | Documented in |
| --- | --- | --- |
| `agentcore` (lib) | `packages/agentcore/` | [Architecture](/concepts/architecture/) |
| `ai-agent-controller` | `packages/controller/` | [Controller lifecycle](/concepts/controller-lifecycle/) |
| `ai-agent-init` | `packages/initializer/` | [Agent runtime](/concepts/agent-runtime/) |
| `ai-agent-supervisor` | `packages/supervisor/` | [Agent runtime](/concepts/agent-runtime/) |
| `ai-agent-crdgen` | `packages/crdgen/` | dev tool — generates `deploy/crds` |
| CRDs / RBAC | `deploy/` | [Reference](/reference/crd-agent/) |

:::note
Bootstrapped so far: the CRD model (with attribute metadata), prompt templating, the pure reconcile
state machine, thin binaries that link the library, and the `crdgen` tool that generates
`deploy/crds` from the model. The Kubernetes client, Job builder, and the supervisor's process
handling are next — see the [roadmap](/contribute/roadmap/).
:::
