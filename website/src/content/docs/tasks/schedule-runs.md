---
title: Schedule runs
description: Start an Agent on a cron schedule with an AgentSpawner, with no external scheduler.
---

An [AgentSpawner](../reference/crd-agentspawner.md) creates an Agent in a Station on a cron
schedule. Use it for recurring work, such as triaging new issues every morning or refreshing
dependencies once a week, without running a scheduler that holds credentials to create Agents. To start runs from GitHub
events instead, see [Trigger runs from GitHub](./trigger-from-github.md).

## Create a spawner

This spawner runs the `story-writer` Station from the [examples](./examples.md) every night at
03:00 UTC (it is `examples/nightly-story.yaml`):

```yaml
apiVersion: agents.re-cinq.com/v1beta1
kind: AgentSpawner
metadata:
  name: nightly-story
  namespace: ai-agents
spec:
  stationRef: story-writer
  schedule: "0 3 * * *"          # minute hour day-of-month month day-of-week, in UTC
  concurrencyPolicy: Forbid      # skip a night while the last run is still going
  parameters:
    title: The Night Shift       # fills {title} in the recipe's prompt
```

```sh
kubectl apply -f examples/story-writer.yaml -f examples/nightly-story.yaml
kubectl -n ai-agents get asp
```

The first run starts at the first schedule time after the spawner was created, within 15 seconds of
it. Schedules are always UTC: `0 3 * * *` is 03:00 UTC whatever the cluster's or your timezone.

## Common schedules

| Schedule | Runs |
| --- | --- |
| `*/5 * * * *` | Every five minutes. |
| `0 * * * *` | Every hour, on the hour. |
| `0 7 * * 1-5` | 07:00 on weekdays. |
| `30 2 * * 0` | 02:30 every Sunday. |
| `0 0 1 * *` | Midnight on the 1st of each month. |

The full syntax is in the [reference](../reference/crd-agentspawner.md#schedule-syntax).

## Find the runs it created

Every spawned Agent has the label `agents.re-cinq.com/spawner=<spawner name>`, and the spawner's
status names the last one:

```sh
kubectl -n ai-agents get agents -l agents.re-cinq.com/spawner=nightly-story
kubectl -n ai-agents get asp nightly-story -o jsonpath='{.status.lastAgent}{"\n"}'
```

Each Agent is named `<spawner>-<number>`, where the number is the schedule time in minutes since the
Unix epoch, so the names sort by schedule time.

## Overlapping runs

With the default `concurrencyPolicy: Allow` a run starts on every tick, even if the previous one is
still going; the Station's `maxConcurrentRuns` still applies, so extra runs wait in `Pending`. With
`Forbid` the spawner skips a tick while any Agent it created is `Pending` or `Running`. A skipped
tick is not made up later: the spawner waits for the next one.

## Pause and resume

```sh
kubectl -n ai-agents patch asp nightly-story --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n ai-agents patch asp nightly-story --type=merge -p '{"spec":{"suspend":false}}'
```

A suspended spawner starts nothing. When it is resumed, the spawner runs once if a schedule time
passed while it was suspended, then follows the schedule again.

## Keep history short

Spawned Agents are ordinary runs of their Station, so the Station's
`successfulRunsHistoryLimit` and `failedRunsHistoryLimit` prune the oldest finished ones. A spawner
that runs every few minutes fills those limits quickly; give it its own Station if you want to keep
its history apart from runs you launch by hand.

## Remove a spawner

```sh
kubectl -n ai-agents delete asp nightly-story
```

The Agents it created are deleted with it, through their owner reference, and so are their Jobs.
To keep them, remove the owner reference first, or delete with `--cascade=orphan`.

## When a spawner does not fire

- **Check `kubectl get asp`.** `Last Schedule` shows the last slot handled. If it is behind, read the
  controller log: `kubectl -n ai-agents logs deploy/agent-controller | grep 'agent spawner'`.
- **A bad schedule** is logged as `agent spawner <name>: cron <field> "<value>": ...` and that
  spawner is skipped until you fix it. The API server only checks that there are five fields.
- **A missing Station** does not stop the spawner. Each Agent is created and goes `Failed`, as any
  Agent with a bad `stationRef` does. Without a Station there are no history limits to prune them,
  so suspend the spawner until the Station exists.
- **Restarts and failover** neither repeat nor drop a run: the last slot is kept in the spawner's
  status. After a long outage the spawner runs once, for the latest missed slot, not once per
  missed slot.
