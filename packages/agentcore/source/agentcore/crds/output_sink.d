module agentcore.crds.output_sink;

import agentcore.crds.schema;
import agentcore.crds.enums : SinkType;

struct OutputSink
{
	@optional @Required SinkType type;
	@optional string url;
	@optional @wire("headers_secret") string headersSecret;
	@optional string path;
}
