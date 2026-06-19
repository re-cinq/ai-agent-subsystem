module agentcore.crds.env_var;

import agentcore.schema;

struct EnvVar
{
	@Required string name;
	@Required string value;
}
