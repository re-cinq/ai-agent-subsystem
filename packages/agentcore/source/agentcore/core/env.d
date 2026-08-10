module agentcore.core.env;

// Environment variable names the controller injects into a run container and
// the supervisor reads. Shared here so the Job builder and the supervisor never
// drift apart.

enum envModel = "AGENT_MODEL";
enum envNotifyUrl = "AGENT_NOTIFY_URL";
enum envSinks = "AGENT_SINKS";
enum envParameters = "AGENT_PARAMETERS";

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
// JSON array of {event, path} the supervisor reads back once the agent exits, each
// raised as a named `kind:"file"` event carrying the file's contents (#188).
enum envWatch = "AGENT_WATCH";
// JSON array of skill names the init fetches into $HOME/.claude/skills for this run.
enum envSkills = "AGENT_SKILLS";
// Base URL of the skill/settings registry the init fetches skills + settings from.
enum envSkillsSource = "AGENT_SKILLS_SOURCE";

// After the agent emits its terminal event, how long the supervisor waits for the
// process to exit on its own before escalating SIGTERM -> SIGKILL. Some agent CLIs
// finish their work but leave a lingering worker that keeps the process (and its
// stdout) open, so process exit alone is not a reliable "run is done" signal.
enum envExitGraceMs = "AGENT_EXIT_GRACE_MS";
enum defaultExitGraceMs = 5000;

// The supervisor's own run deadline. An agent that neither exits nor emits a terminal
// event leaves the supervisor waiting until the kubelet kills the pod at the Job's
// activeDeadlineSeconds — which takes the terminal `agentExit` event with it, so
// downstream sees a run that simply stops. The controller sets this below the Job's
// window so the supervisor always terminates the agent first and still reports (#48).
// Unset or non-positive disables it, leaving the Job deadline as the only bound.
enum envDeadlineMs = "AGENT_DEADLINE_MS";
// How far ahead of the Job's activeDeadlineSeconds the supervisor's deadline fires:
// enough to SIGTERM the agent, wait a grace window, SIGKILL it, and flush the event.
enum deadlineMarginMs = 10_000;

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
