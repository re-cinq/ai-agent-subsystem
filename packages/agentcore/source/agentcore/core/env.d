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
// A previous run this one continues: the base URL its state archive is fetched from,
// and the opaque id identifying it. Empty id ⇒ fresh conversation.
enum envConversationSource = "AGENT_CONVERSATION_SOURCE";
enum envConversationId = "AGENT_CONVERSATION_ID";
// The id this run saves its own state as (a fork's destination).
enum envConversationPin = "AGENT_CONVERSATION_PIN";
// Name of the agent-secrets key holding the conversation registry's Authorization
// header. The controller injects that key as an env var of the same name; the pod
// resolves it back, so the credential never rides in argv or a command string.
enum envConversationAuth = "AGENT_CONVERSATION_AUTH";
/// The credential VALUE, exported by the init under a shell-safe name.
///
/// `AGENT_CONVERSATION_AUTH` holds the NAME of the injected secret key, and that
/// name comes from Kubernetes, where dashes are legal — `agent-events-auth`. A shell
/// will not propagate a variable whose name is not a valid shell identifier, so a
/// child process (`printenv`) can never see it, whatever the syntax. The init reads
/// it with getenv, where the name is just a string, and re-exports it as this.
enum envConversationAuthValue = "LORE_CONVERSATION_AUTH";

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
