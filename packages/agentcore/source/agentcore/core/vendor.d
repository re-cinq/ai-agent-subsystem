module agentcore.core.vendor;

import std.algorithm.searching : startsWith, canFind;
import std.uni : toLower;

/// The vendor a model id belongs to — the single classification both the CLI adapter
/// routing and batch provider routing use, so the two cannot diverge. The literal `exec`
/// id is the non-LLM command runner (station recipes); an explicit `opencode` /
/// `opencode/…` id is OpenCode; the GPT / o-series / codex family is Codex; Gemini models
/// are Gemini; Claude models and the empty or unrecognized case are Claude (the system
/// default). OpenCode is checked first so an `opencode/openai/gpt-…` id routes to
/// OpenCode rather than matching the Codex `gpt` rule.
enum Vendor
{
	claude,
	codex,
	exec,
	gemini,
	opencode,
}

/// ditto
Vendor vendorOf(string model) @safe pure
{
	const m = model.toLower;
	if (m == "exec")
		return Vendor.exec;
	if (m.canFind("opencode"))
		return Vendor.opencode;
	if (m.canFind("gemini"))
		return Vendor.gemini;
	if (m.canFind("codex") || m.startsWith("gpt") || m.startsWith("o1")
		|| m.startsWith("o3") || m.startsWith("o4"))
		return Vendor.codex;
	return Vendor.claude;
}

version (unittest) import fluent.asserts;

@safe unittest // model ids map to their vendor, opencode winning over gpt and exec matching exactly
{
	const vendors = [
		"claude-sonnet-4-6": Vendor.claude,
		"": Vendor.claude,
		"something-weird": Vendor.claude,
		"executive-model": Vendor.claude,
		"gpt-5-codex": Vendor.codex,
		"gpt-4.1": Vendor.codex,
		"o1-preview": Vendor.codex,
		"o3-mini": Vendor.codex,
		"o4-mini": Vendor.codex,
		"opencode": Vendor.opencode,
		"opencode/openai/gpt-4.1": Vendor.opencode,
		"gemini-1.5-pro": Vendor.gemini,
		"exec": Vendor.exec,
		"EXEC": Vendor.exec,
	];
	foreach (model, vendor; vendors)
		vendorOf(model).should.equal(vendor);
}
