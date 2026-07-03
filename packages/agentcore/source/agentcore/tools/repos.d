module agentcore.tools.repos;

import vibe.data.json : Json, parseJsonString;

import agentcore.crds.repo_ref : RepoRef;
import agentcore.crds.serialization : fromJson;

/// Parse a JSON array of repos (the value of the `AGENT_REPOS` env var the
/// controller builds from the recipe's `resources.repos`) into the `RepoRef` CRD
/// structs the controller serialized — the same type, so no field is dropped here.
/// An entry missing the required `name`/`url` is skipped (the controller never emits
/// one); a malformed document yields an empty list rather than throwing.
RepoRef[] parseRepos(string json)
{
	if (json.length == 0)
		return null;

	RepoRef[] repos;
	try
	{
		foreach (entry; parseJsonString(json).get!(Json[]))
			if ("name" in entry && "url" in entry)
				repos ~= fromJson!RepoRef(entry);
	}
	catch (Exception)
		return null;
	return repos;
}

version (unittest) import fluent.asserts;

unittest
{
	auto repos = parseRepos(
		`[{"name":"app","url":"https://github.com/o/app","ref":"main","path":"/ws/app","token_secret":"GH_TOKEN"},`
		~ `{"name":"lib","url":"o/lib"}]`);
	repos.length.should.equal(2);
	repos[0].should.equal(RepoRef("app", "https://github.com/o/app", "main", "/ws/app", "GH_TOKEN"));
	repos[1].name.should.equal("lib");
	repos[1].url.should.equal("o/lib");
	repos[1].ref_.should.equal("");

	parseRepos("").should.beNull;
	parseRepos("not json").should.beNull;
	parseRepos("[]").length.should.equal(0);
	// entries missing the required name/url are skipped
	parseRepos(`[{"url":"o/x"}]`).length.should.equal(0);
	parseRepos(`[{"name":"x"}]`).length.should.equal(0);
}
