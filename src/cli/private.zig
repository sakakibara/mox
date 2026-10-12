//! `mox private`: the private layer's expectation.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");
const display = @import("display.zig");

const BareSpec = struct {};

fn bare(ctx: *app.Ctx, _: cli.Args(BareSpec)) anyerror!u8 {
    try ctx.err.writeAll("mox private: name a subcommand: retire\n");
    return 2;
}

const RetireSpec = struct {
    dry_run: cli.Flag(.{ .help = "say whether there is an expectation to retire, and change nothing" }),
};

/// Stop expecting a private layer for this repo and HOME.
fn retire(ctx: *app.Ctx, a: cli.Args(RetireSpec)) anyerror!u8 {
    const context = ctx.context.?;
    const tag = try mox.apply.applied.repoTag(ctx.alloc, ctx.io, context.paths.repo_dir, context.paths.home);
    const shown = display.of(context.paths.private_dir, context.paths.home);
    if (!try mox.private.expect.retire(ctx.alloc, ctx.io, context.paths.state_dir, tag, a.dry_run)) {
        try ctx.out.print("no private layer at {f} is expected here; nothing to retire\n", .{shown});
        return 0;
    }
    if (a.dry_run) {
        try ctx.out.print("would stop expecting the private layer at {f}\n", .{shown});
    } else try ctx.out.print("stopped expecting the private layer at {f}; the next apply treats it as absent\n", .{shown});
    return 0;
}

const retire_cmd = app.command(RetireSpec, .{
    .name = "retire",
    .summary = "Stop expecting a private layer that is gone on purpose",
    .usage = "mox private retire [--dry-run]",
    .details = "Once an apply has seen a private layer holding sources, every command that composes refuses while it is absent, not a directory, or holding no source. retire removes that expectation for this repo and HOME. The next apply then treats the private layer as absent, and its sweeps remove the files only it provided, snapshot first, as for any source that left the tree.",
    .group = .general,
    .needs_context = true,
}, retire);

pub const command = blk: {
    var c = app.command(BareSpec, .{
        .name = "private",
        .usage = "mox private <command>",
        .summary = "Manage the private layer's expectation",
        .group = .general,
        .needs_context = true,
    }, bare);
    c.subcommands = &.{retire_cmd};
    break :blk c;
};
