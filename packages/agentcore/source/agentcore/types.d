module agentcore.types;

/// Lifecycle phase of an Agent run, mirroring the CRD status enum.
enum Phase : string
{
	pending = "Pending",
	running = "Running",
	succeeded = "Succeeded",
	failed = "Failed",
}

@safe unittest
{
	assert(cast(string) Phase.pending == "Pending");
	assert(cast(string) Phase.succeeded == "Succeeded");
}
