module agentcore.tools.git_tool;

import std.algorithm.searching : canFind;
import std.path : buildNormalizedPath;
import std.string : indexOf;

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
		return stripUserinfo(urlOrOwnerName);
	return "https://github.com/" ~ urlOrOwnerName ~ ".git";
}

/// Remove any `userinfo@` from a `scheme://userinfo@host/...` url so credentials a
/// caller embedded in the url can't reach the clone argv or a logged step. An scp-style
/// `user@host:path` (no scheme) is left as-is: there the `user` is an ssh login, not a
/// secret, and there is no password component.
private string stripUserinfo(string url) @safe pure
{
	const scheme = url.indexOf("://");
	if (scheme < 0)
		return url;
	const hostStart = scheme + 3;
	const rest = url[hostStart .. $];
	const at = rest.indexOf('@');
	if (at < 0)
		return url;
	const slash = rest.indexOf('/');
	if (slash >= 0 && at > slash)
		return url; // the '@' is in the path, not userinfo
	return url[0 .. hostStart] ~ rest[at + 1 .. $];
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

/// A destination is safe to `rm -rf` and clone into only when — after `.`/`..`/`//`
/// are resolved — it is an absolute path strictly *below* the workspace root: never
/// the root itself, a sibling, or a `..`-escape to a system path. `dest` is expected
/// already normalized (see `steps`); the root is normalized here. A workspace root of
/// `/` (or any non-absolute value) authorizes nothing, so nothing is ever deleted.
/// This is what stops a crafted `path: "../.."` or `/usr` from being `rm -rf`'d as
/// root inside the init container.
private bool safeDest(string dest, string workspaceDir) @safe pure
{
	const root = buildNormalizedPath(workspaceDir);
	if (root.length <= 1 || root[0] != '/')
		return false;
	const prefix = root ~ "/";
	return dest.length > prefix.length && dest[0 .. prefix.length] == prefix;
}

/// The clone argv for `r`. When the repo declares a `token_secret`, the clone
/// authenticates through a git credential helper that reads the token from that
/// **environment variable, by name**, at clone time — so the token value never
/// appears in the argv (and therefore never in any log of it); only the git child
/// that inherits the environment ever sees it. The name is validated first, so a
/// crafted `token_secret` can't inject into the helper, and the repo url is never
/// passed through a shell. A `--` separator precedes the url so an option-shaped
/// value (e.g. `--upload-pack=...`) is parsed as data, never as a git flag.
private string[] cloneStep(in RepoRef r, string dest) @safe pure
{
	const url = repoUrl(r.url);
	if (!isEnvName(r.tokenSecret))
		return ["git", "clone", "--", url, dest];

	const helper = "!f() { echo username=x-access-token; echo password=$" ~ r.tokenSecret ~ "; }; f";
	return ["git", "-c", "credential.helper=", "-c", "credential.helper=" ~ helper, "clone", "--", url, dest];
}

/// The checkout argv for a declared `ref_`. A ref beginning with `-` is never a
/// valid branch/tag/sha, so it is routed after a `--` separator: git then rejects
/// it as a non-matching pathspec (a clean, fail-closed error) instead of parsing
/// it as an option. A `--` can't wrap a legitimate ref — there it *starts* the
/// pathspec list, so `checkout -- v1` looks for a file named `v1` — hence the
/// common path stays a bare revision. (`--end-of-options` would be tidier but is
/// not honored by `git checkout` before ~2.44, so it isn't portable here.)
private string[] checkoutStep(string dest, string ref_) @safe pure
{
	if (ref_[0] == '-')
		return ["git", "-C", dest, "checkout", "--", ref_];
	return ["git", "-C", dest, "checkout", ref_];
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
			const dest = buildNormalizedPath(repoDest(r, ctx.workspaceDir));
			if (!safeDest(dest, ctx.workspaceDir))
				continue;
			all ~= ["rm", "-rf", dest];
			all ~= cloneStep(r, dest);
			if (r.ref_.length)
				all ~= checkoutStep(dest, r.ref_);
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
	// #117: userinfo embedded in an http(s) url is stripped so credentials can't leak into
	// the clone argv (visible in /proc/<pid>/cmdline) or a logged step. The secure path for
	// private repos is token_secret (env-based), not credentials in the url.
	repoUrl("https://user:token@github.com/o/app").should.equal("https://github.com/o/app");
	repoUrl("https://x-access-token@github.com/o/app.git").should.equal("https://github.com/o/app.git");
	// an scp-style user@host is an ssh login, not a secret, and is left intact.
	repoUrl("git@github.com:o/app.git").should.equal("git@github.com:o/app.git");

	// the stripped url is what lands in the clone argv.
	auto git = new GitTool;
	InitContext ctx;
	ctx.workspaceDir = "/ws";
	ctx.repos = [RepoRef("app", "https://user:token@github.com/o/app.git")];
	auto clone = git.steps(ctx)[1];
	clone.canFind!(a => a.canFind("token")).should.equal(false);
	clone.should.equal(["git", "clone", "--", "https://github.com/o/app.git", "/ws/app"]);
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
	steps.should.equal([["rm", "-rf", "/ws/app"], ["git", "clone", "--", "https://github.com/o/app.git", "/ws/app"]]);
	steps[1][0].should.equal("git");

	// a ref adds a checkout that works for branch, tag, or sha
	InitContext withRef;
	withRef.workspaceDir = "/ws";
	withRef.repos = [RepoRef("app", "https://github.com/o/app", "v1.2.3")];
	git.steps(withRef)[2].should.equal(["git", "-C", "/ws/app", "checkout", "v1.2.3"]);

	// an explicit absolute path under the workspace overrides <workspaceDir>/<name>
	InitContext withPath;
	withPath.workspaceDir = "/ws";
	withPath.repos = [RepoRef("app", "o/app")];
	withPath.repos[0].path = "/ws/custom/app";
	git.steps(withPath)[0].should.equal(["rm", "-rf", "/ws/custom/app"]);
}

// A `rm -rf <dest>` only ever fires on a path strictly *below* the workspace root
// (issue #100). A recipe `path` that escapes via `..`, names a system directory,
// or resolves to the root itself is rejected — no destructive step is emitted for
// it — so a crafted recipe can't delete `/usr` (or anything else) as root.
unittest
{
	auto git = new GitTool;

	string[][] stepsFor(string path)
	{
		InitContext ctx;
		ctx.workspaceDir = "/ws";
		auto r = RepoRef("app", "o/app");
		r.path = path;
		ctx.repos = [r];
		return git.steps(ctx);
	}

	// escapes and system paths produce no steps at all
	stepsFor("../../etc").length.should.equal(0);
	stepsFor("/ws/../etc").length.should.equal(0);
	stepsFor("/usr").length.should.equal(0);
	stepsFor("//").length.should.equal(0);
	stepsFor("/ws/../..").length.should.equal(0);
	stepsFor("/ws").length.should.equal(0); // the root itself is never rm-able

	// a legitimate nested path is kept, normalized
	stepsFor("/ws/team/app")[0].should.equal(["rm", "-rf", "/ws/team/app"]);
	stepsFor("sub/./app")[0].should.equal(["rm", "-rf", "/ws/sub/app"]);

	// a "/" workspace can never authorize a delete — everything is a system path
	InitContext rootWs;
	rootWs.workspaceDir = "/";
	rootWs.repos = [RepoRef("app", "o/app")];
	git.steps(rootWs).length.should.equal(0);
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
	clone[$ - 4 .. $].should.equal(["clone", "--", "https://github.com/o/app.git", "/ws/app"]);
	clone.canFind("credential.helper=").should.equal(true); // inherited helpers reset first
	clone.canFind!(a => a.canFind("username=x-access-token")).should.equal(true);
	clone.canFind!(a => a.canFind("password=$GH_TOKEN")).should.equal(true);

	// a malformed env-var name can't inject: fall back to an unauthenticated clone
	auto bad = RepoRef("app", "o/app");
	bad.tokenSecret = "GH;rm -rf /";
	ctx.repos = [bad];
	git.steps(ctx)[1].should.equal(["git", "clone", "--", "https://github.com/o/app.git", "/ws/app"]);
}

// An option-shaped url/ref is handed to git as data, never as a flag, so a crafted
// recipe can't inject git options — no argv injection (issue #99). The url rides a
// `--` separator; the (always-invalid) dash ref is rejected as a pathspec.
unittest
{
	auto git = new GitTool;

	InitContext optUrl;
	optUrl.workspaceDir = "/ws";
	optUrl.repos = [RepoRef("app", "--upload-pack=touch /tmp/pwned foo@bar")];
	auto clone = git.steps(optUrl)[1];
	clone.should.equal(["git", "clone", "--", "--upload-pack=touch /tmp/pwned foo@bar", "/ws/app"]);

	InitContext optRef;
	optRef.workspaceDir = "/ws";
	optRef.repos = [RepoRef("app", "o/app", "--orphan=x")];
	git.steps(optRef)[2].should.equal(["git", "-C", "/ws/app", "checkout", "--", "--orphan=x"]);

	// the `--` guards the authenticated clone path too
	auto authed = RepoRef("app", "o/app");
	authed.tokenSecret = "GH_TOKEN";
	InitContext optAuth;
	optAuth.workspaceDir = "/ws";
	optAuth.repos = [authed];
	auto authClone = git.steps(optAuth)[1];
	authClone[$ - 3 .. $].should.equal(["--", "https://github.com/o/app.git", "/ws/app"]);
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
