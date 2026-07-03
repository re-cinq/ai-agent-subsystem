module agentcore.pkgmanager.packagemanager;

version (unittest) import fluent.asserts;

/// A pluggable OS package manager, used by the init container to install missing
/// prerequisites (git, curl, sha256sum, …). The initializer probes `PATH` to pick
/// the implementation; new distros are added by implementing this interface.
interface PackageManager
{
	/// Identifier (e.g. "apt", "dnf", "apk").
	string name() const @safe;

	/// The argv steps that install `packages`, in order.
	string[][] installSteps(const string[] packages) const @safe;
}

/// Map an executable name to the OS package that provides it. Most tools are
/// named after their package; `sha256sum` ships in `coreutils`.
string packageFor(string exe) @safe pure
{
	switch (exe)
	{
	case "sha256sum":
		return "coreutils";
	default:
		return exe;
	}
}

unittest
{
	packageFor("git").should.equal("git");
	packageFor("curl").should.equal("curl");
	packageFor("sha256sum").should.equal("coreutils");
}
