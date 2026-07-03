module agentcore.pkgmanager.dnf;

import agentcore.pkgmanager.packagemanager : PackageManager;

version (unittest) import fluent.asserts;

/// Fedora / RHEL / CentOS Stream.
final class Dnf : PackageManager
{
	override string name() const @safe
	{
		return "dnf";
	}

	override string[][] installSteps(const string[] packages) const @safe
	{
		return [["dnf", "install", "-y"] ~ packages.dup];
	}
}

unittest
{
	auto dnf = new Dnf;
	dnf.name.should.equal("dnf");
	dnf.installSteps(["git"]).should.equal([["dnf", "install", "-y", "git"]]);
}
