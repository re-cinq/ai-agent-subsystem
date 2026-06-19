module app;

import std.stdio : stderr;

import crdgen : writeStructures;

int main(string[] args)
{
	if (args.length >= 2 && args[1] == "write-structures")
		return args[1 .. $].writeStructures;

	stderr.writeln("usage: ai-agent-crdgen write-structures <dir>");
	return 2;
}
