//! The INI and gitconfig context tracker. Generic INI follows the reader mox
//! parses it with: comments only at the start of a line, `=` or `:` between
//! key and value, indented continuation lines, and a value that starts with
//! `"` taken as quoted up to the next `"` (no escapes). gitconfig follows
//! git: `[section "subsection"]` with `\` escapes in the subsection, values
//! with quoted parts and `\` escapes anywhere, `;` and `#` comments outside
//! quotes, and a trailing `\` continuing the value on the next line. A
//! `\r` ends a line as `\n` does, and `\r\n` is one line end.

const std = @import("std");
const types = @import("types.zig");

pub const Dialect = enum { generic, gitconfig };

const State = enum {
    line_start,
    comment,
    key,
    /// gitconfig: whitespace between a key and its `=`.
    key_after,
    /// Generic: a section name. gitconfig: the section part before any
    /// subsection.
    section,
    /// Generic: the rest of the line after `]`.
    after_section,
    /// gitconfig: between the section name and the subsection's `"`.
    sec_gap,
    subsection,
    subsection_esc,
    /// gitconfig: after the subsection's closing `"`, before `]`.
    sec_close,
    /// Generic: after the assignment, before the value's first byte.
    value_start,
    value,
    quoted,
    /// Generic: after a quoted value's closing `"`.
    after_quote,
    value_esc,
    quoted_esc,
};

const unclosed_quote_line = "a quoted value is not closed before the end of its line";
const unclosed_quote_eof = "a quoted value is not closed at the end of the file";
const unclosed_header_line = "a section header is not closed before the end of its line";
const unclosed_header_eof = "a section header is not closed at the end of the file";

const refuse_ini_key = "a value cannot be written in an INI key; move it to the value";
const refuse_git_key = "a value cannot be written in a gitconfig key; move it to the value";
const refuse_ini_after_section = "a value cannot be written after an INI section header; move it to a value";
const refuse_git_section = "a value cannot be written in a gitconfig section name; move it to a quoted subsection";
const refuse_git_sec_outside = "a value cannot be written outside the quotes of a gitconfig subsection; move it inside them";
const refuse_backslash = "a value cannot directly follow a backslash; remove the backslash";

pub const Tracker = struct {
    dialect: Dialect,
    state: State = .line_start,
    /// The last byte was `\r`, so a `\n` next is part of the same line end.
    prev_cr: bool = false,
    /// Why the file stopped following the dialect, the first time it did.
    broken: ?[]const u8 = null,
    /// Generic: the leading whitespace of the current line so far.
    indent: u32 = 0,
    /// Generic: inside a key's block, where a line indented deeper than
    /// `key_indent` continues the value.
    in_block: bool = false,
    key_indent: u32 = 0,

    pub fn init(dialect: Dialect) Tracker {
        return .{ .dialect = dialect };
    }

    pub fn feed(t: *Tracker, bytes: []const u8) void {
        for (bytes) |c| {
            if (c == '\n' and t.prev_cr) {
                t.prev_cr = false;
                continue;
            }
            t.prev_cr = c == '\r';
            if (c == '\n' or c == '\r') {
                t.newline();
                continue;
            }
            switch (t.dialect) {
                .generic => t.genericByte(c),
                .gitconfig => t.gitByte(c),
            }
        }
    }

    fn fail(t: *Tracker, why: []const u8) void {
        if (t.broken == null) t.broken = why;
    }

    fn newline(t: *Tracker) void {
        t.indent = 0;
        switch (t.state) {
            .quoted => t.fail(unclosed_quote_line),
            .section, .sec_gap, .subsection, .subsection_esc, .sec_close => {
                t.fail(unclosed_header_line);
                t.in_block = false;
            },
            .value_esc, .quoted_esc => {
                t.state = if (t.state == .value_esc) .value else .quoted;
                return;
            },
            else => {},
        }
        t.state = .line_start;
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn genericByte(t: *Tracker, c: u8) void {
        switch (t.state) {
            .line_start => {
                if (isSpace(c)) {
                    t.indent +|= 1;
                    return;
                }
                if (t.in_block and t.indent > t.key_indent) {
                    t.state = .value;
                } else if (c == ';' or c == '#') {
                    t.state = .comment;
                    t.in_block = false;
                } else if (c == '[') {
                    t.state = .section;
                    t.in_block = false;
                } else {
                    t.in_block = true;
                    t.key_indent = t.indent;
                    t.state = if (c == '=' or c == ':') .value_start else .key;
                }
                t.indent = 0;
            },
            .key => if (c == '=' or c == ':') {
                t.state = .value_start;
            },
            .section => if (c == ']') {
                t.state = .after_section;
            },
            .value_start => {
                if (c == '"') {
                    t.state = .quoted;
                } else if (!isSpace(c)) {
                    t.state = .value;
                }
            },
            .quoted => if (c == '"') {
                t.state = .after_quote;
            },
            .comment, .after_section, .value, .after_quote => {},
            .key_after, .sec_gap, .subsection, .subsection_esc, .sec_close, .value_esc, .quoted_esc => unreachable,
        }
    }

    fn gitByte(t: *Tracker, c: u8) void {
        switch (t.state) {
            .line_start => {
                if (isSpace(c)) return;
                t.state = switch (c) {
                    ';', '#' => .comment,
                    '[' => .section,
                    '=' => .value,
                    else => .key,
                };
            },
            .key => {
                if (c == '=') {
                    t.state = .value;
                } else if (isSpace(c)) {
                    t.state = .key_after;
                }
            },
            .key_after => switch (c) {
                '=' => t.state = .value,
                ';', '#' => t.state = .comment,
                else => {},
            },
            .section => switch (c) {
                ']' => t.state = .line_start,
                '"' => t.state = .subsection,
                ' ', '\t' => t.state = .sec_gap,
                else => {},
            },
            .sec_gap => switch (c) {
                ']' => t.state = .line_start,
                '"' => t.state = .subsection,
                else => {},
            },
            .subsection => switch (c) {
                '\\' => t.state = .subsection_esc,
                '"' => t.state = .sec_close,
                else => {},
            },
            .subsection_esc => t.state = .subsection,
            .sec_close => if (c == ']') {
                t.state = .line_start;
            },
            .value => switch (c) {
                '"' => t.state = .quoted,
                '\\' => t.state = .value_esc,
                ';', '#' => t.state = .comment,
                else => {},
            },
            .value_esc => t.state = .value,
            .quoted => switch (c) {
                '"' => t.state = .value,
                '\\' => t.state = .quoted_esc,
                else => {},
            },
            .quoted_esc => t.state = .quoted,
            .comment => {},
            .after_section, .value_start, .after_quote => unreachable,
        }
    }

    pub fn context(t: *const Tracker) types.Context {
        return switch (t.dialect) {
            .generic => switch (t.state) {
                .comment => .{ .enc = .raw_line },
                .section => .{ .enc = .ini_section },
                .value_start, .value, .after_quote => .{ .enc = .ini_unquoted },
                .quoted => .{ .enc = .ini_quoted },
                .after_section => .{ .enc = .raw_line, .refuse = refuse_ini_after_section },
                else => .{ .enc = .raw_line, .refuse = refuse_ini_key },
            },
            .gitconfig => switch (t.state) {
                .comment => .{ .enc = .raw_line },
                .subsection => .{ .enc = .gitconfig_subsection },
                .value => .{ .enc = .gitconfig_unquoted },
                .quoted => .{ .enc = .gitconfig_quoted },
                .section => .{ .enc = .raw_line, .refuse = refuse_git_section },
                .sec_gap, .sec_close => .{ .enc = .raw_line, .refuse = refuse_git_sec_outside },
                .subsection_esc, .value_esc, .quoted_esc => .{ .enc = .raw_line, .refuse = refuse_backslash },
                else => .{ .enc = .raw_line, .refuse = refuse_git_key },
            },
        };
    }

    /// Whether `a` and `b` are in the same lexical state. A generic value's
    /// start and its middle compare equal: the bytes of an unquoted value
    /// move one to the other without leaving the token.
    pub fn same(a: *const Tracker, b: *const Tracker) bool {
        return a.dialect == b.dialect and
            norm(a.state) == norm(b.state) and
            a.prev_cr == b.prev_cr and
            (a.broken == null) == (b.broken == null) and
            a.indent == b.indent and
            a.in_block == b.in_block and
            a.key_indent == b.key_indent;
    }

    fn norm(s: State) State {
        return if (s == .value_start) .value else s;
    }

    pub fn finish(t: *const Tracker) ?[]const u8 {
        if (t.broken) |why| return why;
        return switch (t.state) {
            .quoted, .quoted_esc => unclosed_quote_eof,
            .section, .sec_gap, .subsection, .subsection_esc, .sec_close => unclosed_header_eof,
            else => null,
        };
    }
};

const testing = std.testing;

fn fed(dialect: Dialect, text: []const u8) Tracker {
    var t = Tracker.init(dialect);
    t.feed(text);
    return t;
}

fn expectEnc(dialect: Dialect, text: []const u8, enc: types.Encoding) !void {
    const ctx = fed(dialect, text).context();
    try testing.expectEqual(enc, ctx.enc);
    try testing.expect(ctx.refuse == null);
}

fn expectRefuse(dialect: Dialect, text: []const u8, why: []const u8) !void {
    const ctx = fed(dialect, text).context();
    try testing.expectEqual(types.Encoding.raw_line, ctx.enc);
    try testing.expectEqualStrings(why, ctx.refuse orelse return error.TestExpectedRefuse);
}

/// Whether feeding `value` after `prefix` leaves the state as it was.
fn keeps(dialect: Dialect, prefix: []const u8, value: []const u8) bool {
    const before = fed(dialect, prefix);
    var after = before;
    after.feed(value);
    return before.same(&after);
}

test "generic: quoted and unquoted values" {
    try expectEnc(.generic, "[s]\nk = ", .ini_unquoted);
    try expectEnc(.generic, "[s]\nk = abc", .ini_unquoted);
    try expectEnc(.generic, "[s]\nk: abc", .ini_unquoted);
    try expectEnc(.generic, "[s]\nk = \"", .ini_quoted);
    try expectEnc(.generic, "[s]\nk = \"abc", .ini_quoted);
    try expectEnc(.generic, "[s]\nk = \"abc\"", .ini_unquoted);
    try expectEnc(.generic, "k=\"", .ini_quoted);
}

test "generic: a quote inside an unquoted value is literal" {
    try expectEnc(.generic, "k = a\"", .ini_unquoted);
    try expectEnc(.generic, "k = a\"b\"", .ini_unquoted);
}

test "generic: section name" {
    try expectEnc(.generic, "[", .ini_section);
    try expectEnc(.generic, "[abc", .ini_section);
    try expectEnc(.generic, "k = v\n  [abc", .ini_unquoted);
    try expectRefuse(.generic, "[abc]", refuse_ini_after_section);
    try expectRefuse(.generic, "[abc]\n", refuse_ini_key);
}

test "generic: comments only at line start" {
    try expectEnc(.generic, "; ", .raw_line);
    try expectEnc(.generic, "# x", .raw_line);
    try expectEnc(.generic, "[s]\n  # x", .raw_line);
    try expectEnc(.generic, "k = a ; b", .ini_unquoted);
    try expectEnc(.generic, "k = a # b", .ini_unquoted);
    try expectEnc(.generic, "k = \"a ; b", .ini_quoted);
    try expectEnc(.generic, "# \"x\n[", .ini_section);
}

test "generic: key positions refuse" {
    try expectRefuse(.generic, "", refuse_ini_key);
    try expectRefuse(.generic, "[s]\n", refuse_ini_key);
    try expectRefuse(.generic, "[s]\nab", refuse_ini_key);
    try expectRefuse(.generic, "[s]\nk = v\n", refuse_ini_key);
}

test "generic: indented continuation lines continue the value" {
    try expectEnc(.generic, "k = v\n  more", .ini_unquoted);
    try expectEnc(.generic, "k = v\n\n  more", .ini_unquoted);
    try expectEnc(.generic, "k = v\n  # not a comment", .ini_unquoted);
    try expectEnc(.generic, "  k = v\n    more", .ini_unquoted);
    try expectRefuse(.generic, "  k = v\n  j", refuse_ini_key);
    try expectRefuse(.generic, "# c\n  j", refuse_ini_key);
    try expectRefuse(.generic, "[s]\n  j", refuse_ini_key);
}

test "generic: a quote at value start opens a quoted value, the value changes state" {
    try testing.expect(keeps(.generic, "k = ", "abc"));
    try testing.expect(keeps(.generic, "k = a", "b\"c"));
    try testing.expect(!keeps(.generic, "k = ", "\"abc\""));
    try testing.expect(!keeps(.generic, "k = ", " \"abc"));
    try testing.expect(keeps(.generic, "k = \"", "abc"));
    try testing.expect(!keeps(.generic, "k = \"", "a\"b"));
    try testing.expect(!keeps(.generic, "k = \"", "a\nb"));
    try testing.expect(!keeps(.generic, "k = v", "a\nb"));
    try testing.expect(keeps(.generic, "[", "abc"));
    try testing.expect(!keeps(.generic, "[", "a]b"));
    try testing.expect(keeps(.generic, "; ", "a\"b[c]"));
    try testing.expect(!keeps(.generic, "; ", "a\nb"));
}

test "generic: finish" {
    try testing.expect(fed(.generic, "[s]\nk = \"v\"\n").finish() == null);
    try testing.expect(fed(.generic, "[s]\nk = v").finish() == null);
    try testing.expectEqualStrings(unclosed_quote_eof, fed(.generic, "k = \"v").finish().?);
    try testing.expectEqualStrings(unclosed_quote_line, fed(.generic, "k = \"v\nj = w\n").finish().?);
    try testing.expectEqualStrings(unclosed_header_eof, fed(.generic, "[s").finish().?);
    try testing.expectEqualStrings(unclosed_header_line, fed(.generic, "[s\nk = v\n").finish().?);
}

test "gitconfig: quoted and unquoted values" {
    try expectEnc(.gitconfig, "[core]\n\teditor = ", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[core]\n\teditor = vim", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[core]\n\teditor=", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[core]\n\teditor = \"", .gitconfig_quoted);
    try expectEnc(.gitconfig, "[core]\n\teditor = \"a b", .gitconfig_quoted);
    try expectEnc(.gitconfig, "[core]\n\teditor = \"a b\"", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[core]\n\teditor = \"a b\" c", .gitconfig_unquoted);
}

test "gitconfig: quoted parts inside an unquoted value" {
    try expectEnc(.gitconfig, "[a]\nk = x \"", .gitconfig_quoted);
    try expectEnc(.gitconfig, "[a]\nk = x \"y\" z \"", .gitconfig_quoted);
    try expectEnc(.gitconfig, "[a]\nk = x \"y\" z \"w\" ", .gitconfig_unquoted);
}

test "gitconfig: escapes in quoted values" {
    try expectEnc(.gitconfig, "[a]\nk = \"x\\\"", .gitconfig_quoted);
    try expectEnc(.gitconfig, "[a]\nk = \"x\\\\", .gitconfig_quoted);
    try expectEnc(.gitconfig, "[a]\nk = \"x\\\\\"", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[a]\nk = \"x\\n", .gitconfig_quoted);
    try expectRefuse(.gitconfig, "[a]\nk = \"x\\", refuse_backslash);
    try expectRefuse(.gitconfig, "[a]\nk = x\\", refuse_backslash);
    try expectEnc(.gitconfig, "[a]\nk = x\\\"", .gitconfig_unquoted);
}

test "gitconfig: comments start only outside quotes" {
    try expectEnc(.gitconfig, "# x", .raw_line);
    try expectEnc(.gitconfig, "; x", .raw_line);
    try expectEnc(.gitconfig, "[a] # x", .raw_line);
    try expectEnc(.gitconfig, "[a]\nk = v # x", .raw_line);
    try expectEnc(.gitconfig, "[a]\nk = v ; x", .raw_line);
    try expectEnc(.gitconfig, "[a]\nk = v; x", .raw_line);
    try expectEnc(.gitconfig, "[a]\nk = \"v # x", .gitconfig_quoted);
    try expectEnc(.gitconfig, "[a]\nk = \"v ; x", .gitconfig_quoted);
    try expectEnc(.gitconfig, "[a]\nk = \"v ; x\" ", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[a]\nk = v \\# x", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[a]\nk = v # \"x\n[b \"", .gitconfig_subsection);
    try expectRefuse(.gitconfig, "[a]\nk = v # x\n", refuse_git_key);
}

test "gitconfig: line continuation" {
    try expectEnc(.gitconfig, "[a]\nk = x \\\n", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[a]\nk = x \\\ny", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[a]\nk = x \\\r\ny", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[a]\nk = \"x \\\n", .gitconfig_quoted);
    try expectEnc(.gitconfig, "[a]\nk = \"x \\\ny\" ", .gitconfig_unquoted);
    try expectRefuse(.gitconfig, "[a]\nk = x \\\\\n", refuse_git_key);
    try expectRefuse(.gitconfig, "[a]\nk = x # c \\\n", refuse_git_key);
    try testing.expect(fed(.gitconfig, "[a]\nk = \"x \\\ny\"\n").finish() == null);
}

test "gitconfig: section and subsection headers" {
    try expectRefuse(.gitconfig, "[", refuse_git_section);
    try expectRefuse(.gitconfig, "[remote", refuse_git_section);
    try expectRefuse(.gitconfig, "[remote ", refuse_git_sec_outside);
    try expectEnc(.gitconfig, "[remote \"", .gitconfig_subsection);
    try expectEnc(.gitconfig, "[remote \"ori", .gitconfig_subsection);
    try expectEnc(.gitconfig, "[remote \"a\\\"b", .gitconfig_subsection);
    try expectEnc(.gitconfig, "[remote \"a]b", .gitconfig_subsection);
    try expectRefuse(.gitconfig, "[remote \"a\\", refuse_backslash);
    try expectRefuse(.gitconfig, "[remote \"origin\"", refuse_git_sec_outside);
    try expectRefuse(.gitconfig, "[remote \"origin\"]", refuse_git_key);
    try expectRefuse(.gitconfig, "[remote \"origin\"]\n\turl", refuse_git_key);
    try expectRefuse(.gitconfig, "[remote \"origin\"]\n\turl ", refuse_git_key);
    try expectEnc(.gitconfig, "[remote \"origin\"]\n\turl = ", .gitconfig_unquoted);
    try expectEnc(.gitconfig, "[remote \"origin\"] url = \"", .gitconfig_quoted);
    try expectEnc(.gitconfig, "[a]\nk = \"[b \\\"", .gitconfig_quoted);
}

test "gitconfig: an escaped value keeps the state, a raw quote changes it" {
    const q = "[a]\nk = \"";
    try testing.expect(keeps(.gitconfig, q, "x\\\"y"));
    try testing.expect(keeps(.gitconfig, q, "x\\\\y"));
    try testing.expect(keeps(.gitconfig, q, "x\\\\"));
    try testing.expect(!keeps(.gitconfig, q, "x\"y"));
    try testing.expect(!keeps(.gitconfig, q, "x\\"));
    try testing.expect(!keeps(.gitconfig, q, "x\ny"));
    try testing.expect(keeps(.gitconfig, q, "a ; b # c"));

    const u = "[a]\nk = ";
    try testing.expect(keeps(.gitconfig, u, "abc"));
    try testing.expect(!keeps(.gitconfig, u, "a\"b"));
    try testing.expect(!keeps(.gitconfig, u, "a#b"));
    try testing.expect(!keeps(.gitconfig, u, "a;b"));
    try testing.expect(!keeps(.gitconfig, u, "ab\\"));
    try testing.expect(!keeps(.gitconfig, u, "a\nb"));

    const s = "[remote \"";
    try testing.expect(keeps(.gitconfig, s, "a\\\"b\\\\"));
    try testing.expect(keeps(.gitconfig, s, "a]b"));
    try testing.expect(!keeps(.gitconfig, s, "a\"b"));
    try testing.expect(!keeps(.gitconfig, s, "a\\"));
    try testing.expect(!keeps(.gitconfig, s, "a\nb"));

    try testing.expect(keeps(.gitconfig, "# ", "a\"b;c\\"));
    try testing.expect(!keeps(.gitconfig, "# ", "a\nb"));
}

test "gitconfig: finish" {
    try testing.expect(fed(.gitconfig, "[a \"b\"]\n\tk = \"v\" # c\n").finish() == null);
    try testing.expect(fed(.gitconfig, "[a]\n\tk = v \\").finish() == null);
    try testing.expectEqualStrings(unclosed_quote_eof, fed(.gitconfig, "[a]\nk = \"v").finish().?);
    try testing.expectEqualStrings(unclosed_quote_eof, fed(.gitconfig, "[a]\nk = \"v \\\n").finish().?);
    try testing.expectEqualStrings(unclosed_quote_line, fed(.gitconfig, "[a]\nk = \"v\nj = w\n").finish().?);
    try testing.expectEqualStrings(unclosed_header_eof, fed(.gitconfig, "[a \"b").finish().?);
    try testing.expectEqualStrings(unclosed_header_line, fed(.gitconfig, "[a \"b\nk = v\n").finish().?);
    try testing.expectEqualStrings(unclosed_header_line, fed(.gitconfig, "[a \"b\\\n\"]\n").finish().?);
    try testing.expectEqualStrings(unclosed_header_line, fed(.gitconfig, "[a\n").finish().?);
}

test "feed is split-invariant" {
    const text = "[remote \"o\\\"x\"]\r\n\turl = \"a \\\r\nb\" c \\\r\n d ; e\r\n[s]\n k = \"q";
    for ([_]Dialect{ .generic, .gitconfig }) |d| {
        const whole = fed(d, text);
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            var t = Tracker.init(d);
            t.feed(text[0..i]);
            t.feed(text[i..]);
            try testing.expect(whole.same(&t));
            try testing.expectEqual(whole.state, t.state);
        }
        var b = Tracker.init(d);
        for (text) |c| b.feed(&.{c});
        try testing.expect(whole.same(&b));
    }
}

test "a CR alone ends a line" {
    try expectRefuse(.gitconfig, "[a]\rk", refuse_git_key);
    try testing.expectEqualStrings(unclosed_quote_line, fed(.gitconfig, "[a]\nk = \"v\rw\"\n").finish().?);
    try expectEnc(.generic, "k = v\r\n  w", .ini_unquoted);
}

test "the dialects differ on a mid-value quote and inline comments" {
    try expectEnc(.generic, "k = a \"", .ini_unquoted);
    try expectEnc(.gitconfig, "[a]\nk = a \"", .gitconfig_quoted);
    try expectEnc(.generic, "k = a ;", .ini_unquoted);
    try expectEnc(.gitconfig, "[a]\nk = a ;", .raw_line);
    var g = Tracker.init(.generic);
    const h = Tracker.init(.gitconfig);
    try testing.expect(!g.same(&h));
    g.feed("");
    try testing.expect(g.same(&Tracker.init(.generic)));
}
