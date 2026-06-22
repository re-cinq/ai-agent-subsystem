module agentcore.packagemanagerselect;

import agentcore.apk : Apk;
import agentcore.apt : Apt;
import agentcore.dnf : Dnf;
import agentcore.packagemanager : PackageManager;

/// Select a package manager by identifier. The initializer probes `PATH` for
/// `apt-get`/`dnf`/`apk` and passes the match here; an unknown name yields null.
PackageManager packageManagerByName(string name) @safe
{
	switch (name)
	{
	case "apt":
		return new Apt;
	case "dnf":
		return new Dnf;
	case "apk":
		return new Apk;
	default:
		return null;
	}
}

unittest
{
	assert(packageManagerByName("apt").name == "apt");
	assert(packageManagerByName("dnf").name == "dnf");
	assert(packageManagerByName("apk").name == "apk");
	assert(packageManagerByName("zypper") is null);
}
