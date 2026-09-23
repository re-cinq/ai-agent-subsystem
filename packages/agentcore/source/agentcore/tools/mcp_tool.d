module agentcore.tools.mcp_tool;

import agentcore.crds.mcp_server : McpServer;
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
		return ["sh"];
	}

	/// Only a vendor that implements `McpSettings` gets steps: one whose adapter passes
	/// the servers on its command line needs nothing written.
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
	// A Gemini run gets the step that writes its servers into gemini-cli's settings.
	const steps = stepsFor(withServers("gemini-3.1-pro-preview"));
	steps.length.should.equal(1);
	steps[0][$ - 1].should.equal(geminiMcpSettingsPath);
}

unittest
{
	// Claude takes its servers on the command line (--mcp-config), so the init writes
	// nothing for it; and a run that declares no servers writes nothing for anyone.
	stepsFor(withServers("claude-sonnet-4-6")).length.should.equal(0);
	InitContext none;
	none.model = "gemini-3.1-pro-preview";
	stepsFor(none).length.should.equal(0);
}

@safe unittest
{
	// The step only creates a directory and writes a file: a plain shell is all it needs,
	// so a custom init image is never sent to its package manager for it.
	(new McpTool(agentSetupForModel("gemini-3.1-pro-preview"))).requires.should.equal(["sh"]);
}
