module agentcore.tools.hooks_tool;

import agentcore.core.env : envSkillsSource;
import agentcore.kube.bundle : bundleRoot;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.skills : safeSkillName;
import agentcore.tools.tool : Tool;

/// Stage the registry's hook bundle for the vendor this run's model routes to. Hooks
/// are how an org puts a guard between the agent and its tools (refuse a command,
/// audit a call), and every CLI reads them in its own format from its own place
/// under `$HOME` — Claude Code `.claude/settings.json`, Codex `.codex/`, Gemini
/// `.gemini/settings.json`, OpenCode its plugin dir. The subsystem translates none
/// of that: the registry publishes one bundle per vendor at
/// `<source>/hooks/<vendor>.tar.gz`, laid out relative to `$HOME`, and this tool
/// extracts it there. One mechanism for every vendor; the content stays with the
/// registry (consumer-agnostic, exactly like skills). The vendor name is the
/// adapter's own (`agentSetupForModel(model).name`), never recipe input, and the
/// source URL is read from the env so it never enters the command string.
/// Best-effort: a registry with no bundle for this vendor leaves the run without org
/// hooks, never failed. Runs after the skills tool, so a bundle's
/// `.claude/settings.json` wins over the flat `<source>/settings.json` it stages.
final class HooksTool : Tool
{
	private string vendor;

	this(string vendor) @safe
	{
		this.vendor = vendor;
	}

	override string name() const @safe
	{
		return "hooks";
	}

	override string[] requires() const @safe
	{
		return ["sh", "curl", "tar"];
	}

	override string[][] steps(in InitContext ctx) const @safe
	{
		// No registry, or a vendor name that could not be a safe path segment: nothing
		// to stage.
		if (ctx.skillsSource.length == 0 || !safeSkillName(vendor))
			return [];

		const src = "\"$" ~ envSkillsSource ~ "\"";

		return [[
			"sh", "-c",
			"mkdir -p " ~ bundleRoot ~ " && curl -fsSL " ~ src ~ "/hooks/" ~ vendor
				~ ".tar.gz | tar -xz -C " ~ bundleRoot ~ " 2>/dev/null || true",
		]];
	}
}

version (unittest) import fluent.asserts;
version (unittest) import std.algorithm.searching : canFind;

@safe unittest
{
	auto tool = new HooksTool("claude");
	tool.name.should.equal("hooks");
	tool.requires.should.equal(["sh", "curl", "tar"]);

	// No registry source: nothing to fetch.
	InitContext ctx;
	ctx.workspaceDir = "/workspace";
	tool.steps(ctx).length.should.equal(0);
}

@safe unittest
{
	InitContext ctx;
	ctx.workspaceDir = "/workspace";
	ctx.skillsSource = "https://registry.example/skills";

	// One step per run: the vendor-keyed bundle, extracted relative to $HOME.
	auto steps = (new HooksTool("codex")).steps(ctx);
	steps.length.should.equal(1);
	steps[0][0 .. 2].should.equal(["sh", "-c"]);
	steps[0][2].canFind("/hooks/codex.tar.gz").should.equal(true);
	steps[0][2].canFind("tar -xz -C /agent").should.equal(true);

	// The URL is an env reference, never a literal (no shell injection surface).
	steps[0][2].canFind("AGENT_SKILLS_SOURCE").should.equal(true);
	steps[0][2].canFind("registry.example").should.equal(false);

	// A vendor name that is not a safe path segment stages nothing rather than a
	// shell step it could break out of.
	(new HooksTool("../evil")).steps(ctx).length.should.equal(0);
}
