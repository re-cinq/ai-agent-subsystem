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
| `model` | string | runtime default | Model id, e.g. `claude-sonnet-4-6`. Selects the tool adapter. The [ModelCatalog](./crd-modelcatalog.md) lists the ids the configured keys can run; the value is not checked against it. |
| `prompt` | string |  | Task template; `{placeholder}` tokens filled from Agent `parameters`. |
| `allowed_tools` | []string |  | Permission rules, e.g. `Bash(npm run test:*)`. |
| `disallowed_tools` | []string |  | Scoped denials, e.g. `Bash(rm *)`. |
| `permission_mode` | enum | `auto` | `auto` enforces allow/deny lists; `bypass` grants all. |
| `max_turns` | int |  | Agentic turn cap; omit for uncapped. |
| `execution` | enum | `interactive` | `interactive` runs the CLI in a Job pod. `batch` sends the prompt to the vendor's batch API from the controller; see [batch runs](../tasks/batch-runs.md). |
| `batch` | object |  | Batch settings, read only when `execution: batch`; see below. |
| `resources` | object |  | Run inputs; see below. |
| `output` | object |  | Result contract; see below. |
| `tool_config` | object |  | Raw passthrough for tool-specific knobs; unknown fields preserved. |

### `spec.resources`

| Field | Type | Notes |
| --- | --- | --- |
| `env` | [] `{name, value}` | Plain environment variables. |
| `secrets` | [] `{name, ref}` | `name` is the env var; `ref` is an allowlisted secret-store key. A Codex run accepts its key as `OPENAI_API_KEY` or `CODEX_API_KEY`, here or in `env`; see [Credentials](../concepts/agent-runtime.md). |
| `mcp_servers` | [] object | `{name, transport(stdio\|http\|sse), command?, args?, url?, headers?: [{name, ref}], env?: [{name, ref}], headers_secret?}`. `headers` (http/sse) and `env` (stdio) take their values from `agent-secrets` keys; `headers_secret` is the deprecated single-`Authorization` form. See [Connect MCP servers](../tasks/connect-mcp-servers.md). Names must be unique; `http`/`sse` need `url`, `stdio` needs `command`; header and env names must be valid and unique. Not supported by the `exec` model; Codex does not support `sse`. A violation fails the Agent with the reason instead of starting a Job. |
| `repos` | [] object | `{name, url, ref?, path?, token_secret?}`. |
| `skills` | []string | Skill names staged into the run's `$HOME/.claude/skills`, fetched from `skills_source` as `<source>/<name>.tar.gz`. The recipe declares intent; each adapter realizes it. |
| `skills_source` | string | Base URL of the skill/settings registry. The init also fetches `<source>/settings.json` (Claude's flat session settings) and `<source>/hooks/<vendor>.tar.gz` — the hook bundle for the vendor the `model` routes to, in that vendor's native format, extracted relative to `$HOME`. Empty means no fetch — the cloned repo's own `.claude/skills` is still staged. |
| `conversation` | object | `{source, id?, pin?, headers_secret?}` — a previous run this one continues. The init restores its state before the agent starts; the supervisor saves this run's own state as `pin`. `id` is opaque to the subsystem. |

### `spec.batch`

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `timeoutMinutes` | int (min 1) | `1440` | Minutes to wait for the batch result, counted from the Agent's `startedAt`. |
| `onTimeout` | enum | `fail` | `fail` cancels the batch and marks the Agent `Failed` with reason `batch timed out`. `fallback` cancels the batch and runs the same definition as an ordinary CLI Job, which is faster but costs full price. |
| `maxTokens` | int (min 1) | `16000` | The batch request's `max_tokens`. Models that always think spend part of it on thinking. |

#### Batch validation

A batch request is one model call with no tool loop, so a definition with `execution: batch` may only
set the fields a single call can use. The controller checks this when it reconciles an Agent, and
fails the Agent with `batch execution does not support <field>` when the definition sets any of:

- `allowed_tools`, `disallowed_tools` or `max_turns`
- `resources.repos`, `resources.mcp_servers`, `resources.skills` or `resources.conversation`
- `output.watch`
- the `exec` model
- a model that routes to neither Claude nor Gemini. OpenAI (Codex) and opencode models are rejected
  with `batch execution does not support codex models` (or `opencode`); support for OpenAI batch is
  coming.

`output.schema` is allowed: it is sent as the request's structured-output format
(`output_config.format` of type `json_schema` for Claude, `generationConfig.responseJsonSchema` with
`responseMimeType: application/json` for Gemini). An empty `model` (on the definition and the Agent)
sends `claude-opus-5-5`; a Gemini model is always named, so it is sent as given. A controller without the batch component fails every batch Agent with
`batch execution is disabled on this controller`; see
[enabling batch](../tasks/batch-runs.md#enable-batch-on-the-controller).

The model checked is the run's model: an Agent's `spec.model` overrides the definition's, as for a
Job, so an Agent that overrides a batch recipe with a Codex or opencode model fails with the same
reason. An Agent that sets `spec.files` on a batch recipe fails with
`batch execution does not support files`, since there is no workspace to download them into.

The definition must also map the vendor's API key: a `resources.secrets` entry named
`ANTHROPIC_API_KEY` for a Claude model, or `GEMINI_API_KEY` for a Gemini model. Without it the
Agent fails with `batch execution needs a resources.secrets entry named <name>`, for example
`batch execution needs a resources.secrets entry named GEMINI_API_KEY`.

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
