module agentcore.schema;

import std.traits : getUDAs, hasUDA;

// User-Defined Attributes that carry CRD schema metadata which plain D types
// cannot express: human descriptions, wire (JSON/YAML) field names, required
// flags, numeric bounds, and "preserve unknown fields" objects. The annotated
// model in agentcore.crds is the single source of truth a CRD generator can
// read at compile time.

/// Human description, mapped to the field/type `description` in the CRD schema.
struct Description
{
	string text;
}

/// Wire field name when it differs from the D identifier
/// (snake_case fields, or D keywords like `ref`/`template`).
struct Json
{
	string name;
}

/// Inclusive lower bound for an integer field (`minimum` in the schema).
struct Minimum
{
	long value;
}

/// Marks a field as required in the CRD schema.
enum Required;

/// Marks an object that preserves unknown fields
/// (`x-kubernetes-preserve-unknown-fields: true`).
enum PreserveUnknownFields;

/// The `@Description` text attached to `sym`, or "" when absent.
template descriptionOf(alias sym)
{
	static if (hasUDA!(sym, Description))
		enum descriptionOf = getUDAs!(sym, Description)[0].text;
	else
		enum descriptionOf = "";
}

/// The wire field name for `sym`: its `@Json` name if present, else its identifier.
template jsonNameOf(alias sym)
{
	static if (hasUDA!(sym, Json))
		enum jsonNameOf = getUDAs!(sym, Json)[0].name;
	else
		enum jsonNameOf = __traits(identifier, sym);
}

/// Whether `sym` is annotated `@Required`.
template isRequired(alias sym)
{
	enum isRequired = hasUDA!(sym, Required);
}

// CRD-level metadata for a resource type — the `names` / `printerColumns` parts
// that are not derivable from the field set.

/// The CRD plural name (e.g. "agentdefinitions").
struct Plural
{
	string value;
}

/// The CRD short names (e.g. ["agentdef", "ad"]).
struct ShortNames
{
	string[] values;
}

/// One `kubectl get` printer column.
struct PrinterColumn
{
	string name;
	string type;
	string jsonPath;
}

/// An OpenAPI string `format` for a field (e.g. "date-time").
struct Format
{
	string value;
}

/// The `@Plural` value of a resource type.
template pluralOf(alias T)
{
	enum pluralOf = getUDAs!(T, Plural)[0].value;
}

/// The `@ShortNames` values of a resource type.
template shortNamesOf(alias T)
{
	enum shortNamesOf = getUDAs!(T, ShortNames)[0].values;
}

/// Every `@PrinterColumn` on a resource type, in declaration order.
template printerColumnsOf(alias T)
{
	enum printerColumnsOf = [getUDAs!(T, PrinterColumn)];
}

/// The `@Format` value for `sym`, or "" when absent.
template formatOf(alias sym)
{
	static if (hasUDA!(sym, Format))
		enum formatOf = getUDAs!(sym, Format)[0].value;
	else
		enum formatOf = "";
}
