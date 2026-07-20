const std = @import("std");

pub const MIN_TOKEN_LEN: usize = 8;
pub const MAX_ENTROPY_BITS: f32 = 4.5;
pub const PUNCT_RATIO_LIMIT: f32 = 0.5;

const COMMON_WORDS = [_][]const u8{
    "function",    "default",    "disable",    "localhost",  "username",
    "password",    "settings",   "configure",  "register",   "complete",
    "continue",    "execute",    "external",   "internal",   "namespace",
    "operator",    "override",   "platform",   "previous",   "property",
    "release",     "required",   "response",   "standard",   "structure",
    "template",    "timestamp",  "uppercase",  "validation", "variable",
    "absolute",    "abstract",   "argument",   "background", "behavior",
    "boundary",    "callback",   "category",   "checkbox",   "constant",
    "constructor", "container",  "datetime",   "delegate",   "directory",
    "document",    "ephemeral",  "expected",   "extension",  "filename",
    "generator",   "graphics",   "horizontal", "implement",  "increment",
    "indicator",   "instance",   "interface",  "iteration",  "keyboard",
    "language",    "metadata",   "negative",   "occurrence", "operation",
    "parameter",   "permission", "position",   "preference", "primitive",
    "procedure",   "protocol",   "selector",   "separator",  "sequence",
    "serialize",   "shortcut",   "spectrum",   "specific",   "translate",
    "transient",   "transition", "triangle",   "vertical",   "viewport",
};

const PATH_SEGMENT_EXCLUSIONS = [_][]const u8{
    "/usr/local", "/opt/homebrew", "/home/linuxbrew",
    "/usr/share", "/usr/bin",
};

pub const ExtractError = error{
    OutOfMemory,
};

/// Extract tokens from `content`, applying all filters. Returned slices
/// alias `content`. Returned ArrayList itself is arena-allocated.
pub fn extract(arena: std.mem.Allocator, content: []const u8) ExtractError![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(arena);

    var i: usize = 0;
    while (i < content.len) {
        while (i < content.len and !isTokenChar(content[i])) : (i += 1) {}
        if (i >= content.len) break;
        const start = i;
        while (i < content.len and isTokenChar(content[i])) : (i += 1) {}
        const tok = content[start..i];

        if (passesFilters(tok)) {
            try result.append(arena, tok);
        }
    }
    return result.toOwnedSlice(arena);
}

pub fn isTokenChar(c: u8) bool {
    if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return false;
    if (c == '"' or c == '\'' or c == '`') return false;
    if (c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}') return false;
    if (c == '<' or c == '>') return false;
    return true;
}

fn passesFilters(tok: []const u8) bool {
    if (tok.len < MIN_TOKEN_LEN) return false;
    if (isNumeric(tok)) return false;
    for (PATH_SEGMENT_EXCLUSIONS) |p| {
        if (std.mem.eql(u8, tok, p)) return false;
    }
    for (COMMON_WORDS) |w| {
        if (std.mem.eql(u8, tok, w)) return false;
    }
    if (punctuationRatio(tok) >= PUNCT_RATIO_LIMIT) return false;
    if (shannonEntropy(tok) > MAX_ENTROPY_BITS) return false;
    return true;
}

fn isNumeric(tok: []const u8) bool {
    if (tok.len == 0) return false;
    var i: usize = 0;
    if (tok[0] == '-') i = 1;
    if (i >= tok.len) return false;
    while (i < tok.len) : (i += 1) {
        const c = tok[i];
        if (!std.ascii.isDigit(c) and c != '.') return false;
    }
    return true;
}

fn punctuationRatio(tok: []const u8) f32 {
    if (tok.len == 0) return 0;
    var punct: usize = 0;
    for (tok) |c| {
        if (!std.ascii.isAlphanumeric(c)) punct += 1;
    }
    return @as(f32, @floatFromInt(punct)) / @as(f32, @floatFromInt(tok.len));
}

fn shannonEntropy(tok: []const u8) f32 {
    if (tok.len == 0) return 0;
    var counts: [256]u32 = @splat(0);
    for (tok) |c| counts[c] += 1;
    const len_f = @as(f32, @floatFromInt(tok.len));
    var entropy: f32 = 0;
    for (counts) |count| {
        if (count == 0) continue;
        const p = @as(f32, @floatFromInt(count)) / len_f;
        entropy -= p * @log2(p);
    }
    return entropy;
}

test "extract: simple text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), "hello user@example.com world");
    var found = false;
    for (result) |t| {
        if (std.mem.eql(u8, t, "user@example.com")) found = true;
    }
    try std.testing.expect(found);
}

test "extract: short tokens excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), "abc def short");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "extract: numeric excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), "12345678 12345.6789 -100000");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "extract: high-entropy base64 excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), "Xb7Kj9Pq3Lz8Mn4Vt6Rw2Yc5Eh1Sd0");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "extract: common words excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), "function default disable");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "extract: punctuation-heavy excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), "&&&&&&&&&");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "extract: token boundaries on quotes/brackets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), "(somelongname) [anotherone1]");
    var has_first = false;
    var has_second = false;
    for (result) |t| {
        if (std.mem.eql(u8, t, "somelongname")) has_first = true;
        if (std.mem.eql(u8, t, "anotherone1")) has_second = true;
    }
    try std.testing.expect(has_first);
    try std.testing.expect(has_second);
}
