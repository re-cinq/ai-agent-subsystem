module agentcore.env;

// Environment variable names the controller injects into a run container and
// the supervisor reads. Shared here so the Job builder and the supervisor never
// drift apart.

enum envPrompt = "LORE_PROMPT";
enum envModel = "LORE_MODEL";
enum envNotifyUrl = "LORE_NOTIFY_URL";
enum envSinks = "AGENT_SINKS";
enum envParameters = "LORE_PARAMETERS";
enum envTargetRepo = "TARGET_REPO";
enum envBranch = "BRANCH_NAME";

/// Model used when a recipe does not specify one.
enum defaultModel = "claude-sonnet-4-6";
