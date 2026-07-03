module agentcore.crds.agent_status;

import agentcore.core.types : Phase;
import agentcore.crds.schema;

struct AgentStatus
{
	@optional Phase phase;
	@optional string jobName;
	@optional @Description("RFC3339 timestamp when the run began.") @Format("date-time") string startedAt;
	@optional @Description("RFC3339 timestamp when the run ended.") @Format("date-time") string completedAt;
	@optional int exitCode;
	@optional string output;
	@optional string failureReason;
	@optional string prUrl;
}
