//! TOML statements as a parser sees them: table headers and key/value
//! assignments are recognized only at statement position, never inside an
//! open multi-line string, a multi-line array or an inline table, and each
//! statement spans every line its value takes.
//!
//! Malformed text never fails the scan: a line that starts no statement is
//! skipped, an unterminated single-line string ends at the end of its line,
//! and an unterminated multi-line string, array or inline table runs to the
//! end of the text. Only nesting arrays and inline tables deeper than
//! `max_depth` fails it, as the TOML parser does.

const std = @import("std");

/// Array and inline-table nesting the scan follows: the TOML parser's limit,
/// so every document that parses also scans.
pub const max_depth: usize = 128;

pub const Error = std.mem.Allocator.Error || error{NestingTooDeep};

/// Byte range `[start, end)` of the scanned text.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn of(s: Span, src: []const u8) []const u8 {
        return src[s.start..s.end];
    }
};

pub const Statement = struct {
    kind: Kind,
    /// From the statement's first byte to the end of its closing bracket or
    /// its value; a trailing comment is not part of it.
    span: Span,
    /// The key path as written: inside a header's brackets, or before an
    /// assignment's `=`, without surrounding blanks.
    key_span: Span,
    /// The key path, each segment decoded: `"a.b".c` is `a.b`, `c`.
    key: []const []const u8,
    /// An assignment's value as written, every line of it; empty for a
    /// header.
    value_span: Span = .{ .start = 0, .end = 0 },
    /// The comments inside an assignment's value (an array's or an inline
    /// table's), in order.
    value_comments: []const Span = &.{},

    pub const Kind = enum { table, array_table, assignment };

    /// The value's text with the comments inside it cut out.
    pub fn valueText(st: Statement, arena: std.mem.Allocator, src: []const u8) ![]const u8 {
        if (st.value_comments.len == 0) return st.value_span.of(src);
        var out: std.ArrayList(u8) = .empty;
        var at = st.value_span.start;
        for (st.value_comments) |c| {
            try out.appendSlice(arena, src[at..c.start]);
            at = c.end;
        }
        try out.appendSlice(arena, src[at..st.value_span.end]);
        return out.toOwnedSlice(arena);
    }
};

/// Every statement of `src`, in order.
pub fn scan(arena: std.mem.Allocator, src: []const u8) Error![]const Statement {
    var s: Scanner = .{ .arena = arena, .src = src };
    var out: std.ArrayList(Statement) = .empty;
    while (true) {
        s.skipBlankLines();
        if (s.i >= src.len) break;
        const start = s.i;
        if (src[s.i] == '[') {
            const kind: Statement.Kind = if (std.mem.startsWith(u8, src[s.i..], "[[")) .array_table else .table;
            s.i += if (kind == .array_table) 2 else 1;
            s.skipSpaces();
            const key_start = s.i;
            const key = try s.keyPath() orelse {
                s.skipLine();
                continue;
            };
            const key_end = s.i;
            s.skipSpaces();
            const close = if (kind == .array_table) "]]" else "]";
            if (!std.mem.startsWith(u8, src[s.i..], close)) {
                s.skipLine();
                continue;
            }
            s.i += close.len;
            try out.append(arena, .{
                .kind = kind,
                .span = .{ .start = start, .end = s.i },
                .key_span = .{ .start = key_start, .end = key_end },
                .key = key,
            });
            s.skipLine();
            continue;
        }
        const key = try s.keyPath() orelse {
            s.skipLine();
            continue;
        };
        const key_end = s.i;
        s.skipSpaces();
        if (s.i >= src.len or src[s.i] != '=') {
            s.skipLine();
            continue;
        }
        s.i += 1;
        s.skipSpaces();
        var comments: std.ArrayList(Span) = .empty;
        const value_start = s.i;
        try s.value(&comments);
        try out.append(arena, .{
            .kind = .assignment,
            .span = .{ .start = start, .end = s.i },
            .key_span = .{ .start = start, .end = key_end },
            .key = key,
            .value_span = .{ .start = value_start, .end = s.i },
            .value_comments = try comments.toOwnedSlice(arena),
        });
        s.skipLine();
    }
    return out.toOwnedSlice(arena);
}

/// One `[[stem]]` table: its header and its own assignments.
pub const Row = struct {
    header: Statement,
    body: []const Statement,
};

/// The `row`-th `[[stem]]` header of `stmts` and the statements of the table
/// it opens, which ends at the next header of any kind.
pub fn arrayTableRow(stmts: []const Statement, stem: []const u8, row: usize) ?Row {
    var seen: usize = 0;
    for (stmts, 0..) |st, i| {
        if (st.kind != .array_table or st.key.len != 1 or !std.mem.eql(u8, st.key[0], stem)) continue;
        if (seen < row) {
            seen += 1;
            continue;
        }
        var end = i + 1;
        while (end < stmts.len and stmts[end].kind == .assignment) end += 1;
        return .{ .header = st, .body = stmts[i + 1 .. end] };
    }
    return null;
}

const Scanner = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    i: usize = 0,
    /// Arrays and inline tables open around `i`.
    depth: usize = 0,

    fn at(s: *const Scanner, c: u8) bool {
        return s.i < s.src.len and s.src[s.i] == c;
    }

    fn skipSpaces(s: *Scanner) void {
        while (s.i < s.src.len and (s.src[s.i] == ' ' or s.src[s.i] == '\t')) s.i += 1;
    }

    /// Past blanks, newlines and whole-line comments.
    fn skipBlankLines(s: *Scanner) void {
        while (s.i < s.src.len) {
            switch (s.src[s.i]) {
                ' ', '\t', '\r', '\n' => s.i += 1,
                '#' => s.toEol(),
                else => return,
            }
        }
    }

    fn toEol(s: *Scanner) void {
        s.i = std.mem.indexOfScalarPos(u8, s.src, s.i, '\n') orelse s.src.len;
    }

    /// Past whatever follows a statement on its last line.
    fn skipLine(s: *Scanner) void {
        s.toEol();
        if (s.i < s.src.len) s.i += 1;
    }

    /// Blanks, newlines and comments inside an array or inline table, each
    /// comment recorded.
    fn skipInside(s: *Scanner, comments: *std.ArrayList(Span)) !void {
        while (s.i < s.src.len) {
            switch (s.src[s.i]) {
                ' ', '\t', '\r', '\n' => s.i += 1,
                '#' => {
                    const start = s.i;
                    s.toEol();
                    try comments.append(s.arena, .{ .start = start, .end = s.i });
                },
                else => return,
            }
        }
    }

    /// A dotted key path, each segment decoded, or null when none starts
    /// here. Leaves `i` just past the last segment.
    fn keyPath(s: *Scanner) !?[]const []const u8 {
        var segments: std.ArrayList([]const u8) = .empty;
        while (true) {
            const seg = try s.keySegment() orelse return null;
            try segments.append(s.arena, seg);
            const end = s.i;
            s.skipSpaces();
            if (!s.at('.')) {
                s.i = end;
                return try segments.toOwnedSlice(s.arena);
            }
            s.i += 1;
            s.skipSpaces();
        }
    }

    fn keySegment(s: *Scanner) !?[]const u8 {
        if (s.at('"')) {
            const start = s.i + 1;
            s.basicString();
            if (s.i == start or s.src[s.i - 1] != '"') return null;
            return try decodeBasic(s.arena, s.src[start .. s.i - 1]);
        }
        if (s.at('\'')) {
            const start = s.i + 1;
            s.literalString();
            if (s.i == start or s.src[s.i - 1] != '\'') return null;
            return s.src[start .. s.i - 1];
        }
        const start = s.i;
        while (s.i < s.src.len and isBareKeyChar(s.src[s.i])) s.i += 1;
        return if (s.i == start) null else s.src[start..s.i];
    }

    /// Past one value, every line of it.
    fn value(s: *Scanner, comments: *std.ArrayList(Span)) Error!void {
        const rest = s.src[s.i..];
        if (std.mem.startsWith(u8, rest, "\"\"\"")) return s.multiLine('"');
        if (std.mem.startsWith(u8, rest, "'''")) return s.multiLine('\'');
        if (s.at('"')) return s.basicString();
        if (s.at('\'')) return s.literalString();
        if (s.at('[')) return s.container(']', comments);
        if (s.at('{')) return s.container('}', comments);
        const start = s.i;
        while (s.i < s.src.len and std.mem.indexOfScalar(u8, "\r\n#,]}", s.src[s.i]) == null) s.i += 1;
        while (s.i > start and (s.src[s.i - 1] == ' ' or s.src[s.i - 1] == '\t')) s.i -= 1;
    }

    /// An array (`close` is `]`) or inline table (`}`): values, and in an
    /// inline table their keys and `=`, separated by commas, blanks,
    /// newlines and comments, nested to any depth.
    fn container(s: *Scanner, close: u8, comments: *std.ArrayList(Span)) Error!void {
        if (s.depth >= max_depth) return error.NestingTooDeep;
        s.depth += 1;
        defer s.depth -= 1;
        s.i += 1;
        while (true) {
            try s.skipInside(comments);
            if (s.i >= s.src.len) return;
            const c = s.src[s.i];
            if (c == close) {
                s.i += 1;
                return;
            }
            if (c == ',') {
                s.i += 1;
                continue;
            }
            const before = s.i;
            if (close == '}') {
                if (try s.keyPath() != null) {
                    s.skipSpaces();
                    if (s.at('=')) {
                        s.i += 1;
                        s.skipSpaces();
                    }
                }
            }
            try s.value(comments);
            if (s.i == before) s.i += 1;
        }
    }

    /// A single-line basic string from its opening quote; unterminated, it
    /// ends at the end of its line, a line ending in `\` included, since only
    /// a multi-line string continues past one.
    fn basicString(s: *Scanner) void {
        s.i += 1;
        while (s.i < s.src.len) : (s.i += 1) {
            switch (s.src[s.i]) {
                '\\' => if (s.i + 1 < s.src.len and s.src[s.i + 1] != '\n') {
                    s.i += 1;
                },
                '"' => {
                    s.i += 1;
                    return;
                },
                '\n' => return,
                else => {},
            }
        }
    }

    fn literalString(s: *Scanner) void {
        s.i += 1;
        while (s.i < s.src.len) : (s.i += 1) {
            switch (s.src[s.i]) {
                '\'' => {
                    s.i += 1;
                    return;
                },
                '\n' => return,
                else => {},
            }
        }
    }

    /// A multi-line string from its opening delimiter: it closes at the
    /// first run of three or more `quote`s not escaped, and up to two quotes
    /// of a longer run belong to the content.
    fn multiLine(s: *Scanner, quote: u8) void {
        s.i += 3;
        while (s.i < s.src.len) {
            const c = s.src[s.i];
            if (quote == '"' and c == '\\') {
                s.i = @min(s.i + 2, s.src.len);
                continue;
            }
            if (c == quote) {
                var run: usize = 0;
                while (s.i + run < s.src.len and s.src[s.i + run] == quote) run += 1;
                s.i += run;
                if (run >= 3) return;
                continue;
            }
            s.i += 1;
        }
    }
};

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// The text a basic string's body stands for; an escape it does not know is
/// kept as written.
fn decodeBasic(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, body, '\\') == null) return body;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\' or i + 1 >= body.len) {
            try out.append(arena, body[i]);
            continue;
        }
        i += 1;
        const simple: ?u8 = switch (body[i]) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0c,
            'r' => '\r',
            'e' => 0x1b,
            '"' => '"',
            '\\' => '\\',
            else => null,
        };
        if (simple) |c| {
            try out.append(arena, c);
            continue;
        }
        const digits: usize = switch (body[i]) {
            'x' => 2,
            'u' => 4,
            'U' => 8,
            else => 0,
        };
        const cp = if (digits > 0 and i + digits < body.len)
            std.fmt.parseInt(u21, body[i + 1 .. i + 1 + digits], 16) catch null
        else
            null;
        if (cp) |code| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(code, &buf) catch {
                try out.appendSlice(arena, body[i - 1 .. i + 1]);
                continue;
            };
            try out.appendSlice(arena, buf[0..n]);
            i += digits;
            continue;
        }
        try out.appendSlice(arena, body[i - 1 .. i + 1]);
    }
    return out.toOwnedSlice(arena);
}

fn keysOf(arena: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try scan(arena, src)) |st| {
        const prefix: []const u8 = switch (st.kind) {
            .table => "[",
            .array_table => "[[",
            .assignment => "",
        };
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, try std.mem.join(arena, ".", st.key) }));
    }
    return out.toOwnedSlice(arena);
}

fn expectKeys(src: []const u8, want: []const []const u8) !void {
    try expectScanFinishes(&.{src});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try keysOf(arena.allocator(), src);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "scan: a multi-line basic string's lines are never statements" {
    try expectKeys(
        "[[abbrs]]\nkey = \"ll\"\ndesc = \"\"\"\n[x]\nb = \\\"\\\"\\\" inside\n[[abbrs]]\n\"\"\"\na = \"quokkanote\"\n",
        &.{ "[[abbrs", "key", "desc", "a" },
    );
}

test "scan: a multi-line literal string's lines are never statements" {
    try expectKeys("[t]\ns = '''\n[[t]]\nb = 1\n'''\nc = 2\n", &.{ "[t", "s", "c" });
}

test "scan: a multi-line basic string ends at its first run of three quotes, keeping up to two" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "a = \"\"\"x\"\"\"\"\"  # c\nb = 1\n";
    const stmts = try scan(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    try std.testing.expectEqualStrings("\"\"\"x\"\"\"\"\"", stmts[0].value_span.of(src));
}

test "scan: an array spanning lines, with lines that open brackets and comments, is one value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "xs = [\n  [1, 2], # [not] = a header\n[3],\n  \"]\" ,\n]  # after\n[next]\ny = 1\n";
    const stmts = try scan(a, src);
    try std.testing.expectEqual(@as(usize, 3), stmts.len);
    try std.testing.expectEqualStrings("[\n  [1, 2], # [not] = a header\n[3],\n  \"]\" ,\n]", stmts[0].value_span.of(src));
    try std.testing.expectEqual(@as(usize, 1), stmts[0].value_comments.len);
    try std.testing.expectEqualStrings("[\n  [1, 2], \n[3],\n  \"]\" ,\n]", try stmts[0].valueText(a, src));
    try std.testing.expectEqualStrings("next", stmts[1].key[0]);
    try std.testing.expectEqual(Statement.Kind.table, stmts[1].kind);
}

test "scan: an inline table's keys and a multi-line inline table are part of its value" {
    try expectKeys("a = { b = 1, c = \"[x]\" }\nd = {\n  e = [\n    1,\n  ],\n  f = { g = 2 },\n}\nh = 3\n", &.{ "a", "d", "h" });
}

test "scan: a comment is not a statement and is not part of one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "# [x]\n  # a = 1\n[[abbrs]]  # [[abbrs]]\nk = \"v # not a comment \\\" #\"  # a comment\n";
    const stmts = try scan(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    try std.testing.expectEqualStrings("[[abbrs]]", stmts[0].span.of(src));
    try std.testing.expectEqualStrings("k = \"v # not a comment \\\" #\"", stmts[1].span.of(src));
    try std.testing.expectEqualStrings("\"v # not a comment \\\" #\"", stmts[1].value_span.of(src));
}

test "scan: quoted and dotted keys decode segment by segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "[[ \"abbrs\" ]]\n\"a.b\" . c = 1\n'lit' = 2\n\"esc\\u0041\\\"\" = 3\nbare-key_1 = 4\n";
    const stmts = try scan(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 5), stmts.len);
    try std.testing.expectEqualStrings("\"abbrs\"", stmts[0].key_span.of(src));
    try std.testing.expectEqualStrings("abbrs", stmts[0].key[0]);
    try std.testing.expectEqual(@as(usize, 2), stmts[1].key.len);
    try std.testing.expectEqualStrings("a.b", stmts[1].key[0]);
    try std.testing.expectEqualStrings("c", stmts[1].key[1]);
    try std.testing.expectEqualStrings("\"a.b\" . c", stmts[1].key_span.of(src));
    try std.testing.expectEqualStrings("lit", stmts[2].key[0]);
    try std.testing.expectEqualStrings("escA\"", stmts[3].key[0]);
    try std.testing.expectEqualStrings("bare-key_1", stmts[4].key[0]);
}

test "arrayTableRow: finds a row by its decoded stem and ends it at a header of any kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "[[abbrs]]\nk = 1\n[[other]]\nk = 2\n['abbrs']\nnot = 0\n[[\"abbrs\"]]\nk = 3\nv = \"\"\"\n[x]\n\"\"\"\n[tail]\nk = 4\n";
    const stmts = try scan(arena.allocator(), src);
    const row = arrayTableRow(stmts, "abbrs", 1).?;
    try std.testing.expectEqualStrings("[[\"abbrs\"]]", row.header.span.of(src));
    try std.testing.expectEqual(@as(usize, 2), row.body.len);
    try std.testing.expectEqualStrings("k = 3", row.body[0].span.of(src));
    try std.testing.expectEqualStrings("\"\"\"\n[x]\n\"\"\"", row.body[1].value_span.of(src));
    try std.testing.expect(arrayTableRow(stmts, "abbrs", 2) == null);
}

test "scan: a multi-line string closes only on its own quote kind" {
    try expectKeys("a = \"\"\"x\n'''\n[b]\n\"\"\"\nc = 1\n", &.{ "a", "c" });
    try expectKeys("a = '''x\n\"\"\"\n[b]\n'''\nc = 1\n", &.{ "a", "c" });
}

test "scan: a single-line basic string ending in a backslash ends at its line" {
    try expectKeys("a = \"x\\\n[b]\nc = 1\n", &.{ "a", "[b", "c" });
    try expectKeys("a = \"x\\", &.{"a"});
}

test "scan: unterminated values run to the end and never loop" {
    try expectScanFinishes(&.{
        "a = [1,\n[b]\n",
        "a = \"\"\"open\n[b]\n",
        "a = { = , }\nb = 1\n",
        "= 1\n[ ]\nc = 2\n",
    });
    try expectKeys("a = [1,\n[b]\n", &.{"a"});
    try expectKeys("a = \"\"\"open\n[b]\n", &.{"a"});
    try expectKeys("a = { = , }\nb = 1\n", &.{ "a", "b" });
    try expectKeys("= 1\n[ ]\nc = 2\n", &.{"c"});
}

test "scan: nesting past the parser's limit fails with NestingTooDeep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const at_limit = try std.mem.concat(a, u8, &.{ "a = ", "[" ** max_depth, "]" ** max_depth, "\nb = 1\n" });
    try std.testing.expectEqual(@as(usize, 2), (try scan(a, at_limit)).len);
    const past = try std.mem.concat(a, u8, &.{ "a = ", "[{x = " ** max_depth, "1" });
    try std.testing.expectError(error.NestingTooDeep, scan(a, past));
    const unclosed = try std.mem.concat(a, u8, &.{ "a = ", "[" ** (max_depth * 4) });
    try std.testing.expectError(error.NestingTooDeep, scan(a, unclosed));
    try expectScanFinishes(&.{ at_limit, past, unclosed });
}

test "scan: every short text over the syntax characters finishes" {
    // Each loop of the scanner advances `i` or returns, so a scan takes at
    // most a bounded number of steps per byte; this sweeps every text of up
    // to five characters over the bytes that open or close anything.
    const alphabet = "[]{}\"'=,#\\\n a";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var texts: std.ArrayList([]const u8) = .empty;
    var buf: [5]u8 = undefined;
    var len: usize = 1;
    while (len <= buf.len) : (len += 1) {
        var idx = [_]usize{0} ** 5;
        outer: while (true) {
            for (idx[0..len], buf[0..len]) |k, *c| c.* = alphabet[k];
            try texts.append(arena.allocator(), try arena.allocator().dupe(u8, buf[0..len]));
            var d: usize = 0;
            while (d < len) : (d += 1) {
                idx[d] += 1;
                if (idx[d] < alphabet.len) continue :outer;
                idx[d] = 0;
            }
            break;
        }
    }
    try expectScanFinishes(texts.items);
}

/// Scan every text on its own thread and fail, rather than hang, when the
/// scans do not all finish within a wall-clock bound. Each statement must
/// lie inside its text, in order.
fn expectScanFinishes(texts: []const []const u8) !void {
    const Job = struct {
        texts: []const []const u8,
        done: std.atomic.Value(bool) = .init(false),
        bad: std.atomic.Value(bool) = .init(false),

        fn run(job: *@This()) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            for (job.texts) |text| {
                _ = arena.reset(.retain_capacity);
                const stmts = scan(arena.allocator(), text) catch |e| switch (e) {
                    error.NestingTooDeep => continue,
                    error.OutOfMemory => {
                        job.bad.store(true, .release);
                        break;
                    },
                };
                var at: usize = 0;
                for (stmts) |st| {
                    if (st.span.start < at or st.span.end > text.len or st.span.start > st.span.end) job.bad.store(true, .release);
                    at = st.span.end;
                }
            }
            job.done.store(true, .release);
        }
    };
    // The job owns a copy of the texts, left to a stuck thread on timeout.
    var owned = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const copies = try owned.allocator().alloc([]const u8, texts.len);
    for (texts, copies) |t, *c| c.* = try owned.allocator().dupe(u8, t);
    const job = try owned.allocator().create(Job);
    job.* = .{ .texts = copies };
    const thread = try std.Thread.spawn(.{}, Job.run, .{job});
    const io = std.testing.io;
    const start = std.Io.Timestamp.now(io, .awake);
    while (!job.done.load(.acquire)) {
        if (start.untilNow(io, .awake).toSeconds() >= 60) {
            thread.detach();
            return error.ScanDidNotFinish;
        }
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    thread.join();
    defer owned.deinit();
    try std.testing.expect(!job.bad.load(.acquire));
}
