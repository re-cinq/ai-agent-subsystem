module agentcore.tools.provider_tool;

import agentcore.tools.initcontext : InitContext;
import agentcore.tools.tool : Tool;
import agentcore.vendors.base.setup : AgentSetup, ProviderSettings;

/// Point a vendor CLI at the model provider the run selected (the Foundry endpoint)
/// by writing the provider into the CLI's own config file.
final class ProviderTool : Tool
{
	private const AgentSetup setup;

	this(const AgentSetup setup) @safe
	{
		this.setup = setup;
	}

	override string name() const @safe
	{
		return "provider";
	}

	override string[] requires() const @safe
	{
		return ["bash"];
	}

	/// Only a vendor that implements `ProviderSettings` gets steps: one that takes its
	/// provider some other way needs nothing written.
	override string[][] steps(in InitContext ctx) const @safe
	{
		auto settings = cast(const ProviderSettings) setup;
		return settings is null ? [] : settings.providerSteps;
	}
}
