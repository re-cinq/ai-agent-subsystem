module agentcore.crds.model_catalog;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.schema;

/// One model a vendor's list-models API reported for a configured key.
struct ModelInfo
{
	@optional @Description("Model id to set as an AgentDefinition's or Agent's model.") string id;
	@optional @Description("The vendor's human-readable name for the model.") string displayName;
}

/// The models one vendor offers through the API keys AgentDefinitions map from agent-secrets.
struct VendorModels
{
	@optional @Description("Agent CLI vendor the subsystem routes these model ids to.") string vendor;
	@optional @Description("Provider API whose list-models endpoint was queried.") string provider;
	@optional @Description("agent-secrets keys that were queried; an AgentDefinition can run these models when its resources.secrets maps one of them.")
	string[] secretRefs;
	@optional @Description("Why the last refresh could not list models with some of the keys; empty when every key answered.")
	string error;
	@optional ModelInfo[] models;
}

/// What the controller found on its last refresh.
struct ModelCatalogStatus
{
	@optional @Description("RFC3339 timestamp of the last refresh.") @Format("date-time") string refreshedAt;
	@optional VendorModels[] vendors;
}

/// The models the subsystem can run, discovered by the controller from each vendor's
/// list-models API with the keys AgentDefinitions map from agent-secrets.
@Plural("modelcatalogs")
@ShortNames(["mc"])
@PrinterColumn("Refreshed", "date", ".status.refreshedAt")
@PrinterColumn("Age", "date", ".metadata.creationTimestamp")
@Description("The models the subsystem can run, written by the controller from each vendor's list-models API.")
struct ModelCatalog
{
	@optional string apiVersion = "agents.re-cinq.com/v1alpha1";
	@optional string kind = "ModelCatalog";
	@optional ObjectMeta metadata;
	@optional ModelCatalogStatus status;
}
