const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const apply = @import("apply.zig");
const mox = @import("../root.zig");
const display = @import("display.zig");
const clt = @import("clt.zig");

const Io = std.Io;
const exec = mox.packages.exec;

/// How a `git clone` that ran ended, when it did not succeed.
const CloneFailure = struct {
    /// git's exit code; null when it ended any other way.
    code: ?u8,
    stderr: []const u8,
};

/// Seam over `git clone` so the guard and orchestration can be tested without
/// a real subprocess. The default is `gitClone`.
const CloneFn = *const fn (std.mem.Allocator, Io, mox.env.Env, []const u8, []const u8) anyerror!?CloneFailure;

const Spec = struct {
    clone: cli.Opt([]const u8, .{ .value_name = "url", .help = "git clone <url> into the repo dir (review it, then run 'mox apply'); <owner>, <owner>/<repo>, and <host>/<owner>/<repo> are shorthand for https URLs (owner alone assumes a repo named dotfiles)" }),
    apply: cli.Flag(.{ .help = "after cloning, apply immediately (write files, run scripts) instead of stopping to review" }),
    defaults: cli.Flag(.{ .help = "with --apply: never prompt in the facts interview; bind declared defaults and decline the rest" }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    if (a.clone) |raw| {
        if (raw.len == 0) {
            try ctx.err.writeAll("mox init: --clone requires a repository URL\n");
            return 2;
        }
        const url = try resolveCloneUrl(ctx.alloc, raw);
        // A credential cached for the Command Line Tools stays fresh through
        // the apply, so Homebrew's bootstrap does not ask for it again.
        var keepalive: mox.packages.admin.Keepalive = .{};
        defer keepalive.stop();
        const rc = try runClone(ctx, url, gitClone, a.apply, &keepalive);
        if (rc != 0) return rc;
        // Opt-in one-command bootstrap: clone, then apply a repo the user trusts.
        if (a.apply) return apply.applyImpl(ctx, false, false, false, a.defaults, .auto, &.{}, &keepalive);
        return rc;
    }
    const rc = try initFresh(ctx);
    if (rc != 0) return rc;
    if (a.apply) return apply.applyImpl(ctx, false, false, false, a.defaults, .auto, &.{}, null);
    return rc;
}

/// Expand a `--clone` shorthand into a git URL. Sugar only: anything that
/// could already be a URL, an scp-style remote, or a local path passes
/// through verbatim, so no clonable spelling is lost.
///
///   owner            -> https://github.com/owner/dotfiles
///   owner/repo       -> https://github.com/owner/repo
///   host/owner/repo  -> https://host/owner/repo
///
/// Verbatim: a scheme (`://`), any colon (scp-style `git@host:path`, drive
/// letters), a leading `/`, `.`, or `~` (local paths), an empty segment, or
/// a character outside [A-Za-z0-9._-].
fn resolveCloneUrl(arena: std.mem.Allocator, arg: []const u8) ![]const u8 {
    if (arg.len == 0) return arg;
    if (std.mem.indexOfScalar(u8, arg, ':') != null) return arg;
    if (arg[0] == '/' or arg[0] == '.' or arg[0] == '~') return arg;

    var slashes: usize = 0;
    var seg_len: usize = 0;
    for (arg) |c| {
        if (c == '/') {
            if (seg_len == 0) return arg;
            slashes += 1;
            seg_len = 0;
            continue;
        }
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
        if (!ok) return arg;
        seg_len += 1;
    }
    if (seg_len == 0) return arg;

    return switch (slashes) {
        0 => std.fmt.allocPrint(arena, "https://github.com/{s}/dotfiles", .{arg}),
        1 => std.fmt.allocPrint(arena, "https://github.com/{s}", .{arg}),
        else => std.fmt.allocPrint(arena, "https://{s}", .{arg}),
    };
}

/// Clone `url` into the repo dir. Does not apply by default: a freshly cloned
/// repo is untrusted until looked at, and applying would write its files and
/// run its `scripts/` (arbitrary code) unreviewed -- so the user reviews, then
/// runs `mox apply`. `apply_now` (from `init --apply`) opts into applying right
/// away for a repo the user trusts. Refuses a non-empty repo dir, so an
/// existing repo is never clobbered.
fn runClone(ctx: *app.Ctx, url: []const u8, clone_fn: CloneFn, apply_now: bool, keepalive: *mox.packages.admin.Keepalive) !u8 {
    const context = ctx.context.?;
    if (try dirNonEmpty(ctx.io, context.paths.repo_dir)) {
        try ctx.err.print("mox init: refusing to clone into non-empty {f}\n", .{display.of(context.paths.repo_dir, ctx.context.?.paths.home)});
        return 1;
    }
    // On a fresh Mac `git` is a shim that opens an install dialog and fails.
    if (std.mem.eql(u8, mox.machine.state.osAxis(ctx.alloc, context.env), "darwin")) {
        var env_map = try context.env.createMap(ctx.alloc);
        var proc: exec.Process = .{
            .io = ctx.io,
            .env = &env_map,
            .timeout_ms = exec.timeoutFromEnv(&env_map, ctx.err),
            .install_timeout_ms = exec.installTimeoutMs(&env_map, ctx.err),
            .out = ctx.out,
            .err = ctx.err,
        };
        var on_path: OnPath = .{ .inner = proc.runner(), .io = ctx.io, .path = env_map.get("PATH") orelse "" };
        const hold: clt.Hold = .{
            .io = ctx.io,
            .keepalive = keepalive,
            .refresh = app.admin_refresh_override orelse mox.packages.admin.sudo_refresh,
        };
        if (try clt.ensure(ctx.alloc, on_path.runner(), ctx.out, app.elevation(), hold)) |why| {
            try ctx.err.print("mox init: {s}\n", .{why});
            return 1;
        }
    }
    if (std.fs.path.dirname(context.paths.repo_dir)) |parent| {
        Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
    }
    const failed = clone_fn(ctx.alloc, ctx.io, context.env, url, context.paths.repo_dir) catch |e| {
        const why = switch (e) {
            error.OutOfMemory => return e,
            error.FileNotFound => "git is not on PATH",
            else => exec.errorText(e),
        };
        try ctx.err.print("mox init: git clone failed: {s}\n", .{why});
        return 1;
    };
    if (failed) |f| {
        const stderr = std.mem.trim(u8, f.stderr, " \t\r\n");
        if (f.code) |code| {
            try ctx.err.print("mox init: git clone failed: git exited {d}", .{code});
        } else {
            try ctx.err.writeAll("mox init: git clone failed: git was killed by a signal");
        }
        if (stderr.len > 0) try ctx.err.print(": {s}", .{stderr});
        try ctx.err.writeAll("\n");
        return 1;
    }
    try ctx.out.print("Cloned {s} to {f}\n", .{ url, display.of(context.paths.repo_dir, ctx.context.?.paths.home) });
    if (!apply_now) {
        try ctx.out.writeAll("Review the repository, then run 'mox apply' to interview for facts, write files, and run setup scripts.\n");
    }
    return 0;
}

/// True when `path` exists and holds at least one non-junk entry.
fn dirNonEmpty(io: Io, path: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    defer dir.close(io);
    // Raw iterate() is sound here: the result is "does any non-junk entry
    // exist", independent of the order they are seen.
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (mox.source.junk.isJunk(entry.name)) continue;
        return true;
    }
    return false;
}

fn gitClone(arena: std.mem.Allocator, io: Io, env: mox.env.Env, url: []const u8, dest: []const u8) !?CloneFailure {
    var env_map = try env.createMap(arena);
    const git = try programOn(arena, io, env_map.get("PATH") orelse "", "git");
    // Disable git's `ext::`/`file::` command transports so a hostile URL cannot
    // run a shell command during clone; `--` blocks option injection.
    // `core.autocrlf=false` keeps the checkout byte-exact: dotfiles are content
    // mox composes verbatim, so a Windows CRLF rewrite would corrupt them.
    const result = try std.process.run(arena, io, .{ .argv = &.{ git, "-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=user", "-c", "core.autocrlf=false", "clone", "--", url, dest }, .environ_map = &env_map });
    return switch (result.term) {
        .exited => |code| if (code == 0) null else .{ .code = code, .stderr = result.stderr },
        else => .{ .code = null, .stderr = result.stderr },
    };
}

/// Where `name` resolves on `path` (the environment mox was given), or `name`
/// itself, left to the spawn. A spawn resolves a bare argv[0] on mox's own
/// process PATH, which a caller handing mox an environment of its own (the
/// test harness) does not control. Windows keeps the spawn's own lookup,
/// which knows its executable extensions.
fn programOn(arena: std.mem.Allocator, io: Io, path: []const u8, name: []const u8) ![]const u8 {
    if (@import("builtin").os.tag == .windows) return name;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(arena, &.{ dir, name });
        Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return candidate;
    }
    return name;
}

/// A runner that resolves each argv[0] with `programOn` before handing the
/// call on.
const OnPath = struct {
    inner: exec.Runner,
    io: Io,
    path: []const u8,

    fn runner(self: *OnPath) exec.Runner {
        return .{ .ctx = self, .runFn = runImpl, .streamFn = streamImpl };
    }

    fn resolved(self: *OnPath, arena: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
        const out = try arena.dupe([]const u8, argv);
        out[0] = try programOn(arena, self.io, self.path, argv[0]);
        return out;
    }

    fn runImpl(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8, cap: usize, capture: exec.Capture) anyerror!exec.Result {
        const self: *OnPath = @ptrCast(@alignCast(ctx));
        return self.inner.runFn(self.inner.ctx, arena, try self.resolved(arena, argv), stdin, cap, capture);
    }

    fn streamImpl(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!exec.Result {
        const self: *OnPath = @ptrCast(@alignCast(ctx));
        return self.inner.streamFn(self.inner.ctx, arena, try self.resolved(arena, argv), stdin);
    }
};

fn initFresh(ctx: *app.Ctx) !u8 {
    const context = ctx.context.?;
    const dirs = [_][]const u8{
        context.paths.repo_dir,
        try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" }),
        try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "scripts" }),
        try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "scripts", "pre" }),
        try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "scripts", "post" }),
        context.paths.state_dir,
        context.paths.private_dir,
    };

    for (dirs) |d| {
        Io.Dir.cwd().createDirPath(ctx.io, d) catch |e| {
            try ctx.err.print("mox init: failed to create {s}: {s}\n", .{ d, @errorName(e) });
            return 1;
        };
    }

    const moxignore_path = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, ".moxignore" });
    Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = moxignore_path, .data = mox.source.ignore.load.scaffold_moxignore }) catch |e| {
        try ctx.err.print("mox init: failed to write .moxignore: {s}\n", .{@errorName(e)});
        return 1;
    };

    try ctx.out.print("Initialized mox repo at {f}\n", .{display.of(context.paths.repo_dir, ctx.context.?.paths.home)});
    try ctx.out.print("State directory: {f}\n", .{display.of(context.paths.state_dir, ctx.context.?.paths.home)});
    try ctx.out.print("Private layer:   {f}\n", .{display.of(context.paths.private_dir, ctx.context.?.paths.home)});
    return 0;
}

pub const command = app.command(Spec, .{
    .name = "init",
    .summary = "Initialize a fresh mox repo",
    .usage = "mox init [--clone <url>] [--apply [--defaults]]",
    .details = "Creates src/ and scripts/. --clone <url>: git clone <url> into the repo dir; without --apply it stops for you to review (then run 'mox apply'), with --apply it applies right away (writes files, runs scripts) for a one-command bootstrap. Refuses a non-empty repo dir. On macOS, absent Xcode Command Line Tools are installed before the clone (sudo asks for the administrator password on the terminal). <owner> expands to https://github.com/<owner>/dotfiles, <owner>/<repo> to https://github.com/<owner>/<repo>, <host>/<owner>/<repo> to https://<host>/<owner>/<repo>; full URLs, ssh remotes, and local paths are used as given.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "resolveCloneUrl: shorthand tiers expand to https URLs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("https://github.com/sakakibara/dotfiles", try resolveCloneUrl(a, "sakakibara"));
    try testing.expectEqualStrings("https://github.com/sakakibara/dotfiles", try resolveCloneUrl(a, "sakakibara/dotfiles"));
    try testing.expectEqualStrings("https://gitlab.com/me/dots", try resolveCloneUrl(a, "gitlab.com/me/dots"));
}

test "resolveCloneUrl: URLs, remotes, and paths pass through verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const verbatim = [_][]const u8{
        "https://github.com/x/y",
        "ssh://git@host/x/y",
        "git@github.com:x/y.git",
        "C:\\repos\\dots",
        "/abs/path/repo",
        "./relative/repo",
        "~/repo",
        "owner//repo",
        "owner/repo/",
        "owner/re po",
        "owner/répo",
    };
    for (verbatim) |v| {
        try testing.expectEqualStrings(v, try resolveCloneUrl(a, v));
    }
}

test "dirNonEmpty: missing is empty, populated is non-empty, junk-only is empty" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    try testing.expect(!try dirNonEmpty(io, try std.fs.path.join(a, &.{ base, "missing" })));

    try tmp.dir.createDirPath(io, "empty");
    try testing.expect(!try dirNonEmpty(io, try std.fs.path.join(a, &.{ base, "empty" })));

    try tmp.dir.createDirPath(io, "junkonly");
    try tmp.dir.writeFile(io, .{ .sub_path = "junkonly/.DS_Store", .data = "" });
    try testing.expect(!try dirNonEmpty(io, try std.fs.path.join(a, &.{ base, "junkonly" })));

    try tmp.dir.createDirPath(io, "full");
    try tmp.dir.writeFile(io, .{ .sub_path = "full/README", .data = "hi\n" });
    try testing.expect(try dirNonEmpty(io, try std.fs.path.join(a, &.{ base, "full" })));
}
