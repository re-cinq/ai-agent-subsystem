module leaderelection;

import core.thread : Thread;
import core.time : seconds;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.format : format;
import std.json : JSONValue;

import vibe.core.core : sleep;
import vibe.core.log : logError, logInfo;

import httpkube : LeaseClient, LeaseRecord;
import metrics : recordLeadership;

/// Fixed Lease the controller's replicas contend for. Whoever holds it reconciles;
/// every standby stays idle. One Lease per controller Deployment.
enum leaseName = "agent-controller";

/// How long a held Lease stays valid without a renewal. A standby waits this long
/// without seeing the holder renew before it takes over.
enum leaseDurationSeconds = 15;

/// Tick cadence: the leader renews this often (well inside the duration) and a
/// standby re-checks the Lease this often.
enum renewIntervalSeconds = 5;

/// Leadership flag the election loop (writer) shares with the reconcile loops
/// (readers). They all run as cooperative vibe fibers on the one event-loop
/// thread, so the unsynchronized flag is race-free — but only while that holds.
/// The accessors bind the owning thread on first touch and assert every later
/// access stays on it, so moving a loop onto a worker thread trips loudly in a
/// debug/test build instead of silently becoming a data race (UB in D).
final class Leadership
{
	private bool flag;
	private Thread owner;

	bool isLeader() nothrow
	{
		assertOwningThread();
		return flag;
	}

	void isLeader(bool value) nothrow
	{
		assertOwningThread();
		flag = value;
	}

	private void assertOwningThread() nothrow
	{
		auto current = Thread.getThis();
		if (owner is null)
			owner = current;
		else
			assert(owner is current,
				"Leadership accessed off its event-loop thread: the flag is unsynchronized and single-thread-only");
	}
}

/// One running leader election: its fixed collaborators (the Lease client, this
/// replica's namespace + identity, and the `Leadership` flag it drives) plus the
/// `observation` that advances each tick. Built once and passed by `ref` so a
/// tick mutates it in place rather than threading state through return values.
struct Election
{
	LeaseClient client;
	string ns;
	string identity;
	Leadership leadership;
	Observation observation;
}

/// What this replica should do with the Lease this tick.
enum LeaseAction
{
	create, /// no Lease exists yet; create one we hold
	acquire, /// an existing Lease expired unrenewed; take it over
	renew, /// we already hold it; refresh its renewTime
	observe, /// another replica holds a still-valid Lease; stand by
}

struct LeaseDecision
{
	LeaseAction action;
	bool leader; /// do we hold leadership after acting on this decision?
}

/// Our running view of the Lease. `firstSeenUnix` is when *this* replica first saw
/// the current (holder, renewTime); judging expiry against our own clock rather
/// than the remote renewTime keeps us correct under clock skew between replicas.
struct Observation
{
	bool exists;
	string holder;
	string renewTime;
	long firstSeenUnix;
}

/// Fold a freshly fetched Lease into our observation. An unchanged (holder,
/// renewTime) keeps the original `firstSeenUnix`; any change resets it to now,
/// restarting the expiry clock — the holder is alive and renewing.
Observation observe(Observation prev, bool exists, string holder, string renewTime, long nowUnix) @safe pure nothrow
{
	const unchanged = exists && prev.exists && holder == prev.holder && renewTime == prev.renewTime;
	return unchanged ? prev : Observation(exists, holder, renewTime, nowUnix);
}

/// Decide what to do with the Lease this tick, purely from our observation.
LeaseDecision electionDecide(Observation lease, string identity, long nowUnix, long durationSeconds) @safe pure nothrow
{
	if (!lease.exists)
		return LeaseDecision(LeaseAction.create, true);
	if (lease.holder == identity)
		return LeaseDecision(LeaseAction.renew, true);
	if (nowUnix - lease.firstSeenUnix >= durationSeconds)
		return LeaseDecision(LeaseAction.acquire, true);
	return LeaseDecision(LeaseAction.observe, false);
}

/// Body for creating a brand-new Lease we hold (POST to the leases collection).
JSONValue createLeaseBody(string identity, long durationSeconds, string timestamp)
{
	return JSONValue([
		"apiVersion": JSONValue("coordination.k8s.io/v1"),
		"kind": JSONValue("Lease"),
		"metadata": JSONValue(["name": JSONValue(leaseName)]),
		"spec": leaseSpec(identity, durationSeconds, timestamp, 0),
	]);
}

/// Merge-patch that refreshes the renewTime of a Lease we already hold. The
/// resourceVersion precondition turns the write into a no-op (409) if a standby
/// raced us, so a stale leader stops believing it still holds the Lease.
JSONValue renewLeaseBody(string resourceVersion, string timestamp)
{
	return JSONValue([
		"metadata": JSONValue(["resourceVersion": JSONValue(resourceVersion)]),
		"spec": JSONValue(["renewTime": JSONValue(timestamp)]),
	]);
}

/// Merge-patch that takes over an expired Lease, bumping leaseTransitions. The
/// resourceVersion precondition stops two standbys both winning the same takeover.
JSONValue acquireLeaseBody(string resourceVersion, string identity, long durationSeconds,
	string timestamp, int transitions)
{
	return JSONValue([
		"metadata": JSONValue(["resourceVersion": JSONValue(resourceVersion)]),
		"spec": leaseSpec(identity, durationSeconds, timestamp, transitions + 1),
	]);
}

private JSONValue leaseSpec(string identity, long durationSeconds, string timestamp, int transitions)
{
	return JSONValue([
		"holderIdentity": JSONValue(identity),
		"leaseDurationSeconds": JSONValue(durationSeconds),
		"acquireTime": JSONValue(timestamp),
		"renewTime": JSONValue(timestamp),
		"leaseTransitions": JSONValue(transitions),
	]);
}

/// Contend for the Lease forever: each tick fetch it, fold it into our
/// observation, decide, and act, flipping `leadership.isLeader` to match. Any
/// error (including a lost renewal race) steps us down so a stale leader stops
/// reconciling. Runs as a vibe task; never returns.
void runLeaderElection(LeaseClient client, string ns, string identity, Leadership leadership) nothrow
{
	auto election = Election(client, ns, identity, leadership);
	for (;;)
	{
		try
			electionTick(election, nowUnix(), rfc3339Micro());
		catch (Exception error)
		{
			logError("election: %s", error.msg);
			setLeader(leadership, identity, false);
		}
		backoff(renewIntervalSeconds);
	}
}

/// One election tick with the clock injected (`now` in unix seconds, `timestamp`
/// the RFC3339 micro string written into the Lease): fetch, fold into the running
/// observation, decide, act, and set leadership to whether we hold the Lease
/// afterwards. Mutates `election` in place — its observation carries to the next tick.
void electionTick(ref Election election, long now, string timestamp)
{
	const record = election.client.getLease(election.ns, leaseName);
	election.observation = observe(election.observation, record.exists, record.holder, record.renewTime, now);
	const decision = electionDecide(election.observation, election.identity, now, leaseDurationSeconds);
	const won = decision.leader && act(election, decision, record, timestamp);
	setLeader(election.leadership, election.identity, won);
}

private bool act(ref Election election, LeaseDecision decision, LeaseRecord record, string timestamp)
{
	final switch (decision.action)
	{
	case LeaseAction.create:
		return election.client.createLease(election.ns,
			createLeaseBody(election.identity, leaseDurationSeconds, timestamp));
	case LeaseAction.renew:
		return election.client.patchLease(election.ns, leaseName,
			renewLeaseBody(record.resourceVersion, timestamp));
	case LeaseAction.acquire:
		return election.client.patchLease(election.ns, leaseName,
			acquireLeaseBody(record.resourceVersion, election.identity, leaseDurationSeconds, timestamp,
				record.transitions));
	case LeaseAction.observe:
		return false;
	}
}

private void setLeader(Leadership leadership, string identity, bool won) nothrow
{
	if (won && !leadership.isLeader)
		logInfo("election: %s acquired leadership", identity);
	else if (!won && leadership.isLeader)
		logInfo("election: %s lost leadership", identity);
	leadership.isLeader = won;
	recordLeadership(won);
}

private long nowUnix()
{
	return Clock.currTime(UTC()).toUnixTime();
}

/// RFC3339 with microsecond precision — the format Kubernetes `MicroTime` expects
/// for a Lease's acquireTime/renewTime.
private string rfc3339Micro()
{
	auto now = Clock.currTime(UTC());
	return format("%04d-%02d-%02dT%02d:%02d:%02d.%06dZ",
		now.year, cast(int) now.month, now.day, now.hour, now.minute, now.second,
		now.fracSecs.total!"usecs");
}

private void backoff(int secs) nothrow
{
	try
		sleep(secs.seconds);
	catch (Exception)
	{
	}
}

version (unittest) import fluent.asserts;

unittest
{
	// No Lease yet -> create it and lead.
	electionDecide(Observation(false), "me", 100, 15).should.equal(LeaseDecision(LeaseAction.create, true));
}

unittest
{
	// We already hold it -> renew and keep leading, regardless of elapsed time.
	electionDecide(Observation(true, "me", "t", 100), "me", 130, 15)
		.should.equal(LeaseDecision(LeaseAction.renew, true));
}

unittest
{
	// Another holder, still inside the duration since we first saw this renewTime -> stand by.
	electionDecide(Observation(true, "other", "t", 100), "me", 110, 15)
		.should.equal(LeaseDecision(LeaseAction.observe, false));
}

unittest
{
	// Another holder that went unrenewed for the full duration -> take over (>= boundary).
	electionDecide(Observation(true, "other", "t", 100), "me", 115, 15)
		.should.equal(LeaseDecision(LeaseAction.acquire, true));
}

unittest
{
	auto seen = Observation(true, "other", "t1", 100);
	// Unchanged (holder, renewTime) keeps the first-seen timestamp...
	observe(seen, true, "other", "t1", 200).firstSeenUnix.should.equal(100L);
	// ...a renewTime change resets it (holder is renewing; restart the clock)...
	observe(seen, true, "other", "t2", 200).firstSeenUnix.should.equal(200L);
	// ...a holder change resets it...
	observe(seen, true, "new", "t1", 200).firstSeenUnix.should.equal(200L);
	// ...and a Lease that vanished resets it too.
	observe(seen, false, "", "", 200).should.equal(Observation(false, "", "", 200));
}

unittest
{
	auto created = createLeaseBody("pod-a", 15, "2026-06-23T00:00:00.000000Z");
	created["metadata"]["name"].str.should.equal("agent-controller");
	created["spec"]["holderIdentity"].str.should.equal("pod-a");
	created["spec"]["leaseDurationSeconds"].integer.should.equal(15);

	auto taken = acquireLeaseBody("42", "pod-b", 15, "2026-06-23T00:00:00.000000Z", 7);
	taken["metadata"]["resourceVersion"].str.should.equal("42");
	taken["spec"]["holderIdentity"].str.should.equal("pod-b");
	taken["spec"]["leaseTransitions"].integer.should.equal(8);

	auto renewed = renewLeaseBody("42", "2026-06-23T00:00:01.000000Z");
	renewed["metadata"]["resourceVersion"].str.should.equal("42");
	renewed["spec"]["renewTime"].str.should.equal("2026-06-23T00:00:01.000000Z");
}

version (unittest)
{
	import std.conv : to;

	/// In-memory Lease store standing in for the API server: a successful write
	/// mutates the stored record the way the apiserver would (merge semantics, a
	/// bumped resourceVersion), and the `*Ok` flags simulate a lost
	/// optimistic-concurrency race (a 409).
	final class FakeLeaseClient : LeaseClient
	{
		LeaseRecord record;
		bool createOk = true;
		bool patchOk = true;
		string[] writes;
		private int generation;

		override LeaseRecord getLease(string ns, string name)
		{
			return record;
		}

		override bool createLease(string ns, JSONValue body)
		{
			writes ~= "create";
			if (!createOk)
				return false;
			apply(body);
			return true;
		}

		override bool patchLease(string ns, string name, JSONValue body)
		{
			writes ~= "patch";
			if (!patchOk)
				return false;
			apply(body);
			return true;
		}

		private void apply(JSONValue body)
		{
			auto spec = body["spec"];
			record.exists = true;
			if (auto holder = "holderIdentity" in spec.object)
				record.holder = holder.str;
			if (auto renew = "renewTime" in spec.object)
				record.renewTime = renew.str;
			if (auto transitions = "leaseTransitions" in spec.object)
				record.transitions = cast(int) transitions.integer;
			record.resourceVersion = (++generation).to!string;
		}
	}
}

unittest
{
	// Bootstrap: no Lease yet -> we create it and lead. Next tick: we hold it, so
	// we renew and stay leader.
	auto client = new FakeLeaseClient;
	auto leadership = new Leadership;
	auto election = Election(client, "ns", "me", leadership);

	electionTick(election, 100, "ts-1");
	leadership.isLeader.should.equal(true);
	client.writes.should.equal(["create"]);
	client.record.holder.should.equal("me");

	electionTick(election, 105, "ts-2");
	leadership.isLeader.should.equal(true);
	client.writes.should.equal(["create", "patch"]);
	client.record.renewTime.should.equal("ts-2");
}

unittest
{
	// A live peer holds the Lease: within the duration we stand by (no write), then
	// the peer stops renewing and a full duration later we take it over.
	auto client = new FakeLeaseClient;
	client.record = LeaseRecord(true, "peer", "ts-x", "7", 2);
	auto leadership = new Leadership;
	auto election = Election(client, "ns", "me", leadership);

	electionTick(election, 100, "ts-1");
	leadership.isLeader.should.equal(false);
	client.writes.length.should.equal(0);

	electionTick(election, 115, "ts-2");
	leadership.isLeader.should.equal(true);
	client.writes.should.equal(["patch"]);
	client.record.holder.should.equal("me");
	client.record.transitions.should.equal(3); // bumped on takeover
}

unittest
{
	// We believe we hold it, but the renew loses the resourceVersion race (409):
	// step down so a stale leader stops reconciling.
	auto client = new FakeLeaseClient;
	client.record = LeaseRecord(true, "me", "ts-x", "3", 0);
	client.patchOk = false;
	auto leadership = new Leadership;
	leadership.isLeader = true;
	auto election = Election(client, "ns", "me", leadership, Observation(true, "me", "ts-x", 90));

	electionTick(election, 100, "ts-1");
	leadership.isLeader.should.equal(false);
	client.writes.should.equal(["patch"]);
}

unittest
{
	// Bootstrap race: another replica created the Lease first (409) -> not leader,
	// store untouched.
	auto client = new FakeLeaseClient;
	client.createOk = false;
	auto leadership = new Leadership;
	auto election = Election(client, "ns", "me", leadership);

	electionTick(election, 100, "ts-1");
	leadership.isLeader.should.equal(false);
	client.writes.should.equal(["create"]);
	client.record.exists.should.equal(false);
}

version (unittest)
{
	import std.algorithm : canFind, filter, map, sort, startsWith;
	import std.array : array, split;
	import std.file : readText;
	import std.path : buildNormalizedPath, dirName;
	import std.string : indexOf, replace, strip;

	/// Verbs the controller Role grants the `leases` resource: the `verbs:` line
	/// following the `resources: ["leases"]` rule. Text-simple on purpose — it reads
	/// one known rule in our own manifest, not arbitrary YAML.
	string[] leaseRuleVerbs(string manifest)
	{
		auto lines = manifest.split("\n");
		foreach (i, line; lines)
		{
			if (!line.canFind(`["leases"]`))
				continue;
			foreach (rest; lines[i + 1 .. $])
				if (rest.strip.startsWith("verbs:"))
					return bracketItems(rest);
		}
		return [];
	}

	/// The quoted tokens inside the first `[...]` on a line:
	/// `verbs: ["get", "patch"]` -> ["get", "patch"].
	string[] bracketItems(string line)
	{
		auto items = line[line.indexOf('[') + 1 .. line.indexOf(']')];
		return items.split(",")
			.map!(token => token.strip.replace(`"`, ""))
			.filter!(token => token.length > 0)
			.array;
	}
}

unittest
{
	// Least privilege (issue #21): the Role grants the Lease exactly the verbs the
	// leader-election client issues -- getLease/createLease/patchLease map to
	// get/create/patch. No `update`: HttpKubeClient never PUTs a Lease, so granting
	// it would be unused privilege. This fails if anyone re-adds it.
	auto manifest = readText(buildNormalizedPath(dirName(__FILE_FULL_PATH__),
		"../../../deploy/rbac/controller-rbac.yaml"));

	auto granted = leaseRuleVerbs(manifest);
	auto used = ["get", "create", "patch"];
	granted.sort();
	used.sort();
	granted.should.equal(used);
}

unittest
{
	import core.exception : AssertError;
	import core.thread : Thread;

	// issue #20: the leadership flag is unsynchronized and assumes every access stays
	// on the one event-loop thread. It binds its owning thread on first touch, so a
	// read from any other thread must trip loudly rather than silently racing.
	auto leadership = new Leadership;
	leadership.isLeader = false; // binds this thread as the owner

	auto tripped = false;
	auto intruder = new Thread(() {
		try
			cast(void) leadership.isLeader;
		catch (AssertError)
			tripped = true;
	});
	intruder.start();
	intruder.join();

	tripped.should.equal(true);
}
