module agentcore.kube.outputcap;

import std.conv : to;

/// Keep only the last `maxBytes` bytes of a run pod's log so `status.output`
/// stays well under etcd's per-object limit; the tail holds the final result
/// event. When the log is cut, prepend a marker naming the dropped bytes. The
/// cut is snapped forward to a UTF-8 lead byte so the result is never invalid
/// UTF-8 (which would break JSON serialization of the status patch).
string capOutput(string log, size_t maxBytes) @safe pure
{
	if (log.length <= maxBytes)
		return log;

	size_t cut = log.length - maxBytes;
	while (cut < log.length && (log[cut] & 0xC0) == 0x80)
		cut++;
	return "...[truncated " ~ cut.to!string ~ " bytes]...\n" ~ log[cut .. $];
}

version (unittest) import fluent.asserts;

@safe unittest
{
	// Under the cap -> returned unchanged.
	capOutput("small log", 1024).should.equal("small log");
}

@safe unittest
{
	// Over the cap -> keep the tail, prepend a marker naming the dropped bytes.
	capOutput("HEADHEADTAILTAIL", 8).should.equal("...[truncated 8 bytes]...\n" ~ "TAILTAIL");
}

@safe unittest
{
	// A cut landing mid-codepoint snaps forward so the tail stays valid UTF-8.
	// "ab" ~ "é" ~ "cd": 'é' is 0xC3 0xA9; maxBytes=3 cuts at byte 3 (the 0xA9
	// continuation byte), which advances to byte 4 -> the tail is "cd".
	import std.utf : validate;

	const capped = capOutput("abécd", 3);
	capped.should.equal("...[truncated 4 bytes]...\ncd");
	validate(capped);
}
