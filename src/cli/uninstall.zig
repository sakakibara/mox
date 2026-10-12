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

pub const Action = enum { remove, preserve, prompt };

/// Decide what to do with a top-level entry of the state dir. The private
/// layer is preserved unless `--purge-private`; the history in `v2/` and
/// trash are prompted (they hold the user's recoverable originals); the lock file is left to the lock's own
/// release; everything else is removed.
pub fn actionFor(name: []const u8, purge_private: bool) Action {
    if (std.mem.eql(u8, name, lock_name)) return .preserve;
    if (std.mem.eql(u8, name, "trash")) return .prompt;
    if (std.mem.eql(u8, name, mox.state.draft.store_dir_name)) return .prompt;
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
    const st = (try state_cli.open(ctx, .{ .run_kind = .uninstall, .writes = true, .locked = true })) orelse return 2;

    // Sorted so kept/removed lines print in the same order on every machine.
    dir = try Io.Dir.cwd().openDir(ctx.io, context.paths.state_dir, .{ .iterate = true, .follow_symlinks = false });
    const entries = try dirent.sorted(ctx.alloc, ctx.io, dir);
    dir.close(ctx.io);
    var names: std.ArrayList([]const u8) = .empty;
    for (entries) |e| try names.append(ctx.alloc, e.name);

    var removed: usize = 0;
    var prompt_names: std.ArrayList([]const u8) = .empty;

    for (names.items) |name| {
        const path = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, name });
        switch (actionFor(name, purge_private)) {
            .preserve => try ctx.out.print("  kept {f}\n", .{display.of(path, ctx.context.?.paths.home)}),
            .prompt => try prompt_names.append(ctx.alloc, name),
            .remove => try removeEntry(ctx, path, &removed),
        }
    }

    // Recoverable entries (the history, trash): delete only if the matching
    // --purge flag is set or an interactive user confirms; otherwise keep.
    var history_kept = false;
    var history_asked = false;
    var purge_history = false;
    for (prompt_names.items) |name| {
        const path = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, name });
        const is_trash = std.mem.eql(u8, name, "trash");
        const do_delete = if (is_trash)
            a.purge_trash or (tty.isInteractive(0) and try confirm(ctx, name, path))
        else blk: {
            if (!history_asked) {
                history_asked = true;
                purge_history = a.purge_snapshots or (tty.isInteractive(0) and try confirm(ctx, "snapshots", st.store.v2));
            }
            break :blk purge_history;
        };
        if (do_delete) {
            try removeEntry(ctx, path, &removed);
        } else {
            if (!is_trash) history_kept = true;
            try ctx.out.print("  kept {f} (preserved; delete manually or re-run with --purge-{s})\n", .{ display.of(path, ctx.context.?.paths.home), if (is_trash) "trash" else "snapshots" });
        }
    }

    if (history_kept) try forgetRecords(ctx, st);

    try ctx.out.print("mox uninstall: removed {d} state entr(ies); source repo untouched\n", .{removed});
    return 0;
}

/// Commit a generation that forgets every record and flag, and strip every
/// retained generation down to its displaced history so the records' blobs
/// go.
fn forgetRecords(ctx: *app.Ctx, st: *mox.state.Draft) !void {
    try st.forgetEverything();
    try state_cli.commit(ctx, st, .{ .skip_gc = true });
    try mox.state.retention.stripRecords(ctx.alloc, ctx.io, st.store);
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

/// Prompt `[y/N]` for deleting a preserved entry, with a hard re-ask bound so
/// unparsable input cannot spin. Empty input / EOF defaults to No (keep).
fn confirm(ctx: *app.Ctx, name: []const u8, path: []const u8) !bool {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), ctx.io, &stdin_buf);
    const input: *Io.Reader = &stdin_reader.interface;

    var attempts: usize = 0;
    while (attempts < max_prompt_attempts) : (attempts += 1) {
        try ctx.out.print("Delete {s} at {f}? [y/N] ", .{ name, display.of(path, ctx.context.?.paths.home) });
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
    // The history holds the pre-mox originals: prompt, never silently removed.
    try testing.expectEqual(Action.prompt, actionFor(mox.state.draft.store_dir_name, false));
}
