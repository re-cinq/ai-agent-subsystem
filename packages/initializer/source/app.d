module app;

import core.sys.posix.signal : signal, SIGPIPE, SIG_IGN;

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

	// Ignore SIGPIPE (as the supervisor does): notify writes the curl config to a child's
	// stdin, and if curl exits before reading it (killed, or a config it rejects), the
	// write would otherwise raise SIGPIPE and kill PID 1 of the init container — turning a
	// retryable sink failure into a fatal Pod init failure. Ignored, the write instead
	// fails with a catchable ErrnoException that curlOnce turns into a clean retry.
	signal(SIGPIPE, SIG_IGN);

	return provision(contextFromEnv());
}
