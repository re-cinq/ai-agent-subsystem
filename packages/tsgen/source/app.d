/// CLI for the contract generators: `ai-agent-tsgen emit <outfile>` writes the
/// TypeScript types, `ai-agent-tsgen emit-go <outfile>` the Go types,
/// `ai-agent-tsgen emit-python <outfile>` the Python models,
/// `ai-agent-tsgen emit-rust <outfile>` the Rust types,
/// `ai-agent-tsgen emit-csharp <outfile>` the C# types and
/// `ai-agent-tsgen emit-java <outdir>` one Java file per type (replacing the directory's
/// `.java` files). Backs every contract package and its drift check.
module app;

import std.file : write, mkdirRecurse, dirEntries, SpanMode, remove;
import std.path : dirName, buildPath, extension;
import std.stdio : writeln, stderr;

import csgen : emitCsTypes;
import gogen : emitGoTypes;
import javagen : emitJavaTypes;
import pygen : emitPyTypes;
import rustgen : emitRustTypes;
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
		const emitters = ["emit": &emitTypes, "emit-go": &emitGoTypes, "emit-python": &emitPyTypes,
			"emit-rust": &emitRustTypes, "emit-csharp": &emitCsTypes];
		if (args.length < 3 || (args[1] !in emitters && args[1] != "emit-java"))
		{
			stderr.writeln("usage: ai-agent-tsgen emit|emit-go|emit-python|emit-rust|emit-csharp <outfile> | emit-java <outdir>");
			return 2;
		}

		const target = args[2];
		if (args[1] == "emit-java")
		{
			writeJavaDirectory(target);
			writeln("wrote ", target);
			return 0;
		}
		const dir = dirName(target);
		if (dir.length)
			mkdirRecurse(dir);
		write(target, emitters[args[1]]());
		writeln("wrote ", target);
		return 0;
	}

	/// Replaces every `.java` file in `outdir` with the generated set, so a removed type disappears.
	void writeJavaDirectory(string outdir)
	{
		mkdirRecurse(outdir);
		foreach (entry; dirEntries(outdir, SpanMode.shallow))
		{
			if (entry.name.extension == ".java")
				remove(entry.name);
		}
		foreach (fileName, content; emitJavaTypes())
			write(buildPath(outdir, fileName), content);
	}
}
