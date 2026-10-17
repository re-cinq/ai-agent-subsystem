---
title: Open pull requests
description: Turn a run's commits into a pull request without giving the agent a token that can push.
---

A recipe with `delivery.pullRequest` turns a successful run's commits into a GitHub pull request. The
agent never holds a token that can push. It commits in its clone, and a separate `courier` container
in the same pod pushes the branch and opens the pull request. The pull request's URL ends up in the
Agent's `status.prUrl`.

Without `delivery`, the agent container gets the repo's token as its `token_secret` variable and as
`GH_TOKEN`, and the clone keeps push auth in its config. An agent that a prompt injection has taken
over can then push anywhere that token reaches. With `delivery`, it can only commit.

## Configure the recipe

```yaml
apiVersion: agents.re-cinq.com/v1alpha1
kind: AgentDefinition
metadata: { name: bug-fixer, namespace: ai-agents }
spec:
  model: claude-sonnet-4-6
  prompt: "Fix {ticket} and commit the fix."
  resources:
    repos:
      - name: app
        url: https://github.com/acme/app.git
        token_secret: GH_TOKEN_APP     # a key in the agent-secrets Secret
  delivery:
    pullRequest:
      base: main
      titleTemplate: "Fix {ticket}"
      draft: true
```

| Field | Notes |
| --- | --- |
| `base` | *Required.* The branch the pull request merges into. |
| `titleTemplate` | *Required.* The title. `{placeholder}` tokens are filled from the Agent's `parameters`, as the prompt's are. |
| `draft` | Open the pull request as a draft. Default `false`. |
| `apiUrl` | GitHub REST API base URL. Default `https://api.github.com`; set it for GitHub Enterprise (`https://ghe.example.com/api/v3`). |

The pull request comes from the first entry of `resources.repos`. Its token is that repo's
`token_secret`. When the Agent's parameters carry `git_credential` and `git_credential_url`, the
[credential broker](../concepts/agent-runtime.md) mints the token instead, for both the push and the
API call.

## Launch a run

```yaml
apiVersion: agents.re-cinq.com/v1alpha1
kind: Agent
metadata: { generateName: fix-, namespace: ai-agents }
spec:
  stationRef: bug-fixer
  parameters: { ticket: ENG-1 }
  branch: fix/eng-1          # optional; default agent/<Agent name>
  targetRepo: acme/app       # optional; default the repo's own owner/name
```

The work is pushed to `branch`, or to `agent/<Agent name>` when the Agent names none. The pull request
opens on `targetRepo`, or on the `owner/name` of the repo's GitHub URL. Once the run ends:

```sh
kubectl -n ai-agents get agent fix-abc12 -o jsonpath='{.status.prUrl}'
```

## What happens in the pod

1. The init container clones the repo with the token and writes no push auth into the clone.
2. The agent runs and commits. Its container has no git token, no `GH_TOKEN`, and no broker
   credential.
3. When the agent exits, the supervisor writes a `git bundle` of the clone's `HEAD` to the `outbox`
   volume, and then a marker that says whether there is anything to deliver.
4. The `courier` container waits for the marker. It fetches the bundle into a bare repository of its
   own and never runs git in the agent's clone. It pushes `HEAD` to `refs/heads/<branch>`, then calls
   `POST /repos/{owner}/{repo}/pulls`. When a pull request from that branch is already open (a 422
   saying so), it looks that one up and reports it.
5. The courier raises a [delivery event](../reference/notification-api.md#delivery-events) on its
   stdout and on the recipe's sinks. The controller reads the courier container's log, not the
   agent's, so the agent cannot forge the URL, and records it as `status.prUrl`.

The courier is an ordinary container, not a native sidecar, because it has to outlive the agent.
The Job completes once both have exited. It runs the agent image's `ai-agent-init` binary as
`ai-agent-init courier`, so no extra image is needed.

## What gets delivered

| The run | Outcome |
| --- | --- |
| Exits 0 with new commits | Branch pushed, pull request opened, `status.prUrl` set. |
| Exits non-zero | Nothing pushed. The delivery event says `skipped`, and the Agent fails because the agent did. |
| Exits 0 without a new commit | Nothing pushed, `skipped` with `no new commits`. The Agent succeeds. |
| Push or API call fails | The courier exits 1, so the Agent fails, with `failureReason` set to `pull request delivery failed: …`. |
| The agent container dies before the supervisor writes the marker | The courier gives up five seconds after the supervisor's deadline and the Agent fails. |

The branch is pushed without `--force`. A rerun onto a branch whose history has moved on is rejected.

## Requirements and limits

- `execution` must be `interactive`. Batch and realtime recipes with `delivery` fail the Agent before
  a Job is created, as does a recipe with no `resources.repos`, a repo without `token_secret` when there
  is no broker, a branch name git would refuse, or no GitHub `owner/name` to open the pull request on.
- The Station's image needs `git`, since the supervisor bundles the work there. The courier uses the
  agent image, which ships it.
- The agent has no credential, so it cannot `git fetch` from a private repo or use `gh` against it during
  the run. Anything it needs has to be in the clone the init made.
- A Station template that already has a container named `courier`, or a volume named `outbox` or
  `courier`, is rejected or overridden; those names are reserved.
