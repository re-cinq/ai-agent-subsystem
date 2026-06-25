/// CLI for the TypeScript contract generator: `ai-agent-tsgen emit <outfile>`
/// writes the generated types to `<outfile>` (creating parent dirs). Backs the
/// `@re-cinq/agent-contracts` build and the contracts drift check.
module app;

import std.file : write, mkdirRecurse;
import std.path : dirName;
import std.stdio : writeln, stderr;

import tsgen : emitTypes;

version (unittest)
{
	// `dub test` builds this executable with -unittest; the module unittests run
	// automatically and this empty main lets the test binary exit afterwards
	// instead of writing a file.
	void main()
	{
	}
}
else
{
	int main(string[] args)
	{
		if (args.length < 3 || args[1] != "emit")
		{
			stderr.writeln("usage: ai-agent-tsgen emit <outfile>");
			return 2;
		}

		const outfile = args[2];
		const dir = dirName(outfile);
		if (dir.length)
			mkdirRecurse(dir);
		write(outfile, emitTypes());
		writeln("wrote ", outfile);
		return 0;
	}
}
