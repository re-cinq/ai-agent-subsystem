/// CLI for the contract generators: `ai-agent-tsgen emit <outfile>` writes the
/// TypeScript types and `ai-agent-tsgen emit-go <outfile>` the Go types to `<outfile>`
/// (creating parent dirs). Backs both contract packages and their drift checks.
module app;

import std.file : write, mkdirRecurse;
import std.path : dirName;
import std.stdio : writeln, stderr;

import gogen : emitGoTypes;
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
		const emitters = ["emit": &emitTypes, "emit-go": &emitGoTypes];
		if (args.length < 3 || args[1] !in emitters)
		{
			stderr.writeln("usage: ai-agent-tsgen emit|emit-go <outfile>");
			return 2;
		}

		const outfile = args[2];
		const dir = dirName(outfile);
		if (dir.length)
			mkdirRecurse(dir);
		write(outfile, emitters[args[1]]());
		writeln("wrote ", outfile);
		return 0;
	}
}
