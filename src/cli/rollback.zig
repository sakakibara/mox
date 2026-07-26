const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const apply_cmd = @import("apply.zig");
const mox = @import("../root.zig");
const Env = @import("env").Env;

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
    id: cli.Pos([]const u8, .{ .help = "snapshot id (see 'mox snapshot list')" }),
};

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const id = a.id;

    const lk = (try lock_mod.acquireForCommand(ctx, "rollback")) orelse return 1;
    defer lk.release();

    // Tree info for the re-patch (own paths, check hook, format), best
    // effort: a broken source tree must not block the
    // whole-file restores, so a failed walk leaves the map empty and only
    // the withheld partial targets report an error below.
    var partials: std.StringHashMap(mox.source.tree.ManagedFile) = .init(ctx.alloc);
    {
        const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
        var walk_diag: mox.source.tree.Diag = .{};
        const base_tree: ?mox.source.tree.ManagedTree = mox.source.tree.walkDiag(ctx.alloc, ctx.io, src_dir, context.paths.home, &walk_diag) catch |e| switch (e) {
            error.FileNotFound => null,
            error.OwnOnSymlink,
            error.OwnOnSeedOnce,
            error.OwnOnGenerator,
            error.OwnAndDisown,
            error.OwnPathOverlap,
            error.InvalidOwnPath,
            error.InvalidCheckDirective,
            error.CheckWithoutOwnership,
            => blk: {
                try ctx.err.print("mox rollback: warning: ownership declaration: {s}: {s}; whole-file restores proceed, partial targets cannot be re-patched\n", .{
                    walk_diag.capture() orelse "?", mox.apply.owned.ownDiagText(e),
                });
                break :blk null;
            },
            else => return e,
        };
        if (base_tree) |bt| {
            const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, bt, context.paths.private_dir, context.paths.home);
            for (tree.files) |f| {
                if (f.own_paths.len == 0) continue;
                try partials.put(f.live_path, f);
            }
        }
    }

    // Partial targets are detected by OWNED RECORD existence, not by the
    // walked tree: the records were written by the same runs that took the
    // snapshots, and unlike the tree they stay readable when the repo is
    // broken -- a whole-file restore over a partial target must never
    // happen just because the walk failed.
    var skip: std.StringHashMap(void) = .init(ctx.alloc);
    for (try snapshotLivePaths(ctx, id)) |lp| {
        if ((try mox.apply.applied.readOwned(ctx.alloc, ctx.io, context.paths.state_dir, lp)) != null) {
            try skip.put(lp, {});
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
        const file = partials.get(w.live_path) orelse {
            try ctx.err.print("  ERROR   {s} (partially owned, but its own declaration is unavailable; fix the source tree, then re-run)\n", .{w.live_path});
            failed += 1;
            continue;
        };
        if (try repatchPartial(ctx, file, w.content, &failed)) repatched += 1;
    }

    try ctx.out.print("Restored {d} file(s) from snapshot {s}\n", .{ restored.count + repatched, id });
    return if (failed > 0) 1 else 0;
}

/// Live paths of every regular file captured in snapshot `id` (symlink
/// snapshots are never partial targets). A missing snapshot yields none;
/// `restoreExcept` reports it.
fn snapshotLivePaths(ctx: *app.Ctx, id: []const u8) ![]const []const u8 {
    const context = ctx.context.?;
    var out: std.ArrayList([]const u8) = .empty;
    const snap_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.snapshots_dir, id });
    var dir = Io.Dir.cwd().openDir(ctx.io, snap_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return out.toOwnedSlice(ctx.alloc),
        else => return e,
    };
    defer dir.close(ctx.io);
    var walker = try dir.walk(ctx.alloc);
    defer walker.deinit();
    while (try walker.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        try out.append(ctx.alloc, try mox.source.path.joinKeyOnto(ctx.alloc, context.paths.home, entry.path));
    }
    return out.toOwnedSlice(ctx.alloc);
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
    const masked = switch (file.ownership) {
        .disown => try partial.complementHasSecretMask(ctx.alloc, &snap_doc, file.own_paths),
        else => partial.ownedHasSecretMask(&snap_doc, file.own_paths),
    };
    if (masked) {
        try ctx.err.print("  ERROR   {s} (snapshot masks a secret; placeholders are never written live -- re-apply the source instead)\n", .{live_path});
        failed.* += 1;
        return false;
    }

    // A symlinked live path is re-patched at its resolved target, same as
    // apply's partial path; a dangling link is refused, live untouched.
    const live_target = mox.apply.write.resolvePartialLive(ctx.alloc, ctx.io, live_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DanglingLink => {
            try ctx.err.print("  ERROR   {s} (live path is a dangling symlink; fix or remove the link)\n", .{live_path});
            failed.* += 1;
            return false;
        },
    };
    // Stat before the read so a write landing between the two refuses at
    // the post-fsync recheck, same as apply's partial path.
    const pre_stat = mox.apply.write.liveStat(ctx.io, live_target);
    const live: ?[]const u8 = Io.Dir.cwd().readFileAlloc(ctx.io, live_target, ctx.alloc, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
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

    // Disown mode re-patches the snapshot's owned COMPLEMENT: the snapshot
    // text minus its disowned spans plays the composed text's role, and the
    // current live file's disowned spans are preserved.
    var snap_owned_text: []const u8 = "";
    if (file.ownership == .disown) {
        const snap_loc = partial.locateSpans(ctx.alloc, format, snap_content, file.own_paths, &pdiag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try ctx.err.print("  ERROR   {s} (snapshot: {s})\n", .{ live_path, pdiag.text() });
                failed.* += 1;
                return false;
            },
        };
        snap_owned_text = try partial.textWithoutSpans(ctx.alloc, format, snap_content, snap_loc);
    }
    const snap_owned_doc = if (file.ownership == .disown)
        partial.OwnedDoc.parse(ctx.alloc, format, snap_owned_text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OwnedUnparseable => {
                try ctx.err.print("  ERROR   {s} (snapshot owned content does not parse as {s})\n", .{ live_path, @tagName(format) });
                failed.* += 1;
                return false;
            },
        }
    else
        snap_doc;

    const candidate = (switch (file.ownership) {
        .disown => partial.replaceDisowned(ctx.alloc, format, live_text, file.own_paths, snap_owned_text, &pdiag),
        else => partial.replaceOwned(ctx.alloc, format, live_text, file.own_paths, &snap_doc, &pdiag),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("  ERROR   {s} ({s})\n", .{ live_path, pdiag.text() });
            failed.* += 1;
            return false;
        },
    };
    (switch (file.ownership) {
        .disown => partial.verifyDisownInvariant(ctx.alloc, format, live_text, candidate, file.own_paths, snap_owned_text, &snap_owned_doc, &pdiag),
        else => partial.verifyInvariant(ctx.alloc, format, live_text, candidate, file.own_paths, &snap_doc, &pdiag),
    }) catch |e| switch (e) {
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

    // A live target absent here is legitimate (this partial target was never
    // materialized); any other stat failure is a real anomaly and must not
    // silently degrade the mode a rollback writes back.
    const mode = blk: {
        const st = Io.Dir.cwd().statFile(ctx.io, live_target, .{}) catch |e| switch (e) {
            error.FileNotFound => break :blk @as(u32, 0o644),
            else => return e,
        };
        break :blk mox.apply.write.modeOf(st.permissions);
    };
    mox.apply.write.writeAtomicPartial(ctx.io, live_target, candidate, mode, live_stat) catch |e| switch (e) {
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

fn testCtx(a: std.mem.Allocator, io: Io, home: []const u8, snapshots_dir: []const u8, out: *Io.Writer, err: *Io.Writer) !app.Ctx {
    const map_ptr = try a.create(std.process.Environ.Map);
    map_ptr.* = std.process.Environ.Map.init(a);
    return .{
        .alloc = a,
        .io = io,
        .context = .{
            .env = Env{ .map = map_ptr },
            .paths = .{
                .home = home,
                .repo_dir = "",
                .state_dir = "",
                .private_dir = "",
                .triggers_path = "",
                .snapshots_dir = snapshots_dir,
                .facts_path = "",
            },
        },
        .out = out,
        .err = err,
    };
}

var read_calls_after_setup: usize = 0;
var real_dir_read: *const fn (?*anyopaque, *Io.Dir.Reader, []Io.Dir.Entry) Io.Dir.Reader.Error!usize = undefined;

fn failingDirReadAfterOne(userdata: ?*anyopaque, r: *Io.Dir.Reader, buffer: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
    read_calls_after_setup += 1;
    if (read_calls_after_setup > 1) return error.Unexpected;
    return real_dir_read(userdata, r, buffer);
}

test "snapshotLivePaths: a mid-walk read failure propagates instead of silently truncating the set" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const home = try std.fs.path.join(a, &.{ base, "home" });
    const snaps = try std.fs.path.join(a, &.{ base, "snaps" });

    // Two entries: the walk order is unspecified, so a failure after the
    // first one must be reported rather than mistaken for having reached
    // the end of a one-entry snapshot.
    const live_a = try std.fs.path.join(a, &.{ home, "a" });
    const live_b = try std.fs.path.join(a, &.{ home, "b" });
    try mox.apply.write.writeAtomic(io, live_a, "a content\n", 0o644);
    try mox.apply.write.writeAtomic(io, live_b, "b content\n", 0o644);
    try mox.apply.snapshot.save(a, io, snaps, "id1", home, live_a, "a content\n");
    try mox.apply.snapshot.save(a, io, snaps, "id1", home, live_b, "b content\n");

    read_calls_after_setup = 0;
    real_dir_read = io.vtable.dirRead;
    var vtable = io.vtable.*;
    vtable.dirRead = failingDirReadAfterOne;
    const faulty: Io = .{ .userdata = io.userdata, .vtable = &vtable };

    var out_aw: Io.Writer.Allocating = .init(a);
    var err_aw: Io.Writer.Allocating = .init(a);
    var ctx = try testCtx(a, faulty, home, snaps, &out_aw.writer, &err_aw.writer);

    try std.testing.expectError(error.Unexpected, snapshotLivePaths(&ctx, "id1"));
}

test "snapshotLivePaths: a non-missing openDir failure propagates instead of reporting no paths" {
    if (!Io.File.Permissions.has_executable_bit) return; // no unix perms to lock out with
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const home = try std.fs.path.join(a, &.{ base, "home" });
    const snaps = try std.fs.path.join(a, &.{ base, "snaps" });

    const live_a = try std.fs.path.join(a, &.{ home, "a" });
    try mox.apply.write.writeAtomic(io, live_a, "a content\n", 0o644);
    try mox.apply.snapshot.save(a, io, snaps, "id1", home, live_a, "a content\n");
    const snap_dir = try std.fs.path.join(a, &.{ snaps, "id1" });
    try mox.apply.write.setMode(snap_dir, 0o000);
    defer mox.apply.write.setMode(snap_dir, 0o755) catch {};

    var out_aw: Io.Writer.Allocating = .init(a);
    var err_aw: Io.Writer.Allocating = .init(a);
    var ctx = try testCtx(a, io, home, snaps, &out_aw.writer, &err_aw.writer);

    try std.testing.expectError(error.AccessDenied, snapshotLivePaths(&ctx, "id1"));
}
