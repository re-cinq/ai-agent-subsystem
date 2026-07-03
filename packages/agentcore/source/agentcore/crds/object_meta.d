module agentcore.crds.object_meta;

import agentcore.crds.schema : optional;

/// Subset of Kubernetes ObjectMeta these resources use.
struct ObjectMeta
{
	@optional string name;
	@optional string generateName;
	@optional string namespace;
	@optional string uid;
	@optional string resourceVersion;
	@optional string[string] labels;
	@optional string[string] annotations;
}
