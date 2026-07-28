const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const tty = @import("tty.zig");
const mox = @import("../root.zig");

const BareSpec = struct {
    report: cli.Flag(.{ .help = "print every dimension's state (bound/declined/UNBOUND), provenance, and asking-condition instead" }),
};

/// `mox facts`: list current facts, then interview for any discovered
/// dimension that is still unanswered. `--report` replaces that whole
/// output with `reportDimensions`'s state-per-dimension listing instead --
/// bare mode's `name = "value"` lines are a machine-readable format other
/// tooling parses, kept byte-frozen, so a richer report is a distinct mode
/// rather than something appended to it.
fn run(ctx: *app.Ctx, args: cli.Args(BareSpec)) anyerror!u8 {
    const context = ctx.context.?;
    var facts_diag: mox.machine.facts.Diag = .{};
    const current = mox.machine.facts.load(ctx.alloc, ctx.io, context.paths.facts_path, &facts_diag) catch |e| switch (e) {
        error.ReservedFactName => {
            try ctx.err.print("mox facts: {s}\n", .{facts_diag.capture() orelse "a fact name collides with a reserved axis name"});
            return 1;
        },
        else => return e,
    };
    if (!args.report) {
        for (current.facts) |f| {
            try ctx.out.print("{s} = \"{s}\"\n", .{ f.name, f.value });
        }
    }
    for (current.skipped) |key| {
        try ctx.err.print("mox facts: facts.toml: {s}: not a string; ignored (a gate naming it will never match)\n", .{key});
    }

    const discovery = try mox.machine.dimensions.discover(ctx.alloc, ctx.io, context.paths.repo_dir);
    try mox.machine.dimensions.writeDiagnostics(ctx.err, "", discovery.diagnostics, discovery.default_diagnostics);
    // Unlike apply, `facts` has no later, richer source-tree walk that could
    // still surface this failure downstream -- so a tree-discovery error
    // here is a loud refusal, not a silent degrade to an empty dimension
    // list.
    if (discovery.tree_error) |e| {
        try ctx.err.print(
            "mox facts: source tree could not be scanned ({s}); fact listing and interview are unavailable until it parses\n",
            .{@errorName(e)},
        );
        return 1;
    }
    if (args.report) return reportDimensions(ctx, discovery, current.facts);
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

/// `mox facts --report`'s body: every discovered dimension's current state
/// (bound with its value, declined -- bound empty, or UNBOUND against
/// `facts`, which is facts.toml's own content -- a dimension is never bound
/// through any other source), its provenance, and its asking-condition when
/// it has one, one line each, in `discovery.dimensions`'s own (sorted-by-
/// name) order. Read-only: never interviews, never persists.
fn reportDimensions(ctx: *app.Ctx, discovery: mox.machine.dimensions.Discovery, facts: []const mox.machine.state.Fact) !u8 {
    for (discovery.dimensions) |dim| {
        try ctx.out.print("{s}: ", .{dim.name});
        if (findFactValue(facts, dim.name)) |v| {
            if (v.len > 0) {
                try ctx.out.print("bound \"{s}\"", .{v});
            } else {
                try ctx.out.writeAll("declined (bound empty)");
            }
        } else {
            try ctx.out.writeAll("UNBOUND");
        }
        try ctx.out.writeAll(" (");
        try mox.machine.dimensions.writeProvenance(ctx.out, dim.provenance);
        try ctx.out.writeAll(")");
        if (dim.asking_condition) |cond| {
            try ctx.out.writeAll(" -- asked when ");
            try mox.dsl.ast.writeExpr(ctx.out, cond);
        }
        try ctx.out.writeAll("\n");
    }
    return 0;
}

fn findFactValue(facts: []const mox.machine.state.Fact, name: []const u8) ?[]const u8 {
    for (facts) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
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

const AskSpec = struct {
    name: cli.Pos([]const u8, .{ .optional = true, .help = "re-interview only this fact, even if already bound" }),
};

fn findDimension(dims: []const mox.machine.dimensions.Dimension, name: []const u8) ?mox.machine.dimensions.Dimension {
    for (dims) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

/// `mox facts ask [<name>]`: re-runs the interview interactively, reusing
/// `interview.walkDimensions`/`askDimension` unchanged -- never a forked
/// prompt path. Both forms work by widening ELIGIBILITY, not by changing how
/// a dimension is asked: `walkDimensions` skips any name `bindings_map`
/// already answers, so this clears the relevant entries from a cloned
/// binding set before calling it, then restores nothing (the clone is
/// scratch).
///
/// With `<name>`: that dimension alone, even if already bound to a real
/// value -- the change-an-answer flow (full choices/default/provenance UX).
/// Its own `asking_condition` is forced null so it is unconditionally
/// eligible regardless of other bindings: naming it is the user's own
/// override of whatever would normally gate it.
///
/// Bare: every dimension currently unbound OR declined (bound empty) whose
/// condition holds -- wider than the standard interview, which treats a
/// decline as terminal and never revisits it. Every currently-declined name
/// is cleared from the clone so `walkDimensions`'s own fixpoint/deferral
/// logic treats it as unbound again; an already-answered non-empty fact is
/// untouched and stays skipped.
///
/// Refuses on a non-TTY (no `scripted_input` seam either): there is no
/// meaningful non-interactive form of "ask again".
fn askRun(ctx: *app.Ctx, a: cli.Args(AskSpec)) anyerror!u8 {
    const context = ctx.context.?;
    const scripted_input = app.stdin_override;
    if (scripted_input == null and !tty.isInteractive(0)) {
        try ctx.err.writeAll("mox facts ask: refusing -- not a terminal (no stdin to interview from)\n");
        return 1;
    }

    const discovery = try mox.machine.dimensions.discover(ctx.alloc, ctx.io, context.paths.repo_dir);
    try mox.machine.dimensions.writeDiagnostics(ctx.err, "", discovery.diagnostics, discovery.default_diagnostics);
    if (discovery.tree_error) |e| {
        try ctx.err.print(
            "mox facts ask: source tree could not be scanned ({s}); the interview is unavailable until it parses\n",
            .{@errorName(e)},
        );
        return 1;
    }

    var target: ?mox.machine.dimensions.Dimension = null;
    if (a.name) |name| {
        target = findDimension(discovery.dimensions, name) orelse {
            try ctx.err.print("mox facts ask: \"{s}\" is not a fact this repo's sources consume\n", .{name});
            return 1;
        };
    } else if (discovery.dimensions.len == 0) {
        return 0;
    }

    const lk = (try lock_mod.acquireForCommand(ctx, "facts ask")) orelse return 1;
    defer lk.release();

    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env, context.paths.repo_dir, context.paths.private_dir);
    var bindings_map = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);

    var dims: []const mox.machine.dimensions.Dimension = discovery.dimensions;
    if (target) |dim| {
        _ = bindings_map.remove(dim.name);
        var forced = dim;
        forced.asking_condition = null;
        const one = try ctx.alloc.alloc(mox.machine.dimensions.Dimension, 1);
        one[0] = forced;
        dims = one;
    } else {
        for (discovery.dimensions) |dim| {
            if (bindings_map.get(dim.name)) |v| {
                if (v.len == 0) _ = bindings_map.remove(dim.name);
            }
        }
    }

    var live_ctx: mox.dsl.resolver.Resolver.Live = m_state.liveResolver(&bindings_map);
    var bindings: mox.dsl.resolver.Resolver = .{ .live = &live_ctx };
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .initStreaming(.stdin(), ctx.io, &stdin_buf);
    const input: *std.Io.Reader = scripted_input orelse &stdin_reader.interface;
    const mode: mox.machine.interview.Mode = .{ .interactive = .{ .input = input, .out = ctx.out } };

    const outcome = try mox.machine.interview.walkDimensions(ctx.alloc, dims, &bindings, mode);
    if (outcome.answers.len > 0) {
        try mox.machine.interview.persist(ctx.alloc, ctx.io, context.paths.facts_path, outcome.answers);
        for (outcome.answers) |ans| {
            try ctx.out.print("{s} = \"{s}\"\n", .{ ans.name, ans.value });
        }
    }
    return 0;
}

const ask_cmd = app.command(AskSpec, .{
    .name = "ask",
    .summary = "Re-interview one fact, or every unbound/declined one",
    .usage = "mox facts ask [<name>]",
    .group = .general,
    .needs_context = true,
}, askRun);

pub const command = blk: {
    var c = app.command(BareSpec, .{
        .name = "facts",
        .summary = "List facts; interview for missing ones",
        .group = .general,
        .needs_context = true,
    }, run);
    c.subcommands = &.{ set_cmd, probe_cmd, ask_cmd };
    break :blk c;
};
