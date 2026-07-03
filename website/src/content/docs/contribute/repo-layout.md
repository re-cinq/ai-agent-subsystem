---
title: Repository layout
description: "How the D monorepo is organized: three binaries and a shared library."
---

The repository is a single **dub** monorepo (root `dub.json` with `targetType: none`; every
sub-package lives under `packages/`): reusable code in a shared library, thin executables on top.

```
ai-agent-subsystem/
├── dub.json                       # root: targetType none, lists the sub-packages
├── packages/
│   ├── agentcore/                 # shared library
│   │   └── source/agentcore/      # one folder per domain (no package.d):
│   │       ├── crds/              #   CR types + schema (UDAs)
│   │       ├── reconcile/         #   decide() state machine, driver, pruning, concurrency
│   │       ├── kube/              #   KubeClient, Job builder, JSON bodies, bundle paths
│   │       ├── agents/            #   pluggable agent adapters (claude/codex) + prompt
│   │       ├── tools/             #   init-container tools (supervisor/git/claude) + repos
│   │       ├── pkgmanager/        #   apt/dnf/apk detection + bootstrap
│   │       ├── output/            #   event wrapping, sinks, lifecycle, output.select
│   │       └── core/              #   types, env names, exec, log
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
| `agentcore` (lib) | `packages/agentcore/` | [Architecture](../concepts/architecture.md) |
| `ai-agent-controller` | `packages/controller/` | [Controller lifecycle](../concepts/controller-lifecycle.md) |
| `ai-agent-init` | `packages/initializer/` | [Agent runtime](../concepts/agent-runtime.md) |
| `ai-agent-supervisor` | `packages/supervisor/` | [Agent runtime](../concepts/agent-runtime.md) |
| `ai-agent-crdgen` | `packages/crdgen/` | dev tool, generates `deploy/crds` |
| `ai-agent-tsgen` | `packages/tsgen/` | dev tool, generates the `@re-cinq/agent-contracts` TS types |
| CRDs / RBAC | `deploy/` | [Reference](../reference/crd-agent.md) |

:::note
The controller, initializer, and supervisor are implemented and covered by unit + integration
tests; `crdgen`/`tsgen` generate `deploy/crds` and the TypeScript contracts from the annotated
model, with both directions gated against drift in CI. See the [roadmap](./roadmap.md) for direction.
:::
