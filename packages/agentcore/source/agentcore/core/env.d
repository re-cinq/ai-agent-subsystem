module agentcore.core.env;

// Environment variable names the controller injects into a run container and
// the supervisor reads. Shared here so the Job builder and the supervisor never
// drift apart.

enum envPrompt = "LORE_PROMPT";
enum envModel = "LORE_MODEL";
enum envNotifyUrl = "LORE_NOTIFY_URL";
enum envSinks = "AGENT_SINKS";
enum envParameters = "LORE_PARAMETERS";

// HTTP sink delivery retry: a transient POST failure is retried with capped
// exponential backoff before the event is dropped (never fatal to the run).
enum envSinkRetryAttempts = "AGENT_SINK_RETRY_ATTEMPTS";
enum envSinkRetryBaseMs = "AGENT_SINK_RETRY_BASE_MS";
enum envSinkRetryMaxMs = "AGENT_SINK_RETRY_MAX_MS";
enum envTargetRepo = "TARGET_REPO";
enum envBranch = "BRANCH_NAME";
enum envRepos = "AGENT_REPOS";
enum envWorkspace = "WORKSPACE_DIR";
enum envSelect = "AGENT_SELECT";

// Identity the controller stamps onto the run so every emitted event can be
// traced back to its agent + pod in a workflow. `POD_*` come from the downward
// API; the rest from the resolved Station / AgentDefinition / Agent.
enum envAgentName = "AGENT_NAME";
enum envStationName = "STATION_NAME";
enum envTaskId = "TASK_ID";
enum envPodName = "POD_NAME";
enum envPodNamespace = "POD_NAMESPACE";

/// Model used when a recipe does not specify one.
enum defaultModel = "claude-sonnet-4-6";

/// Workspace the init container clones repos into when none is injected.
enum defaultWorkspace = "/workspace";

/// Cap on bytes of run-pod log copied into status.output, keeping the tail, so
/// the Agent object stays well under etcd's ~1.5 MB per-object limit.
enum envMaxOutputBytes = "MAX_OUTPUT_BYTES";
enum defaultMaxOutputBytes = 256 * 1024;
