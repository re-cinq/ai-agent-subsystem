/// Five-field cron schedules, evaluated in UTC: minute, hour, day of month, month and day
/// of week. A field is `*`, a number, a range `a-b`, any of those with a step `/n`, or a
/// comma-separated list of them. Day of week counts Sunday as 0 or 7. When both day of
/// month and day of week are restricted (neither starts with `*`), a day matching either
/// one fires, as in Vixie cron.
module agentcore.spawner.cron;

import std.algorithm.iteration : filter, splitter;
import std.algorithm.searching : all, find, findSplit, startsWith;
import std.array : array, split;
import std.ascii : isDigit;
import std.conv : to;
import std.datetime : Date, DateTime, SysTime, TimeOfDay, UTC, days;
import std.exception : enforce;
import std.format : format;
import std.range : empty, iota, retro;

/// The values each field of a cron expression allows.
struct CronSchedule
{
	bool[60] minutes;
	bool[24] hours;
	bool[32] daysOfMonth; /// indexed by day, 1 to 31
	bool[13] months; /// indexed by month, 1 to 12
	bool[7] daysOfWeek; /// indexed by day, Sunday = 0
	bool dayOfMonthRestricted;
	bool dayOfWeekRestricted;
}

/// Parse a five-field cron expression; throws naming the field and value it rejects.
CronSchedule parseCron(string expression)
{
	const fields = expression.split;
	enforce(fields.length == 5, format!`cron "%s": want 5 fields (minute hour day-of-month month day-of-week), got %s`(
			expression, fields.length));

	CronSchedule cron;
	cron.minutes = parseField(fields[0], "minute", 0, 59);
	cron.hours = parseField(fields[1], "hour", 0, 23);
	cron.daysOfMonth = parseField(fields[2], "day-of-month", 1, 31);
	cron.months = parseField(fields[3], "month", 1, 12);
	const weekdays = parseField(fields[4], "day-of-week", 0, 7);
	cron.daysOfWeek = weekdays[0 .. 7];
	cron.daysOfWeek[0] = weekdays[0] || weekdays[7];
	cron.dayOfMonthRestricted = !fields[2].startsWith("*");
	cron.dayOfWeekRestricted = !fields[4].startsWith("*");
	return cron;
}

/// The first fire time strictly after `after`.
SysTime cronNextFire(const CronSchedule cron, SysTime after)
{
	const start = minuteOf(after) + 1;
	auto day = dayOf(start);
	auto fromMinute = cast(int)(start % minutesPerDay);
	auto firing = firingMinutes(cron);
	foreach (_; 0 .. searchDays)
	{
		auto later = firing.find!(minute => minute >= fromMinute);
		if (dayMatches(cron, day) && !later.empty)
			return at(day, later[0]);
		day += 1.days;
		fromMinute = 0;
	}
	throw new Exception(neverFires);
}

/// The last fire time at or before `atOrBefore`.
SysTime cronPreviousFire(const CronSchedule cron, SysTime atOrBefore)
{
	const end = minuteOf(atOrBefore);
	auto day = dayOf(end);
	auto untilMinute = cast(int)(end % minutesPerDay);
	auto firing = firingMinutes(cron);
	foreach (_; 0 .. searchDays)
	{
		auto earlier = firing.retro.find!(minute => minute <= untilMinute);
		if (dayMatches(cron, day) && !earlier.empty)
			return at(day, earlier.front);
		day -= 1.days;
		untilMinute = minutesPerDay - 1;
	}
	throw new Exception(neverFires);
}

private enum minutesPerDay = 24 * 60;

/// Days searched for a fire time: Feb 29 can be eight years from the last one.
private enum searchDays = 366 * 9;

private enum neverFires = "cron schedule never fires";

private bool[] parseField(string field, string name, int min, int max)
{
	auto allowed = new bool[max + 1];
	foreach (part; field.splitter(','))
		foreach (value; partValues(part, name, min, max))
			allowed[value] = true;
	return allowed;
}

/// The values one list element (`*`, `n`, `a-b`, optionally `/step`) allows.
private int[] partValues(string part, string name, int min, int max)
{
	const stepped = part.findSplit("/");
	const hasStep = stepped[1].length > 0;
	const step = hasStep ? cronNumber(stepped[2], name, part) : 1;
	enforce(step > 0, format!`cron %s "%s": step must be positive`(name, part));

	auto first = min;
	auto last = max;
	if (stepped[0] != "*")
	{
		const range = stepped[0].findSplit("-");
		first = cronNumber(range[0], name, part);
		last = range[1].length ? cronNumber(range[2], name, part) : hasStep ? max : first;
	}
	enforce(min <= first && first <= last && last <= max,
		format!`cron %s "%s": outside %s-%s`(name, part, min, max));
	return iota(first, last + 1, step).array;
}

private int cronNumber(string text, string name, string part)
{
	enforce(text.length && text.all!isDigit, format!`cron %s "%s": "%s" is not a number`(name, part, text));
	return text.to!int;
}

private bool dayMatches(const CronSchedule cron, Date day)
{
	if (!cron.months[day.month])
		return false;
	const byDayOfMonth = cron.daysOfMonth[day.day];
	const byDayOfWeek = cron.daysOfWeek[day.dayOfWeek];
	return cron.dayOfMonthRestricted && cron.dayOfWeekRestricted
		? byDayOfMonth || byDayOfWeek : byDayOfMonth && byDayOfWeek;
}

/// Every minute of a day the schedule fires at, ascending.
private int[] firingMinutes(const CronSchedule cron)
{
	return iota(0, minutesPerDay)
		.filter!(minute => cron.hours[minute / 60] && cron.minutes[minute % 60])
		.array;
}

/// Minutes since the Unix epoch, rounded down.
private long minuteOf(SysTime time)
{
	return time.toUnixTime / 60;
}

private Date dayOf(long epochMinute)
{
	return cast(Date) SysTime.fromUnixTime(epochMinute * 60, UTC());
}

private SysTime at(Date day, int minuteOfDay)
{
	return SysTime(DateTime(day, TimeOfDay(minuteOfDay / 60, minuteOfDay % 60)), UTC());
}

version (unittest)
{
	import fluent.asserts;

	private SysTime utc(string iso)
	{
		return SysTime.fromISOExtString(iso, UTC());
	}

	private string next(string expression, string after)
	{
		return cronNextFire(parseCron(expression), utc(after)).toISOExtString;
	}

	private string previous(string expression, string atOrBefore)
	{
		return cronPreviousFire(parseCron(expression), utc(atOrBefore)).toISOExtString;
	}
}

unittest // every minute fires at the next whole minute, never at the instant itself
{
	[next("* * * * *", "2026-10-17T10:00:30Z"), next("* * * * *", "2026-10-17T10:00:00Z")]
		.should.equal(["2026-10-17T10:01:00Z", "2026-10-17T10:01:00Z"]);
}

unittest // */5 after 10:07 fires at 10:10, and 5/15 means 5-59/15
{
	[next("*/5 * * * *", "2026-10-17T10:07:00Z"), next("5/15 * * * *", "2026-10-17T10:21:00Z")]
		.should.equal(["2026-10-17T10:10:00Z", "2026-10-17T10:35:00Z"]);
}

unittest // 0 3 * * * after 03:00 fires at 03:00 the next day, rolling over a month end
{
	next("0 3 * * *", "2026-10-31T03:00:00Z").should.equal("2026-11-01T03:00:00Z");
}

unittest // a list with a stepped range, 0,30 9-17/4 * * *, fires at 09:00, 09:30, 13:00, 13:30, 17:00, 17:30
{
	string[] fires;
	auto after = utc("2026-10-17T00:00:00Z");
	foreach (_; 0 .. 7)
	{
		after = cronNextFire(parseCron("0,30 9-17/4 * * *"), after);
		fires ~= after.toISOExtString;
	}
	fires.should.equal(["2026-10-17T09:00:00Z", "2026-10-17T09:30:00Z", "2026-10-17T13:00:00Z",
		"2026-10-17T13:30:00Z", "2026-10-17T17:00:00Z", "2026-10-17T17:30:00Z", "2026-10-18T09:00:00Z"]);
}

unittest // day of week 7 is Sunday like 0: 2026-10-17 is a Saturday, so the next fire is Sunday the 18th
{
	[next("0 0 * * 7", "2026-10-17T12:00:00Z"), next("0 0 * * 0", "2026-10-17T12:00:00Z")]
		.should.equal(["2026-10-18T00:00:00Z", "2026-10-18T00:00:00Z"]);
}

unittest // day of month 1 and Monday both restricted fire on either: after Sat Oct 17, Mon Oct 19 comes before Nov 1
{
	next("0 0 1 * 1", "2026-10-17T00:00:00Z").should.equal("2026-10-19T00:00:00Z");
}

unittest // day of month restricted with day of week * fires on that day of month only
{
	next("0 0 1 * *", "2026-10-17T00:00:00Z").should.equal("2026-11-01T00:00:00Z");
}

unittest // Feb 29 after 2026 next fires in 2028
{
	next("0 0 29 2 *", "2026-03-01T00:00:00Z").should.equal("2028-02-29T00:00:00Z");
}

unittest // previous fire includes the instant itself and goes back across a day
{
	[previous("*/5 * * * *", "2026-10-17T10:05:00Z"), previous("*/5 * * * *", "2026-10-17T10:09:59Z"),
		previous("30 23 * * *", "2026-10-17T10:00:00Z")]
		.should.equal(["2026-10-17T10:05:00Z", "2026-10-17T10:05:00Z", "2026-10-16T23:30:00Z"]);
}

unittest // a schedule that never fires, Feb 30, throws
{
	next("0 0 30 2 *", "2026-01-01T00:00:00Z").should.throwException!Exception.withMessage(
		"cron schedule never fires");
}

unittest // four fields is rejected with the expected field list
{
	parseCron("* * * *").should.throwException!Exception.withMessage(
		`cron "* * * *": want 5 fields (minute hour day-of-month month day-of-week), got 4`);
}

unittest // minute 60, hour 5-2, step 0 and a name each throw naming the field and value
{
	parseCron("60 * * * *").should.throwException!Exception.withMessage(`cron minute "60": outside 0-59`);
	parseCron("* 5-2 * * *").should.throwException!Exception.withMessage(`cron hour "5-2": outside 0-23`);
	parseCron("*/0 * * * *").should.throwException!Exception.withMessage(`cron minute "*/0": step must be positive`);
	parseCron("* * * jan *").should.throwException!Exception.withMessage(
		`cron month "jan": "jan" is not a number`);
	parseCron("* * 0 * *").should.throwException!Exception.withMessage(`cron day-of-month "0": outside 1-31`);
}
