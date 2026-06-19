module agentcore.crds.output_spec;

import std.json : JSONValue;

import agentcore.schema;
import agentcore.crds.enums : OutputFormat;
import agentcore.crds.output_selector : OutputSelector;
import agentcore.crds.output_sink : OutputSink;

struct OutputSpec
{
	OutputFormat format;

	@PreserveUnknownFields @Description("JSON Schema validating the result.")
	JSONValue schema;

	OutputSelector[] select;
	OutputSink[] sinks;
}
