module agentcore.tools.conversation_tool;

import agentcore.core.env : envConversationSource, envConversationId, envConversationAuth;
import agentcore.tools.initcontext : InitContext;
import agentcore.tools.tool : Tool;

/// Restore the state of a previous run so the agent continues that conversation
/// instead of starting fresh.
///
/// Modelled on the SkillsTool, and consumer-agnostic for the same reason: it fetches
/// `<source>/<id>` from the URL the recipe hands it and knows nothing about what the
/// id groups.
///
/// The state is restored as a whole DIRECTORY (a tarball extracted under `$HOME`)
/// rather than a single file, because a CLI's layout is its own business: Claude
/// writes `.claude/projects/<cwd-slug>/<id>.jsonl`, but Codex writes
/// `.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<timestamp>-<id>.jsonl` — a path that
/// cannot be derived from the id. Snapshotting the directory also handles multi-file
/// formats without this tool knowing any of them.
///
/// Best-effort by construction: a missing or unreachable archive leaves the run with a
/// fresh conversation rather than failing it. Losing continuity is a bad round; failing
/// here would be a lost one.
final class ConversationTool : Tool
{
	override string name() const @safe
	{
		return "conversation";
	}

	override string[] requires() const @safe
	{
		return ["sh", "curl", "tar"];
	}

	override string[][] steps(in InitContext ctx) const @safe
	{
		// Nothing to continue, or a vendor with no state directory to continue into.
		if (ctx.conversationId.length == 0 || ctx.conversationSource.length == 0
			|| ctx.conversationStateDir.length == 0)
			return null;

		// Source and id ride the env, never the command string — same reason as the
		// skills registry: a URL or id from the recipe must not be able to inject shell.
		const src = "\"$" ~ envConversationSource ~ "\"";
		const id = "\"$" ~ envConversationId ~ "\"";

		// The credential is read through `printenv`, not shell expansion. The env var
		// holding it is named after a Kubernetes SECRET KEY, and those routinely
		// contain dashes — `$agent-events-auth` expands `$agent` (unset) and leaves
		// `-events-auth` behind, so every restore answered 401 while the upload side,
		// which resolves the name in D, worked fine. The name itself now rides the
		// env too, so nothing from the recipe reaches the command string.
		const auth = ctx.conversationAuthEnv.length
			? "-H \"Authorization: $(printenv \"$" ~ envConversationAuth ~ "\")\" " : "";

		return [
			[
				"sh", "-c",
				"mkdir -p \"$HOME/" ~ ctx.conversationStateDir ~ "\" && curl -fsSL "
					~ auth ~ src ~ "/" ~ id ~ " | tar -xz -C \"$HOME\" 2>/dev/null || true",
			],
		];
	}
}

version (unittest) import fluent.asserts;

@safe unittest
{
	// Nothing declared: no step at all, so a fresh run pays nothing.
	InitContext ctx;
	(new ConversationTool).steps(ctx).length.should.equal(0);
}

@safe unittest
{
	// A vendor with no state dir cannot continue, so no restore is attempted even
	// when the consumer supplied a conversation.
	InitContext ctx;
	ctx.conversationSource = "https://floor/api/agent-conversations";
	ctx.conversationId = "conv-1";
	(new ConversationTool).steps(ctx).length.should.equal(0);
}

@safe unittest
{
	// A declared conversation extracts under $HOME, with source and id read from the
	// env rather than interpolated into the command.
	InitContext ctx;
	ctx.conversationSource = "https://floor/api/agent-conversations";
	ctx.conversationId = "conv-1";
	ctx.conversationStateDir = ".claude/projects";

	const steps = (new ConversationTool).steps(ctx);
	steps.length.should.equal(1);
	steps[0][0 .. 2].should.equal(["sh", "-c"]);
	steps[0][2].should.contain("$AGENT_CONVERSATION_SOURCE");
	steps[0][2].should.contain("$AGENT_CONVERSATION_ID");
	steps[0][2].should.contain("$HOME/.claude/projects");
	steps[0][2].should.contain("tar -xz -C \"$HOME\"");
	// The literal URL never enters the command string.
	steps[0][2].should.not.contain("https://floor");
	// No credential configured -> no Authorization header at all.
	steps[0][2].should.not.contain("Authorization");
}

@safe unittest
{
	// A configured credential is sent, resolved from its env var rather than baked in.
	InitContext ctx;
	ctx.conversationSource = "https://floor/api/agent-conversations";
	ctx.conversationId = "conv-1";
	ctx.conversationStateDir = ".claude/projects";
	ctx.conversationAuthEnv = "agent-events-auth";

	const step = (new ConversationTool).steps(ctx)[0][2];
	// Read via printenv, because a secret-key name with dashes is not a shell
	// variable name — `$agent-events-auth` would send `-events-auth`.
	step.should.contain("Authorization: $(printenv \"$AGENT_CONVERSATION_AUTH\")");
	step.should.not.contain("$agent-events-auth");
}

@safe unittest
{
	// An unreachable archive must not fail the run — continuity is lost, the round is not.
	InitContext ctx;
	ctx.conversationSource = "https://floor/api/agent-conversations";
	ctx.conversationId = "conv-1";
	ctx.conversationStateDir = ".codex/sessions";
	(new ConversationTool).steps(ctx)[0][2].should.contain("|| true");
}
