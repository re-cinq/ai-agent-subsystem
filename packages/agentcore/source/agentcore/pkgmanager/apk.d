module agentcore.pkgmanager.apk;

import agentcore.pkgmanager.packagemanager : PackageManager;

version (unittest) import fluent.asserts;

/// Alpine. (The D binaries are glibc-linked, so this only applies once a musl
/// build exists — included for completeness and future-proofing.)
final class Apk : PackageManager
{
	override string name() const @safe
	{
		return "apk";
	}

	override string[][] installSteps(const string[] packages) const @safe
	{
		return [["apk", "add", "--no-cache"] ~ packages.dup];
	}
}

unittest
{
	auto apk = new Apk;
	apk.name.should.equal("apk");
	apk.installSteps(["git", "curl"]).should.equal([["apk", "add", "--no-cache", "git", "curl"]]);
}
