//! Instantiates cli-zig's `Cli(cfg)` for mox: the per-command `Context`
//! (env + resolved paths), the help-grouping `Group` enum, the
//! `loadContext` hook that ports `context.zig`'s `init` into cli-zig's
//! shape, and the registered `command_table` every mox command dispatches
//! through.

const std = @import("std");
const cli = @import("cli");
const paths_mod = @import("paths.zig");
const Env = @import("env").Env;

pub const VERSION = @import("build_options").version;

/// Per-command context: process environment plus mox's resolved paths.
/// `arena`/`stdout`/`stderr` are not stored here - cli-zig supplies those
/// per-dispatch as `Ctx.alloc`/`Ctx.out`/`Ctx.err`. The lock stays out too:
/// `loadContext` runs for every `needs_context` command, including
/// read-only ones, so acquiring it here would over-serialize and mislabel -
/// each mutating command's `run_fn` acquires it itself.
pub const Context = struct {
    env: Env,
    paths: paths_mod.Paths,
};

/// mox's help is currently flat (no sections); a single group is the safe
/// default until help-format fidelity is ported in a later task.
pub const Group = enum { general };

/// The environment `loadContext` hands every command, when it should not be
/// the live process one. A caller that drives `run` in-process -- the test
/// harness -- sets this to stand the command up against an environment it
/// controls. Null means the real process environment.
///
/// This exists because `loadContext` is a plain function pointer with no
/// channel for an environment, so the alternative is the process's own -- which
/// cannot be a synthetic one on Windows.
pub var environ_override: ?Env = null;

/// The reader a command's interactive prompts read from, when it should not be
/// the process's own stdin. A caller that drives `run` in-process -- the test
/// harness -- sets this to script the answers to a prompt sequence. Null means
/// real stdin.
///
/// Setting it also means "drive this command as a terminal would": a command
/// that gates its prompts on `tty.isInteractive(0)` treats an injected reader
/// as interactive, since the real fd-0 TTY check says nothing about it.
pub var stdin_override: ?*std.Io.Reader = null;

/// Ports `context.zig`'s `init` into cli-zig's context-loader shape.
/// `loadContext` is a plain function pointer with no access to
/// `std.process.Init`, so the live process environment is read from the
/// same process-global `std.Io.Threaded` populates it into at startup,
/// rather than being passed in. On a `paths_mod.resolve` failure, `diag`
/// carries a message and the error propagates.
pub fn loadContext(alloc: std.mem.Allocator, io: std.Io, diag: *cli.args.Diagnostic) anyerror!Context {
    _ = io;
    const env: Env = environ_override orelse Env.current();
    const paths = paths_mod.resolve(alloc, env) catch |err| {
        diag.message = std.fmt.allocPrint(alloc, "failed to resolve mox paths: {s}", .{@errorName(err)}) catch "";
        return err;
    };
    return .{ .env = env, .paths = paths };
}

/// mox's help footer: the Environment section (`MOX_REPO`/`MOX_STATE_DIR`/
/// `MOX_SNAPSHOT_RETENTION`/`HOME`/`USER`). These are env vars, not CLI
/// flags, so cli-zig's generated per-command help has nowhere else to
/// surface them.
pub fn renderHelpFooter(w: *std.Io.Writer, prog_name: []const u8) anyerror!void {
    _ = prog_name;
    try w.writeAll(
        \\
        \\Environment:
        \\  MOX_REPO       Path to mox dotfiles repo (default: $XDG_DATA_HOME/mox/dotfiles)
        \\  MOX_STATE_DIR  Path to mox state (default: $XDG_STATE_HOME/mox)
        \\  MOX_SNAPSHOT_RETENTION  Snapshots to keep (default: 10)
        \\  HOME, USER     Standard POSIX env
        \\
        \\See the project README for the full design spec.
        \\
    );
}

pub const MoxCli = cli.cli.Cli(.{
    .Context = Context,
    .Group = Group,
    .loadContext = loadContext,
    .messagePrefix = "mox: ",
    .renderHelpFooter = renderHelpFooter,
});

/// The environment a command reads through. A `needs_context` command takes it
/// from its loaded `Context`; one that runs without a context (e.g. `upgrade`,
/// which needs no mox repo) still must not read the process's own environment
/// when a caller (the test harness) supplied one via `environ_override`.
pub fn envOf(ctx: *Ctx) Env {
    if (ctx.context) |c| return c.env;
    return environ_override orelse Env.current();
}

pub const Ctx = MoxCli.Ctx;
pub const Command = MoxCli.Command;
pub const run = MoxCli.run;
pub const command = MoxCli.command;
pub const About = MoxCli.About;

/// Writes `fmt` (caller supplies its own "mox <cmd>: " / "usage: " prefix)
/// to `ctx.err` and returns exit code 2. Used by a subcommand-group's own
/// body (a bare invocation with no useful behavior, or a stray unmatched
/// subcommand name) to report a usage error.
pub fn usageError(ctx: *Ctx, comptime fmt: []const u8, args: anytype) u8 {
    ctx.err.print(fmt, args) catch {};
    return 2;
}

fn versionRun(ctx: *Ctx) anyerror!u8 {
    try ctx.out.print("mox {s}\n", .{VERSION});
    return 0;
}

const version_cmd = Command{
    .name = "version",
    .summary = "Show mox version",
    .group = .general,
    .run = versionRun,
};

const init_cmd = @import("init.zig");
const add_cmd = @import("add.zig");
const addtree_cmd = @import("addtree.zig");
const apply_cmd = @import("apply.zig");
const status_cmd = @import("status.zig");
const secret_cmd = @import("secret.zig");
const trigger_cmd = @import("trigger.zig");
const snapshot_cmd = @import("snapshot.zig");
const rollback_cmd = @import("rollback.zig");
const facts_cmd = @import("facts.zig");
const data_cmd = @import("data.zig");
const commit_cmd = @import("commit.zig");
const diff_cmd = @import("diff.zig");
const edit_cmd = @import("edit.zig");
const export_cmd = @import("export.zig");
const mv_cmd = @import("mv.zig");
const remove_cmd = @import("remove.zig");
const doctor_cmd = @import("doctor.zig");
const uninstall_cmd = @import("uninstall.zig");
const sync_cmd = @import("sync.zig");
const upgrade_cmd = @import("upgrade.zig");

/// Every registered top-level command.
pub const command_table = [_]Command{
    init_cmd.command,
    add_cmd.command,
    addtree_cmd.command,
    apply_cmd.command,
    status_cmd.command,
    secret_cmd.command,
    trigger_cmd.command,
    snapshot_cmd.command,
    rollback_cmd.command,
    facts_cmd.command,
    data_cmd.command,
    commit_cmd.command,
    diff_cmd.command,
    edit_cmd.command,
    export_cmd.command,
    mv_cmd.command,
    remove_cmd.command,
    doctor_cmd.command,
    uninstall_cmd.command,
    sync_cmd.command,
    upgrade_cmd.command,
    version_cmd,
};

const SmokeSpec = struct {};

fn smokeRun(ctx: *Ctx, _: cli.args.Args(SmokeSpec)) anyerror!u8 {
    try ctx.out.writeAll("smoke ok\n");
    return 0;
}

test "MoxCli wiring: a command built via command() dispatches through run() and writes output" {
    const smoke_cmd = command(SmokeSpec, .{
        .name = "smoke",
        .summary = "smoke-tests the cli-zig wiring",
        .group = .general,
    }, smokeRun);

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try run(std.testing.allocator, std.testing.io, &.{ "mox", "smoke" }, &.{smoke_cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("smoke ok\n", out_w.buffered());
}

fn smokeContextRun(ctx: *Ctx, _: cli.args.Args(SmokeSpec)) anyerror!u8 {
    const context = ctx.context.?;
    try ctx.out.print("state_dir={s}\n", .{context.paths.state_dir});
    return 0;
}

test "MoxCli wiring: a needs_context command loads Context via loadContext" {
    const smoke_cmd = command(SmokeSpec, .{
        .name = "smoke-context",
        .summary = "smoke-tests loadContext wiring",
        .group = .general,
        .needs_context = true,
    }, smokeContextRun);

    var out_buf: [512]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    // loadContext's paths.resolve allocations are meant to live in an
    // arena (production wires Ctx.alloc to the process arena in main.zig);
    // an arena here matches that shape instead of leaking against
    // std.testing.allocator's leak checker.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const code = try run(arena_state.allocator(), std.testing.io, &.{ "mox", "smoke-context" }, &.{smoke_cmd}, &out_w, &err_w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.startsWith(u8, out_w.buffered(), "state_dir="));
    try std.testing.expect(out_w.buffered().len > "state_dir=\n".len);
}
