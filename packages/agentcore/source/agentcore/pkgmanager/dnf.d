module agentcore.pkgmanager.dnf;

import agentcore.pkgmanager.packagemanager : PackageManager;

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
	assert(dnf.name == "dnf");
	assert(dnf.installSteps(["git"]) == [["dnf", "install", "-y", "git"]]);
}
