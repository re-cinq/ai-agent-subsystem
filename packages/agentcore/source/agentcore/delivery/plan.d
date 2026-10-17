module agentcore.delivery.plan;

import std.algorithm.searching : all, canFind, endsWith;
import std.ascii : isAlphaNum;

import vibe.data.json : parseJsonString;

import agentcore.core.env : defaultWorkspace;
import agentcore.core.prompt : renderPrompt;
import agentcore.crds.agent : Agent;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec;
import agentcore.crds.delivery_spec : defaultGithubApiUrl, opensPullRequest;
import agentcore.crds.enums : Execution;
import agentcore.crds.repo_ref : RepoRef;
import agentcore.crds.schema : optional;
import agentcore.crds.serialization : fromJson;
import agentcore.tools.git_tool : isRepoSlug, repoDest, repoSlug;

/// The emptyDir the supervisor drops the run's bundle into and the courier reads it from.
enum outboxRoot = "/outbox";

/// Everything the run's pods need to deliver its work as a pull request, resolved by the
/// controller and handed to the init, supervisor and courier as `AGENT_DELIVERY`. Names
/// and paths only: the credential stays in the environment variable `repo.tokenSecret`
/// names, which only the init and courier containers receive.
struct DeliveryPlan
{
	/// The repo the agent works in: the first of `resources.repos`.
	@optional RepoRef repo;
	/// The `owner/name` the pull request is opened on.
	@optional string slug;
	/// The branch the work is pushed to and the pull request is opened from.
	@optional string branch;
	@optional string base;
	@optional string title;
	@optional bool draft;
	@optional string apiUrl;
	/// The clone the supervisor bundles once the agent exits.
	@optional string clone;
	@optional string outbox;
}

/// The plan for delivering `agent`'s run of `recipe`. The branch is the Agent's own, or
/// `agent/<name>` (unique per namespace) when it names none; the pull request opens on
/// the Agent's `targetRepo`, or else on the repo it clones.
DeliveryPlan planFor(const Agent agent, const AgentDefinitionSpec recipe) @safe
{
	const pullRequest = recipe.delivery.pullRequest;
	DeliveryPlan plan;
	plan.repo = recipe.resources.repos[0];
	plan.slug = agent.spec.targetRepo.length ? agent.spec.targetRepo : repoSlug(plan.repo.url);
	plan.branch = agent.spec.branch.length ? agent.spec.branch : "agent/" ~ agent.metadata.name;
	plan.base = pullRequest.base;
	plan.title = renderPrompt(pullRequest.titleTemplate, agent.spec.parameters);
	plan.draft = pullRequest.draft;
	plan.apiUrl = pullRequest.apiUrl.length ? pullRequest.apiUrl : defaultGithubApiUrl;
	plan.clone = repoDest(plan.repo, defaultWorkspace);
	plan.outbox = outboxRoot;
	return plan;
}

/// Why `agent` cannot deliver its run of `recipe` as a pull request, or "" when it can
/// (or asks for no delivery). Checked before the Job exists, so a misconfigured delivery
/// fails the Agent up front instead of after the agent has done the work.
string deliveryViolation(const Agent agent, const AgentDefinitionSpec recipe) @safe
{
	if (!opensPullRequest(recipe.delivery))
		return "";
	if (recipe.execution != Execution.interactive)
		return "delivery.pullRequest requires interactive execution";
	if (recipe.resources.repos.length == 0)
		return "delivery.pullRequest needs a repo in resources.repos";
	const plan = planFor(agent, recipe);
	if (!isRepoSlug(plan.slug))
		return "delivery.pullRequest needs the Agent's targetRepo or resources.repos[0] as a GitHub owner/name";
	if (!isBranchName(plan.branch) || !isBranchName(plan.base))
		return "delivery.pullRequest cannot use branch '" ~ plan.branch ~ "' with base '" ~ plan.base ~ "'";
	if (plan.repo.tokenSecret.length == 0 && "git_credential_url" !in agent.spec.parameters)
		return "delivery.pullRequest needs resources.repos[0].token_secret or a git_credential_url parameter";
	return "";
}

/// Whether `name` is a branch name git accepts and a refspec cannot misread: branch
/// characters only, no leading `-`, `/` or `.`, no `..`, `//` or `/.`, and no trailing
/// `/`, `.` or `.lock`.
bool isBranchName(string name) @safe pure
{
	if (name.length == 0 || name[0] == '-' || name[0] == '/' || name[0] == '.')
		return false;
	if (name.endsWith("/") || name.endsWith(".") || name.endsWith(".lock"))
		return false;
	if ([`..`, `//`, `/.`].canFind!(sequence => name.canFind(sequence)))
		return false;
	return name.all!(c => c.isAlphaNum || c == '.' || c == '_' || c == '-' || c == '/');
}

/// The plan in `json` (the value of `AGENT_DELIVERY`), or an empty plan when the run
/// delivers nothing. Throws on a malformed plan: the controller never writes one.
DeliveryPlan parsePlan(string json)
{
	return json.length ? fromJson!DeliveryPlan(parseJsonString(json)) : DeliveryPlan.init;
}

/// Whether `plan` asks for a delivery at all.
bool delivers(const DeliveryPlan plan) @safe pure nothrow
{
	return plan.branch.length > 0;
}

version (unittest)
{
	import fluent.asserts;
	import agentcore.crds.serialization : toJson;

	private void deliveringFixtures(out Agent agent, out AgentDefinitionSpec recipe) @safe
	{
		agent.metadata.name = "fix-run-1";
		agent.spec.parameters = ["ticket": "ENG-1"];
		recipe.delivery.pullRequest.base = "main";
		recipe.delivery.pullRequest.titleTemplate = "Fix {ticket}";
		auto repo = RepoRef("app", "o/app");
		repo.tokenSecret = "GH_TOKEN_APP";
		recipe.resources.repos = [repo];
	}
}

@safe unittest // a plan pushes agent/<name> of the first repo and renders the title from the parameters
{
	Agent agent;
	AgentDefinitionSpec recipe;
	deliveringFixtures(agent, recipe);

	auto plan = planFor(agent, recipe);

	plan.should.equal(DeliveryPlan(recipe.resources.repos[0], "o/app", "agent/fix-run-1", "main", "Fix ENG-1",
		false, "https://api.github.com", "/workspace/app", "/outbox"));
}

@safe unittest // the Agent's own branch and targetRepo win over the defaults
{
	Agent agent;
	AgentDefinitionSpec recipe;
	deliveringFixtures(agent, recipe);
	agent.spec.branch = "fix/eng-1";
	agent.spec.targetRepo = "upstream/app";
	recipe.delivery.pullRequest.apiUrl = "https://ghe.example.com/api/v3";

	const plan = planFor(agent, recipe);

	[plan.branch, plan.slug, plan.apiUrl].should.equal(["fix/eng-1", "upstream/app", "https://ghe.example.com/api/v3"]);
}

@safe unittest // a delivering recipe with a repo, a token and an interactive execution has no violation
{
	Agent agent;
	AgentDefinitionSpec recipe;
	deliveringFixtures(agent, recipe);
	Agent plain;

	[deliveryViolation(agent, recipe), deliveryViolation(plain, AgentDefinitionSpec.init)].should.equal(["", ""]);
}

@safe unittest // each unusable delivery names what is missing
{
	string violation(void delegate(ref Agent, ref AgentDefinitionSpec) @safe change)
	{
		Agent agent;
		AgentDefinitionSpec recipe;
		deliveringFixtures(agent, recipe);
		change(agent, recipe);
		return deliveryViolation(agent, recipe);
	}

	[
		violation((ref a, ref r) { r.execution = Execution.realtime; }),
		violation((ref a, ref r) { r.resources.repos = null; }),
		violation((ref a, ref r) { r.resources.repos[0].url = "git@github.com:o/app.git"; }),
		violation((ref a, ref r) { a.spec.branch = "--force"; }),
		violation((ref a, ref r) { r.resources.repos[0].tokenSecret = ""; }),
	].should.equal([
		"delivery.pullRequest requires interactive execution",
		"delivery.pullRequest needs a repo in resources.repos",
		"delivery.pullRequest needs the Agent's targetRepo or resources.repos[0] as a GitHub owner/name",
		"delivery.pullRequest cannot use branch '--force' with base 'main'",
		"delivery.pullRequest needs resources.repos[0].token_secret or a git_credential_url parameter",
	]);
}

@safe unittest // a broker parameter stands in for the repo's token secret
{
	Agent agent;
	AgentDefinitionSpec recipe;
	deliveringFixtures(agent, recipe);
	recipe.resources.repos[0].tokenSecret = "";
	agent.spec.parameters["git_credential_url"] = "https://broker.example.com";

	deliveryViolation(agent, recipe).should.equal("");
}

@safe unittest // branch names git accepts pass and option- or traversal-shaped ones do not
{
	[isBranchName("main"), isBranchName("agent/fix-run-1"), isBranchName("release-1.2_x")]
		.should.equal([true, true, true]);
	[isBranchName(""), isBranchName("-f"), isBranchName("a..b"), isBranchName("a//b"), isBranchName("a/.b"),
		isBranchName("a.lock"), isBranchName("a/"), isBranchName("a b"), isBranchName("a@{1}"),
		isBranchName("a:b")]
		.should.equal([false, false, false, false, false, false, false, false, false, false]);
}

unittest // a plan round-trips through AGENT_DELIVERY and an unset one delivers nothing
{
	Agent agent;
	AgentDefinitionSpec recipe;
	deliveringFixtures(agent, recipe);
	auto plan = planFor(agent, recipe);

	parsePlan(toJson(plan).toString()).should.equal(plan);
	[delivers(parsePlan(toJson(plan).toString())), delivers(parsePlan(""))].should.equal([true, false]);
}
