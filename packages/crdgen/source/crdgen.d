/// Generates Kubernetes CustomResourceDefinition YAML from the annotated
/// `agentcore.crds` structs: introspects them with describe-d and emits OpenAPI
/// v3 schemas using open-api's vocabulary. Backs the `write-structures` command.
module crdgen;

import std.conv : to;
import std.file : mkdirRecurse, write;
import std.meta : AliasSeq;
import std.path : buildPath;
import std.stdio : writeln, stderr;
import std.string : indexOf, toLower;
import std.traits : isIntegral, isBoolean, isSomeString, isArray, isAssociativeArray,
	EnumMembers, ForeachType, ValueType, getUDAs, hasUDA;

import std.json : JSONValue;

import described : describe;
import openapi.definitions : SchemaType;

import agentcore.schema;
import agentcore.crds;

/// Renders an open-api `SchemaType` to its wire string (e.g. `object` -> "object").
private enum st(SchemaType t) = cast(string) t;

/// Two-space YAML indentation, `levels` deep.
private string ind(size_t levels)
{
	string s;
	foreach (_; 0 .. levels)
		s ~= "  ";
	return s;
}

/// Renders `value` as a double-quoted YAML scalar, escaping `\` and `"`.
private string yamlStr(string value)
{
	string s = "\"";
	foreach (c; value)
	{
		if (c == '\\' || c == '"')
			s ~= '\\';
		s ~= c;
	}
	return s ~ "\"";
}

/// The per-field schema decorations gathered from a field's UDAs and initializer.
private struct Deco
{
	/// The field's `@Description` text, or "".
	string description;
	/// The rendered default value (a YAML scalar), or "" when the field has no non-zero initializer.
	string defaultLit;
	/// Whether the field carries a `@Minimum` bound.
	bool hasMinimum;
	/// The `@Minimum` bound (valid only when `hasMinimum`).
	long minimum;
	/// The field's `@Format` (e.g. "date-time"), or "".
	string format;
}

/// Builds the `Deco` for field `name` of struct `T` from its UDAs and default
/// initializer (the initializer becomes `default` when it differs from the type's `.init`).
private Deco decoOf(T, string name)()
{
	alias member = __traits(getMember, T, name);
	alias FT = typeof(member);
	Deco d;
	d.description = descriptionOf!member;
	d.format = formatOf!member;
	static if (hasUDA!(member, Minimum))
	{
		d.hasMinimum = true;
		d.minimum = getUDAs!(member, Minimum)[0].value;
	}
	enum initial = __traits(getMember, T.init, name);
	static if (is(FT == enum))
	{
		if (initial != FT.init)
			d.defaultLit = cast(string) initial;
	}
	else static if (isIntegral!FT)
	{
		if (initial != FT.init)
			d.defaultLit = initial.to!string;
	}
	else static if (isBoolean!FT)
	{
		if (initial != FT.init)
			d.defaultLit = initial ? "true" : "false";
	}
	return d;
}

/// Emits the OpenAPI v3 schema body for type `FT` at `indent`, decorated by `d`.
/// Recurses into arrays (`items`), associative arrays (`additionalProperties`),
/// and nested structs (`properties`); `JSONValue` becomes a preserve-unknown object.
private string emitType(FT)(size_t indent, Deco d)
{
	const pad = ind(indent);
	string s;

	/// Emits the optional `description:` line for this node, or "".
	string describe_()
	{
		return d.description.length ? pad ~ "description: " ~ yamlStr(d.description) ~ "\n" : "";
	}

	static if (is(FT == JSONValue))
	{
		s ~= pad ~ "type: " ~ st!(SchemaType.object) ~ "\n";
		s ~= describe_();
		s ~= pad ~ "x-kubernetes-preserve-unknown-fields: true\n";
	}
	else static if (is(FT == enum))
	{
		s ~= pad ~ "type: " ~ st!(SchemaType.string) ~ "\n";
		if (d.defaultLit.length)
			s ~= pad ~ "default: " ~ d.defaultLit ~ "\n";
		s ~= describe_();
		s ~= pad ~ "enum:\n";
		static foreach (member; EnumMembers!FT)
			s ~= pad ~ "  - " ~ cast(string) member ~ "\n";
	}
	else static if (isIntegral!FT)
	{
		s ~= pad ~ "type: " ~ st!(SchemaType.integer) ~ "\n";
		if (d.defaultLit.length)
			s ~= pad ~ "default: " ~ d.defaultLit ~ "\n";
		if (d.hasMinimum)
			s ~= pad ~ "minimum: " ~ d.minimum.to!string ~ "\n";
		s ~= describe_();
	}
	else static if (isBoolean!FT)
	{
		s ~= pad ~ "type: " ~ st!(SchemaType.boolean) ~ "\n";
		s ~= describe_();
	}
	else static if (isSomeString!FT)
	{
		s ~= pad ~ "type: " ~ st!(SchemaType.string) ~ "\n";
		if (d.format.length)
			s ~= pad ~ "format: " ~ d.format ~ "\n";
		s ~= describe_();
	}
	else static if (isAssociativeArray!FT)
	{
		s ~= pad ~ "type: " ~ st!(SchemaType.object) ~ "\n";
		s ~= describe_();
		s ~= pad ~ "additionalProperties:\n";
		s ~= emitType!(ValueType!FT)(indent + 1, Deco.init);
	}
	else static if (isArray!FT)
	{
		s ~= pad ~ "type: " ~ st!(SchemaType.array) ~ "\n";
		s ~= describe_();
		s ~= pad ~ "items:\n";
		s ~= emitType!(ForeachType!FT)(indent + 1, Deco.init);
	}
	else static if (is(FT == struct))
	{
		s ~= pad ~ "type: " ~ st!(SchemaType.object) ~ "\n";
		s ~= describe_();
		enum required = requiredNames!FT;
		static if (required.length > 0)
		{
			s ~= pad ~ "required:\n";
			static foreach (name; required)
				s ~= pad ~ "  - " ~ name ~ "\n";
		}
		s ~= pad ~ "properties:\n";
		// describe-d gives the fields in declaration order.
		enum aggregate = describe!FT;
		static foreach (property; aggregate.properties)
		{
			s ~= ind(indent + 1) ~ jsonNameOf!(__traits(getMember, FT, property.name)) ~ ":\n";
			s ~= emitType!(typeof(__traits(getMember, FT, property.name)))(
				indent + 2, decoOf!(FT, property.name));
		}
	}
	else
		static assert(false, "crdgen: unsupported field type " ~ FT.stringof);

	return s;
}

/// The wire names of the `@Required` fields of struct `T`, in declaration order.
private string[] requiredNames(T)()
{
	string[] names;
	static foreach (member; T.tupleof)
		static if (isRequired!member)
			names ~= jsonNameOf!member;
	return names;
}

/// The full CustomResourceDefinition YAML for resource type `T`, derived from
/// the annotated struct via introspection (names/printer columns from UDAs;
/// group/version/kind from the struct's defaults; status subresource when present).
string crdYaml(T)()
{
	enum apiVersion = T.init.apiVersion;
	enum slash = indexOf(apiVersion, '/');
	enum group = apiVersion[0 .. slash];
	enum version_ = apiVersion[slash + 1 .. $];
	enum kind = T.init.kind;
	enum plural = pluralOf!T;
	enum shortNames = shortNamesOf!T;
	enum columns = printerColumnsOf!T;
	enum hasStatus = __traits(hasMember, T, "status");
	alias SpecT = typeof(T.init.spec);
	enum specDescription = descriptionOf!SpecT;

	string s;
	s ~= "apiVersion: apiextensions.k8s.io/v1\n";
	s ~= "kind: CustomResourceDefinition\n";
	s ~= "metadata:\n";
	s ~= "  name: " ~ plural ~ "." ~ group ~ "\n";
	s ~= "spec:\n";
	s ~= "  group: " ~ group ~ "\n";
	s ~= "  scope: Namespaced\n";
	s ~= "  names:\n";
	s ~= "    plural: " ~ plural ~ "\n";
	s ~= "    singular: " ~ toLower(kind) ~ "\n";
	s ~= "    kind: " ~ kind ~ "\n";
	s ~= "    shortNames:\n";
	static foreach (name; shortNames)
		s ~= "      - " ~ name ~ "\n";
	s ~= "  versions:\n";
	s ~= "    - name: " ~ version_ ~ "\n";
	s ~= "      served: true\n";
	s ~= "      storage: true\n";
	static if (hasStatus)
	{
		s ~= "      subresources:\n";
		s ~= "        status: {}\n";
	}
	s ~= "      additionalPrinterColumns:\n";
	static foreach (column; columns)
	{
		s ~= "        - name: " ~ column.name ~ "\n";
		s ~= "          type: " ~ column.type ~ "\n";
		s ~= "          jsonPath: " ~ column.jsonPath ~ "\n";
	}
	s ~= "      schema:\n";
	s ~= "        openAPIV3Schema:\n";
	s ~= "          type: object\n";
	static if (specDescription.length > 0)
		s ~= "          description: " ~ yamlStr(specDescription) ~ "\n";
	s ~= "          required:\n";
	s ~= "            - spec\n";
	s ~= "          properties:\n";
	s ~= "            spec:\n";
	s ~= emitType!SpecT(7, Deco.init);
	static if (hasStatus)
	{
		alias StatusT = typeof(T.init.status);
		s ~= "            status:\n";
		s ~= emitType!StatusT(7, Deco.init);
	}
	return s;
}

/// Handle the `write-structures <dir>` sub-command: generate the three CRD
/// YAMLs into `dir`. `args` is the sub-command argv (args[0] is the verb).
/// Returns the process exit code.
int writeStructures(string[] args)
{
	if (args.length < 2)
	{
		stderr.writeln("usage: ai-agent-crdgen write-structures <dir>");
		return 2;
	}

	const dir = args[1];
	mkdirRecurse(dir);
	static foreach (T; AliasSeq!(AgentDefinition, Station, Agent))
	{{
		enum yaml = crdYaml!T();
		write(buildPath(dir, toLower(T.init.kind) ~ ".yaml"), yaml);
	}}

	writeln("wrote agentdefinition.yaml, station.yaml, agent.yaml to ", dir);
	return 0;
}
