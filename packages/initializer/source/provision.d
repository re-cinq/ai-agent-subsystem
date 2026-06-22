module provision;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind;
import std.array : array, join;
import std.conv : to;
import std.file : exists, isFile;
import std.path : buildPath;
import std.process : environment, spawnProcess, wait;
import std.string : split, toStringz;

import core.sys.posix.unistd : access, W_OK;

import agentcore.crds.enums : SinkType;
import agentcore.env : defaultWorkspace, envModel, envRepos, envWorkspace;
import agentcore.event : EventSource;
import agentcore.initcontext : InitContext;
import agentcore.log : logError;
import agentcore.output : SinkSpec;
import agentcore.packagemanager : packageFor;
import agentcore.packagemanagerselect : packageManagerByName;
import agentcore.repos : parseRepos;
import agentcore.tool : Tool;
import agentcore.toolselect : allTools;

import notify : notify, sinksFromEnv, sourceFromEnv;

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

	notify(sinks, source, `{"phase":"init","status":"started"}`);

	// The Claude installer writes into $HOME; it must be set and writable.
	if (active.canFind!(t => t.name == "claude") && !homeWritable())
		return fail(sinks, source,
			"[init] HOME is unset or not writable; the Claude installer needs it",
			`"reason":"home"`, 2);

	if (const code = ensurePrerequisites(active, sinks, source))
		return code;

	foreach (tool; active)
	{
		notify(sinks, source, `{"phase":"init","tool":"` ~ tool.name ~ `","status":"running"}`);
		foreach (step; tool.steps(ctx))
		{
			const code = runStep(step);
			if (code != 0)
				return fail(sinks, source,
					"[init] " ~ tool.name ~ " step failed (exit " ~ code.to!string ~ "): " ~ step.join(" "),
					`"tool":"` ~ tool.name ~ `","exitCode":` ~ code.to!string, code);
		}
	}

	notify(sinks, source, `{"phase":"init","status":"succeeded"}`);
	return 0;
}

/// The tools this run needs, in execution order — those whose `steps` are non-empty.
private Tool[] activeTools(in InitContext ctx)
{
	Tool[] active;
	foreach (tool; allTools())
		if (tool.steps(ctx).length)
			active ~= tool;
	return active;
}

/// Install any prerequisites the active tools (and http notifications) need but
/// that aren't already on `PATH`, using the package manager detected from the
/// distro. A no-op when nothing is missing.
private int ensurePrerequisites(Tool[] active, const SinkSpec[] sinks, in EventSource source)
{
	auto missing = neededExecutables(active, sinks).filter!(e => findExecutable(e).length == 0).array;
	if (missing.length == 0)
		return 0;

	const pmName = detectPackageManager();
	if (pmName.length == 0)
		return fail(sinks, source,
			"[init] missing prerequisites and no supported package manager: " ~ missing.join(", "),
			`"reason":"no-package-manager"`, 2);

	notify(sinks, source, `{"phase":"init","tool":"` ~ pmName ~ `","status":"installing"}`);
	auto pkgs = missing.map!packageFor.array;
	foreach (step; packageManagerByName(pmName).installSteps(pkgs))
	{
		const code = runStep(step);
		if (code != 0)
			return fail(sinks, source,
				"[init] prerequisite install failed (exit " ~ code.to!string ~ "): " ~ step.join(" "),
				`"reason":"install"`, code);
	}

	auto still = missing.filter!(e => findExecutable(e).length == 0).array;
	if (still.length)
		return fail(sinks, source,
			"[init] prerequisites still missing after install: " ~ still.join(", "),
			`"reason":"prerequisites"`, 2);
	return 0;
}

/// The executables the run needs: each active tool's `requires`, plus `curl` when
/// an http sink is configured (notifications POST through the curl CLI).
private string[] neededExecutables(Tool[] active, const SinkSpec[] sinks)
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

/// Report a failure: log it, emit a `failed` event carrying `detail`, return `code`.
private int fail(const SinkSpec[] sinks, in EventSource src, string logMsg, string detail, int code)
{
	logError(logMsg);
	notify(sinks, src, `{"phase":"init","status":"failed",` ~ detail ~ `}`);
	return code;
}

/// True when $HOME is set and writable — the installer's home for `~/.local/bin`.
private bool homeWritable()
{
	const home = environment.get("HOME", "");
	return home.length > 0 && access(home.toStringz, W_OK) == 0;
}

/// Resolve `cmd` to an existing file: the path itself when it contains a `/`, else
/// the first match on `PATH`. Returns "" when not found.
string findExecutable(string cmd)
{
	if (cmd.canFind('/'))
		return (exists(cmd) && isFile(cmd)) ? cmd : "";

	foreach (dir; environment.get("PATH", "").split(':'))
	{
		if (dir.length == 0)
			continue;
		const candidate = buildPath(dir, cmd);
		if (exists(candidate) && isFile(candidate))
			return candidate;
	}
	return "";
}
