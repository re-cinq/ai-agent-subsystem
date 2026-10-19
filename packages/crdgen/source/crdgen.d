/// Generates Kubernetes CustomResourceDefinition YAML from the annotated
/// `agentcore.crds` structs: introspects them with describe-d and emits OpenAPI
/// v3 schemas using open-api's vocabulary. Backs the `write-structures` command.
module crdgen;

import std.array : join;
import std.conv : to;
import std.format : format;
import std.file : mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : writeln, stderr;
import std.string : indexOf, toLower;
import std.traits : isIntegral, isBoolean, isSomeString, isArray, isAssociativeArray,
	EnumMembers, ForeachType, ValueType, getUDAs, hasUDA;

import vibe.data.json : Json;

import described : describe;
import openapi.definitions : SchemaType;

import agentcore.crds.api_group : crDeprecatedVersion;
import agentcore.crds.schema;
import agentcore.crds.agent : Agent;
import agentcore.crds.model_catalog : ModelCatalog;
import agentcore.crds.registry : CrdKinds;

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

/// Renders `value` as a double-quoted YAML scalar, escaping `\`, `"`, and the control
/// characters that would otherwise break the line (newline, tab, carriage return) — so a
/// multi-line `@Description` can never emit invalid YAML.
private string yamlStr(string value)
{
	string s = "\"";
	foreach (char c; value)
	{
		switch (c)
		{
		case '\\':
			s ~= "\\\\";
			break;
		case '"':
			s ~= "\\\"";
			break;
		case '\n':
			s ~= "\\n";
			break;
		case '\t':
			s ~= "\\t";
			break;
		case '\r':
			s ~= "\\r";
			break;
		default:
			// Any remaining C0 control char is invalid raw inside a double-quoted YAML
			// scalar, so escape it as \xXX rather than emitting it verbatim.
			if (c < 0x20)
				s ~= format("\\x%02x", c);
			else
				s ~= c;
			break;
		}
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
	/// The field's `@Pattern` regex (`pattern` in the schema), or "".
	string pattern;
	/// Whether the field carries a `@MaxLength` bound.
	bool hasMaxLength;
	/// The `@MaxLength` bound (valid only when `hasMaxLength`).
	long maxLength;
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
	static if (hasUDA!(member, Pattern))
		d.pattern = getUDAs!(member, Pattern)[0].regex;
	static if (hasUDA!(member, MaxLength))
	{
		d.hasMaxLength = true;
		d.maxLength = getUDAs!(member, MaxLength)[0].value;
	}
	enum initial = __traits(getMember, T.init, name);
	static if (is(FT == enum))
	{
		if (initial != FT.init)
			d.defaultLit = yamlStr(cast(string) initial);
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
	else static if (isSomeString!FT)
	{
		if (initial != FT.init)
			d.defaultLit = yamlStr(initial);
	}
	return d;
}

/// Emits the OpenAPI v3 schema body for type `FT` at `indent`, decorated by `d`.
/// Recurses into arrays (`items`), associative arrays (`additionalProperties`),
/// and nested structs (`properties`); `Json` becomes a preserve-unknown object.
private string emitType(FT)(size_t indent, Deco d)
{
	const pad = ind(indent);
	string s;

	/// Emits the optional `description:` line for this node, or "".
	string describe_()
	{
		return d.description.length ? pad ~ "description: " ~ yamlStr(d.description) ~ "\n" : "";
	}

	static if (is(FT == Json))
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
			s ~= pad ~ "  - " ~ yamlStr(cast(string) member) ~ "\n";
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
		if (d.defaultLit.length)
			s ~= pad ~ "default: " ~ d.defaultLit ~ "\n";
		s ~= describe_();
	}
	else static if (isSomeString!FT)
	{
		s ~= pad ~ "type: " ~ st!(SchemaType.string) ~ "\n";
		if (d.defaultLit.length)
			s ~= pad ~ "default: " ~ d.defaultLit ~ "\n";
		if (d.format.length)
			s ~= pad ~ "format: " ~ d.format ~ "\n";
		if (d.pattern.length)
			s ~= pad ~ "pattern: " ~ yamlStr(d.pattern) ~ "\n";
		if (d.hasMaxLength)
			s ~= pad ~ "maxLength: " ~ d.maxLength.to!string ~ "\n";
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
	enum hasSpec = __traits(hasMember, T, "spec");
	enum hasStatus = __traits(hasMember, T, "status");
	static if (hasSpec)
		enum crdDescription = descriptionOf!(typeof(T.init.spec));
	else
		enum crdDescription = descriptionOf!T;

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
	string body;
	static if (hasStatus)
	{
		body ~= "      subresources:\n";
		body ~= "        status: {}\n";
	}
	body ~= "      additionalPrinterColumns:\n";
	static foreach (column; columns)
	{
		body ~= "        - name: " ~ column.name ~ "\n";
		body ~= "          type: " ~ column.type ~ "\n";
		body ~= "          jsonPath: " ~ column.jsonPath ~ "\n";
	}
	body ~= "      schema:\n";
	body ~= "        openAPIV3Schema:\n";
	body ~= "          type: object\n";
	static if (crdDescription.length > 0)
		body ~= "          description: " ~ yamlStr(crdDescription) ~ "\n";
	static if (hasSpec)
	{
		body ~= "          required:\n";
		body ~= "            - spec\n";
	}
	body ~= "          properties:\n";
	static if (hasSpec)
	{
		body ~= "            spec:\n";
		body ~= emitType!(typeof(T.init.spec))(7, Deco.init);
	}
	static if (hasStatus)
	{
		alias StatusT = typeof(T.init.status);
		body ~= "            status:\n";
		body ~= emitType!StatusT(7, Deco.init);
	}

	// Both versions share one schema, so the API server's default `None` conversion is
	// lossless and no conversion webhook is needed.
	s ~= "  versions:\n";
	s ~= "    - name: " ~ version_ ~ "\n";
	s ~= "      served: true\n";
	s ~= "      storage: true\n";
	s ~= body;
	s ~= "    - name: " ~ crDeprecatedVersion ~ "\n";
	s ~= "      served: true\n";
	s ~= "      storage: false\n";
	s ~= "      deprecated: true\n";
	s ~= "      deprecationWarning: " ~ yamlStr(group ~ "/" ~ crDeprecatedVersion ~ " " ~ kind
		~ " is deprecated; use " ~ apiVersion) ~ "\n";
	s ~= body;
	return s;
}

/// Handle the `write-structures <dir>` sub-command: generate one CRD YAML per
/// registered kind into `dir`. `args` is the sub-command argv (args[0] is the verb).
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
	string[] written;
	static foreach (T; CrdKinds)
	{{
		enum fileName = toLower(T.init.kind) ~ ".yaml";
		write(buildPath(dir, fileName), crdYaml!T());
		written ~= fileName;
	}}

	writeln("wrote ", written.join(", "), " to ", dir);
	return 0;
}

version (unittest)
{
	import fluent.asserts;
	import std.algorithm.searching : canFind;
}

unittest
{
	// yamlStr escapes quotes, backslashes, and the control chars that would otherwise
	// break the YAML line — so a multi-line @Description can't emit invalid YAML.
	yamlStr("plain").should.equal(`"plain"`);
	yamlStr(`a"b\c`).should.equal(`"a\"b\\c"`);
	yamlStr("line1\nline2\tend").should.equal(`"line1\nline2\tend"`);
	// Any other C0 control char (here a form feed) is escaped, not emitted raw.
	yamlStr("a\x0cb").should.equal(`"a\x0cb"`);
}

unittest
{
	// An enum's default and members are emitted as quoted scalars, so a future value like
	// `on`/`no`/`null` can't reparse as a YAML bool/null. decoOf pre-quotes defaultLit
	// (the same convention as every other type), and emitType emits it raw.
	enum Mode : string
	{
		red = "red",
		green = "green",
	}

	const yaml = emitType!Mode(0, Deco("", `"green"`));
	yaml.canFind(`default: "green"`).should.equal(true);
	yaml.canFind(`- "red"`).should.equal(true);
	yaml.canFind(`- "green"`).should.equal(true);
}

unittest
{
	// A bool field's default is emitted (the boolean arm previously dropped it silently).
	emitType!bool(0, Deco("", "true")).canFind("default: true").should.equal(true);
	// No default -> no default line.
	emitType!bool(0, Deco.init).canFind("default:").should.equal(false);
}

unittest
{
	// A string field's default is emitted, quoted.
	emitType!string(0, Deco("", `"v1alpha1"`)).canFind(`default: "v1alpha1"`).should.equal(true);
}

unittest
{
	// A string field's @Pattern (quoted) and @MaxLength become schema constraints, so a
	// bad cross-resource ref is rejected at admission instead of only at reconcile.
	Deco d;
	d.pattern = "^[a-z0-9]+$";
	d.hasMaxLength = true;
	d.maxLength = 253;
	const yaml = emitType!string(0, d);
	yaml.canFind(`pattern: "^[a-z0-9]+$"`).should.equal(true);
	yaml.canFind("maxLength: 253").should.equal(true);
}

unittest // ModelCatalog has no spec, so its schema neither requires nor declares one and takes its own description
{
	const yaml = crdYaml!ModelCatalog();
	[yaml.canFind("- spec"), yaml.canFind("            spec:"), yaml.canFind("status: {}"),
		yaml.canFind(`description: "The models the subsystem can run`)].should.equal([false, false, true, true]);
}

unittest // Agent is stored at v1beta1 and still served at v1alpha1, deprecated, with the same schema
{
	const yaml = crdYaml!Agent();
	const stored = yaml.indexOf("    - name: v1beta1\n      served: true\n      storage: true\n");
	const servedOnly = yaml.indexOf("    - name: v1alpha1\n      served: true\n      storage: false\n      deprecated: true\n"
		~ `      deprecationWarning: "agents.re-cinq.com/v1alpha1 Agent is deprecated; use agents.re-cinq.com/v1beta1"` ~ "\n");
	[stored > 0, servedOnly > stored].should.equal([true, true]);
	yaml[stored .. servedOnly].canFind("openAPIV3Schema").should.equal(true);
	yaml[servedOnly .. $].canFind("openAPIV3Schema").should.equal(true);
}
