---
title: Agent CRD
description: Full field reference for the Agent custom resource.
---

**Group/Version:** `agents.re-cinq.com/v1beta1` · **Kind:** `Agent` · **Scope:** Namespaced ·
**Short name:** `agt`

One run. It has a `spec` (your desired run) and a `status` (owned by the controller).

## `spec`

| Field | Type | Notes |
| --- | --- | --- |
| `stationRef` | string | *Required.* Station to run in (which selects the recipe). |
| `parameters` | map[string]string | Per-run values; fill the prompt `{placeholder}` tokens and pass to the agent. |
| `taskId` | string | Optional external id for correlation. |
| `model` | string | Optional model id for this run; overrides the AgentDefinition's `model`, including which agent CLI runs (e.g. a `gemini-*` model runs gemini-cli). Omitted, the definition's model applies. |
| `targetRepo` | string | Optional repo in `owner/name` form. With [`delivery.pullRequest`](../tasks/open-pull-requests.md), the repo the pull request opens on. |
| `branch` | string | Optional git branch. With `delivery.pullRequest`, the branch the work is pushed to; default `agent/<Agent name>`. |
| `files` | [] object | `{path, url, headers_secret?}` — files the init downloads into the workspace before the agent starts. Only the references travel; see [below](#specfiles). |
| `resumeSession` | string | Optional. The `status.sessionId` of an earlier run to continue. Needs a definition with `execution: realtime` and a `resources.conversation.source`, and a vendor that keeps conversation state (not opencode or `exec`). The saved conversation is restored and the definition's prompt is not sent. |

### `spec.files`

Per-run inputs by reference. The Agent carries where each file comes from and where it goes, never
its contents, so a run's inputs can be larger than etcd's per-object limit would allow in the CR.

| Field | Type | Notes |
| --- | --- | --- |
| `path` | string | *Required.* Destination. A relative path resolves against `WORKSPACE_DIR` (`/workspace`); an absolute one must already be inside it. |
| `url` | string | *Required.* `http://` or `https://` URL the file is streamed from. No other scheme is fetched. |
| `headers_secret` | string | Optional. A key in the `agent-secrets` Secret holding a header block (`Name: value` lines) sent with the download — the same convention as a sink's `headers_secret`. |

```yaml
spec:
  stationRef: writer-station
  files:
    - path: notes/brief.md
      url: https://files.example.com/runs/42/brief.md
      headers_secret: files-auth
```

- **Confined to the workspace.** A path that escapes `WORKSPACE_DIR` — through `..`, an absolute path
  elsewhere, or a symlink a cloned repo carries — fails the init, naming the path.
- **Parents are created.** `notes/brief.md` needs no `notes/` to exist first.
- **Written after the repo clones, before the agent starts.** A clone replaces its destination, so a
  file placed first could be deleted with it; writing afterwards also lets a file land *inside* a
  cloned repo. The files are handed to the agent's uid along with the rest of the workspace.
- **A failed download fails the run.** A non-2xx response or an unreachable URL fails the init
  container with a message naming the path (never the header), and the Agent reaches `Failed`
  before the agent starts. A declared input is one the prompt relies on.
- **The header stays with the init.** The references (`AGENT_FILES`) and the secrets they name are
  injected into the init container only; the agent container never sees them.

## `status`

| Field | Type | Notes |
| --- | --- | --- |
| `phase` | enum | `Pending`, `Running`, `Succeeded`, or `Failed`. |
| `jobName` | string | Name of the created Job. |
| `startedAt` | date-time | When the run began. |
| `completedAt` | date-time | When the run ended. |
| `exitCode` | int | Process exit code (`0` = success). |
| `output` | string | Captured summary: the truncated tail of pod logs, capped at `MAX_OUTPUT_BYTES` (default 256 KiB) to stay under etcd's per-object limit. |
| `failureReason` | string | Human-readable reason on failure. Also set when a run reaches a terminal phase but its result couldn't be fully read back, e.g. `run output unavailable: pod garbage-collected` or `run record unavailable: Job garbage-collected before its result was observed`. |
| `prUrl` | string | The pull request the run opened, for a definition with [`delivery.pullRequest`](../tasks/open-pull-requests.md). Read from the last [delivery event](./notification-api.md#delivery-events) in the `courier` container's log when the run ends, never from the agent's own log. Empty when nothing was delivered. |
| `sessionId` | string | The agent CLI's session id, from the last [session event](./notification-api.md#session-events) in the run's pod log. While a realtime session runs, the prompt API patches it as soon as a prompt's reply carries a new id; it is set again from the pod log when the run ends. Empty for vendors that announce none. |
| `batchId` | string | Batch runs only. The provider's batch id, set when the controller submits the batch: `msgbatch_...` for Anthropic, `batch_...` for OpenAI, and for Gemini the `<id>` of the operation name `batches/<id>`. Kept after a fallback for the audit trail. |
| `batchProvider` | string | Batch runs only. The batch API the run was submitted to: `anthropic`, `gemini` or `openai`, from the vendor the model routes to. |
| `batchFallback` | bool | Batch runs only. `true` once the batch timed out with `onTimeout: fallback` and the run switched to a CLI Job. |
| `batchCleanupAttempts` | int | Batch runs only. Failed attempts to delete the batch's provider-side objects. |

For a [batch run](../tasks/batch-runs.md), `output` holds the event lines the CLI of the vendor the
model routes to prints for a single-turn run (Claude `stream-json`, Codex `exec --json`, Gemini
`stream-json`), which the controller builds from the batch result, capped at `MAX_OUTPUT_BYTES` in the same way. `exitCode` is `0` on success
and `1` on failure, and `jobName` stays empty unless the run fell back to a Job.

## Finalizer

When the controller submits a batch, it adds the finalizer `agents.re-cinq.com/batch-cleanup` to the
Agent. A provider batch has no owner reference, so without the finalizer a deleted Agent would leave a
running, billed batch behind. While the finalizer is present, deleting the Agent makes the controller
cancel the batch if it is still in flight, delete the batch at the provider, and then remove the
finalizer so the delete completes.

The controller also removes the finalizer once it has cleaned up a finished batch, so history pruning
deletes the Agent straight away. If the provider cleanup fails, the controller retries on later
reconciles and counts the failures in `status.batchCleanupAttempts`. After 5 failed attempts it removes
the finalizer anyway and leaves the provider object behind, so a delete never stays stuck. Cleanup
failures never change the Agent's phase.

The finalizer is added and removed with JSON patches (`application/json-patch+json`) that append to
or remove one entry of `metadata.finalizers`, so finalizers that other controllers add to the same
Agent are left alone.

Phase transitions are driven by the
[controller lifecycle](../concepts/controller-lifecycle.md).
