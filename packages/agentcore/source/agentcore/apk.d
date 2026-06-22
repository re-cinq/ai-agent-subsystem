module agentcore.apk;

import agentcore.packagemanager : PackageManager;

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
	assert(apk.name == "apk");
	assert(apk.installSteps(["git", "curl"]) == [["apk", "add", "--no-cache", "git", "curl"]]);
}
