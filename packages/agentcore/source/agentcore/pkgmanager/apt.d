module agentcore.pkgmanager.apt;

import agentcore.pkgmanager.packagemanager : PackageManager;

version (unittest) import fluent.asserts;

/// Debian / Ubuntu. Refresh the index, then install without recommends.
final class Apt : PackageManager
{
	override string name() const @safe
	{
		return "apt";
	}

	override string[][] installSteps(const string[] packages) const @safe
	{
		return [
			["apt-get", "update"],
			["apt-get", "install", "--no-install-recommends", "-y"] ~ packages.dup
		];
	}
}

unittest
{
	auto apt = new Apt;
	apt.name.should.equal("apt");
	apt.installSteps(["git", "curl"]).should.equal([
		["apt-get", "update"],
		["apt-get", "install", "--no-install-recommends", "-y", "git", "curl"]
	]);
}
