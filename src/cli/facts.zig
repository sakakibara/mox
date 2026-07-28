const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const tty = @import("tty.zig");
const mox = @import("../root.zig");

const BareSpec = struct {};

/// `mox facts`: list current facts, then interview for any discovered
/// dimension that is still unanswered.
fn run(ctx: *app.Ctx, _: cli.Args(BareSpec)) anyerror!u8 {
    const context = ctx.context.?;
    var facts_diag: mox.machine.facts.Diag = .{};
    const current = mox.machine.facts.load(ctx.alloc, ctx.io, context.paths.facts_path, &facts_diag) catch |e| switch (e) {
        error.ReservedFactName => {
            try ctx.err.print("mox facts: {s}\n", .{facts_diag.capture() orelse "a fact name collides with a reserved axis name"});
            return 1;
        },
        else => return e,
    };
    for (current.facts) |f| {
        try ctx.out.print("{s} = \"{s}\"\n", .{ f.name, f.value });
    }
    for (current.skipped) |key| {
        try ctx.err.print("mox facts: facts.toml: {s}: not a string; ignored (a gate naming it will never match)\n", .{key});
    }

    const discovery = try mox.machine.dimensions.discover(ctx.alloc, ctx.io, context.paths.repo_dir);
    try mox.machine.dimensions.writeDiagnostics(ctx.err, "", discovery.diagnostics, discovery.default_diagnostics);
    // Unlike apply, `facts` has no later, richer source-tree walk to report
    // this failure for it -- so a tree discovery could only degrade to
    // "nothing found" over is a loud refusal here, not a silent empty
    // dimension list.
    if (discovery.tree_error) |e| {
        try ctx.err.print(
            "mox facts: source tree could not be scanned ({s}); fact listing and interview are unavailable until it parses\n",
            .{@errorName(e)},
        );
        return 1;
    }
    if (discovery.dimensions.len == 0) return 0;

    // The interview may persist answers into facts.toml; guard that
    // read-modify-write with the command lock, as `facts set` and `apply` do.
    const lk = (try lock_mod.acquireForCommand(ctx, "facts")) orelse return 1;
    defer lk.release();

    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env, context.paths.repo_dir, context.paths.private_dir);
    var bindings_map = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
    var live_ctx: mox.dsl.resolver.Resolver.Live = m_state.liveResolver(&bindings_map);
    var bindings: mox.dsl.resolver.Resolver = .{ .live = &live_ctx };
    const interactive = tty.isInteractive(0);
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .initStreaming(.stdin(), ctx.io, &stdin_buf);
    const mode: mox.machine.interview.Mode = if (interactive)
        .{ .interactive = .{ .input = &stdin_reader.interface, .out = ctx.out } }
    else
        .report_only;

    const outcome = try mox.machine.interview.walkDimensions(ctx.alloc, discovery.dimensions, &bindings, mode);
    if (outcome.answers.len > 0) {
        try mox.machine.interview.persist(ctx.alloc, ctx.io, context.paths.facts_path, outcome.answers);
        for (outcome.answers) |a| {
            try ctx.out.print("{s} = \"{s}\"\n", .{ a.name, a.value });
        }
    }
    // Unlike apply, facts never composes a file: refusing here costs nothing
    // and surfaces an unresolved fact immediately instead of leaving it
    // silently unbound.
    if (outcome.unbound.len > 0) {
        try ctx.err.writeAll("missing facts:");
        for (outcome.unbound) |n| try ctx.err.print(" {s}", .{n});
        try ctx.err.writeAll("\nSet directly with 'mox facts set <name> <value>'.\n");
        return 1;
    }
    return 0;
}

const SetSpec = struct {
    name: cli.Pos([]const u8, .{ .help = "fact name" }),
    value: cli.Pos([]const u8, .{ .help = "fact value" }),
};

fn setRun(ctx: *app.Ctx, a: cli.Args(SetSpec)) anyerror!u8 {
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

const ProbeSpec = struct {
    query: cli.Pos([]const u8, .{ .help = "tool=<name> or env=<name>" }),
};

const probe_usage = "mox facts probe: usage: mox facts probe tool=<name> | env=<name>\n";

/// `mox facts probe <axis>=<name>`: probes live (the same `tool=`/`env=`
/// resolution `apply`/`status` use), the scriptable single-name
/// diagnostic counterpart to status's probe-log section. Exits 0 when bound,
/// 1 when not -- distinct from a usage error (2), so a caller can tell
/// "asked and unbound" from "asked wrong".
fn probeRun(ctx: *app.Ctx, a: cli.Args(ProbeSpec)) anyerror!u8 {
    const context = ctx.context.?;
    const eq = std.mem.indexOfScalar(u8, a.query, '=') orelse
        return app.usageError(ctx, probe_usage, .{});
    const axis = a.query[0..eq];
    const name = a.query[eq + 1 ..];
    if (name.len == 0) return app.usageError(ctx, probe_usage, .{});
    const is_tool = std.mem.eql(u8, axis, "tool");
    const is_env = std.mem.eql(u8, axis, "env");
    if (!is_tool and !is_env) {
        return app.usageError(ctx, "mox facts probe: unknown axis '{s}' (expected tool or env)\n", .{axis});
    }

    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env, context.paths.repo_dir, context.paths.private_dir);
    const found: ?[]const u8 = if (is_tool)
        m_state.tool_probe.?.path(name)
    else
        m_state.env_probe.?.get(name);
    if (found) |v| {
        try ctx.out.print("present {s}\n", .{v});
        return 0;
    }
    try ctx.out.writeAll("absent\n");
    return 1;
}

const probe_cmd = app.command(ProbeSpec, .{
    .name = "probe",
    .summary = "Probe tool=/env= live; exit 0 when bound, 1 when not",
    .usage = "mox facts probe tool=<name> | env=<name>",
    .group = .general,
    .needs_context = true,
}, probeRun);

pub const command = blk: {
    var c = app.command(BareSpec, .{
        .name = "facts",
        .summary = "List facts; interview for missing ones",
        .group = .general,
        .needs_context = true,
    }, run);
    c.subcommands = &.{ set_cmd, probe_cmd };
    break :blk c;
};
