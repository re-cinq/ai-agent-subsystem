module agentcore.pkgmanager.apt;

import agentcore.pkgmanager.packagemanager : PackageManager;

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
	assert(apt.name == "apt");
	assert(apt.installSteps(["git", "curl"]) == [
		["apt-get", "update"],
		["apt-get", "install", "--no-install-recommends", "-y", "git", "curl"]
	]);
}
