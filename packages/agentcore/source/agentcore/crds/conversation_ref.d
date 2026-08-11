module agentcore.crds.conversation_ref;

import agentcore.crds.schema;

/// A previous run this one continues, so the agent resumes a conversation instead of
/// starting fresh.
///
/// The subsystem is a pure execution engine: `id` is opaque to it. What the id groups
/// — a feature, a ticket, a customer — is entirely the consumer's business, exactly as
/// it is for `skills_source` (#188 established the pattern).
///
/// Both fields are needed together. `source` without `id` has nothing to fetch; `id`
/// without `source` names a conversation that cannot be restored.
struct ConversationRef
{
	/// Base URL the init fetches the prior state archive from (`<source>/<id>`).
	@optional @Description("Base URL the prior conversation state is fetched from.")
	string source;

	/// The conversation to continue. Empty ⇒ start fresh.
	@optional @Description("Conversation to continue; empty starts a fresh one.")
	string id;

	/// Secret whose value is sent as the Authorization header when fetching. Empty ⇒
	/// unauthenticated, like the skills registry.
	@optional @wire("headers_secret") @Description(
		"Secret holding the Authorization header for the fetch.")
	string headersSecret;
}
