module agentcore.crds.secret_ref;

import agentcore.crds.schema;

struct SecretRef
{
	@Required @Description("Environment variable name to expose the secret as.")
	string name;

	@Required @Json("ref") @Description("Allowlisted secret-store key.")
	string ref_;
}

@safe unittest
{
	static assert(jsonNameOf!(SecretRef.ref_) == "ref");
}
