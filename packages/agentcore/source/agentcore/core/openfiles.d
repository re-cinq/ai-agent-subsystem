module agentcore.core.openfiles;

import core.stdc.errno : errno;
import core.sys.posix.sys.resource : getrlimit, RLIMIT_NOFILE, rlimit, setrlimit;
import std.conv : to;

import agentcore.core.log : logError;

version (unittest) import fluent.asserts;

/// The soft open-file limit a run process lowers itself to when the runtime hands it more.
/// 1048576 is Docker's default, what every run pod had until containerd 2.x began
/// handing out 2147483584; it is plenty for an agent CLI, which inherits it.
enum ulong openFileCap = 1_048_576;

/// The soft limit to set given the current `soft` and `hard` limits: unchanged at or
/// below `cap`, `cap` above it, and never above `hard`.
ulong cappedSoftLimit(ulong soft, ulong hard, ulong cap = openFileCap) @safe pure nothrow @nogc
{
	import std.algorithm.comparison : min;

	return min(soft, cap, hard);
}

/// Lower this process's soft `RLIMIT_NOFILE` to `openFileCap` when it is higher, before
/// anything is spawned: `std.process` sizes a per-descriptor buffer from the limit in every
/// forked child, so a runtime that hands pods an effectively unlimited limit (containerd 2.x
/// gives 2147483584) gets each child OOM-killed. Never raises a limit; a failure to read or
/// set it is logged, not fatal.
void capOpenFileLimit() nothrow
{
	try
	{
		rlimit limit;
		if (getrlimit(RLIMIT_NOFILE, &limit) != 0)
			return logError("[openfiles] getrlimit failed, errno " ~ errno.to!string);

		const target = cappedSoftLimit(limit.rlim_cur, limit.rlim_max);
		if (target == limit.rlim_cur)
			return;

		limit.rlim_cur = target;
		if (setrlimit(RLIMIT_NOFILE, &limit) != 0)
			logError("[openfiles] setrlimit failed, errno " ~ errno.to!string);
	}
	catch (Exception e)
		logError("[openfiles] " ~ e.msg);
}

unittest // a soft limit below the cap stays as it is
{
	cappedSoftLimit(1024, 4096, 1_048_576).should.equal(1024);
}

unittest // a soft limit equal to the cap stays as it is
{
	cappedSoftLimit(1_048_576, 1_048_576, 1_048_576).should.equal(1_048_576);
}

unittest // a soft limit above the cap drops to the cap
{
	cappedSoftLimit(2_147_483_584, 2_147_483_584, 1_048_576).should.equal(1_048_576);
}

unittest // an unlimited soft limit drops to the cap
{
	cappedSoftLimit(ulong.max, ulong.max, 1_048_576).should.equal(1_048_576);
}

unittest // a hard limit below the cap is never exceeded
{
	cappedSoftLimit(ulong.max, 4096, 1_048_576).should.equal(4096);
}

unittest // the default cap is Docker's 1048576
{
	cappedSoftLimit(ulong.max, ulong.max).should.equal(1_048_576);
}

unittest // capping the limit of this process leaves it at or below the cap
{
	capOpenFileLimit();

	rlimit limit;
	getrlimit(RLIMIT_NOFILE, &limit).should.equal(0);
	(limit.rlim_cur <= openFileCap).should.equal(true);
}
