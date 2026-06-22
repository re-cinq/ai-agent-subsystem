module agentcore.core.types;

/// Lifecycle phase of an Agent run, mirroring the CRD status enum.
enum Phase : string
{
	pending = "Pending",
	running = "Running",
	succeeded = "Succeeded",
	failed = "Failed",
}

version (unittest) import fluent.asserts;

@safe unittest
{
	(cast(string) Phase.pending).should.equal("Pending");
	(cast(string) Phase.succeeded).should.equal("Succeeded");
}
