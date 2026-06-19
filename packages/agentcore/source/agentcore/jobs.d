module agentcore.jobs;

/// The Kubernetes Job name the controller creates for a given Agent run.
string jobNameFor(string agentName) @safe pure
{
	return "agent-job-" ~ agentName;
}

@safe unittest
{
	assert(jobNameFor("bug-fixer-run-6ltzm") == "agent-job-bug-fixer-run-6ltzm");
}
