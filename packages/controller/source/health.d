module health;

import vibe.http.server : HTTPServerRequest, HTTPServerResponse, HTTPServerSettings, listenHTTP;

/// Start the `/healthz` endpoint the controller's liveness/readiness probes hit
/// (see deploy/controller.yaml). It runs on vibe's event loop alongside the
/// reconcile loop.
void startHealthServer(ushort port)
{
	auto settings = new HTTPServerSettings;
	settings.port = port;
	listenHTTP(settings, &handleHealth);
}

private void handleHealth(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
	if (req.requestPath.toString() == "/healthz")
		res.writeBody("ok", "text/plain");
}
