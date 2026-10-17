module agentcore.crds.api_group;

/// The API group and version every CRD is served and stored at. crdgen, tsgen, the
/// controller's API paths and the Job owner references all read these, so a version
/// bump is this one edit plus `make regen`.
enum crGroup = "agents.re-cinq.com";
enum crVersion = "v1beta1";
enum crApiVersion = crGroup ~ "/" ~ crVersion;

/// The previous version, still served with the same schema so existing manifests and
/// clients keep working; the API server answers requests for it with a deprecation warning.
enum crDeprecatedVersion = "v1alpha1";
