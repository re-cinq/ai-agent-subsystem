module agentcore.log;

import std.stdio : stderr;

/// Write `message` to stderr, never throwing. For best-effort, non-fatal error
/// reporting from `nothrow` contexts — only a broken stderr can suppress it.
void logError(string message) @safe nothrow
{
	try
		() @trusted { stderr.writeln(message); }();
	catch (Exception)
	{
	}
}
