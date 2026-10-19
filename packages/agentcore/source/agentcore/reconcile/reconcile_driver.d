module agentcore.reconcile.reconcile_driver;

import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.mcp_server : mcpViolation;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec, batchViolation, realtimeViolation;
import agentcore.crds.station : Station;
import agentcore.reconcile.concurrency : effectiveMaxRuns, oldestRunningRun, stationAtCapacity;
import agentcore.kube.jobs : jobNameFor;
import agentcore.kube.jobspec : buildJob, runRecipe, templateViolation;
import agentcore.batch.provider : batchCleanupFinalizer, batchSettleMinutes, maxBatchCleanupAttempts, BatchNotSettled,
	BatchPoll, BatchProvider, BatchProviderFor, BatchRequest, BatchState, batchModel, batchVendor;
import agentcore.batch.translate : batchCliEvents;
import agentcore.core.env : defaultMaxOutputBytes;
import agentcore.core.log : logError;
import agentcore.core.token : runToken;
import agentcore.kube.outputcap : capOutput;
import agentcore.output.session : lastSessionId;
import agentcore.delivery.outbox : DeliveryStatus, lastDelivery;
import agentcore.delivery.plan : deliveryViolation;
import std.array : join;
import agentcore.core.prompt : renderPrompt;
import agentcore.core.vendor : vendorOf;
import agentcore.crds.enums : BatchTimeoutAction, Execution;
import agentcore.crds.secret_ref : SecretRef;
import agentcore.kube.jobspec : agentSecretName;
import agentcore.kube.jsonbody : batchCleanupAttemptsPatch, addFinalizerPatch, batchSubmittedPatch, removeFinalizerPatch, statusPatch;
import agentcore.kube.kubeclient : KubeClient, NotFound, PodResult;
import agentcore.reconcile.prune : agentsToPrune;
import agentcore.reconcile.reconcile : ActionKind, BatchRun, batchPolled, batchTimedOut, cancelsBatch,
	coherentExitCode, decide, Decision, JobOutcome, JobState;
import agentcore.core.types : Phase;
import agentcore.vendors.select : agentForModel;
import agentcore.output.event : EventSource;
import agentcore.output.lifecycle : LifecycleEvent, LifecyclePhase = Phase, Status, toJson;
import agentcore.output.output : deliverEvent, HttpSink;
import agentcore.output.selectmatcher : selected;
import std.algorithm.iteration : filter;
import std.conv : to;
import std.exception : enforce;
import vibe.data.json : Json;

/// Status reason when the run Job was garbage-collected before the controller could
/// observe its result — the controller was down or backlogged past the Job's
/// TTL-after-finished. The real outcome is unrecoverable, so the run is reported
/// terminal with this reason instead of being left Running forever.
enum runRecordUnavailable = "run record unavailable: Job garbage-collected before its result was observed";

/// Status reason when the Job's result was read but the run pod (and the stdout it
/// captured) was already garbage-collected, so `status.output` could not be
/// recovered. Surfaced instead of a silently empty output.
enum runOutputUnavailable = "run output unavailable: pod garbage-collected";

/// What a single reconcile did that the batch pass (`reconcileAll`) must account for
/// before reconciling the next Agent: whether a new run for this Agent's Station is now
/// in flight, and any run this action preempted. The cache won't reflect either until
/// the status patch round-trips through the informer, so the batch applies them to its
/// working view to keep the Station concurrency count correct within one pass.
struct ReconcileEffect
{
	bool startedRun;
	string preemptedAgent;
	/// What was decided, so the caller can observe a start or a terminal transition
	/// (and time it) without re-deriving the state machine.
	Decision decision;
	/// Whether deleting the batch's provider-side objects failed in this reconcile.
	bool batchCleanupFailed;
}

/**
 * Reconcile one Agent: resolve its refs, decide the next action with the pure
 * `decide()` state machine, then apply the decision through the injected client.
 * `agentImage` is the image whose init container injects the runtime into the
 * run Pod; `now` is the RFC3339 timestamp stamped onto the status (injected so
 * the driver is deterministic and fake-testable). Terminal Agents are a no-op
 * with no I/O. `cached` is the controller's informer view of the namespace's
 * Agents — used for the Station concurrency count and history pruning instead of
 * a fresh LIST per reconcile, so cost stays O(changed) rather than O(all). Returns
 * the `ReconcileEffect` so a batch pass can keep its concurrency count honest.
 */
ReconcileEffect reconcileAgent(KubeClient client, string ns, Agent agent, string agentImage, string now,
	const Agent[] cached, BatchConfig batchConfig = BatchConfig.init,
	RealtimeConfig realtimeConfig = RealtimeConfig.init)
{
	const phase = agent.status.phase;
	auto run = AgentReconcile(client, ns, agent, Station.init, AgentDefinition.init, agentImage, now,
		cached, batchConfig, agent.status.jobName, realtimeConfig);
	if (batchCleanupDue(agent))
	{
		resolveRefs(client, ns, agent, run.station, run.definition);
		ReconcileEffect released;
		released.batchCleanupFailed = run.releaseBatch();
		return released;
	}
	if (phase == Phase.succeeded || phase == Phase.failed)
		return ReconcileEffect.init;

	const batchInFlight = agent.status.batchId.length > 0;
	const batchPending = batchInFlight && !agent.status.batchFallback;
	const awaitingFallbackJob = agent.status.batchFallback && agent.status.jobName.length == 0;
	const needsRefs = phase == Phase.pending || batchPending || awaitingFallbackJob;
	const refsResolved = !needsRefs || resolveRefs(client, ns, agent, run.station, run.definition);
	const atCapacity = refsResolved && (phase == Phase.pending || awaitingFallbackJob) && run.stationFull;

	if (refsResolved && batchPending && batchConfig.providers is null)
		return run.failBatchDisabled();

	JobOutcome outcome;
	const observesJob = phase == Phase.running && !batchPending && !awaitingFallbackJob;
	if (observesJob)
	{
		// A Running Agent whose status never recorded its jobName (a controller crash
		// between the Running patch and the jobName write) would otherwise observe no
		// outcome and stay Running forever. The Job name is derived from the Agent name,
		// so fall back to it and let observeJob resolve the run or report it terminal.
		if (run.jobName.length == 0)
			run.jobName = jobNameFor(agent.metadata.name);
		outcome = observeJob(client, ns, run.jobName);
	}

	return run.apply(decide(phase, refsResolved, observesJob, outcome, atCapacity,
		run.station.spec.concurrencyPolicy,
		runViolation(agent, run.definition.spec, run.station.spec.template_, batchConfig.providers !is null,
			realtimeConfig.enabled),
		BatchRun(run.definition.spec.execution == Execution.batch, agent.status.batchId,
			agent.status.batchFallback, awaitingFallbackJob)));
}

/// How the controller runs realtime Agents: the key it derives each run's prompt token
/// from. Without one, realtime execution is disabled.
struct RealtimeConfig
{
	string signingKey;

	bool enabled() const @safe pure nothrow
	{
		return signingKey.length > 0;
	}
}

/// How the controller runs batch-executed Agents: the vendor providers it submits to, and
/// the `status.output` cap it applies to their results, as it does to a run pod's log.
struct BatchConfig
{
	BatchProviderFor providers;
	size_t maxOutputBytes = defaultMaxOutputBytes;
	/// Posts a batch run's events to its definition's http sinks; null delivers to no sink.
	HttpSink postSink;
}

/// One Agent's reconcile once its refs are resolved: applies a `Decision` through the
/// client. `jobName` is the Job the run uses (recovered from the Agent name when the
/// status lost it).
private struct AgentReconcile
{
	KubeClient client;
	string ns;
	Agent agent;
	Station station;
	AgentDefinition definition;
	string agentImage;
	string now;
	const(Agent)[] cached;
	BatchConfig batchConfig;
	string jobName;
	RealtimeConfig realtimeConfig;
	BatchProvider batchProvider;
	/// The finished batch's result as the vendor CLI's event lines, uncapped, for the sinks.
	string[] batchLines;

	ReconcileEffect apply(Decision decision)
	{
		final switch (decision.kind)
		{
		case ActionKind.none:
			return ReconcileEffect(false, "", decision);
		case ActionKind.pollBatch:
			auto polled = apply(pollBatch());
			emitBatchOutcome(polled.decision);
			if (polled.decision.kind != ActionKind.none)
				polled.batchCleanupFailed = cleanupBatch();
			return polled;
		case ActionKind.submitBatch:
			return submitBatch(decision);
		case ActionKind.replaceWithBatch:
			const preemptedForBatch = oldestRunningRun(cached, agent.spec.stationRef);
			client.deleteAgent(ns, preemptedForBatch, resourceVersionByName(cached, preemptedForBatch));
			return submitBatch(decision, preemptedForBatch);
		case ActionKind.startRun:
		case ActionKind.batchFallbackStart:
			return startJob(decision, "");
		case ActionKind.replaceRun:
			const preempted = oldestRunningRun(cached, agent.spec.stationRef);
			client.deleteAgent(ns, preempted, resourceVersionByName(cached, preempted));
			return startJob(decision, preempted);
		case ActionKind.failMissingRef:
			return fail(decision.failureReason);
		case ActionKind.batchFallbackWait:
			patch(statusPatch(decision, "", now, agent.metadata.resourceVersion));
			return ReconcileEffect(false, "", decision);
		case ActionKind.complete:
		case ActionKind.batchTimeoutFail:
			patch(statusPatch(decision, jobName, now, agent.metadata.resourceVersion));
			pruneHistory(client, ns, agent.spec.stationRef, cached);
			return ReconcileEffect(false, "", decision);
		}
	}

	/// Whether the Station's other runs already fill its concurrent-run limit.
	bool stationFull()
	{
		import std.algorithm.iteration : filter;
		import std.array : array;

		return stationAtCapacity(cached.filter!(a => a.metadata.name != agent.metadata.name).array,
			agent.spec.stationRef,
			effectiveMaxRuns(station.spec.concurrencyPolicy, station.spec.maxConcurrentRuns));
	}

	/// Create the run Job and record it. Only a Pending Agent's start adds a run to the
	/// Station; a batch Agent falling back to a Job already counts as Running.
	private ReconcileEffect startJob(Decision decision, string preempted)
	{
		const token = definition.spec.execution == Execution.realtime
			? runToken(realtimeConfig.signingKey, agent.metadata.uid) : "";
		client.createJob(ns, buildJob(agent, station, definition, agentImage, token));
		patch(statusPatch(decision, jobNameFor(agent.metadata.name), now, agent.metadata.resourceVersion));
		return ReconcileEffect(agent.status.phase == Phase.pending, preempted, decision);
	}

	/// Submit the Agent's rendered prompt to its vendor's batch API, authenticated with the
	/// key its definition maps from agent-secrets, and record the batch on the status. A
	/// definition with no secrets entry for the vendor's key fails the Agent instead.
	private ReconcileEffect submitBatch(Decision decision, string preempted = "")
	{
		const target = batchVendor(vendorOf(definition.spec.model));
		if (apiKeyRef.length == 0)
			return fail("batch execution needs a resources.secrets entry named " ~ target.apiKeyEnv);

		const batchId = provider.submit(BatchRequest(batchModel(definition.spec.model),
				renderPrompt(definition.spec.prompt, agent.spec.parameters), definition.spec.output.schema.clone,
				definition.spec.batch.maxTokens, agent.metadata.uid));
		patch(batchSubmittedPatch(batchId, target.provider, now, agent.metadata.resourceVersion));
		client.patchAgent(ns, agent.metadata.name, addFinalizerPatch(agent.metadata.finalizers, batchCleanupFinalizer));
		emitToSinks(LifecycleEvent(LifecyclePhase.agent, Status.started).toJson);
		return ReconcileEffect(true, preempted, decision);
	}

	/// Poll the Agent's batch and decide what its result, or its timeout, leads to. A
	/// finished batch carries the result translated to the vendor CLI's event lines; a
	/// timed-out one is cancelled before the Agent fails or falls back to a Job.
	/// The returned decision (in `ReconcileEffect.decision`) is where sink events such
	/// as `batch_timeout` attach.
	private Decision pollBatch()
	{
		const vendor = vendorOf(definition.spec.model);
		auto batch = provider;
		const poll = pollOrPending(batch, agent.status.batchId);
		batchLines = poll.state == BatchState.pending ? null : batchCliEvents(vendor, poll, agent.metadata.uid);
		const output = capOutput(batchLines.join("\n"), batchConfig.maxOutputBytes);
		const decision = batchPolled(poll, output,
			batchTimedOut(agent.status.startedAt, now, definition.spec.batch.timeoutMinutes),
			definition.spec.batch.onTimeout, stationFull);
		if (cancelsBatch(decision.kind))
			batch.cancel(agent.status.batchId);
		return decision;
	}

	/// Deliver what a batch poll that went somewhere means to the definition's sinks, after its
	/// status patch: a finished batch's CLI lines (through `output.select`) and the agent's
	/// terminal lifecycle event.
	private void emitBatchOutcome(Decision decision)
	{
		switch (decision.kind)
		{
		case ActionKind.complete:
			const provider = vendorOf(definition.spec.model).to!string;
			foreach (line; batchLines.filter!(line => selected(definition.spec.output.select, provider, line)))
				emitToSinks(line);
			emitToSinks(batchFinished(decision.phase == Phase.succeeded).toJson);
			break;
		case ActionKind.batchTimeoutFail:
			emitToSinks(batchTimeout(true).toJson);
			break;
		case ActionKind.batchFallbackStart:
		case ActionKind.batchFallbackWait:
			emitToSinks(batchTimeout(false).toJson);
			break;
		default:
			break;
		}
	}

	/// Send one event to the definition's sinks, wrapped with the Agent's run identity.
	private void emitToSinks(string payload)
	{
		if (batchConfig.postSink is null)
			return;
		const source = EventSource(agent.metadata.name, agent.spec.stationRef, agent.spec.taskId, "", ns);
		deliverEvent(definition.spec.output.sinks, source, payload, batchConfig.postSink, "[controller]",
			&secretHeaders);
	}

	/// An http sink's `headers_secret`, read from the agent-secrets key it names, as the run
	/// pod reads it from the env var that key is injected as. Empty when unresolvable: auth
	/// never breaks the run.
	private string secretHeaders(string headersSecret) nothrow
	{
		if (headersSecret.length == 0)
			return "";
		try
			return client.secretValue(ns, agentSecretName, headersSecret);
		catch (Exception)
			return "";
	}

	/// A deleted or finished Agent's batch: cancel it while still in flight, then clean it
	/// up and release the Agent. Without a provider (batch disabled) it only releases the
	/// Agent, leaving the batch to expire. True when the cleanup failed.
	bool releaseBatch()
	{
		if (batchConfig.providers is null)
		{
			releaseFinalizer();
			return false;
		}
		const terminal = agent.status.phase == Phase.succeeded || agent.status.phase == Phase.failed;
		if (!terminal && !agent.status.batchFallback)
			cancelInFlight();
		return cleanupBatch();
	}

	/// Cancel a deleted Agent's in-flight batch, best effort: a cleanup that is not settled
	/// retries this every reconcile, and a batch already cancelling or ended can refuse a
	/// repeated cancel. The cleanup's `BatchNotSettled` says whether the batch still runs.
	private void cancelInFlight()
	{
		try
			provider.cancel(agent.status.batchId);
		catch (Exception)
		{
		}
	}

	/// Delete what the Agent's batch left at the provider, then release its deletion.
	/// A batch not settled yet (a cancel still in progress) keeps the finalizer for a
	/// later reconcile without counting a failed attempt, until `batchSettleMinutes`
	/// after `startedAt`, past which it counts as one so the finalizer cannot hang forever.
	/// True when the cleanup failed.
	private bool cleanupBatch()
	{
		try
			provider.cleanup(agent.status.batchId);
		catch (BatchNotSettled)
			return batchTimedOut(agent.status.startedAt, now, batchSettleMinutes) && countFailedCleanup();
		catch (Exception)
			return countFailedCleanup();
		releaseFinalizer();
		return false;
	}

	/// Record one more failed cleanup, releasing the finalizer at `maxBatchCleanupAttempts`
	/// and leaving the provider objects behind. Always true, the cleanup having failed.
	private bool countFailedCleanup()
	{
		// The batch-cleanup-failed event attaches here (slice 2).
		const attempts = agent.status.batchCleanupAttempts + 1;
		if (attempts < maxBatchCleanupAttempts)
			patch(batchCleanupAttemptsPatch(attempts));
		else
			releaseFinalizer();
		return true;
	}

	/// Remove the batch-cleanup finalizer, if the Agent holds it.
	private void releaseFinalizer()
	{
		const release = removeFinalizerPatch(agent.metadata.finalizers, batchCleanupFinalizer);
		if (release.length)
			client.patchAgent(ns, agent.metadata.name, release);
	}

	/// The vendor's batch provider, authenticated with the agent-secrets value the
	/// definition maps to the vendor's API key; built once per reconcile.
	private BatchProvider provider()
	{
		enforce(batchConfig.providers !is null, "batch execution has no provider configured");
		if (batchProvider is null)
			batchProvider = batchConfig.providers(vendorOf(definition.spec.model),
				client.secretValue(ns, agentSecretName, apiKeyRef));
		return batchProvider;
	}

	private string apiKeyRef()
	{
		return secretRefFor(definition.spec.resources.secrets,
			batchVendor(vendorOf(definition.spec.model)).apiKeyEnv);
	}

	/// Fail a Running batch Agent on a controller whose batch execution was disabled since it
	/// submitted. With no provider the batch can be neither cancelled nor cleaned up, so it is
	/// left to finish and expire at the provider.
	ReconcileEffect failBatchDisabled()
	{
		auto failed = fail(batchDisabledReason);
		emitToSinks(batchFinished(false).toJson);
		releaseFinalizer();
		return failed;
	}

	/// Patch the Agent terminal Failed with `reason`.
	private ReconcileEffect fail(string reason)
	{
		const failed = Decision(ActionKind.failMissingRef, Phase.failed, 0, reason);
		patch(statusPatch(failed, "", now, agent.metadata.resourceVersion));
		return ReconcileEffect(false, "", failed);
	}

	private void patch(Json statusPatch)
	{
		client.patchAgentStatus(ns, agent.metadata.name, statusPatch);
	}
}

/// A poll of the batch `id`, or a pending one when polling throws: a provider or HTTP
/// error is logged and retried on the next pass, so the batch timeout still applies.
private BatchPoll pollOrPending(BatchProvider batch, string id)
{
	try
		return batch.poll(id);
	catch (Exception error)
	{
		logError("batch " ~ id ~ " poll failed: " ~ error.msg);
		return BatchPoll(BatchState.pending);
	}
}

/// The agent-phase terminal event of a finished batch, shaped like the supervisor's on a process
/// exit: `succeeded` with exit code 0, or `failed` with exit code 1 and reason `batch_failed`.
private LifecycleEvent batchFinished(bool succeeded) @safe pure nothrow
{
	LifecycleEvent finished = {phase: LifecyclePhase.agent, status: succeeded ? Status.succeeded : Status.failed,
		reason: succeeded ? "" : "batch_failed"};
	finished.exitCode = succeeded ? 0 : 1;
	return finished;
}

/// The agent-phase `batch_timeout` event: `failed` with exit code 1 when the timeout fails the
/// run, else `running`, since the fallback Job's supervisor reports how the run ends and a
/// consumer ends the visit on any `failed`.
private LifecycleEvent batchTimeout(bool failsRun) @safe pure nothrow
{
	LifecycleEvent timedOut = {phase: LifecyclePhase.agent, status: failsRun ? Status.failed : Status.running,
		reason: "batch_timeout"};
	if (failsRun)
		timedOut.exitCode = 1;
	return timedOut;
}

/// Whether the Agent holds the batch-cleanup finalizer and is past needing its batch: it
/// is being deleted, or it finished and a cleanup after its batch failed and must be retried.
private bool batchCleanupDue(const Agent agent) @safe pure
{
	import std.algorithm.searching : canFind;

	const phase = agent.status.phase;
	return agent.metadata.finalizers.canFind(batchCleanupFinalizer)
		&& (agent.metadata.deletionTimestamp.length > 0 || phase == Phase.succeeded
			|| phase == Phase.failed);
}

private enum batchDisabledReason = "batch execution is disabled on this controller";

/// Why the Agent cannot run its resolved recipe, or "": the recipe's own batch or realtime
/// violation, else a `resumeSession` the recipe cannot honour, else a realtime recipe on a
/// controller without a signing key, else a Station template the run pod cannot be built
/// from, else, for a non-batch recipe, its invalid `resources.mcp_servers`, else a batch
/// recipe on a controller without batch providers (`BATCH_ENABLED` unset), else per-run
/// input files, which a batch request has no workspace to download into.
private string runViolation(const Agent agent, const AgentDefinitionSpec recipe, Json stationTemplate,
	bool batchEnabled, bool realtimeEnabled)
{
	import std.algorithm.searching : find;

	const buildsPod = recipe.execution != Execution.batch || recipe.batch.onTimeout == BatchTimeoutAction.fallback;
	const violations = [
		batchViolation(recipe),
		realtimeViolation(recipe),
		resumeViolation(agent.spec.resumeSession, recipe),
		deliveryViolation(agent, recipe),
		recipe.execution == Execution.realtime && !realtimeEnabled ? realtimeDisabledReason : "",
		buildsPod ? templateViolation(stationTemplate, recipe) : "",
	].find!(violation => violation.length > 0);
	if (violations.length)
		return violations[0];
	if (recipe.execution != Execution.batch)
		return mcpViolation(recipe.resources.mcpServers, agentForModel(recipe.model).name);
	if (!batchEnabled)
		return batchDisabledReason;
	if (agent.spec.files.length == 0)
		return "";
	return "batch execution does not support files";
}

private enum realtimeDisabledReason = "realtime execution is disabled on this controller";

/// Why an Agent cannot resume `session` with `recipe`, or "" when it can (or resumes
/// nothing): only a realtime run resumes, from the recipe's conversation source, with a
/// vendor that keeps conversation state.
private string resumeViolation(string session, const AgentDefinitionSpec recipe) @safe
{
	if (session.length == 0)
		return "";
	if (recipe.execution != Execution.realtime)
		return "resumeSession requires realtime execution";
	if (recipe.resources.conversation.source.length == 0)
		return "resumeSession needs resources.conversation.source";
	const vendor = agentForModel(recipe.model);
	if (vendor.stateDir.length == 0)
		return vendor.name ~ " cannot resume a session";
	return "";
}

/// The agent-secrets key the `resources.secrets` entry named `env` points at, or "".
private string secretRefFor(const SecretRef[] secrets, string env) @safe pure nothrow
{
	foreach (secret; secrets)
		if (secret.name == env)
			return secret.ref_;
	return "";
}

/// The `resourceVersion` of the cached Agent named `name`, or "" if it is not in the
/// cache — used to send a delete precondition so a stale-cache delete of an Agent that
/// has since changed is rejected rather than removing the newer object. Public because
/// the controller's startup prune sweep (watchpoll) sends the same precondition.
string resourceVersionByName(const Agent[] cached, string name) @safe
{
	foreach (agent; cached)
		if (agent.metadata.name == name)
			return agent.metadata.resourceVersion;
	return "";
}

/// Observe the run Job: its terminal/running state, enriched on a terminal
/// transition with the run pod's real values. The TTL-after-finished GC can delete
/// the Job (cascading to its pod) before the controller observes the result if the
/// controller was down or backlogged. A GC'd Job is reported terminal with a clear
/// reason — never re-thrown, which would leave the Agent stuck Running.
private JobOutcome observeJob(KubeClient client, string ns, string jobName)
{
	JobOutcome outcome;
	try
		outcome = client.jobOutcome(ns, jobName);
	catch (NotFound)
		return JobOutcome(JobState.failed, 0, runRecordUnavailable, "");
	if (outcome.state != JobState.running)
		enrichFromPod(client, ns, jobName, outcome);
	return outcome;
}

/// On a terminal Job, replace the placeholder exit code / output the Job
/// conditions carry with the run pod's real values — the `agent` container's exit
/// code and its captured stdout — so `status.exitCode` / `status.output` reflect
/// what actually happened. A pod that has already been GC'd can't be read back, so
/// the outcome records why the output is missing instead of leaving it silently
/// empty (a Job-level failure reason already present is kept).
private void enrichFromPod(KubeClient client, string ns, string jobName, ref JobOutcome outcome)
{
	try
	{
		const podName = client.podNameForJob(ns, jobName);
		if (podName.length == 0)
			return markOutputUnavailable(outcome);
		const pod = client.podResult(ns, podName);
		outcome.exitCode = coherentExitCode(outcome.state, pod.exitCode);
		outcome.output = pod.log;
		outcome.sessionId = lastSessionId(pod.log);
		recordDelivery(outcome, pod.courierLog);
	}
	catch (Exception)
	{
		// The pod was GC'd between reads, or the log fetch failed: enrichment is
		// best-effort, so degrade to the Job-level outcome instead of re-throwing —
		// which would propagate up and leave the Agent stuck Running forever.
		markOutputUnavailable(outcome);
	}
}

/// Record what the courier reported in its `courierLog`: the pull request it opened, or,
/// when its delivery failed, why. That reason replaces the Job's generic one
/// (`BackoffLimitExceeded`): the courier only fails after the agent succeeded, so its
/// failure is what failed the pod.
private void recordDelivery(ref JobOutcome outcome, string courierLog)
{
	const delivery = lastDelivery(courierLog);
	outcome.prUrl = delivery.status == DeliveryStatus.opened ? delivery.url : "";
	if (delivery.status == DeliveryStatus.failed)
		outcome.reason = "pull request delivery failed: " ~ delivery.reason;
}

/// Record that the run pod's output couldn't be read back (it was GC'd), keeping any
/// Job-level failure reason already present, and keep the exit code coherent with the
/// Job state so a failed run never reports the placeholder 0.
private void markOutputUnavailable(ref JobOutcome outcome)
{
	if (outcome.reason.length == 0)
		outcome.reason = runOutputUnavailable;
	outcome.exitCode = coherentExitCode(outcome.state, outcome.exitCode);
}

private bool resolveRefs(KubeClient client, string ns, Agent agent, ref Station station,
	ref AgentDefinition definition)
{
	try
	{
		station = client.getStation(ns, agent.spec.stationRef);
		definition = client.getAgentDefinition(ns, station.spec.agentDefRef);
		definition.spec = runRecipe(agent, definition.spec);
		return true;
	}
	catch (NotFound)
		return false;
}

private void pruneHistory(KubeClient client, string ns, string stationRef, const Agent[] cached)
{
	Station station;
	try
		station = client.getStation(ns, stationRef);
	catch (NotFound)
		return;

	foreach (name; agentsToPrune(cached, stationRef, station.spec.successfulRunsHistoryLimit,
			station.spec.failedRunsHistoryLimit))
		client.deleteAgent(ns, name, resourceVersionByName(cached, name));
}

version (unittest)
{
	import fluent.asserts;
	import vibe.data.json : parseJsonString;
	import agentcore.crds.enums : ConcurrencyPolicy;
	import agentcore.reconcile.reconcile : JobState;
	import agentcore.batch.provider : BatchNotSettled, BatchPoll;
	import agentcore.core.vendor : Vendor;

	/// The JSON patch removing the batch-cleanup finalizer when it is the Agent's only one.
	Json removeFirstFinalizer()
	{
		return parseJsonString(`[
			{"op":"test","path":"/metadata/finalizers/0","value":"agents.re-cinq.com/batch-cleanup"},
			{"op":"remove","path":"/metadata/finalizers/0"}]`);
	}

	private final class FakeKubeClient : KubeClient
	{
		Station station;
		AgentDefinition definition;

		// The CRD requires a template, so every Station the API server serves has one.
		this()
		{
			station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent"}]}}`);
		}

		bool stationMissing;
		JobOutcome outcome;
		bool jobMissing;
		string podNameValue;
		PodResult podResultValue;
		bool podReadThrows; /// simulate the pod being GC'd between podNameForJob and podResult
		string[string] secrets; /// "<secret>/<key>" -> value

		Json[] createdJobs;
		Json[] statusPatches;
		string[] patchedNames;
		Json[] agentPatches;
		string[] calls; /// status / metadata patches and provider cleanups, in order
		string[] deletedAgents;
		string[] deletedVersions;

		override Station getStation(string ns, string name)
		{
			enforce(!stationMissing, new NotFound("station " ~ name ~ " not found"));
			return station;
		}

		override AgentDefinition getAgentDefinition(string ns, string name)
		{
			return definition;
		}

		override void createJob(string ns, Json job)
		{
			createdJobs ~= job;
		}

		override JobOutcome jobOutcome(string ns, string jobName)
		{
			enforce(!jobMissing, new NotFound("Job " ~ jobName ~ " not found"));
			return outcome;
		}

		override void patchAgentStatus(string ns, string name, Json patch)
		{
			patchedNames ~= name;
			statusPatches ~= patch;
			calls ~= "patchAgentStatus";
		}

		override void patchAgent(string ns, string name, Json patch)
		{
			agentPatches ~= patch;
			calls ~= "patchAgent";
		}

		override void deleteAgent(string ns, string name, string resourceVersion = "")
		{
			deletedAgents ~= name;
			deletedVersions ~= resourceVersion;
		}

		override string podNameForJob(string ns, string jobName)
		{
			return podNameValue;
		}

		override PodResult podResult(string ns, string podName)
		{
			enforce(!podReadThrows, new NotFound("pod " ~ podName ~ " not found"));
			return podResultValue;
		}

		override string secretValue(string ns, string name, string key)
		{
			const value = (name ~ "/" ~ key) in secrets;
			enforce(value !is null, new NotFound("secret " ~ name ~ "/" ~ key ~ " not found"));
			return *value;
		}
	}

	private final class FakeBatchProvider : BatchProvider
	{
		BatchRequest[] submitted;
		BatchPoll pollResult;
		string[] cancelled;
		string[] cleaned;
		bool cleanupThrows;
		bool pollThrows;
		bool cleanupNotSettled;
		bool cancelThrows;
		FakeKubeClient journal; /// when set, cleanups are logged into its `calls`

		string submit(BatchRequest request)
		{
			submitted ~= request;
			return "msgbatch_1";
		}

		BatchPoll poll(string id)
		{
			enforce(!pollThrows, "provider poll failed");
			return pollResult;
		}

		void cancel(string id)
		{
			cancelled ~= id;
			enforce(!cancelThrows, "batch " ~ id ~ " is already cancelling");
		}

		void cleanup(string id)
		{
			cleaned ~= id;
			enforce(!cleanupNotSettled, new BatchNotSettled("batch " ~ id ~ " is still canceling"));
			enforce(!cleanupThrows, "provider cleanup failed");
			if (journal !is null)
				journal.calls ~= "cleanup " ~ id;
		}
	}

	/// A factory handing out `provider` and recording the vendor and API key it was asked for.
	private struct FakeBatchProviders
	{
		FakeBatchProvider provider;
		Vendor[] vendors;
		string[] apiKeys;

		BatchProvider make(Vendor vendor, string apiKey)
		{
			vendors ~= vendor;
			apiKeys ~= apiKey;
			return provider;
		}
	}

	private FakeKubeClient batchClient(string model)
	{
		import agentcore.crds.enums : Execution;
		import agentcore.crds.secret_ref : SecretRef;

		auto client = new FakeKubeClient;
		client.station.metadata.name = "stn";
		client.station.spec.agentDefRef = "def";
		client.definition.spec.model = model;
		client.definition.spec.prompt = "Fix {ticket}";
		client.definition.spec.execution = Execution.batch;
		client.definition.spec.resources.secrets = [SecretRef("ANTHROPIC_API_KEY", "anthropic-key")];
		client.secrets["agent-secrets/anthropic-key"] = "sk-ant-test";
		return client;
	}

	private Agent runningBatchAgent(string name)
	{
		Agent agent;
		agent.metadata.name = name;
		agent.metadata.uid = "uid-7";
		agent.spec.stationRef = "stn";
		agent.status.phase = Phase.running;
		agent.status.batchId = "msgbatch_1";
		agent.status.batchProvider = "anthropic";
		agent.status.startedAt = "2026-06-22T12:00:00Z";
		return agent;
	}

	private BatchPoll succeededPoll()
	{
		import agentcore.batch.anthropic : parsePoll;

		return parsePoll(parseJsonString(import("batch/anthropic-batch-ended.json")),
			import("batch/anthropic-result-succeeded.json"));
	}

	/// Records every http sink post as `<url> <line>`, and the header block it carried.
	private struct FakeSinkPoster
	{
		string[] posts;
		string[] headers;

		void post(string url, string line, string headerBlock) nothrow
		{
			posts ~= url ~ " " ~ line;
			headers ~= headerBlock;
		}
	}

	/// A `BatchConfig` over `providers` whose http sink posts land in `poster`.
	private BatchConfig sinkConfig(ref FakeBatchProviders providers, ref FakeSinkPoster poster)
	{
		auto config = BatchConfig(&providers.make);
		config.postSink = &poster.post;
		return config;
	}

	private Agent pendingAgent(string name, string stationRef)
	{
		Agent agent;
		agent.metadata.name = name;
		agent.spec.stationRef = stationRef;
		agent.status.phase = Phase.pending;
		return agent;
	}
}

unittest
{
	// Pending + refs resolved -> Job created and status patched to Running.
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.template_ = parseJsonString(
		`{"spec":{"containers":[{"name":"agent","image":"node:22"}]}}`);
	client.definition.spec.model = "claude-sonnet-4-6";
	client.definition.spec.prompt = "Fix it";

	reconcileAgent(client, "ai-agents", pendingAgent("run-1", "stn"), "img", "2026-06-22T12:00:00Z", null);

	client.createdJobs.length.should.equal(1);
	client.patchedNames.should.equal(["run-1"]);
	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Running");
	client.statusPatches[0]["status"]["jobName"].get!string.should.equal("agent-job-run-1");
	client.statusPatches[0]["status"]["startedAt"].get!string.should.equal("2026-06-22T12:00:00Z");
}

unittest
{
	// The Agent's resourceVersion flows into the status patch as an optimistic-
	// concurrency precondition, so two reconcilers racing off different snapshots
	// can't lost-update each other (the stale write 409s).
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.template_ = parseJsonString(
		`{"spec":{"containers":[{"name":"agent","image":"node:22"}]}}`);
	client.definition.spec.model = "claude-sonnet-4-6";
	client.definition.spec.prompt = "Fix it";

	auto agent = pendingAgent("run-1", "stn");
	agent.metadata.resourceVersion = "4242";
	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["metadata"]["resourceVersion"].get!string.should.equal("4242");
}

unittest
{
	// Pending + missing Station -> Failed status, no Job.
	auto client = new FakeKubeClient;
	client.stationMissing = true;

	reconcileAgent(client, "ai-agents", pendingAgent("run-2", "gone"), "img", "2026-06-22T12:00:00Z", null);

	client.createdJobs.length.should.equal(0);
	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["failureReason"].get!string.should
		.equal("Station or AgentDefinition not found");
}

unittest // an exec definition with mcp_servers fails Pending with the violation, no Job
{
	import agentcore.crds.enums : McpTransport;
	import agentcore.crds.mcp_server : McpServer;

	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.definition.spec.model = "exec";
	client.definition.spec.resources.mcpServers = [
		McpServer("tools", McpTransport.http, "", null, "https://tools-mcp/mcp", ""),
	];

	reconcileAgent(client, "ai-agents", pendingAgent("run-3", "stn"), "img", "2026-06-22T12:00:00Z", null);

	client.createdJobs.length.should.equal(0);
	client.statusPatches[0]["status"]["failureReason"].get!string.should
		.equal("the exec model does not support resources.mcp_servers");
}

unittest
{
	// Pending + Station already at maxConcurrentRuns -> wait: no Job, no patch.
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.maxConcurrentRuns = 1;
	client.station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent"}]}}`);

	Agent active; // one run already in flight for this Station
	active.metadata.name = "run-active";
	active.spec.stationRef = "stn";
	active.status.phase = Phase.running;

	reconcileAgent(client, "ai-agents", pendingAgent("run-waiting", "stn"), "img", "now", [active]);

	client.createdJobs.length.should.equal(0);
	client.statusPatches.length.should.equal(0);
}

unittest
{
	// Pending + Station at capacity with concurrencyPolicy Replace -> preempt the
	// oldest Running run (delete it, cascading to its Job) and start the new one.
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.concurrencyPolicy = ConcurrencyPolicy.replace;
	client.station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent"}]}}`);

	Agent running; // the in-flight run Replace should cancel
	running.metadata.name = "run-old";
	running.metadata.resourceVersion = "rv-old";
	running.spec.stationRef = "stn";
	running.status.phase = Phase.running;
	running.status.startedAt = "2026-06-22T10:00:00Z";

	reconcileAgent(client, "ai-agents", pendingAgent("run-new", "stn"), "img",
		"2026-06-22T12:00:00Z", [running]);

	client.deletedAgents.should.equal(["run-old"]);
	// The preemption carries the victim's resourceVersion as a delete precondition.
	client.deletedVersions.should.equal(["rv-old"]);
	client.createdJobs.length.should.equal(1);
	client.patchedNames.should.equal(["run-new"]);
	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Running");
	client.statusPatches[0]["status"]["jobName"].get!string.should.equal("agent-job-run-new");
}

unittest
{
	// Running + Job succeeded -> Succeeded; status enriched from the run pod
	// (output = pod log, exitCode = the agent container's real code), history pruned.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.succeeded);
	client.podNameValue = "agent-job-run-3-abc";
	client.podResultValue = PodResult(0, "the wrapped event log");
	client.station.metadata.name = "stn";
	client.station.spec.successfulRunsHistoryLimit = 0; // prune the whole succeeded bucket

	Agent old;
	old.metadata.name = "old-success";
	old.metadata.resourceVersion = "rv-old-success";
	old.spec.stationRef = "stn";
	old.status.phase = Phase.succeeded;
	old.status.completedAt = "2026-06-22T01:00:00Z";

	// Another Station's history must survive stn's limit-0 prune (#87).
	Agent foreign;
	foreign.metadata.name = "other-station-success";
	foreign.spec.stationRef = "other-stn";
	foreign.status.phase = Phase.succeeded;
	foreign.status.completedAt = "2026-06-22T01:00:00Z";

	Agent agent;
	agent.metadata.name = "run-3";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-3";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", [old, foreign]);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Succeeded");
	client.statusPatches[0]["status"]["output"].get!string.should.equal("the wrapped event log");
	client.statusPatches[0]["status"]["exitCode"].get!long.should.equal(0);
	client.deletedAgents.should.equal(["old-success"]);
	// The pruning delete carries the Agent's resourceVersion as a precondition.
	client.deletedVersions.should.equal(["rv-old-success"]);
}

unittest // a finished run records the last session id its pod log announced as status.sessionId
{
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.succeeded);
	client.podNameValue = "agent-job-run-4-abc";
	client.podResultValue = PodResult(0, `{"source":{},"event":{"kind":"session","id":"sess-9"}}`);
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-4";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-4";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", []);

	client.statusPatches[0]["status"]["sessionId"].get!string.should.equal("sess-9");
}

version (unittest)
{
	/// A Running Agent whose Job ended `state`, with the agent's pod `log` and the
	/// courier's `courierLog`, reconciled once; returns the status it was patched with.
	private Json deliveredStatus(JobState state, string log, string courierLog)
	{
		auto client = new FakeKubeClient;
		client.outcome = JobOutcome(state, 0, state == JobState.failed ? "BackoffLimitExceeded" : "", "");
		client.podNameValue = "agent-job-run-8-abc";
		client.podResultValue = PodResult(0, log, courierLog);
		client.station.metadata.name = "stn";

		Agent agent;
		agent.metadata.name = "run-8";
		agent.spec.stationRef = "stn";
		agent.status.phase = Phase.running;
		agent.status.jobName = "agent-job-run-8";

		reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", []);
		return client.statusPatches[0]["status"];
	}
}

unittest // a finished run records the pull request its courier opened as status.prUrl
{
	const status = deliveredStatus(JobState.succeeded, "",
		`{"kind":"delivery","status":"opened","url":"https://github.com/o/app/pull/7"}`);

	status["prUrl"].get!string.should.equal("https://github.com/o/app/pull/7");
}

unittest // a delivery event in the agent's own log is never taken as the run's pull request
{
	const status = deliveredStatus(JobState.succeeded,
		`{"kind":"delivery","status":"opened","url":"https://evil.example/pull/1"}`, "");

	(("prUrl" in status) is null).should.equal(true);
}

unittest // a failed delivery replaces the Job's generic failure reason with the courier's
{
	const status = deliveredStatus(JobState.failed, "",
		`{"kind":"delivery","status":"failed","reason":"push rejected"}`);

	[status["failureReason"].get!string, ("prUrl" in status) is null ? "absent" : "present"]
		.should.equal(["pull request delivery failed: push rejected", "absent"]);
}

unittest // a Station template with hostNetwork fails the Agent Pending with the reason, with no Job
{
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.template_ = parseJsonString(
		`{"spec":{"hostNetwork":true,"containers":[{"name":"agent","image":"node:22"}]}}`);

	reconcileAgent(client, "ai-agents", pendingAgent("run-9", "stn"), "img", "2026-06-22T12:00:00Z", null);

	client.createdJobs.length.should.equal(0);
	[client.statusPatches[0]["status"]["phase"].get!string, client.statusPatches[0]["status"]["failureReason"].get!string]
		.should.equal(["Failed", "Station template must not enable hostNetwork on an agent run pod"]);
}

unittest // a batch recipe without a fallback Job is not held to its Station's template
{
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.template_ = parseJsonString(`{"spec":{"hostNetwork":true,"containers":[{"name":"agent"}]}}`);
	client.definition.spec.execution = Execution.batch;

	runViolation(pendingAgent("run-9", "stn"), client.definition.spec, client.station.spec.template_, true, false)
		.should.equal("");
}

unittest // a pull request delivery that cannot run fails the Agent Pending, with no Job
{
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.definition.spec.delivery.pullRequest.base = "main";
	client.definition.spec.delivery.pullRequest.titleTemplate = "Fix";

	reconcileAgent(client, "ai-agents", pendingAgent("run-9", "stn"), "img", "2026-06-22T12:00:00Z", null);

	client.createdJobs.length.should.equal(0);
	client.statusPatches[0]["status"]["failureReason"].get!string.should
		.equal("delivery.pullRequest needs a repo in resources.repos");
}

unittest
{
	// Running + Job failed -> Failed status carries the pod's real exit code + log.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.failed, 0, "BackoffLimitExceeded", "");
	client.podNameValue = "agent-job-run-6-xyz";
	client.podResultValue = PodResult(42, "boom in the log");
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-6";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-6";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["exitCode"].get!long.should.equal(42);
	client.statusPatches[0]["status"]["output"].get!string.should.equal("boom in the log");
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal("BackoffLimitExceeded");
}

unittest
{
	// Running + Job succeeded but the run pod was GC'd before readback -> still
	// Succeeded, but status carries a clear reason instead of a silently empty output.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.succeeded);
	client.podNameValue = ""; // pod garbage-collected
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-7";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-7";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Succeeded");
	client.statusPatches[0]["status"]["output"].get!string.should.equal("");
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal(runOutputUnavailable);
}

unittest
{
	// Running + Job failed, but the pod was GC'd between podNameForJob and podResult
	// (podResult throws) -> still reported terminal Failed (never left stuck Running),
	// keeping the Job-level reason and a non-zero exit code.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.failed, 1, "BackoffLimitExceeded", "");
	client.podNameValue = "agent-job-run-9-xyz";
	client.podReadThrows = true;
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-9";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-9";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal("BackoffLimitExceeded");
	client.statusPatches[0]["status"]["exitCode"].get!long.should.equal(1);
}

unittest
{
	// Running + Job failed but the pod's container exit code reads back as 0 (a GC
	// race leaves it unpopulated) -> status must not contradict itself with "Failed,
	// exitCode 0"; report a non-zero code while keeping the captured log.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.failed, 1, "DeadlineExceeded", "");
	client.podNameValue = "agent-job-run-10-xyz";
	client.podResultValue = PodResult(0, "partial log");
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-10";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-10";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["exitCode"].get!long.should.equal(1);
	client.statusPatches[0]["status"]["output"].get!string.should.equal("partial log");
}

unittest
{
	// Running + Job itself GC'd (controller backlogged past ttlSecondsAfterFinished)
	// -> reported terminal Failed with a clear reason, not left stuck Running.
	auto client = new FakeKubeClient;
	client.jobMissing = true;
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-8";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-8";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal(runRecordUnavailable);
}

unittest
{
	// Running + Job still running -> no-op, no patch.
	auto client = new FakeKubeClient;
	client.outcome = JobOutcome(JobState.running);

	Agent agent;
	agent.metadata.name = "run-4";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "agent-job-run-4";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches.length.should.equal(0);
	client.createdJobs.length.should.equal(0);
}

unittest
{
	// #125: a Running Agent whose status never recorded its jobName (a controller crash
	// between the Running patch and the jobName write) must not stay Running forever. The
	// Job name is derived from the Agent name, so the run is observed under it and repaired;
	// here the Job is gone, so the Agent completes Failed instead of stalling with no patch.
	auto client = new FakeKubeClient;
	client.jobMissing = true;
	client.station.metadata.name = "stn";

	Agent agent;
	agent.metadata.name = "run-11";
	agent.spec.stationRef = "stn";
	agent.status.phase = Phase.running;
	agent.status.jobName = "";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null);

	client.statusPatches.length.should.equal(1);
	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal(runRecordUnavailable);
	// The recovered (derived) Job name is written into the terminal record, so the run
	// no longer ends with a permanently empty jobName.
	client.statusPatches[0]["status"]["jobName"].get!string.should.equal("agent-job-run-11");
}

unittest // pending agent whose batch definition sets allowed_tools goes Failed with that reason and no Job
{
	import agentcore.crds.enums : Execution;

	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.definition.spec.execution = Execution.batch;
	client.definition.spec.allowedTools = ["Read"];

	reconcileAgent(client, "ai-agents", pendingAgent("run-b", "stn"), "img", "2026-06-22T12:00:00Z", null);

	client.createdJobs.length.should.equal(0);
	client.statusPatches[0]["status"]["failureReason"].get!string.should
		.equal("batch execution does not support allowed_tools");
}

unittest // pending claude batch agent submits with the agent-secrets key and patches Running with batchId msgbatch_1
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	auto agent = pendingAgent("run-b", "stn");
	agent.metadata.uid = "uid-7";
	agent.spec.parameters = ["ticket": "ENG-1"];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null, BatchConfig(&providers.make));

	providers.vendors.should.equal([Vendor.claude]);
	providers.apiKeys.should.equal(["sk-ant-test"]);
	providers.provider.submitted.should.equal([
		BatchRequest("claude-sonnet-4-6", "Fix ENG-1", Json.undefined, 16_000, "uid-7")
	]);
	client.createdJobs.length.should.equal(0);
	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Running",
		"batchId":"msgbatch_1","batchProvider":"anthropic","startedAt":"2026-06-22T12:00:00Z"}}`)]);
}

unittest // pending claude batch agent without an ANTHROPIC_API_KEY secret entry goes Failed naming it and submits nothing
{
	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.resources.secrets = null;
	auto providers = FakeBatchProviders(new FakeBatchProvider);

	reconcileAgent(client, "ai-agents", pendingAgent("run-b", "stn"), "img", "2026-06-22T12:00:00Z", null,
		BatchConfig(&providers.make));

	providers.provider.submitted.length.should.equal(0);
	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Failed",
		"failureReason":"batch execution needs a resources.secrets entry named ANTHROPIC_API_KEY",
		"completedAt":"2026-06-22T12:00:00Z"}}`)]);
}

unittest // running claude batch agent whose poll succeeded patches Succeeded with the translated claude lines as output
{
	import agentcore.batch.anthropic : toCliEvents;
	import std.array : join;

	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = succeededPoll();

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T12:05:00Z", null,
		BatchConfig(&providers.make));

	auto expected = Json([
		"phase": Json("Succeeded"),
		"exitCode": Json(0),
		"output": Json(toCliEvents(succeededPoll(), "uid-7").join("\n")),
		"completedAt": Json("2026-06-22T12:05:00Z"),
	]);
	client.statusPatches.should.equal([Json(["status": expected])]);
}

unittest // running claude batch agent whose poll errored patches Failed with the vendor error as reason
{
	import agentcore.batch.anthropic : parsePoll;

	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = parsePoll(parseJsonString(import("batch/anthropic-batch-ended.json")),
		import("batch/anthropic-result-errored.json"));

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T12:05:00Z", null,
		BatchConfig(&providers.make));

	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Failed");
	client.statusPatches[0]["status"]["failureReason"].should.equal(Json(providers.provider.pollResult.error));
}

unittest // running claude batch agent whose poll is pending patches nothing
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T12:05:00Z", null,
		BatchConfig(&providers.make));

	client.statusPatches.length.should.equal(0);
}

unittest // pending batch 60 minutes past a 60-minute timeout with onTimeout fail cancels msgbatch_1 and patches Failed "batch timed out"
{
	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.batch.timeoutMinutes = 60;
	auto providers = FakeBatchProviders(new FakeBatchProvider);

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T13:00:00Z", null,
		BatchConfig(&providers.make));

	providers.provider.cancelled.should.equal(["msgbatch_1"]);
	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Failed","exitCode":1,
		"output":"","failureReason":"batch timed out","completedAt":"2026-06-22T13:00:00Z"}}`)]);
}

unittest // batch whose poll throws 60 minutes past a 60-minute timeout cancels msgbatch_1 and patches Failed "batch timed out"
{
	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.batch.timeoutMinutes = 60;
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollThrows = true;

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T13:00:00Z", null,
		BatchConfig(&providers.make));

	providers.provider.cancelled.should.equal(["msgbatch_1"]);
	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Failed","exitCode":1,
		"output":"","failureReason":"batch timed out","completedAt":"2026-06-22T13:00:00Z"}}`)]);
}

unittest // batch whose poll throws before its timeout stays Running with no patch
{
	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.batch.timeoutMinutes = 60;
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollThrows = true;

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T12:05:00Z", null,
		BatchConfig(&providers.make));

	client.statusPatches.length.should.equal(0);
}

unittest // timed-out batch with onTimeout fallback cancels msgbatch_1, creates the buildJob Job and patches batchFallback true
{
	import agentcore.crds.enums : BatchTimeoutAction;

	auto client = batchClient("claude-sonnet-4-6");
	client.station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent","image":"node:22"}]}}`);
	client.definition.spec.batch.timeoutMinutes = 60;
	client.definition.spec.batch.onTimeout = BatchTimeoutAction.fallback;
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	auto agent = runningBatchAgent("run-b");

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T13:00:00Z", null, BatchConfig(&providers.make));

	providers.provider.cancelled.should.equal(["msgbatch_1"]);
	client.createdJobs.should.equal([buildJob(agent, client.station, client.definition, "img")]);
	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Running","batchFallback":true,
		"jobName":"agent-job-run-b","startedAt":"2026-06-22T13:00:00Z"}}`)]);
}

unittest // fallen-back batch agent whose Job succeeded completes Succeeded from the pod without polling the batch
{
	auto client = batchClient("claude-sonnet-4-6");
	client.outcome = JobOutcome(JobState.succeeded);
	client.podNameValue = "agent-job-run-b-abc";
	client.podResultValue = PodResult(0, "job log");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	auto agent = runningBatchAgent("run-b");
	agent.status.batchFallback = true;
	agent.status.jobName = "agent-job-run-b";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T13:00:00Z", null, BatchConfig(&providers.make));

	providers.vendors.length.should.equal(0);
	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Succeeded");
	client.statusPatches[0]["status"]["output"].get!string.should.equal("job log");
}

unittest // timed-out fallback batch whose poll succeeded completes Succeeded without cancel or Job
{
	import agentcore.crds.enums : BatchTimeoutAction;

	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.batch.timeoutMinutes = 60;
	client.definition.spec.batch.onTimeout = BatchTimeoutAction.fallback;
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = succeededPoll();

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T13:00:00Z", null,
		BatchConfig(&providers.make));

	providers.provider.cancelled.length.should.equal(0);
	client.createdJobs.length.should.equal(0);
	client.statusPatches[0]["status"]["phase"].get!string.should.equal("Succeeded");
}

unittest // timed-out fallback batch at Station capacity cancels and patches batchFallback true with no Job
{
	import agentcore.crds.enums : BatchTimeoutAction;

	auto client = batchClient("claude-sonnet-4-6");
	client.station.spec.maxConcurrentRuns = 1;
	client.definition.spec.batch.timeoutMinutes = 60;
	client.definition.spec.batch.onTimeout = BatchTimeoutAction.fallback;
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	auto agent = runningBatchAgent("run-b");
	auto other = runningBatchAgent("run-other");
	other.status.batchId = "";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T13:00:00Z", [agent, other], BatchConfig(&providers.make));

	providers.provider.cancelled.should.equal(["msgbatch_1"]);
	client.createdJobs.length.should.equal(0);
	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Running","batchFallback":true}}`)]);
}

unittest // fallen-back batch agent waiting for a slot creates its Job once the Station has room, without polling
{
	auto client = batchClient("claude-sonnet-4-6");
	client.station.spec.maxConcurrentRuns = 1;
	client.station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent","image":"node:22"}]}}`);
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	auto agent = runningBatchAgent("run-b");
	agent.status.batchFallback = true;

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T14:00:00Z", [agent], BatchConfig(&providers.make));

	providers.vendors.length.should.equal(0);
	client.createdJobs.should.equal([buildJob(agent, client.station, client.definition, "img")]);
	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Running",
		"jobName":"agent-job-run-b","startedAt":"2026-06-22T14:00:00Z"}}`)]);
}

unittest // fallen-back batch agent waiting for a slot at Station capacity stays without a Job or patch
{
	auto client = batchClient("claude-sonnet-4-6");
	client.station.spec.maxConcurrentRuns = 1;
	auto agent = runningBatchAgent("run-b");
	agent.status.batchFallback = true;
	auto other = runningBatchAgent("run-other");

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T14:00:00Z", [agent, other]);

	client.createdJobs.length.should.equal(0);
	client.statusPatches.length.should.equal(0);
}

unittest // pending claude batch agent submit JSON-patches the batch-cleanup finalizer into the Agent metadata
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);

	reconcileAgent(client, "ai-agents", pendingAgent("run-b", "stn"), "img", "2026-06-22T12:00:00Z", null,
		BatchConfig(&providers.make));

	client.agentPatches.should.equal([
		parseJsonString(`[{"op":"add","path":"/metadata/finalizers","value":["agents.re-cinq.com/batch-cleanup"]}]`)
	]);
}

unittest // succeeded batch poll cleans up msgbatch_1 after the status patch, then removes the batch-cleanup finalizer
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = succeededPoll();
	providers.provider.journal = client;
	auto agent = runningBatchAgent("run-b");
	agent.metadata.finalizers = ["other/keep", batchCleanupFinalizer];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:05:00Z", null, BatchConfig(&providers.make));

	client.calls.should.equal(["patchAgentStatus", "cleanup msgbatch_1", "patchAgent"]);
	client.agentPatches.should.equal([parseJsonString(`[
		{"op":"test","path":"/metadata/finalizers/1","value":"agents.re-cinq.com/batch-cleanup"},
		{"op":"remove","path":"/metadata/finalizers/1"}]`)]);
}

unittest // timed-out batch with onTimeout fail cancels, then cleans up msgbatch_1 and removes the finalizer
{
	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.batch.timeoutMinutes = 60;
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.journal = client;
	auto agent = runningBatchAgent("run-b");
	agent.metadata.finalizers = [batchCleanupFinalizer];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T13:00:00Z", null, BatchConfig(&providers.make));

	providers.provider.cancelled.should.equal(["msgbatch_1"]);
	client.calls.should.equal(["patchAgentStatus", "cleanup msgbatch_1", "patchAgent"]);
	client.agentPatches.should.equal([removeFirstFinalizer]);
}

unittest // timed-out batch with onTimeout fallback starts its Job, then cleans up msgbatch_1 and removes the finalizer
{
	import agentcore.crds.enums : BatchTimeoutAction;

	auto client = batchClient("claude-sonnet-4-6");
	client.station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent","image":"node:22"}]}}`);
	client.definition.spec.batch.timeoutMinutes = 60;
	client.definition.spec.batch.onTimeout = BatchTimeoutAction.fallback;
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.journal = client;
	auto agent = runningBatchAgent("run-b");
	agent.metadata.finalizers = [batchCleanupFinalizer];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T13:00:00Z", null, BatchConfig(&providers.make));

	client.createdJobs.length.should.equal(1);
	client.calls.should.equal(["patchAgentStatus", "cleanup msgbatch_1", "patchAgent"]);
}

unittest // deleted Agent with an in-flight batch cancels, cleans up msgbatch_1, then removes the finalizer without polling
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = succeededPoll();
	providers.provider.journal = client;
	auto agent = runningBatchAgent("run-b");
	agent.metadata.finalizers = [batchCleanupFinalizer];
	agent.metadata.deletionTimestamp = "2026-06-22T12:03:00Z";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:05:00Z", null, BatchConfig(&providers.make));

	providers.provider.cancelled.should.equal(["msgbatch_1"]);
	client.calls.should.equal(["cleanup msgbatch_1", "patchAgent"]);
	client.agentPatches.should.equal([removeFirstFinalizer]);
}

unittest // deleted Agent with an in-flight batch whose repeated cancel fails still cleans up msgbatch_1 and removes the finalizer
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.cancelThrows = true;
	auto agent = runningBatchAgent("run-b");
	agent.metadata.finalizers = [batchCleanupFinalizer];
	agent.metadata.deletionTimestamp = "2026-06-22T12:03:00Z";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:05:00Z", null, BatchConfig(&providers.make));

	[Json(providers.provider.cleaned.length), Json(client.agentPatches == [removeFirstFinalizer])]
		.should.equal([Json(1), Json(true)]);
}

unittest // succeeded batch Agent on its 5th failed cleanup removes the finalizer and keeps its phase
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.cleanupThrows = true;
	auto agent = runningBatchAgent("run-b");
	agent.status.phase = Phase.succeeded;
	agent.status.batchCleanupAttempts = 4;
	agent.metadata.finalizers = [batchCleanupFinalizer];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:10:00Z", null, BatchConfig(&providers.make));

	providers.provider.cleaned.should.equal(["msgbatch_1"]);
	client.statusPatches.length.should.equal(0);
	client.agentPatches.should.equal([removeFirstFinalizer]);
}

unittest // failed batch Agent whose cleanup reports not settled 10 minutes after start keeps the finalizer without counting an attempt
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.cleanupNotSettled = true;
	auto agent = runningBatchAgent("run-b");
	agent.status.phase = Phase.failed;
	agent.metadata.finalizers = [batchCleanupFinalizer];

	const effect = reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:10:00Z", null,
		BatchConfig(&providers.make));

	[Json(client.statusPatches.length), Json(client.agentPatches.length), Json(effect.batchCleanupFailed)]
		.should.equal([Json(0), Json(0), Json(false)]);
}

unittest // failed batch Agent whose cleanup reports not settled 48 hours after start records batchCleanupAttempts 1
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.cleanupNotSettled = true;
	auto agent = runningBatchAgent("run-b");
	agent.status.phase = Phase.failed;
	agent.metadata.finalizers = [batchCleanupFinalizer];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-24T12:00:00Z", null, BatchConfig(&providers.make));

	client.statusPatches.should.equal([parseJsonString(`{"status":{"batchCleanupAttempts":1}}`)]);
}

unittest // succeeded batch Agent whose 1st cleanup fails records batchCleanupAttempts 1 and keeps the finalizer
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.cleanupThrows = true;
	auto agent = runningBatchAgent("run-b");
	agent.status.phase = Phase.succeeded;
	agent.metadata.finalizers = [batchCleanupFinalizer];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:10:00Z", null, BatchConfig(&providers.make));

	client.statusPatches.should.equal([parseJsonString(`{"status":{"batchCleanupAttempts":1}}`)]);
	client.agentPatches.length.should.equal(0);
}

unittest // succeeded batch poll with maxOutputBytes 64 keeps only the last 64 bytes of the output
{
	import agentcore.batch.anthropic : toCliEvents;
	import std.array : join;

	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = succeededPoll();

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T12:05:00Z", null,
		BatchConfig(&providers.make, 64));

	client.statusPatches[0]["status"]["output"].get!string.should.equal(
		capOutput(toCliEvents(succeededPoll(), "uid-7").join("\n"), 64));
}

unittest // running batch Agent whose Station is gone goes Failed "Station or AgentDefinition not found" without polling
{
	auto client = batchClient("claude-sonnet-4-6");
	client.stationMissing = true;
	auto providers = FakeBatchProviders(new FakeBatchProvider);

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T12:05:00Z", null,
		BatchConfig(&providers.make));

	providers.vendors.length.should.equal(0);
	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Failed",
		"failureReason":"Station or AgentDefinition not found","completedAt":"2026-06-22T12:05:00Z"}}`)]);
}

unittest // pending batch agent at a full Replace station deletes run-old and submits a batch without creating a Job
{
	auto client = batchClient("claude-sonnet-4-6");
	client.station.spec.concurrencyPolicy = ConcurrencyPolicy.replace;
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	Agent running;
	running.metadata.name = "run-old";
	running.spec.stationRef = "stn";
	running.status.phase = Phase.running;

	const effect = reconcileAgent(client, "ai-agents", pendingAgent("run-b", "stn"), "img", "2026-06-22T12:00:00Z",
		[running], BatchConfig(&providers.make));

	[client.deletedAgents.length, providers.provider.submitted.length, client.createdJobs.length]
		.should.equal([1, 1, 0]);
	effect.preemptedAgent.should.equal("run-old");
}

unittest // pending batch agent with spec.model claude-opus-4-1 submits its request with model claude-opus-4-1
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	auto agent = pendingAgent("run-b", "stn");
	agent.spec.model = "claude-opus-4-1";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null, BatchConfig(&providers.make));

	providers.provider.submitted[0].model.should.equal("claude-opus-4-1");
}

unittest // pending batch agent with spec.model opencode/openai/gpt-5 fails with batch execution does not support opencode models
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	auto agent = pendingAgent("run-b", "stn");
	agent.spec.model = "opencode/openai/gpt-5";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null, BatchConfig(&providers.make));

	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal(
		"batch execution does not support opencode models");
}

unittest // pending gemini batch agent submits with the GEMINI_API_KEY secret and patches Running with batchProvider gemini
{
	import agentcore.crds.secret_ref : SecretRef;

	auto client = batchClient("gemini-3.1-flash-lite");
	client.definition.spec.resources.secrets = [SecretRef("GEMINI_API_KEY", "gemini-key")];
	client.secrets["agent-secrets/gemini-key"] = "gm-test";
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	auto agent = pendingAgent("run-b", "stn");
	agent.metadata.uid = "uid-7";
	agent.spec.parameters = ["ticket": "ENG-1"];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null, BatchConfig(&providers.make));

	providers.vendors.should.equal([Vendor.gemini]);
	providers.apiKeys.should.equal(["gm-test"]);
	providers.provider.submitted.should.equal([
		BatchRequest("gemini-3.1-flash-lite", "Fix ENG-1", Json.undefined, 16_000, "uid-7")
	]);
	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Running",
		"batchId":"msgbatch_1","batchProvider":"gemini","startedAt":"2026-06-22T12:00:00Z"}}`)]);
}

unittest // running gemini batch agent whose poll succeeded patches Succeeded with the gemini lines and posts them to the http sink
{
	import agentcore.batch.gemini : parsePoll, toCliEvents;
	import agentcore.crds.enums : SinkType;
	import agentcore.crds.output_sink : OutputSink;
	import agentcore.crds.secret_ref : SecretRef;
	import agentcore.output.event : EventSource, wrapEvent;
	import std.algorithm : map;
	import std.array : array, join;

	auto client = batchClient("gemini-3.1-flash-lite");
	client.definition.spec.resources.secrets = [SecretRef("GEMINI_API_KEY", "gemini-key")];
	client.secrets["agent-secrets/gemini-key"] = "gm-test";
	client.definition.spec.output.sinks = [OutputSink(SinkType.http, "http://floor/events")];
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = parsePoll(parseJsonString(import("batch/gemini-batch-succeeded.json")));
	FakeSinkPoster poster;
	auto agent = runningBatchAgent("run-b");
	agent.status.batchProvider = "gemini";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:05:00Z", null, sinkConfig(providers, poster));

	const lines = toCliEvents(providers.provider.pollResult, "uid-7");
	client.statusPatches.should.equal([Json(["status": Json([
		"phase": Json("Succeeded"),
		"exitCode": Json(0),
		"output": Json(lines.join("\n")),
		"completedAt": Json("2026-06-22T12:05:00Z"),
	])])]);
	const source = EventSource("run-b", "stn", "", "", "ai-agents");
	poster.posts.should.equal((lines ~ `{"kind":"lifecycle","phase":"agent","status":"succeeded","exitCode":0}`)
		.map!(line => "http://floor/events " ~ wrapEvent(source, line)).array);
}

unittest // pending codex batch agent submits with the OPENAI_API_KEY secret and patches Running with batchProvider openai
{
	import agentcore.crds.secret_ref : SecretRef;

	auto client = batchClient("gpt-5-mini");
	client.definition.spec.resources.secrets = [SecretRef("OPENAI_API_KEY", "openai-key")];
	client.secrets["agent-secrets/openai-key"] = "sk-test";
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	auto agent = pendingAgent("run-b", "stn");
	agent.metadata.uid = "uid-7";
	agent.spec.parameters = ["ticket": "ENG-1"];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null, BatchConfig(&providers.make));

	providers.vendors.should.equal([Vendor.codex]);
	providers.apiKeys.should.equal(["sk-test"]);
	providers.provider.submitted.should.equal([
		BatchRequest("gpt-5-mini", "Fix ENG-1", Json.undefined, 16_000, "uid-7")
	]);
	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Running",
		"batchId":"msgbatch_1","batchProvider":"openai","startedAt":"2026-06-22T12:00:00Z"}}`)]);
}

unittest // running codex batch agent whose poll succeeded patches Succeeded with the codex lines and posts them to the http sink
{
	import agentcore.batch.openai : parsePoll, toCliEvents;
	import agentcore.crds.enums : SinkType;
	import agentcore.crds.output_sink : OutputSink;
	import agentcore.crds.secret_ref : SecretRef;
	import agentcore.output.event : EventSource, wrapEvent;
	import std.algorithm : map;
	import std.array : array, join;

	auto client = batchClient("gpt-5-mini");
	client.definition.spec.resources.secrets = [SecretRef("OPENAI_API_KEY", "openai-key")];
	client.secrets["agent-secrets/openai-key"] = "sk-test";
	client.definition.spec.output.sinks = [OutputSink(SinkType.http, "http://floor/events")];
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = parsePoll(parseJsonString(import("batch/openai-batch-completed.json")),
		import("batch/openai-output-succeeded.json"));
	FakeSinkPoster poster;
	auto agent = runningBatchAgent("run-b");
	agent.status.batchProvider = "openai";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:05:00Z", null, sinkConfig(providers, poster));

	const lines = toCliEvents(providers.provider.pollResult, "uid-7");
	client.statusPatches.should.equal([Json(["status": Json([
		"phase": Json("Succeeded"),
		"exitCode": Json(0),
		"output": Json(lines.join("\n")),
		"completedAt": Json("2026-06-22T12:05:00Z"),
	])])]);
	const source = EventSource("run-b", "stn", "", "", "ai-agents");
	poster.posts.should.equal((lines ~ `{"kind":"lifecycle","phase":"agent","status":"succeeded","exitCode":0}`)
		.map!(line => "http://floor/events " ~ wrapEvent(source, line)).array);
}

unittest // pending batch agent with spec.files fails with batch execution does not support files
{
	import agentcore.crds.input_file : InputFile;

	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	auto agent = pendingAgent("run-b", "stn");
	agent.spec.files = [InputFile("notes/brief.md", "https://files.example.com/brief.md")];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null, BatchConfig(&providers.make));

	[providers.provider.submitted.length].should.equal([0]);
	client.statusPatches[0]["status"]["failureReason"].get!string.should.equal(
		"batch execution does not support files");
}

unittest // succeeded batch Agent whose cleanup fails reports batchCleanupFailed on the effect
{
	auto client = batchClient("claude-sonnet-4-6");
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.cleanupThrows = true;
	auto agent = runningBatchAgent("run-b");
	agent.status.phase = Phase.succeeded;
	agent.metadata.finalizers = [batchCleanupFinalizer];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:10:00Z", null, BatchConfig(&providers.make))
		.batchCleanupFailed.should.equal(true);
}

unittest // pending batch agent whose definition sets batch.maxTokens 2048 submits max tokens 2048
{
	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.batch.maxTokens = 2048;
	auto providers = FakeBatchProviders(new FakeBatchProvider);

	reconcileAgent(client, "ai-agents", pendingAgent("run-b", "stn"), "img", "2026-06-22T12:00:00Z", null,
		BatchConfig(&providers.make));

	providers.provider.submitted[0].maxTokens.should.equal(2048);
}

unittest // pending batch agent whose definition has an empty model submits model claude-opus-5-5
{
	auto client = batchClient("");
	auto providers = FakeBatchProviders(new FakeBatchProvider);

	reconcileAgent(client, "ai-agents", pendingAgent("run-b", "stn"), "img", "2026-06-22T12:00:00Z", null,
		BatchConfig(&providers.make));

	providers.provider.submitted[0].model.should.equal("claude-opus-5-5");
}

unittest // pending batch agent whose definition has an object output.schema submits that schema
{
	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.output.schema = parseJsonString(`{"type":"object"}`);
	auto providers = FakeBatchProviders(new FakeBatchProvider);

	reconcileAgent(client, "ai-agents", pendingAgent("run-b", "stn"), "img", "2026-06-22T12:00:00Z", null,
		BatchConfig(&providers.make));

	providers.provider.submitted[0].schema.should.equal(parseJsonString(`{"type":"object"}`));
}

unittest // pending batch agent on a controller with batch disabled goes Failed "batch execution is disabled on this controller"
{
	auto client = batchClient("claude-sonnet-4-6");

	reconcileAgent(client, "ai-agents", pendingAgent("run-b", "stn"), "img", "2026-06-22T12:00:00Z", null,
		BatchConfig.init);

	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Failed",
		"failureReason":"batch execution is disabled on this controller",
		"completedAt":"2026-06-22T12:00:00Z"}}`)]);
}

unittest // succeeded batch poll posts each translated claude line to the http sink wrapped with the Agent's source, then agent succeeded
{
	import agentcore.batch.anthropic : toCliEvents;
	import agentcore.crds.enums : SinkType;
	import agentcore.crds.output_sink : OutputSink;
	import agentcore.output.event : EventSource, wrapEvent;
	import std.algorithm : map;
	import std.array : array;

	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.output.sinks = [OutputSink(SinkType.http, "http://floor/events")];
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = succeededPoll();
	FakeSinkPoster poster;
	auto agent = runningBatchAgent("run-b");
	agent.spec.taskId = "T-1";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:05:00Z", null, sinkConfig(providers, poster));

	const source = EventSource("run-b", "stn", "T-1", "", "ai-agents");
	poster.posts.should.equal((toCliEvents(succeededPoll(), "uid-7")
		~ `{"kind":"lifecycle","phase":"agent","status":"succeeded","exitCode":0}`)
		.map!(line => "http://floor/events " ~ wrapEvent(source, line)).array);
}

unittest // succeeded batch poll with output.select on result posts only the result line and the lifecycle event
{
	import agentcore.batch.anthropic : toCliEvents;
	import agentcore.crds.enums : SelectEvent, SinkType;
	import agentcore.crds.output_selector : OutputSelector;
	import agentcore.crds.output_sink : OutputSink;
	import agentcore.output.event : EventSource, wrapEvent;
	import std.algorithm : map;
	import std.array : array;

	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.output.sinks = [OutputSink(SinkType.http, "http://floor/events")];
	OutputSelector onResult = {event: SelectEvent.result};
	client.definition.spec.output.select = [onResult];
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = succeededPoll();
	FakeSinkPoster poster;

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T12:05:00Z", null,
		sinkConfig(providers, poster));

	const source = EventSource("run-b", "stn", "", "", "ai-agents");
	poster.posts.should.equal([toCliEvents(succeededPoll(), "uid-7")[$ - 1],
		`{"kind":"lifecycle","phase":"agent","status":"succeeded","exitCode":0}`]
		.map!(line => "http://floor/events " ~ wrapEvent(source, line)).array);
}

unittest // errored batch poll posts agent failed with exitCode 1 and reason batch_failed after its lines
{
	import agentcore.batch.anthropic : parsePoll;
	import agentcore.crds.enums : SinkType;
	import agentcore.crds.output_sink : OutputSink;
	import agentcore.output.event : EventSource, wrapEvent;

	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.output.sinks = [OutputSink(SinkType.http, "http://floor/events")];
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	providers.provider.pollResult = parsePoll(parseJsonString(import("batch/anthropic-batch-ended.json")),
		import("batch/anthropic-result-errored.json"));
	FakeSinkPoster poster;

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T12:05:00Z", null,
		sinkConfig(providers, poster));

	poster.posts[$ - 1].should.equal("http://floor/events " ~ wrapEvent(EventSource("run-b", "stn", "", "", "ai-agents"),
		`{"kind":"lifecycle","phase":"agent","status":"failed","reason":"batch_failed","exitCode":1}`));
}

unittest // timed-out batch with onTimeout fail posts only agent failed with exitCode 1 and reason batch_timeout
{
	import agentcore.crds.enums : SinkType;
	import agentcore.crds.output_sink : OutputSink;
	import agentcore.output.event : EventSource, wrapEvent;

	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.output.sinks = [OutputSink(SinkType.http, "http://floor/events")];
	client.definition.spec.batch.timeoutMinutes = 60;
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	FakeSinkPoster poster;

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T13:00:00Z", null,
		sinkConfig(providers, poster));

	poster.posts.should.equal(["http://floor/events " ~ wrapEvent(EventSource("run-b", "stn", "", "", "ai-agents"),
		`{"kind":"lifecycle","phase":"agent","status":"failed","reason":"batch_timeout","exitCode":1}`)]);
}

unittest // timed-out batch with onTimeout fallback posts only agent running with reason batch_timeout, never a terminal event
{
	import agentcore.crds.enums : BatchTimeoutAction, SinkType;
	import agentcore.crds.output_sink : OutputSink;
	import agentcore.output.event : EventSource, wrapEvent;

	auto client = batchClient("claude-sonnet-4-6");
	client.station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent","image":"node:22"}]}}`);
	client.definition.spec.output.sinks = [OutputSink(SinkType.http, "http://floor/events")];
	client.definition.spec.batch.timeoutMinutes = 60;
	client.definition.spec.batch.onTimeout = BatchTimeoutAction.fallback;
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	FakeSinkPoster poster;

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T13:00:00Z", null,
		sinkConfig(providers, poster));

	poster.posts.should.equal(["http://floor/events " ~ wrapEvent(EventSource("run-b", "stn", "", "", "ai-agents"),
		`{"kind":"lifecycle","phase":"agent","status":"running","reason":"batch_timeout"}`)]);
}

unittest // pending batch agent submit posts agent started after its Running patch
{
	import agentcore.crds.enums : SinkType;
	import agentcore.crds.output_sink : OutputSink;
	import agentcore.output.event : EventSource, wrapEvent;

	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.output.sinks = [OutputSink(SinkType.http, "http://floor/events")];
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	FakeSinkPoster poster;

	reconcileAgent(client, "ai-agents", pendingAgent("run-b", "stn"), "img", "2026-06-22T12:00:00Z", null,
		sinkConfig(providers, poster));

	poster.posts.should.equal(["http://floor/events " ~ wrapEvent(EventSource("run-b", "stn", "", "", "ai-agents"),
		`{"kind":"lifecycle","phase":"agent","status":"started"}`)]);
}

unittest // http sink with headers_secret floor-auth posts with the agent-secrets floor-auth value as headers
{
	import agentcore.crds.enums : SinkType;
	import agentcore.crds.output_sink : OutputSink;

	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.output.sinks = [OutputSink(SinkType.http, "http://floor/events", "floor-auth")];
	client.secrets["agent-secrets/floor-auth"] = "Authorization: Bearer floor-token";
	auto providers = FakeBatchProviders(new FakeBatchProvider);
	FakeSinkPoster poster;

	reconcileAgent(client, "ai-agents", pendingAgent("run-b", "stn"), "img", "2026-06-22T12:00:00Z", null,
		sinkConfig(providers, poster));

	poster.headers.should.equal(["Authorization: Bearer floor-token"]);
}

unittest // running batch agent on a controller with batch disabled patches Failed "batch execution is disabled on this controller"
{
	auto client = batchClient("claude-sonnet-4-6");

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T12:05:00Z", null);

	client.statusPatches.should.equal([parseJsonString(`{"status":{"phase":"Failed",
		"failureReason":"batch execution is disabled on this controller","completedAt":"2026-06-22T12:05:00Z"}}`)]);
}

unittest // running batch agent with the batch-cleanup finalizer on a controller with batch disabled removes the finalizer
{
	auto client = batchClient("claude-sonnet-4-6");
	auto agent = runningBatchAgent("run-b");
	agent.metadata.finalizers = [batchCleanupFinalizer];

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:05:00Z", null);

	client.agentPatches.should.equal([removeFirstFinalizer]);
}

unittest // running batch agent on a controller with batch disabled posts agent failed with exitCode 1 and reason batch_failed
{
	import agentcore.crds.enums : SinkType;
	import agentcore.crds.output_sink : OutputSink;
	import agentcore.output.event : EventSource, wrapEvent;

	auto client = batchClient("claude-sonnet-4-6");
	client.definition.spec.output.sinks = [OutputSink(SinkType.http, "http://floor/events")];
	FakeSinkPoster poster;
	BatchConfig batchDisabled;
	batchDisabled.postSink = &poster.post;

	reconcileAgent(client, "ai-agents", runningBatchAgent("run-b"), "img", "2026-06-22T12:05:00Z", null,
		batchDisabled);

	poster.posts.should.equal(["http://floor/events " ~ wrapEvent(EventSource("run-b", "stn", "", "", "ai-agents"),
		`{"kind":"lifecycle","phase":"agent","status":"failed","reason":"batch_failed","exitCode":1}`)]);
}

unittest // deleted batch Agent with the batch-cleanup finalizer on a controller with batch disabled removes the finalizer
{
	auto client = batchClient("claude-sonnet-4-6");
	auto agent = runningBatchAgent("run-b");
	agent.metadata.finalizers = [batchCleanupFinalizer];
	agent.metadata.deletionTimestamp = "2026-06-22T12:03:00Z";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:05:00Z", null);

	client.agentPatches.should.equal([removeFirstFinalizer]);
}

version (unittest)
{
	/// The status a Pending Agent resuming `resumeSession` is patched to, on a controller
	/// with `realtime` config, when its definition is built by `define`.
	private Json realtimeOutcome(void delegate(ref AgentDefinitionSpec) define, string resumeSession,
		RealtimeConfig realtime)
	{
		auto client = new FakeKubeClient;
		client.station.metadata.name = "stn";
		client.station.spec.agentDefRef = "def";
		client.station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent"}]}}`);
		client.definition.spec.model = "claude-sonnet-4-6";
		client.definition.spec.prompt = "Fix it";
		define(client.definition.spec);
		Agent agent;
		agent.metadata.name = "run-rt";
		agent.spec.stationRef = "stn";
		agent.spec.resumeSession = resumeSession;
		agent.status.phase = Phase.pending;

		reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null, BatchConfig.init, realtime);
		return client.statusPatches[0]["status"];
	}

	private void realtimeFrom(ref AgentDefinitionSpec spec)
	{
		spec.execution = Execution.realtime;
		spec.resources.conversation.source = "https://conv.example";
	}
}

unittest // pending realtime agent on a controller without a signing key goes Failed "realtime execution is disabled on this controller"
{
	realtimeOutcome((ref s) { realtimeFrom(s); }, "", RealtimeConfig.init)["failureReason"].get!string
		.should.equal("realtime execution is disabled on this controller");
}

unittest // pending agent with resumeSession on an interactive definition goes Failed "resumeSession requires realtime execution"
{
	realtimeOutcome((ref s) {}, "sess-1", RealtimeConfig("key"))["failureReason"].get!string
		.should.equal("resumeSession requires realtime execution");
}

unittest // pending realtime agent resuming without a conversation source goes Failed "resumeSession needs resources.conversation.source"
{
	realtimeOutcome((ref s) { s.execution = Execution.realtime; }, "sess-1", RealtimeConfig("key"))["failureReason"]
		.get!string.should.equal("resumeSession needs resources.conversation.source");
}

unittest // pending realtime opencode agent resuming a session goes Failed "opencode cannot resume a session"
{
	realtimeOutcome((ref s) { realtimeFrom(s); s.model = "opencode/anthropic/claude-sonnet-4"; }, "sess-1",
		RealtimeConfig("key"))["failureReason"].get!string.should.equal("opencode cannot resume a session");
}

unittest // pending realtime claude agent resuming a session on an enabled controller goes Running
{
	realtimeOutcome((ref s) { realtimeFrom(s); }, "sess-1", RealtimeConfig("key"))["phase"].get!string
		.should.equal("Running");
}

unittest // a realtime run's Job carries the token derived from the Agent's uid under the signing key
{
	auto client = new FakeKubeClient;
	client.station.metadata.name = "stn";
	client.station.spec.agentDefRef = "def";
	client.station.spec.template_ = parseJsonString(`{"spec":{"containers":[{"name":"agent"}]}}`);
	realtimeFrom(client.definition.spec);
	Agent agent = pendingAgent("run-rt", "stn");
	agent.metadata.uid = "uid-rt";

	reconcileAgent(client, "ai-agents", agent, "img", "2026-06-22T12:00:00Z", null, BatchConfig.init,
		RealtimeConfig("key"));

	client.createdJobs.should.equal([buildJob(agent, client.station, client.definition, "img",
		runToken("key", "uid-rt"))]);
}
