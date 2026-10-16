module agentcore.vendors.realtime;

import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.vendors.base.agent : Agent, ConversationArgs, StdinSession;

version (unittest) import fluent.asserts;

/// The argv element the supervisor replaces with a turn's prompt.
enum promptSentinel = "@@AGENT_PROMPT@@";

/// The argv element the supervisor replaces with the session id the first turn announced.
enum sessionSentinel = "@@AGENT_SESSION@@";

/// How a realtime run drives its CLI. With `stdin`, `first` is one long-lived process
/// fed every turn on stdin. Otherwise each turn spawns `first` until a session id is
/// known, then `next`, with the sentinels substituted.
struct RealtimeArgv
{
	string[] first;
	string[] next;
	bool stdin;
}

/// The realtime argv for `vendor` running `recipe` with conversation wiring `conv`. A
/// per-turn vendor saves no pin of its own, so only `conv.resume` reaches its first turn.
RealtimeArgv realtimeArgv(const Agent vendor, in AgentDefinitionSpec recipe, in ConversationArgs conv) @safe
{
	if (auto session = cast(const StdinSession) vendor)
		return RealtimeArgv(session.sessionCommand(recipe, conv), null, true);
	return RealtimeArgv(vendor.command(recipe, promptSentinel, ConversationArgs(conv.resume, "")),
		vendor.command(recipe, promptSentinel, ConversationArgs(sessionSentinel, "")), false);
}

/// `template_` with each sentinel element replaced by `prompt` or `session`.
string[] turnArgv(const string[] template_, string prompt, string session) @safe pure nothrow
{
	string[] argv;
	foreach (arg; template_)
		argv ~= arg == promptSentinel ? prompt : arg == sessionSentinel ? session : arg;
	return argv;
}

version (unittest) private AgentDefinitionSpec recipeFor(string model)
{
	import vibe.data.json : parseJsonString;

	AgentDefinitionSpec recipe;
	recipe.model = model;
	if (model == "exec")
		recipe.toolConfig = parseJsonString(`{"command":["run-task"]}`);
	return recipe;
}

unittest // claude runs one stdin session, other vendors one process per turn
{
	import agentcore.vendors.select : agentForModel;

	bool stdinFor(string model)
	{
		auto recipe = recipeFor(model);
		return realtimeArgv(agentForModel(model), recipe, ConversationArgs.init).stdin;
	}

	[stdinFor("claude-sonnet-4-6"), stdinFor("gpt-5-codex"), stdinFor("gemini-3.1-flash-lite"),
		stdinFor("opencode/anthropic/claude-sonnet-4"), stdinFor("exec")]
		.should.equal([true, false, false, false, false]);
}

unittest // codex starts fresh, then resumes the announced thread on every later turn
{
	import agentcore.vendors.codex.agent : CodexAgent;

	AgentDefinitionSpec recipe;
	recipe.model = "gpt-5-codex";
	const argv = realtimeArgv(new CodexAgent, recipe, ConversationArgs.init);

	[turnArgv(argv.first, "one", "t-1"), turnArgv(argv.next, "two", "t-1")].should.equal([
		["codex", "exec", "--json", "--model", "gpt-5-codex", "--", "one"],
		["codex", "exec", "resume", "t-1", "--json", "--model", "gpt-5-codex", "two"],
	]);
}

unittest // a codex run resuming a session resumes it from the first turn
{
	import agentcore.vendors.codex.agent : CodexAgent;

	const argv = realtimeArgv(new CodexAgent, AgentDefinitionSpec.init, ConversationArgs("t-0", "ignored"));

	turnArgv(argv.first, "one", "").should.equal(["codex", "exec", "resume", "t-0", "--json", "one"]);
}

unittest // gemini resumes the latest restored session after its first turn
{
	import agentcore.vendors.gemini.agent : GeminiAgent;

	const argv = realtimeArgv(new GeminiAgent, AgentDefinitionSpec.init, ConversationArgs.init);

	[argv.first.length < argv.next.length, argv.next[$ - 2 .. $] == ["--resume", "latest"]]
		.should.equal([true, true]);
}

unittest // opencode and exec repeat the same fresh argv on every turn
{
	import agentcore.vendors.select : agentForModel;

	foreach (model; ["opencode/anthropic/claude-sonnet-4", "exec"])
	{
		auto recipe = recipeFor(model);
		const argv = realtimeArgv(agentForModel(model), recipe, ConversationArgs.init);
		argv.first.should.equal(argv.next);
	}
}
