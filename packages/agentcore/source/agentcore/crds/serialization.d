module agentcore.crds.serialization;

import std.traits : OriginalType;
import vibe.data.json : Json, JsonSerializer;
import vibe.data.serialization : name, deserializeWithPolicy;

import agentcore.crds.enums : PermissionMode;

// The CRD parse contract (kept from the hand-rolled parser it replaces, #85): the API
// server is trusted to send well-formed JSON, but every field is treated as optional and
// an unrecognised enum string degrades to the field's default instead of throwing. That
// leniency is expressed to vibe by two things: `@optional` on every field (absence keeps
// the default) and `CrdPolicy` below (a bad enum value keeps the enum's `.init` member).

/// The enum member whose string value equals `value`, or `fallback` when no member
/// matches (absent field, typo). All CRD enums are string-backed.
E toEnumMember(E)(string value, E fallback) @safe if (is(E == enum))
{
	static foreach (member; __traits(allMembers, E))
		if (value == cast(string) __traits(getMember, E, member))
			return __traits(getMember, E, member);
	return fallback;
}

/// The member an unrecognised wire value degrades to — the same default the CRD
/// struct field declares, so the parser and the CRD schema agree. `.init` (the first
/// member) is right for every enum whose default is its first member; `PermissionMode`
/// is the one whose declared default (`bypass`) is not, so it is named explicitly.
private E lenientDefault(E)() @safe if (is(E == enum))
{
	static if (is(E == PermissionMode))
		return PermissionMode.bypass;
	else
		return E.init;
}

/// vibe serialization policy for the CRD model: string-backed enums (de)serialize by their
/// wire value, and an unknown value on the wire falls back to `.init` rather than throwing.
/// `isPolicySerializable` matches only string-backed enums, so every other type keeps
/// vibe's default handling.
template CrdPolicy(T)
{
	static if (is(T == enum) && is(OriginalType!T == string))
	{
		static string toRepresentation(T value) @safe
		{
			return cast(string) value;
		}

		static T fromRepresentation(string value) @safe
		{
			return toEnumMember!T(value, lenientDefault!T);
		}
	}
}

/// Wire-name UDA for CRD fields whose JSON name differs from the D identifier (snake_case,
/// or D keywords like `ref`/`template`). It is vibe's `@name` bound to `CrdPolicy` so that
/// `deserializeWithPolicy` honours it — a plain `@name` (DefaultPolicy) is invisible once a
/// non-default policy is active. `jsonNameOf` reads it back for the CRD/TS generators.
alias wire = name!CrdPolicy;

/// Deserialize a CRD value under `CrdPolicy` (lenient enums). The single entry point every
/// parser uses in place of the old field-walking `specFromJson`.
T fromJson(T)(Json src)
{
	return deserializeWithPolicy!(JsonSerializer, CrdPolicy, T)(src);
}
