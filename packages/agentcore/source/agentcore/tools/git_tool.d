module agentcore.tools.git_tool;

import std.algorithm.searching : canFind;

import agentcore.crds.repo_ref : RepoRef;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.tool : Tool;

version (unittest) import fluent.asserts;

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

/// The clone argv for `r`. When the repo declares a `token_secret`, the clone
/// authenticates through a git credential helper that reads the token from that
/// **environment variable, by name**, at clone time — so the token value never
/// appears in the argv (and therefore never in any log of it); only the git child
/// that inherits the environment ever sees it. The name is validated first, so a
/// crafted `token_secret` can't inject into the helper, and the repo url is never
/// passed through a shell.
private string[] cloneStep(in RepoRef r, string dest) @safe pure
{
	const url = repoUrl(r.url);
	if (!isEnvName(r.tokenSecret))
		return ["git", "clone", url, dest];

	const helper = "!f() { echo username=x-access-token; echo password=$" ~ r.tokenSecret ~ "; }; f";
	return ["git", "-c", "credential.helper=", "-c", "credential.helper=" ~ helper, "clone", url, dest];
}

/// True when `s` is a valid POSIX environment-variable name — the only shape we
/// splice into the credential helper.
private bool isEnvName(string s) @safe pure
{
	if (s.length == 0)
		return false;
	foreach (i, c; s)
	{
		const alpha = c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
		const digit = c >= '0' && c <= '9';
		if (!(alpha || (i > 0 && digit)))
			return false;
	}
	return true;
}

/// Clone each declared repo into the workspace. Full history (no `--depth`) so the
/// agent keeps `git log`/`blame`/`diff base...HEAD`. The `rm -rf` makes the clone
/// re-entrant across init-container retries (the shared emptyDir is not wiped
/// between attempts). A repo url is never passed through a shell; a private repo's
/// token is read from the environment by the git child, never spliced into argv.
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
			all ~= cloneStep(r, dest);
			if (r.ref_.length)
				all ~= ["git", "-C", dest, "checkout", r.ref_];
		}
		return all;
	}
}

unittest
{
	repoUrl("o/app").should.equal("https://github.com/o/app.git");
	repoUrl("https://github.com/o/app").should.equal("https://github.com/o/app");
	repoUrl("git@github.com:o/app.git").should.equal("git@github.com:o/app.git");
	repoUrl("").should.equal("");
}

unittest
{
	auto git = new GitTool;
	git.name.should.equal("git");
	git.requires.should.equal(["git"]);

	// no repos -> nothing to do
	InitContext empty;
	empty.workspaceDir = "/ws";
	git.steps(empty).length.should.equal(0);

	// one repo, no ref: rm then clone, no checkout, no shell
	InitContext one;
	one.workspaceDir = "/ws";
	one.repos = [RepoRef("app", "o/app")];
	auto steps = git.steps(one);
	steps.should.equal([["rm", "-rf", "/ws/app"], ["git", "clone", "https://github.com/o/app.git", "/ws/app"]]);
	steps[1][0].should.equal("git");

	// a ref adds a checkout that works for branch, tag, or sha
	InitContext withRef;
	withRef.workspaceDir = "/ws";
	withRef.repos = [RepoRef("app", "https://github.com/o/app", "v1.2.3")];
	git.steps(withRef)[2].should.equal(["git", "-C", "/ws/app", "checkout", "v1.2.3"]);

	// an explicit absolute path overrides <workspaceDir>/<name>
	InitContext withPath;
	withPath.workspaceDir = "/ws";
	withPath.repos = [RepoRef("app", "o/app")];
	withPath.repos[0].path = "/custom/app";
	git.steps(withPath)[0].should.equal(["rm", "-rf", "/custom/app"]);
}

unittest
{
	auto git = new GitTool;
	InitContext ctx;
	ctx.workspaceDir = "/ws";

	// a token_secret authenticates via a credential helper that reads the named
	// env var at clone time — only the name is in the argv, never a value.
	auto authed = RepoRef("app", "o/app");
	authed.tokenSecret = "GH_TOKEN";
	ctx.repos = [authed];
	auto clone = git.steps(ctx)[1];
	clone[0].should.equal("git");
	clone[$ - 3 .. $].should.equal(["clone", "https://github.com/o/app.git", "/ws/app"]);
	clone.canFind("credential.helper=").should.equal(true); // inherited helpers reset first
	clone.canFind!(a => a.canFind("username=x-access-token")).should.equal(true);
	clone.canFind!(a => a.canFind("password=$GH_TOKEN")).should.equal(true);

	// a malformed env-var name can't inject: fall back to an unauthenticated clone
	auto bad = RepoRef("app", "o/app");
	bad.tokenSecret = "GH;rm -rf /";
	ctx.repos = [bad];
	git.steps(ctx)[1].should.equal(["git", "clone", "https://github.com/o/app.git", "/ws/app"]);
}

unittest
{
	isEnvName("GH_TOKEN").should.equal(true);
	isEnvName("_token").should.equal(true);
	isEnvName("").should.equal(false);
	isEnvName("9TOKEN").should.equal(false);
	isEnvName("GH TOKEN").should.equal(false);
	isEnvName("GH;rm").should.equal(false);
}
