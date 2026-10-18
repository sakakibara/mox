//! PowerShell's lexical contexts: quotes (its Unicode quote characters
//! included), backtick escapes, `#` and `<#...#>` comments, here-strings,
//! `${...}` and `$(...)` (nested inside double quotes, whose inner quotes it
//! tracks). Whether `#`, `<#` and `@"` begin a token inside a bare word
//! depends on whether the statement is a command (whose arguments absorb
//! them) or an expression; the tracker follows that from each statement's
//! first token.

const std = @import("std");
const types = @import("types.zig");

const max_depth = 64;

const refuse_quote = "quote it in the source; mox writes a value only inside plain quotes, a heredoc, or as a plain word";
const refuse_dollar = "write `${NAME}`";

/// What the statement being lexed is, as far as its first token tells.
const Cmd = enum(u2) { start, command, expr };

const Kind = enum(u4) {
    dq,
    sq,
    here_dq_head,
    here_sq_head,
    here_dq,
    here_sq,
    sub,
    brace,
    line_comment,
    block_comment,
};

/// A nested context, with the enclosing code's word and statement state
/// to restore when it closes.
const Frame = struct {
    kind: Kind,
    depth: u16 = 0,
    word: bool = false,
    cmd: Cmd = .start,
};

/// A character whose meaning depends on the one after it.
const Pend = enum(u4) {
    none,
    backtick,
    /// A closing quote that a second quote would turn into a literal one.
    quote,
    dollar,
    var_name,
    var_special,
    lt,
    at,
    /// `#` in a block comment.
    hash,
    /// A quote at the start of a here-string line.
    here_close,
};

const Step = enum { consumed, escaped, again };

pub const Tracker = struct {
    frames: [max_depth]Frame = @splat(.{ .kind = .dq }),
    len: u8 = 0,
    pend: Pend = .none,
    word: bool = false,
    cmd: Cmd = .start,
    /// In a here-string body: the next character starts a line.
    line_start: bool = false,
    ubuf: [4]u8 = @splat(0),
    ulen: u8 = 0,
    uneed: u8 = 0,
    bad: ?[]const u8 = null,
    overflow: bool = false,

    pub fn init() Tracker {
        return .{};
    }

    pub fn feed(t: *Tracker, bytes: []const u8) void {
        for (bytes) |b| t.byte(b);
    }

    pub fn context(t: *const Tracker) types.Context {
        var c = t.*;
        c.settleQuote();
        if (c.overflow or c.ulen != 0) return refused(refuse_quote);
        for (c.frames[0..c.len]) |f| {
            if (f.kind == .sub or f.kind == .brace) return refused(refuse_quote);
        }
        const k = c.top() orelse return refused(refuse_quote);
        switch (c.pend) {
            .backtick => return refused(refuse_quote),
            .dollar, .var_name, .var_special => {
                return refused(if (k == .dq or k == .here_dq) refuse_dollar else refuse_quote);
            },
            else => {},
        }
        return switch (k) {
            .dq => .{ .enc = .ps_dq },
            .sq => .{ .enc = .ps_sq },
            .here_dq => .{ .enc = .ps_here_dq, .terminator = "\"@" },
            .here_sq => .{ .enc = .ps_here_sq, .terminator = "'@" },
            .line_comment, .block_comment => .{ .enc = .raw_line },
            .here_dq_head, .here_sq_head, .sub, .brace => refused(refuse_quote),
        };
    }

    /// Whether `b`, the state after a value is fed to `a`, is in `a`'s
    /// lexical context. In a here-string a value may move the position off a
    /// line start, but not onto one where `a` was mid-line, since a closing
    /// quote there would end the here-string.
    pub fn same(a: *const Tracker, b: *const Tracker) bool {
        if (b.line_start and !a.line_start) return false;
        if (a.len != b.len or a.pend != b.pend or a.word != b.word or a.cmd != b.cmd) return false;
        if (a.overflow != b.overflow or (a.bad == null) != (b.bad == null)) return false;
        if (a.uneed != b.uneed or !std.mem.eql(u8, a.ubuf[0..a.ulen], b.ubuf[0..b.ulen])) return false;
        for (a.frames[0..a.len], b.frames[0..b.len]) |x, y| {
            if (x.kind != y.kind or x.depth != y.depth or x.word != y.word or x.cmd != y.cmd) return false;
        }
        return true;
    }

    pub fn finish(t: *const Tracker) ?[]const u8 {
        var c = t.*;
        c.settleQuote();
        if (c.top() == .line_comment) c.pop();
        if (c.overflow) return "nesting deeper than 64 levels";
        if (c.bad) |m| return m;
        const k = c.top() orelse return null;
        return switch (k) {
            .dq => "an unclosed double-quoted string",
            .sq => "an unclosed single-quoted string",
            .here_dq_head, .here_sq_head, .here_dq, .here_sq => "an unclosed here-string",
            .sub => "an unclosed `$(`",
            .brace => "an unclosed `${`",
            .block_comment => "an unclosed block comment",
            .line_comment => unreachable,
        };
    }

    fn refused(msg: []const u8) types.Context {
        return .{ .enc = .raw, .refuse = msg };
    }

    fn settleQuote(t: *Tracker) void {
        if (t.pend == .quote) {
            t.pend = .none;
            t.pop();
        }
    }

    fn top(t: *const Tracker) ?Kind {
        return if (t.len == 0) null else t.frames[t.len - 1].kind;
    }

    fn push(t: *Tracker, kind: Kind) void {
        if (t.len == max_depth) {
            t.overflow = true;
            return;
        }
        t.frames[t.len] = .{ .kind = kind, .word = t.word, .cmd = t.cmd };
        t.len += 1;
    }

    fn pop(t: *Tracker) void {
        const f = t.frames[t.len - 1];
        t.len -= 1;
        switch (f.kind) {
            .dq, .sq => {
                t.word = f.word;
                t.cmd = if (f.cmd == .start) .expr else f.cmd;
            },
            .here_dq_head, .here_sq_head, .here_dq, .here_sq, .sub => {
                t.word = false;
                t.cmd = if (f.cmd == .start) .expr else f.cmd;
            },
            .brace => {
                t.word = true;
                t.cmd = f.cmd;
            },
            .block_comment => {
                t.word = false;
                t.cmd = f.cmd;
            },
            .line_comment => {
                t.word = false;
                t.cmd = .start;
            },
        }
    }

    fn byte(t: *Tracker, b: u8) void {
        if (t.overflow) return;
        if (t.ulen == 0) {
            if (b < 0x80) return t.step(b);
            const need: u8 = if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else 0;
            if (need == 0) return t.step(0xFFFD);
            t.ubuf[0] = b;
            t.ulen = 1;
            t.uneed = need;
            return;
        }
        if (b & 0xC0 != 0x80) {
            t.ulen = 0;
            t.uneed = 0;
            t.step(0xFFFD);
            return t.byte(b);
        }
        t.ubuf[t.ulen] = b;
        t.ulen += 1;
        if (t.ulen < t.uneed) return;
        var cp: u21 = t.ubuf[0] & (@as(u8, 0x7F) >> @intCast(t.uneed));
        for (t.ubuf[1..t.ulen]) |c| cp = (cp << 6) | (c & 0x3F);
        t.ulen = 0;
        t.uneed = 0;
        t.step(cp);
    }

    fn step(t: *Tracker, cp: u21) void {
        while (true) {
            switch (t.step1(cp)) {
                .again => continue,
                .consumed => {
                    t.line_start = isNewline(cp) and t.inHereBody();
                    return;
                },
                .escaped => {
                    t.line_start = false;
                    return;
                },
            }
        }
    }

    fn inHereBody(t: *const Tracker) bool {
        const k = t.top() orelse return false;
        return k == .here_dq or k == .here_sq;
    }

    fn inCode(t: *const Tracker) bool {
        const k = t.top() orelse return true;
        return k == .sub;
    }

    /// Every `.again` clears `pend` or pops a frame, so `step` terminates.
    fn step1(t: *Tracker, cp: u21) Step {
        switch (t.pend) {
            .none => {},
            .backtick => {
                t.pend = .none;
                if (t.inCode() and isNewline(cp)) t.word = false;
                return .escaped;
            },
            .quote => {
                t.pend = .none;
                const k = t.top().?;
                if ((k == .dq and isDq(cp)) or (k == .sq and isSq(cp))) return .consumed;
                t.pop();
                return .again;
            },
            .dollar => {
                t.pend = .none;
                if (cp == '(') {
                    t.push(.sub);
                    t.word = false;
                    t.cmd = .start;
                    return .consumed;
                }
                if (cp == '{') {
                    t.push(.brace);
                    return .consumed;
                }
                if (cp == '?' or cp == '^' or cp == '$') {
                    t.pend = .var_special;
                    return .consumed;
                }
                if (isNameChar(cp)) {
                    t.pend = .var_name;
                    return .consumed;
                }
                return .again;
            },
            .var_name => {
                if (isNameChar(cp)) return .consumed;
                t.pend = .none;
                return .again;
            },
            .var_special => {
                t.pend = .none;
                return .again;
            },
            .lt => {
                t.pend = .none;
                if (cp == '#') {
                    t.push(.block_comment);
                    return .consumed;
                }
                t.word = false;
                return .again;
            },
            .at => {
                t.pend = .none;
                if (isDq(cp)) {
                    t.push(.here_dq_head);
                    return .consumed;
                }
                if (isSq(cp)) {
                    t.push(.here_sq_head);
                    return .consumed;
                }
                t.beginToken('@');
                return .again;
            },
            .hash => {
                t.pend = .none;
                if (cp == '>') {
                    t.pop();
                    return .consumed;
                }
                return .again;
            },
            .here_close => {
                t.pend = .none;
                if (cp == '@') {
                    t.pop();
                    return .consumed;
                }
                return .again;
            },
        }

        const k = t.top() orelse return t.code(cp);
        switch (k) {
            .sub => return t.code(cp),
            .dq => {
                if (cp == '`') {
                    t.pend = .backtick;
                } else if (cp == '$') {
                    t.pend = .dollar;
                } else if (isDq(cp)) {
                    t.pend = .quote;
                }
            },
            .here_dq => {
                if (t.line_start and isDq(cp)) {
                    t.pend = .here_close;
                } else if (cp == '`') {
                    t.pend = .backtick;
                } else if (cp == '$') {
                    t.pend = .dollar;
                }
            },
            .sq => {
                if (isSq(cp)) t.pend = .quote;
            },
            .here_sq => {
                if (t.line_start and isSq(cp)) t.pend = .here_close;
            },
            .here_dq_head, .here_sq_head => {
                if (isNewline(cp)) {
                    t.frames[t.len - 1].kind = if (k == .here_dq_head) .here_dq else .here_sq;
                } else if (cp != ' ' and cp != '\t' and t.bad == null) {
                    t.bad = "text after a here-string's opening quote on its line";
                }
            },
            .brace => {
                if (cp == '`') {
                    t.pend = .backtick;
                } else if (cp == '}') {
                    t.pop();
                }
            },
            .line_comment => {
                if (isNewline(cp)) t.pop();
            },
            .block_comment => {
                if (cp == '#') t.pend = .hash;
            },
        }
        return .consumed;
    }

    fn code(t: *Tracker, cp: u21) Step {
        const glued_ok = !t.word or t.cmd == .expr;
        switch (cp) {
            '\n', '\r' => {
                t.word = false;
                t.cmd = .start;
            },
            ' ', '\t', 0x0B, 0x0C, 0xA0 => t.word = false,
            '`' => {
                t.beginToken(cp);
                t.pend = .backtick;
            },
            '#' => if (glued_ok) t.push(.line_comment),
            '<' => if (glued_ok) {
                t.pend = .lt;
            },
            '@' => if (glued_ok) {
                t.pend = .at;
            },
            '$' => {
                t.beginToken(cp);
                t.pend = .dollar;
            },
            '(' => {
                t.word = false;
                t.cmd = .start;
                if (t.top() == .sub) t.frames[t.len - 1].depth +|= 1;
            },
            ')' => {
                if (t.top() == .sub) {
                    const f = &t.frames[t.len - 1];
                    if (f.depth == 0) {
                        t.pop();
                        return .consumed;
                    }
                    f.depth -= 1;
                }
                t.word = false;
                if (t.cmd != .command) t.cmd = .expr;
            },
            '{', '}', ';', '|', '&' => {
                t.word = false;
                t.cmd = .start;
            },
            ',' => t.word = false,
            '=' => if (t.cmd != .command) {
                t.word = false;
                t.cmd = .start;
            } else t.beginToken(cp),
            else => {
                if (isDq(cp)) {
                    t.push(.dq);
                } else if (isSq(cp)) {
                    t.push(.sq);
                } else {
                    t.beginToken(cp);
                }
            },
        }
        return .consumed;
    }

    fn beginToken(t: *Tracker, cp: u21) void {
        if (t.word) return;
        t.word = true;
        if (t.cmd == .start) t.cmd = if (startsCommand(cp)) .command else .expr;
    }
};

fn isDq(cp: u21) bool {
    return cp == '"' or cp == 0x201C or cp == 0x201D or cp == 0x201E;
}

fn isSq(cp: u21) bool {
    return cp == '\'' or cp == 0x2018 or cp == 0x2019 or cp == 0x201A or cp == 0x201B;
}

fn isNewline(cp: u21) bool {
    return cp == '\n' or cp == '\r';
}

fn isNameChar(cp: u21) bool {
    if (cp >= 0x80) return !isDq(cp) and !isSq(cp);
    return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_' or cp == ':' or cp == '?';
}

fn startsCommand(cp: u21) bool {
    if (cp >= 0x80) return true;
    return std.ascii.isAlphabetic(@intCast(cp)) or switch (cp) {
        '_', '.', '\\', '/', '~', '`' => true,
        else => false,
    };
}

fn after(s: []const u8) types.Context {
    var t = Tracker.init();
    t.feed(s);
    return t.context();
}

fn finished(s: []const u8) ?[]const u8 {
    var t = Tracker.init();
    t.feed(s);
    return t.finish();
}

fn expectEnc(s: []const u8, enc: types.Encoding) !void {
    const c = after(s);
    if (c.refuse) |m| {
        std.debug.print("refused after {s}: {s}\n", .{ s, m });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(enc, c.enc);
}

fn expectRefused(s: []const u8, msg: []const u8) !void {
    const c = after(s);
    try std.testing.expect(c.refuse != null);
    try std.testing.expectEqualStrings(msg, c.refuse.?);
}

test "unquoted positions refuse" {
    try expectRefused("", refuse_quote);
    try expectRefused("$x = ", refuse_quote);
    try expectRefused("echo a", refuse_quote);
    try expectRefused("\"abc\"", refuse_quote);
    try expectRefused("'abc'", refuse_quote);
    try expectRefused("$x = 'a' + ", refuse_quote);
}

test "plain quotes" {
    try expectEnc("$x = \"", .ps_dq);
    try expectEnc("$x = 'a", .ps_sq);
    try expectEnc("$x = \"a\"\"b", .ps_dq);
    try expectEnc("$x = 'it''s ", .ps_sq);
    try expectEnc("echo don't", .ps_sq);
    try expectEnc("$x = 'a\"b", .ps_sq);
    try expectEnc("$x = \"a'b", .ps_dq);
    try expectEnc("$x = 'a$b", .ps_sq);
    try expectEnc("$x = 'a`", .ps_sq);
}

test "unicode quotes open and close strings" {
    try expectEnc("$x = \u{201C}abc", .ps_dq);
    try expectEnc("$x = \u{201E}abc", .ps_dq);
    try expectRefused("$x = \u{201C}abc\u{201D}", refuse_quote);
    try expectRefused("$x = \"abc\u{201D}", refuse_quote);
    try expectRefused("$x = \u{201C}abc\"", refuse_quote);
    try expectEnc("$x = \"a\u{201C}\u{201D}b", .ps_dq);
    try expectEnc("$x = \u{2018}abc", .ps_sq);
    try expectRefused("$x = \u{2018}abc\u{2019}", refuse_quote);
    try expectRefused("$x = 'abc\u{201B}", refuse_quote);
    try expectRefused("$x = \u{201A}abc'", refuse_quote);
    try expectEnc("$x = 'it\u{2019}\u{2019}s ", .ps_sq);
    try expectEnc("echo don\u{2019}t", .ps_sq);
    try expectEnc("$x = \u{2018}a\"b", .ps_sq);
}

test "backtick escapes" {
    try expectEnc("$x = \"a`\"b", .ps_dq);
    try expectEnc("$x = \"a`\u{201D}b", .ps_dq);
    try expectEnc("$x = \"a``", .ps_dq);
    try expectRefused("$x = \"a`", refuse_quote);
    try expectEnc("echo `\"a '", .ps_sq);
    try expectEnc("echo `'a \"", .ps_dq);
}

test "line comments" {
    try expectEnc("# x", .raw_line);
    try expectEnc("$x = 1 # it's", .raw_line);
    try expectRefused("# x\n", refuse_quote);
    try expectEnc("# don't\n$x = '", .ps_sq);
    try expectEnc("$x = 1#y", .raw_line);
    try expectEnc("$a#b", .raw_line);
    try expectEnc("\"x\"#y", .raw_line);
    try expectEnc("echo \"x\"#y", .raw_line);
    try expectEnc("(1)#x", .raw_line);
    try expectEnc("$( \"x\" )#y", .raw_line);
    try expectEnc("'a'#b", .raw_line);
}

test "# inside a command argument is part of the word" {
    try expectEnc("echo a#b '", .ps_sq);
    try expectEnc("echo $a#b '", .ps_sq);
    try expectEnc("echo 1#b '", .ps_sq);
    try expectEnc("echo x\"y\"#z '", .ps_sq);
    try expectEnc("echo a`#b '", .ps_sq);
    try expectEnc("echo a #b", .raw_line);
    try expectEnc("$x = echo a#b '", .ps_sq);
}

test "block comments" {
    try expectEnc("<# don't #> $x = '", .ps_sq);
    try expectEnc("<# don't ", .raw_line);
    try expectEnc("<# a\n# b \"", .raw_line);
    try expectRefused("<# don't #>", refuse_quote);
    try expectEnc("<# a ##> '", .ps_sq);
    try expectEnc("$x=1<#c#>'", .ps_sq);
    try expectEnc("echo a<#b '", .ps_sq);
    try expectEnc("echo a <#b '", .raw_line);
    try expectEnc("echo a<#b#>c <#d '", .raw_line);
    try expectEnc("<# \u{201C} ", .raw_line);
}

test "a capture after $ in an expanding context" {
    try expectRefused("$x = \"$", refuse_dollar);
    try expectRefused("$x = \"$name", refuse_dollar);
    try expectRefused("$x = \"$env:name", refuse_dollar);
    try expectRefused("$x = \"$name:", refuse_dollar);
    try expectRefused("$x = \"$?", refuse_dollar);
    try expectRefused("$x = \"$$", refuse_dollar);
    try expectRefused("$x = \"$_", refuse_dollar);
    try expectRefused("$x = @\"\n$name", refuse_dollar);
    try expectRefused("$x = @\"\n$", refuse_dollar);
    try expectEnc("$x = \"${name}", .ps_dq);
    try expectEnc("$x = \"$ ", .ps_dq);
    try expectEnc("$x = \"$name ", .ps_dq);
    try expectEnc("$x = \"$name-", .ps_dq);
    try expectEnc("$x = \"`$", .ps_dq);
    try expectEnc("$x = \"$(1)", .ps_dq);
    try expectEnc("$x = '$name", .ps_sq);
    try expectEnc("$x = @'\n$name", .ps_here_sq);
    try expectRefused("echo $name", refuse_quote);
}

test "braced variables" {
    try expectRefused("$x = \"${a", refuse_quote);
    try expectRefused("$x = \"${a\"b", refuse_quote);
    try expectEnc("$x = \"${a\"b}c", .ps_dq);
    try expectEnc("$x = \"${a`}b}c", .ps_dq);
    try expectEnc("${a'b} = '", .ps_sq);
}

test "subexpressions inside double quotes" {
    try expectRefused("$x = \"$(", refuse_quote);
    try expectRefused("$x = \"$( \"x", refuse_quote);
    try expectRefused("$x = \"$( 'x", refuse_quote);
    try expectRefused("$x = \"$( (1) ", refuse_quote);
    try expectRefused("$x = \"$( # c", refuse_quote);
    try expectEnc("$x = \"$( \"a)\" ) ", .ps_dq);
    try expectEnc("$x = \"$( 'a\"' ) ", .ps_dq);
    try expectEnc("$x = \"$( (1) ) ", .ps_dq);
    try expectEnc("$x = \"$(\"a\" + \"b\") $(\"x$(\"y\")\") ", .ps_dq);
    try expectRefused("$x = \"$(\"x$(\"y", refuse_quote);
    try expectRefused("$x = \"$(\"a\" + \"b\")\"", refuse_quote);
    try expectRefused("$x = $( \"x", refuse_quote);
    try expectEnc("$x = $( \"x\" ) + '", .ps_sq);
    try expectEnc("$x = \"$( @\"\n\"@\n) ", .ps_dq);
}

test "here-strings" {
    try expectRefused("$x = @\"", refuse_quote);
    try expectRefused("$x = @\"  ", refuse_quote);
    const c = after("$x = @\"\nabc ");
    try std.testing.expectEqual(types.Encoding.ps_here_dq, c.enc);
    try std.testing.expectEqualStrings("\"@", c.terminator);
    try std.testing.expect(c.refuse == null);
    const s = after("$x = @'\nit's ");
    try std.testing.expectEqual(types.Encoding.ps_here_sq, s.enc);
    try std.testing.expectEqualStrings("'@", s.terminator);
    try expectEnc("$x = @\"\n", .ps_here_dq);
    try expectEnc("$x = @\"\nabc\"@", .ps_here_dq);
    try expectEnc("$x = @\"\nabc\n  \"@", .ps_here_dq);
    try expectEnc("$x = @\"\nabc\n\"x", .ps_here_dq);
    try expectEnc("$x = @\"\nabc\n\"\"@", .ps_here_dq);
    try expectRefused("$x = @\"\nabc\n\"@", refuse_quote);
    try expectEnc("$x = @\"\nabc\n\"@\n$y = '", .ps_sq);
    try expectEnc("$x = @'\na'@b\n", .ps_here_sq);
    try expectRefused("$x = @'\nabc\n'@", refuse_quote);
    try expectRefused("$x = @\u{201C}\nabc\n\u{201D}@", refuse_quote);
    try expectRefused("$x = @\u{2018}\nabc\n\u{201B}@", refuse_quote);
    try expectRefused("$x = @\"\nabc\n\u{201E}@", refuse_quote);
    try expectEnc("$x = @\"\na`\n\"@", .ps_here_dq);
    try expectEnc("$x = @\"\n$(\n\"x\"\n)\n", .ps_here_dq);
    try expectRefused("$x = @\"\n$(\n\"@\n", refuse_quote);
    try expectEnc("$x = @\"\na \"b\" 'c' ", .ps_here_dq);
    try expectRefused("$x = @\"\na`", refuse_quote);
    try expectEnc("$x=@\"\n", .ps_here_dq);
    try expectEnc("echo a@\"x", .ps_dq);
    try expectRefused("$x = @\"\r\nabc\r\n\"@\r\n", refuse_quote);
    try expectEnc("$x = @\"\r\nabc\r\n", .ps_here_dq);
    try std.testing.expectEqual(null, finished("$x = @\"\r\nabc\r\n\"@\r\n"));
    try std.testing.expectEqual(null, finished("$x = @'\nabc\n'@"));
}

test "a UTF-8 sequence split across feeds" {
    const open = "$x = \u{201C}";
    var t = Tracker.init();
    for (open) |b| t.feed(&.{b});
    try std.testing.expectEqual(types.Encoding.ps_dq, t.context().enc);
    try std.testing.expect(t.context().refuse == null);

    const close = "\u{201D}";
    t.feed(close[0..1]);
    try std.testing.expect(t.context().refuse != null);
    t.feed(close[1..2]);
    try std.testing.expect(t.context().refuse != null);
    t.feed(close[2..3]);
    try std.testing.expectEqualStrings(refuse_quote, t.context().refuse.?);
    try std.testing.expectEqual(null, t.finish());

    var u = Tracker.init();
    const sq = "$x = \u{2018}abc\u{2019} + '";
    u.feed(sq[0..6]);
    u.feed(sq[6..12]);
    u.feed(sq[12..]);
    try std.testing.expectEqual(types.Encoding.ps_sq, u.context().enc);
}

test "invalid UTF-8 is plain text" {
    try expectEnc("$x = \"a\xff\xe2\x80b", .ps_dq);
    try expectEnc("$x = '\xe2\x80x", .ps_sq);
}

test "finish" {
    try std.testing.expectEqual(null, finished(""));
    try std.testing.expectEqual(null, finished("$x = \"abc\""));
    try std.testing.expectEqual(null, finished("$x = 'it''s'"));
    try std.testing.expectEqual(null, finished("$x = \u{201C}abc\u{201D}"));
    try std.testing.expectEqual(null, finished("# trailing comment"));
    try std.testing.expectEqual(null, finished("<# don't #>"));
    try std.testing.expectEqual(null, finished("$x = \"$( \"a)\" )\""));
    try std.testing.expectEqualStrings("an unclosed double-quoted string", finished("$x = \"abc").?);
    try std.testing.expectEqualStrings("an unclosed double-quoted string", finished("$x = \"abc`\"").?);
    try std.testing.expectEqualStrings("an unclosed single-quoted string", finished("$x = 'abc").?);
    try std.testing.expectEqualStrings("an unclosed single-quoted string", finished("$x = 'it''").?);
    try std.testing.expectEqualStrings("an unclosed single-quoted string", finished("<# don't #> 'it").?);
    try std.testing.expectEqualStrings("an unclosed here-string", finished("$x = @\"\nabc").?);
    try std.testing.expectEqualStrings("an unclosed here-string", finished("$x = @\"\nabc\"@").?);
    try std.testing.expectEqualStrings("an unclosed here-string", finished("$x = @'").?);
    try std.testing.expectEqualStrings("an unclosed block comment", finished("<# abc #").?);
    try std.testing.expectEqualStrings("an unclosed `$(`", finished("$x = \"$( 1").?);
    try std.testing.expectEqualStrings("an unclosed `$(`", finished("$x = \"$( # c").?);
    try std.testing.expectEqualStrings("an unclosed `${`", finished("$x = ${a").?);
    try std.testing.expectEqualStrings(
        "text after a here-string's opening quote on its line",
        finished("$x = @\" x\nabc\n\"@").?,
    );
}

test "nesting beyond the limit" {
    var t = Tracker.init();
    for (0..max_depth + 2) |_| t.feed("\"$(");
    try std.testing.expectEqualStrings("nesting deeper than 64 levels", t.finish().?);
    try std.testing.expect(t.context().refuse != null);
}

test "same" {
    var a = Tracker.init();
    a.feed("$x = \"abc ");
    var b = a;
    try std.testing.expect(Tracker.same(&a, &b));
    b.feed("value `$x `\" `` `\u{201D}");
    try std.testing.expect(Tracker.same(&a, &b));
    var c = a;
    c.feed("\"");
    try std.testing.expect(!Tracker.same(&a, &c));
    var d = a;
    d.feed("x`");
    try std.testing.expect(!Tracker.same(&a, &d));
    var e = a;
    e.feed("$");
    try std.testing.expect(!Tracker.same(&a, &e));
    var f = a;
    f.feed("$(");
    try std.testing.expect(!Tracker.same(&a, &f));
    var g = a;
    g.feed("\xe2\x80");
    try std.testing.expect(!Tracker.same(&a, &g));

    var s = Tracker.init();
    s.feed("$x = 'a");
    var s2 = s;
    s2.feed("it''s");
    try std.testing.expect(Tracker.same(&s, &s2));
    s2.feed("'");
    try std.testing.expect(!Tracker.same(&s, &s2));

    var h = Tracker.init();
    h.feed("$x = @\"\n");
    var h2 = h;
    h2.feed("line one\nline two");
    try std.testing.expect(Tracker.same(&h, &h2));
    var h3 = h;
    h3.feed("x\n\"@");
    try std.testing.expect(!Tracker.same(&h, &h3));
    var h4 = h;
    h4.feed("line\n");
    try std.testing.expect(Tracker.same(&h, &h4));
    var m = h;
    m.feed("text ");
    var m2 = m;
    m2.feed("more");
    try std.testing.expect(Tracker.same(&m, &m2));
    m2.feed("\n");
    try std.testing.expect(!Tracker.same(&m, &m2));
    try std.testing.expect(Tracker.same(&m2, &m));

    var k = Tracker.init();
    k.feed("<# a ");
    var k2 = k;
    k2.feed("b # c");
    try std.testing.expect(Tracker.same(&k, &k2));
    k2.feed(" #>");
    try std.testing.expect(!Tracker.same(&k, &k2));

    var l = Tracker.init();
    l.feed("# a ");
    var l2 = l;
    l2.feed("b\nc");
    try std.testing.expect(!Tracker.same(&l, &l2));
}
