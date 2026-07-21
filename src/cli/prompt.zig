//! Shared interactive-prompt infrastructure for mox commands.
//!
//! A single choice prompt with four dispositions, so every command that asks
//! the user something behaves the same in a terminal, under `--yes`, in a
//! pipe, and in strict CI:
//!   - `.interactive`     read a bounded line and map it to a choice.
//!   - `.assume_default`  `--yes`: take the default, never read.
//!   - `.report_only`     non-TTY without `--yes`: don't ask; the caller
//!                        collects what it would have asked and exits 1.
//!   - `.abort_on_prompt` strict CI: the first would-be prompt aborts, rc 2.
//! `q` (or EOF) at any interactive prompt aborts the whole command; because
//! callers do all writes after all prompts, an abort writes nothing.

const std = @import("std");

const Io = std.Io;

/// Hard bound on re-asks so unparsable or no-progress input can never spin.
pub const max_ask_attempts = 100;

pub const Mode = enum {
    interactive,
    assume_default,
    report_only,
    abort_on_prompt,
};

/// One selectable answer. `key` is what the user types (matched
/// case-insensitively; single alphabetic keys also match on first letter, so
/// "yes" selects key "y"). `label` is shown by `renderChoices`.
pub const Choice = struct {
    key: []const u8,
    label: []const u8,
    /// One-line explanation shown when the user types `?` at the prompt.
    /// Empty means the label alone stands for it.
    help: []const u8 = "",
};

pub const Outcome = union(enum) {
    /// The chosen choice index (or the default under `.assume_default`).
    chosen: usize,
    /// Non-TTY without `--yes`: nothing asked; caller reports and exits 1.
    report_only,
    /// `q`, EOF, or attempts exhausted: abort the command, write nothing.
    abort,
    /// `.abort_on_prompt`: strict CI, caller returns rc 2.
    abort_strict,
};

/// Print `question`, read one bounded line, and map it to a choice. `question`
/// is the fully-rendered prompt shown just before reading (e.g. the caller's
/// `renderChoices` output, or a literal like `"  [Y/n/m/q] "`). Empty input
/// takes `default_index`; `q` or EOF aborts.
pub fn ask(
    mode: Mode,
    choices: []const Choice,
    default_index: usize,
    question: []const u8,
    input: *Io.Reader,
    out: *Io.Writer,
) !Outcome {
    switch (mode) {
        .report_only => return .report_only,
        .abort_on_prompt => return .abort_strict,
        .assume_default => return .{ .chosen = default_index },
        .interactive => {},
    }

    var attempts: usize = 0;
    while (attempts < max_ask_attempts) {
        try out.writeAll(question);
        try out.flush();
        // takeDelimiter (not the -Exclusive variant) consumes the newline, so
        // repeated blank lines make progress toward the attempt bound instead
        // of yielding "" forever. EOF (null) aborts.
        const line = (try input.takeDelimiter('\n')) orelse return .abort;
        const t = std.mem.trim(u8, line, " \t\r");
        // `?` is the user orienting themselves, not a wrong guess: print what
        // every choice does and re-ask without spending an attempt.
        if (t.len == 1 and t[0] == '?') {
            try printHelp(choices, out);
            try out.flush();
            continue;
        }
        attempts += 1;
        if (t.len == 0) return .{ .chosen = default_index };
        // `q` is a universal abort at every prompt.
        if (t.len == 1 and std.ascii.toLower(t[0]) == 'q') return .abort;
        // Exact (case-sensitive) match wins, so choices that differ only by
        // case (e.g. `d` vs `D`) stay distinguishable.
        for (choices, 0..) |c, i| {
            if (std.mem.eql(u8, t, c.key)) return .{ .chosen = i };
        }
        for (choices, 0..) |c, i| {
            if (matches(t, c.key)) return .{ .chosen = i };
        }
    }
    return .abort;
}

/// One line per choice (`key`, `label`, `help`), plus the universal `q`, so
/// `?` explains every option without leaving the prompt.
fn printHelp(choices: []const Choice, out: *Io.Writer) !void {
    for (choices) |c| {
        try out.print("  [{s}] {s}", .{ c.key, c.label });
        if (c.help.len > 0) try out.print(" -- {s}", .{c.help});
        try out.writeAll("\n");
    }
    try out.writeAll("  [q] quit -- abort, write nothing\n");
}

/// Case-insensitive match of typed input against a choice key. Digit keys
/// require an exact token match (so "12" never selects "1"); single
/// alphabetic keys also match on the first letter ("yes" selects "y").
fn matches(token: []const u8, key: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(token, key)) return true;
    if (key.len == 1 and std.ascii.isAlphabetic(key[0]) and token.len >= 1)
        return std.ascii.toLower(token[0]) == std.ascii.toLower(key[0]);
    return false;
}

/// Render a `[k1] l1  [k2] l2 ...  [q] quit ` choice line into `arena`, for
/// callers that don't pass a literal prompt string. Numbered and lettered
/// keys render identically.
pub fn renderChoices(arena: std.mem.Allocator, choices: []const Choice) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (choices) |c| {
        try aw.writer.print("[{s}] {s}  ", .{ c.key, c.label });
    }
    try aw.writer.writeAll("[q] quit ");
    return aw.toOwnedSlice();
}

const testing = std.testing;

test "ask: interactive maps letters, numbers, and empty-default" {
    const choices = [_]Choice{
        .{ .key = "y", .label = "yes" },
        .{ .key = "n", .label = "no" },
        .{ .key = "m", .label = "manual" },
    };
    var out_aw: Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();

    var empty = Io.Reader.fixed("\n");
    try testing.expectEqual(Outcome{ .chosen = 0 }, try ask(.interactive, &choices, 0, "> ", &empty, &out_aw.writer));

    var no = Io.Reader.fixed("n\n");
    try testing.expectEqual(Outcome{ .chosen = 1 }, try ask(.interactive, &choices, 0, "> ", &no, &out_aw.writer));

    // First-letter match: "manual" selects key "m".
    var word = Io.Reader.fixed("manual\n");
    try testing.expectEqual(Outcome{ .chosen = 2 }, try ask(.interactive, &choices, 0, "> ", &word, &out_aw.writer));
}

test "ask: numbered choices require exact token match" {
    const choices = [_]Choice{
        .{ .key = "1", .label = "universal" },
        .{ .key = "2", .label = "profile" },
    };
    var out_aw: Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();

    var two = Io.Reader.fixed("2\n");
    try testing.expectEqual(Outcome{ .chosen = 1 }, try ask(.interactive, &choices, 0, "> ", &two, &out_aw.writer));

    // "12" is not a prefix-select for "1": no match, then EOF aborts.
    var bad = Io.Reader.fixed("12\n");
    try testing.expectEqual(Outcome.abort, try ask(.interactive, &choices, 0, "> ", &bad, &out_aw.writer));
}

test "ask: case-sensitive keys stay distinguishable" {
    const choices = [_]Choice{
        .{ .key = "y", .label = "yes" },
        .{ .key = "n", .label = "no" },
        .{ .key = "d", .label = "decline pair" },
        .{ .key = "D", .label = "decline globally" },
    };
    var out_aw: Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();

    var lower = Io.Reader.fixed("d\n");
    try testing.expectEqual(Outcome{ .chosen = 2 }, try ask(.interactive, &choices, 0, "> ", &lower, &out_aw.writer));

    var upper = Io.Reader.fixed("D\n");
    try testing.expectEqual(Outcome{ .chosen = 3 }, try ask(.interactive, &choices, 0, "> ", &upper, &out_aw.writer));
}

test "ask: q and EOF abort" {
    const choices = [_]Choice{.{ .key = "y", .label = "yes" }};
    var out_aw: Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();

    var q = Io.Reader.fixed("q\n");
    try testing.expectEqual(Outcome.abort, try ask(.interactive, &choices, 0, "> ", &q, &out_aw.writer));

    var eof = Io.Reader.fixed("");
    try testing.expectEqual(Outcome.abort, try ask(.interactive, &choices, 0, "> ", &eof, &out_aw.writer));
}

test "ask: non-interactive modes never read the input" {
    const choices = [_]Choice{
        .{ .key = "y", .label = "yes" },
        .{ .key = "n", .label = "no" },
    };
    var out_aw: Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();
    var input = Io.Reader.fixed("n\n");

    try testing.expectEqual(Outcome.report_only, try ask(.report_only, &choices, 1, "> ", &input, &out_aw.writer));
    try testing.expectEqual(Outcome.abort_strict, try ask(.abort_on_prompt, &choices, 1, "> ", &input, &out_aw.writer));
    try testing.expectEqual(Outcome{ .chosen = 1 }, try ask(.assume_default, &choices, 1, "> ", &input, &out_aw.writer));
    try testing.expectEqualStrings("", out_aw.written());
}

test "ask: blank-line no-progress input is bounded, then aborts" {
    const choices = [_]Choice{.{ .key = "y", .label = "yes" }};
    var out_aw: Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();
    // No default in the middle of a stream of garbage tokens that never match.
    const garbage = "zzz\n" ** (max_ask_attempts + 5);
    var input = Io.Reader.fixed(garbage);
    // default_index picks the default only on EMPTY input; "zzz" is non-empty
    // and never matches, so attempts exhaust and it aborts.
    try testing.expectEqual(Outcome.abort, try ask(.interactive, &choices, 0, "> ", &input, &out_aw.writer));
}

test "ask: ? prints a help block without spending an attempt, then re-asks" {
    const choices = [_]Choice{
        .{ .key = "y", .label = "yes", .help = "do the thing" },
        .{ .key = "n", .label = "no", .help = "skip it" },
    };
    var out_aw: Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();

    var input = Io.Reader.fixed("?\ny\n");
    const outcome = try ask(.interactive, &choices, 0, "> ", &input, &out_aw.writer);
    try testing.expectEqual(Outcome{ .chosen = 0 }, outcome);
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "[y] yes -- do the thing") != null);
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "[n] no -- skip it") != null);
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "[q] quit -- abort, write nothing") != null);
}

test "ask: ? never counts toward max_ask_attempts" {
    const choices = [_]Choice{.{ .key = "y", .label = "yes" }};
    var out_aw: Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();

    // Well past the attempt bound if "?" consumed attempts; a real answer
    // still lands because it never does.
    const scripted = "?\n" ** (max_ask_attempts + 5) ++ "y\n";
    var input = Io.Reader.fixed(scripted);
    const outcome = try ask(.interactive, &choices, 0, "> ", &input, &out_aw.writer);
    try testing.expectEqual(Outcome{ .chosen = 0 }, outcome);
}

test "renderChoices: letters and numbers render with a quit suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const choices = [_]Choice{
        .{ .key = "1", .label = "universal" },
        .{ .key = "y", .label = "yes" },
    };
    const line = try renderChoices(arena.allocator(), &choices);
    try testing.expectEqualStrings("[1] universal  [y] yes  [q] quit ", line);
}
