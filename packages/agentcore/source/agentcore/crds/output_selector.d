module agentcore.crds.output_selector;

import agentcore.crds.schema;
import agentcore.crds.enums : SelectEvent, SelectRole;

struct OutputSelector
{
	@optional @Required SelectEvent event;
	@optional string tool;
	@optional SelectRole role;
	@optional string contains;
}
