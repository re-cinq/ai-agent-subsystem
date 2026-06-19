module agentcore.crds.agent_status;

import agentcore.types : Phase;
import agentcore.schema;

struct AgentStatus
{
	Phase phase;
	string jobName;
	@Description("RFC3339 timestamp when the run began.") string startedAt;
	@Description("RFC3339 timestamp when the run ended.") string completedAt;
	int exitCode;
	string output;
	string failureReason;
	string prUrl;
}
