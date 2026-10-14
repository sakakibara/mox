//! Generator (`for ... into`) produced sets and their prune.
//!
//! A generator OWNS the set of live files it fans out. mox records that set
//! per generator, with the part it came from. On the next apply, after the
//! current set is written, any
//! prior-set path no longer produced is removed -- snapshot-first, and only
//! when the removal is safe: a path this generator no longer owns is deleted
//! only if it is a clean mox-written leaf (or `--overwrite`), never a foreign or
//! drifted file. Removing the generator source removes its whole set.
//!
//! DATA SAFETY: pruning acts ONLY on paths in this generator's own set,
//! minus a `keep` set the caller supplies (the current produced set plus every
//! other managed/generated target), so a path that is now produced by anything
//! else is never touched. Every removal is snapshotted first (secret lines
//! redacted), and an unsnapshottable or drifted leaf is refused, not deleted.

const std = @import("std");

const Io = std.Io;
const applied = @import("applied.zig");
const snapshot = @import("snapshot.zig");
const stale = @import("stale.zig");
const live_remove = @import("live_remove.zig");
const removable = @import("removable.zig");
const parent_link = @import("parent_link.zig");
const write = @import("write.zig");
const source_path = @import("../source/path.zig");
const ignore_match = @import("../source/ignore/match.zig");
const state = @import("../state/root.zig");

pub const Options = struct {
    st: *state.Draft,
    home: []const u8,
    force: bool,
    dry_run: bool,
    /// True when the caller folds a drift-class refusal into its own
    /// generator-scoped report row (the unified classifier's `generated_set`
    /// unit) and so does not want a per-leaf DRIFT line duplicating it.
    /// `false` keeps the per-leaf message (an orphaned generator has no
    /// scopeable row to fold into, so the per-leaf line is the only report).
    mute_drift_message: bool = false,
    /// The released live paths through `stale.foldCase`: such a generator is
    /// forgotten and its files kept.
    released_live: ?*const std.StringHashMap(void) = null,
    /// Live paths the tree plants as symlinks: a leaf below one is never
    /// removed.
    links: ?*const std.StringHashMap(void) = null,
    /// The ignore rules: an orphaned generator's file they match is left
    /// alone, as the stale sweep leaves one.
    ruleset: ?*const ignore_match.RuleSet = null,
    /// The inodes of every path still produced or managed: a dropped file
    /// that is the same file as one of them is forgotten, never removed.
    kept_inodes: ?*const stale.Kept = null,
    /// Live paths still produced or managed: never removed.
    keep: ?*const std.StringHashMap(void) = null,
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
    /// Leaves `.moxignore` matches: left alone, records and all.
    ignored: usize = 0,
};

/// What one apply run knows about generators, for the orphan sweep: every
/// generator it walked (composed, failed or undecided), by live path, and
/// every live path still produced or managed. apply, status and diff build it the same way, so
/// they judge the same orphans.
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
    /// (a head error, a failed compose): its produced set is no orphan.
    pub fn walked(self: *OrphanScan, live: []const u8) !void {
        try self.known.put(live, {});
    }

    /// A generator that failed to compose: walked, and its prior files kept.
    pub fn failed(self: *OrphanScan, st: *const state.Draft, live: []const u8) !void {
        try self.walked(live);
        for (st.produced(live)) |leaf| try self.keep.put(leaf, {});
    }
};

fn samePart(e: state.generation.GeneratorEntry, part: state.Hex) bool {
    return std.mem.eql(u8, &e.part, &part);
}

fn contains(items: []const []const u8, s: []const u8) bool {
    for (items) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

pub const PlannedLeaf = struct { path: []const u8, verdict: removable.Verdict };

/// One orphaned generator: released by a tombstone (its records forgotten,
/// its files kept), or its files as the sweep would judge them.
pub const OrphanGenerator = struct {
    /// The key the generator is kept under.
    key: []const u8,
    released: bool,
    leaves: []const PlannedLeaf,
};

/// Judge one generated file the way `removeLeaf` acts on it.
pub fn judgeLeaf(arena: std.mem.Allocator, io: Io, opts: Options, live_path: []const u8) !removable.Verdict {
    return removable.judge(arena, io, .{
        .home = opts.home,
        .keep = opts.keep,
        .kept = opts.kept_inodes,
        .ruleset = opts.ruleset,
        .links = opts.links,
    }, live_path, .{ .whole = opts.st.read(live_path) });
}

/// Every orphaned generator and what the sweep would do with it: one of this
/// run's part that `scan` does not know. Another part's generator, or one
/// listing a file outside this run's HOME, is never an orphan here.
pub fn planOrphans(arena: std.mem.Allocator, io: Io, opts_in: Options, scan: *const OrphanScan) ![]const OrphanGenerator {
    var opts = opts_in;
    var kept: std.ArrayList([]const u8) = .empty;
    var kit = scan.keep.keyIterator();
    while (kit.next()) |k| try kept.append(arena, k.*);
    const inodes = try arena.create(stale.Kept);
    inodes.* = try stale.inodesOf(arena, io, kept.items);
    opts.kept_inodes = inodes;
    opts.keep = &scan.keep;
    var out: std.ArrayList(OrphanGenerator) = .empty;
    const keys = try sorted(arena, opts.st.gen.generators.keys());
    outer: for (keys) |key| {
        const g = opts.st.gen.generators.get(key).?;
        if (!samePart(g, opts.st.part) or scan.known.contains(key)) continue;
        for (g.produced) |leaf| if (!parent_link.underHome(leaf, opts.home)) continue :outer;
        const released = if (opts.released_live) |rl| rl.contains(try stale.foldCase(arena, key)) else false;
        var planned: std.ArrayList(PlannedLeaf) = .empty;
        for (g.produced) |leaf| {
            if (scan.keep.contains(leaf)) continue;
            try planned.append(arena, .{ .path = leaf, .verdict = if (released) .gone else try judgeLeaf(arena, io, opts, leaf) });
        }
        try out.append(arena, .{ .key = key, .released = released, .leaves = try planned.toOwnedSlice(arena) });
    }
    return out.toOwnedSlice(arena);
}

/// Generators in the order of their live paths.
fn sorted(arena: std.mem.Allocator, keys_in: []const []const u8) ![]const []const u8 {
    const out = try arena.dupe([]const u8, keys_in);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out;
}

/// Act on `plan`: a released generator's files are forgotten and kept, and
/// the generator dropped; every other generator's files are removed as
/// `removeLeaf` decides, an ignored one left alone. A generator is dropped
/// only when nothing of it was refused or left, so the next apply retries.
/// Callers skip this sweep on a scoped apply and in a run where anything
/// failed.
pub fn sweepOrphans(
    arena: std.mem.Allocator,
    io: Io,
    opts: Options,
    plan: []const OrphanGenerator,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !Result {
    var result: Result = .{};
    for (plan) |m| {
        if (m.released) {
            if (!opts.dry_run) {
                for (m.leaves) |leaf| try forgetRecords(opts.st, leaf.path);
                try opts.st.dropGenerator(m.key);
            }
            continue;
        }
        var all_removed = true;
        for (m.leaves) |leaf| {
            const before = result.drift_refused + result.error_refused + result.ignored;
            try actOnLeaf(arena, io, opts, leaf.path, leaf.verdict, stdout, stderr, &result);
            if (result.drift_refused + result.error_refused + result.ignored > before) all_removed = false;
        }
        if (all_removed and !opts.dry_run) try opts.st.dropGenerator(m.key);
    }
    return result;
}

/// The key of the generator of this run's part no longer in the tree
/// (`tree_live` holds every managed live path) that lists `leaf`. Null when
/// none does.
pub fn orphanGeneratorOf(arena: std.mem.Allocator, st: *const state.Draft, tree_live: *const std.StringHashMap(void), leaf: []const u8) !?[]const u8 {
    const all = try orphanGeneratorsOf(arena, st, tree_live, leaf);
    return if (all.len > 0) all[0] else null;
}

/// Every generator `orphanGeneratorOf` would consider that lists `leaf`.
pub fn orphanGeneratorsOf(arena: std.mem.Allocator, st: *const state.Draft, tree_live: *const std.StringHashMap(void), leaf: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const keys = try sorted(arena, st.gen.generators.keys());
    for (keys) |key| {
        if (tree_live.contains(key)) continue;
        const g = st.gen.generators.get(key).?;
        if (!samePart(g, st.part)) continue;
        if (contains(g.produced, leaf)) try out.append(arena, key);
    }
    return out.toOwnedSlice(arena);
}

/// Remove one file of an orphaned generator that a scoped run names, as the
/// orphan sweep would (`opts.force` removes an edited one too), and drop it
/// from its produced set once it is gone.
pub fn removeNamedLeaf(arena: std.mem.Allocator, io: Io, opts: Options, key: []const u8, leaf: []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !Result {
    var result: Result = .{};
    try removeLeaf(arena, io, opts, leaf, stdout, stderr, &result);
    if (result.ignored > 0) {
        try stdout.print("  {s}: matched by .moxignore, left alone\n", .{try tilde(arena, opts.home, leaf)});
        return result;
    }
    if (!opts.dry_run and result.drift_refused + result.error_refused == 0) try opts.st.dropLeaf(key, leaf);
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

/// Remove one generated leaf that is no longer produced, as `judgeLeaf`
/// judges it: snapshot first, and refused rather than deleted when it is
/// unrecoverable, or drifted without `--overwrite`.
fn removeLeaf(
    arena: std.mem.Allocator,
    io: Io,
    opts: Options,
    live_path: []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    result: *Result,
) !void {
    try actOnLeaf(arena, io, opts, live_path, try judgeLeaf(arena, io, opts, live_path), stdout, stderr, result);
}

/// Act on one leaf as `verdict` judged it.
fn actOnLeaf(
    arena: std.mem.Allocator,
    io: Io,
    opts: Options,
    live_path: []const u8,
    verdict: removable.Verdict,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    result: *Result,
) !void {
    const shown = try tilde(arena, opts.home, live_path);
    const found: removable.Found = switch (verdict) {
        .kept, .leave => return,
        .ignored => {
            result.ignored += 1;
            return;
        },
        .same_file, .gone => {
            if (!opts.dry_run) try forgetRecords(opts.st, live_path);
            return;
        },
        .now_dir => {
            if (opts.dry_run) return;
            try forgetRecords(opts.st, live_path);
            try stdout.print("  {s}: now a directory; its record is forgotten\n", .{shown});
            return;
        },
        .linked_parent => {
            if (!opts.dry_run) try forgetRecords(opts.st, live_path);
            try stdout.print("  {s}: {s}\n", .{ shown, parent_link.reason });
            return;
        },
        .refused => |why| {
            result.error_refused += 1;
            try stderr.print("  {s}: generated leaf {s}\n", .{ shown, why });
            return;
        },
        .drift => |d| blk: {
            if (opts.force) break :blk d.found;
            result.drift_refused += 1;
            if (!opts.mute_drift_message)
                try stderr.print("  DRIFT {s} (generated leaf {s}; 'mox commit' or re-run with --overwrite to prune)\n", .{ shown, d.why });
            return;
        },
        .remove => |f| f,
    };
    if (opts.dry_run) {
        result.removed += 1;
        try stdout.print("  would remove {s} (generated, no longer produced)\n", .{shown});
        return;
    }
    switch (found) {
        .link => |target| try finishLeaf(arena, io, opts, live_path, .{ .link = target }, null, stdout, stderr, result),
        // The snapshot keeps the content with secret lines redacted.
        .file => |content| try finishLeaf(arena, io, opts, live_path, .{ .file = content }, content, stdout, stderr, result),
    }
}

/// Remove one leaf through `live_remove`, forgetting its records once gone.
fn finishLeaf(arena: std.mem.Allocator, io: Io, opts: Options, live_path: []const u8, snap: live_remove.Snap, expect: ?[]const u8, stdout: *Io.Writer, stderr: *Io.Writer, result: *Result) !void {
    const shown = try tilde(arena, opts.home, live_path);
    switch (live_remove.remove(arena, io, .{ .home = opts.home, .st = opts.st, .links = opts.links, .expect = expect }, live_path, snap)) {
        .removed => {
            try forgetRecords(opts.st, live_path);
            result.removed += 1;
            try stdout.print("  removed {s} (generated, no longer produced)\n", .{shown});
        },
        .left => |why| {
            try forgetRecords(opts.st, live_path);
            try stdout.print("  {s}: {s}\n", .{ shown, why });
        },
        .failed => |why| {
            result.error_refused += 1;
            try stderr.print("  {s}: generated leaf {s}\n", .{ shown, why });
        },
        .changed => {
            result.error_refused += 1;
            try stderr.print("  CONFLICT {s} (changed underneath mox mid-apply; re-run 'mox apply')\n", .{shown});
        },
    }
}

/// `path` as reports name it, a leading HOME written `~`.
fn tilde(arena: std.mem.Allocator, home: []const u8, path: []const u8) ![]const u8 {
    if (!parent_link.underHome(path, home)) return path;
    return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]});
}

/// Clear every last-applied + provenance record for a pruned leaf.
fn forgetRecords(st: *state.Draft, live_path: []const u8) !void {
    try st.forget(live_path);
    try st.forgetProvenance(live_path);
}
