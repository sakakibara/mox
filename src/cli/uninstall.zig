//! `mox uninstall`: remove mox's machine-local state (applied records,
//! provenance, ...). The private layer is PRESERVED unless `--purge-private`.
//! Snapshots (the pre-mox original content of every file mox overwrote) and
//! trash are PRESERVED unless confirmed: `--purge-snapshots` / `--purge-trash`
//! delete non-interactively, otherwise a TTY is prompted -- so uninstalling
//! never silently destroys the only backup of the user's originals. The user's
//! source repo (their git repo) is NEVER touched. Under the lock.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const dirent = @import("../source/dirent.zig");
const tty = @import("tty.zig");

const Io = std.Io;

const lock_name = "mox.lock";
const max_prompt_attempts = 100;

pub const Action = enum { remove, preserve, prompt };

/// Decide what to do with a top-level entry of the state dir. The private
/// layer is preserved unless `--purge-private`; snapshots and trash are prompted
/// (they hold the user's recoverable originals); the lock file is left to the
/// lock's own release; everything else is removed.
pub fn actionFor(name: []const u8, purge_private: bool) Action {
    if (std.mem.eql(u8, name, lock_name)) return .preserve;
    if (std.mem.eql(u8, name, "trash")) return .prompt;
    if (std.mem.eql(u8, name, "snapshots")) return .prompt;
    if (std.mem.eql(u8, name, "private")) return if (purge_private) .remove else .preserve;
    return .remove;
}

const Spec = struct {
    purge_private: cli.spec.Flag(.{ .help = "also delete the private layer" }),
    purge_trash: cli.spec.Flag(.{ .help = "delete trash non-interactively" }),
    purge_snapshots: cli.spec.Flag(.{ .help = "delete snapshots (pre-mox backups) non-interactively" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
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

    // Sorted so kept/removed lines print in the same order on every machine.
    const entries = try dirent.sorted(ctx.alloc, ctx.io, dir);
    dir.close(ctx.io);
    var names: std.ArrayList([]const u8) = .empty;
    for (entries) |e| try names.append(ctx.alloc, e.name);

    var removed: usize = 0;
    var prompt_names: std.ArrayList([]const u8) = .empty;

    for (names.items) |name| {
        const path = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, name });
        switch (actionFor(name, purge_private)) {
            .preserve => try ctx.out.print("  kept {s}\n", .{path}),
            .prompt => try prompt_names.append(ctx.alloc, name),
            .remove => try removeEntry(ctx, path, &removed),
        }
    }

    // Recoverable entries (snapshots, trash): delete only if the matching
    // --purge flag is set or an interactive user confirms; otherwise keep.
    for (prompt_names.items) |name| {
        const path = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, name });
        const forced = (std.mem.eql(u8, name, "trash") and a.purge_trash) or
            (std.mem.eql(u8, name, "snapshots") and a.purge_snapshots);
        const do_delete = forced or (tty.isInteractive(0) and try confirm(ctx, name, path));
        if (do_delete) {
            try removeEntry(ctx, path, &removed);
        } else {
            try ctx.out.print("  kept {s} (preserved; delete manually or re-run with --purge-{s})\n", .{ path, name });
        }
    }

    try ctx.out.print("mox uninstall: removed {d} state entr(ies); source repo untouched\n", .{removed});
    return 0;
}

/// Remove one state entry, reporting the outcome. A delete FAILURE is reported
/// as kept (not counted as removed), so a permission/IO error never yields a
/// false "removed" line.
fn removeEntry(ctx: *app.Ctx, path: []const u8, removed: *usize) !void {
    if (deleteEntry(ctx.io, path)) |_| {
        removed.* += 1;
        try ctx.out.print("  removed {s}\n", .{path});
    } else |e| {
        try ctx.err.print("  kept {s} (delete failed: {s})\n", .{ path, @errorName(e) });
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
        try ctx.out.print("Delete {s} at {s}? [y/N] ", .{ name, path });
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
    .summary = "Remove mox state",
    .details = "Private preserved unless --purge-private; snapshots and trash preserved unless --purge-snapshots/--purge-trash or confirmed. The source repo is never touched.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "actionFor: private preserved by default, removed on purge; trash prompts" {
    try testing.expectEqual(Action.preserve, actionFor("private", false));
    try testing.expectEqual(Action.remove, actionFor("private", true));
    try testing.expectEqual(Action.prompt, actionFor("trash", false));
    try testing.expectEqual(Action.preserve, actionFor("mox.lock", false));
    try testing.expectEqual(Action.remove, actionFor("applied", false));
    try testing.expectEqual(Action.remove, actionFor("provenance", false));
    // Snapshots hold the pre-mox originals: prompt, never silently removed.
    try testing.expectEqual(Action.prompt, actionFor("snapshots", false));
    try testing.expectEqual(Action.prompt, actionFor("snapshots", true));
}
