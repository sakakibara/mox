const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const apply = @import("apply.zig");
const mox = @import("../root.zig");

const Io = std.Io;

/// Seam over `git clone` so the guard and orchestration can be tested without
/// a real subprocess. The default is `gitClone`.
const CloneFn = *const fn (std.mem.Allocator, Io, []const u8, []const u8) anyerror!void;

const Spec = struct {
    clone: cli.spec.Opt([]const u8, .{ .value_name = "url", .help = "git clone <url> into the repo dir (review it, then run 'mox apply')" }),
    apply: cli.spec.Flag(.{ .help = "after cloning, apply immediately (write files, run scripts) instead of stopping to review" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    if (a.clone) |url| {
        if (url.len == 0) {
            try ctx.err.writeAll("mox init: --clone requires a repository URL\n");
            return 2;
        }
        const rc = try runClone(ctx, url, gitClone, a.apply);
        if (rc != 0) return rc;
        // Opt-in one-command bootstrap: clone, then apply a repo the user trusts.
        if (a.apply) return apply.applyImpl(ctx, false, false, false);
        return rc;
    }
    const rc = try initFresh(ctx);
    if (rc != 0) return rc;
    if (a.apply) return apply.applyImpl(ctx, false, false, false);
    return rc;
}

/// Clone `url` into the repo dir. Does not apply by default: a freshly cloned
/// repo is untrusted until looked at, and applying would write its files and
/// run its `scripts/` (arbitrary code) unreviewed -- so the user reviews, then
/// runs `mox apply`. `apply_now` (from `init --apply`) opts into applying right
/// away for a repo the user trusts. Refuses a non-empty repo dir, so an
/// existing repo is never clobbered.
fn runClone(ctx: *app.Ctx, url: []const u8, clone_fn: CloneFn, apply_now: bool) !u8 {
    const context = ctx.context.?;
    if (try dirNonEmpty(ctx.io, context.paths.repo_dir)) {
        try ctx.err.print("mox init: refusing to clone into non-empty {s}\n", .{context.paths.repo_dir});
        return 1;
    }
    if (std.fs.path.dirname(context.paths.repo_dir)) |parent| {
        Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
    }
    clone_fn(ctx.alloc, ctx.io, url, context.paths.repo_dir) catch |e| {
        try ctx.err.print("mox init: git clone failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    try ctx.out.print("Cloned {s} to {s}\n", .{ url, context.paths.repo_dir });
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
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (mox.source.junk.isJunk(entry.name)) continue;
        return true;
    }
    return false;
}

fn gitClone(arena: std.mem.Allocator, io: Io, url: []const u8, dest: []const u8) !void {
    // Disable git's `ext::`/`file::` command transports so a hostile URL cannot
    // run a shell command during clone; `--` blocks option injection.
    // `core.autocrlf=false` keeps the checkout byte-exact: dotfiles are content
    // mox composes verbatim, so a Windows CRLF rewrite would corrupt them.
    const result = std.process.run(arena, io, .{ .argv = &.{ "git", "-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=user", "-c", "core.autocrlf=false", "clone", "--", url, dest } }) catch |e| switch (e) {
        error.FileNotFound => return error.GitNotFound,
        else => return error.CloneFailed,
    };
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CloneFailed,
        else => return error.CloneFailed,
    }
}

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

    try ctx.out.print("Initialized mox repo at {s}\n", .{context.paths.repo_dir});
    try ctx.out.print("State directory: {s}\n", .{context.paths.state_dir});
    try ctx.out.print("Private layer:   {s}\n", .{context.paths.private_dir});
    return 0;
}

pub const command = app.command(Spec, .{
    .name = "init",
    .summary = "Initialize a fresh mox repo",
    .usage = "mox init [--clone <url>] [--apply]",
    .details = "Creates src/ and scripts/. --clone <url>: git clone <url> into the repo dir; without --apply it stops for you to review (then run 'mox apply'), with --apply it applies right away (writes files, runs scripts) for a one-command bootstrap. Refuses a non-empty repo dir.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

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
