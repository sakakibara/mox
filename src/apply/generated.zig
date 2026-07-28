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
const dirent = @import("../source/dirent.zig");

const max_content_bytes: usize = 64 * 1024 * 1024;

pub const Options = struct {
    state_dir: []const u8,
    snapshots_dir: []const u8,
    snap_id: []const u8,
    home: []const u8,
    force: bool,
    dry_run: bool,
    /// True when the caller folds a drift-class refusal into its own
    /// generator-scoped report row (the unified classifier's `generated_set`
    /// unit) and so does not want a per-leaf DRIFT line duplicating it.
    /// `false` keeps the per-leaf message (an orphaned generator has no
    /// scopeable row to fold into, so the per-leaf line is the only report).
    mute_drift_message: bool = false,
};

pub const Result = struct {
    /// Leaves removed (or, under dry-run, that would be removed).
    removed: usize = 0,
    /// Leaves refused because they drifted and `--force`/`--overwrite` was
    /// not given: resolvable by the caller re-running forced.
    drift_refused: usize = 0,
    /// Leaves refused for a reason `--force`/`--overwrite` cannot resolve
    /// (unsnapshottable, undeletable, or now a directory/special file).
    error_refused: usize = 0,
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

/// The manifest-file name (hash of the generator's live path) for membership
/// checks against the on-disk manifest set.
pub fn manifestName(gen_live: []const u8) [64]u8 {
    return applied.contentHashHex(gen_live);
}

/// Prune ORPHANED manifests: every manifest in `<state>/generated/` whose
/// name is not in `known` belongs to a generator that left the tree -- its
/// source was deleted outside `mox remove`, or the file no longer parses as
/// a generator. Each orphan's listed leaves are pruned against `keep`
/// (snapshot-first, drift-refusing, exactly like a live generator's prune),
/// then the manifest itself is dropped. Callers must skip this sweep on a
/// scoped apply (an unwalked generator is not an orphan) and after a
/// drift-prompt abort.
pub fn sweepOrphans(
    arena: std.mem.Allocator,
    io: Io,
    opts: Options,
    known: *const std.StringHashMap(void),
    keep: *const std.StringHashMap(void),
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !Result {
    var result: Result = .{};
    const gen_dir_path = try std.fs.path.join(arena, &.{ opts.state_dir, "generated" });

    const entries = dirent.sortedPath(arena, io, gen_dir_path, .{ .iterate = true }) catch return result;

    for (entries) |entry| {
        if (entry.kind != .file) continue;
        if (known.contains(entry.name)) continue;
        const name = entry.name;
        const path = try std.fs.path.join(arena, &.{ gen_dir_path, name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_content_bytes)) catch continue;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var all_removed = true;
        while (lines.next()) |line| {
            const leaf = std.mem.trim(u8, line, " \t\r");
            if (leaf.len == 0) continue;
            if (keep.contains(leaf)) continue;
            const before = result.drift_refused + result.error_refused;
            try removeLeaf(arena, io, opts, leaf, stdout, stderr, &result);
            if (result.drift_refused + result.error_refused > before) all_removed = false;
        }
        // Keep the manifest while any leaf was refused (drifted or
        // unsnapshottable), so the next apply retries instead of orphaning
        // the leaf itself.
        if (all_removed and !opts.dry_run) {
            Io.Dir.cwd().deleteFile(io, path) catch {};
        }
    }
    return result;
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
        // Never delete a directory that appeared where a leaf was. `--force`
        // does not resolve this (there is no directory-replace primitive
        // here), so it is an error, not drift needing a decision.
        .directory => {
            result.error_refused += 1;
            try stderr.print("  {s}: generated leaf is now a directory, not removing\n", .{live_path});
            return;
        },
        // mox only ever wrote a regular file as a generated leaf, so a symlink
        // here is drift: refuse without --force, else snapshot the LINK (its
        // target string, not the dereferenced content) and remove it.
        .symlink => |target| {
            if (!opts.force) {
                result.drift_refused += 1;
                if (!opts.mute_drift_message)
                    try stderr.print("  DRIFT {s} (generated leaf is now a symlink; 'mox commit' or re-run with --force to prune)\n", .{live_path});
                return;
            }
            if (opts.dry_run) {
                result.removed += 1;
                try stdout.print("  would remove {s} (generated, no longer produced)\n", .{live_path});
                return;
            }
            snapshot.saveSymlink(arena, io, opts.snapshots_dir, opts.snap_id, opts.home, live_path, target) catch |e| {
                result.error_refused += 1;
                try stderr.print("  UNSNAPSHOTTABLE {s} (generated leaf; snapshot failed, not removing: {s})\n", .{ live_path, @errorName(e) });
                return;
            };
            Io.Dir.cwd().deleteFile(io, live_path) catch |e| {
                result.error_refused += 1;
                try stderr.print("  {s}: could not remove generated leaf: {s}\n", .{ live_path, @errorName(e) });
                return;
            };
            try forgetRecords(arena, io, opts.state_dir, live_path);
            result.removed += 1;
            try stdout.print("  removed {s} (generated, no longer produced)\n", .{live_path});
            return;
        },
        // Not a symlink, directory, or absent entry: usually a regular file.
        // The kind guard below refuses the special inodes this also covers.
        .other => {},
    }

    // A FIFO/socket/device where a leaf was: mox never wrote it, cannot back
    // it up, and opening a FIFO to read would block -- refuse, never delete.
    switch (write.guardLiveRead(io, live_path)) {
        .readable, .absent => {},
        .special => {
            result.error_refused += 1;
            try stderr.print("  {s}: generated leaf is not a regular file, not removing\n", .{live_path});
            return;
        },
    }

    const content = Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(max_content_bytes)) catch |e| switch (e) {
        error.FileNotFound => {
            try forgetRecords(arena, io, opts.state_dir, live_path);
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            result.error_refused += 1;
            try stderr.print("  UNSNAPSHOTTABLE {s} (generated leaf; not removing, cannot read to back up)\n", .{live_path});
            return;
        },
    };

    // A clean leaf is exactly what mox last wrote here. A drifted one (edited,
    // or never recorded) is refused without --force, mirroring the exact sweep.
    const rec = try applied.read(arena, io, opts.state_dir, live_path);
    const clean = if (rec) |r| std.mem.eql(u8, &r, &applied.contentHashHex(content)) else false;
    if (!clean and !opts.force) {
        result.drift_refused += 1;
        if (!opts.mute_drift_message)
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
        result.error_refused += 1;
        try stderr.print("  UNSNAPSHOTTABLE {s} (generated leaf; snapshot failed, not removing: {s})\n", .{ live_path, @errorName(e) });
        return;
    };
    Io.Dir.cwd().deleteFile(io, live_path) catch |e| {
        result.error_refused += 1;
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
