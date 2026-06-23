module health;

import vibe.http.server : HTTPServerRequest, HTTPServerResponse, HTTPServerSettings, listenHTTP;

import metrics : renderMetrics;

/// Start the controller's HTTP server: `/healthz` for the liveness/readiness
/// probes and `/metrics` for Prometheus scraping (see deploy/controller.yaml). It
/// runs on vibe's event loop alongside the reconcile loop.
void startHealthServer(ushort port)
{
	auto settings = new HTTPServerSettings;
	settings.port = port;
	listenHTTP(settings, &handleHealth);
}

private void handleHealth(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
	const path = req.requestPath.toString();
	if (path == "/healthz")
		res.writeBody("ok", "text/plain");
	else if (path == "/metrics")
		res.writeBody(renderMetrics(), "text/plain; version=0.0.4; charset=utf-8");
}
