module metrics;

import std.array : Appender, appender;
import std.format : format;

/// In-process Prometheus metrics for the controller, rendered as text exposition
/// (format 0.0.4) by `renderMetrics`. State is plain thread-local module data:
/// every writer (the reconcile, watch, poll and election fibers) and the reader
/// (the `/metrics` HTTP handler) run on vibe's single event-loop thread, so no
/// locking is needed — the same race-free assumption leaderelection.d documents.
/// The `record*` helpers are `nothrow` so the `nothrow` reconcile loops can call
/// them; a dropped sample under allocation pressure is acceptable.

private enum Kind
{
	counter,
	gauge,
	summary,
}

private struct Declared
{
	Kind kind;
	string help;
}

/// Joins a metric name and its label text into one registry key. NUL never occurs
/// in either part, so it splits back unambiguously when rendering.
private enum char nameLabelSep = '\0';

private Declared[string] declared;
private double[string] counterValues;
private double[string] gaugeValues;
private double[string] summarySum;
private double[string] summaryCount;

/// Count a reconcile attempt by result ("success" or "error") and record its
/// wall-clock duration. Together these give reconcile rate, error rate and latency.
void recordReconcile(string result, double seconds) nothrow
{
	addCounter("controller_reconciles_total", "Reconcile attempts, by result.",
		`result="` ~ result ~ `"`);
	observe("controller_reconcile_duration_seconds", "Reconcile wall-clock duration in seconds.", "",
		seconds);
}

/// Count a Job the controller created (a Kubernetes 201, not an idempotent 409).
void recordJobCreated() nothrow
{
	addCounter("controller_jobs_created_total", "Jobs the controller created.", "");
}

/// Count an Agent status subresource patch the controller applied.
void recordStatusPatch() nothrow
{
	addCounter("controller_status_patches_total", "Agent status subresource patches applied.", "");
}

/// Count a re-establishment of the Agent watch stream (every connect after the first).
void recordWatchReconnect() nothrow
{
	addCounter("controller_watch_reconnects_total", "Agent watch stream reconnects.", "");
}

/// Set the number of Agents currently observed in a given phase.
void recordAgentsByPhase(string phase, double count) nothrow
{
	setGauge("controller_agents", "Agents observed at the last poll, by phase.",
		`phase="` ~ phase ~ `"`, count);
}

/// Record the duration of one Kubernetes API request, labelled by HTTP verb.
void recordApiCall(string verb, double seconds) nothrow
{
	observe("controller_apiserver_request_duration_seconds",
		"Kubernetes API request duration in seconds, by verb.", `verb="` ~ verb ~ `"`, seconds);
}

/// Set whether this replica currently holds the leader Lease (1) or stands by (0).
void recordLeadership(bool isLeader) nothrow
{
	setGauge("controller_is_leader", "1 when this replica holds the leader Lease, else 0.", "",
		isLeader ? 1 : 0);
}

private void addCounter(string name, string help, string labels) nothrow
{
	try
	{
		declared[name] = Declared(Kind.counter, help);
		counterValues[seriesKey(name, labels)] += 1;
	}
	catch (Exception)
	{
	}
}

private void setGauge(string name, string help, string labels, double value) nothrow
{
	try
	{
		declared[name] = Declared(Kind.gauge, help);
		gaugeValues[seriesKey(name, labels)] = value;
	}
	catch (Exception)
	{
	}
}

private void observe(string name, string help, string labels, double seconds) nothrow
{
	try
	{
		declared[name] = Declared(Kind.summary, help);
		const key = seriesKey(name, labels);
		summarySum[key] += seconds;
		summaryCount[key] += 1;
	}
	catch (Exception)
	{
	}
}

/// Render the whole registry in Prometheus text exposition format.
string renderMetrics()
{
	auto sink = appender!string;
	foreach (name, decl; declared)
	{
		sink ~= "# HELP " ~ name ~ " " ~ decl.help ~ "\n";
		sink ~= "# TYPE " ~ name ~ " " ~ kindText(decl.kind) ~ "\n";
		final switch (decl.kind)
		{
		case Kind.counter:
			emitSeries(sink, name, name, counterValues);
			break;
		case Kind.gauge:
			emitSeries(sink, name, name, gaugeValues);
			break;
		case Kind.summary:
			emitSeries(sink, name, name ~ "_sum", summarySum);
			emitSeries(sink, name, name ~ "_count", summaryCount);
			break;
		}
	}
	return sink.data;
}

private void emitSeries(ref Appender!string sink, string name, string seriesName, double[string] values)
{
	foreach (key, value; values)
	{
		if (keyName(key) != name)
			continue;
		const labels = keyLabels(key);
		sink ~= labels.length ? seriesName ~ "{" ~ labels ~ "} " : seriesName ~ " ";
		sink ~= format("%g", value);
		sink ~= "\n";
	}
}

private string seriesKey(string name, string labels)
{
	return name ~ nameLabelSep ~ labels;
}

private string keyName(string key)
{
	foreach (i, c; key)
		if (c == nameLabelSep)
			return key[0 .. i];
	return key;
}

private string keyLabels(string key)
{
	foreach (i, c; key)
		if (c == nameLabelSep)
			return key[i + 1 .. $];
	return "";
}

private string kindText(Kind kind)
{
	final switch (kind)
	{
	case Kind.counter:
		return "counter";
	case Kind.gauge:
		return "gauge";
	case Kind.summary:
		return "summary";
	}
}

version (unittest)
{
	/// Clear the registry so each unittest renders only what it recorded.
	void resetMetrics() nothrow
	{
		declared = null;
		counterValues = null;
		gaugeValues = null;
		summarySum = null;
		summaryCount = null;
	}
}

version (unittest) import fluent.asserts;

unittest
{
	resetMetrics();

	recordJobCreated();
	recordJobCreated();
	recordReconcile("error", 0.01);
	recordAgentsByPhase("Running", 3);
	recordApiCall("GET", 0.02);

	const text = renderMetrics();

	text.should.contain("# TYPE controller_jobs_created_total counter");
	text.should.contain("controller_jobs_created_total 2");
	text.should.contain(`controller_reconciles_total{result="error"} 1`);
	text.should.contain(`controller_agents{phase="Running"} 3`);
	text.should.contain("# TYPE controller_apiserver_request_duration_seconds summary");
	text.should.contain(`controller_apiserver_request_duration_seconds_count{verb="GET"} 1`);
	text.should.contain(`controller_apiserver_request_duration_seconds_sum{verb="GET"} 0.02`);
}
