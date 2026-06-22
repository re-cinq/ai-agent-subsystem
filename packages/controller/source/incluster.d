module incluster;

import std.conv : to;
import std.process : environment;

import agentcore.core.env : envMaxOutputBytes, defaultMaxOutputBytes;

/// Connection parameters for the in-cluster Kubernetes API server, assembled from
/// the service-account files and the well-known env vars Kubernetes injects into
/// every Pod.
struct ClusterConfig
{
	string apiBase; /// e.g. "https://10.0.0.1:443"
	string token; /// service-account bearer token
	string caFile; /// path to the CA bundle the API server's cert is signed by
	string namespace; /// the Pod's own namespace
	size_t maxOutputBytes = defaultMaxOutputBytes; /// tail of a run pod's log kept in status.output
}

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
	config.caFile = caPath;
	config.namespace = exists(namespacePath) ? readText(namespacePath)
		.strip : environment.get("NAMESPACE", "ai-agents");
	config.maxOutputBytes = environment.get(envMaxOutputBytes, defaultMaxOutputBytes.to!string)
		.to!size_t;
	return config;
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
