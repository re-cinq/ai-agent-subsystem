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

If `output` is empty on a terminal Agent, check `failureReason`: when the run pod or its Job was
garbage-collected before the controller could read the result back (e.g. the controller was down
longer than the Job's one-hour TTL), the Agent still finishes but `failureReason` says so
(`run output unavailable: pod garbage-collected` or `run record unavailable: …`) rather than leaving
you guessing at a blank `output`. An `http` sink (below) avoids this entirely by capturing events as
they happen.

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

The supervisor POSTs each `stream-json` line to that URL. This is how a UI or an
indexer consumes runs in real time. See [Agent runtime](/concepts/agent-runtime/)
for how the supervisor produces these events.

A failed POST is retried with capped exponential backoff before the event is dropped — a
transient blip in your listener does not lose events, while a persistently unreachable sink
never blocks or fails the run (the pod logs remain the source of truth). Tune the retry with
these env vars on the run container (defaults: 3 attempts, 200 ms base, 5 s cap); set
`AGENT_SINK_RETRY_ATTEMPTS=1` to restore pure fire-and-forget:

| Env var | Default | Meaning |
| --- | --- | --- |
| `AGENT_SINK_RETRY_ATTEMPTS` | `3` | Total delivery attempts per event (minimum 1). |
| `AGENT_SINK_RETRY_BASE_MS` | `200` | Base backoff, doubled each retry. |
| `AGENT_SINK_RETRY_MAX_MS` | `5000` | Cap on the backoff between retries. |
