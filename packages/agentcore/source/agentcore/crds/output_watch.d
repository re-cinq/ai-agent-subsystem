module agentcore.crds.output_watch;

import agentcore.crds.schema;

/// A file the run is expected to produce, and the event name to raise when it does.
///
/// The subsystem is a pure execution engine: it streams what the agent says, but an
/// agent whose deliverable is a FILE had no way to hand that file back. Callers
/// worked around it by asking the model to repeat the artifact as its closing
/// message, which puts an LLM in the delivery path of a deterministic step — and
/// silently produces nothing when the model summarises instead.
///
/// Declaring a watch makes the artifact a first-class run output: after the agent
/// exits, the supervisor reads `path` and raises a `{"kind":"file"}` event carrying
/// `event` and the file's contents through the run's normal sinks, so a downstream
/// consumer receives it on the channel it already listens to (#188).
struct OutputWatch
{
	/// Event name stamped on the raised event, so one run can emit several artifacts
	/// and a consumer can tell them apart. Required — an unnamed artifact cannot be
	/// routed.
	@optional @Required @Description("Event name raised when the file is produced.")
	string event;

	/// The file to read. A relative path resolves against `WORKSPACE_DIR` (the agent
	/// container's cwd is `/`, so a relative path is otherwise meaningless), and must
	/// stay inside it.
	@optional @Required @Description(
		"File to read; relative paths resolve against WORKSPACE_DIR.")
	string path;
}
