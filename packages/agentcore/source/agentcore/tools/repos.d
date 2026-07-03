module agentcore.tools.repos;

import vibe.data.json : Json, parseJsonString;

import agentcore.crds.repo_ref : RepoRef;

/// Parse a JSON array of repos (the value of the `AGENT_REPOS` env var the
/// controller builds from the recipe's `resources.repos`) into `RepoRef`s.
/// Mirrors `parseSinks`: a malformed document, or an entry missing the required
/// `name`/`url`, is skipped rather than throwing.
RepoRef[] parseRepos(string json)
{
	if (json.length == 0)
		return null;

	RepoRef[] repos;
	try
	{
		foreach (entry; parseJsonString(json).get!(Json[]))
		{
			auto name = "name" in entry;
			auto url = "url" in entry;
			if (name is null || url is null)
				continue;
			RepoRef r;
			r.name = (*name).get!string;
			r.url = (*url).get!string;
			if (auto ref_ = "ref" in entry)
				r.ref_ = (*ref_).get!string;
			if (auto path = "path" in entry)
				r.path = (*path).get!string;
			if (auto token = "token_secret" in entry)
				r.tokenSecret = (*token).get!string;
			repos ~= r;
		}
	}
	catch (Exception)
		return null;
	return repos;
}

unittest
{
	auto repos = parseRepos(
		`[{"name":"app","url":"https://github.com/o/app","ref":"main","path":"/ws/app","token_secret":"GH_TOKEN"},`
		~ `{"name":"lib","url":"o/lib"}]`);
	assert(repos.length == 2);
	assert(repos[0].name == "app");
	assert(repos[0].url == "https://github.com/o/app");
	assert(repos[0].ref_ == "main");
	assert(repos[0].path == "/ws/app");
	assert(repos[0].tokenSecret == "GH_TOKEN");
	assert(repos[1].name == "lib" && repos[1].url == "o/lib" && repos[1].ref_ == "");

	assert(parseRepos("") is null);
	assert(parseRepos("not json") is null);
	assert(parseRepos("[]").length == 0);
	// entries missing the required name/url are skipped
	assert(parseRepos(`[{"url":"o/x"}]`).length == 0);
	assert(parseRepos(`[{"name":"x"}]`).length == 0);
}
