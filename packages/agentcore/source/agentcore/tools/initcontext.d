module agentcore.tools.initcontext;

import agentcore.crds.repo_ref : RepoRef;

/// What the init container provisions, built from the env the controller injects
/// (see `agentcore.core.env`). The repos come from the recipe's `resources.repos`, the
/// model decides whether the Claude CLI is installed, and the workspace is where
/// repos are cloned.
struct InitContext
{
	string model;
	RepoRef[] repos;
	string workspaceDir;
	/// Recipe `resources.skills` names — the SkillsTool fetches each from `skillsSource`
	/// into the run's `$HOME/.claude/skills`.
	string[] skills;
	/// Recipe `resources.skillsSource` — the registry base URL skills + settings are
	/// fetched from. Empty ⇒ no fetch (repo-own skills still stage).
	string skillsSource;
	/// Recipe `resources.conversation` — a previous run to continue. The
	/// ConversationTool restores its state into the vendor's stateDir before the agent
	/// starts. Empty id ⇒ fresh conversation.
	string conversationSource;
	string conversationId;
	/// The vendor's state directory, relative to $HOME (e.g. `.claude/projects`).
	/// Empty ⇒ this vendor cannot continue a run, so no restore is attempted.
	string conversationStateDir;
}
