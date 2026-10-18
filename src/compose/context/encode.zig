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
        .yaml_plain => .{ .bytes = value },
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

/// The value `text`, as written in `ctx`, reads back as: the inverse of
/// `encode` that also accepts any other spelling the context allows (a TOML
/// `\u00e9`, a fish `\x`). Null when `text` cannot stand whole in `ctx`: it
/// would end the string, expand, or holds an escape the context rejects.
pub fn decode(arena: std.mem.Allocator, text: []const u8, ctx: Context) !?[]const u8 {
    if (ctx.refuse != null) return null;
    const value: ?[]const u8 = switch (ctx.enc) {
        .raw, .lines, .yaml_typed, .raw_line, .toml_literal, .toml_ml_literal, .toml_bare, .toml_bare_key, .yaml_plain, .ini_quoted, .ini_unquoted, .ini_section, .gitconfig_unquoted, .sh_sq, .sh_word, .sh_heredoc_quoted, .fish_word, .ps_here_sq => text,
        .toml_basic, .toml_ml_basic => try unescapeToml(arena, text, ctx.enc == .toml_ml_basic),
        .yaml_dq => try unescapeYamlDq(arena, text),
        .yaml_sq => try undoubled(arena, text, &.{"'"}),
        .yaml_block => try unindented(arena, text, ctx.indent),
        .gitconfig_quoted => try unescapeGitconfig(arena, text),
        .gitconfig_subsection => try unescapeShell(arena, text, "\\\"", "\"", false),
        .sh_dq => try unescapeShell(arena, text, "\\\"$`", "\"$`", true),
        .sh_heredoc => try unescapeShell(arena, text, "\\$`", "$`", true),
        .fish_dq => try unescapeShell(arena, text, "\\\"$", "\"$", true),
        .fish_sq => try unescapeShell(arena, text, "\\'", "'", false),
        .ps_dq => try unescapePs(arena, text, &ps_double_quotes),
        .ps_sq => try undoubled(arena, text, &ps_single_quotes),
        .ps_here_dq => try unescapePs(arena, text, &.{}),
    };
    const v = value orelse return null;
    // What `encode` refuses here cannot have been written by it, nor can a
    // value whose writing would differ in what it stops at.
    return switch (try encode(arena, v, ctx)) {
        .bytes => v,
        .refused => null,
    };
}

fn unescapeToml(arena: std.mem.Allocator, text: []const u8, multi_line: bool) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' and (!multi_line or std.mem.startsWith(u8, text[i..], "\"\"\""))) return null;
        if (c == '\n' and !multi_line) return null;
        if (c != '\\') {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (i + 1 >= text.len) return null;
        const e = text[i + 1];
        i += 2;
        switch (e) {
            '"' => try out.append(arena, '"'),
            '\\' => try out.append(arena, '\\'),
            'n' => try out.append(arena, '\n'),
            'r' => try out.append(arena, '\r'),
            't' => try out.append(arena, '\t'),
            'b' => try out.append(arena, 0x08),
            'f' => try out.append(arena, 0x0c),
            'e' => try out.append(arena, 0x1b),
            'u', 'U' => {
                const n: usize = if (e == 'u') 4 else 8;
                if (!try appendCodepoint(arena, &out, text, i, n)) return null;
                i += n;
            },
            ' ', '\t', '\n', '\r' => {
                // A multi-line string's line-ending backslash trims the
                // whitespace up to the next non-blank byte.
                if (!multi_line) return null;
                var j = i - 1;
                while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
                if (j >= text.len or (text[j] != '\n' and text[j] != '\r')) return null;
                while (j < text.len and std.mem.indexOfScalar(u8, " \t\r\n", text[j]) != null) j += 1;
                i = j;
            },
            else => return null,
        }
    }
    return try out.toOwnedSlice(arena);
}

/// Append the code point spelled by the `n` hex digits at `text[at..]`.
fn appendCodepoint(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, at: usize, n: usize) !bool {
    if (at + n > text.len) return false;
    const cp = std.fmt.parseInt(u21, text[at .. at + n], 16) catch return false;
    var b: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &b) catch return false;
    try out.appendSlice(arena, b[0..len]);
    return true;
}

fn unescapeYamlDq(arena: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\n' or c == '\r') return null;
        if (c != '\\') {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (i + 1 >= text.len) return null;
        const e = text[i + 1];
        i += 2;
        const single: ?[]const u8 = switch (e) {
            '0' => "\x00",
            'a' => "\x07",
            'b' => "\x08",
            't', '\t' => "\t",
            'n' => "\n",
            'v' => "\x0b",
            'f' => "\x0c",
            'r' => "\r",
            'e' => "\x1b",
            ' ' => " ",
            '"' => "\"",
            '/' => "/",
            '\\' => "\\",
            'N' => "\u{85}",
            '_' => "\u{a0}",
            'L' => "\u{2028}",
            'P' => "\u{2029}",
            else => null,
        };
        if (single) |s| {
            try out.appendSlice(arena, s);
            continue;
        }
        const n: usize = switch (e) {
            'x' => 2,
            'u' => 4,
            'U' => 8,
            else => return null,
        };
        if (!try appendCodepoint(arena, &out, text, i, n)) return null;
        i += n;
    }
    return try out.toOwnedSlice(arena);
}

/// `text` with each doubled quote of `quotes` read as one; null on a quote
/// that is not doubled, which would end the string.
fn undoubled(arena: std.mem.Allocator, text: []const u8, quotes: []const []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < text.len) {
        for (quotes) |q| if (std.mem.startsWith(u8, text[i..], q)) {
            // PowerShell takes any two of its single quotes as one.
            const next = text[i + q.len ..];
            for (quotes) |q2| if (std.mem.startsWith(u8, next, q2)) {
                try out.appendSlice(arena, q);
                i += q.len + q2.len;
                continue :outer;
            };
            return null;
        };
        try out.append(arena, text[i]);
        i += 1;
    }
    return try out.toOwnedSlice(arena);
}

/// `text` with the `n` spaces after each line break removed; null when a
/// non-empty continuation line is indented less.
fn unindented(arena: std.mem.Allocator, text: []const u8, n: u32) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            try out.append(arena, '\n');
            if (line.len < n or !allIn(line[0..n], isSpace)) {
                if (std.mem.trim(u8, line, " ").len != 0) return null;
                continue;
            }
            try out.appendSlice(arena, line[n..]);
        } else try out.appendSlice(arena, line);
        first = false;
    }
    return try out.toOwnedSlice(arena);
}

fn isSpace(c: u8) bool {
    return c == ' ';
}

fn unescapeGitconfig(arena: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"' or c == '\n') return null;
        if (c != '\\') {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (i + 1 >= text.len) return null;
        try out.append(arena, switch (text[i + 1]) {
            '"' => '"',
            '\\' => '\\',
            'n' => '\n',
            't' => '\t',
            'b' => 0x08,
            else => return null,
        });
        i += 2;
    }
    return try out.toOwnedSlice(arena);
}

/// A shell-style string: a backslash before one of `escapes` reads as that
/// byte, before a newline (when `continues`) as nothing, and before any other
/// byte as itself; a bare byte of `bare` would end the string or expand.
fn unescapeShell(arena: std.mem.Allocator, text: []const u8, escapes: []const u8, bare: []const u8, continues: bool) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (std.mem.indexOfScalar(u8, bare, c) != null) return null;
        if (c != '\\') {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (i + 1 >= text.len) return null;
        const e = text[i + 1];
        i += 2;
        if (std.mem.indexOfScalar(u8, escapes, e) != null) {
            try out.append(arena, e);
        } else if (e == '\n' and continues) {} else {
            try out.append(arena, '\\');
            try out.append(arena, e);
        }
    }
    return try out.toOwnedSlice(arena);
}

/// A PowerShell expandable string: a backtick escapes the next character
/// (`n`, `t` and the other letters PowerShell names stand for controls), a
/// doubled quote of `quotes` reads as one, and a bare `$` would expand.
fn unescapePs(arena: std.mem.Allocator, text: []const u8, quotes: []const []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < text.len) {
        if (text[i] == '$') return null;
        if (text[i] == '`') {
            if (i + 1 >= text.len) return null;
            const e = text[i + 1];
            const ctl: ?u8 = switch (e) {
                '0' => 0,
                'a' => 0x07,
                'b' => 0x08,
                'e' => 0x1b,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'v' => 0x0b,
                else => null,
            };
            if (ctl) |b| {
                try out.append(arena, b);
                i += 2;
                continue;
            }
            if (e == 'u' and i + 2 < text.len and text[i + 2] == '{') {
                const close = std.mem.indexOfScalarPos(u8, text, i + 3, '}') orelse return null;
                const hex = text[i + 3 .. close];
                if (hex.len == 0 or hex.len > 6 or !try appendCodepoint(arena, &out, text, i + 3, hex.len)) return null;
                i = close + 1;
                continue;
            }
            // The escaped character, which may be a multi-byte quote.
            const len = std.unicode.utf8ByteSequenceLength(e) catch return null;
            if (i + 1 + len > text.len) return null;
            try out.appendSlice(arena, text[i + 1 .. i + 1 + len]);
            i += 1 + len;
            continue;
        }
        for (quotes) |q| if (std.mem.startsWith(u8, text[i..], q)) {
            const next = text[i + q.len ..];
            for (quotes) |q2| if (std.mem.startsWith(u8, next, q2)) {
                try out.appendSlice(arena, q);
                i += q.len + q2.len;
                continue :outer;
            };
            return null;
        };
        try out.append(arena, text[i]);
        i += 1;
    }
    return try out.toOwnedSlice(arena);
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

test "encode: YAML double quotes escape line separators; plain values are written as they are and checked as a whole scalar by the encoder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("a\\Lb\\\"", bytesOf(try encode(a, "a\u{2028}b\"", .{ .enc = .yaml_dq })));
    try testing.expectEqualStrings("it''s", bytesOf(try encode(a, "it's", .{ .enc = .yaml_sq })));
    for ([_][]const u8{ "en_US.UTF-8", "Asia/Tokyo", "yes", "" }) |v|
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

test "decode: every encoding reads back the value it wrote" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const values = [_][]const u8{ "plain", "C:\\temp \"x\" $HOME `id` it's", "tab\there\x01", "a\u{2028}b\u{85}c", "caf\u{e9} \u{201C}q\u{201D} \u{2019}s", "l1\nl2" };
    inline for (@typeInfo(Encoding).@"enum".fields) |f| {
        const ctx: Context = .{ .enc = @enumFromInt(f.value), .indent = 2, .terminator = "EOF" };
        for (values) |v| switch (try encode(a, v, ctx)) {
            .bytes => |b| {
                const back = (try decode(a, b, ctx)) orelse return error.TestUnexpectedResult;
                testing.expectEqualStrings(v, back) catch |e| {
                    std.debug.print("encoding {s}\n", .{f.name});
                    return e;
                };
            },
            .refused => {},
        };
    }
}

test "decode: other spellings a context allows read back; text that would end the string or expand does not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("caf\u{e9}", (try decode(a, "caf\\u00e9", .{ .enc = .toml_basic })).?);
    try testing.expectEqualStrings("a\\qb", (try decode(a, "a\\qb", .{ .enc = .sh_dq })).?);
    try testing.expectEqualStrings("x\ny", (try decode(a, "x`ny", .{ .enc = .ps_dq })).?);
    try testing.expectEqualStrings("a\"b", (try decode(a, "a\"\"b", .{ .enc = .ps_dq })).?);
    try testing.expect((try decode(a, "a\"b", .{ .enc = .toml_basic })) == null);
    try testing.expect((try decode(a, "a\\qb", .{ .enc = .toml_basic })) == null);
    try testing.expect((try decode(a, "a$b", .{ .enc = .sh_dq })) == null);
    try testing.expect((try decode(a, "it's", .{ .enc = .yaml_sq })) == null);
    try testing.expect((try decode(a, "a$b", .{ .enc = .ps_dq })) == null);
    try testing.expect((try decode(a, "a b", .{ .enc = .sh_word })) == null);
    try testing.expect((try decode(a, "x", .{ .enc = .sh_dq, .refuse = "write `${NAME}`" })) == null);
}
