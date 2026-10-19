module courier;

import core.thread : Thread;
import core.time : Duration, MonoTime, msecs;
import std.algorithm.searching : any, startsWith;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, readText;
import std.process : Config, environment, execute, pipeProcess, Redirect, wait;
import std.string : lastIndexOf, stripRight;
import std.uri : encodeComponent;

import vibe.data.json : Json, parseJsonString;

import agentcore.core.env : deadlineMarginMs, envDeadlineMs, envGitCredential, envGitCredentialUrl;
import agentcore.core.log : logError;
import agentcore.delivery.outbox : bundleName, deliveryEvent, DeliveryReport, DeliveryStatus, OutboxState,
	outcomeName, parseOutcome;
import agentcore.delivery.plan : delivers, DeliveryPlan;
import agentcore.output.event : sourceFromEnv;
import agentcore.output.output : sinksFromEnv;
import agentcore.tools.git_tool : brokerSlug, pushStep;

import notify : curlConfEscape, notify;

/// The courier: wait for the supervisor's outbox outcome, push the bundled work branch
/// with the run's token, open the pull request, and raise the `delivery` event the
/// controller reads `status.prUrl` from. Runs beside the agent in its own container, so
/// the token never enters the agent's. Exits 0 when the pull request is open or there
/// was nothing to deliver, 1 when the delivery failed — which fails the run.
int courier(const DeliveryPlan plan)
{
	enforce(delivers(plan), "the courier needs a delivery plan in AGENT_DELIVERY");
	const report = deliver(plan);
	notify(sinksFromEnv(), sourceFromEnv(), deliveryEvent(report));
	if (report.status == DeliveryStatus.failed)
		logError("[courier] delivery failed: " ~ report.reason);
	return report.status == DeliveryStatus.failed ? 1 : 0;
}

private DeliveryReport deliver(const DeliveryPlan plan)
{
	const marker = plan.outbox ~ "/" ~ outcomeName;
	if (!awaitFile(marker, patienceFor(environment.get(envDeadlineMs, ""))))
		return failed("the agent container left no outbox outcome");
	const outcome = parseOutcome(readText(marker));
	if (outcome.state == OutboxState.empty)
		return DeliveryReport(DeliveryStatus.skipped, "", outcome.reason);
	if (outcome.state == OutboxState.broken)
		return failed(outcome.reason);

	const brokerUrl = environment.get(envGitCredentialUrl, "");
	const gitDir = environment.get("HOME", ".") ~ "/push.git";
	foreach (step; transferSteps(plan, gitDir))
		if (!ran(step))
			return failed("reading the outbox bundle failed");
	if (!ran(pushStep(plan.repo, brokerUrl, gitDir, plan.branch)))
		return failed("pushing " ~ plan.branch ~ " failed");

	const token = apiToken(plan, brokerUrl);
	if (token.length == 0)
		return failed("no token to call the GitHub API with");
	const created = call(requestConfig("POST", pullsUrl(plan), token, pullRequestBody(plan)));
	if (!alreadyOpen(created))
		return createdReport(created);
	return existingReport(call(requestConfig("GET", openPullsUrl(plan), token, "")));
}

private DeliveryReport failed(string reason) @safe pure nothrow
{
	return DeliveryReport(DeliveryStatus.failed, "", reason);
}

/// The steps that rebuild the work branch in a bare repository of the courier's own,
/// from the bundle alone: the courier never runs git in the agent's clone, whose
/// config and hooks the agent controls.
string[][] transferSteps(const DeliveryPlan plan, string gitDir) @safe pure
{
	return [
		["git", "init", "-q", "--bare", gitDir],
		["git", "-C", gitDir, "fetch", "-q", plan.outbox ~ "/" ~ bundleName, "+HEAD:refs/heads/" ~ plan.branch],
	];
}

/// How long the courier waits for the outbox outcome: past the supervisor's own
/// deadline by half the margin the Job deadline leaves, so a supervisor that forces the
/// agent down at its deadline still gets its outcome read. Unbounded without a deadline.
Duration patienceFor(string deadlineMs) @safe
{
	try
	{
		const ms = deadlineMs.to!long;
		return ms > 0 ? (ms + deadlineMarginMs / 2).msecs : Duration.max;
	}
	catch (Exception)
		return Duration.max;
}

private bool awaitFile(string path, Duration patience)
{
	const start = MonoTime.currTime;
	while (!path.exists && MonoTime.currTime - start < patience)
		Thread.sleep(500.msecs);
	return path.exists;
}

private bool ran(string[] step)
{
	const result = execute(step, null, Config.stderrPassThrough);
	if (result.status != 0)
		logError("[courier] " ~ result.output.stripRight);
	return result.status == 0;
}

/// The token the GitHub API call authenticates with: minted by the broker when the run
/// pushes through one, as the push did, else the value of the repo's `token_secret`.
private string apiToken(const DeliveryPlan plan, string brokerUrl)
{
	const slug = brokerSlug(plan.repo, brokerUrl);
	if (slug.length == 0)
		return plan.repo.tokenSecret.length ? environment.get(plan.repo.tokenSecret, "") : "";
	const credential = environment.get(envGitCredential, "");
	const minted = call(brokerConfig(brokerUrl, credential, slug));
	return minted.status == 200 ? brokerToken(minted.body_) : "";
}

/// The curl config asking the broker for a token scoped to `slug`.
string brokerConfig(string brokerUrl, string credential, string slug)
{
	return curlRequest("POST", brokerUrl, ["Authorization: Bearer " ~ credential,
		"Content-Type: application/json"], Json(["repo": Json(slug)]).toString());
}

/// The token in a broker answer `{"username":…,"password":…}`, or "".
string brokerToken(string answer)
{
	try
		return parseJsonString(answer)["password"].opt!string("");
	catch (Exception)
		return "";
}

/// What one curl call answered: the HTTP status (0 when no response arrived) and body.
struct HttpReply
{
	int status;
	string body_;
}

/// One request with the `curl` CLI, its whole invocation fed on stdin so the token in
/// its headers never reaches an argv.
private HttpReply call(string config)
{
	auto pipes = pipeProcess(["curl", "--config", "-"], Redirect.stdin | Redirect.stdout);
	pipes.stdin.write(config);
	pipes.stdin.close();
	string output;
	foreach (chunk; pipes.stdout.byChunk(4096))
		output ~= cast(const(char)[]) chunk;
	wait(pipes.pid);
	return parseReply(output);
}

/// The reply in curl's output: the body, then the status curl's `write-out` appends on
/// a line of its own.
HttpReply parseReply(string output) @safe
{
	const newline = output.lastIndexOf('\n');
	try
		return HttpReply(output[newline + 1 .. $].to!int, newline < 0 ? "" : output[0 .. newline]);
	catch (Exception)
		return HttpReply(0, output);
}

/// The curl config for a GitHub REST call with `token`, carrying `body_` when not empty.
string requestConfig(string method, string url, string token, string body_) @safe
{
	return curlRequest(method, url, ["Accept: application/vnd.github+json", "Authorization: Bearer " ~ token,
		"X-GitHub-Api-Version: 2022-11-28", "Content-Type: application/json"], body_);
}

private string curlRequest(string method, string url, const string[] headers, string body_) @safe
{
	string conf = "silent\nshow-error\nmax-time = 60\nrequest = \"" ~ method ~ "\"\n";
	conf ~= "url = \"" ~ curlConfEscape(url) ~ "\"\n";
	foreach (header; headers)
		conf ~= "header = \"" ~ curlConfEscape(header) ~ "\"\n";
	if (body_.length)
		conf ~= "data-raw = \"" ~ curlConfEscape(body_) ~ "\"\n";
	return conf ~ "write-out = \"\\n%{http_code}\"\n";
}

/// `POST /repos/{owner}/{repo}/pulls` on the plan's API.
string pullsUrl(const DeliveryPlan plan) @safe pure
{
	const api = plan.apiUrl.length && plan.apiUrl[$ - 1] == '/' ? plan.apiUrl[0 .. $ - 1] : plan.apiUrl;
	return api ~ "/repos/" ~ plan.slug ~ "/pulls";
}

/// The open pull requests from the plan's branch, `head` qualified by the repo's owner.
string openPullsUrl(const DeliveryPlan plan)
{
	const owner = plan.slug[0 .. plan.slug.lastIndexOf('/')];
	return pullsUrl(plan) ~ "?state=open&head=" ~ encodeComponent(owner ~ ":" ~ plan.branch);
}

/// The pull request the plan asks for, as the API's JSON body.
string pullRequestBody(const DeliveryPlan plan)
{
	return Json(["title": Json(plan.title), "head": Json(plan.branch), "base": Json(plan.base),
		"draft": Json(plan.draft)]).toString();
}

/// Whether the create call was refused because a pull request from this branch is
/// already open: a 422 whose errors say so. A rerun of the same Agent hits it.
bool alreadyOpen(const HttpReply reply)
{
	if (reply.status != 422)
		return false;
	try
		return parseJsonString(reply.body_)["errors"].opt!(Json[])(null)
			.any!(error => error["message"].opt!string("").startsWith("A pull request already exists"));
	catch (Exception)
		return false;
}

/// The report for the create call's `reply`: opened at its `html_url` on a 201, else
/// failed with what GitHub said.
DeliveryReport createdReport(const HttpReply reply)
{
	if (reply.status != 201)
		return failed(refusal("opening the pull request", reply));
	return openedAt(parseJsonString(reply.body_)["html_url"].opt!string(""), reply);
}

/// The report for the lookup of the already-open pull request: opened at the first
/// one listed, else failed.
DeliveryReport existingReport(const HttpReply reply)
{
	if (reply.status != 200)
		return failed(refusal("finding the open pull request", reply));
	const pulls = parseJsonString(reply.body_).opt!(Json[])(null);
	return openedAt(pulls.length ? pulls[0]["html_url"].opt!string("") : "", reply);
}

private DeliveryReport openedAt(string url, const HttpReply reply)
{
	return url.length ? DeliveryReport(DeliveryStatus.opened, url) : failed(refusal("reading the pull request", reply));
}

/// Why GitHub refused `what`: its status and `message`, when it sent one.
private string refusal(string what, const HttpReply reply)
{
	string message;
	try
		message = parseJsonString(reply.body_)["message"].opt!string("");
	catch (Exception)
		message = "";
	return what ~ " answered " ~ reply.status.to!string ~ (message.length ? ": " ~ message : "");
}

version (unittest)
{
	import fluent.asserts;
	import agentcore.crds.repo_ref : RepoRef;

	private DeliveryPlan planFixture() @safe
	{
		DeliveryPlan plan;
		plan.repo = RepoRef("app", "o/app");
		plan.repo.tokenSecret = "GH_TOKEN_APP";
		plan.slug = "o/app";
		plan.branch = "agent/run-1";
		plan.base = "main";
		plan.title = `Fix "ENG-1"`;
		plan.draft = true;
		plan.apiUrl = "https://api.github.com/";
		plan.clone = "/workspace/app";
		plan.outbox = "/outbox";
		return plan;
	}
}

unittest // the pull request is posted to the repo's pulls on the plan's API with its title, branches and draft flag
{
	const plan = planFixture();

	pullsUrl(plan).should.equal("https://api.github.com/repos/o/app/pulls");
	parseJsonString(pullRequestBody(plan)).should.equal(parseJsonString(
		`{"title":"Fix \"ENG-1\"","head":"agent/run-1","base":"main","draft":true}`));
}

unittest // the lookup of an already-open pull request filters by owner:branch, encoded
{
	openPullsUrl(planFixture()).should.equal(
		"https://api.github.com/repos/o/app/pulls?state=open&head=o%3Aagent%2Frun-1");
}

@safe unittest // the request carries the token in a header of the config on stdin and asks curl for the status
{
	const conf = requestConfig("POST", "https://api.github.com/repos/o/app/pulls", "t0k", `{"title":"x"}`);

	conf.should.equal("silent\nshow-error\nmax-time = 60\nrequest = \"POST\"\n"
		~ "url = \"https://api.github.com/repos/o/app/pulls\"\n"
		~ "header = \"Accept: application/vnd.github+json\"\n"
		~ "header = \"Authorization: Bearer t0k\"\n"
		~ "header = \"X-GitHub-Api-Version: 2022-11-28\"\n"
		~ "header = \"Content-Type: application/json\"\n"
		~ "data-raw = \"{\\\"title\\\":\\\"x\\\"}\"\n"
		~ "write-out = \"\\n%{http_code}\"\n");
}

@safe unittest // a GET carries no body
{
	requestConfig("GET", "https://api.github.com/x", "t0k", "").should.not.contain("data-raw");
}

@safe unittest // curl's output splits into the body and the status it appended, and no response is status 0
{
	[parseReply("{\"a\":1}\n201"), parseReply("\n000"), parseReply("")].should.equal([
		HttpReply(201, `{"a":1}`), HttpReply(0, ""), HttpReply(0, ""),
	]);
}

unittest // a 201 opens the pull request at its html_url
{
	createdReport(HttpReply(201, `{"number":7,"html_url":"https://github.com/o/app/pull/7"}`))
		.should.equal(DeliveryReport(DeliveryStatus.opened, "https://github.com/o/app/pull/7"));
}

unittest // a 422 saying the pull request exists is told apart from any other refusal
{
	const exists = HttpReply(422, `{"message":"Validation Failed","errors":[{"resource":"PullRequest",`
		~ `"code":"custom","message":"A pull request already exists for o:agent/run-1."}]}`);
	const noCommits = HttpReply(422, `{"message":"Validation Failed","errors":[{"resource":"PullRequest",`
		~ `"code":"custom","message":"No commits between main and agent/run-1"}]}`);

	[alreadyOpen(exists), alreadyOpen(noCommits), alreadyOpen(HttpReply(201, "{}")), alreadyOpen(HttpReply(422, "<html>"))]
		.should.equal([true, false, false, false]);
	createdReport(noCommits).should.equal(DeliveryReport(DeliveryStatus.failed, "",
		"opening the pull request answered 422: Validation Failed"));
}

unittest // the open pull request found by the lookup is the one reported
{
	existingReport(HttpReply(200, `[{"html_url":"https://github.com/o/app/pull/3"}]`))
		.should.equal(DeliveryReport(DeliveryStatus.opened, "https://github.com/o/app/pull/3"));
	existingReport(HttpReply(200, `[]`)).should.equal(DeliveryReport(DeliveryStatus.failed, "",
		"reading the pull request answered 200"));
}

unittest // a refusal without a JSON body still names the status
{
	createdReport(HttpReply(0, "")).should.equal(DeliveryReport(DeliveryStatus.failed, "",
		"opening the pull request answered 0"));
	existingReport(HttpReply(401, `{"message":"Bad credentials"}`)).should.equal(
		DeliveryReport(DeliveryStatus.failed, "", "finding the open pull request answered 401: Bad credentials"));
}

@safe unittest // the work branch is rebuilt in the courier's own bare repo from the bundle alone
{
	transferSteps(planFixture(), "/courier/push.git").should.equal([
		["git", "init", "-q", "--bare", "/courier/push.git"],
		["git", "-C", "/courier/push.git", "fetch", "-q", "/outbox/run.bundle", "+HEAD:refs/heads/agent/run-1"],
	]);
}

@safe unittest // the courier outwaits the supervisor's deadline by half the margin, and waits unbounded without one
{
	[patienceFor("1790000"), patienceFor(""), patienceFor("0"), patienceFor("soon")]
		.should.equal([1_795_000.msecs, Duration.max, Duration.max, Duration.max]);
}

unittest // the broker is asked for the repo with the run credential, and its password is the token
{
	brokerConfig("https://broker.example.com/creds", "v1.cred", "o/app").should.contain(
		"header = \"Authorization: Bearer v1.cred\"\n");
	[brokerToken(`{"username":"x-access-token","password":"ghs_1"}`), brokerToken("nope")]
		.should.equal(["ghs_1", ""]);
}
