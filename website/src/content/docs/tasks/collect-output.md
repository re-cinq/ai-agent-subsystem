---
title: Collect output
description: Read a run's result from status, pod logs, or a streaming http sink.
---

A run's output is available three ways, depending on how immediate you need it.

## From the Agent status

The controller records a summary on the Agent once the run finishes:

```sh
kubectl get agent <name> -o yaml
```

Useful fields under `status`: `phase`, `exitCode`, `output` (a truncated tail of the pod logs,
capped at 256 KiB by default), `failureReason`, `startedAt`, and `completedAt`.

## From the pod logs

While a run is in progress, follow the supervisor's stdout. The supervisor echoes every
`stream-json` line, so the pod logs are the live event stream:

```sh
kubectl -n ai-agents logs -f job/agent-job-<name>
```

## From an http sink

Declare an `http` sink in the recipe's `output` to stream events to your own listener as they happen:

```yaml
output:
  format: stream-json
  sinks:
    - type: stdout
    - type: http
      url: http://collector.my-namespace.svc:8099/notify
```

The supervisor POSTs each `stream-json` line to that URL (fire-and-forget). This is how a UI or an
indexer consumes runs in real time. See [Agent runtime](/concepts/agent-runtime/)
for how the supervisor produces these events.
