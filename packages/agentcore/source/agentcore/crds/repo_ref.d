module agentcore.crds.repo_ref;

import agentcore.crds.schema;

struct RepoRef
{
	@optional @Required string name;
	@optional @Required string url;
	@optional @wire("ref") string ref_;
	@optional string path;
	@optional @wire("token_secret") string tokenSecret;
}
