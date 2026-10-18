//! The TOML context tracker: follows strings, comments, table headers,
//! keys, values, arrays and inline tables, so a capture's value is encoded
//! for the token it sits in.

const std = @import("std");
const types = @import("types.zig");

const Mode = enum(u8) {
    key_start,
    key_bare,
    after_key,
    value_start,
    value_bare,
    /// A full date followed by one space: a time may follow in the same token.
    value_date_space,
    after_value,
    header_open,
    header_close,
    after_header,
    open_dq1,
    open_dq2,
    open_sq1,
    open_sq2,
    basic,
    ml_basic,
    literal,
    ml_literal,
    /// `"""` or `'''` seen; up to two more quotes still belong to the string.
    ml_basic_close,
    ml_literal_close,
    comment,
};

const Header = enum(u8) { none, table, array };

const max_depth = 128;

const unclosed_string = "an unclosed TOML string";
const join_refusal = "a value here would join two TOML tokens; put it inside a string or right after `=`";
const escape_refusal = "a value right after a backslash would join a TOML escape; move it out of the escape";

pub const Tracker = struct {
    mode: Mode = .key_start,
    comment_prev: Mode = .key_start,
    header: Header = .none,
    /// The open string is a quoted key.
    is_key: bool = false,
    /// A basic string's backslash awaits its next byte.
    esc: bool = false,
    /// Multi-line strings: quotes just seen inside, or extra quotes after
    /// the closing delimiter.
    run: u8 = 0,
    depth: u16 = 0,
    /// Bit i set: nesting level i is an inline table, else an array.
    tables: u128 = 0,
    overflow: bool = false,
    /// Bytes seen outside any token's interior; a value that stays inside
    /// one token leaves it unchanged.
    bounds: u32 = 0,
    /// Progress of the bare value against `DDDD-DD-DD`; 255 once it fails.
    shape: u8 = 0,
    /// A single-line string met a newline.
    broken: bool = false,

    pub fn init() Tracker {
        return .{};
    }

    pub fn feed(t: *Tracker, bytes: []const u8) void {
        for (bytes) |c| {
            while (!t.consume(c)) {}
        }
    }

    pub fn context(t: *const Tracker) types.Context {
        return switch (t.mode) {
            .key_start, .key_bare, .header_open => .{ .enc = .toml_bare_key },
            .value_start, .value_bare, .value_date_space => .{ .enc = .toml_bare },
            .open_dq1 => .{ .enc = .toml_basic },
            .basic => if (t.esc) refused(escape_refusal) else .{ .enc = .toml_basic },
            .ml_basic => if (t.esc) refused(escape_refusal) else .{ .enc = .toml_ml_basic },
            .open_sq1, .literal => .{ .enc = .toml_literal },
            .ml_literal => .{ .enc = .toml_ml_literal },
            .comment => .{ .enc = .raw_line },
            .after_key,
            .after_value,
            .header_close,
            .after_header,
            .open_dq2,
            .open_sq2,
            .ml_basic_close,
            .ml_literal_close,
            => refused(join_refusal),
        };
    }

    /// Whether `b`, reached from `a` by feeding one value, is still inside
    /// the token `a` was in. Directional: `a` is the state before the value.
    pub fn same(a: *const Tracker, b: *const Tracker) bool {
        if (a.bounds != b.bounds or a.depth != b.depth or a.tables != b.tables or
            a.overflow != b.overflow or a.header != b.header or
            a.is_key != b.is_key or a.esc != b.esc) return false;
        if (!follows(a.mode, b.mode)) return false;
        return switch (b.mode) {
            .ml_basic, .ml_literal => b.run == 0 or b.run == a.run,
            .ml_basic_close, .ml_literal_close => b.run == a.run,
            .comment => a.comment_prev == b.comment_prev,
            else => true,
        };
    }

    /// At the start of a line outside every table header, string, array and
    /// inline table.
    pub fn atLineTop(t: *const Tracker) bool {
        return !t.broken and t.mode == .key_start and t.depth == 0;
    }

    pub fn finish(t: *const Tracker) ?[]const u8 {
        if (t.broken) return unclosed_string;
        switch (t.mode) {
            .open_dq1, .basic, .ml_basic, .open_sq1, .literal, .ml_literal => return unclosed_string,
            else => {},
        }
        if (t.overflow) return "TOML arrays or inline tables nested deeper than 128 levels";
        if (t.depth > 0) return if (t.topIsTable()) "an unclosed TOML inline table" else "an unclosed TOML array";
        const mode = if (t.mode == .comment) t.comment_prev else t.mode;
        if (t.header != .none and mode != .after_header) return "an unclosed TOML table header";
        return null;
    }

    /// Feeds one byte; false when the byte must be fed again in the new mode.
    fn consume(t: *Tracker, c: u8) bool {
        switch (t.mode) {
            .comment => {
                if (c != '\n') return true;
                t.mode = t.comment_prev;
                return false;
            },
            .basic => {
                if (c == '\n') {
                    t.broken = true;
                    t.esc = false;
                    t.endString();
                    return false;
                }
                if (t.esc) {
                    t.esc = false;
                } else if (c == '\\') {
                    t.esc = true;
                } else if (c == '"') {
                    t.endString();
                    t.bump();
                }
                return true;
            },
            .ml_basic => {
                if (t.esc) {
                    t.esc = false;
                } else if (c == '\\') {
                    t.esc = true;
                    t.run = 0;
                } else if (c == '"') {
                    if (t.run == 2) {
                        t.mode = .ml_basic_close;
                        t.run = 0;
                    } else t.run += 1;
                } else t.run = 0;
                return true;
            },
            .literal => {
                if (c == '\n') {
                    t.broken = true;
                    t.endString();
                    return false;
                }
                if (c == '\'') {
                    t.endString();
                    t.bump();
                }
                return true;
            },
            .ml_literal => {
                if (c == '\'') {
                    if (t.run == 2) {
                        t.mode = .ml_literal_close;
                        t.run = 0;
                    } else t.run += 1;
                } else t.run = 0;
                return true;
            },
            .ml_basic_close, .ml_literal_close => {
                const q: u8 = if (t.mode == .ml_basic_close) '"' else '\'';
                if (c == q and t.run < 2) {
                    t.run += 1;
                    return true;
                }
                t.run = 0;
                t.mode = .after_value;
                t.bump();
                return false;
            },
            .open_dq1 => {
                if (c == '"') {
                    t.mode = .open_dq2;
                    t.bump();
                    return true;
                }
                t.mode = .basic;
                return false;
            },
            .open_sq1 => {
                if (c == '\'') {
                    t.mode = .open_sq2;
                    t.bump();
                    return true;
                }
                t.mode = .literal;
                return false;
            },
            .open_dq2, .open_sq2 => {
                const q: u8 = if (t.mode == .open_dq2) '"' else '\'';
                if (c == q) {
                    t.mode = if (q == '"') .ml_basic else .ml_literal;
                    t.run = 0;
                    t.bump();
                    return true;
                }
                t.mode = .after_value;
                return false;
            },
            .key_start => switch (c) {
                ' ', '\t', '\r' => t.whitespace(),
                '\n' => t.newline(),
                '"' => t.openKey(.basic),
                '\'' => t.openKey(.literal),
                '[' => {
                    t.bump();
                    if (t.depth == 0 and t.header == .none) {
                        t.header = .table;
                        t.mode = .header_open;
                    }
                },
                ']' => t.closeHeader(),
                '}' => t.closeNest(c),
                '=' => t.equals(),
                '#' => t.startComment(),
                '.' => t.bump(),
                else => t.mode = .key_bare,
            },
            .key_bare => switch (c) {
                ' ', '\t', '\r' => t.whitespace(),
                '\n' => t.newline(),
                '.' => {
                    t.bump();
                    t.mode = .key_start;
                },
                '=' => t.equals(),
                ']' => t.closeHeader(),
                '}' => t.closeNest(c),
                '#' => t.startComment(),
                '"', '\'' => {
                    t.mode = .after_key;
                    return false;
                },
                else => {},
            },
            .after_key => switch (c) {
                ' ', '\t', '\r' => t.whitespace(),
                '\n' => t.newline(),
                '.' => {
                    t.bump();
                    t.mode = .key_start;
                },
                '=' => t.equals(),
                ']' => t.closeHeader(),
                '}' => t.closeNest(c),
                '#' => t.startComment(),
                '"' => t.openKey(.basic),
                '\'' => t.openKey(.literal),
                else => t.mode = .key_bare,
            },
            .header_open => {
                if (c == '[') {
                    t.bump();
                    t.header = .array;
                    t.mode = .key_start;
                    return true;
                }
                t.mode = .key_start;
                return false;
            },
            .header_close => {
                t.mode = .after_header;
                if (c != ']') return false;
                t.bump();
            },
            .after_header => switch (c) {
                '\n' => t.newline(),
                '#' => t.startComment(),
                else => t.bump(),
            },
            .value_start => switch (c) {
                ' ', '\t', '\r', ',' => t.whitespace(),
                '\n' => t.newline(),
                '"' => t.openValue(.open_dq1),
                '\'' => t.openValue(.open_sq1),
                '[' => t.push(false),
                '{' => t.push(true),
                ']', '}' => t.closeNest(c),
                '#' => t.startComment(),
                else => {
                    t.mode = .value_bare;
                    t.shape = 0;
                    t.addShape(c);
                },
            },
            .value_bare => switch (c) {
                ' ' => {
                    if (t.shape == 10) {
                        t.mode = .value_date_space;
                    } else t.whitespace();
                },
                '\t', '\r' => t.whitespace(),
                '\n' => t.newline(),
                ',' => t.separator(),
                ']', '}' => t.closeNest(c),
                '#' => t.startComment(),
                '"', '\'' => {
                    t.mode = .after_value;
                    return false;
                },
                else => t.addShape(c),
            },
            .value_date_space => {
                if (std.ascii.isDigit(c)) {
                    t.mode = .value_bare;
                    t.shape = 255;
                    return true;
                }
                t.mode = .after_value;
                t.bump();
                return false;
            },
            .after_value => switch (c) {
                '\n' => t.newline(),
                ',' => t.separator(),
                ']', '}' => t.closeNest(c),
                '#' => t.startComment(),
                '"' => t.openValue(.open_dq1),
                '\'' => t.openValue(.open_sq1),
                else => t.bump(),
            },
        }
        return true;
    }

    fn bump(t: *Tracker) void {
        t.bounds +%= 1;
    }

    fn whitespace(t: *Tracker) void {
        t.bump();
        t.mode = switch (t.mode) {
            .key_bare => .after_key,
            .value_bare => .after_value,
            else => t.mode,
        };
    }

    /// A line end outside strings: a new key line at top level, plain
    /// whitespace inside arrays and inline tables.
    fn newline(t: *Tracker) void {
        if (t.depth == 0 or t.header != .none) {
            t.bump();
            t.mode = .key_start;
            t.header = .none;
            return;
        }
        t.whitespace();
    }

    fn startComment(t: *Tracker) void {
        t.bump();
        t.comment_prev = t.mode;
        t.mode = .comment;
    }

    fn openKey(t: *Tracker, mode: Mode) void {
        t.bump();
        t.is_key = true;
        t.mode = mode;
    }

    fn openValue(t: *Tracker, mode: Mode) void {
        t.bump();
        t.is_key = false;
        t.mode = mode;
    }

    fn endString(t: *Tracker) void {
        t.mode = if (t.is_key) .after_key else .after_value;
        t.is_key = false;
    }

    fn equals(t: *Tracker) void {
        t.bump();
        if (t.header == .none) t.mode = .value_start;
    }

    fn closeHeader(t: *Tracker) void {
        t.bump();
        switch (t.header) {
            .none => {},
            .table => t.mode = .after_header,
            .array => t.mode = .header_close,
        }
    }

    fn separator(t: *Tracker) void {
        t.bump();
        if (t.depth == 0) {
            t.mode = .after_value;
        } else t.mode = if (t.topIsTable()) .key_start else .value_start;
    }

    fn push(t: *Tracker, table: bool) void {
        t.bump();
        if (t.depth < max_depth) {
            const bit = @as(u128, 1) << @intCast(t.depth);
            if (table) t.tables |= bit else t.tables &= ~bit;
        } else t.overflow = true;
        t.depth +|= 1;
        t.mode = if (table) .key_start else .value_start;
    }

    fn closeNest(t: *Tracker, c: u8) void {
        t.bump();
        t.mode = .after_value;
        if (t.depth == 0) return;
        if ((c == '}') != t.topIsTable()) return;
        t.depth -= 1;
        if (t.depth < max_depth) t.tables &= ~(@as(u128, 1) << @intCast(t.depth));
    }

    fn topIsTable(t: *const Tracker) bool {
        if (t.depth == 0 or t.depth > max_depth) return false;
        return t.tables & (@as(u128, 1) << @intCast(t.depth - 1)) != 0;
    }

    fn addShape(t: *Tracker, c: u8) void {
        if (t.shape >= 10) {
            t.shape = 255;
            return;
        }
        const ok = if (t.shape == 4 or t.shape == 7) c == '-' else std.ascii.isDigit(c);
        t.shape = if (ok) t.shape + 1 else 255;
    }
};

fn refused(why: []const u8) types.Context {
    return .{ .enc = .raw, .refuse = why };
}

/// Whether mode `b` is `a` or the interior of the token `a` starts.
fn follows(a: Mode, b: Mode) bool {
    if (a == b) return true;
    return switch (a) {
        .key_start => b == .key_bare,
        .header_open => b == .key_start or b == .key_bare,
        .value_start, .value_date_space => b == .value_bare,
        .open_dq1 => b == .basic,
        .open_sq1 => b == .literal,
        else => false,
    };
}

const testing = std.testing;

fn fed(text: []const u8) Tracker {
    var t = Tracker.init();
    t.feed(text);
    return t;
}

fn expectEnc(text: []const u8, enc: types.Encoding) !void {
    const ctx = fed(text).context();
    testing.expectEqual(enc, ctx.enc) catch |e| {
        std.debug.print("text: {s}\n", .{text});
        return e;
    };
    try testing.expect(ctx.refuse == null);
}

fn expectRefused(text: []const u8) !void {
    const ctx = fed(text).context();
    testing.expect(ctx.refuse != null) catch |e| {
        std.debug.print("text: {s}\n", .{text});
        return e;
    };
}

fn keeps(prefix: []const u8, value: []const u8) bool {
    const a = fed(prefix);
    var b = a;
    b.feed(value);
    return Tracker.same(&a, &b);
}

test "key positions" {
    try expectEnc("", .toml_bare_key);
    try expectEnc("ab", .toml_bare_key);
    try expectEnc("a.", .toml_bare_key);
    try expectEnc("a . ", .toml_bare_key);
    try expectEnc("x = 1\n", .toml_bare_key);
    try expectEnc("x = 1\n  ", .toml_bare_key);
    try expectEnc("\"a\".", .toml_bare_key);
}

test "quoted keys" {
    try expectEnc("\"", .toml_basic);
    try expectEnc("\"a b", .toml_basic);
    try expectEnc("'", .toml_literal);
    try expectEnc("a.'b", .toml_literal);
    try expectEnc("\"\" = ", .toml_bare);
    try expectEnc("\"k\" = \"", .toml_basic);
}

test "value positions" {
    try expectEnc("a = ", .toml_bare);
    try expectEnc("a=", .toml_bare);
    try expectEnc("a = 80", .toml_bare);
    try expectEnc("a.b = ", .toml_bare);
    try expectEnc("d = 1979-05-27 ", .toml_bare);
}

test "strings" {
    try expectEnc("a = \"", .toml_basic);
    try expectEnc("a = \"x", .toml_basic);
    try expectEnc("a = \"\"\"", .toml_ml_basic);
    try expectEnc("a = \"\"\"\nx\n", .toml_ml_basic);
    try expectEnc("a = '", .toml_literal);
    try expectEnc("a = 'x", .toml_literal);
    try expectEnc("a = '''", .toml_ml_literal);
    try expectEnc("a = '''\nx\ny ''", .toml_ml_literal);
    try expectEnc("a = \"\"\nb = ", .toml_bare);
    try expectEnc("a = ''\nb = ", .toml_bare);
}

test "comments" {
    try expectEnc("# c", .raw_line);
    try expectEnc("a = 1 # c", .raw_line);
    try expectEnc("a = 1# c", .raw_line);
    try expectEnc("[t] # c", .raw_line);
    try expectEnc("a = 1 # x = \"\nb = ", .toml_bare);
    try expectEnc("# \"\"\" '\n", .toml_bare_key);
    try expectEnc("a = [ # c\n", .toml_bare);
    try expectEnc("a = \"# not a comment", .toml_basic);
}

test "positions that join tokens are refused" {
    try expectRefused("a = 1 ");
    try expectRefused("a = \"x\"");
    try expectRefused("a = \"x\" ");
    try expectRefused("a = \"\"");
    try expectRefused("a = \"\"\"x\"\"\"");
    try expectRefused("a ");
    try expectRefused("\"a\"");
    try expectRefused("[a]");
    try expectRefused("[[a]");
    try expectRefused("[[a]]");
    try expectRefused("a = [1 ");
    try expectRefused("a = \"\\");
    try expectRefused("a = \"\"\"\\");
}

test "escapes in basic strings" {
    try expectEnc("a = \"x\\\"y", .toml_basic);
    try expectEnc("a = \"x\\\\", .toml_basic);
    try expectRefused("a = \"x\\\\\"");
    try expectEnc("a = \"\"\"x\\\"\"\"", .toml_ml_basic);
    try expectEnc("a = \"\"\"x \\\n  y", .toml_ml_basic);
    try expectEnc("a = 'x\\'\nb = ", .toml_bare);
}

test "quotes inside multi-line strings" {
    try expectEnc("a = \"\"\"x\"", .toml_ml_basic);
    try expectEnc("a = \"\"\"x\"\"", .toml_ml_basic);
    try expectRefused("a = \"\"\"x\"\"\"");
    try expectEnc("a = \"\"\"x\"\"\"\"\nb = ", .toml_bare);
    try expectEnc("a = \"\"\"x\"\"\"\"\"\nb = ", .toml_bare);
    try expectEnc("a = '''x''\n", .toml_ml_literal);
    try expectEnc("a = '''x'''''\nb = ", .toml_bare);
    try testing.expect(fed("a = \"\"\"x\"\"\"\"\"").finish() == null);
    try testing.expect(fed("a = '''x'''''").finish() == null);
}

test "multi-line strings span lines" {
    try expectEnc("a = \"\"\"\nline1\nb = \"x\"\n# no\n", .toml_ml_basic);
    try expectEnc("a = \"\"\"\nline1\n\"\"\"\nb = ", .toml_bare);
    try expectEnc("a = '''\n[t]\n'''\n[t]\nc = ", .toml_bare);
}

test "arrays and inline tables" {
    try expectEnc("a = [", .toml_bare);
    try expectEnc("a = [1, ", .toml_bare);
    try expectEnc("a = [1, [2, 3], ", .toml_bare);
    try expectEnc("a = [\n  1,\n  ", .toml_bare);
    try expectEnc("a = [1]\n", .toml_bare_key);
    try expectEnc("a = [\"x\", \"", .toml_basic);
    try expectEnc("a = {", .toml_bare_key);
    try expectEnc("a = { b = ", .toml_bare);
    try expectEnc("a = { b = 1, ", .toml_bare_key);
    try expectEnc("a = { b.c = 1, d.", .toml_bare_key);
    try expectEnc("a = { b = { c = 1 }, ", .toml_bare_key);
    try expectEnc("a = { b = 1 }\n", .toml_bare_key);
    try expectEnc("a = [{ x = \"y\" }, ", .toml_bare);
    try expectEnc("a = [{ x = [1, 2] }, { ", .toml_bare_key);
    try expectEnc("a = {}\nb = ", .toml_bare);
    try expectEnc("a = []\nb = ", .toml_bare);
    try expectEnc("a = { 'k' = '", .toml_literal);
}

test "table headers" {
    try expectEnc("[", .toml_bare_key);
    try expectEnc("[[", .toml_bare_key);
    try expectEnc("[a.", .toml_bare_key);
    try expectEnc("[ a . ", .toml_bare_key);
    try expectEnc("[a.\"", .toml_basic);
    try expectEnc("[[a.'", .toml_literal);
    try expectEnc("[a]\n", .toml_bare_key);
    try expectEnc("[a] # c\n", .toml_bare_key);
    try expectEnc("[[a.b]]\nc = ", .toml_bare);
    try expectEnc("[ \"a b\" . c ]\nd = ", .toml_bare);
    try expectEnc("a = [\n[1],\n", .toml_bare);
}

test "a value inside a string keeps the state" {
    try testing.expect(keeps("a = \"", "secret"));
    try testing.expect(keeps("a = \"pre", "secret"));
    try testing.expect(keeps("a = \"", "x\\\"y"));
    try testing.expect(keeps("a = \"", ""));
    try testing.expect(!keeps("a = \"", "x\"y"));
    try testing.expect(!keeps("a = \"", "x\""));
    try testing.expect(!keeps("a = \"", "x\\"));
    try testing.expect(!keeps("a = \"", "x\ny"));
    try testing.expect(!keeps("a = \"", "\""));
    try testing.expect(keeps("a = '", "x y"));
    try testing.expect(!keeps("a = '", "x'"));
    try testing.expect(!keeps("a = '", "x\ny"));
    try testing.expect(keeps("\"", "key"));
    try testing.expect(!keeps("\"", "k\" = 1"));
}

test "a value inside a multi-line string keeps the state" {
    try testing.expect(keeps("a = \"\"\"", "x\ny"));
    try testing.expect(keeps("a = \"\"\"\n", "x\\\"\\\"\\\"y"));
    try testing.expect(keeps("a = \"\"\"say \"", "hi"));
    try testing.expect(keeps("a = \"\"\"say \"\"", "hi"));
    try testing.expect(!keeps("a = \"\"\"", "x\""));
    try testing.expect(!keeps("a = \"\"\"", "x\"\"\""));
    try testing.expect(!keeps("a = \"\"\"x\"\"", "\""));
    try testing.expect(keeps("a = '''", "x\n'y''z"));
    try testing.expect(!keeps("a = '''", "x'''"));
    try testing.expect(!keeps("a = '''", "x'"));
}

test "a bare value stays one token" {
    try testing.expect(keeps("a = ", "8080"));
    try testing.expect(keeps("a = 80", "80"));
    try testing.expect(keeps("a = ", "true"));
    try testing.expect(keeps("a = ", "1979-05-27T07:32:00Z"));
    try testing.expect(keeps("d = ", "1979-05-27 07:32:00"));
    try testing.expect(keeps("d = 1979-05-27 ", "07:32:00"));
    try testing.expect(keeps("a = [", "1"));
    try testing.expect(keeps("a = [1, ", "2"));
    try testing.expect(!keeps("a = ", "1 2"));
    try testing.expect(!keeps("a = ", " 1"));
    try testing.expect(!keeps("a = ", "1 "));
    try testing.expect(!keeps("a = ", "1\nb = 2"));
    try testing.expect(!keeps("a = ", "1 # c"));
    try testing.expect(!keeps("a = ", "\"q\""));
    try testing.expect(!keeps("a = [", "1, 2"));
    try testing.expect(!keeps("a = [", "1,2"));
    try testing.expect(!keeps("a = [", "1]"));
    try testing.expect(!keeps("a = { b = ", "1, c = 2"));
    try testing.expect(!keeps("a = ", "[1]"));
    try testing.expect(!keeps("d = ", "1979-05-27 x"));
}

test "a bare key stays one token" {
    try testing.expect(keeps("", "key"));
    try testing.expect(keeps("a.", "b"));
    try testing.expect(keeps("ke", "y"));
    try testing.expect(keeps("[", "tbl"));
    try testing.expect(keeps("[[", "tbl"));
    try testing.expect(keeps("a = {", "k"));
    try testing.expect(keeps("a = { x = 1, ", "k"));
    try testing.expect(!keeps("", "a.b"));
    try testing.expect(!keeps("", "a b"));
    try testing.expect(!keeps("", "a = 1"));
    try testing.expect(!keeps("[", "[x"));
    try testing.expect(!keeps("[", "x]"));
    try testing.expect(!keeps("", "\"a\""));
}

test "a value inside a comment keeps the state" {
    try testing.expect(keeps("# c ", "x \"y' = [{"));
    try testing.expect(keeps("a = 1 # ", "x"));
    try testing.expect(!keeps("# c ", "x\ny"));
}

test "finish" {
    const full =
        \\# top
        \\title = "x \" y"
        \\[owner]
        \\name = 'Tom'
        \\dob = 1979-05-27 07:32:00-08:00
        \\[[products]]
        \\a = [1, [2, 3], { b = "c" }]
        \\s = """
        \\multi "" line
        \\"""""
        \\l = '''
        \\raw ''x'' '''
        \\t = { x.y = 1, 'z' = [
        \\  1, # c
        \\] }
        \\
    ;
    try testing.expect(fed(full).finish() == null);
    try testing.expectEqual(.key_start, fed(full).mode);
    try testing.expect(fed("").finish() == null);
    try testing.expect(fed("a = \"x\"").finish() == null);
    try testing.expect(fed("a = \"\"").finish() == null);
    try testing.expect(fed("[a]").finish() == null);
    try testing.expect(fed("[a] # c").finish() == null);
    try testing.expect(fed("a = 1 # c").finish() == null);
    try testing.expect(fed("a = \"\"\"x\"\"\"").finish() == null);
    try testing.expectEqualStrings(unclosed_string, fed("a = \"").finish().?);
    try testing.expectEqualStrings(unclosed_string, fed("a = \"x").finish().?);
    try testing.expectEqualStrings(unclosed_string, fed("a = \"x\\").finish().?);
    try testing.expectEqualStrings(unclosed_string, fed("a = \"\"\"x\n").finish().?);
    try testing.expectEqualStrings(unclosed_string, fed("a = \"\"\"x\"\"").finish().?);
    try testing.expectEqualStrings(unclosed_string, fed("a = 'x").finish().?);
    try testing.expectEqualStrings(unclosed_string, fed("a = '''x\n''").finish().?);
    try testing.expectEqualStrings(unclosed_string, fed("a = \"x\nb = 1\n").finish().?);
    try testing.expectEqualStrings(unclosed_string, fed("a = 'x\nb = 1\n").finish().?);
    try testing.expectEqualStrings(unclosed_string, fed("\"k").finish().?);
    try testing.expectEqualStrings("an unclosed TOML array", fed("a = [1, 2").finish().?);
    try testing.expectEqualStrings("an unclosed TOML inline table", fed("a = { b = 1").finish().?);
    try testing.expectEqualStrings("an unclosed TOML array", fed("a = { b = [").finish().?);
    try testing.expectEqualStrings("an unclosed TOML table header", fed("[a").finish().?);
    try testing.expectEqualStrings("an unclosed TOML table header", fed("[[a]").finish().?);
}

test "deep nesting is reported" {
    var t = Tracker.init();
    t.feed("a = ");
    for (0..200) |_| t.feed("[");
    for (0..200) |_| t.feed("]");
    try testing.expectEqual(@as(u16, 0), t.depth);
    try testing.expect(t.finish() != null);
}

test "feeding in pieces matches feeding at once" {
    const text = "a = \"\"\"x\"\"\"\"\"\n[[t]]\nd = 1979-05-27 07:32:00\nb = [{ c = 'x' }, # c\n 2]\n";
    const whole = fed(text);
    var bytes = Tracker.init();
    for (text) |c| bytes.feed(&.{c});
    try testing.expect(std.meta.eql(whole, bytes));
    try testing.expect(whole.finish() == null);
    try testing.expectEqual(.key_start, whole.mode);
}

test "the tracker is a value type" {
    const a = fed("a = \"x");
    var b = a;
    b.feed("\"");
    try testing.expectEqual(.basic, a.mode);
    try testing.expectEqual(.after_value, b.mode);
}
