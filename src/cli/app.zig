//! Instantiates cli-zig's `Cli(cfg)` for mox: the per-command `Context`
//! (env + resolved paths), the help-grouping `Group` enum, the
//! `loadContext` hook that ports `context.zig`'s `init` into cli-zig's
//! shape, and the registered `command_table` every mox command dispatches
//! through.

const std = @import("std");
const cli = @import("cli");
const paths_mod = @import("paths.zig");
const Env = @import("env").Env;
const mox = @import("../root.zig");

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
    /// The directory a non-absolute path argument resolves against. Null when
    /// the process has no readable current directory (an unlinked cwd): the
    /// commands that take one report that for a relative argument, and resolve
    /// an absolute or `~` one as usual.
    cwd: ?[]const u8,
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

/// The directory a command resolves relative path arguments against, when it
/// should not be the process's own. A caller that drives `run` in-process --
/// the test harness -- sets this to place a command somewhere without moving
/// the process, whose cwd is global and shared with every test running beside
/// it. Null means the real one.
pub var cwd_override: ?[]const u8 = null;

/// The runner every backend adapter reaches its package manager through,
/// when it should not be a real child process. A caller that drives `run`
/// in-process -- the test harness -- sets this so the package path is
/// exercised without a manager installed and without touching the machine
/// running the suite. Null means spawn for real.
pub var package_runner_override: ?mox.packages.exec.Runner = null;

/// Every package backend this run can use: the seven mox ships, then every
/// plugin the repo carries under `scripts/backends/`. Built once so `status`,
/// `apply` and `commit` can never disagree about which exist or how they are
/// reached.
///
/// Registered is not the same as usable: a dnf row on a mac names a real
/// backend that this machine simply cannot run, which is inert. A row naming
/// nothing here is a typo, and says so. A plugin sharing a shipped backend's
/// name overrides it -- shadowing, as the private layer shadows the repo --
/// and `status` says so on every run.
pub const PackageBackends = struct {
    proc: mox.packages.exec.Process = undefined,
    brew: mox.packages.brew.Brew = undefined,
    apt: mox.packages.linux.Distro = undefined,
    dnf: mox.packages.linux.Distro = undefined,
    pacman: mox.packages.linux.Distro = undefined,
    scoop: mox.packages.windows.Scoop = undefined,
    winget: mox.packages.windows.Winget = undefined,
    zypper: mox.packages.zypper.Zypper = undefined,
    plugins: []mox.packages.plugin.Plugin = &.{},
    list: []mox.packages.backend.Backend = &.{},
    /// Every discovered plugin by path, an override of a shipped backend, a
    /// plugin this machine cannot run: printed before any backend is asked
    /// anything, so what will execute is visible rather than inferred.
    notes: []const []const u8 = &.{},

    pub fn runner(self: *PackageBackends) mox.packages.exec.Runner {
        return package_runner_override orelse self.proc.runner();
    }

    /// `scratch_dir` stages a manager's own export file and a plugin's stdin;
    /// mox's state directory keeps both inside a directory mox already owns.
    /// `env` is what every backend and plugin runs under; apply hands its
    /// script environment so a bootstrap's PATH addition reaches the probes
    /// that follow in the same run. Plugins are discovered only when
    /// `discover_plugins`: a repo that carries no manifest is not using the
    /// subsystem, and must not have its executables run by a `status`.
    /// `out`/`err` are flushed before every spawn, so what mox printed about a
    /// call precedes the call's own output. `diag` names a plugin that cannot be discovered (bad name, missing
    /// executable bit, two files for one name). Nothing here runs a plugin.
    pub fn registry(
        self: *PackageBackends,
        arena: std.mem.Allocator,
        io: std.Io,
        scratch_dir: []const u8,
        home: []const u8,
        env: ?*const std.process.Environ.Map,
        repo_dir: []const u8,
        discover_plugins: bool,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
        diag: ?*mox.packages.manifest.Diag,
    ) !mox.packages.backend.Registry {
        self.proc = .{
            .io = io,
            .env = env,
            .scratch_dir = scratch_dir,
            .timeout_ms = mox.packages.exec.timeoutFromEnv(env, err),
            .out = out,
            .err = err,
        };
        const r = self.runner();
        self.brew = .{ .runner = r, .io = io, .scratch_dir = scratch_dir };
        self.apt = .{ .manager = .apt, .runner = r };
        self.dnf = .{ .manager = .dnf, .runner = r };
        self.pacman = .{ .manager = .pacman, .runner = r };
        self.scoop = .{ .runner = r, .home = home };
        self.winget = .{ .runner = r, .io = io, .scratch_dir = scratch_dir };
        self.zypper = .{
            .runner = r,
            .ledger = .{ .io = io, .dir = scratch_dir, .backend = "zypper" },
        };

        var list: std.ArrayList(mox.packages.backend.Backend) = .empty;
        try list.appendSlice(arena, &.{
            self.brew.backend(),
            self.apt.backend(),
            self.dnf.backend(),
            self.pacman.backend(),
            self.scoop.backend(),
            self.winget.backend(),
            self.zypper.backend(),
        });

        var notes: std.ArrayList([]const u8) = .empty;
        const found: []const mox.packages.discover.Found = if (discover_plugins)
            try mox.packages.discover.discover(arena, io, repo_dir, diag)
        else
            &.{};
        self.plugins = try arena.alloc(mox.packages.plugin.Plugin, found.len);
        for (found, 0..) |f, i| {
            self.plugins[i] = .{ .name = f.name, .argv0 = f.argv0, .runner = r, .not_runnable = f.not_runnable };
            const pl = &self.plugins[i];
            if (f.not_runnable) |why| {
                try notes.append(arena, try std.fmt.allocPrint(arena, "backend {s}: {s}: {s}", .{ f.name, f.label, why }));
            } else {
                try notes.append(arena, try std.fmt.allocPrint(arena, "backend {s}: {s}", .{ f.name, f.label }));
            }

            var replaced = false;
            for (list.items) |*b| {
                if (std.mem.eql(u8, b.name, f.name)) {
                    b.* = pl.backend();
                    replaced = true;
                    try notes.append(arena, try std.fmt.allocPrint(arena, "{s}: {s} overrides the built-in", .{ f.name, f.label }));
                    break;
                }
            }
            if (!replaced) try list.append(arena, pl.backend());
        }
        self.list = try list.toOwnedSlice(arena);
        self.notes = try notes.toOwnedSlice(arena);
        return .{ .backends = self.list };
    }
};

/// Ports `context.zig`'s `init` into cli-zig's context-loader shape.
/// `loadContext` is a plain function pointer with no access to
/// `std.process.Init`, so the live process environment is read from the
/// same process-global `std.Io.Threaded` populates it into at startup,
/// rather than being passed in. On a `paths_mod.resolve` failure, `diag`
/// carries a message and the error propagates.
pub fn loadContext(alloc: std.mem.Allocator, io: std.Io, diag: *cli.Diagnostic) anyerror!Context {
    const env: Env = environ_override orelse Env.current();
    const paths = paths_mod.resolve(alloc, env) catch |err| {
        diag.message = std.fmt.allocPrint(alloc, "failed to resolve mox paths: {s}", .{@errorName(err)}) catch "";
        return err;
    };
    // An unreadable cwd is not a startup failure: only a relative path
    // argument needs one, and every command that takes none runs regardless.
    const cwd: ?[]const u8 = cwd_override orelse (std.process.currentPathAlloc(io, alloc) catch null);
    return .{ .env = env, .paths = paths, .cwd = cwd };
}

/// mox's help footer: the Environment section (`MOX_REPO`/`MOX_STATE_DIR`/
/// `MOX_SNAPSHOT_RETENTION`/`MOX_CHECK_TIMEOUT_MS`/`HOME`/`USER`). These are
/// env vars, not CLI flags, so cli-zig's generated per-command help has
/// nowhere else to surface them.
pub fn renderHelpFooter(w: *std.Io.Writer, prog_name: []const u8) anyerror!void {
    _ = prog_name;
    try w.writeAll(
        \\
        \\Environment:
        \\  MOX_REPO       Path to mox dotfiles repo (default: $XDG_DATA_HOME/mox/dotfiles)
        \\  MOX_STATE_DIR  Path to mox state (default: $XDG_STATE_HOME/mox)
        \\  MOX_SNAPSHOT_RETENTION  Snapshots to keep (default: 10)
        \\  MOX_CHECK_TIMEOUT_MS  Wall-clock bound on check hooks in ms (default: 30000; <= 0 disables)
        \\  HOME, USER     Standard POSIX env
        \\
        \\See the project README for the full design spec.
        \\
    );
}

/// `.dynamic` completion resolver for every `paths` positional (`status`,
/// `diff`, `apply`, `commit`). `key == "managed-file"` walks the source tree
/// (base + private layer) and offers every managed file's live path; any
/// other key, or a `loadContext` failure (no `ctx.context`), yields no
/// candidates -- broken completion must never crash the shell.
fn moxResolveCompletion(alloc: std.mem.Allocator, key: []const u8, prev: ?[]const u8, cur: []const u8, ctx: anytype) anyerror!cli.complete.Result {
    _ = prev;
    _ = cur;
    const none: cli.complete.Result = .{ .directive = .default, .candidates = &.{} };
    if (!std.mem.eql(u8, key, "managed-file")) return none;
    const context = ctx.context orelse return none;

    const src_dir = std.fs.path.join(alloc, &.{ context.paths.repo_dir, "src" }) catch return none;
    const base_tree = mox.source.tree.walk(alloc, ctx.io, src_dir, context.paths.home) catch return none;
    const tree = mox.private.layer.merge(alloc, ctx.io, base_tree, context.paths.private_dir, context.paths.home) catch return none;

    var out: std.ArrayList(cli.complete.Candidate) = .empty;
    for (tree.files) |f| {
        out.append(alloc, .{ .value = f.live_path }) catch return none;
    }
    return .{ .directive = .default, .candidates = out.toOwnedSlice(alloc) catch return none };
}

pub const MoxCli = cli.App(.{
    .Context = Context,
    .Group = Group,
    .loadContext = loadContext,
    .messagePrefix = "mox: ",
    .renderHelpFooter = renderHelpFooter,
    .resolveCompletion = moxResolveCompletion,
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
const update_cmd = @import("update.zig");
const publish_cmd = @import("publish.zig");
const path_cmd = @import("path.zig");
const git_cmd = @import("git.zig");
const upgrade_cmd = @import("upgrade.zig");

/// Every registered top-level command.
pub const command_table = [_]Command{
    init_cmd.command,
    add_cmd.command,
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
    update_cmd.command,
    publish_cmd.command,
    path_cmd.command,
    git_cmd.command,
    upgrade_cmd.command,
    version_cmd,
};

const SmokeSpec = struct {};

fn smokeRun(ctx: *Ctx, _: cli.Args(SmokeSpec)) anyerror!u8 {
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

fn smokeContextRun(ctx: *Ctx, _: cli.Args(SmokeSpec)) anyerror!u8 {
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

/// The environment every package backend and plugin runs under, for a
/// command that has captured the machine: the setup-script environment
/// (MOX_REPO, MOX_STATE_DIR, MOX_HOME, a PATH, every fact as MOX_FACT_*),
/// built without refreshing the state bin dir -- that is apply's job, and a
/// read-only command must not rewrite state on the way to a report.
pub fn packageEnv(
    ctx: *Ctx,
    context: Context,
    m_state: mox.machine.state.MachineState,
) !*std.process.Environ.Map {
    const facts = try ctx.alloc.alloc(mox.apply.run_scripts.Fact, m_state.custom_facts.len);
    for (m_state.custom_facts, 0..) |f, i| facts[i] = .{ .name = f.name, .value = f.value };
    const built = try mox.apply.run_scripts.buildScriptEnv(
        ctx.alloc,
        ctx.io,
        context.env,
        context.paths.repo_dir,
        context.paths.state_dir,
        context.paths.home,
        facts,
        false,
    );
    const map = try ctx.alloc.create(std.process.Environ.Map);
    map.* = built.map;
    return map;
}
