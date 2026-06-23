---
title: Station CRD
description: Full field reference for the Station custom resource.
---

**Group/Version:** `agents.re-cinq.com/v1alpha1` · **Kind:** `Station` · **Scope:** Namespaced ·
**Short name:** `stn`

The runtime template. It has a `spec` and no `status`.

## `spec`

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `agentDefRef` | string | *required* | Name of the `AgentDefinition` this Station runs. |
| `template` | PodTemplateSpec | *required* | Standard Pod template. The container named `agent` is wired with the recipe and injected runtime. |
| `deadlineMinutes` | int | `30` | Wall-clock limit; becomes the Job's `activeDeadlineSeconds` (× 60). |
| `maxConcurrentRuns` | int | `0` | Max Agents of this Station `Running` at once; `0` is unlimited. A new Agent waits in `Pending` while at the limit. See [Setting limits](/tasks/set-limits/). |
| `successfulRunsHistoryLimit` | int | `3` | Succeeded Agents to keep before pruning the oldest. |
| `failedRunsHistoryLimit` | int | `3` | Failed Agents to keep before pruning the oldest. |

## Notes on `template`

- The container named **`agent`** has its `command` overridden by the controller to run the injected
  supervisor - do not set it yourself.
- The base image must be **glibc-based**; the injected runtime is glibc-linked.
- Any volumes, node selectors, tolerations, and resource limits you set are preserved. The controller
  adds the bundle `emptyDir` and (if present) a credentials volume mount, and a non-root security
  context.
