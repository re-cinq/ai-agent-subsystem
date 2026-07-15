module agentcore.kube.jobspec;

import std.exception : enforce;
import vibe.data.json;

import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.output_selector : OutputSelector;
import agentcore.crds.output_sink : OutputSink;
import agentcore.crds.enums : SinkType;
import agentcore.crds.repo_ref : RepoRef;
import agentcore.crds.station : Station;
import agentcore.crds.serialization : toJson;
import agentcore.vendors.select : agentForModel;
import agentcore.kube.bundle : bundleRoot, supervisorPath;
import agentcore.core.env;
import agentcore.kube.jobs : jobNameFor, safeName;
import agentcore.core.prompt : renderPrompt;

enum crApiVersion = "agents.re-cinq.com/v1alpha1";
enum agentContainerName = "agent";
enum initContainerName = "init";
enum bundleVolume = "agent";

/// Labels stamped on every run pod. `component=job` is the selector the
/// `agent-job-egress` NetworkPolicy matches on — without it the policy matches no
/// pods and the untrusted agent code gets unrestricted egress. The agent/station
/// labels make a run's pod traceable with `kubectl get pods -l`.
enum labelComponent = "agents.re-cinq.com/component";
enum labelAgent = "agents.re-cinq.com/agent";
enum labelStation = "agents.re-cinq.com/station";
enum componentJob = "job";

/// How long a finished Job (and its pod) lingers before the TTL-after-finished GC
/// removes it. The controller reads the pod's exit code + captured stdout back into
/// the Agent status on the terminal transition, so this is the window it has to
/// observe a finished run. One hour comfortably survives a controller restart or
/// backlog; the trade-off is that finished pods linger that long (terminal, so only
/// an etcd object + node log disk — no CPU/memory), and history pruning already
/// cascade-deletes most of them sooner. Past the window the run is reported terminal
/// with a clear `failureReason` rather than silently losing the output.
enum jobTtlSeconds = 3600;

/// The non-root identity the agent container runs as. A concrete UID/GID (not
/// just `runAsNonRoot`) is required or the kubelet rejects a root-by-default base
/// image; `fsGroup` makes the shared bundle writable across the root init
/// container and the non-root main container.
enum agentUid = 1000;
enum agentGid = 1000;

/// The single namespace Secret the controller reads run credentials from. Each
/// `resources.secrets[].ref` is a key inside it (e.g. ANTHROPIC_API_KEY); the
/// operator creates the Secret out-of-band and kubelet resolves the keyRef at pod
/// start, so the controller needs no Secret read permission.
enum agentSecretName = "agent-secrets";

/**
 * Build the `batch/v1` Job the controller creates for one Agent run. Pure: the
 * driver hands in the resolved Station + AgentDefinition and the agent image
 * whose init container injects the runtime, and this assembles the Job JSON with
 * no I/O. It starts from the Station's `PodTemplateSpec`, overrides the container
 * named `agent` to run the supervisor + the adapter's argv, injects the run env,
 * and adds the init container, the bundle volume, and the security contexts.
 */
Json buildJob(Agent agent, Station station, AgentDefinition definition, string agentImage)
{
	auto recipe = definition.spec;
	const prompt = renderPrompt(recipe.prompt, agent.spec.parameters);
	auto argv = agentForModel(recipe.model).command(recipe, prompt);
	auto env = runEnv(agent, station, recipe);

	auto template_ = wirePodTemplate(deepCopy(station.spec.template_), commandFor(argv), env, agentImage);
	template_ = withRunLabels(template_, agent, station);

	// A deadlineMinutes of 0 (explicitly set, or slipped past the schema-only @Minimum)
	// would render activeDeadlineSeconds 0, which the Job controller treats as an
	// already-exceeded deadline and fails the run instantly. Hold it to at least a minute.
	const deadlineMinutes = station.spec.deadlineMinutes < 1 ? 1 : station.spec.deadlineMinutes;

	Json[string] spec;
	spec["ttlSecondsAfterFinished"] = Json(jobTtlSeconds);
	spec["activeDeadlineSeconds"] = Json(long(deadlineMinutes) * 60);
	spec["backoffLimit"] = Json(0);
	spec["template"] = template_;

	Json[string] job;
	job["apiVersion"] = Json("batch/v1");
	job["kind"] = Json("Job");
	job["metadata"] = jobMeta(agent);
	job["spec"] = Json(spec);
	return Json(job);
}

private Json deepCopy(Json value)
{
	return parseJsonString(value.toString());
}

/// Merge the run labels into the pod template's `metadata.labels`, preserving any
/// labels the Station's template already carries (ours win on the run keys).
private Json withRunLabels(Json template_, Agent agent, Station station)
{
	auto pod = template_;
	Json meta = ("metadata" in pod && pod["metadata"].type == Json.Type.object)
		? pod["metadata"] : Json.emptyObject;
	Json labels = ("labels" in meta && meta["labels"].type == Json.Type.object)
		? meta["labels"] : Json.emptyObject;
	labels[labelComponent] = componentJob;
	labels[labelAgent] = safeName(agent.metadata.name);
	labels[labelStation] = safeName(station.metadata.name);
	meta["labels"] = labels;
	pod["metadata"] = meta;
	return pod;
}

private Json jobMeta(Agent agent)
{
	Json[string] owner;
	owner["apiVersion"] = Json(crApiVersion);
	owner["kind"] = Json("Agent");
	owner["name"] = Json(agent.metadata.name);
	owner["uid"] = Json(agent.metadata.uid);
	owner["controller"] = Json(true);
	owner["blockOwnerDeletion"] = Json(true);

	Json[string] meta;
	meta["name"] = Json(jobNameFor(agent.metadata.name));
	meta["namespace"] = Json(agent.metadata.namespace);
	meta["ownerReferences"] = Json([Json(owner)]);
	return Json(meta);
}

private Json[] commandFor(string[] argv)
{
	Json[] command = [Json(supervisorPath), Json("--")];
	foreach (arg; argv)
		command ~= Json(arg);
	return command;
}

private Json wirePodTemplate(Json template_, Json[] command, Json env, string agentImage)
{
	enforce(template_.type == Json.Type.object, "Station template must be an object");
	auto pod = template_;
	enforce("spec" in pod, "Station template needs a spec");
	auto spec = pod["spec"];
	enforce(spec.type == Json.Type.object && ("containers" in spec),
		"Station template.spec.containers is required");

	Json[] containers;
	bool wired = false;
	foreach (container; spec["containers"].get!(Json[]))
	{
		if (isAgentContainer(container))
		{
			container["command"] = Json(command);
			container["env"] = env;
			container["volumeMounts"] = withBundleMount(container);
			container["securityContext"] = nonRootSecurity();
			if (!("resources" in container))
				container["resources"] = agentResources();
			wired = true;
		}
		containers ~= container;
	}
	enforce(wired, "Station template has no container named '" ~ agentContainerName ~ "'");

	spec["containers"] = Json(containers);
	spec["initContainers"] = Json([initContainer(agentImage, env)]);
	spec["volumes"] = withBundleVolume(spec);
	spec["restartPolicy"] = Json("Never");
	spec["securityContext"] = podSecurity();
	// The run needs no Kubernetes API access; don't mount a SA token into a pod that
	// executes untrusted agent code.
	spec["automountServiceAccountToken"] = Json(false);

	pod["spec"] = spec;
	return pod;
}

private bool isAgentContainer(Json container)
{
	return container.type == Json.Type.object && ("name" in container)
		&& container["name"].get!string == agentContainerName;
}

private Json withBundleMount(Json container)
{
	Json[] mounts;
	if (auto existing = "volumeMounts" in container)
		if (existing.type == Json.Type.array)
			foreach (m; (*existing).get!(Json[]))
				if (!isNamed(m, bundleVolume))
					mounts ~= m;
	Json[string] mount;
	mount["name"] = Json(bundleVolume);
	mount["mountPath"] = Json(bundleRoot);
	mounts ~= Json(mount);
	return Json(mounts);
}

/// Whether `entry` is an object with a `name` field equal to `name`. Used to drop a
/// Station-supplied volume/mount that collides with the bundle's reserved `agent`
/// name so the assembled pod carries exactly one — the kubelet rejects duplicates.
private bool isNamed(Json entry, string name)
{
	return entry.type == Json.Type.object && ("name" in entry)
		&& entry["name"].type == Json.Type.string && entry["name"].get!string == name;
}

private Json withBundleVolume(Json spec)
{
	Json[] volumes;
	if (auto existing = "volumes" in spec)
		if (existing.type == Json.Type.array)
			foreach (v; (*existing).get!(Json[]))
				if (!isNamed(v, bundleVolume))
					volumes ~= v;
	Json[string] volume;
	volume["name"] = Json(bundleVolume);
	volume["emptyDir"] = Json.emptyObject;
	volumes ~= Json(volume);
	return Json(volumes);
}

private Json initContainer(string agentImage, Json env)
{
	Json[string] mount;
	mount["name"] = Json(bundleVolume);
	mount["mountPath"] = Json(bundleRoot);

	Json[string] security;
	security["runAsUser"] = Json(0);

	Json[string] container;
	container["name"] = Json(initContainerName);
	container["image"] = Json(agentImage);
	container["env"] = env;
	container["volumeMounts"] = Json([Json(mount)]);
	container["securityContext"] = Json(security);
	container["resources"] = initResources();
	return Json(container);
}

private Json nonRootSecurity()
{
	Json[string] caps;
	caps["drop"] = Json([Json("ALL")]);

	Json[string] security;
	security["runAsNonRoot"] = Json(true);
	security["runAsUser"] = Json(agentUid);
	security["runAsGroup"] = Json(agentGid);
	security["allowPrivilegeEscalation"] = Json(false);
	security["capabilities"] = Json(caps);
	security["seccompProfile"] = runtimeDefaultSeccomp();
	return Json(security);
}

private Json podSecurity()
{
	Json[string] security;
	security["fsGroup"] = Json(agentGid);
	security["seccompProfile"] = runtimeDefaultSeccomp();
	return Json(security);
}

private Json runtimeDefaultSeccomp()
{
	Json[string] seccomp;
	seccomp["type"] = Json("RuntimeDefault");
	return Json(seccomp);
}

/// Default requests/limits for the agent container when the Station template sets
/// none, so an untrusted run is Burstable (not BestEffort) and memory-bounded — it
/// cannot starve the node. An operator overrides by setting `resources` on the
/// Station's agent container. No CPU limit: a memory limit gives OOM protection
/// without throttling legitimate agent work.
private Json agentResources()
{
	Json[string] requests;
	requests["cpu"] = Json("100m");
	requests["memory"] = Json("256Mi");
	Json[string] limits;
	limits["memory"] = Json("2Gi");
	Json[string] resources;
	resources["requests"] = Json(requests);
	resources["limits"] = Json(limits);
	return Json(resources);
}

/// Requests/limits for the init container so it is Burstable, not BestEffort — a
/// BestEffort init is the kernel OOM-killer's first target under node memory
/// pressure. The limit must cover the real agent's prerequisite install: the
/// Claude CLI installer (curl https://claude.ai/install.sh | bash) runs a native
/// binary whose `install` step embeds a JS runtime and peaks past 512Mi, so the
/// request stays modest while the limit gives that transient spike real headroom.
/// The mock agent bakes its CLI in and never installs, which is why CI did not
/// surface the OOM.
private Json initResources()
{
	Json[string] requests;
	requests["cpu"] = Json("50m");
	requests["memory"] = Json("128Mi");
	Json[string] limits;
	limits["memory"] = Json("2Gi");
	Json[string] resources;
	resources["requests"] = Json(requests);
	resources["limits"] = Json(limits);
	return Json(resources);
}

private Json runEnv(Agent agent, Station station, AgentDefinitionSpec recipe)
{
	Json[] env;

	void strVar(string name, string value)
	{
		Json[string] entry;
		entry["name"] = Json(name);
		entry["value"] = Json(value);
		env ~= Json(entry);
	}

	void fieldVar(string name, string fieldPath)
	{
		Json[string] fieldRef;
		fieldRef["fieldPath"] = Json(fieldPath);
		Json[string] from;
		from["fieldRef"] = Json(fieldRef);
		Json[string] entry;
		entry["name"] = Json(name);
		entry["valueFrom"] = Json(from);
		env ~= Json(entry);
	}

	void secretVar(string name, string key)
	{
		Json[string] keyRef;
		keyRef["name"] = Json(agentSecretName);
		keyRef["key"] = Json(key);
		keyRef["optional"] = Json(false);
		Json[string] from;
		from["secretKeyRef"] = Json(keyRef);
		Json[string] entry;
		entry["name"] = Json(name);
		entry["valueFrom"] = Json(from);
		env ~= Json(entry);
	}

	// An http sink's `headers_secret` names a key in the agent-secrets Secret holding the
	// auth headers, injected below as an env var of the same name. A name colliding with a
	// controller-owned var is dropped up front — on the serialized sinks too, not just the
	// env injection: otherwise the pod's `sinkHeaders()` would still resolve that reserved
	// name from the environment (where it holds the controller's value) and post it to the
	// sink as an auth header. Blanking it here makes pod-side resolution return "".
	auto sinks = recipe.output.sinks.dup;
	foreach (ref sink; sinks)
		if (sink.type == SinkType.http && isReservedEnvName(sink.headersSecret))
			sink.headersSecret = "";

	strVar(envSinks, sinksJson(sinks));
	bool[string] secretsInjected;
	foreach (sink; sinks)
		if (sink.type == SinkType.http && sink.headersSecret.length
			&& sink.headersSecret !in secretsInjected)
		{
			secretVar(sink.headersSecret, sink.headersSecret);
			secretsInjected[sink.headersSecret] = true;
		}
	strVar(envRepos, reposJson(recipe.resources.repos));
	// A repo's token_secret names an agent-secrets key holding its git credential; inject it
	// as a secretKeyRef env of the same name so the init container's clone authenticates.
	// Without it the clone runs with an empty token and fails "Invalid username or token".
	foreach (repo; recipe.resources.repos)
		if (repo.tokenSecret.length && !isReservedEnvName(repo.tokenSecret)
			&& repo.tokenSecret !in secretsInjected)
		{
			secretVar(repo.tokenSecret, repo.tokenSecret);
			secretsInjected[repo.tokenSecret] = true;
		}
	if (recipe.output.select.length)
		strVar(envSelect, selectJson(recipe.output.select));
	strVar(envWorkspace, defaultWorkspace);
	if (agent.spec.parameters.length)
		strVar(envParameters, parametersJson(agent.spec.parameters));
	if (agent.spec.targetRepo.length)
		strVar(envTargetRepo, agent.spec.targetRepo);
	if (agent.spec.branch.length)
		strVar(envBranch, agent.spec.branch);
	strVar(envModel, recipe.model);
	strVar(envAgentName, agent.metadata.name);
	strVar(envStationName, station.metadata.name);
	strVar(envTaskId, agent.spec.taskId);
	fieldVar(envPodName, "metadata.name");
	fieldVar(envPodNamespace, "metadata.namespace");
	// Recipe env/secrets come last, but a recipe entry that reuses a controller-owned
	// name would emit a duplicate the kubelet resolves last-wins — silently redirecting
	// output (AGENT_SINKS), spoofing run identity (AGENT_NAME), or breaking the workspace.
	// Skip any such collision so the controller's value always wins.
	foreach (variable; recipe.resources.env)
		if (!isReservedEnvName(variable.name))
			strVar(variable.name, variable.value);
	foreach (secret; recipe.resources.secrets)
		if (!isReservedEnvName(secret.name) && secret.name !in secretsInjected)
		{
			secretVar(secret.name, secret.ref_);
			secretsInjected[secret.name] = true;
		}
	strVar(homeEnv, bundleRoot);
	strVar(pathEnv, "/agent/.local/bin:/usr/local/bin:/usr/bin:/bin");
	return Json(env);
}

/// Env var names the controller owns in a run container. A recipe may not override
/// these — a collision is dropped so the controller's injected value stands.
enum homeEnv = "HOME";
enum pathEnv = "PATH";

bool isReservedEnvName(string name) @safe pure nothrow
{
	static immutable string[] reserved = [
		envSinks, envRepos, envSelect, envWorkspace, envParameters, envTargetRepo,
		envBranch, envModel, envAgentName, envStationName, envTaskId, envPodName,
		envPodNamespace, homeEnv, pathEnv,
	];
	foreach (owned; reserved)
		if (name == owned)
			return true;
	return false;
}

// The controller→pod env wire (AGENT_SINKS / AGENT_SELECT / AGENT_REPOS) is produced
// straight from the CRD structs via the policy serializer, so it is exactly the shape
// the pod's `fromJson` parsers read back — no hand-maintained field list to drift, which
// is how `headers_secret` and `role` were previously dropped at this seam.
private string sinksJson(const OutputSink[] sinks)
{
	return toJson(sinks).toString();
}

private string selectJson(const OutputSelector[] selectors)
{
	return toJson(selectors).toString();
}

private string reposJson(const RepoRef[] repos)
{
	return toJson(repos).toString();
}

private string parametersJson(const string[string] parameters)
{
	Json[string] object;
	foreach (key, value; parameters)
		object[key] = Json(value);
	return Json(object).toString();
}

version (unittest)
{
	import fluent.asserts;
	import agentcore.crds.enums : SelectEvent;
	import agentcore.crds.env_var : EnvVar;
	import agentcore.crds.output_selector : OutputSelector;
	import agentcore.crds.secret_ref : SecretRef;
	import agentcore.output.output : parseSinks;
	import agentcore.output.selectmatcher : parseSelectors;

	private Json agentContainer(Json job)
	{
		foreach (container; job["spec"]["template"]["spec"]["containers"].get!(Json[]))
			if (container["name"].get!string == agentContainerName)
				return container;
		assert(false, "no agent container");
	}

	private string envValue(Json container, string name)
	{
		foreach (entry; container["env"].get!(Json[]))
			if (entry["name"].get!string == name && ("value" in entry))
				return entry["value"].get!string;
		return "";
	}

	private string envFieldPath(Json container, string name)
	{
		foreach (entry; container["env"].get!(Json[]))
			if (entry["name"].get!string == name && ("valueFrom" in entry))
				return entry["valueFrom"]["fieldRef"]["fieldPath"].get!string;
		return "";
	}

	private string envSecretKey(Json container, string name)
	{
		foreach (entry; container["env"].get!(Json[]))
			if (entry["name"].get!string == name && ("valueFrom" in entry)
				&& ("secretKeyRef" in entry["valueFrom"]))
				return entry["valueFrom"]["secretKeyRef"]["key"].get!string;
		return "";
	}

	private void fixtures(out Agent agent, out Station station, out AgentDefinition definition)
	{
		agent.metadata.name = "bug-fixer-run-1";
		agent.metadata.namespace = "ai-agents";
		agent.metadata.uid = "uid-123";
		agent.spec.stationRef = "bug-fixer-station";
		agent.spec.taskId = "T-1";
		agent.spec.parameters = ["ticket": "ENG-1"];

		station.metadata.name = "bug-fixer-station";
		station.spec.agentDefRef = "bug-fixer";
		station.spec.deadlineMinutes = 30;
		station.spec.template_ = parseJsonString(
			`{"spec":{"containers":[{"name":"agent","image":"node:22"},{"name":"sidecar","image":"busybox"}]}}`);

		definition.metadata.name = "bug-fixer";
		definition.spec.model = "claude-sonnet-4-6";
		definition.spec.prompt = "Fix {ticket}";
		definition.spec.output.sinks = [OutputSink(SinkType.http, "http://collector")];
		definition.spec.resources.env = [EnvVar("LOG_LEVEL", "debug")];
		definition.spec.resources.secrets = [SecretRef("ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY")];
		definition.spec.output.select = [OutputSelector(SelectEvent.result)];
	}
}

unittest
{
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);

	auto job = buildJob(agent, station, definition, "ghcr.io/re-cinq/ai-agent:latest");

	job["apiVersion"].get!string.should.equal("batch/v1");
	job["kind"].get!string.should.equal("Job");
	job["metadata"]["name"].get!string.should.equal("agent-job-bug-fixer-run-1");
	job["metadata"]["namespace"].get!string.should.equal("ai-agents");

	auto owner = job["metadata"]["ownerReferences"][0];
	owner["kind"].get!string.should.equal("Agent");
	owner["name"].get!string.should.equal("bug-fixer-run-1");
	owner["uid"].get!string.should.equal("uid-123");
	owner["controller"].get!bool.should.equal(true);
	owner["blockOwnerDeletion"].get!bool.should.equal(true);

	job["spec"]["ttlSecondsAfterFinished"].get!long.should.equal(3600);
	job["spec"]["activeDeadlineSeconds"].get!long.should.equal(1800);
	job["spec"]["backoffLimit"].get!long.should.equal(0);
}

unittest
{
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);

	auto job = buildJob(agent, station, definition, "ghcr.io/re-cinq/ai-agent:latest");
	auto pod = job["spec"]["template"]["spec"];

	pod["restartPolicy"].get!string.should.equal("Never");
	// Both containers are preserved; the sidecar is untouched.
	pod["containers"].get!(Json[]).length.should.equal(2);
	pod["initContainers"][0]["image"].get!string.should.equal("ghcr.io/re-cinq/ai-agent:latest");
	pod["initContainers"][0]["securityContext"]["runAsUser"].get!long.should.equal(0);
	// The init must not be BestEffort, or the kernel OOM-kills it first under pressure.
	pod["initContainers"][0]["resources"]["requests"]["memory"].get!string.should.equal("128Mi");
	pod["volumes"][0]["name"].get!string.should.equal(bundleVolume);

	auto container = agentContainer(job);
	auto command = container["command"].get!(Json[]);
	command[0].get!string.should.equal(supervisorPath);
	command[1].get!string.should.equal("--");
	command[2].get!string.should.equal("claude");
	command[$ - 1].get!string.should.equal("Fix ENG-1"); // rendered prompt baked in
	container["securityContext"]["runAsNonRoot"].get!bool.should.equal(true);
	// A concrete non-root UID/GID is required, else the kubelet rejects a root image.
	container["securityContext"]["runAsUser"].get!long.should.equal(1000);
	pod["securityContext"]["fsGroup"].get!long.should.equal(1000);
}

unittest
{
	// The run pod must carry the `component: job` label the NetworkPolicy selects on,
	// or the policy matches nothing and untrusted agent code gets unrestricted egress.
	// The agent/station identifiers make a run's pod traceable from `kubectl get pods -l`.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);

	auto labels = buildJob(agent, station, definition, "img")["spec"]["template"]["metadata"]["labels"];
	labels["agents.re-cinq.com/component"].get!string.should.equal("job");
	labels["agents.re-cinq.com/agent"].get!string.should.equal("bug-fixer-run-1");
	labels["agents.re-cinq.com/station"].get!string.should.equal("bug-fixer-station");
}

unittest
{
	// #126: a Station pod template with an explicit null metadata, and a volume/mount
	// already named "agent", must not throw a raw Json error or emit a duplicate "agent"
	// name (the kubelet rejects duplicate volume/mount names). Labels still apply, and
	// exactly one bundle volume + mount survives, at the bundle path.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);
	station.spec.template_ = parseJsonString(
		`{"metadata":null,"spec":{"containers":[{"name":"agent","image":"node:22",`
		~ `"volumeMounts":[{"name":"agent","mountPath":"/somewhere"}]}],`
		~ `"volumes":[{"name":"agent","emptyDir":{}}]}}`);

	auto job = buildJob(agent, station, definition, "img");

	job["spec"]["template"]["metadata"]["labels"]["agents.re-cinq.com/component"]
		.get!string.should.equal("job");

	auto pod = job["spec"]["template"]["spec"];
	int agentVolumes;
	foreach (v; pod["volumes"].get!(Json[]))
		if (v["name"].get!string == "agent")
			agentVolumes++;
	agentVolumes.should.equal(1);

	int agentMounts;
	string mountPath;
	foreach (m; agentContainer(job)["volumeMounts"].get!(Json[]))
		if (m["name"].get!string == "agent")
		{
			agentMounts++;
			mountPath = m["mountPath"].get!string;
		}
	agentMounts.should.equal(1);
	mountPath.should.equal(bundleRoot);
}

unittest
{
	// #126: every template node that can be an explicit JSON null — metadata.labels, the
	// agent container's volumeMounts, and the pod spec's volumes — is handled without a raw
	// Json throw, and the run still gets its label plus the bundle volume/mount.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);
	station.spec.template_ = parseJsonString(
		`{"metadata":{"labels":null},"spec":{"containers":[{"name":"agent","image":"node:22",`
		~ `"volumeMounts":null}],"volumes":null}}`);

	auto job = buildJob(agent, station, definition, "img");

	job["spec"]["template"]["metadata"]["labels"]["agents.re-cinq.com/component"]
		.get!string.should.equal("job");
	job["spec"]["template"]["spec"]["volumes"].get!(Json[]).length.should.equal(1);
	agentContainer(job)["volumeMounts"].get!(Json[]).length.should.equal(1);
}

unittest
{
	// The run pod must not mount a ServiceAccount token: the run needs no API access,
	// and a mounted token is a live credential exposed to the untrusted agent code.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);

	auto pod = buildJob(agent, station, definition, "img")["spec"]["template"]["spec"];
	pod["automountServiceAccountToken"].get!bool.should.equal(false);
}

unittest
{
	// #115: a deadlineMinutes of 0 must not render activeDeadlineSeconds 0, which the Job
	// controller treats as an already-exceeded deadline and fails the run instantly.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);
	station.spec.deadlineMinutes = 0;

	auto job = buildJob(agent, station, definition, "img");
	job["spec"]["activeDeadlineSeconds"].get!long.should.equal(60);
}

unittest
{
	// #115: a very large deadlineMinutes must not overflow `int * 60` into a negative
	// activeDeadlineSeconds, which the API server rejects on every reconcile. Widening to
	// long keeps it a huge-but-positive value the API server accepts.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);
	station.spec.deadlineMinutes = int.max;

	auto job = buildJob(agent, station, definition, "img");
	job["spec"]["activeDeadlineSeconds"].get!long.should.equal(long(int.max) * 60);
}

unittest
{
	// The untrusted agent container is hardened: seccomp RuntimeDefault, every Linux
	// capability dropped, and (when the Station sets none) default resource bounds so
	// it is Burstable, not BestEffort, and cannot starve the node.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);

	auto job = buildJob(agent, station, definition, "img");
	auto container = agentContainer(job);
	auto podSec = job["spec"]["template"]["spec"]["securityContext"];

	container["securityContext"]["seccompProfile"]["type"].get!string.should.equal("RuntimeDefault");
	container["securityContext"]["capabilities"]["drop"][0].get!string.should.equal("ALL");
	podSec["seccompProfile"]["type"].get!string.should.equal("RuntimeDefault");

	container["resources"]["requests"]["memory"].get!string.should.equal("256Mi");
	container["resources"]["limits"]["memory"].get!string.should.equal("2Gi");
}

unittest
{
	// A Station that sets the agent container's resources keeps them — the default
	// only fills in when the operator specified none.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);
	station.spec.template_ = parseJsonString(
		`{"spec":{"containers":[{"name":"agent","image":"node:22","resources":{"limits":{"memory":"512Mi"}}}]}}`);

	auto container = agentContainer(buildJob(agent, station, definition, "img"));
	container["resources"]["limits"]["memory"].get!string.should.equal("512Mi");
}

unittest
{
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);
	agent.spec.targetRepo = "octo/app";
	agent.spec.branch = "fix/eng-1";

	auto container = agentContainer(buildJob(agent, station, definition, "img"));

	envValue(container, "AGENT_NAME").should.equal("bug-fixer-run-1");
	envValue(container, "STATION_NAME").should.equal("bug-fixer-station");
	envValue(container, "AGENT_MODEL").should.equal("claude-sonnet-4-6"); // init routes the agent CLI off this
	envValue(container, "TASK_ID").should.equal("T-1");
	envValue(container, "TARGET_REPO").should.equal("octo/app");
	envValue(container, "BRANCH_NAME").should.equal("fix/eng-1");
	envFieldPath(container, "POD_NAME").should.equal("metadata.name");
	envFieldPath(container, "POD_NAMESPACE").should.equal("metadata.namespace");

	// AGENT_SINKS round-trips through the supervisor's own parser.
	auto sinks = parseSinks(envValue(container, "AGENT_SINKS"));
	sinks.length.should.equal(1);
	sinks[0].type.should.equal(SinkType.http);
	sinks[0].url.should.equal("http://collector");
}

unittest
{
	// The recipe's resources.env land as literal env; resources.secrets land as a
	// secretKeyRef into the namespace `agent-secrets` Secret (key = the ref).
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);

	auto container = agentContainer(buildJob(agent, station, definition, "img"));

	envValue(container, "LOG_LEVEL").should.equal("debug");
	envSecretKey(container, "ANTHROPIC_API_KEY").should.equal("ANTHROPIC_API_KEY");

	// output.select is injected as AGENT_SELECT and round-trips for the supervisor.
	auto selectors = parseSelectors(envValue(container, "AGENT_SELECT"));
	selectors.length.should.equal(1);
	selectors[0].event.should.equal(SelectEvent.result);
}

unittest
{
	// A repo's token_secret names the agent-secrets key holding its git credential, and
	// must be injected as a secretKeyRef env of the same name — the init container's clone
	// reads `$<token_secret>` for auth. Without the env the clone runs with an empty token
	// and fails ("Invalid username or token"). The field is a credential channel, not just
	// AGENT_REPOS metadata.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);
	definition.spec.resources.repos = [
		RepoRef("target", "https://github.com/octo/app.git", "main", "", "GH_TOKEN_abc12345"),
	];

	auto container = agentContainer(buildJob(agent, station, definition, "img"));

	envSecretKey(container, "GH_TOKEN_abc12345").should.equal("GH_TOKEN_abc12345");
}

unittest
{
	// An http sink's headers_secret survives the controller→pod seam both ways: it
	// round-trips on AGENT_SINKS, and its named Secret key is injected as an env var of
	// the same name so the pod's sink delivery can resolve the auth headers at runtime.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);
	definition.spec.output.sinks = [OutputSink(SinkType.http, "http://collector", "SINK_HEADERS")];

	auto container = agentContainer(buildJob(agent, station, definition, "img"));

	auto sinks = parseSinks(envValue(container, "AGENT_SINKS"));
	sinks.length.should.equal(1);
	sinks[0].headersSecret.should.equal("SINK_HEADERS");
	// The header Secret key is injected as an env var so deliverSinks can read it.
	envSecretKey(container, "SINK_HEADERS").should.equal("SINK_HEADERS");
}

unittest
{
	// #137: an http sink's headers_secret that reuses a controller-owned env name must not
	// shadow the real value — the collision is dropped like any other reserved-name reuse.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);
	definition.spec.output.sinks = [OutputSink(SinkType.http, "http://collector", "AGENT_SINKS")];

	auto container = agentContainer(buildJob(agent, station, definition, "img"));

	// Exactly one AGENT_SINKS entry, and it is the controller's literal sinks value —
	// not a secretKeyRef injected from the colliding header secret.
	int sinksEntries;
	foreach (entry; container["env"].get!(Json[]))
		if (entry["name"].get!string == "AGENT_SINKS")
			sinksEntries++;
	sinksEntries.should.equal(1);
	auto sinks = parseSinks(envValue(container, "AGENT_SINKS"));
	sinks.length.should.equal(1);
	// The serialized sink no longer carries the reserved name, so pod-side sinkHeaders()
	// can't resolve the controller-owned AGENT_SINKS value and post it as an auth header.
	sinks[0].headersSecret.should.equal("");
}

unittest
{
	// Round-trip across the parse/build seam: API-shaped JSON through the
	// production parsers into buildJob. The run pod must carry the recipe's
	// secretKeyRef env, literal env, and AGENT_SELECT — the exact fields a
	// hand-maintained parser dropped while struct-built fixtures stayed green (#85).
	import agentcore.kube.jsonbody : parseAgentDefinition, parseStation;

	Agent agent;
	agent.metadata.name = "secret-run";
	agent.metadata.namespace = "ai-agents";

	auto station = parseStation(parseJsonString(`{
		"metadata":{"name":"secret-station","namespace":"ai-agents"},
		"spec":{"agentDefRef":"secret-writer","deadlineMinutes":5,
			"template":{"spec":{"containers":[{"name":"agent","image":"ai-agent:itest"}]}}}}`));
	auto definition = parseAgentDefinition(parseJsonString(`{
		"metadata":{"name":"secret-writer"},
		"spec":{"model":"gpt-mock","prompt":"say hello",
			"resources":{
				"secrets":[{"name":"ANTHROPIC_API_KEY","ref":"ANTHROPIC_API_KEY"}],
				"env":[{"name":"AGENT_EXPECT_API_KEY","value":"sk-ant-itest"}]},
			"output":{"format":"stream-json","select":[{"event":"result"}],"sinks":[{"type":"stdout"}]}}}`));

	auto container = agentContainer(buildJob(agent, station, definition, "img"));

	envSecretKey(container, "ANTHROPIC_API_KEY").should.equal("ANTHROPIC_API_KEY");
	envValue(container, "AGENT_EXPECT_API_KEY").should.equal("sk-ant-itest");
	parseSelectors(envValue(container, "AGENT_SELECT")).length.should.equal(1);
}

unittest
{
	// A recipe may not override a controller-owned env name: a collision is dropped so
	// the controller's value (here the real sinks, not the recipe's "[]") always wins.
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);
	definition.spec.resources.env = [EnvVar("AGENT_SINKS", "[]"), EnvVar("LOG_LEVEL", "debug")];

	auto container = agentContainer(buildJob(agent, station, definition, "img"));

	// Exactly one AGENT_SINKS entry, and it carries the real sink, not the recipe's.
	int sinksEntries;
	foreach (entry; container["env"].get!(Json[]))
		if (entry["name"].get!string == "AGENT_SINKS")
			sinksEntries++;
	sinksEntries.should.equal(1);
	parseSinks(envValue(container, "AGENT_SINKS")).length.should.equal(1);
	// A non-reserved recipe var is unaffected.
	envValue(container, "LOG_LEVEL").should.equal("debug");
}

@safe unittest
{
	isReservedEnvName("AGENT_SINKS").should.equal(true);
	isReservedEnvName("AGENT_NAME").should.equal(true);
	isReservedEnvName("HOME").should.equal(true);
	isReservedEnvName("PATH").should.equal(true);
	isReservedEnvName("LOG_LEVEL").should.equal(false);
	isReservedEnvName("ANTHROPIC_API_KEY").should.equal(false);
}
