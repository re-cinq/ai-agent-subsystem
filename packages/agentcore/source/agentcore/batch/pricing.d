module agentcore.batch.pricing;

/// Standard Anthropic first-party prices in USD per 1M tokens, taken 2026-10-14. Batch
/// requests are billed at half of these. A model with a long-prompt tier bills the whole
/// request at `longPrompt` once its input exceeds `longPromptAbove` tokens.
private struct Rate
{
	double input;
	double output;
}

/// ditto
private struct Price
{
	Rate standard;
	long longPromptAbove = long.max;
	Rate longPrompt;
}

private immutable Price[string] standardPrices;

shared static this()
{
	standardPrices = [
		"claude-fable-5-1": Price(Rate(10, 50)),
		"claude-fable-5": Price(Rate(10, 50)),
		"claude-opus-5-5": Price(Rate(4, 20)),
		"claude-opus-5": Price(Rate(5, 25)),
		"claude-opus-4-8": Price(Rate(5, 25)),
		"claude-opus-4-7": Price(Rate(5, 25)),
		"claude-opus-4-6": Price(Rate(5, 25)),
		"claude-sonnet-5-5": Price(Rate(2, 10)),
		"claude-sonnet-5": Price(Rate(2, 10)),
		"claude-sonnet-4-6": Price(Rate(3, 15)),
		"claude-haiku-5-5": Price(Rate(0.10, 0.50), 100_000, Rate(0.50, 2.50)),
		"claude-haiku-4-5": Price(Rate(1, 5)),
	];
}

private enum batchDiscount = 0.5;

/// What a batch request to `model` costs in USD; 0 for a model id not in the table.
double batchCostUsd(string model, long inputTokens, long outputTokens) @safe
{
	const price = model in standardPrices;
	if (price is null)
		return 0;
	const tier = inputTokens > price.longPromptAbove ? price.longPrompt : price.standard;
	return (inputTokens * tier.input + outputTokens * tier.output) / 1_000_000 * batchDiscount;
}

version (unittest) import fluent.asserts;

unittest // claude-opus-5-5 with 1M input and 1M output tokens costs 12 usd at the batch discount
{
	batchCostUsd("claude-opus-5-5", 1_000_000, 1_000_000).should.be.approximately(12.0, 1e-9);
}

unittest // claude-haiku-5-5 with 200K input and 1M output tokens bills the long-prompt tier at 1.30 usd
{
	batchCostUsd("claude-haiku-5-5", 200_000, 1_000_000).should.be.approximately(1.30, 1e-9);
}

unittest // claude-haiku-5-5 with exactly 100K input and 0 output tokens bills the short tier at 0.005 usd
{
	batchCostUsd("claude-haiku-5-5", 100_000, 0).should.be.approximately(0.005, 1e-12);
}

unittest // unknown model claude-sonnet-4-5 and a prefixed claude-opus-5-5-20261001 cost 0
{
	[batchCostUsd("claude-sonnet-4-5", 1000, 1000), batchCostUsd("claude-opus-5-5-20261001", 1000, 1000)]
		.should.equal([0.0, 0.0]);
}
