//! `mox mv <old> <new>`: rename a managed file's source (base + its `.d/`
//! overlay dir) so the live target changes on the next apply. The old source
//! is copied into the timestamped trash first (recoverable), then renamed, and
//! any `.mox/attributes.toml` entry (mode, symlink, seed-once) is re-keyed as a
//! whole to the new target. Under the lock.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const edit = @import("edit.zig");
const fileops = @import("fileops.zig");
const mox = @import("../root.zig");

const Io = std.Io;

const Spec = struct {
    old: cli.spec.Pos([]const u8, .{ .help = "current managed name" }),
    new: cli.spec.Pos([]const u8, .{ .help = "new managed name" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const old_name = a.old;
    const new_name = a.new;

    const lk = (try lock_mod.acquireForCommand(ctx, "mv")) orelse return 1;
    defer lk.release();

    const old_live = try edit.liveTarget(ctx.alloc, old_name, context.paths.home);
    const new_live = try edit.liveTarget(ctx.alloc, new_name, context.paths.home);

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, context.paths.home) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox mv: source tree not found at {s}\n", .{src_dir});
            return 1;
        },
        else => return e,
    };

    const file = fileops.findByLive(tree, old_live) orelse {
        try ctx.err.print("mox mv: {s}: not managed\n", .{old_name});
        return 1;
    };

    const new_base_rel = try fileops.newBaseRel(ctx.alloc, new_live, context.paths.home);
    // A destination with a `..` segment would rename the source outside the repo
    // (path.join does not normalize) -- refuse the escape.
    if (mox.source.path.keyEscapes(new_base_rel)) {
        try ctx.err.print("mox mv: unsafe destination '{s}' (escapes the source tree)\n", .{new_live});
        return 1;
    }
    const new_base_abs = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, new_base_rel });
    const new_dot_d_abs = try std.fmt.allocPrint(ctx.alloc, "{s}.d", .{new_base_abs});

    // Refuse to clobber an existing destination. Both the base and its overlay
    // dir must be absent, else a rename of the base could succeed while the
    // overlay rename fails onto the existing dir, leaving a half-moved source.
    if (Io.Dir.cwd().access(ctx.io, new_base_abs, .{})) |_| {
        try ctx.err.print("mox mv: destination already exists: {s}\n", .{new_base_abs});
        return 1;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    if (Io.Dir.cwd().access(ctx.io, new_dot_d_abs, .{})) |_| {
        try ctx.err.print("mox mv: destination overlay dir already exists: {s}\n", .{new_dot_d_abs});
        return 1;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }

    const old_dot_d = try fileops.dotDAbs(ctx.alloc, file);

    // Snapshot first: back the source (base + .d) into the trash so the move
    // is recoverable if anything goes wrong.
    const id = mox.apply.snapshot.idNow(ctx.io);
    const trash = try fileops.trashRoot(ctx.alloc, context.paths.state_dir, &id);
    if (file.has_base and file.source_base_abs.len > 0) {
        const dst = try std.fs.path.join(ctx.alloc, &.{ trash, file.source_base_path });
        try fileops.copyTree(ctx.io, ctx.alloc, file.source_base_abs, dst);
    }
    if (old_dot_d) |dd| {
        if (Io.Dir.cwd().access(ctx.io, dd, .{})) |_| {
            const dst = try std.fs.path.join(ctx.alloc, &.{ trash, file.source_base_path });
            try fileops.copyTree(ctx.io, ctx.alloc, dd, try std.fmt.allocPrint(ctx.alloc, "{s}.d", .{dst}));
        } else |_| {}
    }

    // Re-key any attributes entry (mode git cannot carry) from the old target
    // to the new one BEFORE the rename; keys are portable, derived from the live
    // paths. Doing it first means a write failure aborts with nothing moved
    // (consistent), and if a later rename fails the re-key is already done, so a
    // re-run completes the move without orphaning the entry on the old key.
    const old_key = try mox.source.path.liveKeyRelToHome(ctx.alloc, context.paths.home, old_live);
    const new_key = try mox.source.path.liveKeyRelToHome(ctx.alloc, context.paths.home, new_live);
    var attrs = try mox.source.attributes.load(ctx.alloc, ctx.io, context.paths.repo_dir);
    if (attrs.lookup(old_key)) |entry| {
        _ = attrs.remove(old_key);
        try attrs.set(new_key, entry);
        try attrs.write(ctx.io, context.paths.repo_dir);
    }

    // A generator's produced-set manifest is keyed by the generator's live path,
    // not its source file, so a rename would leave the old leaves tracked under
    // the old key -- orphaned, never pruned. Re-key the manifest to the new live
    // path so the next apply prunes the old leaves rather than leaking them.
    const prior_gen = try mox.apply.generated.readManifest(ctx.alloc, ctx.io, context.paths.state_dir, old_live);
    if (prior_gen.len > 0) {
        try mox.apply.generated.writeManifest(ctx.alloc, ctx.io, context.paths.state_dir, new_live, prior_gen);
        try mox.apply.generated.deleteManifest(ctx.alloc, ctx.io, context.paths.state_dir, old_live);
    }

    // Rename base then its overlay dir.
    if (std.fs.path.dirname(new_base_abs)) |parent| Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
    if (file.has_base and file.source_base_abs.len > 0) {
        Io.Dir.rename(Io.Dir.cwd(), file.source_base_abs, Io.Dir.cwd(), new_base_abs, ctx.io) catch |e| {
            try ctx.err.print("mox mv: rename failed: {s}\n", .{@errorName(e)});
            return 1;
        };
    }
    if (old_dot_d) |dd| {
        if (Io.Dir.cwd().access(ctx.io, dd, .{})) |_| {
            Io.Dir.rename(Io.Dir.cwd(), dd, Io.Dir.cwd(), new_dot_d_abs, ctx.io) catch |e| {
                try ctx.err.print("mox mv: overlay dir rename failed: {s}\n", .{@errorName(e)});
                return 1;
            };
        } else |_| {}
    }

    try ctx.out.print("Moved {s} -> {s} (run 'mox apply' to update live files)\n", .{ file.source_base_path, new_base_rel });
    return 0;
}

pub const command = app.command(Spec, .{
    .name = "mv",
    .summary = "Rename a managed file's source; snapshot first",
    .usage = "mox mv <old> <new>",
    .group = .general,
    .needs_context = true,
}, run);
