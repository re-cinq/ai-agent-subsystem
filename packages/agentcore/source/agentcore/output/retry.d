module agentcore.output.retry;

import std.conv : to;
import std.process : environment;

import agentcore.core.env : envSinkRetryAttempts, envSinkRetryBaseMs, envSinkRetryMaxMs;

/// Bounded retry with capped exponential backoff for HTTP sink delivery. Defaults
/// keep a transient sink blip from dropping events without ever blocking a run for
/// long: 3 attempts total, a 200ms base doubling up to a 5s cap. `maxAttempts` is
/// always at least 1 (one delivery try).
struct RetryPolicy
{
	int maxAttempts = 3;
	int baseDelayMs = 200;
	int maxDelayMs = 5000;
}

/// Backoff before the retry that follows a failed `attempt` (1-based): the base
/// delay doubled once per prior attempt, capped at `maxDelayMs`.
int backoffMs(int attempt, RetryPolicy policy) @safe pure nothrow
{
	const cap = policy.maxDelayMs < 0 ? 0 : policy.maxDelayMs;
	long delay = policy.baseDelayMs < 0 ? 0 : policy.baseDelayMs;
	if (delay == 0 || delay >= cap)
		return cast(int)(delay > cap ? cap : delay);
	foreach (_; 1 .. attempt)
	{
		delay *= 2;
		if (delay >= cap)
			return cap;
	}
	return cast(int) delay;
}

/// Whether another attempt remains after a failed `attempt` (1-based).
bool shouldRetry(int attempt, RetryPolicy policy) @safe pure nothrow
{
	return attempt < policy.maxAttempts;
}

/// Drive `attempt` (true = delivered) up to `policy.maxAttempts` times, sleeping via
/// `sleepMs` for the backoff between tries. Returns true once any attempt succeeds,
/// false when all are exhausted. The POST and the sleep are injected so the loop is
/// pure and testable, and so each caller supplies its own client and sleep.
bool withRetry(RetryPolicy policy, scope bool delegate() nothrow attempt,
	scope void delegate(int ms) nothrow sleepMs) nothrow
{
	const attempts = policy.maxAttempts < 1 ? 1 : policy.maxAttempts;
	foreach (i; 0 .. attempts)
	{
		const n = i + 1;
		if (attempt())
			return true;
		if (!shouldRetry(n, policy))
			break;
		sleepMs(backoffMs(n, policy));
	}
	return false;
}

/// Build a RetryPolicy from the environment, falling back to the defaults for any
/// var that is unset or unparseable. Lets an operator tune retries per deployment.
RetryPolicy retryPolicyFromEnv() nothrow
{
	RetryPolicy policy;
	policy.maxAttempts = envInt(envSinkRetryAttempts, policy.maxAttempts);
	if (policy.maxAttempts < 1)
		policy.maxAttempts = 1;
	policy.baseDelayMs = envInt(envSinkRetryBaseMs, policy.baseDelayMs);
	policy.maxDelayMs = envInt(envSinkRetryMaxMs, policy.maxDelayMs);
	return policy;
}

private int envInt(string name, int fallback) nothrow
{
	try
	{
		const raw = environment.get(name, "");
		return raw.length == 0 ? fallback : raw.to!int;
	}
	catch (Exception)
		return fallback;
}

version (unittest) import fluent.asserts;

@safe unittest
{
	RetryPolicy p; // defaults: 3 attempts, 200ms base, 5s cap
	// Capped exponential backoff, 1-based attempt.
	backoffMs(1, p).should.equal(200);
	backoffMs(2, p).should.equal(400);
	backoffMs(3, p).should.equal(800);
	backoffMs(20, p).should.equal(5000); // capped at maxDelayMs
}

@safe unittest
{
	RetryPolicy p; // 3 attempts total
	shouldRetry(1, p).should.equal(true);
	shouldRetry(2, p).should.equal(true);
	shouldRetry(3, p).should.equal(false); // the last attempt has no retry after it
}

unittest
{
	// Succeeds on the 3rd try: two backoff sleeps recorded, returns delivered.
	RetryPolicy p;
	int calls;
	int[] slept;
	const ok = withRetry(p, () { calls++; return calls == 3; }, (int ms) { slept ~= ms; });
	ok.should.equal(true);
	calls.should.equal(3);
	slept.should.equal([200, 400]);
}

unittest
{
	// Never succeeds: exhausts all attempts, sleeps between each but not after the
	// last, returns false — the event is dropped only after the bounded retries.
	RetryPolicy p;
	int calls;
	int[] slept;
	const ok = withRetry(p, () { calls++; return false; }, (int ms) { slept ~= ms; });
	ok.should.equal(false);
	calls.should.equal(3);
	slept.should.equal([200, 400]); // no sleep after the final failed attempt
}

unittest
{
	// #113: an int.max maxAttempts must not overflow the loop bound into zero tries.
	RetryPolicy huge;
	huge.maxAttempts = int.max;
	int calls;
	const ok = withRetry(huge, () { calls++; return calls == 2; }, (int) {});
	ok.should.equal(true);
	calls.should.equal(2);
}

unittest
{
	// #113: maxAttempts below 1 still makes the one guaranteed delivery try.
	RetryPolicy none;
	none.maxAttempts = 0;
	int calls;
	const ok = withRetry(none, () { calls++; return false; }, (int) {});
	ok.should.equal(false);
	calls.should.equal(1);
}

@safe unittest
{
	// #113: a negative base or cap must never produce a negative backoff.
	RetryPolicy negativeBase;
	negativeBase.baseDelayMs = -200;
	backoffMs(1, negativeBase).should.equal(0);
	backoffMs(4, negativeBase).should.equal(0);

	RetryPolicy negativeCap;
	negativeCap.maxDelayMs = -1;
	backoffMs(3, negativeCap).should.equal(0);
}
