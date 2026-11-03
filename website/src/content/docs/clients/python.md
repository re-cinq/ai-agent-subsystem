---
title: Python client
description: Launch and watch Agents from Python with Pydantic models and the official kubernetes package.
---

`re-cinq-agent-contracts` gives a Python program Pydantic models of every resource and a small
client that creates runs, waits for them and applies recipes. The models are generated from the
same source as the CRDs, so they always match the cluster you install from the same release.

## Install

```sh
pip install "re-cinq-agent-contracts[kubernetes]==0.15.0"
```

The `kubernetes` extra installs the official client the examples use. The package needs Python 3.10
or newer and Pydantic 2.11 or newer.

## Create the client

The client wraps the `kubernetes` package's `CustomObjectsApi`:

```python
from kubernetes import client, config

from agent_contracts import AgentContractsClient

config.load_config()  # kubeconfig on a laptop, the service account inside a pod

agents = AgentContractsClient(client.CustomObjectsApi())  # namespace defaults to "ai-agents"
```

Any object with the same four methods works in place of `CustomObjectsApi`, which is how the
package's own tests run without a cluster.

## Launch a run and wait for it

```python
from agent_contracts import Agent, AgentSpec, ObjectMeta

run = agents.create_agent(Agent(
    metadata=ObjectMeta(generate_name="fix-bug-"),
    spec=AgentSpec(
        station_ref="bug-fixer",
        target_repo="re-cinq/ai-agent-subsystem",
        parameters={"issue": "123"},
    ),
))

finished = agents.wait_for_agent(run.metadata.name, timeout=1800, interval=5)

print(finished.status.phase, finished.status.pr_url)
```

`wait_for_agent` polls until the phase is `SUCCEEDED` or `FAILED`. It raises
`AgentNotFinishedError` once the timeout passes. Pass your own `sleep` and `clock` to drive it from
a test.

## Apply a recipe and a runtime

```python
from agent_contracts import AgentDefinition, AgentDefinitionSpec

definition = AgentDefinition(
    metadata=ObjectMeta(name="bug-fixer"),
    spec=AgentDefinitionSpec(model="claude-sonnet-5-5", prompt="Fix the bug described in issue {issue}."),
)

agents.apply_agent_definition(definition)
```

`apply_agent_definition` and `apply_station` are server-side apply with the field manager
`agent-contracts` and forced ownership. A resource without a name raises
`ValueError("apply <Kind>: metadata.name is required")` before any request is sent.

## Methods

| Call | Does |
| --- | --- |
| `create_agent(agent)` | Start one run in the client's namespace. |
| `get_agent(name)` | Read one run; an unknown name raises the API's 404 `ApiException`. |
| `find_agents(label_selector)` | List runs matching a selector such as `team=web`. |
| `get_model_catalog()` | Read the models the subsystem can run. |
| `apply_agent_definition`, `apply_station` | Server-side apply a recipe or runtime. |
| `is_terminal(agent)` | Whether a run has finished. |
| `wait_for_agent(name, timeout, interval)` | Poll until the run finishes or the timeout passes. |

## Permissions

The [`agent-launcher` role](../reference/rbac-and-network.md#caller-role) covers creating, reading
and listing Agents and reading the ModelCatalog. Applying AgentDefinitions and Stations needs
`get`, `create` and `patch` on `agentdefinitions` and `stations`, which that role does not grant;
bind a separate role for the app that manages recipes.

## Models

Attributes are snake_case, and every model also accepts the wire names, so both of these work:

```python
AgentSpec(station_ref="bug-fixer")
AgentSpec.model_validate({"stationRef": "bug-fixer"})
```

Write the wire form with `model_dump(by_alias=True, exclude_none=True)`. A field left at `None` is
omitted, so the API server applies the CRD's default. Free-form fields such as
`StationSpec.template` are `Any`. Enums are `str` enums, and a value the package does not know reads
as the first member, the same rule the controller applies. Fields the models do not know are kept
and written back, so reading and re-applying a resource does not drop them.

## Test without a cluster

Pass any object with `create_namespaced_custom_object`, `get_namespaced_custom_object`,
`list_namespaced_custom_object` and `patch_namespaced_custom_object`. An in-memory dictionary keyed
by namespace, plural and name is enough for most tests.
