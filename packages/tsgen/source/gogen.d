/// Generates the Go contract types (`packages/agent-contracts-go/types.generated.go`)
/// from the same annotated `agentcore.crds` structs tsgen and crdgen read, so a Go
/// consumer gets types that cannot drift from the CRDs. The top-level kinds embed the
/// apimachinery TypeMeta/ObjectMeta and get a List type and DeepCopy methods, which
/// makes them real `runtime.Object`s for controller-runtime and client-go schemes.
///
/// The output is gofmt-stable without running gofmt: struct fields are separated by
/// blank lines (gofmt only aligns consecutive lines) and constants are top-level.
module gogen;

import std.algorithm : canFind, map;
import std.array : join, split;
import std.ascii : isUpper, toUpper;
import std.traits : isIntegral, isBoolean, isSomeString, isArray, isAssociativeArray,
	EnumMembers, ForeachType, ValueType;

import vibe.data.json : Json;

import described : describe;

import agentcore.crds.api_group : crGroup, crVersion;
import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.registry : CrdEnums, CrdKinds, CrdStructs;
import agentcore.crds.schema : descriptionOf, jsonNameOf, isRequired;

/// Words Go spells in capitals inside identifiers.
private immutable string[string] goInitialisms;

shared static this()
{
	goInitialisms = ["Id": "ID", "Uid": "UID", "Url": "URL", "Api": "API", "Http": "HTTP",
		"Mcp": "MCP", "Json": "JSON", "Sse": "SSE"];
}

/// An exported Go identifier from a wire name: `headers_secret` -> `HeadersSecret`,
/// `prUrl` -> `PrURL`, `stream-json` -> `StreamJSON`.
string goName(string wire)
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
	return words.map!(capitalized).join;
}

private string capitalized(string word)
{
	if (!word.length)
		return word;
	const titled = cast(char) toUpper(word[0]) ~ word[1 .. $];
	return titled in goInitialisms ? goInitialisms[titled] : titled;
}

/// Whether `T` is a top-level resource (it has its own CRD).
template isKind(T)
{
	enum isKind = () {
		bool found;
		static foreach (Kind; CrdKinds)
			found = found || is(T == Kind);
		return found;
	}();
}

/// The Go type expression for D type `FT`.
template goType(FT)
{
	static if (is(FT == Json))
		enum goType = "runtime.RawExtension";
	else static if (is(FT == enum))
		enum goType = FT.stringof;
	else static if (isIntegral!FT)
		enum goType = FT.sizeof == 8 ? "int64" : "int32";
	else static if (isBoolean!FT)
		enum goType = "bool";
	else static if (isSomeString!FT)
		enum goType = "string";
	else static if (isAssociativeArray!FT)
		enum goType = "map[string]" ~ goType!(ValueType!FT);
	else static if (isArray!FT)
		enum goType = "[]" ~ goType!(ForeachType!FT);
	else static if (is(FT == struct))
		enum goType = FT.stringof;
	else
		static assert(false, "gogen: unsupported field type " ~ FT.stringof);
}

/// Whether D type `FT` is a value Go copies by assignment (no references inside).
private enum isGoScalar(FT) = is(FT == enum) || isIntegral!FT || isBoolean!FT || isSomeString!FT;

/// Whether field `name` of `T` has a non-zero initializer, which crdgen turns into a
/// schema default. Go gets a pointer for those so "unset" stays distinguishable from
/// the zero value and the API server's default applies.
private bool hasSchemaDefault(T, string name)()
{
	alias FT = typeof(__traits(getMember, T, name));
	static if (isGoScalar!FT)
		return __traits(getMember, T.init, name) != FT.init;
	else
		return false;
}

/// A doc comment block for `text`, or "" when there is none.
private string docComment(string text, string indent)
{
	return text.length ? indent ~ "// " ~ text.split("\n").join("\n" ~ indent ~ "// ") ~ "\n" : "";
}

/// `type <Name> string` plus one constant per value.
string emitGoEnum(E)()
{
	string s = "type " ~ E.stringof ~ " string\n\n";
	static foreach (member; EnumMembers!E)
		s ~= "const " ~ E.stringof ~ goName(cast(string) member) ~ " " ~ E.stringof ~ " = \""
			~ cast(string) member ~ "\"\n";
	return s;
}

/// The struct declaration for `T`. A kind swaps its own apiVersion/kind/metadata for the
/// embedded apimachinery types.
string emitGoStruct(T)()
{
	string s = docComment(descriptionOf!T, "");
	s ~= "type " ~ T.stringof ~ " struct {\n";
	string separator;
	static if (isKind!T)
	{
		s ~= "\tmetav1.TypeMeta `json:\",inline\"`\n\n\tmetav1.ObjectMeta `json:\"metadata,omitempty\"`\n";
		separator = "\n";
	}
	static foreach (property; describe!T.properties)
	{{
		alias member = __traits(getMember, T, property.name);
		alias FT = typeof(member);
		static if (!(isKind!T && ["apiVersion", "kind", "metadata"].canFind(jsonNameOf!member)))
		{
			enum wire = jsonNameOf!member;
			enum pointer = hasSchemaDefault!(T, property.name)();
			enum omit = isRequired!member ? "" : (is(FT == struct) && !is(FT == Json) && !pointer)
				? ",omitzero" : ",omitempty";
			s ~= separator ~ docComment(descriptionOf!member, "\t");
			separator = "\n";
			s ~= "\t" ~ goName(wire) ~ " " ~ (pointer ? "*" : "") ~ goType!FT ~ " `json:\"" ~ wire ~ omit ~ "\"`\n";
		}
	}}
	s ~= "}\n";
	static if (isKind!T)
	{
		s ~= "\n// " ~ T.stringof ~ "List is a list of " ~ T.stringof ~ " resources.\n";
		s ~= "type " ~ T.stringof ~ "List struct {\n";
		s ~= "\tmetav1.TypeMeta `json:\",inline\"`\n\n\tmetav1.ListMeta `json:\"metadata,omitempty\"`\n\n";
		s ~= "\tItems []" ~ T.stringof ~ " `json:\"items\"`\n}\n";
	}
	return s;
}

/// The statements that deep-copy field `goField` of Go type `FT` from `in` to `out`,
/// or "" when the shallow `*out = *in` already copied it.
private string deepCopyField(FT, bool pointer)(string goField)
{
	static if (isGoScalar!FT && !pointer)
		return "";
	else static if (pointer)
		return "\tif in." ~ goField ~ " != nil {\n\t\tin, out := &in." ~ goField ~ ", &out." ~ goField
			~ "\n\t\t*out = new(" ~ goType!FT ~ ")\n\t\t**out = **in\n\t}\n";
	else static if (is(FT == Json) || (is(FT == struct) && !isAssociativeArray!FT))
		return "\tin." ~ goField ~ ".DeepCopyInto(&out." ~ goField ~ ")\n";
	else static if (isAssociativeArray!FT)
		return "\tif in." ~ goField ~ " != nil {\n\t\tin, out := &in." ~ goField ~ ", &out." ~ goField
			~ "\n\t\t*out = make(" ~ goType!FT ~ ", len(*in))\n\t\tfor key, value := range *in {\n"
			~ (isGoScalar!(ValueType!FT) ? "\t\t\t(*out)[key] = value\n" : "\t\t\t(*out)[key] = *value.DeepCopy()\n")
			~ "\t\t}\n\t}\n";
	else static if (isArray!FT)
		return "\tif in." ~ goField ~ " != nil {\n\t\tin, out := &in." ~ goField ~ ", &out." ~ goField
			~ "\n\t\t*out = make(" ~ goType!FT ~ ", len(*in))\n"
			~ (isGoScalar!(ForeachType!FT) ? "\t\tcopy(*out, *in)\n"
				: "\t\tfor index := range *in {\n\t\t\t(*in)[index].DeepCopyInto(&(*out)[index])\n\t\t}\n")
			~ "\t}\n";
	else
		return "";
}

/// DeepCopyInto and DeepCopy for `T`, plus DeepCopyObject and the List's methods for a kind.
string emitGoDeepCopy(T)()
{
	enum name = T.stringof;
	string s = "\n// DeepCopyInto copies the receiver into out. in must be non-nil.\n";
	s ~= "func (in *" ~ name ~ ") DeepCopyInto(out *" ~ name ~ ") {\n\t*out = *in\n";
	static if (isKind!T)
		s ~= "\tout.TypeMeta = in.TypeMeta\n\tin.ObjectMeta.DeepCopyInto(&out.ObjectMeta)\n";
	static foreach (property; describe!T.properties)
	{{
		alias member = __traits(getMember, T, property.name);
		static if (!(isKind!T && ["apiVersion", "kind", "metadata"].canFind(jsonNameOf!member)))
			s ~= deepCopyField!(typeof(member), hasSchemaDefault!(T, property.name)())(goName(jsonNameOf!member));
	}}
	s ~= "}\n\n// DeepCopy returns a deep copy of the receiver.\n";
	s ~= "func (in *" ~ name ~ ") DeepCopy() *" ~ name ~ " {\n\tif in == nil {\n\t\treturn nil\n\t}\n";
	s ~= "\tout := new(" ~ name ~ ")\n\tin.DeepCopyInto(out)\n\treturn out\n}\n";
	static if (isKind!T)
	{
		enum list = name ~ "List";
		s ~= "\n// DeepCopyObject implements runtime.Object.\n";
		s ~= "func (in *" ~ name ~ ") DeepCopyObject() runtime.Object {\n\treturn in.DeepCopy()\n}\n";
		s ~= "\n// DeepCopyInto copies the receiver into out. in must be non-nil.\n";
		s ~= "func (in *" ~ list ~ ") DeepCopyInto(out *" ~ list ~ ") {\n\t*out = *in\n";
		s ~= "\tout.TypeMeta = in.TypeMeta\n\tin.ListMeta.DeepCopyInto(&out.ListMeta)\n";
		s ~= "\tif in.Items != nil {\n\t\tin, out := &in.Items, &out.Items\n\t\t*out = make([]" ~ name
			~ ", len(*in))\n\t\tfor index := range *in {\n\t\t\t(*in)[index].DeepCopyInto(&(*out)[index])\n\t\t}\n\t}\n}\n";
		s ~= "\n// DeepCopy returns a deep copy of the receiver.\n";
		s ~= "func (in *" ~ list ~ ") DeepCopy() *" ~ list ~ " {\n\tif in == nil {\n\t\treturn nil\n\t}\n";
		s ~= "\tout := new(" ~ list ~ ")\n\tin.DeepCopyInto(out)\n\treturn out\n}\n";
		s ~= "\n// DeepCopyObject implements runtime.Object.\n";
		s ~= "func (in *" ~ list ~ ") DeepCopyObject() runtime.Object {\n\treturn in.DeepCopy()\n}\n";
	}
	return s;
}

/// The scheme registration: group/version constants and AddToScheme for every kind.
private string emitGoScheme()
{
	string s = "// Group is the API group of every resource in this package.\n";
	s ~= "const Group = \"" ~ crGroup ~ "\"\n\n";
	s ~= "// Version is the API version this package's types are served and stored at.\n";
	s ~= "const Version = \"" ~ crVersion ~ "\"\n\n";
	s ~= "// SchemeGroupVersion is the group and version the types register under.\n";
	s ~= "var SchemeGroupVersion = schema.GroupVersion{Group: Group, Version: Version}\n\n";
	s ~= "// SchemeBuilder registers the types with a runtime.Scheme.\n";
	s ~= "var SchemeBuilder = runtime.NewSchemeBuilder(addKnownTypes)\n\n";
	s ~= "// AddToScheme adds every resource in this package to a scheme.\n";
	s ~= "var AddToScheme = SchemeBuilder.AddToScheme\n\n";
	s ~= "func addKnownTypes(scheme *runtime.Scheme) error {\n\tscheme.AddKnownTypes(SchemeGroupVersion";
	static foreach (Kind; CrdKinds)
		s ~= ",\n\t\t&" ~ Kind.stringof ~ "{}, &" ~ Kind.stringof ~ "List{}";
	s ~= ",\n\t)\n\tmetav1.AddToGroupVersion(scheme, SchemeGroupVersion)\n\treturn nil\n}\n";
	return s;
}

/// The full generated Go file.
string emitGoTypes()
{
	string s = "// Code generated by ai-agent-tsgen from the agentcore CRD structs. DO NOT EDIT.\n";
	s ~= "// Regenerate: make regen\n\n";
	s ~= "package agentcontracts\n\n";
	s ~= "import (\n\tmetav1 \"k8s.io/apimachinery/pkg/apis/meta/v1\"\n";
	s ~= "\t\"k8s.io/apimachinery/pkg/runtime\"\n\t\"k8s.io/apimachinery/pkg/runtime/schema\"\n)\n\n";
	s ~= emitGoScheme();
	static foreach (E; CrdEnums)
		s ~= "\n" ~ emitGoEnum!E();
	static foreach (T; CrdStructs)
	{
		static if (!is(T == ObjectMeta))
			s ~= "\n" ~ emitGoStruct!T() ~ emitGoDeepCopy!T();
	}
	return s;
}

version (unittest) import fluent.asserts;

unittest // goName turns wire names into exported Go identifiers, with Go's initialisms
{
	[goName("stationRef"), goName("headers_secret"), goName("prUrl"), goName("stream-json"), goName("uid")]
		.should.equal(["StationRef", "HeadersSecret", "PrURL", "StreamJSON", "UID"]);
}

@safe unittest // goType maps each D type kind to its Go expression
{
	import agentcore.crds.enums : SinkType;
	import agentcore.crds.env_var : EnvVar;

	static assert(goType!Json == "runtime.RawExtension");
	static assert(goType!SinkType == "SinkType");
	static assert(goType!int == "int32");
	static assert(goType!long == "int64");
	static assert(goType!(string[string]) == "map[string]string");
	static assert(goType!(EnvVar[]) == "[]EnvVar");
}

unittest // a kind embeds TypeMeta and ObjectMeta, gets a List, and implements runtime.Object
{
	import agentcore.crds.agent : Agent;

	const source = emitGoStruct!Agent() ~ emitGoDeepCopy!Agent();
	[source.canFind("\tmetav1.TypeMeta `json:\",inline\"`"), source.canFind("type AgentList struct"),
		source.canFind("func (in *Agent) DeepCopyObject() runtime.Object"),
		source.canFind("APIVersion"), source.canFind("\tSpec AgentSpec `json:\"spec,omitzero\"`")]
		.should.equal([true, true, true, false, true]);
}

unittest // enum and string fields are copied by the shallow assignment, slices and maps element by element
{
	import agentcore.crds.output_selector : OutputSelector;
	import agentcore.crds.agent_spec : AgentSpec;

	const selector = emitGoDeepCopy!OutputSelector();
	const spec = emitGoDeepCopy!AgentSpec();
	[selector.canFind("in.Event"), spec.canFind("*out = make(map[string]string, len(*in))")]
		.should.equal([false, true]);
}

unittest // a field with a schema default becomes a pointer, so leaving it unset keeps the server's default
{
	import agentcore.crds.station_spec : StationSpec;

	emitGoStruct!StationSpec().canFind("\tDeadlineMinutes *int32 `json:\"deadlineMinutes,omitempty\"`")
		.should.equal(true);
}
