---
title: AgentDefinition CRD
description: Full field reference for the AgentDefinition custom resource.
---

**Group/Version:** `agents.re-cinq.com/v1` · **Kind:** `AgentDefinition` · **Scope:**
Namespaced · **Short names:** `agentdef`, `ad`

The recipe. It has a `spec` and no `status`.

:::note[API version]
`v1` is the stored, stable version. The previous `v1alpha1` is still **served but deprecated**, so
existing clients keep working; the API server converts between them automatically (the schemas are
identical), so existing objects need no migration. Use `agents.re-cinq.com/v1` in new manifests.
:::

## `spec`

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `description` | string |  | Human summary for operators. |
| `model` | string | runtime default | Model id, e.g. `claude-sonnet-4-6`. Selects the tool adapter. |
| `prompt` | string |  | Task template; `{placeholder}` tokens filled from Agent `parameters`. |
| `allowed_tools` | []string |  | Permission rules, e.g. `Bash(npm run test:*)`. |
| `disallowed_tools` | []string |  | Scoped denials, e.g. `Bash(rm *)`. |
| `permission_mode` | enum | `bypass` | `auto` enforces allow/deny lists; `bypass` grants all. |
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

### `spec.output`

| Field | Type | Notes |
| --- | --- | --- |
| `format` | enum | `text`, `json`, or `stream-json`. |
| `schema` | JSON Schema | Optional validation of the result. |
| `select` | [] object | Event filters: `{event(tool_call\|message\|tool_result\|result\|usage), tool?, role?, contains?}`. |
| `sinks` | [] object | `{type(stdout\|http\|file), url?, headers_secret?, path?}`. |

The events delivered to these `sinks` — their envelope, lifecycle and `stream-json` payloads,
and the HTTP delivery contract — are documented in the
[Notification API](./notification-api.md) reference.
