module health;

import vibe.http.server : HTTPServerRequest, HTTPServerResponse, HTTPServerSettings, listenHTTP;

import metrics : renderMetrics;
import readiness : Readiness;

version (unittest) import fluent.asserts;

/// The HTTP status and body for a probe path.
struct HealthReply
{
	int status;
	string text;
}

/// Route a probe path to its reply. `/healthz` is **liveness** — the process is up,
/// so it is always 200 (the kubelet restarts only a hung/dead process). `/readyz` is
/// **readiness** — 200 only once the controller has reached the API server, else 503
/// so a rollout waits for a working replica instead of cutting over to a wedged one.
/// Any other path is 404 (it used to fall through to a silent empty 200).
HealthReply healthResponse(string path, bool ready)
{
	switch (path)
	{
	case "/healthz":
		return HealthReply(200, "ok");
	case "/readyz":
		return ready ? HealthReply(200, "ok") : HealthReply(503, "not ready");
	default:
		return HealthReply(404, "not found");
	}
}

unittest
{
	// Liveness is always ok while the process runs.
	healthResponse("/healthz", false).should.equal(HealthReply(200, "ok"));
	healthResponse("/healthz", true).should.equal(HealthReply(200, "ok"));
	// Readiness tracks API reachability.
	healthResponse("/readyz", true).should.equal(HealthReply(200, "ok"));
	healthResponse("/readyz", false).should.equal(HealthReply(503, "not ready"));
	// Unknown paths are 404, not a silent empty 200.
	healthResponse("/", true).should.equal(HealthReply(404, "not found"));
	healthResponse("/nope", true).should.equal(HealthReply(404, "not found"));
}

/// Start the controller's HTTP server: `/healthz` (liveness), `/readyz` (readiness,
/// backed by `readiness`), and `/metrics` for Prometheus scraping (see
/// deploy/controller.yaml). Runs on vibe's event loop alongside the reconcile loop.
void startHealthServer(ushort port, Readiness readiness)
{
	auto settings = new HTTPServerSettings;
	settings.port = port;
	listenHTTP(settings, (scope HTTPServerRequest req, scope HTTPServerResponse res) {
		handleHealth(req, res, readiness);
	});
}

private void handleHealth(scope HTTPServerRequest req, scope HTTPServerResponse res, Readiness readiness)
{
	const path = req.requestPath.toString();
	if (path == "/metrics")
	{
		res.writeBody(renderMetrics(), "text/plain; version=0.0.4; charset=utf-8");
		return;
	}
	const reply = healthResponse(path, readiness.ready);
	res.statusCode = reply.status;
	res.writeBody(reply.text, "text/plain");
}
