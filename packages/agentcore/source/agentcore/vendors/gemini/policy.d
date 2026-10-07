module agentcore.vendors.gemini.policy;

/// The gemini-cli policy behind `permission_mode: bypass`, loaded at user tier, which
/// outranks every rule the CLI ships. `--yolo` alone leaves those rules in charge of
/// what yolo does not cover: headless, they deny every shell command whenever the
/// approval mode is not yolo, and plan mode, which the model may enter on its own,
/// denies everything. So every tool is allowed in every mode, shell commands with
/// pipes and redirections included. `ask_user` stays denied: nobody answers a headless
/// run, and a question would wait forever.
enum geminiBypassPolicyToml =
	"[[rule]]\ntoolName = \"*\"\ndecision = \"allow\"\npriority = 100\nallowRedirection = true\n\n"
	~ "[[rule]]\ntoolName = \"ask_user\"\ndecision = \"deny\"\npriority = 200";
