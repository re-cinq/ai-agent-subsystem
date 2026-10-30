module agentcore.crds.run_output;

import agentcore.crds.schema;
import agentcore.crds.output_selector : OutputSelector;
import agentcore.crds.output_sink : OutputSink;
import agentcore.crds.output_watch : OutputWatch;

@Description("Where one run's output goes; sinks and select replace the AgentDefinition's when set, watch merges by event.")
struct RunOutput
{
	@optional @Description("Sinks for this run; when set they replace the recipe's sinks.")
	OutputSink[] sinks;

	@optional @Description("Which events reach the sinks; when set it replaces the recipe's selectors.")
	OutputSelector[] select;

	@optional @Description(
		"Files this run produces. An entry replaces the recipe's watch of the same event (so a run can give a recipe's watch its own upload); other events are added.")
	OutputWatch[] watch;
}
