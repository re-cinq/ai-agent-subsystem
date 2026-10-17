---
title: Station CRD
description: Full field reference for the Station custom resource.
---

**Group/Version:** `agents.re-cinq.com/v1beta1` · **Kind:** `Station` · **Scope:** Namespaced ·
**Short name:** `stn`

The runtime template. It has a `spec` and no `status`.

## `spec`

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `agentDefRef` | string | *required* | Name of the `AgentDefinition` this Station runs. |
| `template` | PodTemplateSpec | *required* | Standard Pod template. The container named `agent` is wired with the recipe and injected runtime. |
| `deadlineMinutes` | int | `30` | Wall-clock limit; becomes the Job's `activeDeadlineSeconds` (× 60). |
| `maxConcurrentRuns` | int | `0` | Max Agents of this Station `Running` at once; `0` is unlimited. A new Agent waits in `Pending` while at the limit. See [Setting limits](../tasks/set-limits.md). |
| `concurrencyPolicy` | enum | `Allow` | What happens to a new run while at the limit: `Allow` queues it in `Pending`, `Forbid` caps the Station at a single run (extras wait), `Replace` cancels the oldest `Running` run and starts the new one. See [Setting limits](../tasks/set-limits.md). |
| `successfulRunsHistoryLimit` | int | `3` | Succeeded Agents to keep before pruning the oldest. |
| `failedRunsHistoryLimit` | int | `3` | Failed Agents to keep before pruning the oldest. |

## Batch runs

When the Station's AgentDefinition sets `execution: batch`, the run is a provider batch request
rather than a Job, and the fields above apply as follows. See [batch runs](../tasks/batch-runs.md).

- **`maxConcurrentRuns` and `concurrencyPolicy`** count batch Agents like any other run: an in-flight
  batch is `Running` and takes a slot. Under `Allow` and `Forbid` a new Agent waits in `Pending` while
  the Station is full. Under `Replace` the oldest `Running` Agent is deleted to make room and the new
  Agent submits its batch (no Job is created); if the deleted Agent was a batch run, its finalizer
  cancels and cleans up its batch.
- **`deadlineMinutes`** does not limit the batch. The batch wait is set by the definition's
  `batch.timeoutMinutes`. If the batch times out with `onTimeout: fallback`, the fallback Job gets
  `deadlineMinutes` as usual, counted from when that Job is created.
- **The fallback Job takes a slot too.** If the Station is full when a batch times out, the Agent stays
  `Running` with `batchFallback: true` until a slot frees, then its Job is created.
- **`template`** is not used by the batch request itself, which runs in the controller. A fallback Job
  is built from it like any other run.
- **History limits** prune finished batch Agents the same way, by phase and `completedAt`.

## Notes on `template`

- The container named **`agent`** has its `command` overridden by the controller to run the injected
  supervisor; do not set it yourself.
- The base image must be **glibc-based**; the injected runtime is glibc-linked.
- Any volumes, node selectors, tolerations, `runtimeClassName`, and resource limits you set are
  preserved, so a RuntimeClass can run the pod under gVisor or Kata ([Isolate runs](../../tasks/isolate-runs/)). The controller
  adds the bundle `emptyDir` and (if present) a credentials volume mount, and a non-root security
  context.
