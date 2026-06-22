module agentcore.initcontext;

import agentcore.crds.repo_ref : RepoRef;

/// What the init container provisions, built from the env the controller injects
/// (see `agentcore.env`). The repos come from the recipe's `resources.repos`, the
/// model decides whether the Claude CLI is installed, and the workspace is where
/// repos are cloned.
struct InitContext
{
	string model;
	RepoRef[] repos;
	string workspaceDir;
}
