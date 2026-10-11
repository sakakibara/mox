//! `mox remove <name>`: stop managing a file, keeping its live file on every
//! machine. Its source (base + `.d/`) is moved into the timestamped trash
//! (`<state>/trash/<id>/`) so it stays recoverable, and `.mox/attributes.toml`
//! keeps a tombstone (`released = true`) every other machine's apply honours
//! by forgetting the file, never removing it. `--purge` deletes the live file
//! here, snapshotting it first, and leaves no tombstone, so other machines'
//! applies remove their unedited copies too. A private-only file is this
//! machine's alone: it is forgotten here, with no tombstone. Under the lock.

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const edit = @import("edit.zig");
const fileops = @import("fileops.zig");
const mox = @import("../root.zig");
const display = @import("display.zig");

const Io = std.Io;

const max_file_bytes: usize = 64 * 1024 * 1024;

const Spec = struct {
    name: cli.Pos([]const u8, .{ .help = "managed name to stop managing" }),
    purge: cli.Flag(.{ .help = "also delete the live file here (snapshotted first) and leave no tombstone" }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const name = a.name;
    const purge = a.purge;

    const lk = (try lock_mod.acquireForCommand(ctx, "remove")) orelse return 1;
    defer lk.release();

    const live_path = edit.liveTarget(ctx.alloc, context.paths.home, context.cwd, name) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => |f| return edit.reportTarget(ctx.err, "mox remove", name, f),
    };

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    var walk_diag: mox.source.tree.Diag = .{};
    const tree = mox.source.tree.walkDiag(ctx.alloc, ctx.io, src_dir, context.paths.home, &walk_diag) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox remove: source tree not found at {s}\n", .{src_dir});
            return 1;
        },
        error.OwnOnSymlink,
        error.OwnOnSeedOnce,
        error.OwnOnGenerator,
        error.OwnAndDisown,
        error.OwnPathOverlap,
        error.InvalidOwnPath,
        error.InvalidCheckDirective,
        error.CheckWithoutOwnership,
        => {
            try ctx.err.print("mox remove: ownership declaration: {s}: {s}\n", .{
                walk_diag.capture() orelse "?", mox.apply.owned.ownDiagText(e),
            });
            return 1;
        },
        error.TomlParseError,
        => {
            try ctx.err.print("mox remove: .mox/attributes.toml: not valid TOML\n", .{});
            return 1;
        },
        else => return e,
    };

    const merged = try mox.private.layer.merge(ctx.alloc, ctx.io, tree, context.paths.private_dir, context.paths.home);
    const repo_file = fileops.findByLive(tree, live_path);
    // A path the repo does not manage belongs to the private layer alone.
    const private_only = repo_file == null;
    const file = repo_file orelse fileops.findByLive(merged, live_path) orelse {
        try ctx.err.print("mox remove: {s}: not managed\n", .{name});
        return 1;
    };
    if (repo_file) |rf| {
        if (fileops.privateVaries(merged, rf)) {
            try ctx.err.print("mox remove: {s}: the private layer still varies this file; remove its private overlays first\n", .{name});
            return 1;
        }
    }

    // A partial target's live file is mostly the program's: purging would
    // delete the remainder mox never owned. Plain remove stops managing it.
    if (purge and file.own_paths.len > 0) {
        try ctx.err.print("mox remove: {s}: --purge is refused for a partially owned file (the live file's remainder is not mox's to delete; plain 'mox remove' stops managing it)\n", .{name});
        return 1;
    }

    // The attributes file this remove rewrites: the private layer's for a
    // private-only file, else the repo's, which keeps a tombstone unless the
    // live file is purged. Loaded, and its comment refusal checked, before
    // any side effect.
    const key = try mox.source.path.liveKeyRelToHome(ctx.alloc, context.paths.home, live_path);
    const attrs_root = if (private_only) context.paths.private_dir else context.paths.repo_dir;
    var attrs_diag: mox.source.attributes.Diag = .{};
    var attrs = mox.source.attributes.loadStrict(ctx.alloc, ctx.io, attrs_root, &attrs_diag) catch |e| switch (e) {
        error.UnknownAttributeKey,
        error.InvalidAttributeValue,
        => {
            try ctx.err.print("mox remove: attributes.toml: {s}: {s}\n", .{
                attrs_diag.capture() orelse "?", mox.source.attributes.diagText(e),
            });
            return 1;
        },
        else => return e,
    };
    const tombstone = !private_only and !purge;
    // A stale mode / symlink / seed-once flag would bleed onto a plain file
    // later re-added at the same path (add merges, it does not clear a flag
    // it was not given), so the entry goes; a tombstone replaces it.
    const had_entry = attrs.remove(key);
    if (tombstone) try attrs.set(key, .{ .released = true });
    const rewrite = had_entry or tombstone;
    if (rewrite) {
        attrs.refuseComments() catch {
            try ctx.err.print("mox remove: {s}: comments here would be lost; remove them\n", .{attrs.path});
            return 1;
        };
    }

    const id = mox.apply.snapshot.idNow(ctx.io);
    const trash = try fileops.trashRoot(ctx.alloc, context.paths.state_dir, &id);

    // Trash the source: copy into the trash first, then delete the original,
    // so a failed copy never loses the file.
    if (file.has_base and file.source_base_abs.len > 0) {
        const dst = try std.fs.path.join(ctx.alloc, &.{ trash, file.source_base_path });
        try fileops.copyTree(ctx.io, ctx.alloc, file.source_base_abs, dst);
        Io.Dir.cwd().deleteFile(ctx.io, file.source_base_abs) catch |e| {
            try ctx.err.print("mox remove: could not delete source {f}: {s}\n", .{ display.of(file.source_base_abs, ctx.context.?.paths.home), @errorName(e) });
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

    if (rewrite) try attrs.write(ctx.io, attrs_root);

    // Forget every last-applied record for the path (content hash, content
    // cache, symlink target, owned record) and its provenance: mox stopped
    // tracking it, and a stale record would make a later re-add at the same
    // path compare against state from the previous management era instead of
    // going through first contact.
    try mox.apply.applied.forget(ctx.alloc, ctx.io, context.paths.state_dir, live_path);
    try mox.provenance.map.forget(ctx.alloc, ctx.io, context.paths.state_dir, live_path);

    try ctx.out.print("Removed {s} (trashed to {s})\n", .{ file.source_base_path, trash });

    // A GENERATOR owns a produced set, not a single live file. Its manifest is
    // keyed by the (phantom) live path. Released, its leaves stay where they
    // are and are forgotten; purged, every produced leaf is removed
    // (snapshot-first, recoverable) and the manifest dropped.
    {
        const prior = try mox.apply.generated.readManifest(ctx.alloc, ctx.io, context.paths.state_dir, live_path);
        if (prior.len > 0 and !purge) {
            // A leaf another producer still writes keeps its records.
            var claimed: std.StringHashMap(void) = .init(ctx.alloc);
            for (merged.files) |f| {
                if (std.mem.eql(u8, f.live_path, live_path)) continue;
                try claimed.put(f.live_path, {});
                for (try mox.apply.generated.readManifest(ctx.alloc, ctx.io, context.paths.state_dir, f.live_path)) |leaf| try claimed.put(leaf, {});
            }
            for (prior) |leaf| {
                if (claimed.contains(leaf)) continue;
                try mox.apply.applied.forget(ctx.alloc, ctx.io, context.paths.state_dir, leaf);
                try mox.provenance.map.forget(ctx.alloc, ctx.io, context.paths.state_dir, leaf);
            }
            try mox.apply.generated.deleteManifest(ctx.alloc, ctx.io, context.paths.state_dir, live_path);
            try ctx.out.print("  {d} generated file(s) left in place, no longer managed\n", .{prior.len});
            return 0;
        }
        if (prior.len > 0) {
            // Never prune a path another producer legitimately owns: keep every
            // OTHER tree target (regular managed files and generator phantoms)
            // AND every OTHER generator's produced leaves. Omitting the latter
            // would let removing this generator delete a leaf another generator
            // still owns when the two manifests overlap in a stale state.
            var keep: std.StringHashMap(void) = .init(ctx.alloc);
            for (merged.files) |f| {
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
            const refused = res.drift_refused + res.error_refused;
            if (refused == 0) {
                try mox.apply.generated.deleteManifest(ctx.alloc, ctx.io, context.paths.state_dir, live_path);
            }
            try ctx.out.print("  removed {d} generated file(s)\n", .{res.removed});
            return if (refused > 0) 1 else 0;
        }
    }

    if (purge) {
        // Snapshot before deleting so --purge is recoverable. A live symlink is
        // snapshotted AS a symlink (not its dereferenced target content), so
        // rollback restores a link; a dangling link is snapshotted and removed
        // too rather than followed or left behind.
        switch (mox.apply.applied.inspectSymSite(ctx.io, ctx.alloc, live_path)) {
            .absent => {
                try ctx.out.print("  live file already absent: {f}\n", .{display.of(live_path, context.paths.home)});
                return 0;
            },
            .directory => {
                try ctx.err.print("mox remove: live path is a directory, not deleting: {f}\n", .{display.of(live_path, context.paths.home)});
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
                        try ctx.out.print("  live file already absent: {f}\n", .{display.of(live_path, context.paths.home)});
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
            try ctx.err.print("mox remove: could not delete live file {f}: {s}\n", .{ display.of(live_path, context.paths.home), @errorName(e) });
            return 1;
        };
        try ctx.out.print("  purged live file: {f}\n", .{display.of(live_path, context.paths.home)});
    } else {
        try ctx.out.print("  live file left in place: {f}\n", .{display.of(live_path, context.paths.home)});
        if (tombstone) try ctx.out.print("  released in .mox/attributes.toml: every machine keeps its live copy\n", .{});
    }
    return 0;
}

pub const command = app.command(Spec, .{
    .name = "remove",
    .summary = "Stop managing a file",
    .usage = "mox remove <name> [--purge]",
    .details = "Trashes its source recoverably and keeps the live file on every machine through a tombstone in .mox/attributes.toml; --purge deletes the live file here and leaves no tombstone, so other machines remove their unedited copies too.",
    .group = .general,
    .needs_context = true,
}, run);
