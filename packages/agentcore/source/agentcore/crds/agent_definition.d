module agentcore.crds.agent_definition;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;

struct AgentDefinition
{
	string apiVersion = "agents.re-cinq.com/v1alpha1";
	string kind = "AgentDefinition";
	ObjectMeta metadata;
	AgentDefinitionSpec spec;
}
