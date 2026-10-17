---
title: AgentSpawner CRD
description: Field reference for the AgentSpawner custom resource, which creates Agents on a cron schedule.
---

**Group/Version:** `agents.re-cinq.com/v1beta1` · **Kind:** `AgentSpawner` · **Scope:** Namespaced ·
**Short name:** `asp`

Creates an Agent in a Station on a cron schedule. It has a `spec` you write and a `status` the
controller writes. The kind was added at `v1beta1` and is not served at `v1alpha1`. For a walkthrough,
see [Schedule runs](../tasks/schedule-runs.md).

`kubectl get asp` prints the `Schedule`, `Station`, `Suspend`, `Last Schedule` and `Age` columns.

## `spec`

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `stationRef` | string | *required* | The Station each spawned Agent runs in. A DNS-1123 name. |
| `schedule` | string | *required* | Five-field cron expression, evaluated in **UTC**. See [Schedule syntax](#schedule-syntax). |
| `parameters` | map[string]string | `{}` | Copied as-is into every spawned Agent's `spec.parameters`; they fill the recipe's `{name}` prompt tokens. |
| `concurrencyPolicy` | enum | `Allow` | `Allow` starts a run on every tick. `Forbid` skips a tick while an Agent this spawner created is still `Pending` or `Running`. An unknown value is treated as `Allow`. |
| `suspend` | bool | `false` | `true` stops new runs. Runs already started are not touched. |

## `status`

| Field | Type | Notes |
| --- | --- | --- |
| `lastScheduleTime` | date-time | The schedule time of the last tick the controller handled, whether it created an Agent or skipped it under `Forbid`. This is the slot time (for example `03:00:00Z`), not when the Agent was created. |
| `lastAgent` | string | Name of the last Agent this spawner created. |

## Schedule syntax

Five fields separated by spaces: minute (`0-59`), hour (`0-23`), day of month (`1-31`), month
(`1-12`) and day of week (`0-7`, where both `0` and `7` are Sunday). Each field is one of:

| Form | Example | Meaning |
| --- | --- | --- |
| `*` | `*` | Every value. |
| number | `5` | That value. |
| range | `9-17` | Every value from 9 to 17. |
| step | `*/15`, `9-17/2`, `5/15` | Every 15th value; every 2nd value from 9 to 17; every 15th value from 5 to the field's maximum. |
| list | `0,30` | Any of the comma-separated items, each of which can be any form above. |

When both day of month and day of week are restricted (neither starts with `*`), a day that matches
either one fires. `0 9 1 * 1` runs at 09:00 on the 1st of each month and on every Monday.

Names (`jan`, `mon`), `@daily`-style macros, `?`, `L` and `W` are not supported. The CRD schema only
checks that there are five fields. The controller rejects any other bad value when it reads the
spawner: it logs `agent spawner <name>: cron <field> "<value>": ...` and skips that spawner until the
schedule is fixed. A schedule that can never fire (`0 0 30 2 *`) is logged as
`cron schedule never fires`.

## What the controller does

Only the leader replica runs spawners. Every 15 seconds it lists the AgentSpawners in its namespace.
For each one it takes the latest schedule time at or before now. If that is later than
`status.lastScheduleTime` (or than the spawner's `creationTimestamp` when it has never fired), the
spawner is due:

1. Under `Forbid`, it lists the Agents with the label `agents.re-cinq.com/spawner=<name>`. If any is
   `Pending` or `Running`, it records the slot in `status.lastScheduleTime` and creates nothing.
2. Otherwise it creates the Agent and then sets `status.lastScheduleTime` and `status.lastAgent`.

A run starts at most 15 seconds after its schedule time. A new spawner first fires at the first
schedule time after it was created, not at once.

The spawned Agent looks like this (for the slot `2026-10-17T03:00:00Z`):

```yaml
apiVersion: agents.re-cinq.com/v1beta1
kind: Agent
metadata:
  name: nightly-story-29870100         # <spawner>-<slot in minutes since the Unix epoch>
  namespace: ai-agents
  labels:
    agents.re-cinq.com/spawner: nightly-story
  ownerReferences:
    - apiVersion: agents.re-cinq.com/v1beta1
      kind: AgentSpawner
      name: nightly-story
      controller: true
      blockOwnerDeletion: true
spec:
  stationRef: story-writer
  parameters: { title: "The Night Shift" }
```

- **The name comes from the slot.** A second create for the same slot is rejected by the API server
  as already existing, so the slot still gets one run. Names longer than 63 characters are shortened
  with a hash.
- **Deleting the spawner deletes its Agents** (and their Jobs) through the owner reference.
- **History** is pruned by the Station's `successfulRunsHistoryLimit` and `failedRunsHistoryLimit`,
  the same as any other Agent of that Station. The spawner has no limit of its own.

### Restarts, failover and outages

The last slot handled is stored in the spawner's `status`, not in the controller's memory. A new
leader reads it and carries on: a slot already handled is not run again, and a slot that came due
while no replica was leader is run when the next one takes over.

After an outage that missed several slots, the spawner runs once, for the latest missed slot, and
does not replay the others. An hourly spawner that comes back at 13:20 after missing 11:00, 12:00
and 13:00 creates one Agent, for 13:00.

If the controller stops between creating the Agent and writing the status, the next leader tries
the same slot again. The create is rejected because the Agent already exists, and the status is
then written.

## Parameters and reserved keys

`parameters` are copied as they are, including the reserved `git_credential` and
`git_credential_url` keys the run uses for brokered git access (see
[Agent runtime](../concepts/agent-runtime.md)). A spawner is written by someone who can create
Agents anyway, so this grants nothing new. A run credential is usually short-lived, though, and
putting one in a spawner stores it in the cluster in plain text and reuses it on every run. Leave
those keys out of a spawner unless the credential is meant to be long-lived.

## RBAC

The controller role has `create` on `agents`, `get`/`list`/`watch` on `agentspawners` and `patch`
on `agentspawners/status`. The `agent-launcher` caller role can create, read, update and delete
AgentSpawners. See [RBAC & network](./rbac-and-network.md).

## From TypeScript and Go

`@re-cinq/agent-contracts` exports the `AgentSpawner`, `AgentSpawnerSpec`, `AgentSpawnerStatus` and
`SpawnerConcurrencyPolicy` types. The Go module has the same types plus `AgentSpawnerList`,
registered by `AddToScheme`.
