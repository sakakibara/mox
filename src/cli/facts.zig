const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const tty = @import("tty.zig");
const mox = @import("../root.zig");

const BareSpec = struct {};

/// `mox facts`: list current facts, then interview for any schema-declared
/// facts that are still unanswered.
fn run(ctx: *app.Ctx, _: cli.args.Args(BareSpec)) anyerror!u8 {
    const context = ctx.context.?;
    const current = try mox.machine.facts.load(ctx.alloc, ctx.io, context.paths.facts_path);
    for (current) |f| {
        try ctx.out.print("{s} = \"{s}\"\n", .{ f.name, f.value });
    }

    const schema = try mox.machine.interview.loadSchema(ctx.alloc, ctx.io, context.paths.repo_dir);
    if (schema.len == 0) return 0;

    // The interview may persist answers into facts.toml; guard that
    // read-modify-write with the command lock, as `facts set` and `apply` do.
    const lk = (try lock_mod.acquireForCommand(ctx, "facts")) orelse return 1;
    defer lk.release();

    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
    var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);

    const interactive = tty.isInteractive(0);
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .initStreaming(.stdin(), ctx.io, &stdin_buf);
    const input: ?*std.Io.Reader = if (interactive) &stdin_reader.interface else null;

    const outcome = try mox.machine.interview.walk(ctx.alloc, schema, &bindings, input, if (interactive) ctx.out else null);
    if (outcome.answers.len > 0) {
        try mox.machine.interview.persist(ctx.alloc, ctx.io, context.paths.facts_path, outcome.answers);
        for (outcome.answers) |a| {
            try ctx.out.print("{s} = \"{s}\"\n", .{ a.name, a.value });
        }
    }
    if (outcome.unanswered.len > 0) {
        try ctx.err.writeAll("missing facts:");
        for (outcome.unanswered) |f| try ctx.err.print(" {s}", .{f.name});
        try ctx.err.writeAll("\nSet directly with 'mox facts set <name> <value>'.\n");
        return 1;
    }
    return 0;
}

const SetSpec = struct {
    name: cli.spec.Pos([]const u8, .{ .help = "fact name" }),
    value: cli.spec.Pos([]const u8, .{ .help = "fact value" }),
};

fn setRun(ctx: *app.Ctx, a: cli.args.Args(SetSpec)) anyerror!u8 {
    const context = ctx.context.?;
    const lk = (try lock_mod.acquireForCommand(ctx, "facts set")) orelse return 1;
    defer lk.release();
    const answers = [_]mox.machine.state.Fact{
        .{ .name = a.name, .value = a.value },
    };
    mox.machine.interview.persist(ctx.alloc, ctx.io, context.paths.facts_path, &answers) catch |e| switch (e) {
        error.InvalidFactName => {
            try ctx.err.writeAll("mox facts set: invalid name (use letters, digits, '_' or '-')\n");
            return 2;
        },
        error.InvalidFactValue => {
            try ctx.err.writeAll("mox facts set: value contains a control character\n");
            return 2;
        },
        else => return e,
    };
    try ctx.out.print("{s} = \"{s}\"\n", .{ a.name, a.value });
    return 0;
}

const set_cmd = app.command(SetSpec, .{
    .name = "set",
    .summary = "Write one fact directly",
    .usage = "mox facts set <name> <value>",
    .group = .general,
    .needs_context = true,
}, setRun);

pub const command = blk: {
    var c = app.command(BareSpec, .{
        .name = "facts",
        .summary = "List facts; interview for missing ones",
        .group = .general,
        .needs_context = true,
    }, run);
    c.subcommands = &.{set_cmd};
    break :blk c;
};
