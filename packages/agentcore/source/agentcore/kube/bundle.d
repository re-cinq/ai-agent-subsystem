module agentcore.kube.bundle;

// The shared run bundle: an emptyDir the init container writes and the main
// agent container reads (HOME points here). Both the Job builder (jobspec) and
// the init's SupervisorTool import these, so the path the controller execs and
// the path the init stages to can never diverge into separate string literals.

/// Mount point of the shared bundle emptyDir; the agent container's HOME.
enum bundleRoot = "/agent";

/// Directory in the bundle the init stages executables into.
enum bundleBinDir = "/agent/bin";

/// Where the init drops the supervisor and where the main container execs it.
enum supervisorPath = "/agent/bin/ai-agent-supervisor";

/// Where the supervisor binary is baked into the agent image; the init copies it
/// from here into the bundle at run start.
enum supervisorStageSource = "/usr/local/lib/ai-agent/ai-agent-supervisor";

/// The run's Claude config dir. HOME=/agent, so headless `claude --print` auto-loads
/// user-scope skills + settings from here (cwd-independent, trust-free) — the init
/// (SkillsTool) stages into it.
enum claudeConfigDir = "/agent/.claude";
enum claudeSkillsDir = "/agent/.claude/skills";
enum claudeSettingsPath = "/agent/.claude/settings.json";

/// Where the org skill bundle + base settings.json are baked into the agent image;
/// the init copies the recipe-named skills and the settings from here into the run's
/// HOME (the SupervisorTool staging pattern).
enum skillsStageSource = "/usr/local/lib/ai-agent/skills";
enum settingsStageSource = "/usr/local/lib/ai-agent/settings.json";

version (unittest) import fluent.asserts;

@safe unittest
{
	supervisorPath.should.equal(bundleBinDir ~ "/ai-agent-supervisor");
}
