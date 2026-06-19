module agentcore.crds.agent;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.agent_spec : AgentSpec;
import agentcore.crds.agent_status : AgentStatus;

struct Agent
{
	string apiVersion = "agents.re-cinq.com/v1alpha1";
	string kind = "Agent";
	ObjectMeta metadata;
	AgentSpec spec;
	AgentStatus status;
}
