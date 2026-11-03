# re-cinq-agent-contracts (Python)

Pydantic models and a small client for the [ai-agent-subsystem](https://github.com/re-cinq/ai-agent-subsystem)
Custom Resources: **Agent**, **Station**, **AgentDefinition**, **ModelCatalog** and **AgentSpawner** (API group
`agents.re-cinq.com/v1beta1`).

The models are generated from the D structs that define the CRDs, the same source the CRD YAML and
the TypeScript, Go and Java contracts come from, so they cannot drift. CI fails if the committed
file stops matching the model, and a test decodes every manifest in `examples/` and fails on any
field the models do not know.

## Install

```sh
pip install "re-cinq-agent-contracts[kubernetes]"
```

The `kubernetes` extra brings the official client the examples use. Versions follow the
subsystem's releases. Requires Python 3.10+ and Pydantic 2.11+.

## Models

Every resource and nested type is a Pydantic model. Attributes are snake_case and accept either
name on input (`AgentSpec(station_ref=...)` or `AgentSpec.model_validate({"stationRef": ...})`).
Write the wire form with `model_dump(by_alias=True, exclude_none=True)`.

- A field left at `None` is omitted, so the API server applies the CRD's default.
- Free-form fields such as `StationSpec.template` are `Any`.
- Enums are `str` enums; an unknown value decodes to the first member, the same rule the controller
  applies, so a newer cluster does not break an older client.
- Fields the models do not know are kept and written back, so reading and re-applying a resource
  does not drop them.
- Each kind has `PLURAL` and `SHORT_NAMES`; `GROUP`, `VERSION` and `API_VERSION` are module constants.

## Client

`AgentContractsClient` wraps the `kubernetes` package's `CustomObjectsApi` and works in one
namespace (`ai-agents` by default):

```python
from kubernetes import client, config

from agent_contracts import Agent, AgentContractsClient, AgentSpec, ObjectMeta

config.load_config()  # kubeconfig, or the pod's service account in a cluster
agents = AgentContractsClient(client.CustomObjectsApi())

run = agents.create_agent(Agent(
    metadata=ObjectMeta(generate_name="story-writer-run-"),
    spec=AgentSpec(station_ref="story-writer", parameters={"title": "The Last Lighthouse"}),
))

finished = agents.wait_for_agent(run.metadata.name, timeout=1800)
print(finished.status.phase)
```

| Method | Does |
| --- | --- |
| `create_agent` | Start one run. |
| `get_agent`, `find_agents` | Read one run, or list runs by label selector. |
| `wait_for_agent` | Poll until the run is `SUCCEEDED` or `FAILED`; `AgentNotFinishedError` after the timeout. |
| `get_model_catalog` | The models the subsystem can run with its configured keys. |
| `apply_agent_definition`, `apply_station` | Server-side apply a recipe or runtime (field manager `agent-contracts`, forced). |
| `is_terminal` | Whether a run has finished. |

## Development

`make regen` from the repository root rewrites `src/agent_contracts/types_generated.py`; do not
edit it by hand. `make contracts-python` runs the tests with a 100% coverage gate on the client.
