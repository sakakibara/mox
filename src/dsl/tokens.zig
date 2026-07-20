const std = @import("std");

/// Token kinds emitted by the directive lexer.
pub const TokenKind = union(enum) {
    /// A reserved keyword: `include`, `replace`, `append`, `prepend`,
    /// `remove`, `from`, `when`, `for`, `secret`, `in`, `and`, `or`, `not`, `end`.
    keyword: []const u8,
    /// A bareword identifier (axis name, axis value, variable name).
    ident: []const u8,
    /// A double-quoted string literal (path or URI). String body contents
    /// are stored as a slice into the original input -- the surrounding `"`
    /// characters are NOT included.
    string: []const u8,
    /// `=` for axis equality.
    eq,
    /// `(` opening paren for grouping.
    lparen,
    /// `)` closing paren for grouping.
    rparen,
    /// End-of-input.
    eof,
};

/// A token with its source-byte range.
///
/// `start`/`end` are byte offsets into the directive args string passed
/// to the lexer (NOT into the original file). `end` is exclusive.
pub const Token = struct {
    kind: TokenKind,
    start: u32,
    end: u32,
};

test "Token type can be constructed" {
    const tok = Token{ .kind = .{ .keyword = "include" }, .start = 5, .end = 12 };
    try std.testing.expectEqual(@as(u32, 5), tok.start);
}

test "TokenKind eq variant has no payload" {
    const tok = Token{ .kind = .eq, .start = 0, .end = 1 };
    try std.testing.expect(tok.kind == .eq);
}
