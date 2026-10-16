---
title: Prompt API
description: The controller's HTTP API for sending prompts to realtime sessions and closing them.
---

The controller serves the prompt API for [realtime sessions](../tasks/realtime-sessions.md) on port
8082, behind the `agent-controller-api` Service. It exists only with the `deploy/components/realtime`
component applied. Each request is forwarded to the session's run pod, whose supervisor queues or
refuses it.

## Authentication

Every request carries `Authorization: Bearer <api-token>`, the `api-token` key of the `agent-realtime`
Secret. The controller does not forward it. Instead it signs the request to the run pod with that run's
own token, an HMAC-SHA256 of the Agent's uid under the Secret's `signing-key`.

## Endpoints

| Method and path | Body | Success |
| --- | --- | --- |
| `POST /v1/namespaces/<ns>/agents/<name>/prompt` | `{"prompt": "<text>"}` | 202 `{"turn": <n>, "queued": <k>, "sessionId": "<id>"}` |
| `POST /v1/namespaces/<ns>/agents/<name>/close` | none | 202 `{"queued": <k>}` |

- `turn` is the prompt's turn number, counted from 1 across the session, and matches the `turn` of
  its [turn events](./notification-api.md#turn-events).
- `queued` is how many prompts are waiting, this one included.
- `sessionId` is the agent's session id once the supervisor knows it, else `""`. A resumed session and
  a fresh Claude session know it from the start. A fresh Codex or Gemini session learns it from its
  first turn, so the first prompt's reply carries `""` and a later prompt's reply carries the id. When
  it differs from the Agent's `status.sessionId`, the controller records it there.

A close stops new prompts. The queued turns still run, then the session ends and the Agent goes
`Succeeded`.

## Status codes

| Status | Meaning |
| --- | --- |
| 202 | Accepted: the prompt is queued, or the session will close. |
| 400 | The body is not JSON with a non-empty `prompt` string. |
| 401 | The bearer token is missing or wrong. |
| 404 | The namespace is not the controller's (`this controller serves namespace <ns>`), the Agent does not exist (`Agent <name> not found`), or the method or path is not one of the two endpoints (`not found`). |
| 409 | The Agent is not `Running` or has no Job yet (`Agent <name> is <phase>, not a running session`), is not a realtime run (`Agent <name> is not a realtime run`), or the session is closing, which also refuses a second close (`the session is ending`). |
| 413 | The request body is over 200 KiB (`request body too large`, from the controller), or the decoded prompt is over 100 KiB, 102400 bytes (`prompt exceeds 102400 bytes`, from the supervisor). |
| 429 | 16 prompts are already waiting (`too many queued prompts`). The running turn does not count. |
| 502 | The session's supervisor answered something unexpected. |
| 503 | The run pod is not serving (`the session is not serving yet`) or cannot be reached (`the session's pod cannot be reached`). Retry after the `Retry-After` seconds (2). This also covers the moment after a session ended and before the Agent turns terminal, so a caller that keeps getting 503 should check the Agent's phase. |

Error bodies are `{"error": "<message>"}`.

## Run pod endpoint

The supervisor in a realtime run pod listens on port 8090. It offers the same two routes as
`POST /v1/prompt` and `POST /v1/close`, plus an unauthenticated `GET /healthz`, and accepts only the
run's own token. The `agent-job-realtime-ingress` NetworkPolicy lets only controller pods reach it.
Callers use the controller's API, not this port.
