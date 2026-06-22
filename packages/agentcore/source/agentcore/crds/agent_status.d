module agentcore.crds.agent_status;

import agentcore.core.types : Phase;
import agentcore.crds.schema;

struct AgentStatus
{
	Phase phase;
	string jobName;
	@Description("RFC3339 timestamp when the run began.") @Format("date-time") string startedAt;
	@Description("RFC3339 timestamp when the run ended.") @Format("date-time") string completedAt;
	int exitCode;
	string output;
	string failureReason;
	string prUrl;
}
