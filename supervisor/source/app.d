module app;

import std.stdio : writeln, writefln;
import std.process : environment;

import agentcore.env;

int main()
{
	const prompt = environment.get(envPrompt, "");
	const model = environment.get(envModel, defaultModel);
	const notify = environment.get(envNotifyUrl, "");

	writefln("ai-agent supervisor: model=%s notifyConfigured=%s promptBytes=%s",
		model, notify.length > 0, prompt.length);

	writeln("agent process supervision not yet implemented (bootstrap)");
	return 0;
}
