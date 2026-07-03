module agentcore.crds.env_var;

import agentcore.crds.schema;

struct EnvVar
{
	@optional @Required string name;
	@optional @Required string value;
}
