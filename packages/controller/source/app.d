module app;

import core.time : seconds;
import std.conv : to;
import std.process : environment;

import vibe.core.core : runEventLoop, runTask;
import vibe.core.log : logInfo;

import httpkube : HttpKubeClient;
import health : startHealthServer;
import incluster : loadClusterConfig;
import leaderelection : Leadership, runLeaderElection;
import readiness : Readiness;
import watchpoll : ControlSettings, runControlLoop;

import agentcore.batch.translate : batchProvidersOver;
import agentcore.reconcile.reconcile_driver : BatchConfig;

import batchhttp : batchTransport, sinkPoster;

version (unittest)
{
	// `dub test` builds this executable with -unittest; the module unittests run
	// automatically and this empty main lets the test binary exit afterwards
	// instead of starting the reconcile loop.
	void main()
	{
	}
}
else
{
	int main()
	{
		const healthPort = environment.get("HEALTH_PORT", "8081").to!ushort;
		const agentImage = environment.get("AGENT_IMAGE", "ghcr.io/re-cinq/ai-agent:latest");

		auto config = loadClusterConfig();
		auto client = new HttpKubeClient(config);
		auto leadership = new Leadership();
		auto readiness = new Readiness();
		auto settings = ControlSettings(agentImage,
			BatchConfig(config.batchEnabled ? batchProvidersOver((request) => batchTransport(request)) : null,
				config.maxOutputBytes, sinkPoster()),
			config.batchPollSeconds.seconds);

		logInfo("ai-agent-controller: namespace=%s identity=%s health=:%s agentImage=%s",
			config.namespace, config.identity, healthPort, agentImage);

		startHealthServer(healthPort, readiness);
		runTask(() nothrow {
			runLeaderElection(client, config.namespace, config.identity, leadership, readiness);
		});
		runTask(() nothrow {
			runControlLoop(client, config.namespace, settings, leadership, readiness);
		});
		return runEventLoop();
	}
}
