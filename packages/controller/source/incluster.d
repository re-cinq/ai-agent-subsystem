module incluster;

import std.algorithm.searching : all;
import std.ascii : isDigit;
import std.conv : to;
import std.exception : enforce;
import std.process : environment;

import agentcore.core.env : envMaxOutputBytes, defaultMaxOutputBytes;

/// Connection parameters for the in-cluster Kubernetes API server, assembled from
/// the service-account files and the well-known env vars Kubernetes injects into
/// every Pod.
struct ClusterConfig
{
	string apiBase; /// e.g. "https://10.0.0.1:443"
	string token; /// service-account bearer token (the initial / out-of-cluster value)
	string tokenPath; /// file to re-read the token from (rotated in place); "" out of cluster
	string caFile; /// path to the CA bundle the API server's cert is signed by
	string namespace; /// the Pod's own namespace
	size_t maxOutputBytes = defaultMaxOutputBytes; /// tail of a run pod's log kept in status.output
	string identity; /// this replica's leader-election identity (its Pod name)
	size_t batchPollSeconds = defaultBatchPollSeconds; /// how often an in-flight batch is polled
	bool batchEnabled; /// whether the controller submits batch-execution Agents (opt-in)
	bool modelCatalogEnabled; /// whether the controller publishes the ModelCatalog (opt-in)
	size_t modelCatalogRefreshSeconds = defaultModelCatalogRefreshSeconds; /// how often the ModelCatalog is refreshed
	string realtimeApiToken; /// the bearer prompt API callers present
	string realtimeSigningKey; /// the key realtime run tokens are derived from
	ushort realtimeApiPort = defaultRealtimeApiPort; /// where the prompt API listens

	/// Realtime execution runs only with both secrets set (the realtime component).
	bool realtimeEnabled() const @safe pure nothrow
	{
		return realtimeApiToken.length > 0 && realtimeSigningKey.length > 0;
	}
}

/// Env settings for realtime execution: the prompt API's caller bearer, the key run tokens
/// are derived from, and the prompt API's port, with its default.
enum envRealtimeApiToken = "REALTIME_API_TOKEN";
/// ditto
enum envRealtimeSigningKey = "REALTIME_SIGNING_KEY";
/// ditto
enum envRealtimeApiPort = "REALTIME_API_PORT";
/// ditto
enum ushort defaultRealtimeApiPort = 8082;

/// Env setting that opts the controller into publishing the ModelCatalog; off unless set to "true".
enum envModelCatalogEnabled = "MODEL_CATALOG_ENABLED";

/// Env setting for how often the ModelCatalog is refreshed, and its default.
enum envModelCatalogRefreshSeconds = "MODEL_CATALOG_REFRESH_SECONDS";
/// ditto
enum size_t defaultModelCatalogRefreshSeconds = 3600;

/// Env setting that opts the controller into batch execution; off unless set to "true".
enum envBatchEnabled = "BATCH_ENABLED";

/// Env setting for how often an in-flight batch Agent's batch is polled, and its default.
enum envBatchPollSeconds = "BATCH_POLL_SECONDS";
/// ditto
enum size_t defaultBatchPollSeconds = 60;

enum tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token";
enum caPath = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt";
enum namespacePath = "/var/run/secrets/kubernetes.io/serviceaccount/namespace";

/// The API server base URL from the host/port Kubernetes injects.
string apiBase(string host, string port) @safe pure
{
	return "https://" ~ host ~ ":" ~ port;
}

/// The effective API base: an explicit `KUBE_API_URL` override (used to run the
/// controller out-of-cluster against a `kubectl proxy`) wins; otherwise the
/// in-cluster host/port. Lets the same binary run locally for integration tests.
string resolveApiBase(string overrideUrl, string host, string port) @safe pure
{
	return overrideUrl.length ? overrideUrl : apiBase(host, port);
}

/// Load the in-cluster config from the service-account files + env. Falls back to
/// the `NAMESPACE` env var when the namespace file is absent (e.g. out of cluster).
ClusterConfig loadClusterConfig()
{
	import std.file : exists, readText;
	import std.string : strip;

	const host = environment.get("KUBERNETES_SERVICE_HOST", "");
	const port = environment.get("KUBERNETES_SERVICE_PORT", "443");

	ClusterConfig config;
	config.apiBase = resolveApiBase(environment.get("KUBE_API_URL", ""), host, port);
	config.token = exists(tokenPath) ? readText(tokenPath).strip : environment.get("KUBE_API_TOKEN", "");
	config.tokenPath = exists(tokenPath) ? tokenPath : "";
	config.caFile = caPath;
	config.namespace = exists(namespacePath) ? readText(namespacePath)
		.strip : environment.get("NAMESPACE", "ai-agents");
	config.maxOutputBytes = parseMaxOutputBytes(
		environment.get(envMaxOutputBytes, defaultMaxOutputBytes.to!string));
	config.batchPollSeconds = parseCount(envBatchPollSeconds,
		environment.get(envBatchPollSeconds, defaultBatchPollSeconds.to!string));
	config.batchEnabled = parseFlag(envBatchEnabled, environment.get(envBatchEnabled, "false"));
	config.modelCatalogEnabled = parseFlag(envModelCatalogEnabled, environment.get(envModelCatalogEnabled, "false"));
	config.modelCatalogRefreshSeconds = parseCount(envModelCatalogRefreshSeconds,
		environment.get(envModelCatalogRefreshSeconds, defaultModelCatalogRefreshSeconds.to!string));
	config.identity = environment.get("POD_NAME", environment.get("HOSTNAME", "agent-controller"));
	config.realtimeApiToken = environment.get(envRealtimeApiToken, "");
	config.realtimeSigningKey = environment.get(envRealtimeSigningKey, "");
	config.realtimeApiPort = parseCount(envRealtimeApiPort,
		environment.get(envRealtimeApiPort, defaultRealtimeApiPort.to!string)).to!ushort;
	return config;
}

/// Parse the `MAX_OUTPUT_BYTES` env value into a byte count.
size_t parseMaxOutputBytes(string raw) @safe pure
{
	return parseCount(envMaxOutputBytes, raw);
}

/// Parse the env value of `setting` as a count. Rejects anything that isn't a plain
/// non-negative integer with a message naming the setting, so a typo fails fast at
/// startup with a clear reason rather than a bare `ConvException`.
size_t parseCount(string setting, string raw) @safe pure
{
	enforce(raw.length && raw.all!isDigit,
		setting ~ " must be a non-negative integer, got: \"" ~ raw ~ "\"");
	return raw.to!size_t;
}

/// Parse the env value of `setting` as a boolean, accepting only "true" or "false" so a typo
/// fails fast at startup instead of silently leaving the setting off.
bool parseFlag(string setting, string raw) @safe pure
{
	enforce(raw == "true" || raw == "false",
		setting ~ ` must be "true" or "false", got: "` ~ raw ~ `"`);
	return raw == "true";
}

version (unittest) import fluent.asserts;

@safe unittest
{
	apiBase("10.0.0.1", "443").should.equal("https://10.0.0.1:443");
}

@safe unittest
{
	// No override -> in-cluster host/port; an override URL wins (out-of-cluster).
	resolveApiBase("", "10.0.0.1", "443").should.equal("https://10.0.0.1:443");
	resolveApiBase("http://127.0.0.1:8001", "10.0.0.1", "443").should.equal("http://127.0.0.1:8001");
}

@safe unittest
{
	// A plain integer parses to its byte count.
	parseMaxOutputBytes("262144").should.equal(size_t(262_144));
}

unittest
{
	// A non-numeric value fails fast with a message naming the setting.
	({ parseMaxOutputBytes("256k"); }).should.throwException!Exception
		.withMessage.equal(`MAX_OUTPUT_BYTES must be a non-negative integer, got: "256k"`);
}

unittest // BATCH_POLL_SECONDS "1m" fails naming the setting, "30" parses to 30
{
	({ parseCount(envBatchPollSeconds, "1m"); }).should.throwException!Exception
		.withMessage.equal(`BATCH_POLL_SECONDS must be a non-negative integer, got: "1m"`);
	parseCount(envBatchPollSeconds, "30").should.equal(size_t(30));
}

unittest // BATCH_ENABLED "true" parses true, "false" false, "yes" fails naming the setting
{
	[parseFlag(envBatchEnabled, "true"), parseFlag(envBatchEnabled, "false")].should.equal([true, false]);
	({ parseFlag(envBatchEnabled, "yes"); }).should.throwException!Exception
		.withMessage.equal(`BATCH_ENABLED must be "true" or "false", got: "yes"`);
}

unittest // realtime is enabled only with both the API token and the signing key
{
	ClusterConfig config;
	const neither = config.realtimeEnabled;
	config.realtimeApiToken = "api";
	const tokenOnly = config.realtimeEnabled;
	config.realtimeSigningKey = "key";

	[neither, tokenOnly, config.realtimeEnabled].should.equal([false, false, true]);
}
