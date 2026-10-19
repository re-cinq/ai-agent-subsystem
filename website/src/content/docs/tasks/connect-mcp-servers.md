---
title: Connect MCP servers
description: Give an agent tools from MCP servers, authenticated without anyone clicking through a login.
---

An AgentDefinition lists the MCP servers its runs connect to under `resources.mcp_servers`. The
controller hands them to whichever agent CLI the model routes to, and injects each server's
credential from `agent-secrets` as an environment variable, so the token never appears in the pod
spec's argv or on disk.

## Declare the servers

```yaml
apiVersion: agents.re-cinq.com/v1beta1
kind: AgentDefinition
metadata:
  name: triage
spec:
  model: claude-sonnet-4-6
  prompt: "Triage {ticket}"
  resources:
    mcp_servers:
      - name: tools                    # letters, digits, _ and - only; unique per definition
        transport: http                # http | sse | stdio
        url: https://tools.example.com/mcp
        headers:                       # http/sse only
          - name: Authorization
            ref: tools-mcp-auth        # agent-secrets key holding the whole value
          - name: X-Org-Id
            ref: tools-org
      - name: github
        transport: stdio
        command: github-mcp-server     # must already exist in the agent image
        args: ["stdio"]
        env:                           # stdio only
          - name: GITHUB_PERSONAL_ACCESS_TOKEN
            ref: gh-token
```

Each `ref` names a key in the `agent-secrets` Secret (see
[prerequisites](../setup/prerequisites.md)). A header's value is sent as is, so store the scheme
with it:

```sh
kubectl -n ai-agents create secret generic agent-secrets \
  --from-literal=tools-mcp-auth="Bearer $TOOLS_TOKEN" \
  --from-literal=tools-org="$ORG_ID" \
  --from-literal=gh-token="$GITHUB_TOKEN"   # add to your existing keys
```

The controller injects each secret into the run pod as `MCP_<SERVER>_<NAME>` (for example
`MCP_TOOLS_X_ORG_ID`) and every CLI reads it from there, so no token appears in argv or on disk.
A stdio server with `env` is started through `sh`, which exports each value under the name the
server expects before it `exec`s the command.

`headers_secret: <key>` is the older, deprecated form of a single `Authorization` header; it still
works, but cannot be combined with an `Authorization` entry in `headers`. It keeps its old env var
name rather than `MCP_<SERVER>_<NAME>`: the key upper-cased, with every non-alphanumeric character
folded to `_` (`tools-mcp-auth` becomes `TOOLS_MCP_AUTH`).

## Which agent CLIs support it

| Model routes to | http | sse | stdio | How the servers reach the CLI |
| --- | --- | --- | --- | --- |
| Claude Code | yes | yes | yes | `--mcp-config` + `--strict-mcp-config` on the command line |
| gemini-cli | yes | yes | yes | `mcpServers` in `/agent/.gemini/settings.json`, written by the init container |
| Codex | yes | no | yes | `-c mcp_servers.<name>.…` overrides on the command line |
| OpenCode | yes | yes | yes | `mcp` in `/agent/.config/opencode/opencode.json`, written by the init container |
| `exec` | no | no | no | not an LLM CLI |

For gemini-cli and OpenCode the init container replaces the whole key on every run, and writes it
empty when the definition declares no servers, so a server from an earlier run never outlives its
secret.

A definition the CLI cannot honour fails the Agent before a Job is created, with the reason in
`status.failureReason`. That covers `mcp_servers` on `exec`, `sse` on Codex, a duplicate or invalid
name, `http`/`sse` without `url`, `stdio` without `command`, `headers` on a stdio server or `env`
on a remote one, a header or variable name that is invalid or repeated, and an entry without `ref`.

A headless gemini-cli run can only call MCP tools under `permission_mode: bypass`; see
[agent runtime](../concepts/agent-runtime.md).

## Prefer remote servers

A `stdio` server is a process inside the run pod, so its binary must already be in the agent image.
The subsystem installs nothing for it. Fetching one at start-up (`npx -y …`, `uvx …`) needs that
runtime in the image, egress to the package registry, and gives up the image's pinned, signed
supply chain.

Run tools you own as an `http` MCP server instead: an ordinary Deployment and Service with its own
image, RBAC and secrets, shared by every agent.

## Network access

The run-pod NetworkPolicy (`deploy/rbac/networkpolicy.yaml`) allows HTTPS to the public internet
only. Private ranges are excluded, so **an in-cluster MCP Service is unreachable until you add an
egress rule for it**, for example:

```yaml
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: mcp-tools
          podSelector:
            matchLabels:
              app: tools-mcp
      ports:
        - protocol: TCP
          port: 8080
```

## Authentication

Runs are headless, so the browser-based OAuth flow the MCP spec defines for HTTP servers cannot
complete. Use a credential the server accepts without a login: an API key, personal access token
or service token, stored in `agent-secrets` and referenced from `headers` (remote) or `env`
(stdio). OpenCode's OAuth auto-discovery is switched off for a server that has headers.
