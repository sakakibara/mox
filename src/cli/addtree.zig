//! `mox add-tree <dir>`: recursively start managing every non-junk regular
//! file under a live directory, reusing the single-file add path. Already-
//! managed files and junk (editor temp, OS metadata) are skipped. Under the
//! lock.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const edit = @import("edit.zig");
const add = @import("add.zig");
const mox = @import("../root.zig");

const Io = std.Io;

const Counts = struct {
    added: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
};

const Spec = struct {
    dir: cli.spec.Pos([]const u8, .{ .help = "live directory to start managing" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const dir_abs = try edit.liveTarget(ctx.alloc, a.dir, context.paths.home);

    const lk = (try lock_mod.acquireForCommand(ctx, "add-tree")) orelse return 1;
    defer lk.release();

    var counts: Counts = .{};
    walk(ctx, dir_abs, &counts) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox add-tree: {s}: not found\n", .{dir_abs});
            return 1;
        },
        else => return e,
    };

    try ctx.out.print("Added {d} file(s); {d} skipped, {d} failed\n", .{ counts.added, counts.skipped, counts.failed });
    return if (counts.failed > 0) 1 else 0;
}

fn walk(ctx: *app.Ctx, dir_abs: []const u8, counts: *Counts) !void {
    const context = ctx.context.?;
    var dir = try Io.Dir.cwd().openDir(ctx.io, dir_abs, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(ctx.io);

    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (mox.source.junk.isJunk(entry.name)) continue;
        const child = try std.fs.path.join(ctx.alloc, &.{ dir_abs, entry.name });
        switch (entry.kind) {
            .directory => try walk(ctx, child, counts),
            .file => {
                const home = context.env.getAlloc(ctx.alloc, "HOME") catch context.paths.home;
                // Bulk-adding a tree never seeds once; only single-file add
                // exposes the intent.
                const result = add.addFile(ctx.alloc, ctx.io, context.paths.repo_dir, home, child, false) catch {
                    counts.failed += 1;
                    continue;
                };
                switch (result.outcome) {
                    .added => {
                        counts.added += 1;
                        try ctx.out.print("  added {s}\n", .{child});
                    },
                    .already_managed => counts.skipped += 1,
                    else => counts.skipped += 1,
                }
            },
            else => {},
        }
    }
}

pub const command = app.command(Spec, .{
    .name = "add-tree",
    .summary = "Recursively add every non-junk file under a live dir",
    .usage = "mox add-tree <dir>",
    .group = .general,
    .needs_context = true,
}, run);
