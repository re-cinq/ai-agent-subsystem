/// Naming helpers shared by the Java, Python, C# and Rust emitters: they all split a wire
/// name into words the same way and only differ in how they join them.
module wirenames;

import std.algorithm : map;
import std.array : join;
import std.ascii : isUpper, toLower, toUpper;
import std.string : toLower_ = toLower, toUpper_ = toUpper;

/// The words of a wire name: split on `_`, `-`, `.` and lower-to-upper boundaries.
string[] wireWords(string wire)
{
	string[] words;
	string word;
	foreach (character; wire)
	{
		if (character == '_' || character == '-' || character == '.')
		{
			words ~= word;
			word = "";
			continue;
		}
		if (isUpper(character) && word.length)
		{
			words ~= word;
			word = "";
		}
		word ~= character;
	}
	words ~= word;
	return words;
}

/// `word` with its first letter in capitals.
string capitalized(string word)
{
	return word.length ? cast(char) toUpper(word[0]) ~ word[1 .. $] : word;
}

/// `STREAM_JSON` from `stream-json`.
string upperSnake(string wire)
{
	return wireWords(wire).map!(toUpper_).join("_");
}

/// `pr_url` from `prUrl`.
string lowerSnake(string wire)
{
	return wireWords(wire).map!(toLower_).join("_");
}

/// `StreamJson` from `stream-json`.
string pascal(string wire)
{
	return wireWords(wire).map!(word => capitalized(toLower_(word))).join;
}

/// `HeadersSecret` from `headers_secret`, keeping the case inside each word.
string pascalKeepCase(string wire)
{
	return wireWords(wire).map!(capitalized).join;
}

/// `headersSecret` from `headers_secret`.
string camel(string wire)
{
	const words = wireWords(wire);
	return words[0] ~ words[1 .. $].map!(capitalized).join;
}

version (unittest) import fluent.asserts;

unittest // each case style joins the same words
{
	[upperSnake("stream-json"), lowerSnake("prUrl"), pascal("stream-json"), pascal("Succeeded"),
		pascalKeepCase("headers_secret"), camel("headers_secret")]
		.should.equal(["STREAM_JSON", "pr_url", "StreamJson", "Succeeded", "HeadersSecret", "headersSecret"]);
}
