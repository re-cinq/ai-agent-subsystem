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

/// Where the agent image bakes its pinned Claude CLI (build arg
/// `CLAUDE_CLI_VERSION`); the init copies it into HOME instead of downloading one.
/// Off PATH on purpose: the main container runs the Station's own image, so only
/// the copy in the shared HOME is visible there.
enum claudeStageSource = "/usr/local/lib/ai-agent/claude";

/// The run's Claude config dir. HOME=/agent, so headless `claude --print` auto-loads
/// user-scope skills + settings from here (cwd-independent, trust-free) — the init
/// (SkillsTool) fetches into it. Consumer-agnostic paths; no baked content lives in
/// the image.
enum claudeConfigDir = "/agent/.claude";
enum claudeSkillsDir = "/agent/.claude/skills";
enum claudeSettingsPath = "/agent/.claude/settings.json";

/// Where the init (McpTool) merges a recipe's MCP servers for gemini-cli, which reads
/// them from its settings rather than its argv: the CLI's USER settings. Its system
/// scope (`GEMINI_CLI_SYSTEM_SETTINGS_PATH`, v0.11.2) is refused unless the directory
/// is root-owned, which a uid-1000 pod cannot arrange — the CLI skipped the file with a
/// security warning and every Gemini run started with no tools. The user file is read
/// without that check. A hook bundle and a restored conversation both land here first
/// (the mcp tool runs last), so the init rewrites only `mcpServers`, never the file.
enum geminiMcpSettingsPath = "/agent/.gemini/settings.json";

/// The init binary itself, baked into the agent image, which a step re-enters for work
/// the init image's shell cannot do (a JSON merge: slim has no jq, node or python).
enum initializerPath = "/usr/local/bin/ai-agent-init";

version (unittest) import fluent.asserts;

@safe unittest
{
	supervisorPath.should.equal(bundleBinDir ~ "/ai-agent-supervisor");
}
