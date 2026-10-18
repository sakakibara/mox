//! Writing a value for the context a capture sits in, or refusing it with
//! the reason and the remedy compose prints.

const std = @import("std");
const types = @import("types.zig");

const Context = types.Context;
const Encoding = types.Encoding;

/// Why a value cannot be written where its capture sits.
pub const Refusal = struct {
    /// The context, as the message names it ("a TOML literal string").
    where: []const u8,
    reason: []const u8,
    remedy: []const u8,
};

pub const Result = union(enum) {
    bytes: []const u8,
    refused: Refusal,
};

/// `value` written for `ctx`, or why it cannot be.
pub fn encode(arena: std.mem.Allocator, value: []const u8, ctx: Context) !Result {
    if (ctx.refuse) |why| return refuse(ctx.enc, "", why);
    return switch (ctx.enc) {
        .raw, .lines, .yaml_typed => .{ .bytes = value },
        .raw_line => if (hasNewline(value)) refuse(.raw_line, "it holds a newline", "keep it out of the comment") else .{ .bytes = value },
        .toml_basic => .{ .bytes = try tomlBasic(arena, value, false) },
        .toml_ml_basic => .{ .bytes = try tomlBasic(arena, value, true) },
        .toml_literal => if (std.mem.indexOfScalar(u8, value, '\'') != null or hasNewline(value))
            refuse(.toml_literal, "it holds a `'` or a newline", "use a basic string")
        else
            .{ .bytes = value },
        .toml_ml_literal => if (std.mem.indexOf(u8, value, "'''") != null)
            refuse(.toml_ml_literal, "it holds `'''`", "use a multi-line basic string")
        else
            .{ .bytes = value },
        .toml_bare => if (!tomlBareValue(value))
            refuse(.toml_bare, "it is not one TOML value", "quote it in the source")
        else
            .{ .bytes = value },
        .toml_bare_key => if (value.len == 0 or !allIn(value, isBareKeyByte))
            refuse(.toml_bare_key, "it holds a byte a bare key cannot", "quote the key in the source")
        else
            .{ .bytes = value },
        .yaml_dq => .{ .bytes = try yamlDq(arena, value) },
        .yaml_sq => if (hasNewline(value) or hasYamlBreak(value))
            refuse(.yaml_sq, "it holds a line break", "use a block scalar")
        else
            .{ .bytes = try doubled(arena, value, "'") },
        .yaml_plain => if (yamlPlainProblem(value)) |why|
            refuse(.yaml_plain, why, "quote it in the source")
        else
            .{ .bytes = value },
        .yaml_block => if (hasYamlBreak(value))
            refuse(.yaml_block, "it holds U+0085, U+2028 or U+2029", "use a double-quoted scalar")
        else
            .{ .bytes = try indented(arena, if (std.mem.endsWith(u8, value, "\n")) value[0 .. value.len - 1] else value, ctx.indent) },
        .ini_quoted => if (std.mem.indexOfScalar(u8, value, '"') != null or hasNewline(value))
            refuse(.ini_quoted, "it holds a `\"` or a newline, which INI readers do not unescape", "keep them out of the value")
        else
            .{ .bytes = value },
        .ini_unquoted => if (iniUnquotedProblem(value, false)) |why|
            refuse(.ini_unquoted, why, "quote it in the source")
        else
            .{ .bytes = value },
        .ini_section => if (std.mem.indexOfScalar(u8, value, ']') != null or hasNewline(value))
            refuse(.ini_section, "it holds a `]` or a newline", "keep them out of the section name")
        else
            .{ .bytes = value },
        .gitconfig_quoted => .{ .bytes = try gitconfigQuoted(arena, value) },
        .gitconfig_unquoted => if (iniUnquotedProblem(value, true)) |why|
            refuse(.gitconfig_unquoted, why, "quote it in the source")
        else
            .{ .bytes = value },
        .gitconfig_subsection => if (hasNewline(value))
            refuse(.gitconfig_subsection, "it holds a newline", "keep it out of the subsection name")
        else
            .{ .bytes = try escaped(arena, value, "\"\\", "\\") },
        .sh_dq => .{ .bytes = try escaped(arena, value, "\\\"$`", "\\") },
        .sh_sq => if (std.mem.indexOfScalar(u8, value, '\'') != null)
            refuse(.sh_sq, "it holds a `'`", "use double quotes")
        else
            .{ .bytes = value },
        .sh_word => if (value.len == 0 or !allIn(value, isShellWordByte))
            refuse(.sh_word, "it is empty or holds a byte the shell would read", "quote it in the source")
        else
            .{ .bytes = value },
        .sh_heredoc => if (heredocEnds(value, ctx))
            refuse(.sh_heredoc, "a line of it ends the heredoc", "use another terminator")
        else
            .{ .bytes = try escaped(arena, value, "\\$`", "\\") },
        .sh_heredoc_quoted => if (heredocEnds(value, ctx))
            refuse(.sh_heredoc_quoted, "a line of it ends the heredoc", "use another terminator")
        else
            .{ .bytes = value },
        .fish_dq => .{ .bytes = try escaped(arena, value, "\\\"$", "\\") },
        .fish_sq => .{ .bytes = try escaped(arena, value, "\\'", "\\") },
        .fish_word => if (value.len == 0 or !allIn(value, isFishWordByte))
            refuse(.fish_word, "it is empty or holds a byte fish would read", "quote it in the source")
        else
            .{ .bytes = value },
        .ps_dq => .{ .bytes = try psEscaped(arena, value, &ps_double_quotes) },
        .ps_sq => .{ .bytes = try psDoubled(arena, value) },
        .ps_here_dq => if (psHereEnds(value, &ps_double_quotes))
            refuse(.ps_here_dq, "a line of it ends the here-string", "use a single-quoted string")
        else
            .{ .bytes = try psEscaped(arena, value, &.{}) },
        .ps_here_sq => if (psHereEnds(value, &ps_single_quotes))
            refuse(.ps_here_sq, "a line of it ends the here-string", "use a double-quoted string")
        else
            .{ .bytes = value },
    };
}

/// The context as compose's message names it.
pub fn name(enc: Encoding) []const u8 {
    return switch (enc) {
        .raw, .lines, .yaml_typed => "the file",
        .raw_line => "a comment",
        .toml_basic => "a TOML basic string",
        .toml_ml_basic => "a TOML multi-line basic string",
        .toml_literal => "a TOML literal string",
        .toml_ml_literal => "a TOML multi-line literal string",
        .toml_bare => "a bare TOML value",
        .toml_bare_key => "a bare TOML key",
        .yaml_dq => "a YAML double-quoted scalar",
        .yaml_sq => "a YAML single-quoted scalar",
        .yaml_plain => "a YAML plain scalar",
        .yaml_block => "a YAML block scalar",
        .ini_quoted => "a quoted INI value",
        .ini_unquoted => "an unquoted INI value",
        .ini_section => "an INI section name",
        .gitconfig_quoted => "a quoted gitconfig value",
        .gitconfig_unquoted => "an unquoted gitconfig value",
        .gitconfig_subsection => "a gitconfig subsection name",
        .sh_dq => "a double-quoted shell string",
        .sh_sq => "a single-quoted shell string",
        .sh_word => "an unquoted shell word",
        .sh_heredoc, .sh_heredoc_quoted => "a heredoc",
        .fish_dq => "a double-quoted fish string",
        .fish_sq => "a single-quoted fish string",
        .fish_word => "an unquoted fish word",
        .ps_dq => "a double-quoted PowerShell string",
        .ps_sq => "a single-quoted PowerShell string",
        .ps_here_dq, .ps_here_sq => "a PowerShell here-string",
    };
}

fn refuse(enc: Encoding, reason: []const u8, remedy: []const u8) Result {
    return .{ .refused = .{ .where = name(enc), .reason = reason, .remedy = remedy } };
}

fn hasNewline(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\r\n") != null;
}

/// U+0085, U+2028 or U+2029, which a YAML 1.1 reader takes as a line break.
fn hasYamlBreak(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "\u{85}") != null or
        std.mem.indexOf(u8, s, "\u{2028}") != null or
        std.mem.indexOf(u8, s, "\u{2029}") != null;
}

fn allIn(s: []const u8, comptime ok: fn (u8) bool) bool {
    for (s) |c| if (!ok(c)) return false;
    return true;
}

fn isBareKeyByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn isShellWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_./:@%+,", c) != null;
}

fn isFishWordByte(c: u8) bool {
    return c != '%' and isShellWordByte(c);
}

/// `value` with every byte in `chars` preceded by `prefix`.
fn escaped(arena: std.mem.Allocator, value: []const u8, chars: []const u8, prefix: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |c| {
        if (std.mem.indexOfScalar(u8, chars, c) != null) try out.appendSlice(arena, prefix);
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

/// `value` with every occurrence of `quote` doubled.
fn doubled(arena: std.mem.Allocator, value: []const u8, quote: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, arena, value, quote, try std.mem.concat(arena, u8, &.{ quote, quote }));
}

fn tomlBasic(arena: std.mem.Allocator, value: []const u8, multi_line: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => if (multi_line) try out.append(arena, '\n') else try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        0x08 => try out.appendSlice(arena, "\\b"),
        0x0c => try out.appendSlice(arena, "\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => try out.print(arena, "\\u{X:0>4}", .{c}),
        else => try out.append(arena, c),
    };
    return out.toOwnedSlice(arena);
}

/// True when `value`, written bare after `=`, is one TOML value of a type
/// a bare value can be: a boolean, an integer, a float, or a date-time.
fn tomlBareValue(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return true;
    for ([_][]const u8{ "inf", "+inf", "-inf", "nan", "+nan", "-nan" }) |w| if (std.mem.eql(u8, value, w)) return true;
    // Numbers and date-times use only these bytes; anything else would
    // start a string, an array, a table or a comment.
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "+-._:", c) != null)) return false;
    return std.ascii.isDigit(value[0]) or value[0] == '+' or value[0] == '-' or value[0] == '.';
}

fn yamlDq(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (std.mem.startsWith(u8, value[i..], "\u{85}")) {
            try out.appendSlice(arena, "\\N");
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, value[i..], "\u{2028}")) {
            try out.appendSlice(arena, "\\L");
            i += 3;
            continue;
        }
        if (std.mem.startsWith(u8, value[i..], "\u{2029}")) {
            try out.appendSlice(arena, "\\P");
            i += 3;
            continue;
        }
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try out.print(arena, "\\x{X:0>2}", .{c}),
            else => try out.append(arena, c),
        }
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Why `value` cannot stand as one YAML plain scalar that both a YAML 1.1
/// and a YAML 1.2 core reader take as this string, or null.
fn yamlPlainProblem(value: []const u8) ?[]const u8 {
    if (value.len == 0) return "it is empty";
    if (hasNewline(value) or hasYamlBreak(value)) return "it holds a line break";
    if (value[0] == ' ' or value[0] == '\t' or value[value.len - 1] == ' ' or value[value.len - 1] == '\t') return "it starts or ends with a space";
    if (std.mem.indexOfScalar(u8, "-?:,[]{}#&*!|>'\"%@`", value[0]) != null) return "it starts with a YAML indicator";
    if (std.mem.indexOf(u8, value, ": ") != null or std.mem.indexOf(u8, value, " #") != null or value[value.len - 1] == ':') return "it holds `: ` or ` #`";
    if (yamlNonString(value)) return "a YAML reader would not read it as a string";
    return null;
}

/// True when a YAML 1.1 or core reader resolves the plain scalar `value`
/// to something other than a string: null, a boolean, a number, a date.
fn yamlNonString(value: []const u8) bool {
    const words = [_][]const u8{ "~", "null", "y", "yes", "n", "no", "true", "false", "on", "off", "=", "<<" };
    for (words) |w| if (std.ascii.eqlIgnoreCase(value, w)) return true;
    const body = if (value[0] == '+' or value[0] == '-') value[1..] else value;
    for ([_][]const u8{ ".inf", ".nan" }) |w| if (std.ascii.eqlIgnoreCase(body, w)) return true;
    // Numbers in any base, sexagesimal numbers and dates use only these.
    for (value) |c| if (!(std.ascii.isHex(c) or std.mem.indexOfScalar(u8, "+-._:xXoO", c) != null)) return false;
    return std.ascii.isDigit(body[0]) or (body.len > 1 and body[0] == '.' and std.ascii.isDigit(body[1]));
}

/// `value` with every line after the first indented by `n` spaces. A block
/// scalar's own line break ends the value, so a value's one trailing newline
/// is not written twice.
fn indented(arena: std.mem.Allocator, value: []const u8, n: u32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value, 0..) |c, i| {
        try out.append(arena, c);
        if (c == '\n' and i + 1 < value.len) try out.appendNTimes(arena, ' ', n);
    }
    return out.toOwnedSlice(arena);
}

fn iniUnquotedProblem(value: []const u8, gitconfig: bool) ?[]const u8 {
    if (hasNewline(value)) return "it holds a newline";
    if (value.len > 0 and (value[0] == ' ' or value[0] == '\t' or value[value.len - 1] == ' ' or value[value.len - 1] == '\t')) return "it starts or ends with a space";
    if (std.mem.indexOfAny(u8, value, ";#\"") != null) return "it holds `;`, `#` or `\"`";
    if (gitconfig and value.len > 0 and value[value.len - 1] == '\\') return "it ends with `\\`, which continues the line";
    return null;
}

fn gitconfigQuoted(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => try out.append(arena, c),
    };
    return out.toOwnedSlice(arena);
}

/// True when a line of `value` would end the heredoc `ctx` names.
fn heredocEnds(value: []const u8, ctx: Context) bool {
    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |line| {
        const l = if (ctx.strip_tabs) std.mem.trimStart(u8, line, "\t") else line;
        if (std.mem.eql(u8, l, ctx.terminator)) return true;
    }
    return false;
}

const ps_double_quotes = [_][]const u8{ "\"", "\u{201C}", "\u{201D}", "\u{201E}" };
const ps_single_quotes = [_][]const u8{ "'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}" };

/// `value` with a backtick before every backtick, `$`, and each of `quotes`.
fn psEscaped(arena: std.mem.Allocator, value: []const u8, quotes: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < value.len) {
        for (quotes) |q| if (std.mem.startsWith(u8, value[i..], q)) {
            try out.append(arena, '`');
            try out.appendSlice(arena, q);
            i += q.len;
            continue :outer;
        };
        if (value[i] == '`' or value[i] == '$') try out.append(arena, '`');
        try out.append(arena, value[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// `value` with every single-quote character PowerShell accepts doubled.
fn psDoubled(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < value.len) {
        for (ps_single_quotes) |q| if (std.mem.startsWith(u8, value[i..], q)) {
            try out.appendSlice(arena, q);
            try out.appendSlice(arena, q);
            i += q.len;
            continue :outer;
        };
        try out.append(arena, value[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// True when a line of `value` starts with one of `quotes` followed by `@`,
/// which closes a PowerShell here-string.
fn psHereEnds(value: []const u8, quotes: []const []const u8) bool {
    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |line| for (quotes) |q| {
        if (std.mem.startsWith(u8, line, q) and std.mem.startsWith(u8, line[q.len..], "@")) return true;
    };
    return false;
}

const testing = std.testing;

fn bytesOf(r: Result) []const u8 {
    return r.bytes;
}

test "encode: TOML basic strings escape quotes, backslashes and controls; literal strings refuse what they cannot hold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("C:\\\\temp \\\"x\\\"\\n", bytesOf(try encode(a, "C:\\temp \"x\"\n", .{ .enc = .toml_basic })));
    try testing.expectEqualStrings("a\nb\\\"", bytesOf(try encode(a, "a\nb\"", .{ .enc = .toml_ml_basic })));
    try testing.expect((try encode(a, "it's", .{ .enc = .toml_literal })) == .refused);
    try testing.expectEqualStrings("plain", bytesOf(try encode(a, "plain", .{ .enc = .toml_literal })));
    try testing.expect((try encode(a, "a'''b", .{ .enc = .toml_ml_literal })) == .refused);
    try testing.expectEqualStrings("10080", bytesOf(try encode(a, "10080", .{ .enc = .toml_bare })));
    try testing.expect((try encode(a, "abc", .{ .enc = .toml_bare })) == .refused);
    try testing.expect((try encode(a, "a b", .{ .enc = .toml_bare_key })) == .refused);
}

test "encode: YAML double quotes escape line separators; plain scalars refuse what would not read back as this string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("a\\Lb\\\"", bytesOf(try encode(a, "a\u{2028}b\"", .{ .enc = .yaml_dq })));
    try testing.expectEqualStrings("it''s", bytesOf(try encode(a, "it's", .{ .enc = .yaml_sq })));
    for ([_][]const u8{ "10080", "true", "No", "null", "~", "0123", ".inf", "-.Inf", "1:20", "2026-10-18", "a: b", "x #y", "#x", "", " a" }) |v|
        try testing.expect((try encode(a, v, .{ .enc = .yaml_plain })) == .refused);
    for ([_][]const u8{ "en_US.UTF-8", "Asia/Tokyo", "hello world", "v1.2.3", "abc" }) |v|
        try testing.expectEqualStrings(v, bytesOf(try encode(a, v, .{ .enc = .yaml_plain })));
    try testing.expectEqualStrings("l1\n    l2", bytesOf(try encode(a, "l1\nl2\n", .{ .enc = .yaml_block, .indent = 4 })));
    try testing.expect((try encode(a, "a\u{85}b", .{ .enc = .yaml_block, .indent = 2 })) == .refused);
}

test "encode: INI quoted values refuse quotes; gitconfig quoted values escape them; unquoted values must stay one value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect((try encode(a, "a\"b", .{ .enc = .ini_quoted })) == .refused);
    try testing.expectEqualStrings("C:\\temp", bytesOf(try encode(a, "C:\\temp", .{ .enc = .ini_quoted })));
    try testing.expectEqualStrings("a\\\"b\\\\c\\n", bytesOf(try encode(a, "a\"b\\c\n", .{ .enc = .gitconfig_quoted })));
    try testing.expect((try encode(a, "x;y", .{ .enc = .ini_unquoted })) == .refused);
    try testing.expect((try encode(a, "x\\", .{ .enc = .gitconfig_unquoted })) == .refused);
    try testing.expectEqualStrings("https://u:p@h", bytesOf(try encode(a, "https://u:p@h", .{ .enc = .gitconfig_unquoted })));
    try testing.expect((try encode(a, "a]b", .{ .enc = .ini_section })) == .refused);
}

test "encode: shell contexts escape what expands, refuse what they cannot hold, and keep heredoc terminators out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("p\\$x\\\"\\`\\\\", bytesOf(try encode(a, "p$x\"`\\", .{ .enc = .sh_dq })));
    try testing.expect((try encode(a, "it's", .{ .enc = .sh_sq })) == .refused);
    try testing.expectEqualStrings("Asia/Tokyo", bytesOf(try encode(a, "Asia/Tokyo", .{ .enc = .sh_word })));
    for ([_][]const u8{ "", "a b", "a{b,c}", "$x", "a;b" }) |v| try testing.expect((try encode(a, v, .{ .enc = .sh_word })) == .refused);
    try testing.expect((try encode(a, "%self", .{ .enc = .fish_word })) == .refused);
    try testing.expectEqualStrings("p\\$x\\\"", bytesOf(try encode(a, "p$x\"", .{ .enc = .fish_dq })));
    try testing.expectEqualStrings("a\\'b\\\\", bytesOf(try encode(a, "a'b\\", .{ .enc = .fish_sq })));
    try testing.expect((try encode(a, "x\nEOF\ny", .{ .enc = .sh_heredoc, .terminator = "EOF" })) == .refused);
    try testing.expect((try encode(a, "x\n\tEOF", .{ .enc = .sh_heredoc_quoted, .terminator = "EOF", .strip_tabs = true })) == .refused);
    try testing.expectEqualStrings("a\\$b", bytesOf(try encode(a, "a$b", .{ .enc = .sh_heredoc, .terminator = "EOF" })));
    try testing.expect((try encode(a, "anything", .{ .enc = .sh_dq, .refuse = "write `${NAME}`" })) == .refused);
}

test "encode: PowerShell escapes every quote character it accepts, and keeps here-string closers out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("a`\u{201D}; b`$c``", bytesOf(try encode(a, "a\u{201D}; b$c`", .{ .enc = .ps_dq })));
    try testing.expectEqualStrings("it''s \u{2019}\u{2019}", bytesOf(try encode(a, "it's \u{2019}", .{ .enc = .ps_sq })));
    try testing.expect((try encode(a, "x\n\"@", .{ .enc = .ps_here_dq })) == .refused);
    try testing.expect((try encode(a, "x\n\u{2019}@", .{ .enc = .ps_here_sq })) == .refused);
}

test "encode: a comment refuses a newline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect((try encode(a, "a\nb", .{ .enc = .raw_line })) == .refused);
    try testing.expectEqualStrings("ab", bytesOf(try encode(a, "ab", .{ .enc = .raw_line })));
}
