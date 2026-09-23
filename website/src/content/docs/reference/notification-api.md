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
| `stdout` | Echoed to the pod logs. Always happens regardless of configured sinks — it is the source of truth. Carries the **bare** event line, not the envelope: pod logs (and the `Agent.status.output` capped from them) come from exactly one pod, so attribution adds nothing there and downstream `status.output` parsers expect the tool's own line. |
| `http` | `POST`ed to the sink's `url` **wrapped in the envelope below**, one event per request. This is how a UI or indexer consumes runs live. |
| `file` | Appended to the sink's `path` on the container filesystem, wrapped in the envelope below. |

Both the init container (setup phase) and the supervisor (agent phase) emit through the same path, so the two phases' streams look identical to a listener. A single run therefore produces one uniform event stream from start to finish.

## The envelope

Every event **delivered to an http or file sink** is wrapped in an envelope carrying the run's identity, so a downstream workflow — where streams from many pods merge — can correlate it back to its agent and pod. The envelope is applied exactly once, at sink delivery; wrapping an already-wrapped line is refused (enforce) rather than nested:

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
| `status` | enum | `started`, `installing`, `running`, `installed`, `succeeded`, or `failed`. `installed` is init-only: an agent CLI is in place, reported right after its tool's steps. |
| `tool` | string | Optional. The tool or package-manager involved (e.g. `apt`). |
| `version` | string | Optional, on `installed`. The agent CLI's version, as its own `--version` reports it. Absent when the CLI could not say. |
| `origin` | string | Optional, on `installed`. Where the CLI came from: `baked` (copied from the agent image, no network), `downloaded` (the vendor's installer), or `present` (already on `PATH`, nothing installed). |
| `reason` | string | Optional. A short failure slug — e.g. `not-found` (agent binary missing), `spawn` (process failed to start). |
| `exitCode` | int | Optional. The agent process exit code. `0` is present and meaningful; it is not treated as empty. |

Empty optional fields are omitted. Examples:

```json
{ "kind": "lifecycle", "phase": "init", "status": "started" }
{ "kind": "lifecycle", "phase": "init", "status": "installing", "tool": "apt" }
{ "kind": "lifecycle", "phase": "init", "status": "installed", "tool": "claude", "version": "2.1.267", "origin": "baked" }
{ "kind": "lifecycle", "phase": "agent", "status": "started" }
{ "kind": "lifecycle", "phase": "agent", "status": "succeeded", "exitCode": 0 }
{ "kind": "lifecycle", "phase": "agent", "status": "failed", "reason": "not-found" }
{ "kind": "lifecycle", "phase": "agent", "status": "failed", "exitCode": 42 }
```

A run that reaches the agent phase emits, at minimum, an `agent`/`started` at launch and an `agent`/`succeeded` or `agent`/`failed` (carrying `exitCode`) when it ends — so a hook can branch on the outcome without parsing logs.

## File events

Artifacts the recipe declared under [`spec.output.watch`](./crd-agentdefinition.md). The supervisor reads each declared path once the agent has exited and raises one event per entry, tagged `"kind": "file"`.

This exists because the subsystem streams what an agent *says*: an agent whose deliverable is a file had no way to hand it back, so callers asked the model to repeat the artifact as its closing message — putting an LLM in the delivery path of a deterministic step, and silently producing nothing whenever the model summarised instead.

| Field | Type | Notes |
| --- | --- | --- |
| `kind` | string | Always `"file"`. |
| `event` | string | The recipe-declared event name, so one run can emit several artifacts. |
| `path` | string | The resolved path read from. Relative paths resolve against `WORKSPACE_DIR`. |
| `content` | string | The file's contents. Absent when `reason` is set or the file was uploaded. |
| `uploaded` | bool | Only for a watch with [`upload`](./crd-agentdefinition.md#specoutputwatchupload): `true` once the upload URL accepted the bytes (2xx). |
| `bytes` | int | With `uploaded`: the size of the uploaded file. |
| `sha256` | string | With `uploaded`: the lowercase hex SHA-256 of the uploaded bytes, so a consumer can check what it stored. |
| `reason` | string | Optional. Why there is no content: `missing`, `too-large`, `unreadable`, or `upload-failed` (the upload URL refused the file, or stayed unreachable or failing through every retry). |

```json
{ "kind": "file", "event": "report.ready", "path": "/workspace/out/report.json", "content": "{\"ok\":true}" }
{ "kind": "file", "event": "report.ready", "path": "/workspace/out/report.json", "reason": "missing" }
{ "kind": "file", "event": "report.ready", "path": "/workspace/out/report.md", "uploaded": true, "bytes": 48213, "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" }
{ "kind": "file", "event": "report.ready", "path": "/workspace/out/report.md", "reason": "upload-failed" }
```

The size caps differ by delivery. **Inline** content is capped at **128 KiB**, below the
`status.output` cap that would otherwise truncate it mid-JSON. An **uploaded** file never rides the
stream, so its cap is **64 MiB** by default, overridable with `MAX_UPLOAD_BYTES` (bytes) in the
recipe's `resources.env`; the supervisor reads the file into memory to hash and send it. Either cap
exceeded reports `too-large`. The upload URL's `{agent}` and `{event}` placeholders expand to the
run's Agent name and the watch's event name. An upload that cannot connect, or is answered 408,
429 or 5xx, is sent again up to five times with backoff from one second doubling to eight, which
outlasts a receiver's rollout; any other non-2xx is a refusal and is sent once, since the same bytes
get the same answer. The event reports what the last attempt came to, and the supervisor logs only
the HTTP status — never the body or the header.

Every upload carries **`X-Agent-Exit-Code`**, the agent process's exit code as decimal text (`0` on
success). The watched file is read after the agent exits, whatever the outcome, so without that
header a receiver cannot tell a finished result from whatever a failed run happened to leave on
disk. It is sent on every attempt, alongside any headers `headers_secret` resolves to.

Two guarantees a consumer can rely on:

- **File events precede the terminal event.** They are raised before `agent`/`succeeded`\|`failed`, so a consumer that treats the terminal event as end-of-stream still receives them.
- **A declared artifact always reports.** A file the agent never produced still raises its event carrying `reason`, so a consumer learns the run delivered nothing instead of waiting on an event that never arrives.

A path that escapes `WORKSPACE_DIR` is refused and raises nothing — that is a recipe bug, not a run outcome.

## Agent (tool-native) events

Between the lifecycle events, the supervisor forwards each line the agent tool writes, verbatim — to pod-log stdout as-is, and to the sinks as the envelope's `event`. **These are produced by the tool adapter, not the subsystem** — the schema below describes Claude Code's `stream-json` output and may vary by model or tool. Treat the subsystem-owned contract (the envelope and lifecycle events above) as stable; treat these as the tool's format.

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
