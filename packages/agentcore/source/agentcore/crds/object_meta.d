module agentcore.crds.object_meta;

/// Subset of Kubernetes ObjectMeta these resources use.
struct ObjectMeta
{
	string name;
	string generateName;
	string namespace;
	string uid;
	string[string] labels;
	string[string] annotations;
}
