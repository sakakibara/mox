//! Generator (`for ... into`) produced-set manifest and prune.
//!
//! A generator OWNS the set of live files it fans out. mox records that set
//! per generator under `<state>/generated/<hash(gen-live-path)>`: a first line
//! `repo <pct>` naming the repo it came from, then one produced path per
//! line. On the next apply, after the current set is written, any
//! prior-set path no longer produced is removed -- snapshot-first, and only
//! when the removal is safe: a path this generator no longer owns is deleted
//! only if it is a clean mox-written leaf (or `--overwrite`), never a foreign or
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
const stale = @import("stale.zig");
const parent_link = @import("parent_link.zig");
const write = @import("write.zig");
const prov_map = @import("../provenance/root.zig").map;
const dirent = @import("../source/dirent.zig");
const source_path = @import("../source/path.zig");
const ignore_match = @import("../source/ignore/match.zig");

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
    /// The repo this run applies, as records name it: the orphan sweep
    /// leaves another repo's tagged manifests alone.
    repo: []const u8 = "",
    /// Manifest names (`manifestName`) of generators `.mox/attributes.toml`
    /// released: their manifests are forgotten and their leaves kept.
    released: ?*const std.StringHashMap(void) = null,
    /// The released live paths through `stale.foldCase`, matched against a
    /// manifest's recorded generator path.
    released_live: ?*const std.StringHashMap(void) = null,
    /// Live paths the tree plants as symlinks: a leaf below one is never
    /// removed.
    links: ?*const std.StringHashMap(void) = null,
    /// The ignore rules: an orphaned generator's file they match is left
    /// alone, as the stale sweep leaves one.
    ruleset: ?*const ignore_match.RuleSet = null,
    /// The inodes of every path still produced or managed: a dropped file
    /// that is the same file as one of them is forgotten, never removed.
    kept_inodes: ?*const std.AutoHashMap(u128, void) = null,
};

pub const Result = struct {
    /// Leaves removed (or, under dry-run, that would be removed).
    removed: usize = 0,
    /// Leaves refused because they drifted and `--overwrite` was
    /// not given: resolvable by the caller re-running forced.
    drift_refused: usize = 0,
    /// Leaves refused for a reason `--overwrite` cannot resolve
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
    return leavesOf(arena, bytes);
}

/// The produced paths a manifest's bytes list, its repo line skipped.
fn leavesOf(arena: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        defer first = false;
        if (t.len == 0) continue;
        if (first and std.mem.startsWith(u8, t, "repo ")) continue;
        if (std.mem.startsWith(u8, t, generator_prefix)) continue;
        try out.append(arena, try arena.dupe(u8, t));
    }
    return out.toOwnedSlice(arena);
}

const generator_prefix = "generator ";

/// The generator's live path a manifest's bytes record, or null for one
/// written before manifests recorded it.
pub fn generatorOf(arena: std.mem.Allocator, bytes: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, generator_prefix)) return applied.pctDecode(arena, line[generator_prefix.len..]);
    }
    return null;
}

/// The generator live path of every manifest in `<state>/generated/`.
pub fn allGenerators(arena: std.mem.Allocator, io: Io, state_dir: []const u8) ![]const []const u8 {
    const gen_dir_path = try std.fs.path.join(arena, &.{ state_dir, "generated" });
    const entries = dirent.sortedPath(arena, io, gen_dir_path, .{ .iterate = true }) catch return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(arena, &.{ gen_dir_path, entry.name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_content_bytes)) catch continue;
        if (try generatorOf(arena, bytes)) |g| try out.append(arena, g);
    }
    return out.toOwnedSlice(arena);
}

/// The repo a manifest's bytes name, or null for an untagged one.
fn repoOf(arena: std.mem.Allocator, bytes: []const u8) !?[]const u8 {
    const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    const first = bytes[0..nl];
    if (!std.mem.startsWith(u8, first, "repo ")) return null;
    return applied.pctDecode(arena, first["repo ".len..]);
}

/// Every produced path any manifest in `<state>/generated/` lists, whatever
/// repo wrote it.
pub fn allLeaves(arena: std.mem.Allocator, io: Io, state_dir: []const u8) ![]const []const u8 {
    const gen_dir_path = try std.fs.path.join(arena, &.{ state_dir, "generated" });
    const entries = dirent.sortedPath(arena, io, gen_dir_path, .{ .iterate = true }) catch return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(arena, &.{ gen_dir_path, entry.name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_content_bytes)) catch continue;
        try out.appendSlice(arena, try leavesOf(arena, bytes));
    }
    return out.toOwnedSlice(arena);
}

/// Record `paths` as the generator's current produced set, under a first
/// line naming `repo`.
pub fn writeManifest(arena: std.mem.Allocator, io: Io, state_dir: []const u8, gen_live: []const u8, paths: []const []const u8, repo: []const u8) !void {
    const path = try manifestPath(arena, state_dir, gen_live);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(arena);
    try body.appendSlice(arena, "repo ");
    try body.appendSlice(arena, try applied.pctEncode(arena, repo));
    try body.append(arena, '\n');
    try body.appendSlice(arena, generator_prefix);
    try body.appendSlice(arena, try applied.pctEncode(arena, gen_live));
    try body.append(arena, '\n');
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

/// What one apply run knows about generators, for the orphan sweep: the
/// manifest names of every generator it walked (composed, failed or
/// undecided), and every live path still produced or managed. apply, status
/// and diff build it the same way, so they judge the same orphans.
pub const OrphanScan = struct {
    known: std.StringHashMap(void),
    keep: std.StringHashMap(void),

    pub fn init(arena: std.mem.Allocator) OrphanScan {
        return .{ .known = .init(arena), .keep = .init(arena) };
    }

    /// A managed file's live path, or a file a generator produces this run.
    pub fn kept(self: *OrphanScan, live: []const u8) !void {
        try self.keep.put(live, {});
    }

    /// A file walked as a generator, or whose nature is undecided this run
    /// (a head error, a failed compose): its manifest is no orphan.
    pub fn walked(self: *OrphanScan, arena: std.mem.Allocator, live: []const u8) !void {
        try self.known.put(try arena.dupe(u8, &manifestName(live)), {});
    }

    /// A generator that failed to compose: walked, and its prior files kept.
    pub fn failed(self: *OrphanScan, arena: std.mem.Allocator, io: Io, state_dir: []const u8, live: []const u8) !void {
        try self.walked(arena, live);
        for (try readManifest(arena, io, state_dir, live)) |leaf| try self.keep.put(leaf, {});
    }
};

/// How the orphan sweep judges one file of an orphaned generator.
pub const LeafVerdict = enum {
    /// Already gone: its records are forgotten.
    gone,
    /// Below a symlinked directory: left in place, its records forgotten.
    linked_parent,
    /// The same file as a path still produced or managed (a case-only
    /// rename, a hardlink): its records forgotten, nothing removed.
    same_file,
    /// A path `.moxignore` matches: not mox's to touch.
    ignored,
    /// Now a directory, a special file, or unreadable: refused.
    refused,
    /// Now a symlink, or edited since mox wrote it: drift.
    drift,
    /// Unedited: removed, snapshot-first.
    remove,
};

pub const PlannedLeaf = struct { path: []const u8, verdict: LeafVerdict };

/// One orphaned manifest: released by a tombstone (its records forgotten,
/// its files kept), or its files as the sweep would judge them.
pub const OrphanManifest = struct {
    path: []const u8,
    released: bool,
    leaves: []const PlannedLeaf,
};

/// Judge one file the way `removeLeaf` acts on it.
pub fn judgeLeaf(arena: std.mem.Allocator, io: Io, opts: Options, live_path: []const u8) !LeafVerdict {
    if (parent_link.through(io, opts.home, live_path, opts.links)) return .linked_parent;
    if (opts.kept_inodes) |k| if (stale.sameFile(io, live_path, k)) return .same_file;
    if (opts.ruleset) |rs| {
        if (rs.isPathIgnored(try source_path.liveKeyRelToHome(arena, opts.home, live_path), false)) return .ignored;
    }
    switch (applied.inspectSymSite(io, arena, live_path)) {
        .absent => return .gone,
        .directory => return .refused,
        .symlink => return .drift,
        .other => {},
    }
    if (write.guardLiveRead(io, live_path) == .special) return .refused;
    const content = Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(max_content_bytes)) catch |e| switch (e) {
        error.FileNotFound => return .gone,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .refused,
    };
    const rec = try applied.read(arena, io, opts.state_dir, live_path);
    const clean = if (rec) |r| std.mem.eql(u8, &r, &applied.contentHashHex(content)) else false;
    return if (clean) .remove else .drift;
}

/// Every orphaned manifest in `<state>/generated/` and what the sweep would
/// do with it: a manifest `scan` does not know, tagged with `opts.repo`.
/// An untagged manifest, another repo's or HOME's, or one listing a file
/// outside this run's HOME is never an orphan here.
pub fn planOrphans(arena: std.mem.Allocator, io: Io, opts_in: Options, scan: *const OrphanScan) ![]const OrphanManifest {
    var opts = opts_in;
    var kept: std.ArrayList([]const u8) = .empty;
    var kit = scan.keep.keyIterator();
    while (kit.next()) |k| try kept.append(arena, k.*);
    const inodes = try arena.create(std.AutoHashMap(u128, void));
    inodes.* = try stale.inodesOf(arena, io, kept.items);
    opts.kept_inodes = inodes;
    var out: std.ArrayList(OrphanManifest) = .empty;
    const gen_dir_path = try std.fs.path.join(arena, &.{ opts.state_dir, "generated" });
    const entries = dirent.sortedPath(arena, io, gen_dir_path, .{ .iterate = true }) catch return &.{};
    outer: for (entries) |entry| {
        if (entry.kind != .file or scan.known.contains(entry.name)) continue;
        const path = try std.fs.path.join(arena, &.{ gen_dir_path, entry.name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_content_bytes)) catch continue;
        const r = (try repoOf(arena, bytes)) orelse continue;
        if (!std.mem.eql(u8, r, opts.repo)) continue;
        const leaves = try leavesOf(arena, bytes);
        for (leaves) |leaf| if (!parent_link.underHome(leaf, opts.home)) continue :outer;
        const released = if (try generatorOf(arena, bytes)) |g|
            (if (opts.released_live) |rl| rl.contains(try stale.foldCase(arena, g)) else false)
        else if (opts.released) |rel| rel.contains(entry.name) else false;
        var planned: std.ArrayList(PlannedLeaf) = .empty;
        for (leaves) |leaf| {
            if (scan.keep.contains(leaf)) continue;
            try planned.append(arena, .{ .path = leaf, .verdict = if (released) .gone else try judgeLeaf(arena, io, opts, leaf) });
        }
        try out.append(arena, .{ .path = path, .released = released, .leaves = try planned.toOwnedSlice(arena) });
    }
    return out.toOwnedSlice(arena);
}

/// Act on `plan`: a released manifest's files are forgotten and kept, and
/// the manifest dropped; every other manifest's files are removed as
/// `removeLeaf` decides, an ignored one left alone. A manifest is dropped
/// only when nothing of it was refused or left, so the next apply retries.
/// Callers skip this sweep on a scoped apply and in a run where anything
/// failed.
pub fn sweepOrphans(
    arena: std.mem.Allocator,
    io: Io,
    opts: Options,
    plan: []const OrphanManifest,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !Result {
    var result: Result = .{};
    for (plan) |m| {
        if (m.released) {
            if (!opts.dry_run) {
                for (m.leaves) |leaf| try forgetRecords(arena, io, opts.state_dir, leaf.path);
                Io.Dir.cwd().deleteFile(io, m.path) catch {};
            }
            continue;
        }
        var all_removed = true;
        for (m.leaves) |leaf| {
            if (leaf.verdict == .ignored) {
                all_removed = false;
                continue;
            }
            if (leaf.verdict == .same_file) {
                if (!opts.dry_run) try forgetRecords(arena, io, opts.state_dir, leaf.path);
                continue;
            }
            const before = result.drift_refused + result.error_refused;
            try removeLeaf(arena, io, opts, leaf.path, stdout, stderr, &result);
            if (result.drift_refused + result.error_refused > before) all_removed = false;
        }
        if (all_removed and !opts.dry_run) Io.Dir.cwd().deleteFile(io, m.path) catch {};
    }
    return result;
}

/// The manifest that lists `leaf` for a generator no longer in the tree
/// (`tree_live` holds every managed live path): one tagged `repo`, or with
/// `untagged` one that names no repo. Null when none does.
pub fn orphanManifestOf(arena: std.mem.Allocator, io: Io, state_dir: []const u8, repo: []const u8, untagged: bool, tree_live: *const std.StringHashMap(void), leaf: []const u8) !?[]const u8 {
    var tree_names = std.StringHashMap(void).init(arena);
    var it = tree_live.keyIterator();
    while (it.next()) |p| try tree_names.put(try arena.dupe(u8, &manifestName(p.*)), {});
    const gen_dir_path = try std.fs.path.join(arena, &.{ state_dir, "generated" });
    const entries = dirent.sortedPath(arena, io, gen_dir_path, .{ .iterate = true }) catch return null;
    for (entries) |entry| {
        if (entry.kind != .file or tree_names.contains(entry.name)) continue;
        const path = try std.fs.path.join(arena, &.{ gen_dir_path, entry.name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_content_bytes)) catch continue;
        if (try repoOf(arena, bytes)) |r| {
            if (!std.mem.eql(u8, r, repo)) continue;
        } else if (!untagged) continue;
        for (try leavesOf(arena, bytes)) |l| if (std.mem.eql(u8, l, leaf)) return path;
    }
    return null;
}

/// Drop `leaf` from the manifest at `manifest_path`, deleting the manifest
/// when no file is left in it.
pub fn dropLeaf(arena: std.mem.Allocator, io: Io, manifest_path: []const u8, leaf: []const u8) !void {
    const bytes = Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(max_content_bytes)) catch return;
    var out: std.ArrayList(u8) = .empty;
    var leaves: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        defer first = false;
        if (line.len == 0) continue;
        const header = (first and std.mem.startsWith(u8, line, "repo ")) or std.mem.startsWith(u8, line, generator_prefix);
        if (!header) {
            if (std.mem.eql(u8, line, leaf)) continue;
            leaves += 1;
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    if (leaves == 0) {
        Io.Dir.cwd().deleteFile(io, manifest_path) catch {};
        return;
    }
    try write.writeAtomic(io, manifest_path, out.items, 0o644);
}

/// Remove one file of an orphaned generator that a scoped run names, as the
/// orphan sweep would (`opts.force` removes an edited one too), and drop it
/// from its manifest once it is gone.
pub fn removeNamedLeaf(arena: std.mem.Allocator, io: Io, opts: Options, manifest_path: []const u8, leaf: []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !Result {
    var result: Result = .{};
    try removeLeaf(arena, io, opts, leaf, stdout, stderr, &result);
    if (!opts.dry_run and result.drift_refused + result.error_refused == 0) try dropLeaf(arena, io, manifest_path, leaf);
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
    if (opts.kept_inodes) |k| if (stale.sameFile(io, live_path, k)) {
        if (!opts.dry_run) try forgetRecords(arena, io, opts.state_dir, live_path);
        return;
    };
    if (parent_link.through(io, opts.home, live_path, opts.links)) {
        if (!opts.dry_run) try forgetRecords(arena, io, opts.state_dir, live_path);
        try stdout.print("  {s}: {s}\n", .{ try tilde(arena, opts.home, live_path), parent_link.reason });
        return;
    }
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
        // Never delete a directory that appeared where a leaf was. `--overwrite`
        // does not resolve this (there is no directory-replace primitive
        // here), so it is an error, not drift needing a decision.
        .directory => {
            result.error_refused += 1;
            try stderr.print("  {s}: generated leaf is now a directory, not removing\n", .{try tilde(arena, opts.home, live_path)});
            return;
        },
        // mox only ever wrote a regular file as a generated leaf, so a symlink
        // here is drift: refuse without --overwrite, else snapshot the LINK (its
        // target string, not the dereferenced content) and remove it.
        .symlink => |target| {
            if (!opts.force) {
                result.drift_refused += 1;
                if (!opts.mute_drift_message)
                    try stderr.print("  DRIFT {s} (generated leaf is now a symlink; 'mox commit' or re-run with --overwrite to prune)\n", .{try tilde(arena, opts.home, live_path)});
                return;
            }
            if (opts.dry_run) {
                result.removed += 1;
                try stdout.print("  would remove {s} (generated, no longer produced)\n", .{try tilde(arena, opts.home, live_path)});
                return;
            }
            snapshot.saveSymlink(arena, io, opts.snapshots_dir, opts.snap_id, opts.home, live_path, target) catch |e| {
                result.error_refused += 1;
                try stderr.print("  UNSNAPSHOTTABLE {s} (generated leaf; snapshot failed, not removing: {s})\n", .{ try tilde(arena, opts.home, live_path), @errorName(e) });
                return;
            };
            Io.Dir.cwd().deleteFile(io, live_path) catch |e| {
                result.error_refused += 1;
                try stderr.print("  {s}: could not remove generated leaf: {s}\n", .{ try tilde(arena, opts.home, live_path), @errorName(e) });
                return;
            };
            try forgetRecords(arena, io, opts.state_dir, live_path);
            result.removed += 1;
            try stdout.print("  removed {s} (generated, no longer produced)\n", .{try tilde(arena, opts.home, live_path)});
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
            try stderr.print("  {s}: generated leaf is not a regular file, not removing\n", .{try tilde(arena, opts.home, live_path)});
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
            try stderr.print("  UNSNAPSHOTTABLE {s} (generated leaf; not removing, cannot read to back up)\n", .{try tilde(arena, opts.home, live_path)});
            return;
        },
    };

    // A clean leaf is exactly what mox last wrote here. A drifted one (edited,
    // or never recorded) is refused without --overwrite, mirroring the exact sweep.
    const rec = try applied.read(arena, io, opts.state_dir, live_path);
    const clean = if (rec) |r| std.mem.eql(u8, &r, &applied.contentHashHex(content)) else false;
    if (!clean and !opts.force) {
        result.drift_refused += 1;
        if (!opts.mute_drift_message)
            try stderr.print("  DRIFT {s} (generated leaf edited; 'mox commit' or re-run with --overwrite to prune)\n", .{try tilde(arena, opts.home, live_path)});
        return;
    }
    if (opts.dry_run) {
        result.removed += 1;
        try stdout.print("  would remove {s} (generated, no longer produced)\n", .{try tilde(arena, opts.home, live_path)});
        return;
    }

    // Snapshot the prior content (secret lines redacted from its provenance)
    // before deleting, and refuse the delete if the snapshot cannot be taken.
    const snap_content = try redactedContent(arena, io, opts.state_dir, live_path, content);
    snapshot.save(arena, io, opts.snapshots_dir, opts.snap_id, opts.home, live_path, snap_content) catch |e| {
        result.error_refused += 1;
        try stderr.print("  UNSNAPSHOTTABLE {s} (generated leaf; snapshot failed, not removing: {s})\n", .{ try tilde(arena, opts.home, live_path), @errorName(e) });
        return;
    };
    Io.Dir.cwd().deleteFile(io, live_path) catch |e| {
        result.error_refused += 1;
        try stderr.print("  {s}: could not remove generated leaf: {s}\n", .{ try tilde(arena, opts.home, live_path), @errorName(e) });
        return;
    };
    try forgetRecords(arena, io, opts.state_dir, live_path);
    result.removed += 1;
    try stdout.print("  removed {s} (generated, no longer produced)\n", .{try tilde(arena, opts.home, live_path)});
}

/// `path` as reports name it, a leading HOME written `~`.
fn tilde(arena: std.mem.Allocator, home: []const u8, path: []const u8) ![]const u8 {
    if (!parent_link.underHome(path, home)) return path;
    return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]});
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

    try writeManifest(a, io, state, "/home/me/.config/git/gen", &.{ "/home/me/.config/git/id-a.inc", "/home/me/.config/git/id-b.inc" }, "/repo");
    const got = try readManifest(a, io, state, "/home/me/.config/git/gen");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("/home/me/.config/git/id-a.inc", got[0]);
    try std.testing.expectEqualStrings("/home/me/.config/git/id-b.inc", got[1]);

    try deleteManifest(a, io, state, "/home/me/.config/git/gen");
    try std.testing.expectEqual(@as(usize, 0), (try readManifest(a, io, state, "/home/me/.config/git/gen")).len);
}
