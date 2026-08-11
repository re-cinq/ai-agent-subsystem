---
title: Collect output
description: Read a run's result from status, pod logs, or a streaming http sink.
---

A run's output is available four ways, depending on how immediate you need it — and on whether the
deliverable is what the agent *said* or a file it *wrote*.

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
indexer consumes runs in real time. See [Agent runtime](../concepts/agent-runtime.md)
for how the supervisor produces these events.

A failed POST is retried with capped exponential backoff before the event is dropped — a
transient blip in your listener does not lose events, while a persistently unreachable sink
never blocks or fails the run (the pod logs remain the source of truth).

## Files the run produced

When the deliverable is an artifact rather than a message, declare it under `output.watch` instead of
asking the model to repeat the file as its closing text:

```yaml
output:
  format: stream-json
  sinks:
    - type: stdout
    - type: http
      url: http://collector.my-namespace.svc:8099/notify
  watch:
    - event: planning.result
      path: target/result.json
```

Once the agent exits, the supervisor reads each declared path and raises a named
`{"kind": "file"}` event carrying the file's contents on the sinks above:

```json
{ "kind": "file", "event": "planning.result", "path": "/workspace/target/result.json", "content": "{\"gap\":\"found\"}" }
```

Relative paths resolve against `WORKSPACE_DIR`, and a path escaping it is refused. The event is
raised **before** the terminal `agent/succeeded|failed` lifecycle event, so a consumer that treats
that as end-of-stream still receives it.

A declared artifact always reports. A file the agent never wrote still raises its event, carrying a
`reason` instead of `content`, so your consumer learns the run delivered nothing rather than waiting
on an event that never arrives:

```json
{ "kind": "file", "event": "planning.result", "path": "/workspace/target/result.json", "reason": "missing" }
```

Oversized (>128 KiB) and unreadable files report the same way.

For the exact wire format your listener receives (the event envelope, lifecycle, file and
`stream-json` payloads, the HTTP contract, and the retry env vars), see the
[Notification API](../reference/notification-api.md) reference. For a step-by-step setup with the
example listener, see [Receive notifications](./receive-notifications.md).
