"""Creates and reads the subsystem's resources in one namespace through the official
``kubernetes`` package's ``CustomObjectsApi``, or anything with the same four methods."""

import time
from collections.abc import Callable
from typing import Any, TypeVar

from agent_contracts.api import CustomObjects

from agent_contracts.types_generated import (
    GROUP,
    VERSION,
    Agent,
    AgentDefinition,
    ModelCatalog,
    Phase,
    Station,
    _Model,
)

DEFAULT_NAMESPACE = "ai-agents"

_FIELD_MANAGER = "agent-contracts"
_MODEL_CATALOG_NAME = "default"
_APPLY_PATCH = "application/apply-patch+yaml"

_Resource = TypeVar("_Resource", bound=_Model)


class AgentNotFinishedError(TimeoutError):
    """A run did not reach a terminal phase before the timeout."""


def is_terminal(agent: Agent) -> bool:
    """Whether a run has finished (Succeeded or Failed)."""
    phase = agent.status.phase if agent.status else None
    return phase in (Phase.SUCCEEDED, Phase.FAILED)


def _wire(resource: _Model) -> dict[str, Any]:
    return resource.model_dump(by_alias=True, exclude_none=True, mode="json")


class AgentContractsClient:
    """Typed calls for the Agent, Station, AgentDefinition and ModelCatalog resources."""

    def __init__(self, api: CustomObjects, namespace: str | None = None) -> None:
        self._api = api
        self._namespace = namespace or DEFAULT_NAMESPACE

    def create_agent(self, agent: Agent) -> Agent:
        """Starts one run in the client's namespace."""
        created = self._api.create_namespaced_custom_object(
            GROUP, VERSION, self._namespace, Agent.PLURAL, _wire(agent))
        return Agent.model_validate(created)

    def get_agent(self, name: str) -> Agent:
        """Reads one run; the API's 404 error propagates for an unknown name."""
        return Agent.model_validate(self._api.get_namespaced_custom_object(
            GROUP, VERSION, self._namespace, Agent.PLURAL, name))

    def find_agents(self, label_selector: str) -> list[Agent]:
        """Lists the runs matching a Kubernetes label selector such as ``team=web``."""
        listed = self._api.list_namespaced_custom_object(
            GROUP, VERSION, self._namespace, Agent.PLURAL, label_selector=label_selector)
        return [Agent.model_validate(item) for item in listed.get("items") or []]

    def get_model_catalog(self) -> ModelCatalog:
        """Reads the models the subsystem can run (the controller's ``default`` ModelCatalog)."""
        return ModelCatalog.model_validate(self._api.get_namespaced_custom_object(
            GROUP, VERSION, self._namespace, ModelCatalog.PLURAL, _MODEL_CATALOG_NAME))

    def apply_agent_definition(self, definition: AgentDefinition) -> AgentDefinition:
        """Server-side applies an AgentDefinition, taking over fields other managers set."""
        return self._apply(definition)

    def apply_station(self, station: Station) -> Station:
        """Server-side applies a Station, taking over fields other managers set."""
        return self._apply(station)

    def _apply(self, resource: _Resource) -> _Resource:
        name = resource.metadata.name if resource.metadata else None
        if not name:
            raise ValueError(f"apply {resource.kind}: metadata.name is required")
        body = _wire(resource)
        body["metadata"] = {**body["metadata"], "namespace": self._namespace}
        body["metadata"].pop("managedFields", None)
        applied = self._api.patch_namespaced_custom_object(
            GROUP, VERSION, self._namespace, type(resource).PLURAL, name, body,
            field_manager=_FIELD_MANAGER, force=True, _content_type=_APPLY_PATCH)
        return type(resource).model_validate(applied)

    def wait_for_agent(self, name: str, timeout: float = 1200.0, interval: float = 2.0,
                       sleep: Callable[[float], None] = time.sleep,
                       clock: Callable[[], float] = time.monotonic) -> Agent:
        """Polls the run until it is Succeeded or Failed, or raises AgentNotFinishedError after
        ``timeout`` seconds."""
        deadline = clock() + timeout
        while True:
            agent = self.get_agent(name)
            if is_terminal(agent):
                return agent
            if clock() >= deadline:
                raise AgentNotFinishedError(
                    f"agent {name} did not reach a terminal phase within {timeout:g}s")
            sleep(interval)
