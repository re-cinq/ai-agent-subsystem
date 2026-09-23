module agentcore.tools.mcp_tool;

import agentcore.crds.mcp_server : McpServer;
import agentcore.kube.bundle : initializerPath;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.tool : Tool;
import agentcore.vendors.base.setup : AgentSetup, McpSettings;

/// Parse the JSON array of MCP servers the controller serialized into
/// `AGENT_MCP_SERVERS` — the CRD struct itself, so no field is dropped at this seam. A
/// malformed document yields no servers rather than throwing, like `AGENT_FILES`.
McpServer[] parseMcpServers(string json)
{
	import vibe.data.json : Json, parseJsonString;
	import agentcore.crds.serialization : fromJson;

	if (json.length == 0)
		return null;
	McpServer[] servers;
	try
		foreach (entry; parseJsonString(json).get!(Json[]))
			servers ~= fromJson!McpServer(entry);
	catch (Exception)
		return null;
	return servers;
}

/// Hand the recipe's `mcp_servers` to a vendor CLI that reads them from a settings
/// file rather than its argv.
final class McpTool : Tool
{
	private const AgentSetup setup;

	this(const AgentSetup setup) @safe
	{
		this.setup = setup;
	}

	override string name() const @safe
	{
		return "mcp";
	}

	override string[] requires() const @safe
	{
		return [initializerPath];
	}

	/// Only a vendor that implements `McpSettings` gets steps: one whose adapter passes
	/// the servers on its command line needs nothing written. The vendor decides what a
	/// run without servers needs (Gemini clears a restored file; see `GeminiSetup`).
	override string[][] steps(in InitContext ctx) const @safe
	{
		auto settings = cast(const McpSettings) setup;
		return settings is null ? [] : settings.mcpSteps(ctx.mcpServers);
	}
}

version (unittest)
{
	import fluent.asserts;
	import agentcore.crds.enums : McpTransport;
	import agentcore.crds.mcp_server : McpServer;
	import agentcore.kube.bundle : geminiMcpSettingsPath;
	import agentcore.vendors.select : agentSetupForModel;
	import std.algorithm.searching : canFind;

	private InitContext withServers(string model)
	{
		InitContext ctx;
		ctx.model = model;
		ctx.mcpServers = [
			McpServer("tools", McpTransport.http, "", null, "https://tools-mcp/mcp", "tools-mcp-auth"),
		];
		return ctx;
	}

	private string[][] stepsFor(in InitContext ctx)
	{
		return (new McpTool(agentSetupForModel(ctx.model))).steps(ctx);
	}
}

unittest
{
	// A Gemini run gets the step that merges its servers into gemini-cli's settings.
	const steps = stepsFor(withServers("gemini-3.1-pro-preview"));
	steps.length.should.equal(1);
	steps[0].canFind(geminiMcpSettingsPath).should.equal(true);
	steps[0][$ - 1].canFind("tools-mcp").should.equal(true);
}

unittest
{
	// Claude takes its servers on the command line (--mcp-config), so the init writes
	// nothing for it, servers or none; a Gemini run without servers still gets the
	// step, which writes an empty `mcpServers`.
	stepsFor(withServers("claude-sonnet-4-6")).length.should.equal(0);
	InitContext none;
	none.model = "claude-sonnet-4-6";
	stepsFor(none).length.should.equal(0);
	none.model = "gemini-3.1-pro-preview";
	stepsFor(none)[0][$ - 1].should.equal("{}");
}

@safe unittest
{
	// The step re-enters the init binary baked into the agent image, by absolute path:
	// nothing for a custom init image's package manager to install.
	(new McpTool(agentSetupForModel("gemini-3.1-pro-preview"))).requires.should.equal([initializerPath]);
}
