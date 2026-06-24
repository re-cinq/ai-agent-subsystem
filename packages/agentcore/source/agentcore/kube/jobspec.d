module agentcore.kube.jobspec;

import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;

import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.output_selector : OutputSelector;
import agentcore.crds.output_sink : OutputSink;
import agentcore.crds.repo_ref : RepoRef;
import agentcore.crds.station : Station;
import agentcore.agents.agentselect : agentForModel;
import agentcore.kube.bundle : bundleRoot, supervisorPath;
import agentcore.core.env;
import agentcore.kube.jobs : jobNameFor;
import agentcore.agents.prompt : renderPrompt;

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
JSONValue buildJob(Agent agent, Station station, AgentDefinition definition, string agentImage)
{
	auto recipe = definition.spec;
	const prompt = renderPrompt(recipe.prompt, agent.spec.parameters);
	auto argv = agentForModel(recipe.model).command(recipe, prompt);
	auto env = runEnv(agent, station, recipe);

	auto template_ = wirePodTemplate(deepCopy(station.spec.template_), commandFor(argv), env, agentImage);
	template_ = withRunLabels(template_, agent, station);

	JSONValue[string] spec;
	spec["ttlSecondsAfterFinished"] = JSONValue(jobTtlSeconds);
	spec["activeDeadlineSeconds"] = JSONValue(station.spec.deadlineMinutes * 60);
	spec["backoffLimit"] = JSONValue(0);
	spec["template"] = template_;

	JSONValue[string] job;
	job["apiVersion"] = JSONValue("batch/v1");
	job["kind"] = JSONValue("Job");
	job["metadata"] = jobMeta(agent);
	job["spec"] = JSONValue(spec);
	return JSONValue(job);
}

private JSONValue deepCopy(JSONValue value)
{
	return parseJSON(value.toString());
}

/// Merge the run labels into the pod template's `metadata.labels`, preserving any
/// labels the Station's template already carries (ours win on the run keys).
private JSONValue withRunLabels(JSONValue template_, Agent agent, Station station)
{
	auto pod = template_;
	JSONValue meta = ("metadata" in pod.object) ? pod["metadata"] : parseJSON("{}");
	JSONValue labels = (meta.type == JSONType.object && ("labels" in meta.object))
		? meta["labels"] : parseJSON("{}");
	labels[labelComponent] = JSONValue(componentJob);
	labels[labelAgent] = JSONValue(agent.metadata.name);
	labels[labelStation] = JSONValue(station.metadata.name);
	meta["labels"] = labels;
	pod["metadata"] = meta;
	return pod;
}

private JSONValue jobMeta(Agent agent)
{
	JSONValue[string] owner;
	owner["apiVersion"] = JSONValue(crApiVersion);
	owner["kind"] = JSONValue("Agent");
	owner["name"] = JSONValue(agent.metadata.name);
	owner["uid"] = JSONValue(agent.metadata.uid);
	owner["controller"] = JSONValue(true);
	owner["blockOwnerDeletion"] = JSONValue(true);

	JSONValue[string] meta;
	meta["name"] = JSONValue(jobNameFor(agent.metadata.name));
	meta["namespace"] = JSONValue(agent.metadata.namespace);
	meta["ownerReferences"] = JSONValue([JSONValue(owner)]);
	return JSONValue(meta);
}

private JSONValue[] commandFor(string[] argv)
{
	JSONValue[] command = [JSONValue(supervisorPath), JSONValue("--")];
	foreach (arg; argv)
		command ~= JSONValue(arg);
	return command;
}

private JSONValue wirePodTemplate(JSONValue template_, JSONValue[] command, JSONValue env, string agentImage)
{
	enforce(template_.type == JSONType.object, "Station template must be an object");
	auto pod = template_;
	enforce("spec" in pod.object, "Station template needs a spec");
	auto spec = pod["spec"];
	enforce(spec.type == JSONType.object && ("containers" in spec.object),
		"Station template.spec.containers is required");

	JSONValue[] containers;
	bool wired = false;
	foreach (container; spec["containers"].array)
	{
		if (isAgentContainer(container))
		{
			container["command"] = JSONValue(command);
			container["env"] = env;
			container["volumeMounts"] = withBundleMount(container);
			container["securityContext"] = nonRootSecurity();
			wired = true;
		}
		containers ~= container;
	}
	enforce(wired, "Station template has no container named '" ~ agentContainerName ~ "'");

	spec["containers"] = JSONValue(containers);
	spec["initContainers"] = JSONValue([initContainer(agentImage, env)]);
	spec["volumes"] = withBundleVolume(spec);
	spec["restartPolicy"] = JSONValue("Never");
	spec["securityContext"] = podSecurity();

	pod["spec"] = spec;
	return pod;
}

private bool isAgentContainer(JSONValue container)
{
	return container.type == JSONType.object && ("name" in container.object)
		&& container["name"].str == agentContainerName;
}

private JSONValue withBundleMount(JSONValue container)
{
	JSONValue[] mounts;
	if (auto existing = "volumeMounts" in container.object)
		mounts = (*existing).array.dup;
	JSONValue[string] mount;
	mount["name"] = JSONValue(bundleVolume);
	mount["mountPath"] = JSONValue(bundleRoot);
	mounts ~= JSONValue(mount);
	return JSONValue(mounts);
}

private JSONValue withBundleVolume(JSONValue spec)
{
	JSONValue[] volumes;
	if (auto existing = "volumes" in spec.object)
		volumes = (*existing).array.dup;
	JSONValue[string] volume;
	volume["name"] = JSONValue(bundleVolume);
	volume["emptyDir"] = parseJSON("{}");
	volumes ~= JSONValue(volume);
	return JSONValue(volumes);
}

private JSONValue initContainer(string agentImage, JSONValue env)
{
	JSONValue[string] mount;
	mount["name"] = JSONValue(bundleVolume);
	mount["mountPath"] = JSONValue(bundleRoot);

	JSONValue[string] security;
	security["runAsUser"] = JSONValue(0);

	JSONValue[string] container;
	container["name"] = JSONValue(initContainerName);
	container["image"] = JSONValue(agentImage);
	container["env"] = env;
	container["volumeMounts"] = JSONValue([JSONValue(mount)]);
	container["securityContext"] = JSONValue(security);
	container["resources"] = initResources();
	return JSONValue(container);
}

private JSONValue nonRootSecurity()
{
	JSONValue[string] security;
	security["runAsNonRoot"] = JSONValue(true);
	security["runAsUser"] = JSONValue(agentUid);
	security["runAsGroup"] = JSONValue(agentGid);
	security["allowPrivilegeEscalation"] = JSONValue(false);
	return JSONValue(security);
}

private JSONValue podSecurity()
{
	JSONValue[string] security;
	security["fsGroup"] = JSONValue(agentGid);
	return JSONValue(security);
}

/// Requests/limits for the init container so it is Burstable, not BestEffort — a
/// BestEffort init is the kernel OOM-killer's first target under node memory
/// pressure. The limit must cover the real agent's prerequisite install: the
/// Claude CLI installer (curl https://claude.ai/install.sh | bash) runs a native
/// binary whose `install` step embeds a JS runtime and peaks past 512Mi, so the
/// request stays modest while the limit gives that transient spike real headroom.
/// The mock agent bakes its CLI in and never installs, which is why CI did not
/// surface the OOM.
private JSONValue initResources()
{
	JSONValue[string] requests;
	requests["cpu"] = JSONValue("50m");
	requests["memory"] = JSONValue("128Mi");
	JSONValue[string] limits;
	limits["memory"] = JSONValue("2Gi");
	JSONValue[string] resources;
	resources["requests"] = JSONValue(requests);
	resources["limits"] = JSONValue(limits);
	return JSONValue(resources);
}

private JSONValue runEnv(Agent agent, Station station, AgentDefinitionSpec recipe)
{
	JSONValue[] env;

	void strVar(string name, string value)
	{
		JSONValue[string] entry;
		entry["name"] = JSONValue(name);
		entry["value"] = JSONValue(value);
		env ~= JSONValue(entry);
	}

	void fieldVar(string name, string fieldPath)
	{
		JSONValue[string] fieldRef;
		fieldRef["fieldPath"] = JSONValue(fieldPath);
		JSONValue[string] from;
		from["fieldRef"] = JSONValue(fieldRef);
		JSONValue[string] entry;
		entry["name"] = JSONValue(name);
		entry["valueFrom"] = JSONValue(from);
		env ~= JSONValue(entry);
	}

	void secretVar(string name, string key)
	{
		JSONValue[string] keyRef;
		keyRef["name"] = JSONValue(agentSecretName);
		keyRef["key"] = JSONValue(key);
		keyRef["optional"] = JSONValue(false);
		JSONValue[string] from;
		from["secretKeyRef"] = JSONValue(keyRef);
		JSONValue[string] entry;
		entry["name"] = JSONValue(name);
		entry["valueFrom"] = JSONValue(from);
		env ~= JSONValue(entry);
	}

	strVar(envSinks, sinksJson(recipe.output.sinks));
	strVar(envRepos, reposJson(recipe.resources.repos));
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
	foreach (variable; recipe.resources.env)
		strVar(variable.name, variable.value);
	foreach (secret; recipe.resources.secrets)
		secretVar(secret.name, secret.ref_);
	strVar("HOME", bundleRoot);
	strVar("PATH", "/agent/.local/bin:/usr/local/bin:/usr/bin:/bin");
	return JSONValue(env);
}

private string sinksJson(const OutputSink[] sinks)
{
	JSONValue[] array;
	foreach (sink; sinks)
	{
		JSONValue[string] object;
		object["type"] = JSONValue(cast(string) sink.type);
		if (sink.url.length)
			object["url"] = JSONValue(sink.url);
		if (sink.path.length)
			object["path"] = JSONValue(sink.path);
		array ~= JSONValue(object);
	}
	return JSONValue(array).toString();
}

private string selectJson(const OutputSelector[] selectors)
{
	JSONValue[] array;
	foreach (selector; selectors)
	{
		JSONValue[string] object;
		object["event"] = JSONValue(cast(string) selector.event);
		if (selector.tool.length)
			object["tool"] = JSONValue(selector.tool);
		if (selector.contains.length)
			object["contains"] = JSONValue(selector.contains);
		array ~= JSONValue(object);
	}
	return JSONValue(array).toString();
}

private string reposJson(const RepoRef[] repos)
{
	JSONValue[] array;
	foreach (repo; repos)
	{
		JSONValue[string] object;
		object["name"] = JSONValue(repo.name);
		object["url"] = JSONValue(repo.url);
		if (repo.ref_.length)
			object["ref"] = JSONValue(repo.ref_);
		if (repo.path.length)
			object["path"] = JSONValue(repo.path);
		if (repo.tokenSecret.length)
			object["token_secret"] = JSONValue(repo.tokenSecret);
		array ~= JSONValue(object);
	}
	return JSONValue(array).toString();
}

private string parametersJson(const string[string] parameters)
{
	JSONValue[string] object;
	foreach (key, value; parameters)
		object[key] = JSONValue(value);
	return JSONValue(object).toString();
}

version (unittest)
{
	import fluent.asserts;
	import agentcore.crds.enums : SinkType, SelectEvent;
	import agentcore.crds.env_var : EnvVar;
	import agentcore.crds.output_selector : OutputSelector;
	import agentcore.crds.secret_ref : SecretRef;
	import agentcore.output.output : parseSinks;
	import agentcore.output.selectmatcher : parseSelectors;

	private JSONValue agentContainer(JSONValue job)
	{
		foreach (container; job["spec"]["template"]["spec"]["containers"].array)
			if (container["name"].str == agentContainerName)
				return container;
		assert(false, "no agent container");
	}

	private string envValue(JSONValue container, string name)
	{
		foreach (entry; container["env"].array)
			if (entry["name"].str == name && ("value" in entry.object))
				return entry["value"].str;
		return "";
	}

	private string envFieldPath(JSONValue container, string name)
	{
		foreach (entry; container["env"].array)
			if (entry["name"].str == name && ("valueFrom" in entry.object))
				return entry["valueFrom"]["fieldRef"]["fieldPath"].str;
		return "";
	}

	private string envSecretKey(JSONValue container, string name)
	{
		foreach (entry; container["env"].array)
			if (entry["name"].str == name && ("valueFrom" in entry.object)
				&& ("secretKeyRef" in entry["valueFrom"].object))
				return entry["valueFrom"]["secretKeyRef"]["key"].str;
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
		station.spec.template_ = parseJSON(
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

	job["apiVersion"].str.should.equal("batch/v1");
	job["kind"].str.should.equal("Job");
	job["metadata"]["name"].str.should.equal("agent-job-bug-fixer-run-1");
	job["metadata"]["namespace"].str.should.equal("ai-agents");

	auto owner = job["metadata"]["ownerReferences"][0];
	owner["kind"].str.should.equal("Agent");
	owner["name"].str.should.equal("bug-fixer-run-1");
	owner["uid"].str.should.equal("uid-123");
	owner["controller"].boolean.should.equal(true);
	owner["blockOwnerDeletion"].boolean.should.equal(true);

	job["spec"]["ttlSecondsAfterFinished"].integer.should.equal(3600);
	job["spec"]["activeDeadlineSeconds"].integer.should.equal(1800);
	job["spec"]["backoffLimit"].integer.should.equal(0);
}

unittest
{
	Agent agent;
	Station station;
	AgentDefinition definition;
	fixtures(agent, station, definition);

	auto job = buildJob(agent, station, definition, "ghcr.io/re-cinq/ai-agent:latest");
	auto pod = job["spec"]["template"]["spec"];

	pod["restartPolicy"].str.should.equal("Never");
	// Both containers are preserved; the sidecar is untouched.
	pod["containers"].array.length.should.equal(2);
	pod["initContainers"][0]["image"].str.should.equal("ghcr.io/re-cinq/ai-agent:latest");
	pod["initContainers"][0]["securityContext"]["runAsUser"].integer.should.equal(0);
	// The init must not be BestEffort, or the kernel OOM-kills it first under pressure.
	pod["initContainers"][0]["resources"]["requests"]["memory"].str.should.equal("128Mi");
	pod["volumes"][0]["name"].str.should.equal(bundleVolume);

	auto container = agentContainer(job);
	auto command = container["command"].array;
	command[0].str.should.equal(supervisorPath);
	command[1].str.should.equal("--");
	command[2].str.should.equal("claude");
	command[$ - 1].str.should.equal("Fix ENG-1"); // rendered prompt baked in
	container["securityContext"]["runAsNonRoot"].boolean.should.equal(true);
	// A concrete non-root UID/GID is required, else the kubelet rejects a root image.
	container["securityContext"]["runAsUser"].integer.should.equal(1000);
	pod["securityContext"]["fsGroup"].integer.should.equal(1000);
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
	labels["agents.re-cinq.com/component"].str.should.equal("job");
	labels["agents.re-cinq.com/agent"].str.should.equal("bug-fixer-run-1");
	labels["agents.re-cinq.com/station"].str.should.equal("bug-fixer-station");
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
