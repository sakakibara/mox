//! `mox remove <name>`: stop managing a file. Its source (base + `.d/`) is
//! moved into the timestamped trash (`<state>/trash/<id>/`) so it stays
//! recoverable, and the live file is left orphaned. `--purge` additionally
//! deletes the live file, snapshotting it first. Under the lock.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const edit = @import("edit.zig");
const fileops = @import("fileops.zig");
const mox = @import("../root.zig");

const Io = std.Io;

const max_file_bytes: usize = 64 * 1024 * 1024;

const Spec = struct {
    name: cli.spec.Pos([]const u8, .{ .help = "managed name to stop managing" }),
    purge: cli.spec.Flag(.{ .help = "also delete the live file (snapshotted first)" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const name = a.name;
    const purge = a.purge;

    const lk = (try lock_mod.acquireForCommand(ctx, "remove")) orelse return 1;
    defer lk.release();

    const live_path = try edit.liveTarget(ctx.alloc, name, context.paths.home);

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, context.paths.home) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox remove: source tree not found at {s}\n", .{src_dir});
            return 1;
        },
        else => return e,
    };

    const file = fileops.findByLive(tree, live_path) orelse {
        try ctx.err.print("mox remove: {s}: not managed\n", .{name});
        return 1;
    };

    const id = mox.apply.snapshot.idNow(ctx.io);
    const trash = try fileops.trashRoot(ctx.alloc, context.paths.state_dir, &id);

    // Trash the source: copy into the trash first, then delete the original,
    // so a failed copy never loses the file.
    if (file.has_base and file.source_base_abs.len > 0) {
        const dst = try std.fs.path.join(ctx.alloc, &.{ trash, file.source_base_path });
        try fileops.copyTree(ctx.io, ctx.alloc, file.source_base_abs, dst);
        Io.Dir.cwd().deleteFile(ctx.io, file.source_base_abs) catch |e| {
            try ctx.err.print("mox remove: could not delete source {s}: {s}\n", .{ file.source_base_abs, @errorName(e) });
            return 1;
        };
    }
    if (try fileops.dotDAbs(ctx.alloc, file)) |dd| {
        if (Io.Dir.cwd().access(ctx.io, dd, .{})) |_| {
            const dst = try std.fmt.allocPrint(ctx.alloc, "{s}.d", .{try std.fs.path.join(ctx.alloc, &.{ trash, file.source_base_path })});
            try fileops.copyTree(ctx.io, ctx.alloc, dd, dst);
            Io.Dir.cwd().deleteTree(ctx.io, dd) catch |e| {
                try ctx.err.print("mox remove: could not delete overlay dir {s}: {s}\n", .{ dd, @errorName(e) });
                return 1;
            };
        } else |_| {}
    }

    // Drop the target's `.mox/attributes.toml` entry: leaving a stale mode /
    // symlink / seed-once flag would bleed onto a plain file later re-added at
    // the same path (add merges, it does not clear a flag it was not given).
    {
        const key = try mox.source.path.liveKeyRelToHome(ctx.alloc, context.paths.home, live_path);
        var attrs = try mox.source.attributes.load(ctx.alloc, ctx.io, context.paths.repo_dir);
        if (attrs.remove(key)) try attrs.write(ctx.io, context.paths.repo_dir);
    }

    try ctx.out.print("Removed {s} (trashed to {s})\n", .{ file.source_base_path, trash });

    // A GENERATOR owns a produced set, not a single live file. Its manifest is
    // keyed by the (phantom) live path. When one exists, remove every produced
    // leaf (snapshot-first, recoverable) and drop the manifest -- there is no
    // single live file to leave in place, so this happens with or without
    // --purge. `force` here means a drifted generated leaf is still pruned
    // (it is mox-owned and the removal is snapshotted).
    {
        const prior = try mox.apply.generated.readManifest(ctx.alloc, ctx.io, context.paths.state_dir, live_path);
        if (prior.len > 0) {
            // Never prune a path another producer legitimately owns: keep every
            // OTHER tree target (regular managed files and generator phantoms)
            // AND every OTHER generator's produced leaves. Omitting the latter
            // would let removing this generator delete a leaf another generator
            // still owns when the two manifests overlap in a stale state.
            var keep: std.StringHashMap(void) = .init(ctx.alloc);
            for (tree.files) |f| {
                if (std.mem.eql(u8, f.live_path, live_path)) continue;
                try keep.put(f.live_path, {});
                const other = try mox.apply.generated.readManifest(ctx.alloc, ctx.io, context.paths.state_dir, f.live_path);
                for (other) |leaf| try keep.put(leaf, {});
            }
            const res = try mox.apply.generated.pruneStale(ctx.alloc, ctx.io, .{
                .state_dir = context.paths.state_dir,
                .snapshots_dir = context.paths.snapshots_dir,
                .snap_id = &id,
                .home = context.paths.home,
                .force = true,
                .dry_run = false,
            }, prior, &keep, ctx.out, ctx.err);
            // Drop the manifest only when the whole set was pruned. A refused
            // leaf (undeletable, a directory, an unsnapshottable drift) would
            // otherwise become a permanent un-prunable orphan once the source is
            // trashed; retain the manifest so it stays tracked and retryable.
            if (res.refused == 0) {
                try mox.apply.generated.deleteManifest(ctx.alloc, ctx.io, context.paths.state_dir, live_path);
            }
            try ctx.out.print("  removed {d} generated file(s)\n", .{res.removed});
            return if (res.refused > 0) 1 else 0;
        }
    }

    if (purge) {
        // Snapshot before deleting so --purge is recoverable. A live symlink is
        // snapshotted AS a symlink (not its dereferenced target content), so
        // rollback restores a link; a dangling link is snapshotted and removed
        // too rather than followed or left behind.
        switch (mox.apply.applied.inspectSymSite(ctx.io, ctx.alloc, live_path)) {
            .absent => {
                try ctx.out.print("  live file already absent: {s}\n", .{live_path});
                return 0;
            },
            .directory => {
                try ctx.err.print("mox remove: live path is a directory, not deleting: {s}\n", .{live_path});
                return 1;
            },
            .symlink => |target| {
                mox.apply.snapshot.saveSymlink(ctx.alloc, ctx.io, context.paths.snapshots_dir, &id, context.paths.home, live_path, target) catch |e| {
                    try ctx.err.print("mox remove: snapshot failed, not deleting live symlink: {s}\n", .{@errorName(e)});
                    return 1;
                };
            },
            .other => {
                const live = Io.Dir.cwd().readFileAlloc(ctx.io, live_path, ctx.alloc, .limited(max_file_bytes)) catch |e| switch (e) {
                    error.FileNotFound => {
                        try ctx.out.print("  live file already absent: {s}\n", .{live_path});
                        return 0;
                    },
                    else => return e,
                };
                mox.apply.snapshot.save(ctx.alloc, ctx.io, context.paths.snapshots_dir, &id, context.paths.home, live_path, live) catch |e| {
                    try ctx.err.print("mox remove: snapshot failed, not deleting live file: {s}\n", .{@errorName(e)});
                    return 1;
                };
            },
        }
        Io.Dir.cwd().deleteFile(ctx.io, live_path) catch |e| {
            try ctx.err.print("mox remove: could not delete live file {s}: {s}\n", .{ live_path, @errorName(e) });
            return 1;
        };
        try ctx.out.print("  purged live file: {s}\n", .{live_path});
    } else {
        try ctx.out.print("  live file left in place: {s}\n", .{live_path});
    }
    return 0;
}

pub const command = app.command(Spec, .{
    .name = "remove",
    .summary = "Stop managing a file",
    .usage = "mox remove <name> [--purge]",
    .details = "Trashes its source recoverably, orphans the live file (--purge also deletes the live file).",
    .group = .general,
    .needs_context = true,
}, run);
