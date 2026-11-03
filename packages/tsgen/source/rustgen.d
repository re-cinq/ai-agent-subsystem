/// Generates the Rust contract types (`packages/agent-contracts-rust/src/types.rs`) from the same
/// annotated `agentcore.crds` structs the other emitters read: serde structs whose renames are the
/// wire names, and for each kind a `kube::Resource` impl so `kube::Api<Agent>` works directly.
module rustgen;

import std.algorithm : canFind, map;
import std.array : join, split;
import std.traits : isIntegral, isBoolean, isSomeString, isArray, isAssociativeArray,
	EnumMembers, ForeachType, ValueType;

import vibe.data.json : Json;

import described : describe;

import agentcore.crds.api_group : crGroup, crVersion, crApiVersion;
import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.registry : CrdEnums, CrdStructs, isKind;
import agentcore.crds.schema : descriptionOf, jsonNameOf, isRequired, pluralOf, shortNamesOf;

import wirenames : lowerSnake, pascal;

private enum indent = "    ";

/// Rust keywords a field name must be written as a raw identifier for.
private immutable string[] rustKeywords = ["as", "async", "await", "break", "const", "continue", "dyn",
	"else", "enum", "extern", "false", "fn", "for", "gen", "if", "impl", "in", "let", "loop", "match", "mod",
	"move", "mut", "pub", "ref", "return", "static", "struct", "trait", "true", "type", "unsafe", "use",
	"where", "while", "abstract", "become", "box", "do", "final", "macro", "override", "priv", "try",
	"typeof", "unsized", "virtual", "yield"];

/// A Rust field from a wire name: `stationRef` -> `station_ref`, `ref` -> `r#ref`.
string rustField(string wire)
{
	const name = lowerSnake(wire);
	return rustKeywords.canFind(name) ? "r#" ~ name : name;
}

/// The Rust type for D type `FT`.
template rustType(FT)
{
	static if (is(FT == Json))
		enum rustType = "serde_json::Value";
	else static if (is(FT == enum))
		enum rustType = FT.stringof;
	else static if (isIntegral!FT)
		enum rustType = FT.sizeof == 8 ? "i64" : "i32";
	else static if (isBoolean!FT)
		enum rustType = "bool";
	else static if (isSomeString!FT)
		enum rustType = "String";
	else static if (isAssociativeArray!FT)
		enum rustType = "BTreeMap<String, " ~ rustType!(ValueType!FT) ~ ">";
	else static if (isArray!FT)
		enum rustType = "Vec<" ~ rustType!(ForeachType!FT) ~ ">";
	else static if (is(FT == ObjectMeta))
		enum rustType = "ObjectMeta";
	else static if (is(FT == struct))
		enum rustType = FT.stringof;
	else
		static assert(false, "rustgen: unsupported field type " ~ FT.stringof);
}

/// `///` doc lines for `text`, or "" when there is none.
private string docLines(string text, string prefix)
{
	return text.length ? text.split("\n").map!(line => prefix ~ "/// " ~ line ~ "\n").join : "";
}

/// An enum serialized as its wire string; an unknown value becomes the first variant, like
/// `CrdPolicy` does in D.
string emitRustEnum(E)()
{
	enum name = E.stringof;
	string variants, toWire, fromWire;
	bool first = true;
	static foreach (member; EnumMembers!E)
	{{
		enum variant = pascal(cast(string) member);
		variants ~= (first ? indent ~ "#[default]\n" : "") ~ indent ~ variant ~ ",\n";
		toWire ~= indent ~ indent ~ indent ~ "Self::" ~ variant ~ " => \"" ~ cast(string) member ~ "\",\n";
		fromWire ~= indent ~ indent ~ indent ~ "\"" ~ cast(string) member ~ "\" => Self::" ~ variant ~ ",\n";
		first = false;
	}}
	string s = "#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]\n";
	s ~= "#[serde(from = \"String\", into = \"String\")]\npub enum " ~ name ~ " {\n" ~ variants ~ "}\n\n";
	s ~= "impl " ~ name ~ " {\n" ~ indent ~ "/// The value as it appears on the wire.\n";
	s ~= indent ~ "pub fn as_str(&self) -> &'static str {\n" ~ indent ~ indent ~ "match self {\n" ~ toWire
		~ indent ~ indent ~ "}\n" ~ indent ~ "}\n}\n\n";
	s ~= "impl From<String> for " ~ name ~ " {\n" ~ indent ~ "fn from(wire: String) -> Self {\n";
	s ~= indent ~ indent ~ "match wire.as_str() {\n" ~ fromWire;
	s ~= indent ~ indent ~ indent ~ "_ => Self::default(),\n" ~ indent ~ indent ~ "}\n" ~ indent ~ "}\n}\n\n";
	s ~= "impl From<" ~ name ~ "> for String {\n" ~ indent ~ "fn from(value: " ~ name ~ ") -> Self {\n";
	s ~= indent ~ indent ~ "value.as_str().to_string()\n" ~ indent ~ "}\n}\n";
	return s;
}

/// The serde fields of `T`. A kind's `apiVersion` and `kind` default to its own values.
private string rustFields(T)()
{
	string s;
	static foreach (property; describe!T.properties)
	{{
		alias member = __traits(getMember, T, property.name);
		alias FT = typeof(member);
		enum wire = jsonNameOf!member;
		s ~= docLines(descriptionOf!member, indent);
		static if (isKind!T && wire == "apiVersion")
			s ~= indent ~ "#[serde(rename = \"apiVersion\", default = \"api_version\")]\n" ~ indent
				~ "pub api_version: String,\n";
		else static if (isKind!T && wire == "kind")
			s ~= indent ~ "#[serde(default = \"" ~ T.stringof ~ "::kind_name\")]\n" ~ indent ~ "pub kind: String,\n";
		else static if (is(FT == ObjectMeta))
			s ~= indent ~ "#[serde(default)]\n" ~ indent ~ "pub metadata: ObjectMeta,\n";
		else static if (isRequired!member)
			s ~= indent ~ "#[serde(rename = \"" ~ wire ~ "\")]\n" ~ indent ~ "pub " ~ rustField(wire) ~ ": "
				~ rustType!FT ~ ",\n";
		else
			s ~= indent ~ "#[serde(rename = \"" ~ wire ~ "\", default, skip_serializing_if = \"Option::is_none\")]\n"
				~ indent ~ "pub " ~ rustField(wire) ~ ": Option<" ~ rustType!FT ~ ">,\n";
	}}
	return s;
}

/// A plain struct.
string emitRustStruct(T)()
{
	return docLines(descriptionOf!T, "") ~ "#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]\n"
		~ "pub struct " ~ T.stringof ~ " {\n" ~ rustFields!T() ~ "}\n";
}

/// A kind: the struct, its constructor and short names, `Default` with its own apiVersion and kind,
/// and the `kube::Resource` impl that names its group, version and plural.
string emitRustKind(T)()
{
	enum name = T.stringof;
	string defaults;
	static foreach (property; describe!T.properties)
	{{
		enum wire = jsonNameOf!(__traits(getMember, T, property.name));
		static if (wire == "apiVersion")
			defaults ~= indent ~ indent ~ indent ~ "api_version: api_version(),\n";
		else static if (wire == "kind")
			defaults ~= indent ~ indent ~ indent ~ "kind: Self::kind_name(),\n";
		else
			defaults ~= indent ~ indent ~ indent ~ rustField(wire) ~ ": Default::default(),\n";
	}}
	string s = docLines(descriptionOf!T, "") ~ "#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]\n";
	s ~= "pub struct " ~ name ~ " {\n" ~ rustFields!T() ~ "}\n\n";
	s ~= "impl " ~ name ~ " {\n";
	s ~= indent ~ "/// The CRD's short names, as `kubectl get` accepts them.\n";
	s ~= indent ~ "pub const SHORT_NAMES: &'static [&'static str] = &["
		~ shortNamesOf!T.map!(short_ => "\"" ~ short_ ~ "\"").join(", ") ~ "];\n\n";
	s ~= indent ~ "/// A " ~ name ~ " with `metadata.name` set and everything else empty.\n";
	s ~= indent ~ "pub fn new(name: &str) -> Self {\n" ~ indent ~ indent ~ "let mut resource = Self::default();\n";
	s ~= indent ~ indent ~ "resource.metadata.name = Some(name.to_string());\n" ~ indent ~ indent ~ "resource\n"
		~ indent ~ "}\n\n";
	s ~= indent ~ "fn kind_name() -> String {\n" ~ indent ~ indent ~ "\"" ~ name ~ "\".to_string()\n" ~ indent
		~ "}\n}\n\n";
	s ~= "impl Default for " ~ name ~ " {\n" ~ indent ~ "fn default() -> Self {\n" ~ indent ~ indent ~ "Self {\n"
		~ defaults ~ indent ~ indent ~ "}\n" ~ indent ~ "}\n}\n\n";
	s ~= "impl Resource for " ~ name ~ " {\n";
	s ~= indent ~ "type DynamicType = ();\n" ~ indent ~ "type Scope = NamespaceResourceScope;\n\n";
	foreach (pair; [["kind", "\"" ~ name ~ "\""], ["group", "GROUP"], ["version", "VERSION"],
			["plural", "\"" ~ pluralOf!T ~ "\""]])
		s ~= indent ~ "fn " ~ pair[0] ~ "(_: &()) -> Cow<'_, str> {\n" ~ indent ~ indent ~ "Cow::Borrowed("
			~ pair[1] ~ ")\n" ~ indent ~ "}\n\n";
	s ~= indent ~ "fn meta(&self) -> &ObjectMeta {\n" ~ indent ~ indent ~ "&self.metadata\n" ~ indent ~ "}\n\n";
	s ~= indent ~ "fn meta_mut(&mut self) -> &mut ObjectMeta {\n" ~ indent ~ indent ~ "&mut self.metadata\n"
		~ indent ~ "}\n}\n";
	return s;
}

/// The full generated Rust module.
string emitRustTypes()
{
	string s = "// Code generated by ai-agent-tsgen from the agentcore CRD structs. DO NOT EDIT.\n";
	s ~= "// Regenerate: make regen\n\n";
	s ~= "use std::borrow::Cow;\nuse std::collections::BTreeMap;\n\n";
	s ~= "use k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta;\n";
	s ~= "use kube::core::{NamespaceResourceScope, Resource};\nuse serde::{Deserialize, Serialize};\n\n";
	s ~= "/// The API group of every resource in this module.\npub const GROUP: &str = \"" ~ crGroup ~ "\";\n\n";
	s ~= "/// The API version the resources are served and stored at.\npub const VERSION: &str = \"" ~ crVersion
		~ "\";\n\n";
	s ~= "/// `GROUP/VERSION`, the `apiVersion` of every resource.\npub const API_VERSION: &str = \""
		~ crApiVersion ~ "\";\n\n";
	s ~= "fn api_version() -> String {\n" ~ indent ~ "API_VERSION.to_string()\n}\n";
	static foreach (E; CrdEnums)
		s ~= "\n" ~ emitRustEnum!E();
	static foreach (T; CrdStructs)
	{
		static if (isKind!T)
			s ~= "\n" ~ emitRustKind!T();
		else static if (!is(T == ObjectMeta))
			s ~= "\n" ~ emitRustStruct!T();
	}
	return s;
}

version (unittest) import fluent.asserts;

unittest // wire names become snake_case fields, keywords raw identifiers
{
	[rustField("stationRef"), rustField("ref"), rustField("type"), rustField("headers_secret")]
		.should.equal(["station_ref", "r#ref", "r#type", "headers_secret"]);
}

@safe unittest // rustType maps each D type kind to its Rust type
{
	import agentcore.crds.env_var : EnvVar;

	static assert(rustType!Json == "serde_json::Value");
	static assert(rustType!int == "i32");
	static assert(rustType!long == "i64");
	static assert(rustType!(string[string]) == "BTreeMap<String, String>");
	static assert(rustType!(EnvVar[]) == "Vec<EnvVar>");
}

unittest // an enum serializes as its wire string and falls back to its first variant
{
	import agentcore.crds.enums : OutputFormat;

	const source = emitRustEnum!OutputFormat();
	[source.canFind("    #[default]\n    Text,\n"), source.canFind("            \"stream-json\" => Self::StreamJson,\n"),
		source.canFind("            _ => Self::default(),\n")].should.equal([true, true, true]);
}

unittest // a required field is plain; an optional one is an Option left out when None
{
	import agentcore.crds.secret_ref : SecretRef;
	import agentcore.crds.station_spec : StationSpec;

	emitRustStruct!SecretRef().should.contain("    #[serde(rename = \"ref\")]\n    pub r#ref: String,\n");
	emitRustStruct!StationSpec().should.contain("    #[serde(rename = \"deadlineMinutes\", default, "
		~ "skip_serializing_if = \"Option::is_none\")]\n    pub deadline_minutes: Option<i32>,\n");
}

unittest // a kind implements kube::Resource with its group, version and plural
{
	import agentcore.crds.agent : Agent;

	const source = emitRustKind!Agent();
	[source.canFind("impl Resource for Agent {"), source.canFind("        Cow::Borrowed(\"agents\")\n"),
		source.canFind("    pub const SHORT_NAMES: &'static [&'static str] = &[\"agt\"];\n"),
		source.canFind("    pub metadata: ObjectMeta,\n")].should.equal([true, true, true, true]);
}
