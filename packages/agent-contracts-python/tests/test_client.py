import pytest
from kubernetes.client.exceptions import ApiException

from agent_contracts import (
    DEFAULT_NAMESPACE,
    Agent,
    AgentContractsClient,
    AgentDefinition,
    AgentDefinitionSpec,
    AgentNotFinishedError,
    AgentSpec,
    AgentStatus,
    ModelCatalog,
    ModelCatalogStatus,
    ModelInfo,
    ObjectMeta,
    Phase,
    Station,
    StationSpec,
    VendorModels,
    is_terminal,
)
from fake_api import FakeCustomObjects


def agent_named(name: str, phase: Phase, labels: dict[str, str] | None = None) -> Agent:
    return Agent(
        metadata=ObjectMeta(name=name, labels=labels),
        spec=AgentSpec(station_ref="story-writer"),
        status=AgentStatus(phase=phase),
    )


@pytest.fixture
def api() -> FakeCustomObjects:
    return FakeCustomObjects()


def test_create_agent_puts_the_run_in_the_client_namespace(api):
    agents = AgentContractsClient(api)

    created = agents.create_agent(Agent(metadata=ObjectMeta(generate_name="run-"),
                                        spec=AgentSpec(station_ref="story-writer")))

    assert created.model_dump(include={"metadata", "spec"}, exclude_none=True) == {
        "metadata": {"name": "run-1", "generate_name": "run-", "namespace": DEFAULT_NAMESPACE},
        "spec": {"station_ref": "story-writer"},
    }
    assert api.objects[(DEFAULT_NAMESPACE, "agents", "run-1")]["apiVersion"] == "agents.re-cinq.com/v1beta1"


def test_get_agent_raises_the_api_404_for_an_unknown_run(api):
    with pytest.raises(ApiException, match="Not Found"):
        AgentContractsClient(api).get_agent("missing")


def test_find_agents_returns_only_the_runs_matching_the_selector(api):
    agents = AgentContractsClient(api, "team-a")
    agents.create_agent(agent_named("web-1", Phase.RUNNING, {"team": "web"}))
    agents.create_agent(agent_named("data-1", Phase.RUNNING, {"team": "data"}))

    assert [found.metadata.name for found in agents.find_agents("team=web")] == ["web-1"]


def test_find_agents_returns_an_empty_list_when_the_api_lists_no_items(api):
    api.list_namespaced_custom_object = lambda *args, **kwargs: {}

    assert AgentContractsClient(api).find_agents("team=web") == []


def test_get_model_catalog_reads_the_default_catalog(api):
    catalog = ModelCatalog(
        metadata=ObjectMeta(name="default"),
        status=ModelCatalogStatus(vendors=[VendorModels(vendor="claude", models=[ModelInfo(id="claude-opus-5-5")])]),
    )
    api.objects[(DEFAULT_NAMESPACE, "modelcatalogs", "default")] = catalog.model_dump(by_alias=True, exclude_none=True)

    read = AgentContractsClient(api).get_model_catalog()

    assert read.status.vendors[0].models[0].id == "claude-opus-5-5"


def test_apply_station_sends_a_forced_apply_patch_in_the_client_namespace(api):
    station = Station(metadata=ObjectMeta(name="story-writer", managedFields=[{"manager": "kubectl"}]),
                      spec=StationSpec(agent_def_ref="story-writer", template={"spec": {}}))

    applied = AgentContractsClient(api, "team-a").apply_station(station)

    assert api.patches == [{
        "path": ("agents.re-cinq.com", "v1beta1", "team-a", "stations", "story-writer"),
        "body": {"apiVersion": "agents.re-cinq.com/v1beta1", "kind": "Station",
                 "metadata": {"name": "story-writer", "namespace": "team-a"},
                 "spec": {"agentDefRef": "story-writer", "template": {"spec": {}}}},
        "field_manager": "agent-contracts", "force": True, "_content_type": "application/apply-patch+yaml",
    }]
    assert applied.spec.agent_def_ref == "story-writer"


def test_apply_agent_definition_returns_the_applied_definition(api):
    definition = AgentDefinition(metadata=ObjectMeta(name="story-writer"),
                                 spec=AgentDefinitionSpec(model="claude-opus-5-5", prompt="Write a story."))

    applied = AgentContractsClient(api).apply_agent_definition(definition)

    assert applied.spec.model == "claude-opus-5-5"


@pytest.mark.parametrize("metadata", [None, ObjectMeta(), ObjectMeta(name="")])
def test_apply_station_without_a_name_fails(api, metadata):
    with pytest.raises(ValueError, match="^apply Station: metadata.name is required$"):
        AgentContractsClient(api).apply_station(Station(metadata=metadata))


def test_wait_for_agent_returns_the_run_once_it_succeeds(api):
    agents = AgentContractsClient(api)
    agents.create_agent(agent_named("run-1", Phase.RUNNING))
    stored = api.objects[(DEFAULT_NAMESPACE, "agents", "run-1")]

    def finish(seconds: float) -> None:
        stored["status"]["phase"] = "Succeeded"

    assert agents.wait_for_agent("run-1", sleep=finish).status.phase == Phase.SUCCEEDED


def test_wait_for_agent_raises_once_the_timeout_passes_while_running(api):
    agents = AgentContractsClient(api)
    agents.create_agent(agent_named("run-1", Phase.RUNNING))
    ticks = iter([0.0, 5.0, 11.0])

    with pytest.raises(AgentNotFinishedError, match="^agent run-1 did not reach a terminal phase within 10s$"):
        agents.wait_for_agent("run-1", timeout=10, sleep=lambda seconds: None, clock=lambda: next(ticks))


@pytest.mark.parametrize(("status", "terminal"), [
    (None, False),
    (AgentStatus(), False),
    (AgentStatus(phase=Phase.PENDING), False),
    (AgentStatus(phase=Phase.RUNNING), False),
    (AgentStatus(phase=Phase.SUCCEEDED), True),
    (AgentStatus(phase=Phase.FAILED), True),
])
def test_is_terminal_is_true_only_for_succeeded_and_failed(status, terminal):
    assert is_terminal(Agent(status=status)) is terminal
