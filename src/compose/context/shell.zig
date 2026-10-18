//! The lexical context of a position in a POSIX shell (sh, bash, zsh) or
//! fish file. The tracker follows quotes, escapes, comments, heredocs,
//! `${...}`, `$(...)`, backticks and arithmetic, not a grammar: syntax a
//! shell adds outside those contexts (zsh's `fpath=(...)`, glob qualifiers)
//! is plain text to it.

const std = @import("std");
const types = @import("types.zig");
const Context = types.Context;

pub const Dialect = enum { posix, fish };

const max_depth = 32;
const max_terminator = 64;
const max_heredocs = 4;

const msg_quote = "quote it in the source; mox writes a value only inside plain quotes, a heredoc, or as a plain word";
const msg_param_posix = "write `${NAME}`";
const msg_param_fish = "end the quote after the variable, as in `\"$NAME\"\"<capture>\"`";

const FrameKind = enum(u8) { top, dq, sq, dollar_sq, brace, cmdsub, backtick, arith, heredoc };

const Frame = struct {
    kind: FrameKind,
    /// `cmdsub` and `arith`: open parentheses; `brace`: open plain braces.
    nest: u16 = 0,
    /// `cmdsub`: open `case ... esac`.
    cases: u16 = 0,
};

/// Lookahead across bytes that may arrive in separate feeds.
const Pend = enum(u8) {
    none,
    /// After `$`.
    dollar,
    /// After `$(`: arithmetic when the next byte is `(`.
    dollar_paren,
    /// After one or two `<`.
    lt1,
    lt2,
    /// After `(` in command position: arithmetic when the next byte is `(`.
    paren1,
    /// After the first `)` that closes arithmetic.
    arith_close,
};

/// Where a `$` parameter reference stands, for the rule that a value must
/// not directly follow an unbraced parameter.
const Dollar = enum(u8) {
    none,
    /// A `$` with nothing after it yet.
    bare,
    /// `$name`, `$1`.
    name,
    /// `$?`, `$#`, `$$`, ...
    special,
    /// After a subscript closed: `$a[1]`.
    after,
    /// zsh modifiers: `$name:h`.
    mod,
    /// Inside a subscript: `$a[...`.
    sub,
};

const Delim = enum(u8) { none, blank, word, sq, dq, esc };

const Heredoc = struct {
    buf: [max_terminator]u8 = [_]u8{0} ** max_terminator,
    len: u8 = 0,
    strip: bool = false,
    quoted: bool = false,

    fn text(h: *const Heredoc) []const u8 {
        return h.buf[0..h.len];
    }
};

pub const Tracker = struct {
    dialect: Dialect,
    broken: ?[]const u8 = null,
    stack: [max_depth]Frame = [_]Frame{.{ .kind = .top }} ** max_depth,
    depth: u8 = 1,
    escape: bool = false,
    comment: bool = false,
    pend: Pend = .none,
    dol: Dollar = .none,
    dol_sub: u8 = 0,
    /// The current top-level unquoted word holds an unquoted `{` or `}`.
    word_brace: bool = false,
    /// fish: the current top-level unquoted word starts with `%`.
    word_percent: bool = false,

    /// Heredocs whose operator was read; `heredocs[0]` is the one whose
    /// body is being read while `body` is set.
    heredocs: [max_heredocs]Heredoc = [_]Heredoc{.{}} ** max_heredocs,
    n_heredoc: u8 = 0,
    body: bool = false,
    delim: Delim = .none,

    // Positional state below: `same` compares it only by direction.
    at_word_start: bool = true,
    cmd_pos: bool = true,
    word: [5]u8 = [_]u8{0} ** 5,
    word_len: u8 = 0,
    word_cmd: bool = false,
    /// Word boundaries crossed; a value must cross none.
    word_seq: u32 = 0,
    /// The previous byte was an unquoted `(`: a `#` after it is not a
    /// comment (zsh `(#i)`).
    after_paren: bool = false,
    /// Heredoc body: lines read, whether the current line can still be
    /// the terminator, and how many of its bytes matched (tabs included).
    hd_lines: u32 = 0,
    hd_live: bool = false,
    hd_lead: bool = false,
    hd_match: u8 = 0,
    hd_col: u8 = 0,

    pub fn init(dialect: Dialect) Tracker {
        return .{ .dialect = dialect };
    }

    pub fn feed(t: *Tracker, bytes: []const u8) void {
        for (bytes) |c| t.step(c);
    }

    pub fn context(t: *const Tracker) Context {
        const fish = t.dialect == .fish;
        if (t.broken) |why| return refuse(why);
        if (t.delim != .none) return refuse(msg_quote);
        if (t.depth > 2) return refuse(msg_quote);
        const kind = t.stack[t.depth - 1].kind;
        switch (kind) {
            .top, .dq, .sq, .heredoc => {},
            else => return refuse(msg_quote),
        }
        switch (t.pend) {
            .none, .lt1, .paren1 => {},
            .dollar => return refuse(if (fish) msg_param_fish else msg_param_posix),
            else => return refuse(msg_quote),
        }
        switch (t.dol) {
            .none => {},
            .sub => return refuse(msg_quote),
            else => return refuse(if (fish) msg_param_fish else msg_param_posix),
        }
        if (t.escape) return refuse(msg_quote);
        return switch (kind) {
            .top => if (t.comment)
                .{ .enc = .raw_line }
            else if (t.word_brace or t.word_percent)
                refuse(msg_quote)
            else
                .{ .enc = if (fish) .fish_word else .sh_word },
            .dq => .{ .enc = if (fish) .fish_dq else .sh_dq },
            .sq => .{ .enc = if (fish) .fish_sq else .sh_sq },
            .heredoc => blk: {
                const h = &t.heredocs[0];
                break :blk .{
                    .enc = if (h.quoted) .sh_heredoc_quoted else .sh_heredoc,
                    .terminator = h.text(),
                    .strip_tabs = h.strip,
                };
            },
            else => unreachable,
        };
    }

    /// Whether `b`, the state after a value was fed at `a`, is in the same
    /// lexical context as `a`. A value may move from the start of a word,
    /// line or string into its interior; any other change fails.
    pub fn same(a: *const Tracker, b: *const Tracker) bool {
        if (a.dialect != b.dialect) return false;
        if ((a.broken == null) != (b.broken == null)) return false;
        if (a.depth != b.depth) return false;
        for (a.stack[0..a.depth], b.stack[0..b.depth]) |x, y| {
            if (x.kind != y.kind or x.nest != y.nest or x.cases != y.cases) return false;
        }
        if (a.escape != b.escape or a.comment != b.comment) return false;
        if (normPend(a.pend) != normPend(b.pend)) return false;
        if (a.dol != b.dol) return false;
        if (a.dol == .sub and a.dol_sub != b.dol_sub) return false;
        if (a.word_brace != b.word_brace or a.word_percent != b.word_percent) return false;
        if (a.n_heredoc != b.n_heredoc or a.body != b.body or a.delim != b.delim) return false;
        const n = a.n_heredoc + @intFromBool(a.delim != .none);
        for (a.heredocs[0..n], b.heredocs[0..n]) |*x, *y| {
            if (x.strip != y.strip or x.quoted != y.quoted) return false;
            if (!std.mem.eql(u8, x.text(), y.text())) return false;
        }
        if (a.word_seq != b.word_seq) return false;
        if (!a.at_word_start and b.at_word_start) return false;
        if (a.body and b.hd_live and b.hd_col > 0 and
            (b.hd_lines != a.hd_lines or b.hd_col != a.hd_col)) return false;
        return true;
    }

    pub fn finish(t: *const Tracker) ?[]const u8 {
        if (t.broken) |why| return why;
        if (t.delim != .none) return "a heredoc operator without its terminator";
        switch (t.pend) {
            .dollar_paren => return "an unclosed `$(`",
            .arith_close => return "an unclosed arithmetic expansion",
            else => {},
        }
        var depth = t.depth;
        var pending = t.n_heredoc;
        // A terminator on the last line, without a line break after it.
        if (t.body and depth > 1 and t.stack[depth - 1].kind == .heredoc and
            t.hd_live and t.hd_match == t.heredocs[0].len)
        {
            depth -= 1;
            pending -= 1;
        }
        if (depth > 1) return switch (t.stack[depth - 1].kind) {
            .dq => "an unclosed double quote",
            .sq => "an unclosed single quote",
            .dollar_sq => "an unclosed `$'`",
            .brace => "an unclosed `${`",
            .cmdsub => if (t.dialect == .fish) "an unclosed command substitution" else "an unclosed `$(`",
            .backtick => "an unclosed backtick",
            .arith => "an unclosed arithmetic expansion",
            .heredoc => "an unclosed heredoc",
            .top => unreachable,
        };
        if (pending > 0) return "an unclosed heredoc";
        return null;
    }

    fn refuse(why: []const u8) Context {
        return .{ .enc = .raw, .refuse = why };
    }

    fn normPend(p: Pend) Pend {
        return switch (p) {
            .lt1, .paren1 => .none,
            else => p,
        };
    }

    fn top(t: *Tracker) *Frame {
        return &t.stack[t.depth - 1];
    }

    fn fail(t: *Tracker, why: []const u8) void {
        if (t.broken == null) t.broken = why;
    }

    fn push(t: *Tracker, kind: FrameKind) void {
        if (t.depth == max_depth) return t.fail("nesting deeper than 32 levels");
        t.stack[t.depth] = .{ .kind = kind };
        t.depth += 1;
        if (kind == .cmdsub) {
            t.at_word_start = true;
            t.cmd_pos = true;
            t.word_len = 0;
        }
    }

    fn pop(t: *Tracker) void {
        t.depth -= 1;
    }

    fn insideDq(t: *const Tracker) bool {
        for (t.stack[0..t.depth]) |f| if (f.kind == .dq) return true;
        return false;
    }

    fn step(t: *Tracker, c: u8) void {
        if (t.broken != null) return;
        if (t.delim != .none) return t.delimByte(c);
        if (t.escape) {
            t.escape = false;
            t.after_paren = false;
            t.at_word_start = false;
            t.word_len = 255;
            if (t.top().kind == .heredoc) {
                t.hd_live = false;
                t.hd_lead = false;
            }
            return;
        }
        if (t.comment) {
            if (c != '\n') return;
            t.comment = false;
        }
        if (t.pend != .none) {
            if (t.resolvePend(c)) return;
            return t.step(c);
        }
        if (c == '\n') {
            if (t.body and t.top().kind != .heredoc)
                return t.fail("a line break inside an expansion in a heredoc body");
            t.dol = .none;
        }
        t.dolByte(c);
        if (t.dialect == .fish) {
            switch (t.top().kind) {
                .top, .cmdsub => t.fishUnquoted(c),
                .dq => t.fishDq(c),
                .sq => t.fishSq(c),
                else => unreachable,
            }
            return;
        }
        switch (t.top().kind) {
            .top, .cmdsub => t.unquoted(c),
            .dq => t.dq(c),
            .sq => if (c == '\'') t.pop(),
            .dollar_sq => switch (c) {
                '\\' => t.escape = true,
                '\'' => t.pop(),
                else => {},
            },
            .brace => t.brace(c),
            .backtick => switch (c) {
                '\\' => t.escape = true,
                '`' => t.pop(),
                else => {},
            },
            .arith => t.arith(c),
            .heredoc => t.heredocByte(c),
        }
    }

    /// Resolves the lookahead; false when `c` must be processed again.
    fn resolvePend(t: *Tracker, c: u8) bool {
        const p = t.pend;
        t.pend = .none;
        const fish = t.dialect == .fish;
        switch (p) {
            .none => return false,
            .dollar => {
                if (t.dol == .bare) t.dol = .none;
                const kind = t.top().kind;
                const unquoted_level = switch (kind) {
                    .top, .cmdsub, .brace, .backtick, .arith => true,
                    else => false,
                };
                switch (c) {
                    '{' => if (!fish) {
                        t.push(.brace);
                        return true;
                    },
                    '(' => {
                        if (fish) t.push(.cmdsub) else t.pend = .dollar_paren;
                        return true;
                    },
                    '\'' => if (!fish and unquoted_level) {
                        t.push(.dollar_sq);
                        return true;
                    },
                    '"' => if (!fish and unquoted_level) {
                        t.push(.dq);
                        return true;
                    },
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => {
                        if (t.dol != .sub) t.dol = .name;
                        return true;
                    },
                    '$' => if (fish) {
                        if (t.dol != .sub) t.dol = .bare;
                        t.pend = .dollar;
                        return true;
                    },
                    else => {},
                }
                if (!fish) switch (c) {
                    '?', '#', '@', '*', '!', '$', '-' => {
                        if (t.dol != .sub) t.dol = .special;
                        return true;
                    },
                    else => {},
                };
                return false;
            },
            .dollar_paren => {
                if (c == '(') {
                    t.push(.arith);
                    return true;
                }
                t.push(.cmdsub);
                return false;
            },
            .lt1 => {
                if (c == '<') {
                    t.pend = .lt2;
                    return true;
                }
                return false;
            },
            .lt2 => {
                if (c == '<') return true;
                t.startDelim(c == '-');
                return c == '-';
            },
            .paren1 => {
                if (c == '(') {
                    t.push(.arith);
                    return true;
                }
                if (t.top().kind == .cmdsub) t.top().nest += 1;
                return false;
            },
            .arith_close => {
                if (c == ')') {
                    t.pop();
                    return true;
                }
                t.fail("an arithmetic expansion mox cannot follow");
                return true;
            },
        }
    }

    fn dolByte(t: *Tracker, c: u8) void {
        const posix = t.dialect == .posix;
        switch (t.dol) {
            .none, .bare => {},
            .name, .special, .after => {
                if (t.dol != .after and isNameChar(c)) {
                    t.dol = .name;
                } else if (c == '[') {
                    t.dol = .sub;
                    t.dol_sub = 1;
                } else if (c == ':' and posix) {
                    t.dol = .mod;
                } else t.dol = .none;
            },
            .mod => if (!(std.ascii.isAlphanumeric(c) or c == ':')) {
                t.dol = .none;
            },
            .sub => switch (c) {
                '[' => t.dol_sub +|= 1,
                ']' => {
                    t.dol_sub -= 1;
                    if (t.dol_sub == 0) t.dol = .after;
                },
                else => {},
            },
        }
    }

    fn startDollar(t: *Tracker) void {
        t.pend = .dollar;
        if (t.dol != .sub) t.dol = .bare;
    }

    /// Ends the current word: a `case`/`esac` keyword in command position
    /// inside `$(...)` opens or closes a case, and reserved words keep the
    /// next word in command position.
    fn endWord(t: *Tracker) void {
        if (t.word_len == 0) return;
        const was_cmd = t.word_cmd;
        const w = if (t.word_len <= t.word.len) t.word[0..t.word_len] else "";
        t.word_len = 0;
        t.word_cmd = false;
        t.cmd_pos = false;
        if (!was_cmd) return;
        const f = t.top();
        if (std.mem.eql(u8, w, "case")) {
            if (f.kind == .cmdsub) f.cases += 1;
        } else if (std.mem.eql(u8, w, "esac")) {
            if (f.kind == .cmdsub and f.cases > 0) f.cases -= 1;
        } else {
            const reserved = [_][]const u8{ "if", "then", "else", "elif", "do", "while", "until", "for", "time", "!", "{" };
            for (reserved) |r| if (std.mem.eql(u8, w, r)) {
                t.cmd_pos = true;
            };
        }
    }

    /// A byte that is part of a word at command level.
    fn wordByte(t: *Tracker, c: u8, plain: bool) void {
        if (t.at_word_start) {
            t.at_word_start = false;
            t.word_cmd = t.cmd_pos;
            t.word_len = 0;
            if (t.depth == 1) {
                t.word_brace = false;
                t.word_percent = t.dialect == .fish and c == '%';
            }
        }
        if (plain and t.word_len < t.word.len) {
            t.word[t.word_len] = c;
            t.word_len += 1;
        } else t.word_len = 255;
        if (t.depth == 1 and (c == '{' or c == '}')) t.word_brace = true;
    }

    /// A byte that ends a word; `cmd` when the next word is a command.
    fn boundary(t: *Tracker, cmd: bool) void {
        t.endWord();
        t.at_word_start = true;
        t.word_seq +%= 1;
        if (t.depth == 1) {
            t.word_brace = false;
            t.word_percent = false;
        }
        if (cmd) t.cmd_pos = true;
    }

    fn newline(t: *Tracker) void {
        t.boundary(true);
        if (t.n_heredoc > 0 and !t.body) t.beginBody();
    }

    fn unquoted(t: *Tracker, c: u8) void {
        const after_paren = t.after_paren;
        t.after_paren = c == '(';
        const f = t.top();
        switch (c) {
            ' ', '\t' => t.boundary(false),
            '\n' => t.newline(),
            ';', '&', '|' => t.boundary(true),
            '>' => t.boundary(false),
            '<' => {
                t.boundary(false);
                t.pend = .lt1;
            },
            '#' => if (t.at_word_start and !after_paren) {
                t.comment = true;
            } else t.wordByte(c, false),
            '(' => {
                const cmd = t.cmd_pos and t.at_word_start;
                if (t.at_word_start) t.endWord();
                if (!t.at_word_start) t.wordByte(c, false);
                if (cmd) {
                    t.pend = .paren1;
                } else if (f.kind == .cmdsub) f.nest += 1;
                if (f.kind == .cmdsub) {
                    t.at_word_start = true;
                    t.cmd_pos = true;
                }
            },
            ')' => {
                if (f.kind == .cmdsub) {
                    t.endWord();
                    if (f.nest > 0) {
                        f.nest -= 1;
                    } else if (f.cases > 0) {
                        t.cmd_pos = true;
                    } else {
                        t.pop();
                        t.at_word_start = false;
                        return;
                    }
                    t.at_word_start = true;
                } else t.wordByte(c, false);
            },
            '"' => {
                t.wordByte(c, false);
                t.push(.dq);
            },
            '\'' => {
                t.wordByte(c, false);
                t.push(.sq);
            },
            '`' => {
                t.wordByte(c, false);
                t.push(.backtick);
            },
            '\\' => {
                t.wordByte(c, false);
                t.escape = true;
            },
            '$' => {
                t.wordByte(c, false);
                t.startDollar();
            },
            else => t.wordByte(c, true),
        }
    }

    fn dq(t: *Tracker, c: u8) void {
        switch (c) {
            '"' => t.pop(),
            '\\' => t.escape = true,
            '$' => t.startDollar(),
            '`' => t.push(.backtick),
            else => {},
        }
    }

    fn brace(t: *Tracker, c: u8) void {
        const f = t.top();
        switch (c) {
            '{' => f.nest += 1,
            '}' => if (f.nest > 0) {
                f.nest -= 1;
            } else t.pop(),
            '"' => t.push(.dq),
            '\'' => if (t.insideDq())
                t.fail("a single quote inside `${...}` in double quotes, which shells read differently")
            else
                t.push(.sq),
            '\\' => t.escape = true,
            '$' => t.startDollar(),
            '`' => t.push(.backtick),
            else => {},
        }
    }

    fn arith(t: *Tracker, c: u8) void {
        const f = t.top();
        switch (c) {
            '(' => f.nest += 1,
            ')' => if (f.nest > 0) {
                f.nest -= 1;
            } else {
                t.pend = .arith_close;
            },
            '"' => t.push(.dq),
            '\'' => t.push(.sq),
            '\\' => t.escape = true,
            '$' => t.startDollar(),
            '`' => t.push(.backtick),
            else => {},
        }
    }

    fn beginBody(t: *Tracker) void {
        t.push(.heredoc);
        t.body = true;
        t.hd_lines = 0;
        t.lineStart();
    }

    fn lineStart(t: *Tracker) void {
        t.hd_live = true;
        t.hd_lead = true;
        t.hd_match = 0;
        t.hd_col = 0;
    }

    fn heredocByte(t: *Tracker, c: u8) void {
        const h = &t.heredocs[0];
        if (c == '\n') {
            if (t.hd_live and t.hd_match == h.len) return t.endBody();
            t.hd_lines +|= 1;
            t.lineStart();
            return;
        }
        if (t.hd_live) {
            if (t.hd_lead and h.strip and c == '\t') {
                t.hd_col +|= 1;
            } else {
                t.hd_lead = false;
                if (t.hd_match < h.len and h.buf[t.hd_match] == c) {
                    t.hd_match += 1;
                    t.hd_col +|= 1;
                } else t.hd_live = false;
            }
        }
        if (h.quoted) return;
        switch (c) {
            '\\' => t.escape = true,
            '$' => t.startDollar(),
            '`' => t.push(.backtick),
            else => {},
        }
    }

    fn endBody(t: *Tracker) void {
        t.pop();
        var i: usize = 1;
        while (i < t.n_heredoc) : (i += 1) t.heredocs[i - 1] = t.heredocs[i];
        t.n_heredoc -= 1;
        t.heredocs[t.n_heredoc] = .{};
        t.body = false;
        t.hd_live = false;
        t.at_word_start = true;
        t.cmd_pos = true;
        if (t.n_heredoc > 0) t.beginBody();
    }

    fn startDelim(t: *Tracker, strip: bool) void {
        if (t.n_heredoc == max_heredocs) return t.fail("more than 4 heredocs pending on one line");
        t.heredocs[t.n_heredoc] = .{ .strip = strip };
        t.delim = .blank;
    }

    fn delimByte(t: *Tracker, c: u8) void {
        const h = &t.heredocs[t.n_heredoc];
        switch (t.delim) {
            .none => unreachable,
            .blank => switch (c) {
                ' ', '\t' => {},
                '\n', ';', '&', '|', '<', '>', '(', ')' => t.fail("a heredoc operator without its terminator"),
                else => {
                    t.delim = .word;
                    t.delimByte(c);
                },
            },
            .word => switch (c) {
                '\'' => {
                    h.quoted = true;
                    t.delim = .sq;
                },
                '"' => {
                    h.quoted = true;
                    t.delim = .dq;
                },
                '\\' => {
                    h.quoted = true;
                    t.delim = .esc;
                },
                ' ', '\t', '\n', ';', '&', '|', '<', '>', '(', ')' => {
                    t.delim = .none;
                    if (h.len == 0) return t.fail("a heredoc operator without its terminator");
                    t.n_heredoc += 1;
                    t.at_word_start = true;
                    t.step(c);
                },
                else => t.delimAppend(c),
            },
            .sq => if (c == '\'') {
                t.delim = .word;
            } else t.delimAppend(c),
            .dq => if (c == '"') {
                t.delim = .word;
            } else t.delimAppend(c),
            .esc => {
                t.delim = .word;
                t.delimAppend(c);
            },
        }
    }

    fn delimAppend(t: *Tracker, c: u8) void {
        const h = &t.heredocs[t.n_heredoc];
        if (h.len == max_terminator) return t.fail("a heredoc terminator longer than 64 bytes");
        h.buf[h.len] = c;
        h.len += 1;
    }

    fn fishUnquoted(t: *Tracker, c: u8) void {
        const after_paren = t.after_paren;
        t.after_paren = c == '(';
        switch (c) {
            ' ', '\t', '>', '<' => t.boundary(false),
            '\n' => t.boundary(true),
            ';', '&', '|' => t.boundary(true),
            '#' => if (t.at_word_start and !after_paren) {
                t.comment = true;
            } else t.wordByte(c, false),
            '(' => {
                t.wordByte(c, false);
                t.push(.cmdsub);
                t.at_word_start = true;
                t.cmd_pos = true;
            },
            ')' => if (t.top().kind == .cmdsub) {
                t.endWord();
                t.pop();
                t.at_word_start = false;
            } else t.wordByte(c, false),
            '"' => {
                t.wordByte(c, false);
                t.push(.dq);
            },
            '\'' => {
                t.wordByte(c, false);
                t.push(.sq);
            },
            '\\' => {
                t.wordByte(c, false);
                t.escape = true;
            },
            '$' => {
                t.wordByte(c, false);
                t.startDollar();
            },
            else => t.wordByte(c, true),
        }
    }

    fn fishDq(t: *Tracker, c: u8) void {
        switch (c) {
            '"' => t.pop(),
            '\\' => t.escape = true,
            '$' => t.startDollar(),
            else => {},
        }
    }

    fn fishSq(t: *Tracker, c: u8) void {
        switch (c) {
            '\'' => t.pop(),
            '\\' => t.escape = true,
            else => {},
        }
    }

    fn isNameChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};

// Tests

fn ctxAfter(dialect: Dialect, text: []const u8) Context {
    var t = Tracker.init(dialect);
    t.feed(text);
    return t.context();
}

fn expectEnc(dialect: Dialect, text: []const u8, enc: types.Encoding) !void {
    const c = ctxAfter(dialect, text);
    if (c.refuse) |why| {
        std.debug.print("unexpected refusal after {s}: {s}\n", .{ text, why });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(enc, c.enc);
}

fn expectRefuse(dialect: Dialect, text: []const u8, why: []const u8) !void {
    const c = ctxAfter(dialect, text);
    try std.testing.expect(c.refuse != null);
    try std.testing.expectEqualStrings(why, c.refuse.?);
}

fn finishOf(dialect: Dialect, text: []const u8) ?[]const u8 {
    var t = Tracker.init(dialect);
    t.feed(text);
    return t.finish();
}

/// Feeds `pre`, inserts `value`, feeds `post`; checks `same` across the
/// value and returns the context at the capture.
fn sameAcross(dialect: Dialect, pre: []const u8, value: []const u8) bool {
    var t = Tracker.init(dialect);
    t.feed(pre);
    const before = t;
    t.feed(value);
    return before.same(&t);
}

test "posix quotes" {
    try expectEnc(.posix, "export A=\"x", .sh_dq);
    try expectEnc(.posix, "export A='x", .sh_sq);
    try expectEnc(.posix, "export A=", .sh_word);
    try expectEnc(.posix, "echo a 'b' \"c\" ", .sh_word);
    try expectEnc(.posix, "echo \"a\\\"b", .sh_dq);
    try expectEnc(.posix, "echo 'a\\'", .sh_word);
    try expectRefuse(.posix, "echo \"a\\", msg_quote);
    try expectRefuse(.posix, "echo a\\", msg_quote);
}

test "posix comments" {
    try expectEnc(.posix, "# it's a comment ", .raw_line);
    try expectEnc(.posix, "echo a # x\n", .sh_word);
    try expectEnc(.posix, "echo a#b ", .sh_word);
    try expectEnc(.posix, "echo a#b'", .sh_sq);
    try expectEnc(.posix, "echo \"#\" '", .sh_sq);
    try expectEnc(.posix, "echo $# '", .sh_sq);
    try expectRefuse(.posix, "x=$(echo # c\n", msg_quote);
    try expectEnc(.posix, "ls (#i)x '", .sh_sq);
    try expectEnc(.posix, "x=$( (#i) )'", .sh_sq);
    try expectEnc(.fish, "echo (#x) '", .fish_sq);
}

test "dollar-single quotes" {
    try expectRefuse(.posix, "echo $'a", msg_quote);
    try expectRefuse(.posix, "echo $'a\\'b", msg_quote);
    try expectEnc(.posix, "echo $'a\\'b' ", .sh_word);
    try expectEnc(.posix, "echo $'a\\'b' \"", .sh_dq);
    try expectEnc(.posix, "echo \"$'", .sh_dq);
    try expectEnc(.posix, "echo \"$'\" '", .sh_sq);
    try expectEnc(.posix, "echo $\"loc", .sh_dq);
}

test "parameter expansion" {
    try expectRefuse(.posix, "echo ${X:-", msg_quote);
    try expectRefuse(.posix, "echo \"${X:-", msg_quote);
    try expectRefuse(.posix, "echo ${X:-\"", msg_quote);
    try expectEnc(.posix, "echo ${X:-\"}\"} ", .sh_word);
    try expectEnc(.posix, "echo ${X:-{a}}\"", .sh_dq);
    try expectEnc(.posix, "echo ${HOME}", .sh_word);
    try expectEnc(.posix, "echo \"${HOME}", .sh_dq);
    try std.testing.expect(finishOf(.posix, "echo ${X") != null);
    try std.testing.expect(finishOf(.posix, "echo \"${X:-'}'}\"") != null);
}

test "unbraced parameter before a capture" {
    try expectRefuse(.posix, "echo $HOME", msg_param_posix);
    try expectRefuse(.posix, "echo \"$HOME", msg_param_posix);
    try expectRefuse(.posix, "echo $", msg_param_posix);
    try expectRefuse(.posix, "echo \"$", msg_param_posix);
    try expectRefuse(.posix, "echo $1", msg_param_posix);
    try expectRefuse(.posix, "echo \"$?", msg_param_posix);
    try expectRefuse(.posix, "echo $$", msg_param_posix);
    try expectRefuse(.posix, "PATH=$PATH:", msg_param_posix);
    try expectRefuse(.posix, "echo \"$H:h", msg_param_posix);
    try expectRefuse(.posix, "echo \"$a[1]", msg_param_posix);
    try expectRefuse(.posix, "echo \"$a[", msg_quote);
    try expectEnc(.posix, "echo $HOME/", .sh_word);
    try expectEnc(.posix, "echo \"$HOME ", .sh_dq);
    try expectEnc(.posix, "PATH=$PATH:/bin:", .sh_word);
    try expectEnc(.posix, "echo '$HOME", .sh_sq);
    try expectRefuse(.fish, "echo $HOME", msg_param_fish);
    try expectRefuse(.fish, "echo \"$HOME", msg_param_fish);
    try expectRefuse(.fish, "echo $", msg_param_fish);
    try expectRefuse(.fish, "echo \"$a[2]", msg_param_fish);
    try expectEnc(.fish, "echo \"$HOME:", .fish_dq);
    try expectEnc(.fish, "echo '$HOME", .fish_sq);
}

test "heredoc parameter rule" {
    try expectRefuse(.posix, "cat <<E\n$HOME", msg_param_posix);
    try expectEnc(.posix, "cat <<'E'\n$HOME", .sh_heredoc_quoted);
}

test "command substitution and case" {
    try expectRefuse(.posix, "x=$(echo ", msg_quote);
    try expectRefuse(.posix, "x=\"$(echo \"", msg_quote);
    try expectEnc(.posix, "x=$(echo a) ", .sh_word);
    try expectEnc(.posix, "x=$(case $y in x) echo a;; esac) \"", .sh_dq);
    try expectRefuse(.posix, "x=$(case $y in x) echo ", msg_quote);
    try expectEnc(.posix, "x=$(case $y in (x) echo a;; *) b;; esac)\"", .sh_dq);
    try expectEnc(.posix, "x=$(case $y in\n x) (echo a);;\n esac\n)\n\"", .sh_dq);
    try expectEnc(.posix, "x=$(echo case x) '", .sh_sq);
    try expectEnc(.posix, "x=$(echo \"(\" ) '", .sh_sq);
    try expectEnc(.posix, "x=$( (a) ) '", .sh_sq);
    try std.testing.expect(finishOf(.posix, "x=$(echo") != null);
    try std.testing.expect(finishOf(.posix, "x=$(case a in a) b;; esac)") == null);
}

test "backticks" {
    try expectRefuse(.posix, "x=`echo ", msg_quote);
    try expectRefuse(.posix, "x=\"`echo ", msg_quote);
    try expectEnc(.posix, "x=`echo \\` a` \"", .sh_dq);
    try expectEnc(.posix, "x=\"a `echo \"x\"` ", .sh_dq);
    try std.testing.expect(finishOf(.posix, "x=`a") != null);
    try expectEnc(.fish, "echo `x` '", .fish_sq);
    try expectEnc(.fish, "echo `", .fish_word);
    try std.testing.expect(finishOf(.fish, "echo `x") == null);
}

test "arithmetic" {
    try expectRefuse(.posix, "echo $((1 + ", msg_quote);
    try expectEnc(.posix, "echo $((a<<3)) \"", .sh_dq);
    try expectEnc(.posix, "echo $(( (a+1)*2 )) '", .sh_sq);
    try expectRefuse(.posix, "((x = ", msg_quote);
    try expectEnc(.posix, "((x <<= 2)); y='", .sh_sq);
    try expectEnc(.posix, "if ((x)); then y='", .sh_sq);
    try expectEnc(.posix, "x=$(((1)))'", .sh_sq);
    try std.testing.expect(finishOf(.posix, "echo $((1") != null);
}

test "here-strings are not heredocs" {
    try expectEnc(.posix, "cat <<< ", .sh_word);
    try expectEnc(.posix, "cat <<<\"", .sh_dq);
    try expectEnc(.posix, "cat <<< word\n'", .sh_sq);
    try std.testing.expect(finishOf(.posix, "cat <<< EOF\necho hi\n") == null);
}

test "heredocs" {
    {
        const c = ctxAfter(.posix, "cat <<EOF\nline ");
        try std.testing.expectEqual(types.Encoding.sh_heredoc, c.enc);
        try std.testing.expectEqualStrings("EOF", c.terminator);
        try std.testing.expect(!c.strip_tabs);
    }
    {
        const c = ctxAfter(.posix, "cat <<-'END'\n\tline\n\t");
        try std.testing.expectEqual(types.Encoding.sh_heredoc_quoted, c.enc);
        try std.testing.expectEqualStrings("END", c.terminator);
        try std.testing.expect(c.strip_tabs);
    }
    try expectEnc(.posix, "cat <<-EOF\n\tbody\n\tEOF\nx='", .sh_sq);
    try expectEnc(.posix, "cat <<EOF\n\tEOF\n", .sh_heredoc);
    try expectEnc(.posix, "cat <<\"E F\"\nx\n", .sh_heredoc_quoted);
    try expectEnc(.posix, "cat <<E\\OF\n", .sh_heredoc_quoted);
    try expectEnc(.posix, "cat <<EOF | grep 'x'\nit's\nEOF\necho \"", .sh_dq);
    try expectEnc(.posix, "cat <<EOF # it's\nbody 'x\n", .sh_heredoc);
    try expectEnc(.posix, "cat <<A <<B\na\nA\nb ", .sh_heredoc);
    try expectEnc(.posix, "cat <<A <<B\na\nA\nb\nB\n'", .sh_sq);
    try expectRefuse(.posix, "cat <<EOF\n$(echo ", msg_quote);
    try expectRefuse(.posix, "cat <<EOF\n${X:-", msg_quote);
    try expectRefuse(.posix, "cat <<", msg_quote);
    try expectRefuse(.posix, "cat <<-", msg_quote);
    try expectRefuse(.posix, "x=$(cat <<EOF\n", msg_quote);
    try expectEnc(.posix, "x=$(cat <<EOF\nbody)\nEOF\n)'", .sh_sq);
    try std.testing.expect(finishOf(.posix, "cat <<EOF\nbody\n") != null);
    try std.testing.expect(finishOf(.posix, "cat <<EOF\nbody\nEOF") == null);
    try std.testing.expect(finishOf(.posix, "cat <<EOF\nbody\nEOF\n") == null);
    try std.testing.expect(finishOf(.posix, "cat <<EOF\nbody\n EOF\n") != null);
    try std.testing.expect(finishOf(.posix, "cat <<EOF\n$(a\nb)\nEOF\n") != null);
}

test "heredoc terminator too long" {
    var t = Tracker.init(.posix);
    t.feed("x='");
    try std.testing.expectEqual(types.Encoding.sh_sq, t.context().enc);
    t.feed("'\ncat <<" ++ "T" ** 65 ++ "\n");
    try std.testing.expect(t.finish() != null);
    try std.testing.expect(t.context().refuse != null);
    try std.testing.expect(finishOf(.posix, "cat <<" ++ "T" ** 64 ++ "\nx\n" ++ "T" ** 64 ++ "\n") == null);
}

test "brace expansion words" {
    try expectRefuse(.posix, "echo {a,b}", msg_quote);
    try expectRefuse(.posix, "echo a{", msg_quote);
    try expectRefuse(.posix, "echo x}", msg_quote);
    try expectEnc(.posix, "echo {a,b} ", .sh_word);
    try expectEnc(.posix, "echo '{'", .sh_word);
    try expectEnc(.posix, "echo \\{", .sh_word);
    try expectEnc(.posix, "f() { echo ", .sh_word);
    try expectRefuse(.fish, "echo {$HOME}", msg_quote);
    try expectRefuse(.fish, "echo a{b,", msg_quote);
    try expectEnc(.fish, "echo {a,b} ", .fish_word);
}

test "fish percent words" {
    try expectRefuse(.fish, "echo %", msg_quote);
    try expectRefuse(.fish, "echo %se", msg_quote);
    try expectEnc(.fish, "echo x%", .fish_word);
    try expectEnc(.fish, "echo '%'", .fish_word);
    try expectEnc(.posix, "echo %", .sh_word);
}

test "fish quotes" {
    try expectEnc(.fish, "set -x A \"", .fish_dq);
    try expectEnc(.fish, "set -x A '", .fish_sq);
    try expectEnc(.fish, "set -x A ", .fish_word);
    try expectEnc(.fish, "# it's ", .raw_line);
    try expectEnc(.fish, "echo 'a\\'b' ", .fish_word);
    try expectEnc(.fish, "echo 'a\\'b'; set x \"", .fish_dq);
    try expectEnc(.fish, "echo 'a\\\\' \"", .fish_dq);
    try expectRefuse(.fish, "echo 'a\\", msg_quote);
    try expectEnc(.fish, "echo \"a\\\"b", .fish_dq);
    try expectEnc(.posix, "echo 'a\\'b' ", .sh_sq);
}

test "fish command substitution" {
    try expectRefuse(.fish, "set x (echo ", msg_quote);
    try expectRefuse(.fish, "set x (echo \"", msg_quote);
    try expectRefuse(.fish, "set x \"$(echo ", msg_quote);
    try expectEnc(.fish, "set x (echo \")\") \"", .fish_dq);
    try expectEnc(.fish, "set x \"(\" '", .fish_sq);
    try std.testing.expect(finishOf(.fish, "set x (echo") != null);
}

test "fish has no heredocs, dollar-quotes or braces expansions" {
    try expectEnc(.fish, "cat <<EOF\n'", .fish_sq);
    try expectEnc(.fish, "echo $'", .fish_sq);
    try expectRefuse(.fish, "echo ${", msg_quote);
}

test "zsh syntax outside quotes" {
    const text =
        \\fpath=(${HOME}/.zfunc ${fpath})
        \\autoload -Uz ${HOME}/.zfunc/*(.,@:t)
        \\setopt extendedglob
        \\print -l *(#qN.)
        \\typeset -A m; m=(a 1 b 2)
        \\export LANG="
    ;
    try expectEnc(.posix, text, .sh_dq);
    var t = Tracker.init(.posix);
    t.feed(text);
    t.feed("en_US.UTF-8\"\n");
    try std.testing.expect(t.finish() == null);
}

test "finish reports unclosed constructs" {
    try std.testing.expect(finishOf(.posix, "echo \"abc") != null);
    try std.testing.expect(finishOf(.posix, "echo 'abc") != null);
    try std.testing.expect(finishOf(.posix, "echo $'abc") != null);
    try std.testing.expect(finishOf(.fish, "echo \"abc") != null);
    try std.testing.expect(finishOf(.fish, "echo 'a\\'") != null);
    try std.testing.expect(finishOf(.posix, "echo a # 'x") == null);
    try std.testing.expect(finishOf(.posix, "") == null);
    try std.testing.expectEqualStrings("an unclosed double quote", finishOf(.posix, "x=\"").?);
}

test "same: values that keep the context" {
    try std.testing.expect(sameAcross(.posix, "export A=\"", "va\\$l\\\"ue\nx"));
    try std.testing.expect(sameAcross(.posix, "export A='", "value"));
    try std.testing.expect(sameAcross(.posix, "export A=", "value"));
    try std.testing.expect(sameAcross(.posix, "echo ", "value"));
    try std.testing.expect(sameAcross(.posix, "sort <", "file"));
    try std.testing.expect(sameAcross(.posix, "# c ", "text"));
    try std.testing.expect(sameAcross(.posix, "cat <<EOF\n", "line one\nline two\n"));
    try std.testing.expect(sameAcross(.posix, "cat <<EOF\nab ", "cd"));
    try std.testing.expect(sameAcross(.fish, "set a \"", "x\\$y"));
    try std.testing.expect(sameAcross(.fish, "set a '", "it\\'s"));
}

test "same: values that change the context" {
    try std.testing.expect(!sameAcross(.posix, "export A=\"", "x\"y"));
    try std.testing.expect(!sameAcross(.posix, "export A='", "it's"));
    try std.testing.expect(!sameAcross(.posix, "export A=", "a b"));
    try std.testing.expect(!sameAcross(.posix, "export A=", "x;y"));
    try std.testing.expect(sameAcross(.posix, "export A=", "x#y"));
    try std.testing.expect(!sameAcross(.posix, "export A=\"", "$(x"));
    try std.testing.expect(!sameAcross(.posix, "export A=\"", "${x"));
    try std.testing.expect(!sameAcross(.posix, "export A=\"", "x\\"));
    try std.testing.expect(!sameAcross(.posix, "# c ", "x\ny"));
    try std.testing.expect(!sameAcross(.posix, "cat <<EOF\n", "a\nEOF\n"));
    try std.testing.expect(!sameAcross(.posix, "cat <<EOF\n", "E"));
    try std.testing.expect(!sameAcross(.posix, "cat <<EOF\nEO", "F"));
    try std.testing.expect(!sameAcross(.posix, "cat <<-EOF\n", "\t"));
    try std.testing.expect(!sameAcross(.fish, "set a '", "it's"));
    try std.testing.expect(!sameAcross(.posix, "echo a", "{b,c}"));
    // Directional: from inside a word back to a word start splits it.
    var a = Tracker.init(.posix);
    a.feed("echo x");
    var b = Tracker.init(.posix);
    b.feed("echo x ");
    try std.testing.expect(!a.same(&b));
}

test "split feeds match a single feed" {
    const text = "x=$((1<<2)) y=\"${a:-b}\" z=$'q' <<-E\n\tb\n\tE\n'";
    var whole = Tracker.init(.posix);
    whole.feed(text);
    var parts = Tracker.init(.posix);
    for (text) |c| parts.feed(&[_]u8{c});
    try std.testing.expect(whole.same(&parts) and parts.same(&whole));
    try std.testing.expectEqual(types.Encoding.sh_sq, parts.context().enc);
}
