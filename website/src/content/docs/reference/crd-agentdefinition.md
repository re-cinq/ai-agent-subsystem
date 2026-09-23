---
title: AgentDefinition CRD
description: Full field reference for the AgentDefinition custom resource.
---

**Group/Version:** `agents.re-cinq.com/v1alpha1` · **Kind:** `AgentDefinition` · **Scope:**
Namespaced · **Short names:** `agentdef`, `ad`

The recipe. It has a `spec` and no `status`.

## `spec`

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `description` | string |  | Human summary for operators. |
| `model` | string | runtime default | Model id, e.g. `claude-sonnet-4-6`. Selects the tool adapter. |
| `prompt` | string |  | Task template; `{placeholder}` tokens filled from Agent `parameters`. |
| `allowed_tools` | []string |  | Permission rules, e.g. `Bash(npm run test:*)`. |
| `disallowed_tools` | []string |  | Scoped denials, e.g. `Bash(rm *)`. |
| `permission_mode` | enum | `auto` | `auto` enforces allow/deny lists; `bypass` grants all. |
| `max_turns` | int |  | Agentic turn cap; omit for uncapped. |
| `resources` | object |  | Run inputs; see below. |
| `output` | object |  | Result contract; see below. |
| `tool_config` | object |  | Raw passthrough for tool-specific knobs; unknown fields preserved. |

### `spec.resources`

| Field | Type | Notes |
| --- | --- | --- |
| `env` | [] `{name, value}` | Plain environment variables. |
| `secrets` | [] `{name, ref}` | `name` is the env var; `ref` is an allowlisted secret-store key. |
| `mcp_servers` | [] object | `{name, transport(stdio\|http\|sse), command?, args?, url?, headers_secret?}`. |
| `repos` | [] object | `{name, url, ref?, path?, token_secret?}`. |
| `skills` | []string | Skill names staged into the run's `$HOME/.claude/skills`, fetched from `skills_source` as `<source>/<name>.tar.gz`. The recipe declares intent; each adapter realizes it. |
| `skills_source` | string | Base URL of the skill/settings registry. The init also fetches `<source>/settings.json` (Claude's flat session settings) and `<source>/hooks/<vendor>.tar.gz` — the hook bundle for the vendor the `model` routes to, in that vendor's native format, extracted relative to `$HOME`. Empty means no fetch — the cloned repo's own `.claude/skills` is still staged. |
| `conversation` | object | `{source, id?, pin?, headers_secret?}` — a previous run this one continues. The init restores its state before the agent starts; the supervisor saves this run's own state as `pin`. `id` is opaque to the subsystem. |

### `spec.output`

| Field | Type | Notes |
| --- | --- | --- |
| `format` | enum | `text`, `json`, or `stream-json`. |
| `schema` | JSON Schema | Optional validation of the result. |
| `select` | [] object | Event filters: `{event(tool_call\|message\|tool_result\|result\|usage), tool?, role?, contains?}`. |
| `sinks` | [] object | `{type(stdout\|http\|file), url?, headers_secret?, path?}`. |
| `watch` | [] object | `{event, path, upload?}` — files the run is expected to produce; each is raised as a named `kind:"file"` event once the agent exits. Relative paths resolve against `WORKSPACE_DIR`. Inline content is capped at 128 KiB; set `upload` to deliver larger files by reference. |

#### `spec.output.watch[].upload`

Without `upload`, the file's contents ride the event (`content`). With it, the supervisor POSTs the
file's bytes to a URL and the event carries only its size and digest — for artifacts past the inline
cap, or that should never pass through the event stream and `status.output`.

Every upload also carries `X-Agent-Exit-Code`, the agent's exit code: the file is read after the
agent exits, whatever the outcome, so a receiver can tell a failed run's file from a result.

| Field | Type | Notes |
| --- | --- | --- |
| `url` | string | *Required.* Where the bytes are POSTed (`Content-Type: application/octet-stream`). `{agent}` expands to the run's Agent name and `{event}` to the watch's event name, each URL-encoded — a watch is declared once per recipe, while its destination is usually per run. |
| `headers_secret` | string | Optional. A key in the `agent-secrets` Secret holding a header block sent with the upload, resolved exactly as a sink's `headers_secret`. |

```yaml
output:
  watch:
    - event: report.ready
      path: out/report.md
      upload:
        url: https://files.example.com/runs/{agent}/{event}
        headers_secret: files-auth
```

Uploads are capped at 64 MiB by default; set `MAX_UPLOAD_BYTES` (bytes) in `resources.env` to change
it. A larger file is not sent and reports `reason: "too-large"`; an upload that is refused, or stays
unreachable or failing through its retries, reports `reason: "upload-failed"`. See [file events](./notification-api.md#file-events).

The events delivered to these `sinks` — their envelope, lifecycle and `stream-json` payloads,
and the HTTP delivery contract — are documented in the
[Notification API](./notification-api.md) reference.
