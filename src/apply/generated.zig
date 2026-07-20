//! Generator (`for ... into`) produced-set manifest and prune.
//!
//! A generator OWNS the set of live files it fans out. mox records that set
//! per generator under `<state>/generated/<hash(gen-live-path)>` (one produced
//! path per line). On the next apply, after the current set is written, any
//! prior-set path no longer produced is removed -- snapshot-first, and only
//! when the removal is safe: a path this generator no longer owns is deleted
//! only if it is a clean mox-written leaf (or `--force`), never a foreign or
//! drifted file. Removing the generator source removes its whole set.
//!
//! DATA SAFETY: pruning acts ONLY on paths in this generator's own manifest,
//! minus a `keep` set the caller supplies (the current produced set plus every
//! other managed/generated target), so a path that is now produced by anything
//! else is never touched. Every removal is snapshotted first (secret lines
//! redacted), and an unsnapshottable or drifted leaf is refused, not deleted.

const std = @import("std");

const Io = std.Io;
const applied = @import("applied.zig");
const snapshot = @import("snapshot.zig");
const write = @import("write.zig");
const prov_map = @import("../provenance/root.zig").map;

const max_content_bytes: usize = 64 * 1024 * 1024;

pub const Options = struct {
    state_dir: []const u8,
    snapshots_dir: []const u8,
    snap_id: []const u8,
    home: []const u8,
    force: bool,
    dry_run: bool,
};

pub const Result = struct {
    /// Leaves removed (or, under dry-run, that would be removed).
    removed: usize = 0,
    /// Leaves refused (unsnapshottable, or drifted without `--force`).
    refused: usize = 0,
};

fn manifestPath(arena: std.mem.Allocator, state_dir: []const u8, gen_live: []const u8) ![]u8 {
    const name = applied.contentHashHex(gen_live);
    return std.fs.path.join(arena, &.{ state_dir, "generated", &name });
}

/// The prior produced set for the generator identified by `gen_live`, or an
/// empty slice when none is recorded. Arena-owned.
pub fn readManifest(arena: std.mem.Allocator, io: Io, state_dir: []const u8, gen_live: []const u8) ![]const []const u8 {
    const path = try manifestPath(arena, state_dir, gen_live);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_content_bytes)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        try out.append(arena, try arena.dupe(u8, t));
    }
    return out.toOwnedSlice(arena);
}

/// Record `paths` as the generator's current produced set (one path per line).
pub fn writeManifest(arena: std.mem.Allocator, io: Io, state_dir: []const u8, gen_live: []const u8, paths: []const []const u8) !void {
    const path = try manifestPath(arena, state_dir, gen_live);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(arena);
    for (paths) |p| {
        try body.appendSlice(arena, p);
        try body.append(arena, '\n');
    }
    // Atomic (sync+rename), matching every other mox write: a torn manifest
    // would mis-list the produced set and mis-prune on the next apply.
    try write.writeAtomic(io, path, body.items, 0o644);
}

/// Drop the generator's manifest entirely (its source is being removed).
pub fn deleteManifest(arena: std.mem.Allocator, io: Io, state_dir: []const u8, gen_live: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, try manifestPath(arena, state_dir, gen_live)) catch {};
}

/// Remove every prior-set path not in `keep`, snapshot-first. `keep` holds the
/// paths that must survive: the current produced set plus every other managed
/// or generated target, so a path handed off to another producer is never
/// deleted here. Returns the removal/refusal tally.
pub fn pruneStale(
    arena: std.mem.Allocator,
    io: Io,
    opts: Options,
    prior: []const []const u8,
    keep: *const std.StringHashMap(void),
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !Result {
    var result: Result = .{};
    for (prior) |p| {
        if (keep.contains(p)) continue;
        try removeLeaf(arena, io, opts, p, stdout, stderr, &result);
    }
    return result;
}

/// Remove one generated leaf that is no longer produced. Snapshot-first, and
/// refuse rather than delete anything unrecoverable or drifted (without force).
fn removeLeaf(
    arena: std.mem.Allocator,
    io: Io,
    opts: Options,
    live_path: []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    result: *Result,
) !void {
    // Inspect the leaf WITHOUT following a symlink. A leaf that drifted into a
    // link must be snapshotted AS a link and removed -- never dereferenced,
    // which would back up an unrelated target's content and change the entry's
    // type on rollback.
    switch (applied.inspectSymSite(io, arena, live_path)) {
        // Already gone: nothing to remove, but clear its stale records so a
        // later unrelated file at this path is not read as mox-written.
        .absent => {
            try forgetRecords(arena, io, opts.state_dir, live_path);
            return;
        },
        // Never delete a directory that appeared where a leaf was.
        .directory => {
            result.refused += 1;
            try stderr.print("  {s}: generated leaf is now a directory, not removing\n", .{live_path});
            return;
        },
        // mox only ever wrote a regular file as a generated leaf, so a symlink
        // here is drift: refuse without --force, else snapshot the LINK (its
        // target string, not the dereferenced content) and remove it.
        .symlink => |target| {
            if (!opts.force) {
                result.refused += 1;
                try stderr.print("  DRIFT {s} (generated leaf is now a symlink; 'mox commit' or re-run with --force to prune)\n", .{live_path});
                return;
            }
            if (opts.dry_run) {
                result.removed += 1;
                try stdout.print("  would remove {s} (generated, no longer produced)\n", .{live_path});
                return;
            }
            snapshot.saveSymlink(arena, io, opts.snapshots_dir, opts.snap_id, opts.home, live_path, target) catch |e| {
                result.refused += 1;
                try stderr.print("  UNSNAPSHOTTABLE {s} (generated leaf; snapshot failed, not removing: {s})\n", .{ live_path, @errorName(e) });
                return;
            };
            Io.Dir.cwd().deleteFile(io, live_path) catch |e| {
                result.refused += 1;
                try stderr.print("  {s}: could not remove generated leaf: {s}\n", .{ live_path, @errorName(e) });
                return;
            };
            try forgetRecords(arena, io, opts.state_dir, live_path);
            result.removed += 1;
            try stdout.print("  removed {s} (generated, no longer produced)\n", .{live_path});
            return;
        },
        // A regular file (confirmed not a symlink): the read below cannot follow
        // a link. Fall through to the clean/drift check and snapshot.
        .other => {},
    }

    const content = Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(max_content_bytes)) catch |e| switch (e) {
        error.FileNotFound => {
            try forgetRecords(arena, io, opts.state_dir, live_path);
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            result.refused += 1;
            try stderr.print("  UNSNAPSHOTTABLE {s} (generated leaf; not removing, cannot read to back up)\n", .{live_path});
            return;
        },
    };

    // A clean leaf is exactly what mox last wrote here. A drifted one (edited,
    // or never recorded) is refused without --force, mirroring the exact sweep.
    const rec = try applied.read(arena, io, opts.state_dir, live_path);
    const clean = if (rec) |r| std.mem.eql(u8, &r, &applied.contentHashHex(content)) else false;
    if (!clean and !opts.force) {
        result.refused += 1;
        try stderr.print("  DRIFT {s} (generated leaf edited; 'mox commit' or re-run with --force to prune)\n", .{live_path});
        return;
    }
    if (opts.dry_run) {
        result.removed += 1;
        try stdout.print("  would remove {s} (generated, no longer produced)\n", .{live_path});
        return;
    }

    // Snapshot the prior content (secret lines redacted from its provenance)
    // before deleting, and refuse the delete if the snapshot cannot be taken.
    const snap_content = try redactedContent(arena, io, opts.state_dir, live_path, content);
    snapshot.save(arena, io, opts.snapshots_dir, opts.snap_id, opts.home, live_path, snap_content) catch |e| {
        result.refused += 1;
        try stderr.print("  UNSNAPSHOTTABLE {s} (generated leaf; snapshot failed, not removing: {s})\n", .{ live_path, @errorName(e) });
        return;
    };
    Io.Dir.cwd().deleteFile(io, live_path) catch |e| {
        result.refused += 1;
        try stderr.print("  {s}: could not remove generated leaf: {s}\n", .{ live_path, @errorName(e) });
        return;
    };
    try forgetRecords(arena, io, opts.state_dir, live_path);
    result.removed += 1;
    try stdout.print("  removed {s} (generated, no longer produced)\n", .{live_path});
}

/// Clear every last-applied + provenance record for a pruned leaf.
fn forgetRecords(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !void {
    try applied.forget(arena, io, state_dir, live_path);
    try prov_map.forget(arena, io, state_dir, live_path);
}

/// `content` with any secret line redacted using the last-persisted provenance
/// for `live_path`. A generated leaf may hold a resolved secret; its cleartext
/// must not be copied into a snapshot. An absent/non-secret provenance leaves
/// the content unchanged.
fn redactedContent(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8, content: []const u8) ![]const u8 {
    const prior = (try prov_map.read(arena, io, state_dir, live_path)) orelse return content;
    return prov_map.redactSecretLines(arena, content, prior.segments);
}

test "readManifest: absent manifest is an empty set; write then read round-trips" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const state = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "state" });

    try std.testing.expectEqual(@as(usize, 0), (try readManifest(a, io, state, "/home/me/.config/git/gen")).len);

    try writeManifest(a, io, state, "/home/me/.config/git/gen", &.{ "/home/me/.config/git/id-a.inc", "/home/me/.config/git/id-b.inc" });
    const got = try readManifest(a, io, state, "/home/me/.config/git/gen");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("/home/me/.config/git/id-a.inc", got[0]);
    try std.testing.expectEqualStrings("/home/me/.config/git/id-b.inc", got[1]);

    try deleteManifest(a, io, state, "/home/me/.config/git/gen");
    try std.testing.expectEqual(@as(usize, 0), (try readManifest(a, io, state, "/home/me/.config/git/gen")).len);
}
