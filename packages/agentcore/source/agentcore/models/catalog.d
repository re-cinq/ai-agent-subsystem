module agentcore.models.catalog;

import std.algorithm : filter, joiner, map, multiSort, sort, uniq;
import std.array : array, join;
import std.conv : to;
import vibe.data.json : Json;

import agentcore.batch.provider : batchVendor, HttpTransport;
import agentcore.core.vendor : Vendor;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.model_catalog : ModelCatalog, ModelCatalogStatus, ModelInfo, VendorModels;
import agentcore.crds.serialization : toJson;
import agentcore.kube.jobspec : agentSecretName;
import agentcore.models.listing : listModels;

version (unittest)
{
	import agentcore.batch.provider : HttpRequest, HttpResponse;
	import agentcore.crds.secret_ref : SecretRef;
	import fluent.asserts;
	import vibe.data.json : parseJsonString;
}

/// The cluster operations a catalog refresh needs, behind an interface so the refresh is
/// fake-testable — the same seam posture as `KubeClient`.
interface ModelCatalogClient
{
	/// Every AgentDefinition in the namespace.
	AgentDefinition[] listAgentDefinitions(string ns);

	/// The decoded value of `key` in Secret `name`; throws `NotFound` when either is absent.
	string secretValue(string ns, string name, string key);

	/// Server-side apply the ModelCatalog object `catalog`, status included.
	void applyModelCatalog(string ns, Json catalog);
}

/// The one ModelCatalog the controller writes in its namespace.
enum modelCatalogName = "default";

/// The vendors with a list-models API, in the order the catalog lists them.
private immutable Vendor[] listableVendors = [Vendor.claude, Vendor.codex, Vendor.gemini];

/// An agent-secrets key that carries a vendor's API key.
struct VendorKey
{
	Vendor vendor;
	string secretRef;
}

/// What listing the models of one key gave: its models, or why it could not.
struct KeyListing
{
	VendorKey key;
	ModelInfo[] models;
	string error;
}

/// List the models of every vendor key the namespace's AgentDefinitions map, and apply
/// them as the `default` ModelCatalog stamped `now`.
void refreshModelCatalog(ModelCatalogClient client, string ns, HttpTransport transport, string now)
{
	auto listings = vendorKeys(client.listAgentDefinitions(ns))
		.map!(key => listKey(client, ns, key, transport))
		.array;
	client.applyModelCatalog(ns, catalogObject(ModelCatalogStatus(now, vendorModels(listings))));
}

/// The distinct agent-secrets keys `definitions` map under a vendor's API key env name,
/// ordered by vendor then key.
VendorKey[] vendorKeys(AgentDefinition[] definitions)
{
	auto keys = definitions
		.map!(definition => definition.spec.resources.secrets)
		.joiner
		.map!(secret => listableVendors
				.filter!(vendor => batchVendor(vendor).apiKeyEnv == secret.name)
				.map!(vendor => VendorKey(vendor, secret.ref_)))
		.joiner
		.array;
	keys.multiSort!("a.vendor < b.vendor", "a.secretRef < b.secretRef");
	return keys.uniq.array;
}

/// The models one vendor key lists; a failure to read the key or reach the vendor is
/// recorded on the listing so the other keys still make the catalog.
KeyListing listKey(ModelCatalogClient client, string ns, VendorKey key, HttpTransport transport)
{
	try
		return KeyListing(key, listModels(key.vendor, client.secretValue(ns, agentSecretName, key.secretRef), transport));
	catch (Exception error)
		return KeyListing(key, null, error.msg);
}

/// One catalog entry per vendor with listings: the keys queried, the failures, and the
/// union of their models by id, sorted.
VendorModels[] vendorModels(KeyListing[] listings)
{
	return listableVendors
		.map!(vendor => listings.filter!(listing => listing.key.vendor == vendor).array)
		.filter!(ofVendor => ofVendor.length > 0)
		.map!(ofVendor => VendorModels(
				ofVendor[0].key.vendor.to!string,
				batchVendor(ofVendor[0].key.vendor).provider,
				ofVendor.map!(listing => listing.key.secretRef).array,
				ofVendor.filter!(listing => listing.error.length > 0)
				.map!(listing => listing.key.secretRef ~ ": " ~ listing.error)
				.join("; "),
				distinctById(ofVendor.map!(listing => listing.models).joiner.array)))
		.array;
}

private ModelInfo[] distinctById(ModelInfo[] models)
{
	return models.sort!((a, b) => a.id < b.id).uniq!((a, b) => a.id == b.id).array;
}

/// The ModelCatalog object to server-side apply: only the fields the controller owns, so
/// the apply claims no metadata it does not set.
Json catalogObject(ModelCatalogStatus status)
{
	return Json([
		"apiVersion": Json(ModelCatalog.init.apiVersion),
		"kind": Json(ModelCatalog.init.kind),
		"metadata": Json(["name": Json(modelCatalogName)]),
		"status": toJson(status),
	]);
}

version (unittest)
{
	private AgentDefinition definitionMapping(SecretRef[] secrets)
	{
		AgentDefinition definition;
		definition.spec.resources.secrets = secrets;
		return definition;
	}

	private final class FakeCatalogClient : ModelCatalogClient
	{
		AgentDefinition[] definitions;
		string[string] secrets;
		Json applied;

		this(AgentDefinition[] definitions, string[string] secrets)
		{
			this.definitions = definitions;
			this.secrets = secrets;
		}

		AgentDefinition[] listAgentDefinitions(string ns)
		{
			return definitions;
		}

		string secretValue(string ns, string name, string key)
		{
			import agentcore.kube.kubeclient : NotFound;
			import std.exception : enforce;

			enforce(key in secrets, new NotFound("Secret has no key " ~ key));
			return secrets[key];
		}

		void applyModelCatalog(string ns, Json catalog)
		{
			applied = catalog;
		}
	}

	/// Answers each vendor's list-models URL by host, with the key that authenticated it.
	private HttpResponse vendorApi(HttpRequest request)
	{
		import std.algorithm.searching : canFind;

		if (request.url.canFind("anthropic"))
			return request.headers["x-api-key"] == "sk-ant-good"
				? HttpResponse(200, `{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"}],"has_more":false}`)
				: HttpResponse(401, `{"error":"invalid x-api-key"}`);
		return HttpResponse(200, `{"data":[{"id":"gpt-5.1","object":"model"},{"id":"dall-e-3","object":"model"}]}`);
	}
}

unittest // keys mapped under ANTHROPIC_API_KEY and OPENAI_API_KEY by two definitions are listed once each, other envs ignored
{
	vendorKeys([
		definitionMapping([SecretRef("OPENAI_API_KEY", "openai-key"), SecretRef("GITHUB_TOKEN", "gh-token")]),
		definitionMapping([SecretRef("ANTHROPIC_API_KEY", "team-b-key"), SecretRef("OPENAI_API_KEY", "openai-key")]),
		definitionMapping([SecretRef("ANTHROPIC_API_KEY", "team-a-key")]),
	]).should.equal([VendorKey(Vendor.claude, "team-a-key"), VendorKey(Vendor.claude, "team-b-key"),
		VendorKey(Vendor.codex, "openai-key")]);
}

unittest // two claude keys merge into one entry with their models deduplicated and the failing key's error
{
	vendorModels([
		KeyListing(VendorKey(Vendor.claude, "team-a-key"), [ModelInfo("claude-sonnet-5-5", "Claude Sonnet 5.5"),
			ModelInfo("claude-opus-5-5", "Claude Opus 5.5")]),
		KeyListing(VendorKey(Vendor.claude, "team-b-key"), [ModelInfo("claude-opus-5-5", "Claude Opus 5.5")]),
		KeyListing(VendorKey(Vendor.claude, "expired-key"), null, "HTTP 401"),
	]).should.equal([VendorModels("claude", "anthropic", ["team-a-key", "team-b-key", "expired-key"],
		"expired-key: HTTP 401", [ModelInfo("claude-opus-5-5", "Claude Opus 5.5"),
			ModelInfo("claude-sonnet-5-5", "Claude Sonnet 5.5")])]);
}

unittest // refresh applies the default catalog with claude-opus-5-5 and gpt-5.1, a revoked key and a missing key as errors
{
	auto client = new FakeCatalogClient([
		definitionMapping([SecretRef("ANTHROPIC_API_KEY", "anthropic-key"), SecretRef("OPENAI_API_KEY", "openai-key")]),
		definitionMapping([SecretRef("ANTHROPIC_API_KEY", "revoked-key"), SecretRef("GEMINI_API_KEY", "missing-key")]),
	], ["anthropic-key": "sk-ant-good", "revoked-key": "sk-ant-revoked", "openai-key": "sk-openai"]);

	refreshModelCatalog(client, "ai-agents", (request) => vendorApi(request), "2026-10-14T12:00:00Z");

	client.applied.should.equal(parseJsonString(`{
		"apiVersion": "agents.re-cinq.com/v1beta1", "kind": "ModelCatalog", "metadata": {"name": "default"},
		"status": {"refreshedAt": "2026-10-14T12:00:00Z", "vendors": [
			{"vendor": "claude", "provider": "anthropic", "secretRefs": ["anthropic-key", "revoked-key"],
				"error": "revoked-key: GET https://api.anthropic.com/v1/models?limit=1000: HTTP 401: {\"error\":\"invalid x-api-key\"}",
				"models": [{"id": "claude-opus-5-5", "displayName": "Claude Opus 5.5"}]},
			{"vendor": "codex", "provider": "openai", "secretRefs": ["openai-key"], "error": "",
				"models": [{"id": "gpt-5.1", "displayName": "gpt-5.1"}]},
			{"vendor": "gemini", "provider": "gemini", "secretRefs": ["missing-key"],
				"error": "missing-key: Secret has no key missing-key", "models": []}
		]}}`));
}
