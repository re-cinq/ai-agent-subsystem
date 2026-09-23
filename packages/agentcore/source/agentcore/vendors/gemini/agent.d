module agentcore.vendors.gemini.agent;

import agentcore.vendors.base.agent : Agent, ConversationArgs;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.enums : PermissionMode;

/// @google/gemini-cli adapter. Maps the recipe to `gemini --prompt … --output-format stream-json`.
final class GeminiAgent : Agent
{
	/// Un-hide the interface's no-conversation convenience overload, which this
	/// class's own `command` would otherwise shadow.
	alias command = Agent.command;

	override string name() const @safe
	{
		return "gemini";
	}

	/// Gemini CLI assigns its own session id — the launch command has no pin flag,
	/// only the `--resume` option.
	override string[] pinConversationArgs(string) const @safe
	{
		return [];
	}

	override string stateDir() const @safe
	{
		return ".gemini";
	}

	override string[] command(in AgentDefinitionSpec recipe, string renderedPrompt,
		in ConversationArgs conv) const @safe
	{
		string[] cmd = [
			"gemini",
			"--prompt", renderedPrompt,
			"--output-format", "stream-json",
			// The 2.5 family is retired for new users ("no longer available… use
			// gemini-3.1" — first hit in production 2026-09-02):
			// a model-less recipe must fall back to one that still answers.
			"--model", recipe.model.length ? recipe.model : "gemini-3.1-flash-lite",
			// Workspace trust is a separate gate from approvals: a headless run
			// in a freshly-cloned directory is "untrusted" and the CLI refuses
			// to start — --yolo does not cover it (exit 55, first hit in
			// production 2026-09-02). The run pod IS the trust boundary here:
			// the workspace is the recipe's own clone, in a container that
			// exists only for this run.
			"--skip-trust",
		];

		if (recipe.permissionMode == PermissionMode.bypass)
			cmd ~= "--yolo";

		// The CLI resumes only a session id it issued itself, and an unknown one is
		// a fatal input error (exit 42, before the first turn) — the caller's id never
		// is one, since there is no pin. The restored state holds just the
		// conversation being continued, so `latest` names it; and with nothing
		// restored, `latest` starts fresh with a warning, keeping the restore
		// best-effort.
		if (conv.resume.length)
			cmd ~= ["--resume", "latest"];

		return cmd;
	}
}

version (unittest) import fluent.asserts;

@safe unittest
{
	AgentDefinitionSpec recipe;
	recipe.model = "gemini-2.5-pro";
	const cmd = (new GeminiAgent).command(recipe, "Refactor");
	cmd[0].should.equal("gemini");
	cmd.should.contain("--output-format");
	cmd.should.contain("stream-json");
	// Always present, approvals or not: trust gates STARTUP, and every run's
	// workspace is a fresh clone the CLI has never seen.
	cmd.should.contain("--skip-trust");
	cmd.should.contain("gemini-2.5-pro");
	cmd.should.not.contain("--yolo");
	cmd.should.contain("--prompt");
	cmd.should.contain("Refactor");
}

@safe unittest
{
	AgentDefinitionSpec recipe;
	recipe.permissionMode = PermissionMode.bypass;
	const cmd = (new GeminiAgent).command(recipe, "Task");
	cmd.should.contain("--yolo");
}

@safe unittest
{
	AgentDefinitionSpec recipe;
	// The caller's id is not one the CLI issued, so resuming by it exits 42 before
	// the first turn; the restored state holds only the conversation being continued.
	const cmd = (new GeminiAgent).command(recipe, "Task", ConversationArgs("sess-xyz", ""));
	cmd[$ - 2 .. $].should.equal(["--resume", "latest"]);
	cmd.should.not.contain("sess-xyz");
}
