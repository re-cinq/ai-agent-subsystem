---
title: Define a recipe
description: Author an AgentDefinition - the reusable task recipe.
---

An [AgentDefinition](/concepts/agentdefinition/) describes a task once so many
runs can reuse it. Here is a minimal bug-fixer recipe.

```yaml
apiVersion: agents.re-cinq.com/v1alpha1
kind: AgentDefinition
metadata:
  name: bug-fixer
spec:
  description: Fix a referenced bug on a repository branch.
  model: claude-sonnet-4-6
  prompt: |
    Fix bug {ticket} on repository {repo}, branch {branch}.
    Make the smallest change that resolves the issue and keep the tests green.
  permission_mode: auto
  allowed_tools:
    - Read
    - Edit
    - Bash(npm run test:*)
  disallowed_tools:
    - Bash(rm *)
  max_turns: 40
  output:
    format: stream-json
    sinks:
      - type: stdout
```

## Notes

- **`{ticket}`, `{repo}`, `{branch}`** are placeholders filled from an Agent's `parameters` - see
  [Prompt templating](/reference/prompt-templating/).
- **`permission_mode: auto`** enforces the `allowed_tools` / `disallowed_tools` lists. Use `bypass`
  to grant all tools.
- The recipe is environment-independent: no image, no namespace, no credentials. Those belong to the
  [Station](/concepts/station/).

Apply it:

```sh
kubectl apply -f bug-fixer.yaml
kubectl get agentdefinitions
```

Next, pair it with a runtime in [Create a station](/tasks/create-a-station/).
