const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");

const Spec = struct {
    uri: cli.spec.Pos([]const u8, .{ .help = "secret URI (env:, file://, op://, pass://, cmd:)" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const u = mox.secret.uri.parse(a.uri) catch |e| {
        try ctx.err.print("mox secret: invalid URI: {s}\n", .{@errorName(e)});
        return 1;
    };
    const value = mox.secret.resolver.resolve(ctx.alloc, ctx.io, context.env, u) catch |e| {
        try ctx.err.print("mox secret: resolution failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    try ctx.out.writeAll(value);
    if (value.len == 0 or value[value.len - 1] != '\n') {
        try ctx.out.writeAll("\n");
    }
    return 0;
}

pub const command = app.command(Spec, .{
    .name = "secret",
    .summary = "Resolve a secret URI to stdout",
    .usage = "mox secret <uri>",
    .group = .general,
    .needs_context = true,
}, run);
