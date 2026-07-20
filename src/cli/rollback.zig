const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const mox = @import("../root.zig");

/// `mox rollback <id>`: restore all live files captured in a snapshot.
///
/// Last-applied records are deliberately left stale, so the next `mox apply`
/// sees the restored files as drift and refuses to overwrite them without
/// --force. Rollback undoes live-file changes; it never touches the source
/// tree.
const Spec = struct {
    id: cli.spec.Pos([]const u8, .{ .help = "snapshot id (see 'mox snapshot list')" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const id = a.id;

    const lk = (try lock_mod.acquireForCommand(ctx, "rollback")) orelse return 1;
    defer lk.release();

    const restored = mox.apply.snapshot.restore(ctx.alloc, ctx.io, context.paths.snapshots_dir, id, context.paths.home) catch |e| switch (e) {
        error.SnapshotNotFound => {
            try ctx.err.print("mox rollback: no snapshot '{s}' (see 'mox snapshot list')\n", .{id});
            return 1;
        },
        else => return e,
    };
    try ctx.out.print("Restored {d} file(s) from snapshot {s}\n", .{ restored.count, id });
    return 0;
}

pub const command = app.command(Spec, .{
    .name = "rollback",
    .summary = "Restore live files from a snapshot",
    .usage = "mox rollback <snapshot-id>",
    .group = .general,
    .needs_context = true,
}, run);
