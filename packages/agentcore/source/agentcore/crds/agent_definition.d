module agentcore.crds.agent_definition;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.schema;

@Plural("agentdefinitions")
@ShortNames(["agentdef", "ad"])
@PrinterColumn("Model", "string", ".spec.model")
@PrinterColumn("Age", "date", ".metadata.creationTimestamp")
struct AgentDefinition
{
	string apiVersion = "agents.re-cinq.com/v1alpha1";
	string kind = "AgentDefinition";
	ObjectMeta metadata;
	AgentDefinitionSpec spec;
}
