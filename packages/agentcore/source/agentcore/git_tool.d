module agentcore.git_tool;

import std.algorithm.searching : canFind;

import agentcore.crds.repo_ref : RepoRef;
import agentcore.initcontext : InitContext;
import agentcore.tool : Tool;

/// Expand a repo reference to a clone URL. A value that already looks like a URL
/// (contains "://" or an scp-style "user@host:") is used as-is; a bare
/// "owner/name" is expanded to a GitHub https URL.
string repoUrl(string urlOrOwnerName) @safe pure
{
	if (urlOrOwnerName.length == 0)
		return "";
	if (urlOrOwnerName.canFind("://") || urlOrOwnerName.canFind('@'))
		return urlOrOwnerName;
	return "https://github.com/" ~ urlOrOwnerName ~ ".git";
}

/// Where a repo is cloned: its explicit `path` when set (resolved under the
/// workspace if relative), else `<workspaceDir>/<name>`.
string repoDest(in RepoRef r, string workspaceDir) @safe pure
{
	if (r.path.length)
		return r.path[0] == '/' ? r.path : joinPath(workspaceDir, r.path);
	return joinPath(workspaceDir, r.name);
}

private string joinPath(string base, string leaf) @safe pure
{
	if (base.length == 0)
		return leaf;
	const trimmed = base[$ - 1] == '/' ? base[0 .. $ - 1] : base;
	return trimmed ~ "/" ~ leaf;
}

/// A destination is safe to `rm -rf` and clone into only when it is an absolute
/// path below the root — never empty, relative, or "/".
private bool safeDest(string dest) @safe pure
{
	return dest.length > 1 && dest[0] == '/';
}

/// Clone each declared repo into the workspace. Full history (no `--depth`) so the
/// agent keeps `git log`/`blame`/`diff base...HEAD`. The `rm -rf` makes the clone
/// re-entrant across init-container retries (the shared emptyDir is not wiped
/// between attempts). Everything is a plain argv array — never a shell — so a repo
/// url can't inject a command.
final class GitTool : Tool
{
	override string name() const @safe
	{
		return "git";
	}

	override string[] requires() const @safe
	{
		return ["git"];
	}

	override string[][] steps(in InitContext ctx) const @safe
	{
		string[][] all;
		foreach (r; ctx.repos)
		{
			const dest = repoDest(r, ctx.workspaceDir);
			if (!safeDest(dest))
				continue;
			all ~= ["rm", "-rf", dest];
			all ~= ["git", "clone", repoUrl(r.url), dest];
			if (r.ref_.length)
				all ~= ["git", "-C", dest, "checkout", r.ref_];
		}
		return all;
	}
}

unittest
{
	assert(repoUrl("o/app") == "https://github.com/o/app.git");
	assert(repoUrl("https://github.com/o/app") == "https://github.com/o/app");
	assert(repoUrl("git@github.com:o/app.git") == "git@github.com:o/app.git");
	assert(repoUrl("") == "");
}

unittest
{
	auto git = new GitTool;
	assert(git.name == "git");
	assert(git.requires == ["git"]);

	// no repos -> nothing to do
	InitContext empty;
	empty.workspaceDir = "/ws";
	assert(git.steps(empty).length == 0);

	// one repo, no ref: rm then clone, no checkout, no shell
	InitContext one;
	one.workspaceDir = "/ws";
	one.repos = [RepoRef("app", "o/app")];
	auto steps = git.steps(one);
	assert(steps == [["rm", "-rf", "/ws/app"], ["git", "clone", "https://github.com/o/app.git", "/ws/app"]]);
	assert(steps[1][0] == "git");

	// a ref adds a checkout that works for branch, tag, or sha
	InitContext withRef;
	withRef.workspaceDir = "/ws";
	withRef.repos = [RepoRef("app", "https://github.com/o/app", "v1.2.3")];
	assert(git.steps(withRef)[2] == ["git", "-C", "/ws/app", "checkout", "v1.2.3"]);

	// an explicit absolute path overrides <workspaceDir>/<name>
	InitContext withPath;
	withPath.workspaceDir = "/ws";
	withPath.repos = [RepoRef("app", "o/app")];
	withPath.repos[0].path = "/custom/app";
	assert(git.steps(withPath)[0] == ["rm", "-rf", "/custom/app"]);
}
