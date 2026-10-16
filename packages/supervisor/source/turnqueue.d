module turnqueue;

import core.time : Duration;

import agentcore.core.env : maxQueuedTurns;

version (unittest) import fluent.asserts;

/// The prompts of a realtime session, run one turn at a time in the order they arrived.
struct TurnQueue
{
	private string[] pending;
	private size_t accepted;
	private size_t started_;
	private bool busy;

	/// Queue `prompt` as the next turn: its turn number, or 0 when the queue is full.
	size_t push(string prompt) @safe pure nothrow
	{
		if (pending.length >= maxQueuedTurns)
			return 0;
		pending ~= prompt;
		return ++accepted;
	}

	/// Whether a queued turn can start: none is running and one is waiting.
	bool ready() const @safe pure nothrow
	{
		return !busy && pending.length > 0;
	}

	/// Start the next queued turn, returning its prompt.
	string start() @safe pure nothrow
	in (ready)
	{
		const prompt = pending[0];
		pending = pending[1 .. $];
		busy = true;
		++started_;
		return prompt;
	}

	/// End the running turn.
	void finish() @safe pure nothrow
	{
		busy = false;
	}

	/// The number of the turn last started.
	size_t started() const @safe pure nothrow
	{
		return started_;
	}

	bool running() const @safe pure nothrow
	{
		return busy;
	}

	size_t queued() const @safe pure nothrow
	{
		return pending.length;
	}

	/// No turn is running or waiting.
	bool drained() const @safe pure nothrow
	{
		return !busy && pending.length == 0;
	}
}

/// Whether a session with no turn running or waiting has been quiet for its whole `idle` window.
bool idleExpired(bool drained, Duration quiet, Duration idle) @safe pure nothrow
{
	return drained && quiet >= idle;
}

@safe unittest // prompts start one at a time, in arrival order, numbered from 1
{
	TurnQueue queue;
	const numbers = [queue.push("a"), queue.push("b")];
	const first = queue.start();
	const readyWhileBusy = queue.ready;
	queue.finish();
	const second = queue.start();

	[numbers[0], numbers[1], queue.started].should.equal([1, 2, 2]);
	[first, second].should.equal(["a", "b"]);
	readyWhileBusy.should.equal(false);
}

@safe unittest // a full queue refuses the next prompt with turn number 0
{
	TurnQueue queue;
	foreach (i; 0 .. maxQueuedTurns)
		queue.push("p");

	[queue.push("one too many"), queue.queued].should.equal([0, maxQueuedTurns]);
}

@safe unittest // a queue is drained only with no turn running or waiting
{
	TurnQueue queue;
	const empty = queue.drained;
	queue.push("a");
	const waiting = queue.drained;
	queue.start();
	const running = queue.drained;
	queue.finish();

	[empty, waiting, running, queue.drained].should.equal([true, false, false, true]);
}

@safe unittest // an idle session expires once quiet for its window, a busy one never does
{
	import core.time : minutes;

	[idleExpired(true, 15.minutes, 15.minutes), idleExpired(true, 14.minutes, 15.minutes),
		idleExpired(false, 60.minutes, 15.minutes)].should.equal([true, false, false]);
}
