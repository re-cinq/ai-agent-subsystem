module agentcore.crds.mcp_server;

import agentcore.crds.schema;
import agentcore.crds.enums : McpTransport;
import agentcore.crds.secret_ref : SecretRef;

struct McpServer
{
	@optional @Required string name;
	@optional @Required McpTransport transport;
	@optional string command;
	@optional string[] args;
	@optional string url;
	@optional @wire("headers_secret") @Description("Deprecated: use headers. Allowlisted secret-store key sent as the Authorization header.")
	string headersSecret;
	@optional @Description("http/sse: headers whose values come from the secret store.")
	McpHeader[] headers;
	@optional @Description("stdio: environment variables for the server process whose values come from the secret store.")
	SecretRef[] env;
}

struct McpHeader
{
	@optional @Required @Description("HTTP header name, e.g. X-API-Key.")
	string name;

	@optional @Required @wire("ref") @Description("Allowlisted secret-store key holding the header value.")
	string ref_;
}

/// One secret a server needs at run time: the header or env var `name` the server sees,
/// the pod env var `envVar` the controller injects it under, and the secret-store key.
struct McpCredential
{
	string name;
	string envVar;
	string secret;
}

/// The headers an http/sse server sends, each valued from a pod env var. The legacy
/// `headers_secret` keeps its env var name so existing recipes render unchanged.
McpCredential[] headerCredentials(in McpServer server) @safe pure
{
	McpCredential[] credentials;
	if (server.headersSecret.length)
		credentials ~= McpCredential("Authorization", headerEnvName(server), server.headersSecret);
	foreach (header; server.headers)
		credentials ~= McpCredential(header.name, credentialEnvName(server, header.name), header.ref_);
	return credentials;
}

/// The env vars a stdio server process gets, each valued from a pod env var.
McpCredential[] envCredentials(in McpServer server) @safe pure
{
	McpCredential[] credentials;
	foreach (var; server.env)
		credentials ~= McpCredential(var.name, credentialEnvName(server, var.name), var.ref_);
	return credentials;
}

/// Every secret `server` needs injected into the pod.
McpCredential[] credentials(in McpServer server) @safe pure
{
	return headerCredentials(server) ~ envCredentials(server);
}

/// The argv that starts a stdio server. With `env` secrets it runs under `sh`, which
/// exports each pod env var under the name the server expects and then `exec`s it:
/// one launch every CLI runs alike, whatever env expansion its config supports.
string[] stdioLaunch(in McpServer server) @safe pure
{
	import std.algorithm.iteration : map;
	import std.array : join;

	const exports = envCredentials(server);
	if (!exports.length)
		return [server.command] ~ server.args.dup;
	const script = "export " ~ exports.map!(c => c.name ~ `="$` ~ c.envVar ~ `"`).join(" ")
		~ `; exec "$0" "$@"`;
	return ["sh", "-c", script, server.command] ~ server.args.dup;
}

/// `MCP_<SERVER>_<NAME>`, shell-safe: one server's header or env var never shares a pod
/// env var with another's.
private string credentialEnvName(in McpServer server, string name) @safe pure
{
	return "MCP_" ~ shellSafe(server.name) ~ "_" ~ shellSafe(name);
}

private string shellSafe(string raw) @safe pure
{
	import std.ascii : isAlphaNum, toUpper;
	import std.array : appender;

	auto name = appender!string;
	foreach (char c; raw)
		name ~= isAlphaNum(c) ? cast(char) toUpper(c) : '_';
	return name.data;
}

/// Shell-safe env-var name that carries this server's `headers_secret` value at
/// pod runtime. The controller injects the secret under this name (see
/// `runEnv`) and the Claude adapter references it as `${NAME}` inside the
/// `--mcp-config` JSON, which Claude Code expands from the environment — so both
/// sides MUST derive the name the same way. Uppercased, every non-alphanumeric
/// char folded to `_` (e.g. `tools-mcp-auth` -> `TOOLS_MCP_AUTH`), because `${}`
/// expansion rejects the hyphens the raw secret key allows. Empty when there is
/// no `headers_secret`.
string headerEnvName(in McpServer server) @safe pure
{
	return server.headersSecret.length ? shellSafe(server.headersSecret) : "";
}

/// Why `servers` cannot be handed to the `vendor` agent CLI, or "" when they can. The
/// exec runner has no CLI to read them and Codex speaks no sse — without this check those
/// servers would be dropped without a word. Each entry needs a unique name that every
/// CLI's config accepts as a key, and the field its transport connects through. Two
/// credentials whose names fold to the same pod env var (`a-b`/`C` and `a`/`B-C`, or
/// servers `Tools` and `tools`) are refused unless they carry the same secret: the
/// controller injects only the first, so the other server would send its secret.
string mcpViolation(in McpServer[] servers, string vendor) @safe pure
{
	import std.algorithm.searching : all, canFind;
	import std.ascii : isAlpha, isAlphaNum;

	if (servers.length && vendor == "exec")
		return "the exec model does not support resources.mcp_servers";
	string[] seen;
	string[] injectedVars;
	string[] injectedSecrets;
	foreach (server; servers)
	{
		if (!server.name.length)
			return "resources.mcp_servers entry has no name";
		if (!server.name.all!(c => c.isAlphaNum || c == '_' || c == '-'))
			return "resources.mcp_servers name \"" ~ server.name ~ "\" may only hold letters, digits, _ and -";
		if (vendor == "codex" && server.transport == McpTransport.sse)
			return "resources.mcp_servers \"" ~ server.name ~ "\": codex does not support sse, use http";
		if (seen.canFind(server.name))
			return "resources.mcp_servers name \"" ~ server.name ~ "\" is not unique";
		seen ~= server.name;
		const needsUrl = server.transport != McpTransport.stdio;
		if (needsUrl && !server.url.length)
			return "resources.mcp_servers \"" ~ server.name ~ "\" needs a url for " ~ server.transport;
		if (!needsUrl && !server.command.length)
			return "resources.mcp_servers \"" ~ server.name ~ "\" needs a command for stdio";
		const where = "resources.mcp_servers \"" ~ server.name ~ "\" ";
		if (needsUrl && server.env.length)
			return where ~ "sets env, which only a stdio server takes; use headers";
		if (!needsUrl && (server.headers.length || server.headersSecret.length))
			return where ~ "sets headers, which only an http or sse server takes; use env";
		string[] headerNames;
		foreach (header; headerCredentials(server))
		{
			if (!header.name.length || !header.name.all!(c => c.isAlphaNum || c == '-'))
				return where ~ "header \"" ~ header.name ~ "\" may only hold letters, digits and -";
			if (headerNames.canFind(header.name))
				return where ~ "sets header \"" ~ header.name ~ "\" twice";
			headerNames ~= header.name;
		}
		string[] envNames;
		foreach (var; server.env)
		{
			if (!var.name.length || (!var.name[0].isAlpha && var.name[0] != '_')
				|| !var.name.all!(c => c.isAlphaNum || c == '_'))
				return where ~ "env \"" ~ var.name ~ "\" is not a valid variable name";
			if (envNames.canFind(var.name))
				return where ~ "sets env \"" ~ var.name ~ "\" twice";
			envNames ~= var.name;
		}
		foreach (credential; credentials(server))
			if (!credential.secret.length)
				return where ~ "\"" ~ credential.name ~ "\" has no ref";
		foreach (credential; credentials(server))
		{
			foreach (i, envVar; injectedVars)
				if (envVar == credential.envVar && injectedSecrets[i] != credential.secret)
					return where ~ "\"" ~ credential.name ~ "\" lands on env var " ~ envVar
						~ ", which another credential already uses; rename the server, header or env";
			injectedVars ~= credential.envVar;
			injectedSecrets ~= credential.secret;
		}
	}
	return "";
}

@safe unittest
{
	static assert(jsonNameOf!(McpServer.headersSecret) == "headers_secret");
}

@safe unittest
{
	const http = McpServer("tools", McpTransport.http, "", null, "https://tools-mcp/mcp", "");
	const stdio = McpServer("local", McpTransport.stdio, "mcp-local", null, "", "");
	const violations = [
		mcpViolation([http, stdio], "codex"),
		mcpViolation(null, "exec"),
		mcpViolation([http], "exec"),
		mcpViolation([McpServer("", McpTransport.http, "", null, "https://x", "")], "claude"),
		mcpViolation([McpServer("my.tools", McpTransport.http, "", null, "https://x", "")], "claude"),
		mcpViolation([McpServer("events", McpTransport.sse, "", null, "https://x", "")], "codex"),
		mcpViolation([http, http], "claude"),
		mcpViolation([McpServer("sse", McpTransport.sse, "", null, "", "")], "claude"),
		mcpViolation([McpServer("local", McpTransport.stdio, "", null, "", "")], "claude"),
	];
	violations.should.equal([
		"",
		"",
		"the exec model does not support resources.mcp_servers",
		"resources.mcp_servers entry has no name",
		`resources.mcp_servers name "my.tools" may only hold letters, digits, _ and -`,
		`resources.mcp_servers "events": codex does not support sse, use http`,
		`resources.mcp_servers name "tools" is not unique`,
		`resources.mcp_servers "sse" needs a url for sse`,
		`resources.mcp_servers "local" needs a command for stdio`,
	]);
}

@safe unittest
{
	McpServer server;
	server.headersSecret = "tools-mcp-auth";
	headerEnvName(server).should.equal("TOOLS_MCP_AUTH");

	McpServer noAuth;
	headerEnvName(noAuth).should.equal("");
}

version (unittest) import fluent.asserts;

@safe unittest
{
	const violations = [
		mcpViolation([McpServer("t", McpTransport.http, "", null, "https://x", "", [], [SecretRef("A", "a")])], "claude"),
		mcpViolation([McpServer("t", McpTransport.stdio, "c", null, "", "", [McpHeader("X-Key", "k")])], "claude"),
		mcpViolation([McpServer("t", McpTransport.http, "", null, "https://x", "", [McpHeader("X Key", "k")])], "claude"),
		mcpViolation([McpServer("t", McpTransport.http, "", null, "https://x", "auth", [McpHeader("Authorization", "k")])], "claude"),
		mcpViolation([McpServer("t", McpTransport.stdio, "c", null, "", "", [], [SecretRef("1TOKEN", "a")])], "claude"),
		mcpViolation([McpServer("t", McpTransport.stdio, "c", null, "", "", [], [SecretRef("T", "a"), SecretRef("T", "b")])], "claude"),
		mcpViolation([McpServer("t", McpTransport.http, "", null, "https://x", "", [McpHeader("X-Key", "")])], "claude"),
		mcpViolation([McpServer("t", McpTransport.stdio, "c", null, "", "", [], [SecretRef("_TOKEN", "a")])], "claude"),
	];
	violations.should.equal([
		`resources.mcp_servers "t" sets env, which only a stdio server takes; use headers`,
		`resources.mcp_servers "t" sets headers, which only an http or sse server takes; use env`,
		`resources.mcp_servers "t" header "X Key" may only hold letters, digits and -`,
		`resources.mcp_servers "t" sets header "Authorization" twice`,
		`resources.mcp_servers "t" env "1TOKEN" is not a valid variable name`,
		`resources.mcp_servers "t" sets env "T" twice`,
		`resources.mcp_servers "t" "X-Key" has no ref`,
		"",
	]);
}

@safe unittest
{
	// Legacy headers_secret keeps its env var; new headers and env get MCP_<SERVER>_<NAME>.
	const http = McpServer("my-tools", McpTransport.http, "", null, "https://x", "tools-auth",
		[McpHeader("X-Api-Key", "tools-key")]);
	credentials(http).should.equal([
		McpCredential("Authorization", "TOOLS_AUTH", "tools-auth"),
		McpCredential("X-Api-Key", "MCP_MY_TOOLS_X_API_KEY", "tools-key"),
	]);
}

@safe unittest
{
	// A stdio server with env secrets runs under sh, which exports them and execs it.
	const plain = McpServer("gh", McpTransport.stdio, "gh-mcp", ["--ro"], "", "");
	stdioLaunch(plain).should.equal(["gh-mcp", "--ro"]);

	auto withEnv = McpServer("gh", McpTransport.stdio, "gh-mcp", ["--ro"], "", "");
	withEnv.env = [SecretRef("GITHUB_TOKEN", "gh-token")];
	stdioLaunch(withEnv).should.equal(["sh", "-c",
		`export GITHUB_TOKEN="$MCP_GH_GITHUB_TOKEN"; exec "$0" "$@"`, "gh-mcp", "--ro"]);
}

@safe unittest // credentials that fold to one pod env var are refused unless they carry the same secret
{
	McpServer http(string name, string headersSecret, McpHeader[] headers)
	{
		return McpServer(name, McpTransport.http, "", null, "https://x", headersSecret, headers);
	}

	const violations = [
		mcpViolation([http("a-b", "", [McpHeader("C", "k1")]), http("a", "", [McpHeader("B-C", "k2")])], "claude"),
		mcpViolation([http("Tools", "", [McpHeader("X-Key", "k1")]), http("tools", "", [McpHeader("X-Key", "k2")])], "claude"),
		mcpViolation([http("one", "x-y", null), http("two", "x_y", null)], "claude"),
		mcpViolation([McpServer("t", McpTransport.stdio, "c", null, "", "", [], [SecretRef("a", "k1"), SecretRef("A", "k2")])], "claude"),
		mcpViolation([http("one", "shared-auth", null), http("two", "shared-auth", null)], "claude"),
		mcpViolation([http("Tools", "", [McpHeader("X-Key", "k1")]), http("tools", "", [McpHeader("X-Key", "k1")])], "claude"),
	];
	violations.should.equal([
		`resources.mcp_servers "a" "B-C" lands on env var MCP_A_B_C, which another credential already uses; rename the server, header or env`,
		`resources.mcp_servers "tools" "X-Key" lands on env var MCP_TOOLS_X_KEY, which another credential already uses; rename the server, header or env`,
		`resources.mcp_servers "two" "Authorization" lands on env var X_Y, which another credential already uses; rename the server, header or env`,
		`resources.mcp_servers "t" "A" lands on env var MCP_T_A, which another credential already uses; rename the server, header or env`,
		"",
		"",
	]);
}
