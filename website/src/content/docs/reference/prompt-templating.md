---
title: Prompt templating
description: How an AgentDefinition prompt is rendered from an Agent's parameters.
---

The recipe's `prompt` is a template. At reconcile time the controller fills `{placeholder}` tokens
from the Agent's `spec.parameters` and passes the result to the agent as `LORE_PROMPT`.

## Rules

- A token is `{` followed by a name and `}`. Names may contain letters, digits, `_`, `.`, and `-`.
- If the name exists in `parameters`, the token is replaced with its value.
- If the name is **not** found, the token is **left unchanged** — typos surface in the rendered
  prompt instead of failing silently.
- A missing or empty template renders to an empty string.
- The same placeholder may appear multiple times; every occurrence is filled.

## Examples

| Template | Parameters | Result |
| --- | --- | --- |
| `Fix {ticket}.` | `{ticket: ENG-1}` | `Fix ENG-1.` |
| `Fix {ticket}.` | `{}` | `Fix {ticket}.` |
| `Repo {repo} branch {repo}` | `{repo: main}` | `Repo main branch main` |
| *(empty)* | `{a: b}` | *(empty)* |

This is a deliberately small, predictable substitution — no conditionals, loops, or expressions.
Keep logic in the recipe's prose, not the template engine.
