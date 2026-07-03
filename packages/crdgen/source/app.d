module app;

import std.stdio : stderr;

import crdgen : writeStructures;

int main(string[] args)
{
	// `dub test` runs main after the module unittests; return before the usage error so
	// the test binary exits 0.
	version (unittest)
		return 0;

	if (args.length >= 2 && args[1] == "write-structures")
		return args[1 .. $].writeStructures;

	stderr.writeln("usage: ai-agent-crdgen write-structures <dir>");
	return 2;
}
