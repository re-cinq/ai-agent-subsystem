# agent-contracts (Rust)

Types and a small [kube-rs](https://kube.rs) client for the [ai-agent-subsystem](https://github.com/re-cinq/ai-agent-subsystem)
Custom Resources: **Agent**, **Station**, **AgentDefinition**, **ModelCatalog** and **AgentSpawner** (API group
`agents.re-cinq.com/v1beta1`).

The types are generated from the D structs that define the CRDs, the same source the CRD YAML and
the other contract packages come from, so they cannot drift. CI fails if the committed file stops
matching the model, and a test round-trips every manifest in `examples/` and fails if any field is
lost.

## Install

The crate is consumed from git at a release tag:

```toml
[dependencies]
agent-contracts = { git = "https://github.com/re-cinq/ai-agent-subsystem", tag = "v0.15.0" }
kube = { version = "5", features = ["client", "runtime"] }
k8s-openapi = { version = "0.29", features = ["latest"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
```

Cargo finds the crate inside the repository by its name. Like every kube-rs library, it leaves the
choice of Kubernetes API version to your application: enable one `k8s-openapi` version feature
(`latest`, or for example `v1_33`) in your own `Cargo.toml`.

## Types

Every kind has `metadata: ObjectMeta`, optional `spec` and `status`, `new(name)`, `SHORT_NAMES`, and
a `kube::Resource` impl, so `kube::Api<Agent>` works directly. Optional fields are `Option` and are
left out when `None`, so the API server applies the CRD's default. Free-form fields such as
`StationSpec::template` are `serde_json::Value`. Enums serialize as their wire value and an unknown
value reads as the first variant, the same rule the controller applies.

## Client

```rust
use std::time::Duration;

use agent_contracts::{Agent, AgentContractsClient, AgentSpec};

let agents = AgentContractsClient::new(kube::Client::try_default().await?, "ai-agents");

let mut run = Agent::default();
run.metadata.generate_name = Some("story-writer-run-".into());
run.spec = Some(AgentSpec { station_ref: "story-writer".into(), ..Default::default() });

let run = agents.create_agent(&run).await?;
let name = run.metadata.name.unwrap();

let finished = tokio::time::timeout(
    Duration::from_secs(1800),
    agents.wait_for_agent(&name, Duration::from_secs(5)),
).await??;
```

| Method | Does |
| --- | --- |
| `create_agent` | Start one run. |
| `get_agent`, `find_agents` | Read one run, or list runs by label selector. |
| `wait_for_agent` | Poll until the run is `Succeeded` or `Failed`; bound it with `tokio::time::timeout`. |
| `get_model_catalog` | The models the subsystem can run with its configured keys. |
| `apply_agent_definition`, `apply_station` | Server-side apply a recipe or runtime (field manager `agent-contracts`, forced). |
| `is_terminal` | Whether a run has finished. |

## Development

`make regen` from the repository root rewrites `src/types.rs`; do not edit it by hand.
`make contracts-rust` runs rustfmt, clippy and the tests.
