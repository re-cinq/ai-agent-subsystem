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

/// Map an executable name to the OS packages that provide it. Most tools are
/// named after their package; `sha256sum` and `base64` ship in `coreutils`. `curl`
/// brings `ca-certificates` along: apt installs without recommends, and dnf and apk
/// minimal images may lack the bundle too, and without it curl cannot verify any
/// https server — every download the init makes would fail.
string[] packagesFor(string exe) @safe pure
{
	switch (exe)
	{
	case "sha256sum":
	case "base64":
		return ["coreutils"];
	case "curl":
		return ["curl", "ca-certificates"];
	default:
		return [exe];
	}
}

unittest // curl installs with the ca-certificates bundle it needs for https
{
	packagesFor("curl").should.equal(["curl", "ca-certificates"]);
}

unittest // sha256sum and base64 install coreutils, git installs git
{
	packagesFor("git").should.equal(["git"]);
	packagesFor("sha256sum").should.equal(["coreutils"]);
	packagesFor("base64").should.equal(["coreutils"]);
}
