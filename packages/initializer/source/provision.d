module provision;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind;
import std.array : array, join;
import std.conv : to;
import std.process : environment, spawnProcess, wait;
import std.string : toStringz, indexOf;

import core.sys.posix.sys.types : gid_t, uid_t;
import core.sys.posix.unistd : access, geteuid, W_OK;

import agentcore.kube.jobspec : agentUid, agentGid;

// druntime's core.sys.posix.unistd lacks lchown on some compilers (ldc's musl
// bindings); declare the POSIX prototype directly.
private extern (C) int lchown(scope const char* path, uid_t owner, gid_t group) @system nothrow @nogc;

import agentcore.crds.enums : SinkType;
import agentcore.core.env : defaultWorkspace, envModel, envRepos, envWorkspace;
import agentcore.output.event : EventSource, sourceFromEnv;
import agentcore.core.exec : findExecutable;
import agentcore.tools.initcontext : InitContext;
import agentcore.output.lifecycle : LifecycleEvent, Phase, Status, toJson;
import agentcore.core.log : logError;
import agentcore.crds.output_sink : OutputSink;
import agentcore.output.output : sinksFromEnv;
import agentcore.pkgmanager.packagemanager : packageFor;
import agentcore.pkgmanager.packagemanagerselect : packageManagerByName;
import agentcore.tools.agent_tool : AgentTool;
import agentcore.tools.repos : parseRepos;
import agentcore.tools.tool : Tool;
import agentcore.tools.toolselect : allTools;

import notify : notify;

/// Build the provisioning context from the env the controller injects.
InitContext contextFromEnv()
{
	InitContext ctx;
	ctx.model = environment.get(envModel, "");
	ctx.repos = parseRepos(environment.get(envRepos, ""));
	ctx.workspaceDir = environment.get(envWorkspace, defaultWorkspace);
	return ctx;
}

/// Provision the agent's environment: install any missing prerequisites, then run
/// each active tool's steps, reporting lifecycle to the configured sinks. Returns
/// the first non-zero step exit code, 2 for a setup failure, or 0 on success.
int provision(InitContext ctx)
{
	const sinks = sinksFromEnv();
	const source = sourceFromEnv();
	auto active = activeTools(ctx);

	notify(sinks, source, LifecycleEvent(Phase.init_, Status.started).toJson);

	// Every agent-CLI installer writes into $HOME (~/.local/bin, ~/.opencode/bin,
	// …); it must be set and writable when one is active.
	if (active.canFind!(t => cast(AgentTool) t !is null) && !homeWritable())
		return fail(sinks, source,
			"[init] HOME is unset or not writable; the agent CLI installer needs it",
			failedReason("home"), 2);

	if (const code = ensurePrerequisites(active, sinks, source))
		return code;

	foreach (tool; active)
	{
		notify(sinks, source, LifecycleEvent(Phase.init_, Status.running, tool.name).toJson);
		foreach (step; tool.steps(ctx))
		{
			const code = runStep(step);
			if (code != 0)
				return fail(sinks, source,
					"[init] " ~ tool.name ~ " step failed (exit " ~ code.to!string ~ "): "
						~ redactUrlCredentials(step.join(" ")),
					failedStep(tool.name, code), code);
		}
	}

	// This init runs as root; the agent container runs as agentUid/agentGid (jobspec
	// nonRootSecurity). fsGroup only chowns the volume roots at mount — everything the
	// provisioning above created is root-owned 0755, so the agent could neither write
	// its HOME (Claude fails on mkdir $HOME/.claude/session-env) nor edit the cloned
	// workspace. Hand both trees over before declaring init done.
	if (geteuid() == 0)
		foreach (root; [environment.get("HOME", ""), ctx.workspaceDir])
			if (!chownTree(root))
				return fail(sinks, source,
					"[init] chown of " ~ root ~ " to the agent uid failed",
					failedReason("chown"), 2);

	notify(sinks, source, LifecycleEvent(Phase.init_, Status.succeeded).toJson);
	return 0;
}

/// Recursively hand `root` (and everything under it) to the agent uid/gid. Symlinks
/// are re-owned, never followed — a repo can contain hostile links. Missing/empty
/// roots are fine (nothing to hand over).
private bool chownTree(string root)
{
	import std.file : dirEntries, exists, SpanMode;

	if (root.length == 0 || !root.exists)
		return true;

	bool ok = lchown(root.toStringz, agentUid, agentGid) == 0;
	foreach (entry; dirEntries(root, SpanMode.depth, false))
		ok = lchown(entry.name.toStringz, agentUid, agentGid) == 0 && ok;
	return ok;
}

/// The tools this run needs, in execution order — those whose `steps` are non-empty.
private Tool[] activeTools(in InitContext ctx)
{
	Tool[] active;
	foreach (tool; allTools(ctx))
		if (tool.steps(ctx).length)
			active ~= tool;
	return active;
}

/// Install any prerequisites the active tools (and http notifications) need but
/// that aren't already on `PATH`, using the package manager detected from the
/// distro. A no-op when nothing is missing.
private int ensurePrerequisites(Tool[] active, const OutputSink[] sinks, in EventSource source)
{
	auto missing = neededExecutables(active, sinks).filter!(e => findExecutable(e).length == 0).array;
	if (missing.length == 0)
		return 0;

	const pmName = detectPackageManager();
	if (pmName.length == 0)
		return fail(sinks, source,
			"[init] missing prerequisites and no supported package manager: " ~ missing.join(", "),
			failedReason("no-package-manager"), 2);

	notify(sinks, source, LifecycleEvent(Phase.init_, Status.installing, pmName).toJson);
	auto pkgs = missing.map!packageFor.array;
	foreach (step; packageManagerByName(pmName).installSteps(pkgs))
	{
		const code = runStep(step);
		if (code != 0)
			return fail(sinks, source,
				"[init] prerequisite install failed (exit " ~ code.to!string ~ "): "
					~ redactUrlCredentials(step.join(" ")),
				failedReason("install"), code);
	}

	auto still = missing.filter!(e => findExecutable(e).length == 0).array;
	if (still.length)
		return fail(sinks, source,
			"[init] prerequisites still missing after install: " ~ still.join(", "),
			failedReason("prerequisites"), 2);
	return 0;
}

/// The executables the run needs: each active tool's `requires`, plus `curl` when
/// an http sink is configured (notifications POST through the curl CLI).
private string[] neededExecutables(Tool[] active, const OutputSink[] sinks)
{
	string[] needed;
	foreach (tool; active)
		foreach (exe; tool.requires)
			if (!needed.canFind(exe))
				needed ~= exe;
	if (sinks.canFind!(s => s.type == SinkType.http) && !needed.canFind("curl"))
		needed ~= "curl";
	return needed;
}

/// Probe `PATH` for a supported package manager; "" when none is found.
string detectPackageManager()
{
	if (findExecutable("apt-get").length)
		return "apt";
	if (findExecutable("dnf").length)
		return "dnf";
	if (findExecutable("apk").length)
		return "apk";
	return "";
}

/// Run one argv step with inherited stdio. Returns its exit code, or 2 when the
/// executable isn't on `PATH` (a clean failure instead of a deep exception).
private int runStep(string[] step)
{
	if (findExecutable(step[0]).length == 0)
	{
		logError("[init] not found on PATH: " ~ step[0]);
		return 2;
	}
	try
		return wait(spawnProcess(step));
	catch (Exception e)
	{
		logError("[init] failed to run " ~ step[0] ~ ": " ~ e.msg);
		return 1;
	}
}

/// Report a failure: log it, emit `ev` (a `failed` lifecycle event), return `code`.
private int fail(const OutputSink[] sinks, in EventSource src, string logMsg, LifecycleEvent ev, int code)
{
	logError(logMsg);
	notify(sinks, src, ev.toJson);
	return code;
}

/// A `failed` init event explained by a short reason slug ("home", "install", …).
private LifecycleEvent failedReason(string reason)
{
	LifecycleEvent ev = {phase: Phase.init_, status: Status.failed};
	ev.reason = reason;
	return ev;
}

/// A `failed` init event for a tool step that exited non-zero.
private LifecycleEvent failedStep(string tool, int exitCode)
{
	LifecycleEvent ev = {phase: Phase.init_, status: Status.failed, tool: tool};
	ev.exitCode = exitCode;
	return ev;
}

/// True when $HOME is set and writable — the installer's home for `~/.local/bin`.
private bool homeWritable()
{
	const home = environment.get("HOME", "");
	return home.length > 0 && access(home.toStringz, W_OK) == 0;
}

/// Redact any `scheme://userinfo@host` credentials from a step string before it is
/// logged or emitted to a sink, so a repo url that carried embedded credentials never
/// reaches pod logs. Defense in depth behind repoUrl, which already strips userinfo.
string redactUrlCredentials(string s) @safe pure
{
	string result;
	size_t i = 0;
	while (i < s.length)
	{
		const rel = s[i .. $].indexOf("://");
		if (rel < 0)
		{
			result ~= s[i .. $];
			break;
		}
		const schemeEnd = i + rel + 3;
		result ~= s[i .. schemeEnd];
		size_t j = schemeEnd;
		ptrdiff_t at = -1;
		while (j < s.length && s[j] != ' ' && s[j] != '/' && s[j] != '?' && s[j] != '#')
		{
			if (s[j] == '@')
				at = j;
			j++;
		}
		result ~= at >= 0 ? "<redacted>@" ~ s[at + 1 .. j] : s[schemeEnd .. j];
		i = j;
	}
	return result;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	// #117: credentials embedded in a url are redacted from a logged/emitted step string.
	redactUrlCredentials("git clone -- https://user:tok@github.com/o/app /ws/app")
		.should.equal("git clone -- https://<redacted>@github.com/o/app /ws/app");
	// a url without userinfo is untouched.
	redactUrlCredentials("git clone -- https://github.com/o/app /ws/app")
		.should.equal("git clone -- https://github.com/o/app /ws/app");
	// an '@' in a query (no path) is not credentials — the host is not swallowed.
	redactUrlCredentials("curl https://host?next=a@b")
		.should.equal("curl https://host?next=a@b");
}
