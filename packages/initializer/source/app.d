module app;

import provision : contextFromEnv, provision;

/// The init container's entrypoint: read what the controller injected, provision
/// the environment, and exit with the result (0 success, non-zero fails the Pod
/// before the supervisor container starts).
int main()
{
	return provision(contextFromEnv());
}
