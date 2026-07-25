//! Head directives: a source file's partial-ownership contract, declared in
//! its LEADING comment block (recognized before the first content line, after
//! an optional shebang -- the whole-file gate's exact precedent).
//!
//! One directive per line:
//!   `<marker> mox: own <path>`    -- repeatable; the rest of the line is
//!                                    ONE key-path (TOML dotted-key syntax)
//!   `<marker> mox: disown <path>` -- repeatable; the complement mode: the
//!                                    whole file is owned EXCEPT the
//!                                    declared subtrees
//!   `<marker> mox: check "<exe>" ["arg" ...]` -- quoted argv items
//!
//! `own` and `disown` are mutually exclusive per file.
//!
//! The pass also RECORDS a whole-file gate candidate: a `when <expr>` line
//! that would sit on line 1 of the stripped text (every byte before it is a
//! consumed directive line). Whether it actually gates the file is the
//! DSL's call -- a matching `end` later in the file makes it a region -- so
//! the line is reported, never consumed here.
//!
//! Other comment lines in the leading block are left alone. The ownership
//! directives never reach composed output: compose strips exactly the
//! recognized lines from the base layer text (`strip`), so the live file a
//! program reads contains no mox syntax.

const std = @import("std");

pub const Ownership = enum { none, own, disown };

/// Half-open byte range of one recognized directive line, trailing newline
/// included.
pub const Span = struct { start: usize, end: usize };

/// A whole-file gate candidate found in the leading block.
pub const Gate = struct {
    /// Axis-expression text after the `when` keyword, as written.
    expr: []const u8,
    span: Span,
};

pub const Parsed = struct {
    ownership: Ownership = .none,
    /// Raw key-path strings, one per `own`/`disown` line, in declaration
    /// order.
    paths: []const []const u8 = &.{},
    /// `check` argv: a repo-relative executable and its arguments.
    check: []const []const u8 = &.{},
    /// Spans of every recognized directive line, in file order.
    spans: []const Span = &.{},
    /// Whole-file gate candidate: the `when` line that is line 1 of the
    /// stripped text. Null when no such line leads the block.
    gate: ?Gate = null,
    /// Offset of the first content line -- where the leading comment block
    /// ends -- or `text.len` for an all-comment file.
    block_end: usize = 0,
};

pub const ParseError = error{
    OutOfMemory,
    /// An `own` or `disown` line with no path.
    EmptyDirectivePath,
    /// `own` and `disown` lines in the same head.
    OwnAndDisown,
    /// A `check` line whose argv is not one or more double-quoted items.
    InvalidCheckArgv,
    /// More than one `check` line.
    DuplicateCheckDirective,
    /// A `check` line with no ownership declaration.
    CheckWithoutOwnership,
};

/// Parse the leading comment block of `text` for head directives. `marker`
/// is the file's line-comment marker (`#`, `//`, ...).
pub fn parse(arena: std.mem.Allocator, text: []const u8, marker: []const u8) ParseError!Parsed {
    var paths: std.ArrayList([]const u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    var check: ?[]const []const u8 = null;
    var ownership: Ownership = .none;
    var gate: ?Gate = null;
    var block_end: usize = text.len;

    // A UTF-8 BOM belongs to the file, not the directive grammar: skip it
    // so the leading block is recognized, and leave it out of every span so
    // `strip` keeps it as the first remainder bytes.
    var pos: usize = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) 3 else 0;
    var first_line = true;
    // Offset up to which every byte is a consumed directive line, tracked
    // from 0 so a BOM, shebang, blank, or plain comment breaks contiguity.
    var covered: usize = 0;
    while (pos < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n');
        const line_end = if (nl) |n| n + 1 else text.len;
        const line = std.mem.trimEnd(u8, text[pos .. nl orelse text.len], "\r");
        const was_first = first_line;
        first_line = false;
        const line_start = pos;
        pos = line_end;

        if (was_first and std.mem.startsWith(u8, line, "#!")) continue;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (!std.mem.startsWith(u8, trimmed, marker)) {
            block_end = line_start;
            break;
        }

        const args = directiveArgs(trimmed, marker) orelse continue;
        const kw_end = std.mem.indexOfAny(u8, args, " \t") orelse args.len;
        const keyword = args[0..kw_end];
        const rest = std.mem.trim(u8, args[kw_end..], " \t");
        if (std.mem.eql(u8, keyword, "own") or std.mem.eql(u8, keyword, "disown")) {
            const mode: Ownership = if (keyword.len == 3) .own else .disown;
            if (ownership != .none and ownership != mode) return error.OwnAndDisown;
            ownership = mode;
            if (rest.len == 0) return error.EmptyDirectivePath;
            try paths.append(arena, rest);
            try spans.append(arena, .{ .start = line_start, .end = line_end });
            if (line_start == covered) covered = line_end;
        } else if (std.mem.eql(u8, keyword, "check")) {
            if (check != null) return error.DuplicateCheckDirective;
            check = try parseQuotedArgv(arena, rest);
            try spans.append(arena, .{ .start = line_start, .end = line_end });
            if (line_start == covered) covered = line_end;
        } else if (std.mem.eql(u8, keyword, "when")) {
            // Gate candidate: only when it would sit on line 1 of the
            // stripped text. Recorded, not consumed -- compose asks the DSL
            // whether it truly gates the whole file.
            if (gate == null and line_start == covered) {
                gate = .{ .expr = rest, .span = .{ .start = line_start, .end = line_end } };
            }
        }
        // Any other verb (an include, ...) belongs to the DSL and stays in
        // place.
    }

    if (ownership == .none) {
        if (check != null) return error.CheckWithoutOwnership;
        return .{ .gate = gate, .block_end = block_end };
    }
    return .{
        .ownership = ownership,
        .paths = try paths.toOwnedSlice(arena),
        .check = check orelse &.{},
        .spans = try spans.toOwnedSlice(arena),
        .gate = gate,
        .block_end = block_end,
    };
}

/// `text` with every recognized head-directive line removed. A head that
/// fails to parse strips nothing (the walk has already refused the file).
pub fn strip(arena: std.mem.Allocator, text: []const u8, marker: []const u8) error{OutOfMemory}![]const u8 {
    const parsed = parse(arena, text, marker) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return text,
    };
    return stripSpans(arena, text, parsed.spans);
}

/// `text` with the given directive-line spans removed. The spans may come
/// from parsing a bounded prefix of `text`; a recognized leading block ends
/// within the parsed region, so its offsets index `text` directly.
pub fn stripSpans(arena: std.mem.Allocator, text: []const u8, spans: []const Span) error{OutOfMemory}![]const u8 {
    if (spans.len == 0) return text;
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (spans) |s| {
        try out.appendSlice(arena, text[cursor..s.start]);
        cursor = s.end;
    }
    try out.appendSlice(arena, text[cursor..]);
    return out.toOwnedSlice(arena);
}

/// The args of a `<marker> mox: <args>` line, or null when the (already
/// left-trimmed) comment line is not a mox directive. Mirrors the DSL
/// scanner's match rules: whitespace required after the marker, then `mox:`.
fn directiveArgs(line: []const u8, marker: []const u8) ?[]const u8 {
    var rest = line[marker.len..];
    if (rest.len == 0) return null;
    if (rest[0] != ' ' and rest[0] != '\t') return null;
    rest = std.mem.trimStart(u8, rest, " \t");
    const prefix = "mox:";
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    return std.mem.trim(u8, rest[prefix.len..], " \t");
}

/// One or more double-quoted items separated by whitespace; `\"` and `\\`
/// escapes inside an item. Anything else is invalid.
fn parseQuotedArgv(arena: std.mem.Allocator, s: []const u8) ParseError![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len) break;
        if (s[i] != '"') return error.InvalidCheckArgv;
        i += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (i >= s.len) return error.InvalidCheckArgv;
            const c = s[i];
            if (c == '"') {
                i += 1;
                break;
            }
            if (c == '\\') {
                i += 1;
                if (i >= s.len) return error.InvalidCheckArgv;
                switch (s[i]) {
                    '"', '\\' => try out.append(arena, s[i]),
                    else => return error.InvalidCheckArgv,
                }
                i += 1;
                continue;
            }
            try out.append(arena, c);
            i += 1;
        }
        try items.append(arena, try out.toOwnedSlice(arena));
    }
    if (items.items.len == 0) return error.InvalidCheckArgv;
    return items.toOwnedSlice(arena);
}

const testing = std.testing;

test "parse: own and check in the leading block, gate line left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\# a plain comment
        \\# mox: own tui.keymap.global
        \\# mox: own projects."/tmp/example"
        \\# mox: check "scripts/check/codex-config" "--strict"
        \\# mox: when tool=codex
        \\[tui.keymap.global]
        \\
    ;
    const p = try parse(a, text, "#");
    try testing.expectEqual(Ownership.own, p.ownership);
    try testing.expectEqual(@as(usize, 2), p.paths.len);
    try testing.expectEqualStrings("tui.keymap.global", p.paths[0]);
    try testing.expectEqualStrings("projects.\"/tmp/example\"", p.paths[1]);
    try testing.expectEqual(@as(usize, 2), p.check.len);
    try testing.expectEqualStrings("scripts/check/codex-config", p.check[0]);
    try testing.expectEqualStrings("--strict", p.check[1]);
    try testing.expectEqual(@as(usize, 3), p.spans.len);

    const stripped = try strip(a, text, "#");
    const want =
        \\# a plain comment
        \\# mox: when tool=codex
        \\[tui.keymap.global]
        \\
    ;
    try testing.expectEqualStrings(want, stripped);
}

test "parse: jsonc marker, shebang skip, blank lines inside the block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "// mox: own model\n\n// note\n{\n}\n", "//");
    try testing.expectEqual(@as(usize, 1), p.paths.len);
    try testing.expectEqualStrings("model", p.paths[0]);

    const sh = try parse(a, "#!/usr/bin/env tool\n# mox: own a\nbody\n", "#");
    try testing.expectEqual(@as(usize, 1), sh.paths.len);
}

test "parse: a directive after the first content line is not recognized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "[t]\n# mox: own a\n", "#");
    try testing.expectEqual(Ownership.none, p.ownership);
}

test "parse: disown mode, and own+disown together refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "// mox: disown model\n// mox: disown feedbackSurveyState\n{\n}\n", "//");
    try testing.expectEqual(Ownership.disown, p.ownership);
    try testing.expectEqual(@as(usize, 2), p.paths.len);
    try testing.expectEqualStrings("model", p.paths[0]);
    try testing.expectError(error.OwnAndDisown, parse(a, "# mox: own a\n# mox: disown b\n[a]\n", "#"));
}

test "parse: malformed heads are refused, never guessed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.EmptyDirectivePath, parse(a, "# mox: own\n[t]\n", "#"));
    try testing.expectError(error.EmptyDirectivePath, parse(a, "# mox: disown\n[t]\n", "#"));
    try testing.expectError(error.InvalidCheckArgv, parse(a, "# mox: own a\n# mox: check bare\n", "#"));
    try testing.expectError(error.InvalidCheckArgv, parse(a, "# mox: own a\n# mox: check\n", "#"));
    try testing.expectError(error.DuplicateCheckDirective, parse(a, "# mox: own a\n# mox: check \"x\"\n# mox: check \"y\"\n", "#"));
    try testing.expectError(error.CheckWithoutOwnership, parse(a, "# mox: check \"x\"\n[t]\n", "#"));
}

test "parse: quoted argv escapes and the whole rest of an own line as one path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "# mox: own remote.\"my origin\".url\n# mox: check \"a \\\"b\\\"\" \"c\\\\d\"\n", "#");
    try testing.expectEqualStrings("remote.\"my origin\".url", p.paths[0]);
    try testing.expectEqualStrings("a \"b\"", p.check[0]);
    try testing.expectEqualStrings("c\\d", p.check[1]);
}

test "parse: a UTF-8 BOM precedes the leading block; strip keeps it in place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "\xEF\xBB\xBF# mox: own a\n[a]\nk = 1\n";
    const p = try parse(a, text, "#");
    try testing.expectEqual(Ownership.own, p.ownership);
    try testing.expectEqualStrings("a", p.paths[0]);
    try testing.expectEqualStrings("\xEF\xBB\xBF[a]\nk = 1\n", try strip(a, text, "#"));
}

test "parse: gate candidate recognized in either order with ownership lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const own_first = try parse(a, "# mox: own a\n# mox: when tool=codex\n[a]\n", "#");
    try testing.expectEqualStrings("tool=codex", own_first.gate.?.expr);

    const gate_first = try parse(a, "# mox: when tool=codex\n# mox: own a\n[a]\n", "#");
    try testing.expectEqualStrings("tool=codex", gate_first.gate.?.expr);
    try testing.expectEqual(@as(usize, 0), gate_first.gate.?.span.start);

    const alone = try parse(a, "# mox: when os=macos\n[gaps]\n", "#");
    try testing.expectEqual(Ownership.none, alone.ownership);
    try testing.expectEqualStrings("os=macos", alone.gate.?.expr);
}

test "parse: gate candidate needs line 1 of the stripped text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A plain comment, blank line, shebang, or BOM before the `when` line
    // means it is not line 1 after stripping: no candidate.
    try testing.expect((try parse(a, "# note\n# mox: when a=b\n[t]\n", "#")).gate == null);
    try testing.expect((try parse(a, "\n# mox: when a=b\n[t]\n", "#")).gate == null);
    try testing.expect((try parse(a, "#!/usr/bin/env t\n# mox: when a=b\nx\n", "#")).gate == null);
    try testing.expect((try parse(a, "\xEF\xBB\xBF# mox: when a=b\n[t]\n", "#")).gate == null);
    try testing.expect((try parse(a, "# mox: own a\n# note\n# mox: when a=b\n[a]\n", "#")).gate == null);

    // Only the first `when` line can be the candidate.
    const two = try parse(a, "# mox: when a=b\n# mox: when c=d\n[t]\n", "#");
    try testing.expectEqualStrings("a=b", two.gate.?.expr);
}

test "parse: block_end is the first content line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "# mox: own a\n# note\n[a]\nk = 1\n";
    const p = try parse(a, text, "#");
    try testing.expectEqual(std.mem.indexOf(u8, text, "[a]").?, p.block_end);
    const all_comment = try parse(a, "# mox: own a\n# note\n", "#");
    try testing.expectEqual(@as(usize, "# mox: own a\n# note\n".len), all_comment.block_end);
}

test "strip: no directives leaves the text untouched, CRLF line survives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "# comment\n[t]\nk = 1\n";
    try testing.expectEqualStrings(plain, try strip(a, plain, "#"));
    const crlf = "# mox: own a\r\n[a]\r\nk = 1\r\n";
    try testing.expectEqualStrings("[a]\r\nk = 1\r\n", try strip(a, crlf, "#"));
}
