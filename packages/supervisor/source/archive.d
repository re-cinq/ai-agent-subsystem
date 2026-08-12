module archive;

// A tar.gz writer, in-process.
//
// The supervisor is staged into an emptyDir and exec'd by the Station's OWN base
// image (see scripts/container/Dockerfile.agent), so it may only depend on what
// every supported base guarantees: glibc and libssl. `tar` is NOT such a thing —
// amazonlinux:2023, a supported Station base, ships no tar at all — so shelling out
// to it meant conversation state silently failed to save there while the run still
// reported success. zlib is already linked (vibe-d pulls it in), so writing the
// archive here costs no new dependency and no new binary in the bundle.
//
// The format stays byte-compatible ustar + gzip: the restore half extracts with a
// real `tar -xz` in the init image, and any archive already stored server-side has
// to keep working.

import std.algorithm.sorting : sort;
import std.array : appender;
import std.conv : octal, to;
import std.exception : enforce;
import std.file : dirEntries, getAttributes, read, SpanMode, timeLastModified;
import std.path : buildPath, relativePath;
import std.string : rightJustify;
import std.zlib : Compress, HeaderFormat;

version (unittest) import fluent.asserts;

/// One member of the archive, named RELATIVE to the archive root — exactly the path
/// a `tar -xz -C <root>` on the other side recreates.
struct ArchiveMember
{
	string path; /// relative, never leading-slash
	ubyte[] content; /// empty for a directory
	bool isDirectory;
	uint mode = octal!644;
	long modified; /// seconds since the epoch
}

/// tar's fixed block: every header is one, every file body is padded up to one.
private enum blockSize = 512;

/// GNU tar's default record size. The stream is padded to it so the output is
/// byte-conventional; the padding is zeros, which gzip charges nothing for.
private enum recordSize = 20 * blockSize;

private enum nameFieldSize = 100;
private enum prefixFieldSize = 155;
private enum checksumFieldSize = 8;
private enum nameOffset = 0;
private enum modeOffset = 100;
private enum uidOffset = 108;
private enum gidOffset = 116;
private enum sizeOffset = 124;
private enum modifiedOffset = 136;
private enum checksumOffset = 148;
private enum typeOffset = 156;
private enum magicOffset = 257;
private enum versionOffset = 263;
private enum prefixOffset = 345;

/// Walk `root/dir` into members named relative to `root`, so the archive restores to
/// where it came from. Sorted, so the same tree always produces the same archive.
/// Only directories and regular files are taken: a conversation state tree is
/// transcripts and the directories holding them, and archiving a symlink or a socket
/// would promise a restore that cannot happen.
ArchiveMember[] collect(string root, string dir)
{
	auto members = appender!(ArchiveMember[]);
	members ~= memberOf(buildPath(root, dir), dir, true);

	foreach (entry; dirEntries(buildPath(root, dir), SpanMode.breadth, false))
	{
		if (!entry.isDir && !entry.isFile)
			continue;
		members ~= memberOf(entry.name, relativePath(entry.name, root), entry.isDir);
	}

	auto collected = members.data;
	collected.sort!((a, b) => a.path < b.path);
	return collected;
}

/// The gzipped tar stream for `members`, in the order given.
ubyte[] tarGz(const ArchiveMember[] members)
{
	return gzip(tar(members));
}

private ArchiveMember memberOf(string path, string name, bool isDirectory)
{
	ArchiveMember member = {
		path: name,
		isDirectory: isDirectory,
		mode: getAttributes(path) & octal!777,
		modified: timeLastModified(path).toUnixTime,
	};
	if (!isDirectory)
		member.content = cast(ubyte[]) read(path);
	return member;
}

private ubyte[] tar(const ArchiveMember[] members)
{
	auto archive = appender!(ubyte[]);
	foreach (member; members)
	{
		archive ~= header(member)[];
		if (member.isDirectory)
			continue;
		archive ~= member.content;
		archive ~= padding(member.content.length, blockSize);
	}

	// Two zero blocks end the stream; the record padding follows so the archive is a
	// whole number of GNU tar records.
	archive ~= new ubyte[2 * blockSize];
	archive ~= padding(archive.data.length, recordSize);
	return archive.data;
}

private ubyte[] gzip(const(ubyte)[] data)
{
	auto compressor = new Compress(HeaderFormat.gzip);
	auto compressed = appender!(ubyte[]);
	compressed ~= cast(ubyte[]) compressor.compress(data);
	compressed ~= cast(ubyte[]) compressor.flush();
	return compressed.data;
}

private ubyte[] padding(size_t length, size_t boundary)
{
	const remainder = length % boundary;
	return remainder == 0 ? null : new ubyte[boundary - remainder];
}

private ubyte[blockSize] header(in ArchiveMember member)
{
	ubyte[blockSize] block = 0;

	writeName(block, member.isDirectory ? member.path ~ "/" : member.path);
	writeField(block, modeOffset, octalField(member.mode, 8));
	writeField(block, uidOffset, octalField(0, 8));
	writeField(block, gidOffset, octalField(0, 8));
	writeField(block, sizeOffset, octalField(member.isDirectory ? 0 : member.content.length, 12));
	writeField(block, modifiedOffset, octalField(member.modified, 12));
	block[typeOffset] = member.isDirectory ? '5' : '0';
	writeField(block, magicOffset, "ustar"); // the zero fill supplies the trailing NUL
	writeField(block, versionOffset, "00");

	// The checksum covers the header including its own field, which is read as eight
	// spaces while it is computed — hence the fill, then the overwrite. It is stored
	// as six octal digits, a NUL and a space: that odd terminator pair is what tar
	// readers expect.
	block[checksumOffset .. checksumOffset + checksumFieldSize] = ' ';
	writeField(block, checksumOffset, octalField(checksum(block), 7));
	block[checksumOffset + 6] = 0;
	block[checksumOffset + 7] = ' ';
	return block;
}

/// ustar splits a path longer than 100 bytes at a '/' into a 155-byte prefix and the
/// 100-byte name, rejoined on extraction. A path with no separator in the splittable
/// range has no representation in the format at all — saying so beats writing a
/// truncated name that a reader would happily extract to the wrong place.
private void writeName(ref ubyte[blockSize] block, string path)
{
	if (path.length <= nameFieldSize)
	{
		writeField(block, nameOffset, path);
		return;
	}

	size_t split = 0;
	foreach (i, c; path)
		if (c == '/' && i <= prefixFieldSize && path.length - i - 1 <= nameFieldSize)
		{
			split = i;
			break;
		}

	enforce(split > 0, "path too long for the ustar format: " ~ path);
	writeField(block, prefixOffset, path[0 .. split]);
	writeField(block, nameOffset, path[split + 1 .. $]);
}

private void writeField(ref ubyte[blockSize] block, size_t offset, const(char)[] text)
{
	block[offset .. offset + text.length] = cast(const(ubyte)[]) text;
}

/// tar stores a number as zero-padded octal digits filling the field, leaving its
/// last byte for the terminator readers expect.
private string octalField(ulong value, size_t fieldSize)
{
	return rightJustify(to!string(value, 8), fieldSize - 1, '0');
}

private uint checksum(in ubyte[blockSize] block)
{
	uint sum = 0;
	foreach (b; block)
		sum += b;
	return sum;
}

version (unittest)
{
	import std.zlib : UnCompress;

	/// The reader half, for these tests only: gunzip, then walk the blocks back into
	/// members, verifying every header checksum. A writer checked only against
	/// itself proves little, so the itest additionally runs the REAL GNU tar over the
	/// posted archive on every distro that has one.
	private ArchiveMember[] untarGz(const(ubyte)[] archive)
	{
		auto decompressor = new UnCompress(HeaderFormat.gzip);
		auto stream = cast(ubyte[]) decompressor.uncompress(archive);
		stream ~= cast(ubyte[]) decompressor.flush();

		ArchiveMember[] members;
		for (size_t at = 0; at + blockSize <= stream.length; at += blockSize)
		{
			ubyte[blockSize] block;
			block[] = stream[at .. at + blockSize];
			if (block[nameOffset] == 0)
				break;

			ubyte[blockSize] stated = block;
			stated[checksumOffset .. checksumOffset + checksumFieldSize] = ' ';
			checksum(stated).should.equal(
				fieldOctal(block[checksumOffset .. checksumOffset + checksumFieldSize]));

			const size = cast(size_t) fieldOctal(block[sizeOffset .. sizeOffset + 12]);
			ArchiveMember member = {
				path: fieldPath(block),
				isDirectory: block[typeOffset] == '5',
				mode: cast(uint) fieldOctal(block[modeOffset .. modeOffset + 8]),
				modified: cast(long) fieldOctal(block[modifiedOffset .. modifiedOffset + 12]),
			};
			if (!member.isDirectory)
			{
				member.content = stream[at + blockSize .. at + blockSize + size].dup;
				at += blockSize * ((size + blockSize - 1) / blockSize);
			}
			members ~= member;
		}
		return members;
	}

	private string fieldPath(in ubyte[blockSize] block)
	{
		const name = fieldText(block[nameOffset .. nameOffset + nameFieldSize]);
		const prefix = fieldText(block[prefixOffset .. prefixOffset + prefixFieldSize]);
		return prefix.length ? prefix ~ "/" ~ name : name;
	}

	private string fieldText(in ubyte[] field)
	{
		string text;
		foreach (b; field)
		{
			if (b == 0)
				break;
			text ~= cast(char) b;
		}
		return text;
	}

	private ulong fieldOctal(in ubyte[] field)
	{
		ulong value = 0;
		foreach (b; field)
		{
			if (b < '0' || b > '7')
				break;
			value = value * 8 + (b - '0');
		}
		return value;
	}
}

unittest
{
	// a directory and a file round-trip with bytes, mode and mtime intact; the
	// directory carries tar's trailing slash and no content
	auto file = ArchiveMember(".claude/projects/conv.jsonl",
		cast(ubyte[]) `{"turn":"one"}`.dup, false, octal!644, 1_770_000_001);
	auto restored = untarGz(tarGz(
			[ArchiveMember(".claude/projects", null, true, octal!755, 1_770_000_000), file]));

	restored.length.should.equal(2);
	restored[0].should.equal(
		ArchiveMember(".claude/projects/", null, true, octal!755, 1_770_000_000));
	restored[1].should.equal(file);
}

unittest
{
	// the archive is gzip on the wire, and its tar stream is whole GNU tar records
	const archive = tarGz([ArchiveMember("a.jsonl", cast(ubyte[]) "x".dup)]);
	archive[0 .. 2].should.equal([0x1f, 0x8b]);

	auto decompressor = new UnCompress(HeaderFormat.gzip);
	auto stream = cast(ubyte[]) decompressor.uncompress(archive);
	stream ~= cast(ubyte[]) decompressor.flush();
	(stream.length % recordSize).should.equal(0);
}

unittest
{
	// a file whose bytes are not a whole block still round-trips: the body is padded
	// to the block boundary, and the reader takes the size from the header
	auto odd = ArchiveMember("a.jsonl", cast(ubyte[]) "0123456789".dup);
	untarGz(tarGz([odd]))[0].should.equal(odd);
}

unittest
{
	// a path too long for name+prefix is refused, never silently truncated
	string deep;
	foreach (component; 0 .. 40)
		deep ~= "0123456789";
	({ tarGz([ArchiveMember(deep, null)]); }).should.throwException!Exception
		.withMessage.equal("path too long for the ustar format: " ~ deep);
}
