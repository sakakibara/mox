const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");

const HashSpec = struct {
    files: cli.spec.Rest(.{ .help = "files to hash-check" }),
};

fn hash(ctx: *app.Ctx, a: cli.args.Args(HashSpec)) anyerror!u8 {
    const context = ctx.context.?;
    if (a.files.len == 0) {
        try ctx.err.writeAll("mox trigger hash: usage: mox trigger hash <file>...\n");
        return 2;
    }
    var state = try mox.trigger.state.State.loadOrEmpty(ctx.alloc, ctx.io, context.paths.triggers_path);
    const changed = try state.checkHash(ctx.alloc, a.files);
    try state.save();
    return if (changed) 0 else 1;
}

const SeenVersionSpec = struct {
    key: cli.spec.Pos([]const u8, .{ .help = "trigger key" }),
};

fn seenVersion(ctx: *app.Ctx, a: cli.args.Args(SeenVersionSpec)) anyerror!u8 {
    const context = ctx.context.?;
    var state = try mox.trigger.state.State.loadOrEmpty(ctx.alloc, ctx.io, context.paths.triggers_path);
    const first_time = try state.checkSeenVersion(ctx.alloc, a.key);
    try state.save();
    return if (first_time) 0 else 1;
}

const EverySpec = struct {
    key: cli.spec.Pos([]const u8, .{ .help = "trigger key" }),
    interval: cli.spec.Pos(i64, .{ .help = "interval, in seconds" }),
};

fn every(ctx: *app.Ctx, a: cli.args.Args(EverySpec)) anyerror!u8 {
    const context = ctx.context.?;
    var state = try mox.trigger.state.State.loadOrEmpty(ctx.alloc, ctx.io, context.paths.triggers_path);
    const ready = try state.checkEvery(ctx.alloc, a.key, a.interval);
    try state.save();
    return if (ready) 0 else 1;
}

const hash_cmd = app.command(HashSpec, .{
    .name = "hash",
    .summary = "First-time / changed-hash check over one or more files",
    .usage = "mox trigger hash <file>...",
    .group = .general,
    .needs_context = true,
}, hash);

const seen_version_cmd = app.command(SeenVersionSpec, .{
    .name = "seen-version",
    .summary = "First-time-seen check for a key",
    .usage = "mox trigger seen-version <key>",
    .group = .general,
    .needs_context = true,
}, seenVersion);

const every_cmd = app.command(EverySpec, .{
    .name = "every",
    .summary = "Interval-elapsed check for a key",
    .usage = "mox trigger every <key> <interval-seconds>",
    .group = .general,
    .needs_context = true,
}, every);

fn triggerUsage(ctx: *app.Ctx) anyerror!u8 {
    if (ctx.argv.len > 0 and !cli.spec.looksLikeFlag(ctx.argv[0])) {
        return app.usageError(ctx, "mox trigger: unknown subcommand '{s}'\n", .{ctx.argv[0]});
    }
    return app.usageError(ctx, "mox trigger: usage: mox trigger {{hash|seen-version|every}} ...\n", .{});
}

pub const command = app.Command{
    .name = "trigger",
    .summary = "Setup-script staleness primitives",
    .details = "hash|seen-version|every.",
    .group = .general,
    .run = triggerUsage,
    .subcommands = &.{ hash_cmd, seen_version_cmd, every_cmd },
};
