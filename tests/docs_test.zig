//! Keeps `docs/commands.md`'s flag tables equal to what argv accepts.
//!
//! The tables are rendered from the same command table `--help`, shell
//! completion, and `mox __schema` are derived from, so a flag added, renamed,
//! or dropped changes them by construction. This test is what makes that
//! binding real: it re-renders every table and compares it to the file, and
//! prints the block to paste when they differ.
//!
//! Why the docs carry the flags at all when `--help` already lists them: help
//! is for someone who has installed mox, and `commands.md` is read on the web
//! by someone deciding whether to. The prose around each table stays
//! hand-written -- a schema can say a flag exists, never what it means.

const std = @import("std");
const mox = @import("mox");

const Command = mox.cli.app.MoxCli.Command;

/// A command paired with its full name (`facts set`, not `set`).
const Entry = struct { name: []const u8, cmd: Command };
const testing = std.testing;

/// The marker pair a rendered table lives between. `<cmd>` is the command's
/// full name (`facts set`, not `set`), so a subcommand's table is addressed
/// unambiguously.
fn openMarker(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "<!-- generated: flags {s} -->", .{name});
}
const close_marker = "<!-- /generated -->";

/// One command's flag table, or null when it declares none -- an empty table
/// is noise, and a command with no flags says that by having no block.
fn renderTable(arena: std.mem.Allocator, cmd: Command, name: []const u8) !?[]const u8 {
    if (cmd.flags.len == 0) return null;

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{s}\n", .{try openMarker(arena, name)});
    try w.writeAll("| Flag | Description |\n| --- | --- |\n");
    for (cmd.flags) |f| {
        // One code span holding the whole spelling, in the order `--help`
        // itself prints it, so a reader comparing the two sees one form.
        try w.print("| `--{s}", .{f.long});
        if (f.short) |s| try w.print(", -{c}", .{s});
        if (f.takes_value) try w.print(" <{s}>", .{f.value_name});
        try w.writeAll("` | ");
        try w.writeAll(if (f.help.len > 0) f.help else "--");
        try w.writeAll(" |\n");
    }
    try w.writeAll(close_marker);
    return aw.written();
}

/// Every command in the table, flattened to `(full name, command)`.
fn flatten(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Entry),
    cmds: []const Command,
    prefix: []const u8,
) !void {
    for (cmds) |c| {
        const name = if (prefix.len == 0)
            c.name
        else
            try std.fmt.allocPrint(arena, "{s} {s}", .{ prefix, c.name });
        try out.append(arena, .{ .name = name, .cmd = c });
        try flatten(arena, out, c.subcommands, name);
    }
}

test "docs/commands.md flag tables match what argv accepts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const docs = std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "docs/commands.md",
        a,
        .limited(1 << 20),
    ) catch |e| switch (e) {
        // `zig build test` runs from the repo root; a runner that does not is
        // not a failure of the docs.
        error.FileNotFound => return error.SkipZigTest,
        else => return e,
    };

    var all: std.ArrayList(Entry) = .empty;
    try flatten(a, &all, &mox.cli.app.command_table, "");

    var missing: std.ArrayList([]const u8) = .empty;
    var stale: std.ArrayList([]const u8) = .empty;
    for (all.items) |entry| {
        const want = (try renderTable(a, entry.cmd, entry.name)) orelse continue;
        const open = try openMarker(a, entry.name);
        if (std.mem.indexOf(u8, docs, open) == null) {
            try missing.append(a, want);
            continue;
        }
        if (std.mem.indexOf(u8, docs, want) == null) try stale.append(a, want);
    }

    if (missing.items.len == 0 and stale.items.len == 0) return;

    // The failure carries the fix: the exact block to paste, so a flag change
    // never leaves anyone diffing a table by eye.
    std.debug.print("\ndocs/commands.md is out of date with the command table.\n", .{});
    for (missing.items) |m| std.debug.print("\nNo block for this command yet; add it:\n\n{s}\n", .{m});
    for (stale.items) |t| std.debug.print("\nThis block has drifted; replace it with:\n\n{s}\n", .{t});
    return error.DocsOutOfDate;
}

test "every generated block in the docs names a real command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const docs = std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "docs/commands.md",
        a,
        .limited(1 << 20),
    ) catch |e| switch (e) {
        error.FileNotFound => return error.SkipZigTest,
        else => return e,
    };

    var all: std.ArrayList(Entry) = .empty;
    try flatten(a, &all, &mox.cli.app.command_table, "");

    // A block left behind by a command that was renamed or removed would
    // otherwise sit there documenting flags nothing accepts -- the drift that
    // actually misleads, since the reader has no way to tell.
    const needle = "<!-- generated: flags ";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, docs, i, needle)) |at| {
        const rest = docs[at + needle.len ..];
        const end = std.mem.indexOf(u8, rest, " -->") orelse return error.MalformedMarker;
        const name = rest[0..end];
        var found = false;
        for (all.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) found = true;
        }
        if (!found) {
            std.debug.print("\ndocs/commands.md has a flag block for \"{s}\", which is not a command.\n", .{name});
            return error.UnknownCommandBlock;
        }
        i = at + needle.len;
    }
}
