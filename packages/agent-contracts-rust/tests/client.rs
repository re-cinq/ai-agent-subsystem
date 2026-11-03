mod support;

use std::time::Duration;

use agent_contracts::{
    Agent, AgentContractsClient, AgentDefinition, AgentDefinitionSpec, AgentSpec, AgentStatus,
    DEFAULT_NAMESPACE, Error, ModelCatalog, ModelCatalogStatus, ModelInfo, Phase, Station,
    StationSpec, VendorModels, is_terminal,
};
use serde_json::json;
use support::fake_client;

const AGENTS: &str = "/apis/agents.re-cinq.com/v1beta1/namespaces/ai-agents/agents";

fn agent_named(name: &str, phase: Phase, labels: &[(&str, &str)]) -> Agent {
    let mut agent = Agent::new(name);
    agent.metadata.labels = Some(
        labels
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect(),
    );
    agent.spec = Some(AgentSpec {
        station_ref: "story-writer".into(),
        ..Default::default()
    });
    agent.status = Some(AgentStatus {
        phase: Some(phase),
        ..Default::default()
    });
    agent
}

#[tokio::test]
async fn create_agent_puts_the_run_in_the_client_namespace() {
    let (kube, store) = fake_client();
    let mut run = Agent::default();
    run.metadata.generate_name = Some("run-".into());
    run.spec = Some(AgentSpec {
        station_ref: "story-writer".into(),
        ..Default::default()
    });

    let created = AgentContractsClient::new(kube, "")
        .create_agent(&run)
        .await
        .unwrap();

    assert_eq!(
        store.lock().unwrap().objects[&format!("{AGENTS}/run-1")],
        json!({
            "apiVersion": "agents.re-cinq.com/v1beta1", "kind": "Agent",
            "metadata": {"generateName": "run-", "name": "run-1", "namespace": DEFAULT_NAMESPACE},
            "spec": {"stationRef": "story-writer"},
        })
    );
    assert_eq!(created.metadata.name.as_deref(), Some("run-1"));
}

#[tokio::test]
async fn get_agent_fails_with_the_api_404_for_an_unknown_run() {
    let (kube, _) = fake_client();

    let error = AgentContractsClient::new(kube, "")
        .get_agent("missing")
        .await
        .unwrap_err();

    assert!(
        matches!(error, Error::Kube(kube::Error::Api(ref status)) if status.code == 404),
        "{error:?}"
    );
}

#[tokio::test]
async fn find_agents_returns_only_the_runs_matching_the_selector() {
    let (kube, _) = fake_client();
    let agents = AgentContractsClient::new(kube, "");
    agents
        .create_agent(&agent_named("web-1", Phase::Running, &[("team", "web")]))
        .await
        .unwrap();
    agents
        .create_agent(&agent_named("data-1", Phase::Running, &[("team", "data")]))
        .await
        .unwrap();

    let found = agents.find_agents("team=web").await.unwrap();

    assert_eq!(
        found
            .iter()
            .map(|agent| agent.metadata.name.clone().unwrap())
            .collect::<Vec<_>>(),
        ["web-1"]
    );
}

#[tokio::test]
async fn get_model_catalog_reads_the_default_catalog() {
    let (kube, store) = fake_client();
    let mut catalog = ModelCatalog::new("default");
    catalog.status = Some(ModelCatalogStatus {
        vendors: Some(vec![VendorModels {
            vendor: Some("claude".into()),
            models: Some(vec![ModelInfo {
                id: Some("claude-opus-5-5".into()),
                ..Default::default()
            }]),
            ..Default::default()
        }]),
        ..Default::default()
    });
    store.lock().unwrap().objects.insert(
        "/apis/agents.re-cinq.com/v1beta1/namespaces/ai-agents/modelcatalogs/default".into(),
        serde_json::to_value(&catalog).unwrap(),
    );

    let read = AgentContractsClient::new(kube, "")
        .get_model_catalog()
        .await
        .unwrap();

    assert_eq!(read, catalog);
}

#[tokio::test]
async fn apply_station_sends_a_forced_apply_patch_in_the_client_namespace() {
    let (kube, store) = fake_client();
    let mut station = Station::new("story-writer");
    station.metadata.managed_fields = Some(vec![Default::default()]);
    station.spec = Some(StationSpec {
        agent_def_ref: "story-writer".into(),
        template: json!({"spec": {}}),
        ..Default::default()
    });

    let applied = AgentContractsClient::new(kube, "team-a")
        .apply_station(&station)
        .await
        .unwrap();

    let patch = store.lock().unwrap().patches[0].clone();
    assert_eq!(
        (
            patch.path_and_query.as_str(),
            patch.content_type.as_str(),
            patch.body
        ),
        (
            "/apis/agents.re-cinq.com/v1beta1/namespaces/team-a/stations/story-writer?&force=true&fieldManager=agent-contracts",
            "application/apply-patch+yaml",
            json!({"apiVersion": "agents.re-cinq.com/v1beta1", "kind": "Station",
                "metadata": {"name": "story-writer", "namespace": "team-a"},
                "spec": {"agentDefRef": "story-writer", "template": {"spec": {}}}}),
        ),
    );
    assert_eq!(applied.spec.unwrap().agent_def_ref, "story-writer");
}

#[tokio::test]
async fn apply_agent_definition_returns_the_applied_definition() {
    let (kube, _) = fake_client();
    let mut definition = AgentDefinition::new("story-writer");
    definition.spec = Some(AgentDefinitionSpec {
        model: Some("claude-opus-5-5".into()),
        prompt: "Write a story.".into(),
        ..Default::default()
    });

    let applied = AgentContractsClient::new(kube, "")
        .apply_agent_definition(&definition)
        .await
        .unwrap();

    assert_eq!(
        applied.spec.unwrap().model.as_deref(),
        Some("claude-opus-5-5")
    );
}

#[tokio::test]
async fn apply_station_without_a_name_fails() {
    let (kube, _) = fake_client();
    let agents = AgentContractsClient::new(kube, "");

    let unnamed = agents.apply_station(&Station::default()).await.unwrap_err();
    let empty = agents.apply_station(&Station::new("")).await.unwrap_err();

    assert_eq!(
        (unnamed.to_string(), empty.to_string()),
        (
            "apply Station: metadata.name is required".to_string(),
            "apply Station: metadata.name is required".to_string()
        )
    );
}

#[tokio::test(start_paused = true)]
async fn wait_for_agent_returns_the_run_once_it_succeeds() {
    let (kube, store) = fake_client();
    let agents = AgentContractsClient::new(kube, "");
    agents
        .create_agent(&agent_named("run-1", Phase::Running, &[]))
        .await
        .unwrap();
    let finisher = store.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(3)).await;
        finisher
            .lock()
            .unwrap()
            .objects
            .get_mut(&format!("{AGENTS}/run-1"))
            .unwrap()["status"]["phase"] = json!("Succeeded");
    });

    let finished = agents
        .wait_for_agent("run-1", Duration::from_secs(1))
        .await
        .unwrap();

    assert_eq!(finished.status.unwrap().phase, Some(Phase::Succeeded));
}

#[tokio::test(start_paused = true)]
async fn wait_for_agent_keeps_polling_until_the_timeout_while_running() {
    let (kube, _) = fake_client();
    let agents = AgentContractsClient::new(kube, "");
    agents
        .create_agent(&agent_named("run-1", Phase::Running, &[]))
        .await
        .unwrap();

    let waited = tokio::time::timeout(
        Duration::from_secs(10),
        agents.wait_for_agent("run-1", Duration::from_secs(1)),
    )
    .await;

    assert!(waited.is_err());
}

#[tokio::test]
async fn wait_for_agent_fails_for_an_unknown_run() {
    let (kube, _) = fake_client();

    let waited = AgentContractsClient::new(kube, "")
        .wait_for_agent("missing", Duration::from_secs(1))
        .await;

    assert!(matches!(waited, Err(Error::Kube(_))));
}

#[test]
fn is_terminal_is_true_only_for_succeeded_and_failed() {
    let phases = [
        None,
        Some(Phase::Pending),
        Some(Phase::Running),
        Some(Phase::Succeeded),
        Some(Phase::Failed),
    ];
    let terminal: Vec<bool> = phases
        .iter()
        .map(|phase| {
            let agent = Agent {
                status: phase.map(|phase| AgentStatus {
                    phase: Some(phase),
                    ..Default::default()
                }),
                ..Default::default()
            };
            is_terminal(&agent)
        })
        .collect();

    assert_eq!(terminal, [false, false, false, true, true]);
}

#[test]
fn errors_describe_themselves_and_expose_their_source() {
    use std::error::Error as _;

    let missing = Error::MissingName("Station".into());
    let kube = Error::from(kube::Error::LinesCodecMaxLineLengthExceeded);

    assert_eq!(
        (
            missing.source().is_none(),
            kube.source().is_some(),
            kube.to_string().is_empty()
        ),
        (true, true, false)
    );
}
