module notify;

import std.process : environment, execute;
import std.stdio : File, stdout;

import agentcore.crds.enums : SinkType;
import agentcore.env : envAgentName, envNotifyUrl, envPodName, envPodNamespace,
	envSinks, envStationName, envTaskId;
import agentcore.event : EventSource, wrapEvent;
import agentcore.log : logError;
import agentcore.output : SinkSpec, parseSinks;

/// The run's configured sinks: the recipe's `AGENT_SINKS`, plus a single http sink
/// from the `LORE_NOTIFY_URL` shorthand when set — the same set the supervisor
/// delivers to, so init events land on the same channel as the agent's.
SinkSpec[] sinksFromEnv()
{
	auto sinks = parseSinks(environment.get(envSinks, ""));
	const url = environment.get(envNotifyUrl, "");
	if (url.length)
		sinks ~= SinkSpec(SinkType.http, url);
	return sinks;
}

/// The run identity the controller injects, stamped onto every init event so it
/// correlates with the agent's events downstream.
EventSource sourceFromEnv()
{
	EventSource s;
	s.agent = environment.get(envAgentName, "");
	s.station = environment.get(envStationName, "");
	s.task = environment.get(envTaskId, "");
	s.pod = environment.get(envPodName, "");
	s.namespace_ = environment.get(envPodNamespace, "");
	return s;
}

/// Wrap `payload` in the run's event envelope and fan it out: always to stdout
/// (pod logs → status.output), plus every configured http/file sink. Fire-and-
/// forget — a failing sink is logged, never fatal (mirrors the supervisor's sink
/// semantics).
void notify(const SinkSpec[] sinks, in EventSource src, string payload) nothrow
{
	const line = wrapEvent(src, payload);
	try
	{
		stdout.writeln(line);
		stdout.flush();
	}
	catch (Exception)
	{
	}

	foreach (s; sinks)
	{
		final switch (s.type)
		{
		case SinkType.http:
			postHttp(s.url, line);
			break;
		case SinkType.file:
			appendFile(s.path, line);
			break;
		case SinkType.stdout:
			break;
		}
	}
}

/// POST `line` to an http sink with the `curl` CLI — already a guaranteed
/// prerequisite, so no HTTP library or event loop is needed. `execute` captures
/// curl's output instead of leaking the response body into the pod logs.
private void postHttp(string url, string line) nothrow
{
	try
	{
		const r = execute([
			"curl", "-fsS", "-X", "POST",
			"-H", "Content-Type: application/json",
			"-d", line, url
		]);
		if (r.status != 0)
			logError("[init] http sink failed: curl exited " ~ itoa(r.status));
	}
	catch (Exception e)
		logError("[init] http sink failed: " ~ e.msg);
}

/// Append `line` (with a trailing newline) to a file sink.
private void appendFile(string path, string line) nothrow
{
	try
	{
		auto file = File(path, "a");
		scope (exit)
			file.close();
		file.writeln(line);
	}
	catch (Exception e)
		logError("[init] file sink failed: " ~ e.msg);
}

private string itoa(int n) nothrow
{
	try
	{
		import std.conv : to;

		return n.to!string;
	}
	catch (Exception)
		return "?";
}
