module agentcore.kube.jobs;

/// The Kubernetes Job name the controller creates for a given Agent run.
string jobNameFor(string agentName) @safe pure
{
	return "agent-job-" ~ agentName;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	jobNameFor("bug-fixer-run-6ltzm").should.equal("agent-job-bug-fixer-run-6ltzm");
}
