/// Generates the C# contract types (`packages/agent-contracts-dotnet/src/ReCinq.AgentContracts/Types.g.cs`)
/// from the same annotated `agentcore.crds` structs the other emitters read: System.Text.Json classes
/// whose property names are the wire names, and for each kind an `IKubernetesObject<V1ObjectMeta>`
/// with a `List` type, so the official `KubernetesClient` package reads and writes them directly.
module csgen;

import std.algorithm : map;
import std.array : join, replace, split;
import std.traits : isIntegral, isBoolean, isSomeString, isArray, isAssociativeArray,
	EnumMembers, ForeachType, ValueType;

import vibe.data.json : Json;

import described : describe;

import agentcore.crds.api_group : crGroup, crVersion, crApiVersion;
import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.registry : CrdEnums, CrdStructs, isKind;
import agentcore.crds.schema : descriptionOf, jsonNameOf, isRequired, pluralOf, shortNamesOf;

import wirenames : pascal, pascalKeepCase;

/// The C# namespace of the generated types.
enum csNamespace = "ReCinq.AgentContracts";

private enum indent = "    ";

/// A C# property name from a wire name: `headers_secret` -> `HeadersSecret`.
string csProperty(string wire)
{
	return pascalKeepCase(wire);
}

/// The C# type for D type `FT`, without the nullable marker.
template csType(FT)
{
	static if (is(FT == Json))
		enum csType = "JsonNode";
	else static if (is(FT == enum))
		enum csType = FT.stringof;
	else static if (isIntegral!FT)
		enum csType = FT.sizeof == 8 ? "long" : "int";
	else static if (isBoolean!FT)
		enum csType = "bool";
	else static if (isSomeString!FT)
		enum csType = "string";
	else static if (isAssociativeArray!FT)
		enum csType = "Dictionary<string, " ~ csType!(ValueType!FT) ~ ">";
	else static if (isArray!FT)
		enum csType = "List<" ~ csType!(ForeachType!FT) ~ ">";
	else static if (is(FT == ObjectMeta))
		enum csType = "V1ObjectMeta";
	else static if (is(FT == struct))
		enum csType = FT.stringof;
	else
		static assert(false, "csgen: unsupported field type " ~ FT.stringof);
}

/// An XML doc `<summary>` for `text`, or "" when there is none.
private string summary(string text, string prefix)
{
	if (!text.length)
		return "";
	const escaped = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
	return prefix ~ "/// <summary>\n" ~ escaped.split("\n").map!(line => prefix ~ "/// " ~ line ~ "\n").join
		~ prefix ~ "/// </summary>\n";
}

/// An enum, its wire mapping and its JSON converter. An unknown value becomes the first member,
/// like `CrdPolicy` does in D. The converter goes on each property rather than on the enum, because
/// `KubernetesJson`'s own string-enum converter would otherwise take precedence and write the C#
/// member name.
string emitCsEnum(E)()
{
	enum name = E.stringof;
	string members, toWire, fromWire;
	static foreach (member; EnumMembers!E)
	{{
		enum constant = pascal(cast(string) member);
		members ~= indent ~ constant ~ ",\n";
		toWire ~= indent ~ indent ~ indent ~ name ~ "." ~ constant ~ " => \"" ~ cast(string) member ~ "\",\n";
		fromWire ~= indent ~ indent ~ indent ~ "\"" ~ cast(string) member ~ "\" => " ~ name ~ "." ~ constant ~ ",\n";
	}}
	string s = "public enum " ~ name ~ "\n{\n" ~ members ~ "}\n\n";
	s ~= "/// <summary>Maps <see cref=\"" ~ name ~ "\"/> to and from its wire value.</summary>\n";
	s ~= "public static class " ~ name ~ "Wire\n{\n";
	s ~= indent ~ "/// <summary>The value as it appears on the wire.</summary>\n";
	s ~= indent ~ "public static string ToWire(this " ~ name ~ " value) =>\n" ~ indent ~ indent ~ "value switch\n"
		~ indent ~ indent ~ "{\n" ~ toWire ~ indent ~ indent ~ indent
		~ "_ => throw new ArgumentOutOfRangeException(nameof(value), value, null),\n" ~ indent ~ indent ~ "};\n\n";
	s ~= indent ~ "/// <summary>The member for a wire value; an unknown value answers the first member, the server's default.</summary>\n";
	s ~= indent ~ "public static " ~ name ~ " FromWire(string? wire) =>\n" ~ indent ~ indent ~ "wire switch\n" ~ indent
		~ indent ~ "{\n" ~ fromWire ~ indent ~ indent ~ indent ~ "_ => default,\n" ~ indent ~ indent ~ "};\n}\n\n";
	s ~= "/// <summary>Reads and writes <see cref=\"" ~ name ~ "\"/> as its wire value.</summary>\n";
	s ~= "public sealed class " ~ name ~ "JsonConverter : JsonConverter<" ~ name ~ ">\n{\n";
	s ~= indent ~ "public override " ~ name
		~ " Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>\n" ~ indent ~ indent
		~ name ~ "Wire.FromWire(reader.GetString());\n\n";
	s ~= indent ~ "public override void Write(Utf8JsonWriter writer, " ~ name
		~ " value, JsonSerializerOptions options) =>\n" ~ indent ~ indent ~ "writer.WriteStringValue(value.ToWire());\n}\n";
	return s;
}

/// The properties of `T`, minus a kind's apiVersion/kind/metadata, which `emitCsKind` writes.
private string csProperties(T)()
{
	string s;
	string separator;
	static foreach (property; describe!T.properties)
	{{
		alias member = __traits(getMember, T, property.name);
		alias FT = typeof(member);
		enum wire = jsonNameOf!member;
		static if (!(isKind!T && (wire == "apiVersion" || wire == "kind" || wire == "metadata")))
		{
			s ~= separator ~ summary(descriptionOf!member, indent);
			separator = "\n";
			s ~= indent ~ "[JsonPropertyName(\"" ~ wire ~ "\")]\n";
			static if (is(FT == enum))
				s ~= indent ~ "[JsonConverter(typeof(" ~ FT.stringof ~ "JsonConverter))]\n";
			static if (isRequired!member)
				s ~= indent ~ "public required " ~ csType!FT ~ " " ~ csProperty(wire) ~ " { get; set; }\n";
			else
				s ~= indent ~ "[JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]\n" ~ indent ~ "public "
					~ csType!FT ~ "? " ~ csProperty(wire) ~ " { get; set; }\n";
		}
	}}
	return s;
}

/// A plain class.
string emitCsClass(T)()
{
	return summary(descriptionOf!T, "") ~ "public sealed class " ~ T.stringof ~ "\n{\n" ~ csProperties!T() ~ "}\n";
}

/// A kind: `IKubernetesObject<V1ObjectMeta>` with its group, version, plural and short names, plus
/// the `List` type the API returns for it.
string emitCsKind(T)()
{
	enum name = T.stringof;
	string s = summary(descriptionOf!T, "");
	s ~= "[KubernetesEntity(Group = ApiGroup.Group, ApiVersion = ApiGroup.Version, Kind = KubeKind, PluralName = Plural)]\n";
	s ~= "public sealed class " ~ name ~ " : IKubernetesObject<V1ObjectMeta>\n{\n";
	s ~= indent ~ "/// <summary>The resource's kind.</summary>\n" ~ indent ~ "public const string KubeKind = \"" ~ name
		~ "\";\n\n";
	s ~= indent ~ "/// <summary>The resource's plural, as it appears in API paths.</summary>\n" ~ indent
		~ "public const string Plural = \"" ~ pluralOf!T ~ "\";\n\n";
	s ~= indent ~ "/// <summary>The CRD's short names, as <c>kubectl get</c> accepts them.</summary>\n" ~ indent
		~ "public static readonly IReadOnlyList<string> ShortNames = ["
		~ shortNamesOf!T.map!(short_ => "\"" ~ short_ ~ "\"").join(", ") ~ "];\n\n";
	s ~= indent ~ "[JsonPropertyName(\"apiVersion\")]\n" ~ indent ~ "public string ApiVersion { get; set; } = ApiGroup.ApiVersion;\n\n";
	s ~= indent ~ "[JsonPropertyName(\"kind\")]\n" ~ indent ~ "public string Kind { get; set; } = KubeKind;\n\n";
	s ~= indent ~ "[JsonPropertyName(\"metadata\")]\n" ~ indent ~ "public V1ObjectMeta Metadata { get; set; } = new();\n\n";
	s ~= csProperties!T() ~ "}\n\n";
	s ~= "/// <summary>A list of " ~ name ~ " resources.</summary>\n";
	s ~= "public sealed class " ~ name ~ "List : IKubernetesObject<V1ListMeta>, IItems<" ~ name ~ ">\n{\n";
	s ~= indent ~ "[JsonPropertyName(\"apiVersion\")]\n" ~ indent ~ "public string ApiVersion { get; set; } = ApiGroup.ApiVersion;\n\n";
	s ~= indent ~ "[JsonPropertyName(\"kind\")]\n" ~ indent ~ "public string Kind { get; set; } = \"" ~ name ~ "List\";\n\n";
	s ~= indent ~ "[JsonPropertyName(\"metadata\")]\n" ~ indent ~ "public V1ListMeta Metadata { get; set; } = new();\n\n";
	s ~= indent ~ "[JsonPropertyName(\"items\")]\n" ~ indent ~ "public IList<" ~ name ~ "> Items { get; set; } = [];\n}\n";
	return s;
}

/// The full generated C# file.
string emitCsTypes()
{
	string s = "// <auto-generated>\n// Code generated by ai-agent-tsgen from the agentcore CRD structs. DO NOT EDIT.\n";
	s ~= "// Regenerate: make regen\n// </auto-generated>\n\n#nullable enable\n\n";
	s ~= "using System.Text.Json;\nusing System.Text.Json.Nodes;\nusing System.Text.Json.Serialization;\n";
	s ~= "using k8s;\nusing k8s.Models;\n\nnamespace " ~ csNamespace ~ ";\n\n";
	s ~= "/// <summary>The API group and version every resource in this namespace is served at.</summary>\n";
	s ~= "public static class ApiGroup\n{\n";
	s ~= indent ~ "public const string Group = \"" ~ crGroup ~ "\";\n\n";
	s ~= indent ~ "public const string Version = \"" ~ crVersion ~ "\";\n\n";
	s ~= indent ~ "public const string ApiVersion = \"" ~ crApiVersion ~ "\";\n}\n";
	static foreach (E; CrdEnums)
		s ~= "\n" ~ emitCsEnum!E();
	static foreach (T; CrdStructs)
	{
		static if (isKind!T)
			s ~= "\n" ~ emitCsKind!T();
		else static if (!is(T == ObjectMeta))
			s ~= "\n" ~ emitCsClass!T();
	}
	return s;
}

version (unittest) import fluent.asserts;

@safe unittest // csType maps each D type kind to its C# type
{
	import agentcore.crds.env_var : EnvVar;

	static assert(csType!Json == "JsonNode");
	static assert(csType!int == "int");
	static assert(csType!long == "long");
	static assert(csType!(string[string]) == "Dictionary<string, string>");
	static assert(csType!(EnvVar[]) == "List<EnvVar>");
}

unittest // an enum maps to and from its wire value and falls back to its first member
{
	import agentcore.crds.enums : OutputFormat;

	const source = emitCsEnum!OutputFormat();
	source.should.contain("public enum OutputFormat\n{\n    Text,\n    Json,\n    StreamJson,\n}\n");
	source.should.contain("            \"stream-json\" => OutputFormat.StreamJson,\n            _ => default,\n");
}

unittest // a required property is `required`; an optional one is nullable and left out when null
{
	import agentcore.crds.secret_ref : SecretRef;
	import agentcore.crds.output_selector : OutputSelector;

	emitCsClass!SecretRef().should.contain("    [JsonPropertyName(\"ref\")]\n    public required string Ref { get; set; }\n");
	emitCsClass!OutputSelector().should.contain("    [JsonConverter(typeof(SelectRoleJsonConverter))]\n"
		~ "    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]\n    public SelectRole? Role { get; set; }\n");
}

unittest // a kind is an IKubernetesObject with its entity attributes and a List type
{
	import agentcore.crds.agent : Agent;

	const source = emitCsKind!Agent();
	source.should.contain("public sealed class Agent : IKubernetesObject<V1ObjectMeta>\n");
	source.should.contain("    public const string Plural = \"agents\";\n");
	source.should.contain("public sealed class AgentList : IKubernetesObject<V1ListMeta>, IItems<Agent>\n");
}
