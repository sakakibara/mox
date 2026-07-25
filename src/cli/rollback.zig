const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const apply_cmd = @import("apply.zig");
const mox = @import("../root.zig");

const Io = std.Io;

/// `mox rollback <id>`: restore all live files captured in a snapshot.
///
/// Last-applied records are deliberately left stale, so the next `mox apply`
/// sees the restored files as drift and refuses to overwrite them without
/// --force. Rollback undoes live-file changes; it never touches the source
/// tree.
///
/// A PARTIALLY owned target is never whole-file restored: that would clobber
/// the program's remainder as it stood at snapshot time. Its snapshot is
/// re-patched onto the CURRENT live file through the full partial pipeline
/// (splice, invariant, `check` hook, raced-write recheck). A snapshot whose
/// owned values were secret-masked is refused -- placeholders are never
/// written live; re-apply the source instead.
const Spec = struct {
    id: cli.spec.Pos([]const u8, .{ .help = "snapshot id (see 'mox snapshot list')" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const id = a.id;

    const lk = (try lock_mod.acquireForCommand(ctx, "rollback")) orelse return 1;
    defer lk.release();

    // Current partial targets, from the walked tree: their snapshots take
    // the re-patch path instead of the whole-file restore.
    var partials: std.StringHashMap(mox.source.tree.ManagedFile) = .init(ctx.alloc);
    var skip: std.StringHashMap(void) = .init(ctx.alloc);
    {
        const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
        var walk_diag: mox.source.tree.Diag = .{};
        const base_tree: ?mox.source.tree.ManagedTree = mox.source.tree.walkDiag(ctx.alloc, ctx.io, src_dir, context.paths.home, &walk_diag) catch |e| switch (e) {
            error.FileNotFound => null,
            error.OwnOnUnstructuredTarget,
            error.OwnOnSymlink,
            error.OwnOnSeedOnce,
            error.OwnOnGenerator,
            error.InvalidOwnPath,
            => {
                try ctx.err.print("mox rollback: .mox/attributes.toml: {s}: {s}\n", .{
                    walk_diag.capture() orelse "?", mox.apply.owned.ownDiagText(e),
                });
                return 1;
            },
            else => return e,
        };
        if (base_tree) |bt| {
            const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, bt, context.paths.private_dir, context.paths.home);
            for (tree.files) |f| {
                if (f.own_paths.len == 0) continue;
                try partials.put(f.live_path, f);
                try skip.put(f.live_path, {});
            }
        }
    }

    var withheld: std.ArrayList(mox.apply.snapshot.Withheld) = .empty;
    const restored = mox.apply.snapshot.restoreExcept(ctx.alloc, ctx.io, context.paths.snapshots_dir, id, context.paths.home, &skip, &withheld) catch |e| switch (e) {
        error.SnapshotNotFound => {
            try ctx.err.print("mox rollback: no snapshot '{s}' (see 'mox snapshot list')\n", .{id});
            return 1;
        },
        else => return e,
    };

    var repatched: usize = 0;
    var failed: usize = 0;
    for (withheld.items) |w| {
        const file = partials.get(w.live_path).?;
        if (try repatchPartial(ctx, file, w.content, &failed)) repatched += 1;
    }

    try ctx.out.print("Restored {d} file(s) from snapshot {s}\n", .{ restored.count + repatched, id });
    return if (failed > 0) 1 else 0;
}

/// Re-patch one partial target's owned subtree from its snapshot onto the
/// CURRENT live file. The owned record is deliberately left stale; the next
/// apply reconciles through the drift rule, mirroring whole-file rollback.
/// Returns true on success; a refusal reports, bumps `failed`, and leaves
/// the live file untouched.
fn repatchPartial(
    ctx: *app.Ctx,
    file: mox.source.tree.ManagedFile,
    snap_content: []const u8,
    failed: *usize,
) !bool {
    const partial = mox.apply.partial;
    const live_path = file.live_path;
    const format = mox.source.format.formatOfPath(file.source_base_path).?;
    var pdiag: partial.Diag = .{};

    const snap_doc = partial.OwnedDoc.parse(ctx.alloc, format, snap_content) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => {
            try ctx.err.print("  ERROR   {s} (snapshot does not parse as {s})\n", .{ live_path, @tagName(format) });
            failed.* += 1;
            return false;
        },
    };
    if (partial.ownedHasSecretMask(&snap_doc, file.own_paths)) {
        try ctx.err.print("  ERROR   {s} (snapshot masks a secret; placeholders are never written live -- re-apply the source instead)\n", .{live_path});
        failed.* += 1;
        return false;
    }

    // Stat before the read so a write landing between the two refuses at
    // the post-fsync recheck, same as apply's partial path.
    const pre_stat = mox.apply.write.liveStat(ctx.io, live_path);
    const live: ?[]const u8 = Io.Dir.cwd().readFileAlloc(ctx.io, live_path, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => {
            try ctx.err.print("mox rollback: {s}: read failed: {s}\n", .{ live_path, @errorName(e) });
            failed.* += 1;
            return false;
        },
    };
    const live_stat: ?mox.apply.write.LiveStat = if (live != null) pre_stat else null;
    const live_text = live orelse "";
    _ = partial.OwnedDoc.parse(ctx.alloc, format, live_text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => {
            try ctx.err.print("  ERROR   {s} (live file does not parse as {s}; mox cannot patch what it cannot preserve)\n", .{ live_path, @tagName(format) });
            failed.* += 1;
            return false;
        },
    };

    const candidate = partial.replaceOwned(ctx.alloc, format, live_text, file.own_paths, &snap_doc, &pdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("  ERROR   {s} ({s})\n", .{ live_path, pdiag.text() });
            failed.* += 1;
            return false;
        },
    };
    partial.verifyInvariant(ctx.alloc, format, live_text, candidate, file.own_paths, &snap_doc, &pdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("  ERROR   {s} (invariant check failed: {s})\n", .{ live_path, pdiag.text() });
            failed.* += 1;
            return false;
        },
    };
    // A rollback must not install content the file's own validator rejects.
    if (file.check_argv.len > 0) {
        if (!try apply_cmd.partialCheckAccepts(ctx, file.check_argv, live_path, candidate, failed)) return false;
    }

    const mode = blk: {
        const st = Io.Dir.cwd().statFile(ctx.io, live_path, .{}) catch break :blk @as(u32, 0o644);
        break :blk mox.apply.write.modeOf(st.permissions);
    };
    mox.apply.write.writeAtomicPartial(ctx.io, live_path, candidate, mode, live_stat) catch |e| switch (e) {
        error.LiveChangedDuringWrite => {
            try ctx.err.print("  CONFLICT {s} (changed underneath mox mid-rollback; re-run 'mox rollback')\n", .{live_path});
            failed.* += 1;
            return false;
        },
        else => {
            try ctx.err.print("mox rollback: {s}: write failed: {s}\n", .{ live_path, @errorName(e) });
            failed.* += 1;
            return false;
        },
    };
    try ctx.out.print("  re-patched {s} (owned subtree from the snapshot; remainder kept current)\n", .{live_path});
    return true;
}

pub const command = app.command(Spec, .{
    .name = "rollback",
    .summary = "Restore live files from a snapshot",
    .usage = "mox rollback <snapshot-id>",
    .group = .general,
    .needs_context = true,
}, run);
