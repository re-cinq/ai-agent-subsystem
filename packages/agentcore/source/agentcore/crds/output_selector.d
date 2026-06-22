module agentcore.crds.output_selector;

import agentcore.crds.schema;
import agentcore.crds.enums : SelectEvent, SelectRole;

struct OutputSelector
{
	@Required SelectEvent event;
	string tool;
	SelectRole role;
	string contains;
}
