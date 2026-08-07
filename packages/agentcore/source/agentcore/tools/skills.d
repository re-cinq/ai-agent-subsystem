module agentcore.tools.skills;

import std.ascii : isAlphaNum;

/// A skill name safe to embed in the init's shell path/arguments: non-empty, only
/// `[A-Za-z0-9._-]`, no leading dot (blocks `.`/`..` traversal), no path separators
/// or shell metacharacters. Names come from the org-authored recipe; this is
/// defense-in-depth so a bad name can never break out of the staging path.
bool safeSkillName(string name) @safe pure nothrow
{
	if (name.length == 0 || name[0] == '.')
		return false;
	foreach (c; name)
		if (!(isAlphaNum(c) || c == '.' || c == '_' || c == '-'))
			return false;
	return true;
}

/// Parse the `AGENT_SKILLS` JSON array (e.g. `["review","tdd"]`) into skill names.
/// Tolerant: `[]` for empty/blank/non-array/unparseable input (a malformed value must
/// never crash the init — it just stages no named skills).
string[] parseSkills(string json)
{
	import std.json : parseJSON, JSONType;

	if (json.length == 0)
		return [];
	try
	{
		auto parsed = parseJSON(json);
		if (parsed.type != JSONType.array)
			return [];
		string[] names;
		foreach (item; parsed.array)
			if (item.type == JSONType.string)
				names ~= item.str;
		return names;
	}
	catch (Exception)
		return [];
}

version (unittest) import fluent.asserts;

@safe unittest
{
	safeSkillName("review-checklist").should.equal(true);
	safeSkillName("lore_test-commands.v2").should.equal(true);
	safeSkillName("").should.equal(false);
	safeSkillName("../evil").should.equal(false);
	safeSkillName("has space").should.equal(false);
	safeSkillName(".hidden").should.equal(false);
	safeSkillName("a;rm -rf /").should.equal(false);
}

unittest
{
	parseSkills(`["a","b"]`).should.equal(["a", "b"]);
	parseSkills("").should.equal(cast(string[]) []);
	parseSkills("not json").should.equal(cast(string[]) []);
	parseSkills("{}").should.equal(cast(string[]) []);
	// non-string array entries are skipped, not fatal.
	parseSkills(`["ok",3,null]`).should.equal(["ok"]);
}
