module agentcore.crds.output_spec;

import vibe.data.json : Json;

import agentcore.crds.schema;
import agentcore.crds.enums : OutputFormat;
import agentcore.crds.output_selector : OutputSelector;
import agentcore.crds.output_sink : OutputSink;

struct OutputSpec
{
	@optional OutputFormat format;

	@optional @PreserveUnknownFields @Description("JSON Schema validating the result.")
	Json schema;

	@optional OutputSelector[] select;
	@optional OutputSink[] sinks;
}
