module agentcore.tools.agentsetup;

/// How to install one coding-agent CLI into the run pod — the Claude Code CLI, the
/// OpenAI Codex CLI, OpenCode, or any other. An implementation reports the
/// executables its installer needs on `PATH` and the argv steps that install the
/// CLI. Which provider a given run uses is decided upstream by `agentSetupForModel`,
/// keyed to the same routing that picks the agent adapter, so the installed CLI can
/// never drift from the adapter that will run it. New providers are added by
/// implementing this interface and registering it in `allAgentSetups` — the init
/// container's runner does not change.
interface AgentSetup
{
	/// Identifier, matching the agent adapter's name (e.g. "claude", "codex",
	/// "opencode").
	string name() const @safe;

	/// Executables the installer needs on `PATH`; the initializer installs any that
	/// are missing before running the steps.
	string[] requires() const @safe;

	/// The argv steps that install the CLI, in order. Each step is idempotent — it
	/// skips when the CLI is already present — so init-container retries and images
	/// that pre-bake the CLI (e.g. the integration-test mock) are no-ops.
	string[][] installSteps() const @safe;
}
