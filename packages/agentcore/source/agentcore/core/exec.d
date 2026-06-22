module agentcore.core.exec;

import std.algorithm.searching : canFind;
import std.file : exists, isFile;
import std.path : buildPath;
import std.process : environment;
import std.string : split;

version (unittest) import fluent.asserts;

/// Resolve `cmd` to an existing file: the path itself when it contains a `/`, else
/// the first match on `PATH`. Returns "" when not found.
string findExecutable(string cmd)
{
	if (cmd.canFind('/'))
		return (exists(cmd) && isFile(cmd)) ? cmd : "";

	foreach (dir; environment.get("PATH", "").split(':'))
	{
		if (dir.length == 0)
			continue;
		const candidate = buildPath(dir, cmd);
		if (exists(candidate) && isFile(candidate))
			return candidate;
	}
	return "";
}

unittest
{
	findExecutable("sh").length.should.be.greaterThan(0);
	findExecutable("this-binary-should-not-exist-zzz").should.equal("");
	findExecutable("/bin/no-such-file").should.equal("");
}
