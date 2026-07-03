module app;

import provision : contextFromEnv, provision;

/// The init container's entrypoint: read what the controller injected, provision
/// the environment, and exit with the result (0 success, non-zero fails the Pod
/// before the supervisor container starts).
int main()
{
	// `dub test` runs main after the module unittests; return before provisioning so
	// the test binary exits 0 instead of attempting a real clone/install.
	version (unittest)
		return 0;

	return provision(contextFromEnv());
}
