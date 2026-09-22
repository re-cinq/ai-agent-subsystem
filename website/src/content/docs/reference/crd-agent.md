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
| `files` | [] object | `{path, url, headers_secret?}` — files the init downloads into the workspace before the agent starts. Only the references travel; see [below](#specfiles). |

### `spec.files`

Per-run inputs by reference. The Agent carries where each file comes from and where it goes, never
its contents, so a run's inputs can be larger than etcd's per-object limit would allow in the CR.

| Field | Type | Notes |
| --- | --- | --- |
| `path` | string | *Required.* Destination. A relative path resolves against `WORKSPACE_DIR` (`/workspace`); an absolute one must already be inside it. |
| `url` | string | *Required.* `http://` or `https://` URL the file is streamed from. No other scheme is fetched. |
| `headers_secret` | string | Optional. A key in the `agent-secrets` Secret holding a header block (`Name: value` lines) sent with the download — the same convention as a sink's or an MCP server's `headers_secret`. |

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
| `prUrl` | string | Pull-request URL when applicable. |

Phase transitions are driven by the
[controller lifecycle](../concepts/controller-lifecycle.md).
