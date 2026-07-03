module agentcore.crds.agent_definition;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.schema;

@Plural("agentdefinitions")
@ShortNames(["agentdef", "ad"])
@PrinterColumn("Model", "string", ".spec.model")
@PrinterColumn("Age", "date", ".metadata.creationTimestamp")
struct AgentDefinition
{
	@optional string apiVersion = "agents.re-cinq.com/v1alpha1";
	@optional string kind = "AgentDefinition";
	@optional ObjectMeta metadata;
	@optional AgentDefinitionSpec spec;
}
