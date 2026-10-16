module agentcore.core.token;

import std.algorithm.searching : startsWith;
import std.digest : LetterCase, toHexString;
import std.digest.hmac : hmac;
import std.digest.sha : SHA256;
import std.string : representation;

version (unittest) import fluent.asserts;

/// The bearer token the controller and a realtime run's supervisor share: an HMAC-SHA256
/// of the Agent's uid under the controller's signing key, as lowercase hex. Any replica
/// derives the same token without storing it, and one leaked token opens one run only.
string runToken(string signingKey, string agentUid) @safe
{
	auto mac = agentUid.representation.hmac!SHA256(signingKey.representation);
	return toHexString!(LetterCase.lower)(mac).idup;
}

/// Whether `presented` equals `expected`, in time independent of where they differ.
bool tokenMatches(string presented, string expected) @safe pure nothrow @nogc
{
	if (presented.length != expected.length || expected.length == 0)
		return false;
	ubyte difference;
	foreach (i; 0 .. expected.length)
		difference |= presented[i] ^ expected[i];
	return difference == 0;
}

/// The token of an `Authorization: Bearer <token>` header value, or "".
string bearerOf(string authorization) @safe pure nothrow
{
	enum scheme = "Bearer ";
	return authorization.startsWith(scheme) ? authorization[scheme.length .. $] : "";
}

unittest // a run token is 64 lowercase hex chars, stable per uid and distinct across uids and keys
{
	import std.regex : matchFirst;

	const token = runToken("key", "uid-1");
	matchFirst(token, `^[0-9a-f]{64}$`).empty.should.equal(false);
	[runToken("key", "uid-1") == token, runToken("key", "uid-2") == token, runToken("other", "uid-1") == token]
		.should.equal([true, false, false]);
}

@safe unittest // tokens match only when equal and non-empty
{
	[tokenMatches("abc", "abc"), tokenMatches("abd", "abc"), tokenMatches("ab", "abc"), tokenMatches("", "")]
		.should.equal([true, false, false, false]);
}

@safe unittest // the bearer token is read from a Bearer header and nothing else
{
	[bearerOf("Bearer t-1"), bearerOf("Basic dTpw"), bearerOf("")].should.equal(["t-1", "", ""]);
}
