module agentcore.kube.jobs;

/// The longest a Kubernetes name may be to stay valid as a label value and a pod
/// hostname (DNS-1123 label). The Job name and the run labels are held to it.
enum maxNameLength = 63;

/// The Kubernetes Job name the controller creates for a given Agent run. Held to
/// `maxNameLength` so the API server never rejects the Job for a long Agent name.
string jobNameFor(string agentName) @safe pure nothrow
{
	return safeName("agent-job-" ~ agentName);
}

/// A name no longer than `maxLen`. A short name passes through; a longer one is
/// truncated and suffixed with a stable hash of the full name so distinct long names
/// stay distinct and the result is deterministic (the driver re-derives the Job name
/// to find the run, so it must not depend on anything but the input).
string safeName(string name, size_t maxLen = maxNameLength) @safe pure nothrow
{
	if (name.length <= maxLen)
		return name;
	const suffix = "-" ~ fnv1aHex(name);
	return name[0 .. maxLen - suffix.length] ~ suffix;
}

/// 8-hex-char FNV-1a digest of `s` — a small, dependency-free `pure nothrow` hash used
/// only to keep truncated names distinct, not for any security purpose.
private string fnv1aHex(string s) @safe pure nothrow
{
	ulong h = 0xcbf29ce484222325;
	foreach (char c; s)
	{
		h ^= cast(ubyte) c;
		h *= 0x100000001b3;
	}
	static immutable hex = "0123456789abcdef";
	char[8] digits;
	foreach (i; 0 .. 8)
		digits[7 - i] = hex[(h >> (i * 4)) & 0xf];
	return digits.idup;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	jobNameFor("bug-fixer-run-6ltzm").should.equal("agent-job-bug-fixer-run-6ltzm");
}

@safe unittest
{
	// A long Agent name is hashed into a name within the k8s 63-char limit, stably, and
	// distinct long names stay distinct.
	const long_ = "an-extremely-long-agent-name-that-runs-well-past-the-sixty-three-char-limit";
	const name = jobNameFor(long_);
	name.length.should.be.lessThan(maxNameLength + 1);
	jobNameFor(long_).should.equal(name);
	jobNameFor(long_ ~ "-different").should.not.equal(name);
}

@safe unittest
{
	// Names already within the limit are untouched.
	safeName("short").should.equal("short");
}
