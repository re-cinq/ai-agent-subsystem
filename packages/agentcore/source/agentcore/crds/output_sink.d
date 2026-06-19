module agentcore.crds.output_sink;

import agentcore.schema;
import agentcore.crds.enums : SinkType;

struct OutputSink
{
	@Required SinkType type;
	string url;
	@Json("headers_secret") string headersSecret;
	string path;
}
