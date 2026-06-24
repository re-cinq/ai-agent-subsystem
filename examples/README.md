# Examples

Ready-to-apply examples you can try against a running cluster. Each is a recipe
([AgentDefinition](../deploy/crds/agentdefinition.yaml)) paired with a runtime
([Station](../deploy/crds/station.yaml)); you then launch runs ([Agents](../deploy/crds/agent.yaml)).

| File | What it shows |
|------|---------------|
| [`story-writer.yaml`](story-writer.yaml) | Pure text — prompt in, prose out. No repo, no tools. **Start here.** |
| [`bug-fixer.yaml`](bug-fixer.yaml) | Code editing — reads/edits/tests with a scoped tool allowlist. |
| [`run-agent.sh`](run-agent.sh) | Launch one run against a Station with `key=value` parameters. |
| [`notify-listener.mjs`](notify-listener.mjs) | A zero-dependency listener for the `http` output sink. |

## Prerequisites

1. **The subsystem installed** into the `ai-agents` namespace — see [Install](../website/src/content/docs/setup/install.md)
   (`kubectl apply -f <release>/install.yaml`, or `kubectl apply -k deploy` from a checkout).
2. **A model credential.** These recipes use `claude-sonnet-4-6`, so the run pod needs an API key.
   Create the `agent-secrets` Secret the controller injects as `ANTHROPIC_API_KEY`:
   ```sh
   kubectl -n ai-agents create secret generic agent-secrets \
     --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
   ```
   The Station base is `node:22-bookworm` (glibc + Node) so the injected init container can install
   the Claude CLI; egress to the API is allowed by the controller's NetworkPolicy.

## Try the pure-text example

```sh
kubectl apply -f examples/story-writer.yaml
examples/run-agent.sh story-writer title="The Last Lighthouse"
kubectl -n ai-agents get agents -w        # Pending -> Running -> Succeeded
```

Collect the result once it reaches `Succeeded`:

```sh
agent=$(kubectl -n ai-agents get agents -o name | grep story-writer-run- | head -1)
kubectl -n ai-agents get "$agent" -o jsonpath='{.status.phase} (exit {.status.exitCode}){"\n"}'
kubectl -n ai-agents get "$agent" -o jsonpath='{.status.output}{"\n"}'
```

## Try the code-editing example

```sh
kubectl apply -f examples/bug-fixer.yaml
examples/run-agent.sh node-fixer ticket=ENG-417 repo=re-cinq/ai-agent-subsystem branch=fix/eng-417
kubectl -n ai-agents get agents -w
```

The `key=value` arguments fill the recipe's `{ticket}`, `{repo}`, `{branch}` placeholders. To make
the agent actually clone and push, add `resources.repos` (with a `token_secret`) to the recipe and
set the Agent's `targetRepo`/`branch`.

## Stream events to a listener (optional)

Run the listener on your host, then uncomment the `http` sink in `story-writer.yaml`:

```sh
node examples/notify-listener.mjs            # listens on :8099
```

On minikube the cluster reaches your host at `http://host.minikube.internal:8099/notify`; adjust the
URL for other clusters. Every stream-json event the run emits is POSTed there as it happens.

## Clean up

```sh
kubectl -n ai-agents delete -f examples/story-writer.yaml -f examples/bug-fixer.yaml
```
