module agentcore.crds.env_var;

import agentcore.crds.schema;

struct EnvVar
{
	@Required string name;
	@Required string value;
}
