module agentcore.vendors.codex.agent;

import agentcore.vendors.base.agent : Agent, AgentSecretAliases, ConversationArgs;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.enums : McpTransport, PermissionMode;
import agentcore.crds.mcp_server : McpServer, envCredentials, headerCredentials, stdioLaunch;

/// OpenAI Codex CLI adapter: `codex exec --json …`. Codex governs tool access
/// through its sandbox/approval model rather than per-tool flags, so the recipe's
/// allow/deny lists do not map to arguments here.
final class CodexAgent : Agent, AgentSecretAliases
{
	/// Un-hide the interface's no-conversation convenience overload, which this
	/// class's own `command` would otherwise shadow.
	alias command = Agent.command;

	override string name() const @safe
	{
		return "codex";
	}

	/// `codex exec` authenticates with CODEX_API_KEY only; it ignores OPENAI_API_KEY,
	/// the name OpenAI keys conventionally carry, and sends no bearer at all.
	override string[string] secretAliases() const @safe
	{
		return ["CODEX_API_KEY": "OPENAI_API_KEY"];
	}

	/// Codex assigns its own session id — `codex exec` has no pin flag, only the
	/// `resume` subcommand. Continuity therefore needs the id read back from the run.
	override string[] pinConversationArgs(string) const @safe
	{
		return [];
	}

	override string stateDir() const @safe
	{
		return ".codex/sessions";
	}

	override string[] command(in AgentDefinitionSpec recipe, string renderedPrompt,
		in ConversationArgs conv) const @safe
	{
		// `resume` is a SUBCOMMAND here, not a flag, and it takes the prompt as a
		// positional rather than after `--` (`codex exec resume <id> <prompt>`) —
		// the reason the conversation id is a parameter of command() instead of an
		// argv fragment a caller could append.
		string[] cmd = ["codex"] ~ mcpOverrides(recipe.resources.mcpServers)
			~ (conv.resume.length ? ["exec", "resume", conv.resume, "--json"] : ["exec", "--json"]);
		if (recipe.model.length)
			cmd ~= ["--model", recipe.model];
		if (recipe.permissionMode == PermissionMode.bypass)
			cmd ~= "--dangerously-bypass-approvals-and-sandbox";
		cmd ~= conv.resume.length ? [renderedPrompt] : ["--", renderedPrompt];
		return cmd;
	}
}

/// The recipe's `mcp_servers` as Codex `-c key=value` config overrides, one per field,
/// so nothing has to be written to `config.toml` (`mcp_servers.<name>.<field>`, values
/// in TOML). Headers map to `env_http_headers`: Codex reads each value from the env var
/// the controller injects, so the token stays out of argv. A stdio server's secrets are
/// whitelisted with `env_vars`, since Codex hands stdio servers a minimal environment. Codex speaks streamable HTTP only; sse is rejected before a run starts.
private string[] mcpOverrides(in McpServer[] servers) @safe
{
	import std.algorithm.iteration : map;
	import std.array : array, join;
	import std.json : JSONOptions, JSONValue;

	// TOML basic strings share JSON's escapes except `\/`, so slashes stay unescaped.
	string toml(JSONValue value)
	{
		return value.toString(JSONOptions.doNotEscapeSlashes);
	}

	string[] args;
	void set(string name, string field, string tomlValue)
	{
		args ~= ["-c", "mcp_servers." ~ name ~ "." ~ field ~ "=" ~ tomlValue];
	}

	foreach (server; servers)
	{
		if (server.transport == McpTransport.stdio)
		{
			const argv = stdioLaunch(server);
			set(server.name, "command", toml(JSONValue(argv[0])));
			if (argv.length > 1)
				set(server.name, "args", toml(JSONValue(argv[1 .. $])));
			const forwarded = envCredentials(server).map!(c => c.envVar).array;
			if (forwarded.length)
				set(server.name, "env_vars", toml(JSONValue(forwarded)));
			continue;
		}
		set(server.name, "url", toml(JSONValue(server.url)));
		const headers = headerCredentials(server).map!(c => c.name ~ `="` ~ c.envVar ~ `"`).array;
		if (headers.length)
			set(server.name, "env_http_headers", "{" ~ headers.join(",") ~ "}");
	}
	return args;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	AgentDefinitionSpec recipe;
	recipe.model = "gpt-5-codex";
	const cmd = (new CodexAgent).command(recipe, "Refactor");
	cmd[0].should.equal("codex");
	cmd[1].should.equal("exec");
	cmd.should.contain("--json");
	cmd.should.contain("gpt-5-codex");
	cmd.should.not.contain("--dangerously-bypass-approvals-and-sandbox"); // auto is the default
	cmd[$ - 2].should.equal("--"); // prompt fenced behind end-of-options
	cmd[$ - 1].should.equal("Refactor");
}

@safe unittest
{
	// #136: a leading-dash prompt is data, not a codex flag — the -- fence guarantees it.
	AgentDefinitionSpec recipe;
	const cmd = (new CodexAgent).command(recipe, "--help");
	cmd[$ - 2].should.equal("--");
	cmd[$ - 1].should.equal("--help");
}

@safe unittest
{
	// Explicit bypass adds the sandbox-skip flag.
	AgentDefinitionSpec recipe;
	recipe.permissionMode = PermissionMode.bypass;
	(new CodexAgent).command(recipe, "p").should.contain("--dangerously-bypass-approvals-and-sandbox");
}

@safe unittest
{
	// `resume` is a subcommand and the prompt is a positional — NOT after `--`.
	AgentDefinitionSpec recipe;
	const cmd = (new CodexAgent).command(recipe, "next turn", ConversationArgs("sess-1", ""));
	cmd[0 .. 4].should.equal(["codex", "exec", "resume", "sess-1"]);
	cmd[$ - 1].should.equal("next turn");
	cmd.should.not.contain("--");
}

@safe unittest
{
	// A fresh run keeps the original shape, prompt after the terminator.
	AgentDefinitionSpec recipe;
	const cmd = (new CodexAgent).command(recipe, "p", ConversationArgs.init);
	cmd[0 .. 3].should.equal(["codex", "exec", "--json"]);
	cmd[$ - 2 .. $].should.equal(["--", "p"]);
}

@safe unittest
{
	// Date/timestamp-partitioned paths mean the state is addressed as a directory.
	(new CodexAgent).stateDir.should.equal(".codex/sessions");
}

@safe unittest
{
	// Codex has no pin flag — only `resume`. An empty result is how the adapter says
	// the id is assigned by the CLI, rather than pretending it can be chosen.
	(new CodexAgent).pinConversationArgs("sess-1").should.equal(cast(string[])[]);
}

@safe unittest
{
	// mcp_servers become -c overrides before the subcommand; the credential is an env
	// var name, never the token.
	AgentDefinitionSpec recipe;
	recipe.resources.mcpServers = [
		McpServer("tools", McpTransport.http, "", null, "https://tools-mcp/mcp", "tools-mcp-auth"),
		McpServer("local", McpTransport.stdio, "mcp-local", ["--stdio"], "", ""),
	];

	(new CodexAgent).command(recipe, "p")[0 .. 10].should.equal([
		"codex",
		"-c", `mcp_servers.tools.url="https://tools-mcp/mcp"`,
		"-c", `mcp_servers.tools.env_http_headers={Authorization="TOOLS_MCP_AUTH"}`,
		"-c", `mcp_servers.local.command="mcp-local"`,
		"-c", `mcp_servers.local.args=["--stdio"]`,
		"exec",
	]);
}

@safe unittest
{
	// Every header maps into env_http_headers; a stdio server's env secrets run it under
	// the sh export wrapper and are whitelisted with env_vars.
	import agentcore.crds.mcp_server : McpHeader;
	import agentcore.crds.secret_ref : SecretRef;

	AgentDefinitionSpec recipe;
	recipe.resources.mcpServers = [
		McpServer("tools", McpTransport.http, "", null, "https://t/mcp", "", [McpHeader("X-Api-Key", "k"), McpHeader("X-Org", "o")]),
		McpServer("gh", McpTransport.stdio, "gh-mcp", null, "", "", [], [SecretRef("GITHUB_TOKEN", "gh-token")]),
	];

	(new CodexAgent).command(recipe, "p")[1 .. 11].should.equal([
		"-c", `mcp_servers.tools.url="https://t/mcp"`,
		"-c", `mcp_servers.tools.env_http_headers={X-Api-Key="MCP_TOOLS_X_API_KEY",X-Org="MCP_TOOLS_X_ORG"}`,
		"-c", `mcp_servers.gh.command="sh"`,
		"-c", `mcp_servers.gh.args=["-c","export GITHUB_TOKEN=\"$MCP_GH_GITHUB_TOKEN\"; exec \"$0\" \"$@\"","gh-mcp"]`,
		"-c", `mcp_servers.gh.env_vars=["MCP_GH_GITHUB_TOKEN"]`,
	]);
}
