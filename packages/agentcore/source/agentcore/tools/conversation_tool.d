module agentcore.tools.conversation_tool;

import agentcore.core.env : envConversationSource, envConversationId,
	envConversationAuthValue;
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

		// The credential rides a SHELL-SAFE name the init exported for us.
		//
		// It cannot be read from its own variable here at any cost: that variable is
		// named after a Kubernetes secret key (`agent-events-auth`), and a shell does
		// not propagate a variable whose name is not a valid shell identifier — so
		// `printenv "$AGENT_CONVERSATION_AUTH"` returns EMPTY from inside `sh -c`,
		// and the header goes out with no value. Two previous fixes here corrected
		// the SYNTAX of that read (`$agent-events-auth` does not expand; the value is
		// already a whole header line) and both were true and both still 401'd,
		// because the read itself was impossible.
		const auth = ctx.conversationAuthEnv.length
			? "-H \"$" ~ envConversationAuthValue ~ "\" " : "";

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
	// A configured credential is sent through a SHELL-SAFE variable.
	//
	// This asserts the PROPERTY, not a spelling: the step must not name the
	// recipe-supplied variable at all, and must not try to read it with printenv.
	// The two previous fixes here each asserted their own syntax, so each passed
	// while the credential still arrived empty — the read was impossible, not
	// misspelled.
	InitContext ctx;
	ctx.conversationSource = "https://floor/api/agent-conversations";
	ctx.conversationId = "conv-1";
	ctx.conversationStateDir = ".claude/projects";
	ctx.conversationAuthEnv = "agent-events-auth";

	const step = (new ConversationTool).steps(ctx)[0][2];

	step.should.contain("-H \"$LORE_CONVERSATION_AUTH\"");
	// The secret-key name is not a shell identifier: no shell can read it, so the
	// step must never mention it or reach for it.
	step.should.not.contain("agent-events-auth");
	step.should.not.contain("printenv");
	step.should.not.contain("AGENT_CONVERSATION_AUTH");
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
