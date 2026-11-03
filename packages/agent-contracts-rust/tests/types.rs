use std::fs;
use std::path::Path;

use agent_contracts::{
    API_VERSION, Agent, AgentDefinition, AgentSpawner, ModelCatalog, PermissionMode, Station,
};
use kube::Resource;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

fn round_trip<K: DeserializeOwned + serde::Serialize>(document: &Value) -> Value {
    serde_json::to_value(serde_json::from_value::<K>(document.clone()).unwrap()).unwrap()
}

/// Every manifest under examples/ survives a decode and encode unchanged, so a field the CRDs
/// accept but the types miss (serde would silently drop it) fails here.
#[test]
fn every_example_manifest_round_trips_unchanged() {
    let examples = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../examples");
    let mut decoded = 0;
    for entry in fs::read_dir(examples).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|extension| extension != "yaml") {
            continue;
        }
        let content = fs::read_to_string(&path).unwrap();
        for document in serde_yaml_ng::Deserializer::from_str(&content) {
            let document = Value::deserialize(document).unwrap();
            let encoded = match document["kind"].as_str() {
                Some("AgentDefinition") => round_trip::<AgentDefinition>(&document),
                Some("Station") => round_trip::<Station>(&document),
                Some("Agent") => round_trip::<Agent>(&document),
                Some("ModelCatalog") => round_trip::<ModelCatalog>(&document),
                Some("AgentSpawner") => round_trip::<AgentSpawner>(&document),
                Some(other) => panic!("{}: kind {other} is not a generated type", path.display()),
                None => continue,
            };
            assert_eq!(encoded, document, "{}", path.display());
            decoded += 1;
        }
    }
    assert!(decoded > 0, "decoded no resources");
}

#[test]
fn an_unknown_enum_value_falls_back_to_the_first_variant() {
    let modes: Vec<PermissionMode> = serde_json::from_value(json!(["bogus", "bypass"])).unwrap();

    assert_eq!(modes, [PermissionMode::Auto, PermissionMode::Bypass]);
}

#[test]
fn a_kind_names_its_group_version_plural_and_short_names() {
    let agent = Agent::new("run-1");

    assert_eq!(
        (
            agent.api_version.as_str(),
            agent.kind.as_str(),
            Agent::plural(&()).as_ref(),
            Agent::SHORT_NAMES,
            Agent::api_version(&()).as_ref()
        ),
        (
            API_VERSION,
            "Agent",
            "agents",
            &["agt"][..],
            "agents.re-cinq.com/v1beta1"
        ),
    );
}

#[test]
fn a_missing_api_version_and_kind_default_to_the_resource_s_own() {
    let agent: Agent = serde_json::from_value(json!({"metadata": {"name": "run-1"}})).unwrap();

    assert_eq!(
        (agent.api_version.as_str(), agent.kind.as_str()),
        (API_VERSION, "Agent")
    );
}
