const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");

const Spec = struct {};

/// `mox snapshot`: list snapshot ids, oldest first.
fn list(ctx: *app.Ctx, _: cli.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const ids = try mox.apply.snapshot.list(ctx.alloc, ctx.io, context.paths.snapshots_dir);
    if (ids.len == 0) {
        try ctx.out.writeAll("no snapshots\n");
        return 0;
    }
    for (ids) |id| {
        try ctx.out.print("{s}\n", .{id});
    }
    return 0;
}

pub const command = app.command(Spec, .{
    .name = "snapshot",
    .summary = "List apply snapshots (taken before every overwrite)",
    .group = .general,
    .needs_context = true,
}, list);
