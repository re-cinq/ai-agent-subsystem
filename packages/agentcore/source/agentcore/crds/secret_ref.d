module agentcore.crds.secret_ref;

import agentcore.crds.schema;

struct SecretRef
{
	@optional @Required @Description("Environment variable name to expose the secret as.")
	string name;

	@optional @Required @wire("ref") @Description("Allowlisted secret-store key.")
	string ref_;
}

@safe unittest
{
	static assert(jsonNameOf!(SecretRef.ref_) == "ref");
}
