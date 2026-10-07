module agentcore.vendors.gemini.agent;

import agentcore.kube.bundle : geminiBypassPolicyPath, geminiExperimentsPath, geminiUserPoliciesDir;
import agentcore.vendors.base.agent : Agent, AgentEnv, ConversationArgs;
import agentcore.core.env : defaultWorkspace;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.enums : PermissionMode;

/// @google/gemini-cli adapter. Maps the recipe to `gemini --prompt … --output-format stream-json`.
final class GeminiAgent : Agent, AgentEnv
{
	/// Un-hide the interface's no-conversation convenience overload, which this
	/// class's own `command` would otherwise shadow.
	alias command = Agent.command;

	override string name() const @safe
	{
		return "gemini";
	}

	/// `GEMINI_EXP` names a local experiments file, which gemini-cli reads before it
	/// asks any experiments server. The init writes it (`GeminiSetup.mcpSteps`) with
	/// a longer request timeout than the CLI's own 60 s.
	override string[string] env() const @safe
	{
		return ["GEMINI_EXP": geminiExperimentsPath];
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
			// gemini-cli confines its file tools to the directory it runs in — the
			// repo clone — and refuses everything else: "Path not in workspace:
			// Attempted path /workspace/plan.md resolves outside the allowed
			// workspace directories". A run's INPUT FILES land beside that clone,
			// in the workspace root (a planning pod's ../plan.md is the whole
			// deliverable), so every read_file and write_file of one was refused
			// and the agent fell back to shell heredocs. The workspace is this
			// run's own volume, mounted at a reserved path, so declaring it costs
			// no reach the agent's shell did not already have.
			"--include-directories", defaultWorkspace,
		];

		// --yolo leaves the CLI's own rules in charge of what yolo does not cover, so
		// bypass also loads the init's policy that allows every tool in every mode
		// (`geminiBypassPolicyToml`). --policy replaces the user policies directory,
		// so that directory is named again and a hook bundle's policies still load.
		if (recipe.permissionMode == PermissionMode.bypass)
			cmd ~= ["--yolo", "--policy", geminiBypassPolicyPath, "--policy", geminiUserPoliciesDir];

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
	// A run's input files live in the workspace BESIDE the clone the CLI runs in
	// (planning's ../plan.md), and gemini-cli's file tools refuse a path outside
	// their roots — so the workspace itself is declared as one.
	import std.algorithm.searching : countUntil;

	const cmd = (new GeminiAgent).command(AgentDefinitionSpec.init, "Task");
	const at = cmd.countUntil("--include-directories");

	(at >= 0).should.equal(true);
	cmd[at + 1].should.equal("/workspace");
}

@safe unittest
{
	// The env var that points gemini-cli at the experiments file the init writes.
	(new GeminiAgent).env.should.equal(["GEMINI_EXP": "/agent/.gemini/experiments.json"]);
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
	// --yolo alone does not keep bypass's promise: headless, gemini-cli's own rules deny
	// every shell command whenever yolo does not apply, and plan mode denies everything.
	// The init's bypass policy allows every tool at user tier; --policy replaces the
	// user policies directory, so it is named again beside the file.
	import std.algorithm.searching : countUntil;

	AgentDefinitionSpec recipe;
	recipe.permissionMode = PermissionMode.bypass;
	const cmd = (new GeminiAgent).command(recipe, "Task");
	const at = cmd.countUntil("--policy");

	cmd[at .. at + 4].should.equal([
		"--policy", "/agent/.gemini/bypass-policy.toml",
		"--policy", "/agent/.gemini/policies",
	]);
}

@safe unittest
{
	// Under auto the CLI keeps its own rules: nothing widens what it may run.
	const cmd = (new GeminiAgent).command(AgentDefinitionSpec.init, "Task");
	cmd.should.not.contain("--policy");
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
