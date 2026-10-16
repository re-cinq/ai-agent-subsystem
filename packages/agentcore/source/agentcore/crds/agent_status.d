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
	@optional @Description("Harness session id of this run; pass it as spec.resumeSession to continue the conversation.") string sessionId;
	@optional @Description("Provider batch id while a batch-executed run is in flight.") string batchId;
	@optional @Description("Provider the batch was submitted to.") string batchProvider;
	@optional @Description("True once the batch timed out and the fallback Job started.") bool batchFallback;
	@optional @Description("Failed attempts to delete the batch's provider-side objects.") int batchCleanupAttempts;
}
