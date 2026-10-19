module agentcore.crds.agent_definition;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.api_group : crApiVersion;
import agentcore.crds.schema;

@Plural("agentdefinitions")
@ShortNames(["agentdef", "ad"])
@PrinterColumn("Model", "string", ".spec.model")
@PrinterColumn("Age", "date", ".metadata.creationTimestamp")
struct AgentDefinition
{
	@optional string apiVersion = crApiVersion;
	@optional string kind = "AgentDefinition";
	@optional ObjectMeta metadata;
	@optional AgentDefinitionSpec spec;
}
