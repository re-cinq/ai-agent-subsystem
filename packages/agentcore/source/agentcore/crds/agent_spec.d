module agentcore.crds.agent_spec;

import agentcore.crds.schema;
import agentcore.crds.input_file : InputFile;
import agentcore.crds.conversation_ref : ConversationRef;
import agentcore.crds.env_var : EnvVar;
import agentcore.crds.repo_ref : RepoRef;
import agentcore.crds.run_output : RunOutput;
import agentcore.crds.secret_ref : SecretRef;

@Description(
	"One run of a recipe in a Station. The AgentDefinition is the reusable recipe; what belongs to a single run (repos, conversation, output, secrets, env) can be given here and wins over the recipe's value when set, so one AgentDefinition serves many Agents.")
struct AgentSpec
{
	@optional @Required @Pattern(dns1123Subdomain) @MaxLength(253)
	@Description("The Station to run in (which selects the recipe).")
	string stationRef;

	@optional @Description("External id for correlation.")
	string taskId;

	@optional @Description("Model id for this run; overrides the AgentDefinition's model.")
	string model;

	@optional @Description("GitHub repo in owner/name form.")
	string targetRepo;

	@optional string branch;

	@optional @Description("Per-run values; fill the prompt {placeholder} tokens and pass to the agent.")
	string[string] parameters;

	@optional @Description(
		"Files downloaded into the workspace before the agent starts; only references travel.")
	InputFile[] files;

	@optional @Description(
		"Session id of an earlier realtime run to continue: its saved conversation is restored and the definition's prompt is not sent.")
	string resumeSession;

	@optional @Description(
		"Repositories to clone for this run; when set they replace the AgentDefinition's resources.repos.")
	RepoRef[] repos;

	@optional @Description(
		"Conversation to continue and the id to save under; each field set here wins over the same field of the AgentDefinition's resources.conversation.")
	ConversationRef conversation;

	@optional @Description(
		"Where this run's output goes; see RunOutput for how each field combines with the AgentDefinition's output.")
	RunOutput output;

	@optional @Description(
		"Secrets exposed to this run, such as per-run credentials; an entry replaces the AgentDefinition's resources.secrets entry of the same name, others are added.")
	SecretRef[] secrets;

	@optional @Description(
		"Environment values for this run, such as ones derived from its inputs; an entry replaces the AgentDefinition's resources.env entry of the same name, others are added.")
	EnvVar[] env;
}
