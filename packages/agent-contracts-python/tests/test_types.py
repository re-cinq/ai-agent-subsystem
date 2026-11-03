from pathlib import Path

import yaml
from pydantic import BaseModel

import agent_contracts
from agent_contracts import API_VERSION, Agent, PermissionMode, SecretRef, StationSpec

EXAMPLES = Path(__file__).resolve().parents[3] / "examples"
KINDS = {kind: getattr(agent_contracts, kind)
         for kind in ("AgentDefinition", "Station", "Agent", "ModelCatalog", "AgentSpawner")}


def unknown_fields(model: BaseModel, path: str) -> list[str]:
    """Every field the model kept only as an extra, outside metadata (which is a subset of Kubernetes')."""
    found = [f"{path}.{name}" for name in (model.model_extra or {}) if path != ".metadata"]
    for name in type(model).model_fields:
        value = getattr(model, name)
        children = value if isinstance(value, list) else list(value.values()) if isinstance(value, dict) else [value]
        found += [field for child in children if isinstance(child, BaseModel)
                  for field in unknown_fields(child, f"{path}.{name}")]
    return found


def test_every_example_manifest_decodes_without_unknown_fields():
    decoded = []
    for file in sorted(EXAMPLES.glob("*.yaml")):
        for document in yaml.safe_load_all(file.read_text()):
            if not document or "kind" not in document:
                continue
            resource = KINDS[document["kind"]].model_validate(document)
            assert (resource.api_version, unknown_fields(resource, "")) == (API_VERSION, []), file.name
            decoded.append(document["kind"])
    assert decoded


def test_a_resource_round_trips_to_the_same_wire_document():
    wire = {"apiVersion": API_VERSION, "kind": "Agent",
            "metadata": {"name": "run-1", "ownerReferences": [{"name": "spawner"}]},
            "spec": {"stationRef": "story-writer", "parameters": {"title": "a"}, "futureField": 1},
            "status": {"phase": "Running"}}

    assert Agent.model_validate(wire).model_dump(by_alias=True, exclude_none=True, mode="json") == wire


def test_an_unknown_enum_value_falls_back_to_the_first_member():
    assert (PermissionMode("bogus"), PermissionMode("bypass")) == (PermissionMode.AUTO, PermissionMode.BYPASS)


def test_unset_fields_are_left_out_of_the_wire_document():
    assert StationSpec(agent_def_ref="story-writer", template={}).model_dump(by_alias=True, exclude_none=True) == {
        "agentDefRef": "story-writer", "template": {}}


def test_a_kind_carries_its_group_version_plural_and_short_names():
    assert (Agent().api_version, Agent().kind, Agent.PLURAL, Agent.SHORT_NAMES) == (
        "agents.re-cinq.com/v1beta1", "Agent", "agents", ("agt",))


def test_a_required_field_is_enforced():
    try:
        SecretRef(name="TOKEN")
    except ValueError as error:
        assert "ref" in str(error)
    else:
        raise AssertionError("SecretRef without ref validated")
