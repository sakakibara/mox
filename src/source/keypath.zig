//! TOML dotted-key grammar for partial-ownership declarations.
//!
//! An `own` entry in `.mox/attributes.toml` names a key subtree with TOML's
//! dotted-key syntax, verbatim: bare segments (`A-Za-z0-9_-`), basic
//! (`"..."`) and literal (`'...'`) quoted segments, whitespace allowed
//! around the dots (`projects."/tmp/example"`, `remote."my origin".url`).
//! Segments are decoded -- quotes stripped, escapes resolved -- so consumers
//! match on key content, never on spelling.

const std = @import("std");

pub const Error = error{
    EmptyPath,
    EmptySegment,
    UnterminatedQuote,
    InvalidEscape,
    InvalidCharacter,
    OutOfMemory,
};

/// Split `path` into decoded key segments. All returned slices are either
/// views into `path` or arena-owned (escaped segments); the arena must
/// outlive the result if `path` does.
pub fn parse(arena: std.mem.Allocator, path: []const u8) Error![]const []const u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    skipWs(path, &i);
    if (i >= path.len) return error.EmptyPath;
    while (true) {
        const seg = switch (path[i]) {
            '"' => try parseBasic(arena, path, &i),
            '\'' => try parseLiteral(path, &i),
            else => try parseBare(path, &i),
        };
        try segs.append(arena, seg);
        skipWs(path, &i);
        if (i >= path.len) break;
        if (path[i] != '.') return error.InvalidCharacter;
        i += 1;
        skipWs(path, &i);
        if (i >= path.len) return error.EmptySegment;
    }
    return segs.toOwnedSlice(arena);
}

/// TOML dot-sep allows surrounding whitespace: `a . b` names `a.b`.
fn skipWs(path: []const u8, i: *usize) void {
    while (i.* < path.len and (path[i.*] == ' ' or path[i.*] == '\t')) i.* += 1;
}

fn isBareChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn parseBare(path: []const u8, i: *usize) Error![]const u8 {
    const start = i.*;
    while (i.* < path.len and isBareChar(path[i.*])) i.* += 1;
    if (i.* == start) {
        // A dot where a segment should be is a missing segment (`a..b`,
        // `.a`); anything else is a character bare keys cannot hold.
        return if (path[start] == '.') error.EmptySegment else error.InvalidCharacter;
    }
    return path[start..i.*];
}

/// Basic (double-quoted) segment with TOML's escape set. Control characters
/// other than tab must arrive escaped, exactly as TOML basic strings demand.
fn parseBasic(arena: std.mem.Allocator, path: []const u8, i: *usize) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    i.* += 1;
    while (true) {
        if (i.* >= path.len) return error.UnterminatedQuote;
        const c = path[i.*];
        if (c == '"') {
            i.* += 1;
            return out.toOwnedSlice(arena);
        }
        if (c == '\\') {
            i.* += 1;
            if (i.* >= path.len) return error.UnterminatedQuote;
            const esc = path[i.*];
            i.* += 1;
            switch (esc) {
                'b' => try out.append(arena, 0x08),
                't' => try out.append(arena, '\t'),
                'n' => try out.append(arena, '\n'),
                'f' => try out.append(arena, 0x0c),
                'r' => try out.append(arena, '\r'),
                '"' => try out.append(arena, '"'),
                '\\' => try out.append(arena, '\\'),
                'u' => try appendUnicode(arena, &out, path, i, 4),
                'U' => try appendUnicode(arena, &out, path, i, 8),
                else => return error.InvalidEscape,
            }
            continue;
        }
        if ((c < 0x20 and c != '\t') or c == 0x7f) return error.InvalidCharacter;
        try out.append(arena, c);
        i.* += 1;
    }
}

/// Literal (single-quoted) segment: no escapes, so the slice is a direct view.
fn parseLiteral(path: []const u8, i: *usize) Error![]const u8 {
    i.* += 1;
    const start = i.*;
    while (i.* < path.len) : (i.* += 1) {
        const c = path[i.*];
        if (c == '\'') {
            const seg = path[start..i.*];
            i.* += 1;
            return seg;
        }
        if ((c < 0x20 and c != '\t') or c == 0x7f) return error.InvalidCharacter;
    }
    return error.UnterminatedQuote;
}

/// Decode `\uXXXX` / `\UXXXXXXXX` (n hex digits at `i`) into UTF-8.
fn appendUnicode(arena: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, i: *usize, n: usize) Error!void {
    if (i.* + n > path.len) return error.InvalidEscape;
    const cp = std.fmt.parseInt(u21, path[i.* .. i.* + n], 16) catch return error.InvalidEscape;
    if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return error.InvalidEscape;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidEscape;
    try out.appendSlice(arena, buf[0..len]);
    i.* += n;
}

const testing = std.testing;

fn expectSegments(path: []const u8, expected: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const segs = try parse(arena.allocator(), path);
    try testing.expectEqual(expected.len, segs.len);
    for (expected, segs) |e, s| try testing.expectEqualStrings(e, s);
}

fn expectFailure(path: []const u8, expected: Error) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(expected, parse(arena.allocator(), path));
}

test "parse: bare dotted path" {
    try expectSegments("tui.keymap.global", &.{ "tui", "keymap", "global" });
    try expectSegments("model", &.{"model"});
    try expectSegments("a-b_c.d2", &.{ "a-b_c", "d2" });
}

test "parse: quoted segment carrying dots and slashes" {
    try expectSegments("projects.\"/tmp/example\"", &.{ "projects", "/tmp/example" });
    try expectSegments("\"a.b\".c", &.{ "a.b", "c" });
}

test "parse: quoted segment carrying spaces" {
    try expectSegments("remote.\"my origin\".url", &.{ "remote", "my origin", "url" });
}

test "parse: literal (single-quoted) segments" {
    try expectSegments("'single'", &.{"single"});
    try expectSegments("a.'b c'.d", &.{ "a", "b c", "d" });
    // Literal segments take backslashes verbatim, TOML literal-string style.
    try expectSegments("'no\\escape'", &.{"no\\escape"});
}

test "parse: whitespace around dots is dot-sep whitespace" {
    try expectSegments("a . b", &.{ "a", "b" });
    try expectSegments("  a.\t\"b\" ", &.{ "a", "b" });
}

test "parse: basic-string escapes decode" {
    try expectSegments("\"a\\\"b\"", &.{"a\"b"});
    try expectSegments("\"back\\\\slash\"", &.{"back\\slash"});
    try expectSegments("\"tab\\there\"", &.{"tab\there"});
    try expectSegments("\"\\u0041\\U0001F600\"", &.{"A\xF0\x9F\x98\x80"});
}

test "parse: quoted empty segment is valid TOML" {
    // TOML allows `"" ` as a key; the grammar is taken verbatim.
    try expectSegments("a.\"\"", &.{ "a", "" });
}

test "parse: empty and whitespace-only paths" {
    try expectFailure("", error.EmptyPath);
    try expectFailure("  ", error.EmptyPath);
}

test "parse: missing segments around dots" {
    try expectFailure(".", error.EmptySegment);
    try expectFailure("a.", error.EmptySegment);
    try expectFailure("a..b", error.EmptySegment);
    try expectFailure(".a", error.EmptySegment);
    try expectFailure("a . ", error.EmptySegment);
}

test "parse: unterminated quotes" {
    try expectFailure("\"abc", error.UnterminatedQuote);
    try expectFailure("'abc", error.UnterminatedQuote);
    try expectFailure("a.\"b", error.UnterminatedQuote);
    try expectFailure("\"trailing backslash\\", error.UnterminatedQuote);
}

test "parse: characters bare keys cannot hold" {
    try expectFailure("a b", error.InvalidCharacter);
    try expectFailure("a/b", error.InvalidCharacter);
    try expectFailure("\"a\"b", error.InvalidCharacter);
    try expectFailure("caf\xc3\xa9", error.InvalidCharacter);
}

test "parse: invalid escapes" {
    try expectFailure("\"\\q\"", error.InvalidEscape);
    try expectFailure("\"\\uZZZZ\"", error.InvalidEscape);
    try expectFailure("\"\\u12\"", error.InvalidEscape);
    try expectFailure("\"\\uD800\"", error.InvalidEscape);
}
