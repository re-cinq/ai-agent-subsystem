---
title: Agent
description: "One run: a Station reference, parameters, and a status that tracks the lifecycle."
---

An `Agent` is **one run**. It references a [Station](./station.md), supplies
per-run parameters, and carries a `status` the controller updates as the run progresses.

```mermaid
flowchart LR
    AD["AgentDefinition"] --> ST["Station"] --> AG["Agent<br/>one run"]:::hi --> JB["Job"]
    classDef hi fill:#2f5fd8,color:#fff,stroke:#16224f;
    class AG hi
```

## Spec

- **`stationRef`**: the Station to run in (which in turn selects the recipe).
- **`parameters`**: a string map used to fill the recipe's `{placeholder}` tokens and passed to the
  agent process.
- **`taskId`**: optional external id for correlation.
- **`targetRepo`** / **`branch`**: optional repo (`owner/name`) and git branch metadata.
- **`files`**: optional per-run input files, by reference: `{path, url, headers_secret?}`. The init
  container downloads each into the workspace before the agent starts, so a run can be handed a
  document without its contents ever sitting in the CR. The recipe says what the agent does; `files`
  and `parameters` are what *this* run does it to.

Agents are usually created with `generateName` (for example `bug-fixer-run-`) so Kubernetes assigns
a unique name per run.

## Status

The controller owns `status`:

- **`phase`**: `Pending` → `Running` → `Succeeded` | `Failed`.
- **`jobName`**: the Job the controller created.
- **`startedAt`** / **`completedAt`**: run timestamps.
- **`exitCode`**: the process exit code (`0` = success).
- **`output`**: captured summary output (the truncated tail of the pod logs).
- **`failureReason`**: a human-readable reason when the run fails.
- **`prUrl`**: a pull-request URL when applicable.

The phase transitions are driven by the controller's reconcile loop; see
[Controller lifecycle](./controller-lifecycle.md). The full field reference
is in [Agent CRD](../reference/crd-agent.md).
