const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");

const Spec = struct {};

/// `mox snapshot` / `mox snapshot list`: list snapshot ids, oldest first.
fn list(ctx: *app.Ctx, _: cli.args.Args(Spec)) anyerror!u8 {
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

const list_cmd = app.command(Spec, .{
    .name = "list",
    .summary = "List apply snapshots, oldest first",
    .group = .general,
    .needs_context = true,
}, list);

pub const command = blk: {
    var c = app.command(Spec, .{
        .name = "snapshot",
        .summary = "List apply snapshots (taken before every overwrite)",
        .group = .general,
        .needs_context = true,
    }, list);
    c.subcommands = &.{list_cmd};
    break :blk c;
};
