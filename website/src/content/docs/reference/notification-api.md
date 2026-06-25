---
title: Notification API
description: The event envelope, lifecycle and stream-json payloads, and HTTP delivery contract for output sinks.
---

How external code receives events from a run. A run emits a stream of JSON events — wrap them in an envelope, deliver one per request to each configured sink, and a listener sees the agent's progress in real time. This is the primary integration surface for the subsystem.

You declare *where* events go in a recipe's `spec.output.sinks` ([AgentDefinition CRD](./crd-agentdefinition.md)); this page is the *wire format* of what arrives. For a hands-on walkthrough, see [Receive notifications](../tasks/receive-notifications.md).

## Delivery

Every event is delivered to each sink declared in `spec.output.sinks`. There are three sink types:

| `type` | Where it goes |
| --- | --- |
| `stdout` | Echoed to the pod logs. Always happens regardless of configured sinks — it is the source of truth. |
| `http` | `POST`ed to the sink's `url`, one event per request. This is how a UI or indexer consumes runs live. |
| `file` | Appended to the sink's `path` on the container filesystem. |

Both the init container (setup phase) and the supervisor (agent phase) emit through the same path, so the two phases' streams look identical to a listener. A single run therefore produces one uniform event stream from start to finish.

## The envelope

Every event is wrapped in an envelope carrying the run's identity, so a downstream workflow can correlate it back to its agent and pod:

```json
{
  "source": {
    "agent": "bug-fixer-run-1",
    "station": "bug-fixer-station",
    "task": "task-123",
    "pod": "agent-job-bug-fixer-run-1-abcde",
    "namespace": "ai-agents"
  },
  "event": { "kind": "lifecycle", "phase": "agent", "status": "started" }
}
```

### `source`

| Field | Type | Notes |
| --- | --- | --- |
| `agent` | string | The run's name. |
| `station` | string | The station the run belongs to. |
| `task` | string | External correlation id (the Agent's `taskId`), if set. |
| `pod` | string | The run pod's name. |
| `namespace` | string | The run pod's namespace. |

Empty ids are omitted from `source`. A line that is not valid JSON is wrapped as a JSON string (`"event": "…"`) rather than dropped, so a listener never has to guard against malformed bodies.

### `event`

The inner `event` is one of:

- a **lifecycle event** — owned by the subsystem, tagged `"kind": "lifecycle"` (below).
- a **tool-native `stream-json` line** — the agent tool's output, passed through verbatim (below).

## Lifecycle events

Typed notifications raised by both the init container and the supervisor. Tagged `"kind": "lifecycle"` so a consumer can tell them apart from raw agent output.

| Field | Type | Notes |
| --- | --- | --- |
| `kind` | string | Always `"lifecycle"`. |
| `phase` | enum | `init` (setup container) or `agent` (supervisor). |
| `status` | enum | `started`, `installing`, `running`, `succeeded`, or `failed`. |
| `tool` | string | Optional. The tool or package-manager involved (e.g. `apt`). |
| `reason` | string | Optional. A short failure slug — e.g. `not-found` (agent binary missing), `spawn` (process failed to start). |
| `exitCode` | int | Optional. The agent process exit code. `0` is present and meaningful; it is not treated as empty. |

Empty optional fields are omitted. Examples:

```json
{ "kind": "lifecycle", "phase": "init", "status": "started" }
{ "kind": "lifecycle", "phase": "init", "status": "installing", "tool": "apt" }
{ "kind": "lifecycle", "phase": "agent", "status": "started" }
{ "kind": "lifecycle", "phase": "agent", "status": "succeeded", "exitCode": 0 }
{ "kind": "lifecycle", "phase": "agent", "status": "failed", "reason": "not-found" }
{ "kind": "lifecycle", "phase": "agent", "status": "failed", "exitCode": 42 }
```

A run that reaches the agent phase emits, at minimum, an `agent`/`started` at launch and an `agent`/`succeeded` or `agent`/`failed` (carrying `exitCode`) when it ends — so a hook can branch on the outcome without parsing logs.

## Agent (tool-native) events

Between the lifecycle events, the supervisor forwards each line the agent tool writes to stdout, verbatim, as the envelope's `event`. **These are produced by the tool adapter, not the subsystem** — the schema below describes Claude Code's `stream-json` output and may vary by model or tool. Treat the subsystem-owned contract (the envelope and lifecycle events above) as stable; treat these as the tool's format.

Each is a JSON object with a `type` discriminator.

### `system`

Emitted once at the start of the agent's session with setup metadata.

| Field | Type | Notes |
| --- | --- | --- |
| `type` | string | `"system"`. |
| `subtype` | string | e.g. `"init"`. |
| … | | Session metadata (session id, model, tools, working directory). |

### `assistant`

An assistant turn. `message` is an Anthropic Messages API message object.

| Field | Type | Notes |
| --- | --- | --- |
| `type` | string | `"assistant"`. |
| `message` | object | Messages API message: `{ id, role: "assistant", model, content[], stop_reason, usage }`. |

`message.content[]` is a list of content blocks:

| Block `type` | Fields | Notes |
| --- | --- | --- |
| `text` | `text` | Assistant prose. |
| `tool_use` | `id`, `name`, `input` | A tool call. `input` is the tool's parsed arguments. |
| `thinking` | `thinking` | Present when extended thinking is enabled. |

### `user`

Tool results fed back to the agent. `message.content[]` carries `tool_result` blocks.

| Field | Type | Notes |
| --- | --- | --- |
| `type` | string | `"user"`. |
| `message` | object | `{ role: "user", content[] }` where each block is a `tool_result` `{ tool_use_id, content, is_error? }`. |

### `result`

The agent's terminal event, emitted once when the run finishes.

| Field | Type | Notes |
| --- | --- | --- |
| `type` | string | `"result"`. |
| `subtype` | string | e.g. `"success"`, `"error_max_turns"`. |
| `result` | string | The final result text. |
| `is_error` | bool | Whether the run ended in error. |
| `total_cost_usd` | number | Total cost of the run. |
| `num_turns` | int | Number of agentic turns. |
| `duration_ms` | int | Wall-clock duration. |

> Always parse tool-native payloads with a JSON parser, never by string-matching the serialized form — escaping (Unicode, forward slashes) can differ between models.

## HTTP sink contract

For an `http` sink, the subsystem expects your listener to behave as follows:

- It `POST`s to the sink's `url`, **one envelope per request**, with a JSON body.
- Any `2xx` status means the event was delivered. The response body is ignored.
- Use `headers_secret` on the sink to attach authentication headers (e.g. a bearer token) to each request.
- A `GET /healthz → ok` endpoint is the convention used by the [example listener](#example-listener) — handy for readiness checks, not required by the subsystem.

## Delivery & retry

HTTP delivery is best-effort but resilient. A failed `POST` is retried with capped exponential backoff before the event is dropped — a transient blip in your listener does not lose events, while a persistently unreachable sink never blocks or fails the run. The pod logs (`stdout`) remain the authoritative record.

Backoff before the retry following a failed attempt *n* (1-based) is `min(baseMs · 2^(n-1), maxMs)`; with the defaults: 200 ms, 400 ms, 800 ms. Tune with these env vars on the run container; set `AGENT_SINK_RETRY_ATTEMPTS=1` to restore pure fire-and-forget:

| Env var | Default | Meaning |
| --- | --- | --- |
| `AGENT_SINK_RETRY_ATTEMPTS` | `3` | Total delivery attempts per event (minimum 1). |
| `AGENT_SINK_RETRY_BASE_MS` | `200` | Base backoff, doubled each retry. |
| `AGENT_SINK_RETRY_MAX_MS` | `5000` | Cap on the backoff between retries. |

## Configuration

The controller derives the run container's environment from the recipe. You don't normally set these by hand — declare `spec.output.sinks` and the controller injects them — but they define the runtime contract:

| Env var | Meaning |
| --- | --- |
| `AGENT_SINKS` | JSON array of sinks, e.g. `[{"type":"http","url":"http://collector/notify"}]`. |
| `AGENT_NOTIFY_URL` | Convenience shorthand: an http sink URL, appended to the sinks. |
| `AGENT_SINK_RETRY_*` | Retry tuning (see above). |
| `AGENT_NAME`, `STATION_NAME`, `TASK_ID`, `POD_NAME`, `POD_NAMESPACE` | The run identity stamped into every envelope's `source`. |

## Filtering

A recipe can filter which events reach its sinks with `spec.output.select` — events that don't match are still echoed to stdout but not delivered to the sinks. See the `spec.output` field table in the [AgentDefinition CRD](./crd-agentdefinition.md) reference for the selector schema.

## Example listener

A zero-dependency Node.js listener that prints every POSTed event lives in the repository at `examples/notify-listener.mjs`. Run it with `node examples/notify-listener.mjs` (default port `8099`) and point a recipe's http sink at it — see [Receive notifications](../tasks/receive-notifications.md) for the end-to-end walkthrough.
