module incluster;

import std.process : environment;

/// Connection parameters for the in-cluster Kubernetes API server, assembled from
/// the service-account files and the well-known env vars Kubernetes injects into
/// every Pod.
struct ClusterConfig
{
	string apiBase; /// e.g. "https://10.0.0.1:443"
	string token; /// service-account bearer token
	string caFile; /// path to the CA bundle the API server's cert is signed by
	string namespace; /// the Pod's own namespace
}

enum tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token";
enum caPath = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt";
enum namespacePath = "/var/run/secrets/kubernetes.io/serviceaccount/namespace";

/// The API server base URL from the host/port Kubernetes injects.
string apiBase(string host, string port) @safe pure
{
	return "https://" ~ host ~ ":" ~ port;
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
	config.apiBase = apiBase(host, port);
	config.token = exists(tokenPath) ? readText(tokenPath).strip : "";
	config.caFile = caPath;
	config.namespace = exists(namespacePath) ? readText(namespacePath)
		.strip : environment.get("NAMESPACE", "ai-agents");
	return config;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	apiBase("10.0.0.1", "443").should.equal("https://10.0.0.1:443");
}
