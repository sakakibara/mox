const std = @import("std");
const tokens_mod = @import("tokens.zig");

const Token = tokens_mod.Token;
const TokenKind = tokens_mod.TokenKind;

const KEYWORDS = [_][]const u8{
    "include", "replace", "append", "prepend",
    "remove",  "from",    "when",   "for",
    "secret",  "in",      "and",    "or",
    "not",     "end",     "where",  "has",
    "into",
};

fn isKeyword(s: []const u8) bool {
    for (KEYWORDS) |kw| {
        if (std.mem.eql(u8, s, kw)) return true;
    }
    return false;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '-' or c == '.';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '+';
}

pub const LexError = error{
    UnterminatedString,
    UnexpectedCharacter,
    OutOfMemory,
};

/// Tokenize a directive args string. The caller-provided `allocator` owns the
/// returned slice; in typical use the caller passes an arena.
pub fn lex(allocator: std.mem.Allocator, src: []const u8) LexError![]Token {
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(allocator);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        // Skip whitespace.
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        // String literal.
        if (c == '"') {
            const start = i + 1;
            i += 1;
            while (i < src.len and src[i] != '"') : (i += 1) {}
            if (i >= src.len) return error.UnterminatedString;
            try list.append(allocator, .{
                .kind = .{ .string = src[start..i] },
                .start = @intCast(start),
                .end = @intCast(i),
            });
            i += 1; // skip closing "
            continue;
        }
        // Equality.
        if (c == '=') {
            try list.append(allocator, .{
                .kind = .eq,
                .start = @intCast(i),
                .end = @intCast(i + 1),
            });
            i += 1;
            continue;
        }
        // Parens for grouping in row-expr.
        if (c == '(') {
            try list.append(allocator, .{ .kind = .lparen, .start = @intCast(i), .end = @intCast(i + 1) });
            i += 1;
            continue;
        }
        if (c == ')') {
            try list.append(allocator, .{ .kind = .rparen, .start = @intCast(i), .end = @intCast(i + 1) });
            i += 1;
            continue;
        }
        // Identifier or keyword.
        if (isIdentStart(c)) {
            const start = i;
            while (i < src.len and isIdentCont(src[i])) : (i += 1) {}
            const word = src[start..i];
            const kind: TokenKind = if (isKeyword(word))
                .{ .keyword = word }
            else
                .{ .ident = word };
            try list.append(allocator, .{
                .kind = kind,
                .start = @intCast(start),
                .end = @intCast(i),
            });
            continue;
        }
        return error.UnexpectedCharacter;
    }
    try list.append(allocator, .{
        .kind = .eof,
        .start = @intCast(src.len),
        .end = @intCast(src.len),
    });
    return list.toOwnedSlice(allocator);
}

test "lex include directive" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const toks = try lex(fba.allocator(), "include \"foo.sh\"");
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqualStrings("include", toks[0].kind.keyword);
    try std.testing.expectEqualStrings("foo.sh", toks[1].kind.string);
}

test "lex axis expression with and/or/not" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const toks = try lex(fba.allocator(), "not os=windows and profile=work or os=darwin");
    // not, os, =, windows, and, profile, =, work, or, os, =, darwin, eof
    try std.testing.expectEqual(@as(usize, 13), toks.len);
}

test "lex empty input" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const toks = try lex(fba.allocator(), "");
    try std.testing.expectEqual(@as(usize, 1), toks.len);
    try std.testing.expect(toks[0].kind == .eof);
}

test "lex unterminated string fails" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = lex(fba.allocator(), "include \"foo.sh");
    try std.testing.expectError(error.UnterminatedString, result);
}

test "lex unexpected character fails" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = lex(fba.allocator(), "include @foo");
    try std.testing.expectError(error.UnexpectedCharacter, result);
}

test "lex identifier starting with digit (axis value 2.0)" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const toks = try lex(fba.allocator(), "version=2.0");
    // version, =, 2.0, eof = 4
    try std.testing.expectEqual(@as(usize, 4), toks.len);
    try std.testing.expectEqualStrings("version", toks[0].kind.ident);
    try std.testing.expect(toks[1].kind == .eq);
    try std.testing.expectEqualStrings("2.0", toks[2].kind.ident);
}

test "lex identifier with + and -" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const toks = try lex(fba.allocator(), "tool=fdfind-2.0");
    try std.testing.expectEqualStrings("fdfind-2.0", toks[2].kind.ident);
}

test "lex consecutive whitespace and tabs" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const toks = try lex(fba.allocator(), "include\t\t \"foo.sh\"   when  os=darwin");
    // include, "foo.sh", when, os, =, darwin, eof = 7
    try std.testing.expectEqual(@as(usize, 7), toks.len);
}
