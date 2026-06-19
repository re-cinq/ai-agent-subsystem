module agentcore.crds.repo_ref;

import agentcore.schema;

struct RepoRef
{
	@Required string name;
	@Required string url;
	@Json("ref") string ref_;
	string path;
	@Json("token_secret") string tokenSecret;
}
