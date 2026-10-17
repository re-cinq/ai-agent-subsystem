module agentcore.crds.delivery_spec;

import agentcore.crds.schema;

/// The REST API a pull request is opened through when `apiUrl` is not set.
enum defaultGithubApiUrl = "https://api.github.com";

/// A pull request opened from the run's work branch once the agent exits successfully.
/// A courier container pushes the branch and calls the GitHub API, so the agent
/// container never holds a token that can push.
@Description("Open a pull request from the run's work branch; the push happens outside the agent container.")
struct PullRequestDelivery
{
	@optional @Required @Description("Branch the pull request merges into.")
	string base;

	@optional @Required @Description(
		"Pull request title; {placeholder} tokens are filled from the Agent's parameters.")
	string titleTemplate;

	@optional @Description("Open the pull request as a draft.")
	bool draft;

	@optional @Description("GitHub REST API base URL; defaults to https://api.github.com.")
	string apiUrl;
}

@Description("What happens to the run's work once the agent exits.")
struct DeliverySpec
{
	@optional PullRequestDelivery pullRequest;
}

/// Whether `delivery` asks for a pull request. `base` is required by the schema
/// whenever `pullRequest` is present, so an empty one means none was asked for.
bool opensPullRequest(const DeliverySpec delivery) @safe pure nothrow
{
	return delivery.pullRequest.base.length > 0;
}

version (unittest) import fluent.asserts;

@safe unittest // a delivery with a base opens a pull request and an empty one does not
{
	DeliverySpec withBase;
	withBase.pullRequest.base = "main";

	[opensPullRequest(withBase), opensPullRequest(DeliverySpec.init)].should.equal([true, false]);
}
