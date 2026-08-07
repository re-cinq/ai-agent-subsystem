module agentcore.tools.skills_tool;

import agentcore.kube.bundle : claudeConfigDir, claudeSkillsDir, claudeSettingsPath,
	skillsStageSource, settingsStageSource;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.skills : safeSkillName;
import agentcore.tools.tool : Tool;

/// Stage the run's Claude skills + base settings into `$HOME/.claude` (HOME=/agent),
/// where headless `claude --print` auto-loads them user-scope (cwd-independent,
/// trust-free — project scope under cwd `/` is skipped). Three guarded, idempotent
/// steps, each skipping cleanly when its source is absent (like the SupervisorTool):
///  1. copy the baked base `settings.json` (org hooks) into the run's HOME;
///  2. copy each recipe-named skill from the baked org bundle;
///  3. best-effort surface the cloned repo's own `.claude/skills/`.
/// Active on every run: even with no named skills it stages the org settings + any
/// repo-own skills. Skill names come from the org recipe but are re-validated
/// (`safeSkillName`) before entering a shell path.
final class SkillsTool : Tool
{
	override string name() const @safe
	{
		return "skills";
	}

	override string[] requires() const @safe
	{
		return ["sh"];
	}

	override string[][] steps(in InitContext ctx) const @safe
	{
		string[][] result;

		// (1) Base org settings.json (the session hooks) -> the run's HOME.
		result ~= [
			"sh", "-c",
			"if [ -f " ~ settingsStageSource ~ " ]; then mkdir -p " ~ claudeConfigDir
				~ " && cp " ~ settingsStageSource ~ " " ~ claudeSettingsPath ~ "; fi",
		];

		// (2) Each recipe-named skill from the baked bundle (unsafe names dropped).
		foreach (skill; ctx.skills)
			if (safeSkillName(skill))
				result ~= [
					"sh", "-c",
					"if [ -d " ~ skillsStageSource ~ "/" ~ skill ~ " ]; then mkdir -p "
						~ claudeSkillsDir ~ " && cp -r " ~ skillsStageSource ~ "/" ~ skill
						~ " " ~ claudeSkillsDir ~ "/" ~ skill ~ "; fi",
				];

		// (3) The cloned repo's own .claude/skills (its conventions), best-effort — the
		// clone may sit at the workspace root or one level down. Never fails the init.
		result ~= [
			"sh", "-c",
			"for d in " ~ ctx.workspaceDir ~ "/*/.claude/skills " ~ ctx.workspaceDir
				~ "/.claude/skills; do if [ -d \"$d\" ]; then mkdir -p " ~ claudeSkillsDir
				~ " && cp -r \"$d\"/. " ~ claudeSkillsDir ~ "/ 2>/dev/null || true; fi; done",
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
	tool.requires.should.equal(["sh"]);

	InitContext ctx;
	ctx.workspaceDir = "/workspace";
	ctx.skills = ["review-checklist", "bad name", "../evil"];
	auto steps = tool.steps(ctx);

	// settings step + 1 safe skill + repo-own step; the 2 unsafe names are dropped.
	steps.length.should.equal(3);
	steps[0][2].canFind("cp " ~ "/usr/local/lib/ai-agent/settings.json"
			~ " /agent/.claude/settings.json").should.equal(true);
	steps[1][2].canFind("/usr/local/lib/ai-agent/skills/review-checklist").should.equal(true);
	steps[2][2].canFind("/workspace/*/.claude/skills").should.equal(true);

	// An unsafe name never reaches any shell step.
	steps.any!(s => s[2].canFind("evil") || s[2].canFind("bad name")).should.equal(false);
}

@safe unittest
{
	// No named skills: still stages the base settings + repo-own skills (active every run).
	InitContext ctx;
	ctx.workspaceDir = "/workspace";
	(new SkillsTool).steps(ctx).length.should.equal(2);
}
