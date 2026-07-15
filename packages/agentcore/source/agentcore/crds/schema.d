module agentcore.crds.schema;

import std.traits : getUDAs, hasUDA;
import vibe.data.serialization : NameAttribute;

import agentcore.crds.serialization : CrdPolicy;

// User-Defined Attributes that carry CRD schema metadata which plain D types
// cannot express: human descriptions, required flags, numeric bounds, and
// "preserve unknown fields" objects. The annotated model in agentcore.crds is the
// single source of truth a CRD generator can read at compile time. Wire field names
// and per-field optionality come from vibe's serialization attributes (`@wire`,
// `@optional`), re-exported here so a CRD struct only has to import this module.
public import agentcore.crds.serialization : wire;
public import vibe.data.serialization : optional;

/// Human description, mapped to the field/type `description` in the CRD schema.
struct Description
{
	string text;
}

/// Inclusive lower bound for an integer field (`minimum` in the schema).
struct Minimum
{
	long value;
}

/// Regex a string field's value must match (`pattern` in the schema).
struct Pattern
{
	string regex;
}

/// Inclusive upper bound on a string field's length (`maxLength` in the schema).
struct MaxLength
{
	long value;
}

/// The DNS-1123 subdomain a Kubernetes object name must match. Reused as the `@Pattern`
/// for cross-resource ref fields (stationRef/agentDefRef) so a name typo is rejected at
/// admission instead of only failing later at reconcile. Paired with `@MaxLength(253)`.
enum dns1123Subdomain = `^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$`;

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

/// The wire field name for `sym`: its `@wire` name if present, else its identifier.
template jsonNameOf(alias sym)
{
	static if (hasUDA!(sym, NameAttribute!CrdPolicy))
		enum jsonNameOf = getUDAs!(sym, NameAttribute!CrdPolicy)[0].name;
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
