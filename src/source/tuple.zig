const std = @import("std");
const tree = @import("tree.zig");

const AxisTuple = tree.AxisTuple;
const Pair = tree.AxisTuple.Pair;

pub const ParseError = error{
    InvalidAxisName,
    InvalidAxisValue,
    MalformedTuple,
    OutOfMemory,
};

/// Parse an axis tuple from a filename, e.g. `os=darwin+profile=work.lua` or
/// `os=darwin` (no extension). Returns the extension-stripped tuple.
///
/// Filename grammar: `<axis>=<value>(+<axis>=<value>)*[.<ext>]`
/// where `<axis>` matches `[a-z][a-z0-9_]*` and `<value>` matches
/// `[A-Za-z0-9_.+-]+`. Extension is detected as the segment after the LAST
/// `.` provided that segment contains no `+` or `=`.
pub fn parseFilename(arena: std.mem.Allocator, filename: []const u8) ParseError!AxisTuple {
    return parseStem(arena, stripExtension(filename));
}

/// Parse an axis tuple from a filename WITHOUT stripping a trailing
/// extension: the filename is the stem verbatim. A value may itself contain a
/// dot (a `machine` value is a hostname, and every macOS hostname ends in
/// `.local`), so this is the reading that stands for what was actually
/// written whenever `parseFilename`'s extension heuristic strips a real
/// dotted value instead of a real extension.
pub fn parseFilenameVerbatim(arena: std.mem.Allocator, filename: []const u8) ParseError!AxisTuple {
    return parseStem(arena, filename);
}

fn parseStem(arena: std.mem.Allocator, stem: []const u8) ParseError!AxisTuple {
    if (stem.len == 0) return error.MalformedTuple;

    var pairs: std.ArrayList(Pair) = .empty;
    errdefer pairs.deinit(arena);

    var iter = std.mem.splitScalar(u8, stem, '+');
    while (iter.next()) |part| {
        const eq_idx = std.mem.indexOfScalar(u8, part, '=') orelse return error.MalformedTuple;
        const name = part[0..eq_idx];
        const value = part[eq_idx + 1 ..];
        if (!isValidAxisName(name)) return error.InvalidAxisName;
        if (!isValidAxisValue(value)) return error.InvalidAxisValue;
        try pairs.append(arena, .{
            .name = try arena.dupe(u8, name),
            .value = try arena.dupe(u8, value),
        });
    }

    const slice = try pairs.toOwnedSlice(arena);
    std.mem.sort(Pair, slice, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    return .{ .pairs = slice };
}

/// The part of `filename` before a trailing extension, or `filename`
/// unchanged when the last dot-suffix isn't one (see `parseFilename`).
pub fn stripExtension(filename: []const u8) []const u8 {
    const last_dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return filename;
    const ext_part = filename[last_dot + 1 ..];
    if (ext_part.len == 0) return filename;
    if (std.mem.indexOfAny(u8, ext_part, "+=") != null) return filename;
    // Treat purely-digit suffixes as part of the value (e.g. version numbers
    // like `tool=fdfind-2.0`), not as a file extension.
    for (ext_part) |c| {
        if (!std.ascii.isDigit(c)) return filename[0..last_dot];
    }
    return filename;
}

fn isValidAxisName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isLower(name[0])) return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    }
    return true;
}

fn isValidAxisValue(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '+' or c == '-')) return false;
    }
    return true;
}

test "parseFilename: single axis" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const t = try parseFilename(fba.allocator(), "os=darwin.lua");
    try std.testing.expectEqual(@as(usize, 1), t.pairs.len);
    try std.testing.expectEqualStrings("os", t.pairs[0].name);
    try std.testing.expectEqualStrings("darwin", t.pairs[0].value);
}

test "parseFilename: combined axes sorted" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const t = try parseFilename(fba.allocator(), "profile=work+os=darwin.lua");
    try std.testing.expectEqualStrings("os", t.pairs[0].name);
    try std.testing.expectEqualStrings("profile", t.pairs[1].name);
}

test "parseFilename: no extension" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const t = try parseFilename(fba.allocator(), "os=darwin");
    try std.testing.expectEqualStrings("darwin", t.pairs[0].value);
}

test "parseFilename: uppercase axis name rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseFilename(fba.allocator(), "OS=darwin.lua");
    try std.testing.expectError(error.InvalidAxisName, result);
}

test "parseFilename: empty value rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseFilename(fba.allocator(), "os=.lua");
    try std.testing.expectError(error.InvalidAxisValue, result);
}

test "parseFilename: missing equals rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseFilename(fba.allocator(), "darwin.lua");
    try std.testing.expectError(error.MalformedTuple, result);
}

test "parseFilename: value with dots and dashes" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const t = try parseFilename(fba.allocator(), "tool=fdfind-2.0");
    try std.testing.expectEqualStrings("fdfind-2.0", t.pairs[0].value);
}

test "parseFilenameVerbatim: keeps a dotted value parseFilename would strip" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const stripped = try parseFilename(fba.allocator(), "machine=host.local");
    try std.testing.expectEqualStrings("host", stripped.pairs[0].value);
    const verbatim = try parseFilenameVerbatim(fba.allocator(), "machine=host.local");
    try std.testing.expectEqualStrings("host.local", verbatim.pairs[0].value);
}
