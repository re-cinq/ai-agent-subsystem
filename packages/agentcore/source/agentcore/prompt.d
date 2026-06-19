module agentcore.prompt;

import std.array : appender;

/**
 * Render a prompt template by substituting `{placeholder}` tokens from
 * `parameters`. A placeholder name may contain letters, digits, `_`, `.` and
 * `-`. Unknown placeholders are left intact (so typos surface in the rendered
 * prompt). An empty template renders to an empty string.
 */
string renderPrompt(string templ, const string[string] parameters) @safe
{
	if (templ.length == 0)
		return "";

	auto result = appender!string();
	size_t i = 0;
	while (i < templ.length)
	{
		if (templ[i] == '{')
		{
			size_t j = i + 1;
			while (j < templ.length && isKeyChar(templ[j]))
				j++;
			if (j > i + 1 && j < templ.length && templ[j] == '}')
			{
				const key = templ[i + 1 .. j];
				if (auto value = key in parameters)
					result.put(*value);
				else
					result.put(templ[i .. j + 1]);
				i = j + 1;
				continue;
			}
		}
		result.put(templ[i]);
		i++;
	}
	return result.data;
}

private bool isKeyChar(char c) @safe @nogc nothrow pure
{
	return (c >= 'a' && c <= 'z')
		|| (c >= 'A' && c <= 'Z')
		|| (c >= '0' && c <= '9')
		|| c == '_' || c == '.' || c == '-';
}

@safe unittest
{
	assert(renderPrompt("Fix {ticket}.", ["ticket": "ENG-1"]) == "Fix ENG-1.");
	assert(renderPrompt("Repo {repo} branch {repo}", ["repo": "main"]) == "Repo main branch main");
}

@safe unittest
{
	// Unknown placeholders are left intact.
	assert(renderPrompt("Fix {ticket}.", null) == "Fix {ticket}.");
	string[string] empty;
	assert(renderPrompt("Fix {ticket}.", empty) == "Fix {ticket}.");
	assert(renderPrompt("Unknown {missing} stays", ["x": "y"]) == "Unknown {missing} stays");
}

@safe unittest
{
	// Empty template and literal braces.
	assert(renderPrompt("", ["a": "b"]) == "");
	assert(renderPrompt("No placeholders here", null) == "No placeholders here");
	assert(renderPrompt("brace { not closed", ["a": "b"]) == "brace { not closed");
	assert(renderPrompt("empty {} braces", ["a": "b"]) == "empty {} braces");
}
