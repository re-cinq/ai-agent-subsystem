module agentcore.vendors.claude.agent;

import std.conv : to;

import agentcore.vendors.base.agent : Agent;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.enums : PermissionMode, McpTransport;
import agentcore.crds.mcp_server : McpServer, headerEnvName;
import agentcore.kube.bundle : claudeSettingsPath;
import agentcore.core.env : defaultModel;

/// Claude Code CLI adapter: maps the recipe to `claude --print --output-format
/// stream-json …`. `bypass` permission mode skips the permission prompts; `auto`
/// passes the recipe's allow/deny tool lists through.
final class ClaudeAgent : Agent
{
	override string name() const @safe
	{
		return "claude";
	}

	override string[] command(in AgentDefinitionSpec recipe, string renderedPrompt) const @safe
	{
		string[] cmd = [
			"claude",
			"--print",
			"--verbose",
			"--output-format", "stream-json",
			"--model", recipe.model.length ? recipe.model : defaultModel,
		];

		if (recipe.permissionMode == PermissionMode.bypass)
			cmd ~= "--dangerously-skip-permissions";
		else
			foreach (tool; recipe.allowedTools)
				cmd ~= ["--allowedTools", tool];

		// disallowedTools is enforced in EVERY permission mode: bypass only skips
		// the interactive prompts, it must not silently re-enable an explicitly
		// denied tool (e.g. mcp__lore__lore_create_pipeline_task, which the seeded
		// agent recipe denies to keep a live-MCP pod from spawning more tasks).
		foreach (tool; recipe.disallowedTools)
			cmd ~= ["--disallowedTools", tool];

		// Live Lore tools: the pod cwd is `/`, so Claude's project-dir auto-load
		// never fires — the recipe's mcp_servers are passed explicitly (and
		// --strict-mcp-config ignores any ambient config). The auth header value is
		// a `${ENV}` reference Claude expands from the pod environment, where the
		// controller injects the resolved headers_secret (see runEnv) — the token
		// never rides in argv.
		const mcpConfig = mcpConfigJson(recipe.resources.mcpServers);
		if (mcpConfig.length)
			cmd ~= ["--mcp-config", mcpConfig, "--strict-mcp-config"];

		// The init stages the org base settings (session hooks) + the recipe's skills
		// into $HOME/.claude (HOME=/agent). Skills auto-load user-scope with no flag;
		// point --settings at the staged file explicitly for robustness (a missing file
		// is silently ignored in --print). The path is shared with the SkillsTool via
		// kube.bundle so the two can never drift.
		cmd ~= ["--settings", claudeSettingsPath];

		if (recipe.maxTurns > 0)
			cmd ~= ["--max-turns", recipe.maxTurns.to!string];

		cmd ~= ["--", renderedPrompt];
		return cmd;
	}
}

/// Render the recipe's `mcp_servers` into Claude Code's `--mcp-config` JSON
/// (`{"mcpServers":{name:{type,url,headers…}}}`). Empty when the recipe declares
/// none. An http/sse entry with a `headers_secret` gets an `Authorization` header
/// whose value is a `${ENV}` placeholder Claude expands at runtime.
private string mcpConfigJson(in McpServer[] servers) @safe
{
	import std.json : JSONValue, JSONOptions;

	if (!servers.length)
		return "";

	JSONValue[string] byName;
	foreach (server; servers)
	{
		JSONValue[string] entry;
		final switch (server.transport) with (McpTransport)
		{
		case http:
			entry["type"] = "http";
			entry["url"] = server.url;
			break;
		case sse:
			entry["type"] = "sse";
			entry["url"] = server.url;
			break;
		case stdio:
			entry["type"] = "stdio";
			entry["command"] = server.command;
			if (server.args.length)
				entry["args"] = JSONValue(server.args.dup);
			break;
		}
		if (server.headersSecret.length && server.transport != McpTransport.stdio)
		{
			JSONValue[string] headers;
			headers["Authorization"] = JSONValue("${" ~ headerEnvName(server) ~ "}");
			entry["headers"] = JSONValue(headers);
		}
		byName[server.name] = JSONValue(entry);
	}
	JSONValue root;
	root["mcpServers"] = JSONValue(byName);
	// doNotEscapeSlashes keeps URLs readable (https://… not https:\/\/…); both are
	// valid JSON, but the unescaped form is what operators expect to see in pod args.
	return root.toString(JSONOptions.doNotEscapeSlashes);
}

version (unittest) import fluent.asserts;

@safe unittest
{
	AgentDefinitionSpec recipe;
	recipe.model = "claude-sonnet-4-6";
	recipe.permissionMode = PermissionMode.auto_;
	recipe.allowedTools = ["Read", "Edit"];
	recipe.disallowedTools = ["Bash(rm *)"];
	recipe.maxTurns = 40;

	const cmd = (new ClaudeAgent).command(recipe, "Fix it");
	cmd[0].should.equal("claude");
	cmd.should.contain("claude-sonnet-4-6");
	cmd.should.contain("--allowedTools");
	cmd.should.contain("Read");
	cmd.should.contain("Edit");
	cmd.should.contain("--disallowedTools");
	cmd.should.contain("Bash(rm *)");
	cmd.should.contain("--max-turns");
	cmd.should.contain("40");
	cmd.should.not.contain("--dangerously-skip-permissions");
	cmd[$ - 2].should.equal("--");
	cmd[$ - 1].should.equal("Fix it");
}

@safe unittest
{
	// Defaults: permissionMode is auto (allow/deny enforced, no bypass), empty model -> default.
	AgentDefinitionSpec recipe;
	const cmd = (new ClaudeAgent).command(recipe, "p");
	cmd.should.not.contain("--dangerously-skip-permissions");
	cmd.should.contain(defaultModel);
	cmd.should.not.contain("--allowedTools");
}

@safe unittest
{
	// Explicit bypass skips the permission prompts.
	AgentDefinitionSpec recipe;
	recipe.permissionMode = PermissionMode.bypass;
	(new ClaudeAgent).command(recipe, "p").should.contain("--dangerously-skip-permissions");
}

@safe unittest
{
	// Every run points --settings at the staged base settings.json (the init stages
	// the org session hooks + recipe skills into $HOME/.claude).
	import std.algorithm.searching : countUntil;

	AgentDefinitionSpec recipe;
	const cmd = (new ClaudeAgent).command(recipe, "p");
	cmd.should.contain("--settings");
	cmd[cmd.countUntil("--settings") + 1].should.equal("/agent/.claude/settings.json");
}

@safe unittest
{
	// disallowedTools is honored under bypass too — bypass only drops the prompts.
	AgentDefinitionSpec recipe;
	recipe.permissionMode = PermissionMode.bypass;
	recipe.disallowedTools = ["mcp__lore__lore_create_pipeline_task"];

	const cmd = (new ClaudeAgent).command(recipe, "p");
	cmd.should.contain("--dangerously-skip-permissions");
	cmd.should.contain("--disallowedTools");
	cmd.should.contain("mcp__lore__lore_create_pipeline_task");
}

@safe unittest
{
	// An http mcp_servers entry renders --mcp-config with a ${ENV} auth header
	// (token stays out of argv) plus --strict-mcp-config.
	import std.algorithm : countUntil;

	AgentDefinitionSpec recipe;
	recipe.resources.mcpServers = [
		McpServer("lore", McpTransport.http, "", null, "https://lore-mcp.example/mcp", "lore-mcp-auth")
	];

	const cmd = (new ClaudeAgent).command(recipe, "p");
	cmd.should.contain("--mcp-config");
	cmd.should.contain("--strict-mcp-config");

	const json = cmd[cmd.countUntil("--mcp-config") + 1];
	json.should.contain(`"type":"http"`);
	json.should.contain(`"url":"https://lore-mcp.example/mcp"`);
	json.should.contain(`"Authorization":"${LORE_MCP_AUTH}"`);
	json.should.not.contain("lore-mcp-auth"); // raw secret key never appears
}

@safe unittest
{
	// No mcp_servers -> no --mcp-config.
	AgentDefinitionSpec recipe;
	(new ClaudeAgent).command(recipe, "p").should.not.contain("--mcp-config");
}
