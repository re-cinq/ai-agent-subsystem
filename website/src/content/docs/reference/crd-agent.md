---
title: Agent CRD
description: Full field reference for the Agent custom resource.
---

**Group/Version:** `agents.re-cinq.com/v1alpha1` · **Kind:** `Agent` · **Scope:** Namespaced ·
**Short name:** `agt`

One run. It has a `spec` (your desired run) and a `status` (owned by the controller).

## `spec`

| Field | Type | Notes |
| --- | --- | --- |
| `stationRef` | string | *Required.* Station to run in (which selects the recipe). |
| `parameters` | map[string]string | Per-run values; fill the prompt `{placeholder}` tokens and pass to the agent. |
| `taskId` | string | Optional external id for correlation. |
| `targetRepo` | string | Optional repo in `owner/name` form. |
| `branch` | string | Optional git branch. |

## `status`

| Field | Type | Notes |
| --- | --- | --- |
| `phase` | enum | `Pending`, `Running`, `Succeeded`, or `Failed`. |
| `jobName` | string | Name of the created Job. |
| `startedAt` | date-time | When the run began. |
| `completedAt` | date-time | When the run ended. |
| `exitCode` | int | Process exit code (`0` = success). |
| `output` | string | Captured summary: the truncated tail of pod logs, capped at `MAX_OUTPUT_BYTES` (default 256 KiB) to stay under etcd's per-object limit. |
| `failureReason` | string | Human-readable reason on failure. Also set when a run reaches a terminal phase but its result couldn't be fully read back - e.g. `run output unavailable: pod garbage-collected` or `run record unavailable: Job garbage-collected before its result was observed`. |
| `prUrl` | string | Pull-request URL when applicable. |

Phase transitions are driven by the
[controller lifecycle](/concepts/controller-lifecycle/).
