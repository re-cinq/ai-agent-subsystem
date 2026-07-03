module agentcore.pkgmanager.packagemanagerselect;

import agentcore.pkgmanager.apk : Apk;
import agentcore.pkgmanager.apt : Apt;
import agentcore.pkgmanager.dnf : Dnf;
import agentcore.pkgmanager.packagemanager : PackageManager;

version (unittest) import fluent.asserts;

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
	packageManagerByName("apt").name.should.equal("apt");
	packageManagerByName("dnf").name.should.equal("dnf");
	packageManagerByName("apk").name.should.equal("apk");
	(packageManagerByName("zypper") is null).should.equal(true);
}
