module agentcore.tools.skills_tool;

import agentcore.core.env : envSkillsSource;
import agentcore.kube.bundle : claudeConfigDir, claudeSkillsDir, claudeSettingsPath;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.skills : safeSkillName;
import agentcore.tools.tool : Tool;

/// Stage the run's Claude skills + settings into `$HOME/.claude` (HOME=/agent), where
/// headless `claude --print` auto-loads them user-scope (cwd-independent, trust-free —
/// project scope under cwd `/` is skipped). The subsystem is **consumer-agnostic**: it
/// FETCHES from the URL the recipe hands it (`resources.skillsSource`) and knows nothing
/// of the registry — nothing org-specific is baked in. Steps, all guarded + best-effort
/// (a missing/unreachable skill never fails the run):
///  1. copy the cloned repo's own `.claude/skills` (its conventions);
///  2. when a source is set: fetch the registry's `settings.json` (org session hooks);
///  3. fetch each recipe-named skill as `<source>/<name>.tar.gz` and extract it.
/// The source is read from the env at run time (`"$AGENT_SKILLS_SOURCE"`) so a URL from
/// the recipe never enters the shell command string; skill names are re-validated.
final class SkillsTool : Tool
{
	override string name() const @safe
	{
		return "skills";
	}

	override string[] requires() const @safe
	{
		return ["sh", "curl", "tar"];
	}

	override string[][] steps(in InitContext ctx) const @safe
	{
		string[][] result;

		// (1) the cloned repo's own skills, best-effort (clone may sit at the workspace
		// root or one level down).
		result ~= [
			"sh", "-c",
			"for d in " ~ ctx.workspaceDir ~ "/*/.claude/skills " ~ ctx.workspaceDir
				~ "/.claude/skills; do if [ -d \"$d\" ]; then mkdir -p " ~ claudeSkillsDir
				~ " && cp -r \"$d\"/. " ~ claudeSkillsDir ~ "/ 2>/dev/null || true; fi; done",
		];

		// No registry configured -> repo-own only.
		if (ctx.skillsSource.length == 0)
			return result;

		// The registry URL, read from the env so it never enters the command string.
		const src = "\"$" ~ envSkillsSource ~ "\"";

		// (2) org settings.json (session hooks) from the registry root.
		result ~= [
			"sh", "-c",
			"mkdir -p " ~ claudeConfigDir ~ " && curl -fsSL " ~ src ~ "/settings.json -o "
				~ claudeSettingsPath ~ " 2>/dev/null || true",
		];

		// (3) each named skill as a tarball, extracted into the skills dir.
		foreach (skill; ctx.skills)
			if (safeSkillName(skill))
				result ~= [
					"sh", "-c",
					"mkdir -p " ~ claudeSkillsDir ~ " && curl -fsSL " ~ src ~ "/" ~ skill
						~ ".tar.gz | tar -xz -C " ~ claudeSkillsDir ~ " 2>/dev/null || true",
				];

		return result;
	}
}

version (unittest) import fluent.asserts;
version (unittest) import std.algorithm.searching : canFind, any;

@safe unittest
{
	auto tool = new SkillsTool;
	tool.name.should.equal("skills");
	tool.requires.should.equal(["sh", "curl", "tar"]);

	// No registry source: only the repo-own copy step.
	InitContext ctx;
	ctx.workspaceDir = "/workspace";
	auto steps = tool.steps(ctx);
	steps.length.should.equal(1);
	steps[0][2].canFind("/workspace/*/.claude/skills").should.equal(true);
}

@safe unittest
{
	InitContext ctx;
	ctx.workspaceDir = "/workspace";
	ctx.skillsSource = "https://registry.example/skills";
	ctx.skills = ["review-checklist", "bad name", "../evil"];
	auto steps = (new SkillsTool).steps(ctx);

	// repo-own + settings fetch + 1 safe skill (2 unsafe names dropped) = 3.
	steps.length.should.equal(3);
	steps[1][2].canFind("AGENT_SKILLS_SOURCE").should.equal(true);
	steps[1][2].canFind("/settings.json").should.equal(true);
	steps[2][2].canFind("/review-checklist.tar.gz").should.equal(true);

	// Unsafe names never reach a shell step; the recipe URL is env-ref only, never a
	// literal in the command (no shell injection surface).
	steps.any!(s => s[2].canFind("evil") || s[2].canFind("bad name")).should.equal(false);
	steps.any!(s => s[2].canFind("registry.example")).should.equal(false);
}
