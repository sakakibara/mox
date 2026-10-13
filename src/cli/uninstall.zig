//! `mox uninstall`: remove mox's machine-local state. Records, provenance and
//! flags are forgotten; the displaced history in `v2/` -- the pre-mox
//! original content of every file mox replaced -- is kept, so `mox rollback`
//! still works, unless `--purge-snapshots` or a confirmation at a terminal
//! deletes `v2/`. The private layer is PRESERVED unless `--purge-private`;
//! trash is preserved unless `--purge-trash` or confirmed. The user's source
//! repo is NEVER touched, and nothing outside the state directory is deleted.
//! Under the lock.

const std = @import("std");
const cli = @import("cli");
const display = @import("display.zig");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const state_cli = @import("state.zig");
const mox = @import("../root.zig");
const dirent = @import("../source/dirent.zig");
const tty = @import("tty.zig");

const Io = std.Io;

const lock_name = mox.state.lock.lock_name;
const max_prompt_attempts = 100;

pub const Action = enum { remove, preserve, prompt, history };

/// Decide what to do with a top-level entry of the state dir. The private
/// layer is preserved unless `--purge-private`; trash and the history
/// (`v2/`) are asked about, since they hold the user's recoverable
/// originals; the lock file is left to the lock's own
/// release; everything else is removed.
pub fn actionFor(name: []const u8, purge_private: bool) Action {
    if (std.mem.eql(u8, name, lock_name)) return .preserve;
    if (std.mem.eql(u8, name, "trash")) return .prompt;
    if (mox.state.isHistory(name)) return .history;
    if (std.mem.eql(u8, name, "private")) return if (purge_private) .remove else .preserve;
    return .remove;
}

const Spec = struct {
    purge_private: cli.Flag(.{ .help = "also delete the private layer" }),
    purge_trash: cli.Flag(.{ .help = "delete trash non-interactively" }),
    purge_snapshots: cli.Flag(.{ .help = "delete snapshots (pre-mox backups) non-interactively" }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const purge_private = a.purge_private;

    const lk = (try lock_mod.acquireForCommand(ctx, "uninstall")) orelse return 1;
    defer lk.release();

    var dir = Io.Dir.cwd().openDir(ctx.io, context.paths.state_dir, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.out.writeAll("mox uninstall: no state to remove\n");
            return 0;
        },
        else => return e,
    };
    dir.close(ctx.io);

    // The history is asked about first, since deleting it needs no readable
    // generation and keeping it needs one to forget the records in.
    const history = try mox.state.history(ctx.alloc, ctx.io, context.paths.state_dir);
    const purge_history = history.present and (a.purge_snapshots or (tty.isInteractive(0) and try confirmHistory(ctx, history)));
    const st = (try state_cli.open(ctx, .{ .run_kind = .uninstall, .writes = !purge_history, .locked = true })) orelse return 2;

    // Sorted so kept/removed lines print in the same order on every machine.
    dir = try Io.Dir.cwd().openDir(ctx.io, context.paths.state_dir, .{ .iterate = true, .follow_symlinks = false });
    const entries = try dirent.sorted(ctx.alloc, ctx.io, dir);
    dir.close(ctx.io);

    var removed: usize = 0;
    var trash_seen = false;
    for (entries) |e| {
        const path = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, e.name });
        switch (actionFor(e.name, purge_private)) {
            .preserve => try ctx.out.print("  kept {f}\n", .{display.of(path, ctx.context.?.paths.home)}),
            .history => {},
            .prompt => trash_seen = true,
            .remove => try removeEntry(ctx, path, &removed),
        }
    }

    // Trash holds recoverable originals: deleted only on --purge-trash or
    // an interactive yes.
    if (trash_seen) {
        const path = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, "trash" });
        if (a.purge_trash or (tty.isInteractive(0) and try confirm(ctx, "trash", path))) {
            try removeEntry(ctx, path, &removed);
        } else try ctx.out.print("  kept {f} (preserved; delete manually or re-run with --purge-trash)\n", .{display.of(path, ctx.context.?.paths.home)});
    }

    if (purge_history) {
        if (try mox.state.purgeHistory(ctx.alloc, ctx.io, context.paths.state_dir)) |r| {
            if (r.err) |err| {
                try ctx.err.print("  kept {f} (delete failed: {s})\n", .{ display.of(r.path, context.paths.home), @errorName(err) });
            } else {
                removed += 1;
                try ctx.out.print("  removed {f}\n", .{display.of(r.path, context.paths.home)});
            }
        }
    } else if (history.present) {
        try ctx.out.print("  kept {f} (preserved; delete manually or re-run with --purge-snapshots)\n", .{display.of(history.path, ctx.context.?.paths.home)});
        if (!try forgetRecords(ctx, st)) return 2;
    }

    try ctx.out.print("mox uninstall: removed {d} state entr(ies); source repo untouched\n", .{removed});
    return 0;
}

/// Commit a generation that forgets every record and flag, and strip every
/// retained generation down to its displaced history so the records' blobs
/// go.
fn forgetRecords(ctx: *app.Ctx, st: *mox.state.Draft) !bool {
    try st.forgetEverything();
    if (!try state_cli.commit(ctx, st, .{ .skip_gc = true })) return false;
    try st.stripHistory();
    return true;
}

/// Remove one state entry, reporting the outcome. A delete FAILURE is reported
/// as kept (not counted as removed), so a permission/IO error never yields a
/// false "removed" line.
fn removeEntry(ctx: *app.Ctx, path: []const u8, removed: *usize) !void {
    if (deleteEntry(ctx.io, path)) |_| {
        removed.* += 1;
        try ctx.out.print("  removed {f}\n", .{display.of(path, ctx.context.?.paths.home)});
    } else |e| {
        try ctx.err.print("  kept {f} (delete failed: {s})\n", .{ display.of(path, ctx.context.?.paths.home), @errorName(e) });
    }
}

/// Remove a state entry, file or directory, propagating a failure.
fn deleteEntry(io: Io, path: []const u8) !void {
    Io.Dir.cwd().deleteTree(io, path) catch {
        try Io.Dir.cwd().deleteFile(io, path);
    };
}

/// Ask once whether to delete the history.
fn confirmHistory(ctx: *app.Ctx, h: mox.state.History) !bool {
    return confirmText(ctx, try std.fmt.allocPrint(ctx.alloc, "Delete the snapshot history at {f}? [y/N] ", .{display.of(h.path, ctx.context.?.paths.home)}));
}

/// Prompt `[y/N]` for deleting a preserved entry, with a hard re-ask bound so
/// unparsable input cannot spin. Empty input / EOF defaults to No (keep).
fn confirm(ctx: *app.Ctx, name: []const u8, path: []const u8) !bool {
    return confirmText(ctx, try std.fmt.allocPrint(ctx.alloc, "Delete {s} at {f}? [y/N] ", .{ name, display.of(path, ctx.context.?.paths.home) }));
}

fn confirmText(ctx: *app.Ctx, question: []const u8) !bool {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), ctx.io, &stdin_buf);
    const input: *Io.Reader = &stdin_reader.interface;

    var attempts: usize = 0;
    while (attempts < max_prompt_attempts) : (attempts += 1) {
        try ctx.out.writeAll(question);
        try ctx.out.flush();
        const line = (try input.takeDelimiter('\n')) orelse return false;
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) return false;
        switch (std.ascii.toLower(t[0])) {
            'y' => return true,
            'n' => return false,
            else => {},
        }
    }
    return false;
}

pub const command = app.command(Spec, .{
    .name = "uninstall",
    .usage = "mox uninstall [--flags]",
    .summary = "Remove mox state",
    .details = "Records and flags are forgotten; the snapshot history is kept unless --purge-snapshots or confirmed, and trash unless --purge-trash or confirmed; the private layer is kept unless --purge-private. The source repo is never touched.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "actionFor: private preserved by default, removed on purge; trash and the history prompt" {
    try testing.expectEqual(Action.preserve, actionFor("private", false));
    try testing.expectEqual(Action.remove, actionFor("private", true));
    try testing.expectEqual(Action.prompt, actionFor("trash", false));
    try testing.expectEqual(Action.preserve, actionFor(lock_name, false));
    try testing.expectEqual(Action.remove, actionFor("coupling", false));
    // The history holds the pre-mox originals: asked about, never silently
    // removed.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(Action.history, actionFor(std.fs.path.basename((try mox.state.history(arena_state.allocator(), testing.io, "/nonexistent")).path), true));
}
