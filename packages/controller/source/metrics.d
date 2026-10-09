module metrics;

import std.array : Appender, appender;
import std.exception : assumeWontThrow;
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
	histogram,
}

/// Cumulative bucket counts under fixed upper bounds, with the sum and count
/// Prometheus expects beside them.
private struct HistogramState
{
	const(double)[] bounds;
	double[] counts;
	double sum = 0;
	double count = 0;
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
private HistogramState[string] histograms;

/// Upper bounds that double from `first`: a minute to about two hours for a run,
/// a second to about eight minutes for the wait before one.
private double[] doublingBounds(double first, size_t steps) pure nothrow
{
	auto bounds = new double[steps];
	foreach (step, ref bound; bounds)
		bound = first * (1 << step);
	return bounds;
}

private immutable double[] runDurationBounds = doublingBounds(60, 8);
private immutable double[] runQueueBounds = doublingBounds(1, 10);

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

/// Count a full namespace resync (a paginated LIST) — done at startup, on a 410
/// Gone, and on the slow periodic resync interval.
void recordResync() nothrow
{
	addCounter("controller_resyncs_total", "Full namespace resyncs (paginated LIST).", "");
}

/// Count a run that reached a terminal phase, by phase and exit code.
void recordRunCompleted(string phase, int exitCode) nothrow
{
	addCounter("controller_runs_completed_total", "Runs that reached a terminal phase, by phase and exit code.",
		`phase="` ~ phase ~ `",exit_code="` ~ exitCodeText(exitCode) ~ `"`);
}

/// Record how long a run ran from `startedAt` to the terminal patch. Only a run
/// that started has a duration: one failed for a missing reference never ran.
void recordRunDuration(string phase, double durationSeconds) nothrow
{
	observeBucketed("controller_run_duration_seconds", "Seconds a run took from its start to its terminal phase, by phase.",
		`phase="` ~ phase ~ `"`, runDurationBounds, durationSeconds);
}

/// Count a run that ended with a reason, by its kind: a missing reference, a failed
/// Job, a success whose output could not be recovered, or a preemption under the
/// Replace policy (the one ending with no terminal status of its own). The reason
/// text itself stays in the Agent's status; as a label it would be one series per message.
void recordRunFailure(string kind) nothrow
{
	addCounter("controller_run_failures_total", "Runs that ended with a failure reason, by kind.",
		`kind="` ~ kind ~ `"`);
}

/// Record how long a run waited from its creation to its Job being created.
void recordRunQueued(double waitSeconds) nothrow
{
	observeBucketed("controller_run_queue_seconds", "Seconds a run waited from creation to its start.", "",
		runQueueBounds, waitSeconds);
}

// `format` is not nothrow by type, though formatting an int cannot fail.
private string exitCodeText(int exitCode) nothrow
{
	return assumeWontThrow(format("%d", exitCode));
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

private void observeBucketed(string name, string help, string labels, immutable double[] bounds, double value) nothrow
{
	try
	{
		declared[name] = Declared(Kind.histogram, help);
		const key = seriesKey(name, labels);
		auto state = key in histograms;
		if (state is null)
		{
			histograms[key] = HistogramState(bounds, new double[bounds.length]);
			state = key in histograms;
			state.counts[] = 0;
		}
		foreach (i, bound; state.bounds)
			if (value <= bound)
				state.counts[i] += 1;
		state.sum += value;
		state.count += 1;
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
		case Kind.histogram:
			emitHistograms(sink, name);
			break;
		}
	}
	return sink.data;
}

/// Prometheus's histogram shape: a cumulative `_bucket` per bound and `+Inf`, then `_sum` and `_count`.
private void emitHistograms(ref Appender!string sink, string name)
{
	foreach (key, state; histograms)
	{
		if (keyName(key) != name)
			continue;
		const labels = keyLabels(key);
		foreach (i, bound; state.bounds)
			sink ~= name ~ "_bucket{" ~ withBound(labels, format("%g", bound)) ~ "} " ~ format("%g", state.counts[i]) ~ "\n";
		sink ~= name ~ "_bucket{" ~ withBound(labels, "+Inf") ~ "} " ~ format("%g", state.count) ~ "\n";
		sink ~= (labels.length ? name ~ "_sum{" ~ labels ~ "} " : name ~ "_sum ") ~ format("%g", state.sum) ~ "\n";
		sink ~= (labels.length ? name ~ "_count{" ~ labels ~ "} " : name ~ "_count ") ~ format("%g", state.count) ~ "\n";
	}
}

private string withBound(string labels, string bound)
{
	return (labels.length ? labels ~ "," : "") ~ `le="` ~ bound ~ `"`;
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
	case Kind.histogram:
		return "histogram";
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
		histograms = null;
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

unittest
{
	resetMetrics();

	recordRunCompleted("Succeeded", 0);
	recordRunDuration("Succeeded", 90);
	recordRunCompleted("Succeeded", 0);
	recordRunDuration("Succeeded", 500);
	recordRunCompleted("Failed", 137);
	recordRunDuration("Failed", 30);
	recordRunFailure("job_failed");
	recordRunQueued(3);

	const text = renderMetrics();

	text.should.contain(`controller_runs_completed_total{phase="Succeeded",exit_code="0"} 2`);
	text.should.contain(`controller_runs_completed_total{phase="Failed",exit_code="137"} 1`);
	text.should.contain("# TYPE controller_run_duration_seconds histogram");
	text.should.contain(`controller_run_duration_seconds_bucket{phase="Succeeded",le="60"} 0`);
	text.should.contain(`controller_run_duration_seconds_bucket{phase="Succeeded",le="120"} 1`);
	text.should.contain(`controller_run_duration_seconds_bucket{phase="Succeeded",le="+Inf"} 2`);
	text.should.contain(`controller_run_duration_seconds_sum{phase="Succeeded"} 590`);
	text.should.contain(`controller_run_duration_seconds_count{phase="Succeeded"} 2`);
	text.should.contain(`controller_run_failures_total{kind="job_failed"} 1`);
	text.should.contain(`controller_run_queue_seconds_bucket{le="4"} 1`);
	text.should.contain("controller_run_queue_seconds_count 1");
}
