//! Live-file snapshots.
//!
//! Before apply overwrites a live file, the prior content is copied into a
//! per-run snapshot directory (`<snapshots>/<id>/<path-relative-to-home>`)
//! so `mox rollback <id>` can restore it. Snapshot ids are UTC timestamps,
//! so lexicographic order is chronological order. Rollback deliberately
//! leaves the last-applied records stale: the next apply then sees the
//! restored files as drift and refuses to silently overwrite them again.
//!
//! `saveTree` extends this to a whole live directory (every descendant file,
//! symlink, and directory, recursively) so apply can replace a directory with
//! a managed symlink and still leave it fully recoverable: it captures the
//! tree into memory before writing anything, so a descendant it cannot fully
//! preserve refuses the whole snapshot rather than saving part of it. File
//! content and symlinks restore as ordinary `save`/`saveSymlink` output that
//! `restore` walks back; directory modes and empty directories -- which the
//! mirrored file tree cannot carry -- are recorded in a `.dirmodes` sidecar
//! and reapplied to the captured directories only, so an ancestor the snapshot
//! merely passed through keeps its own mode.

const std = @import("std");

const Io = std.Io;
const parent_link = @import("parent_link.zig");
const applied = @import("applied.zig");
const write_mod = @import("write.zig");
const source_path = @import("../source/path.zig");
const dirent = @import("../source/dirent.zig");
const prov_map = @import("../provenance/root.zig").map;
const build_options = @import("build_options");

pub const id_len = "YYYYMMDDTHHMMSSZ".len;

/// Format an epoch-seconds value as a snapshot id, e.g. `20260710T081500Z`.
pub fn formatId(epoch_secs: u64) [id_len]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = epoch_secs };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    var out: [id_len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

/// The epoch seconds `idNow` gives instead of the real clock, set from
/// `MOX_TEST_CLOCK` in a build made with `-Dtest-clock` and never otherwise.
pub var test_clock: ?u64 = null;
pub const takes_test_clock = build_options.test_clock;

pub fn idNow(io: Io) [id_len]u8 {
    if (build_options.test_clock) if (test_clock) |secs| return formatId(secs);
    const now = Io.Clock.real.now(io).toSeconds();
    return formatId(if (now > 0) @intCast(now) else 0);
}

/// A snapshot id not already present under `snapshots_dir`. The base is the
/// UTC-second timestamp; two applies in the same second would otherwise share a
/// directory and the later one would overwrite the earlier run's only backup of
/// a shared path, so a `-N` suffix disambiguates.
pub fn freshId(arena: std.mem.Allocator, io: Io, snapshots_dir: []const u8) ![]const u8 {
    const base = idNow(io);
    var candidate: []const u8 = try arena.dupe(u8, &base);
    var n: usize = 2;
    while (true) {
        const path = try std.fs.path.join(arena, &.{ snapshots_dir, candidate });
        if (Io.Dir.cwd().openDir(io, path, .{})) |dir_val| {
            var d = dir_val;
            d.close(io);
        } else |_| {
            return candidate; // does not exist yet -> free to use
        }
        candidate = try std.fmt.allocPrint(arena, "{s}-{d}", .{ &base, n });
        n += 1;
    }
}

/// Save the prior content of `live_path` into snapshot `id`, preserving the
/// file's mode. `live_path` must be under `home` (mox only manages files
/// under the home directory).
pub fn save(
    arena: std.mem.Allocator,
    io: Io,
    snapshots_dir: []const u8,
    id: []const u8,
    home: []const u8,
    live_path: []const u8,
    content: []const u8,
) !void {
    const rel = (try source_path.liveKeyUnderHome(arena, home, live_path)) orelse return error.LiveFileOutsideHome;
    const snapshot_root = try std.fs.path.join(arena, &.{ snapshots_dir, id });
    const dest = try source_path.joinKeyOnto(arena, snapshot_root, rel);
    const st = try Io.Dir.cwd().statFile(io, live_path, .{});
    try write_mod.writeAtomic(io, dest, content, write_mod.modeOf(st.permissions));
}

/// Save a live symlink into snapshot `id` as an ACTUAL symlink, so `mox rollback`
/// recreates a link -- not a regular file holding the target text (which is what
/// `save` with the target string would produce, silently changing the entry's
/// type on restore).
pub fn saveSymlink(
    arena: std.mem.Allocator,
    io: Io,
    snapshots_dir: []const u8,
    id: []const u8,
    home: []const u8,
    live_path: []const u8,
    target: []const u8,
) !void {
    const rel = (try source_path.liveKeyUnderHome(arena, home, live_path)) orelse return error.LiveFileOutsideHome;
    const snapshot_root = try std.fs.path.join(arena, &.{ snapshots_dir, id });
    const dest = try source_path.joinKeyOnto(arena, snapshot_root, rel);
    if (std.fs.path.dirname(dest)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    Io.Dir.cwd().deleteFile(io, dest) catch {};
    try Io.Dir.cwd().symLink(io, target, dest, .{});
}

/// Note in snapshot `id` that its symlink for `live_path` is one mox planted,
/// pointing at `target`, so rollback can tell it from a link the user made.
/// The notes live in the `<id>.records` sidecar, one line per link.
pub fn notePlanted(arena: std.mem.Allocator, io: Io, snapshots_dir: []const u8, id: []const u8, live_path: []const u8, target: []const u8, tag: []const u8) !void {
    const path = try recordsPath(arena, snapshots_dir, id);
    const prior = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    const line = try std.fmt.allocPrint(arena, "planted {s} {s} {s}\n", .{ try applied.pctEncode(arena, live_path), try applied.pctEncode(arena, target), try applied.pctEncode(arena, tag) });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.mem.concat(arena, u8, &.{ prior, line }) });
}

/// A link a snapshot notes as planted: its target, and the repo and HOME
/// tag its record named.
pub const Planted = struct { target: []const u8, tag: []const u8 };

/// The links snapshot `id` notes as planted, by live path. A snapshot taken
/// before these notes existed notes none; one whose notes cannot be read
/// is reported through `corrupt` and notes none either.
fn plantedOf(arena: std.mem.Allocator, io: Io, snapshots_dir: []const u8, id: []const u8, corrupt: *bool) !std.StringHashMap(Planted) {
    var out = std.StringHashMap(Planted).init(arena);
    const bytes = Io.Dir.cwd().readFileAlloc(io, try recordsPath(arena, snapshots_dir, id), arena, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return out,
        error.OutOfMemory => return e,
        else => {
            corrupt.* = true;
            return out;
        },
    };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const entry = (try parsePlanted(arena, line)) orelse {
            corrupt.* = true;
            out.clearRetainingCapacity();
            return out;
        };
        try out.put(entry.live, .{ .target = entry.target, .tag = entry.tag });
    }
    return out;
}

fn parsePlanted(arena: std.mem.Allocator, line: []const u8) !?struct { live: []const u8, target: []const u8, tag: []const u8 } {
    var parts = std.mem.splitScalar(u8, line, ' ');
    if (!std.mem.eql(u8, parts.next() orelse return null, "planted")) return null;
    const live = (try applied.pctDecode(arena, parts.next() orelse return null)) orelse return null;
    const target = (try applied.pctDecode(arena, parts.next() orelse return null)) orelse return null;
    const tag = (try applied.pctDecode(arena, parts.next() orelse return null)) orelse return null;
    if (parts.next() != null) return null;
    return .{ .live = live, .target = target, .tag = tag };
}

fn recordsPath(arena: std.mem.Allocator, snapshots_dir: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.records", .{try std.fs.path.join(arena, &.{ snapshots_dir, id })});
}

/// Bound on directory-tree snapshot recursion depth, matching the bound
/// `exact.snapshotTree` uses for the same reason: a pathologically deep tree
/// refuses rather than recursing without limit.
const tree_max_depth: usize = 64;

/// Total live-file bytes a single directory snapshot holds in memory before
/// writing. The whole tree is buffered so a descendant it cannot preserve
/// refuses with an empty store, but that peak must be bounded: a directory
/// larger than this refuses (the live directory is left untouched, so nothing
/// is lost) rather than risking the process to snapshot, e.g., a cache dir.
const tree_max_bytes: usize = 256 * 1024 * 1024;

const TreeFile = struct { live: []const u8, content: []const u8 };
const TreeSymlink = struct { live: []const u8, target: []const u8 };
const TreeDir = struct { live: []const u8, mode: u32 };

/// Collect every regular file, symlink, and directory under `dir_live`
/// (including `dir_live` itself and any empty directory), recursively, into
/// `files`/`symlinks`/`dirs`. `dirs` is filled parent-first with each
/// directory's own mode so the caller can recreate the tree faithfully.
/// Returns `error.Unsnapshottable` -- without partially filling any list's
/// caller-visible use, since `saveTree` only writes after this returns
/// successfully -- the instant it meets a descendant with no recoverable byte
/// representation (a fifo, socket, device, or other special inode), a
/// read/open failure (permission denied, past the depth cap), or a cumulative
/// size past `max_bytes`.
fn captureTree(
    arena: std.mem.Allocator,
    io: Io,
    dir_live: []const u8,
    depth: usize,
    max_bytes: usize,
    total: *usize,
    files: *std.ArrayList(TreeFile),
    symlinks: *std.ArrayList(TreeSymlink),
    dirs: *std.ArrayList(TreeDir),
) !void {
    if (depth >= tree_max_depth) return error.Unsnapshottable;
    var dir = Io.Dir.cwd().openDir(io, dir_live, .{ .iterate = true, .follow_symlinks = false }) catch return error.Unsnapshottable;
    defer dir.close(io);

    try dirs.append(arena, .{ .live = dir_live, .mode = write_mod.modeOf((try dir.stat(io)).permissions) });

    for (try dirent.sorted(arena, io, dir)) |e| {
        const child = try std.fs.path.join(arena, &.{ dir_live, e.name });
        switch (e.kind) {
            .file => {
                const content = Io.Dir.cwd().readFileAlloc(io, child, arena, .limited(64 * 1024 * 1024)) catch return error.Unsnapshottable;
                total.* += content.len;
                if (total.* > max_bytes) return error.Unsnapshottable;
                try files.append(arena, .{ .live = child, .content = content });
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = Io.Dir.cwd().readLink(io, child, &buf) catch return error.Unsnapshottable;
                try symlinks.append(arena, .{ .live = child, .target = try arena.dupe(u8, buf[0..n]) });
            },
            .directory => try captureTree(arena, io, child, depth + 1, max_bytes, total, files, symlinks, dirs),
            // A fifo, socket, device, or other special inode carries no
            // recoverable byte content: refuse the whole tree rather than
            // silently dropping it, since the caller is about to delete the
            // directory this snapshot is the only copy of.
            else => return error.Unsnapshottable,
        }
    }
}

/// The sidecar recording a directory snapshot's captured directories and
/// their modes, at `<snapshots_dir>/<id>.dirmodes`. It lives beside the `<id>`
/// store rather than inside it for two reasons: a directory's mode and an
/// empty directory cannot be read back from the mirrored file/symlink tree,
/// and a store directory carrying its live mode would (a) block prune's
/// `deleteTree` on a non-writable directory and (b) leave restore unable to
/// tell a captured directory from an implicit ancestor it must not chmod. The
/// sidecar names exactly the captured set, so restore recreates their modes
/// and empty directories without ever touching an ancestor like `~/.config`.
/// A file, not a directory, so `list` (directories only) never mistakes it
/// for a snapshot id.
fn dirmodesPath(arena: std.mem.Allocator, snapshots_dir: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.dirmodes", .{try std.fs.path.join(arena, &.{ snapshots_dir, id })});
}

/// Snapshot every descendant of live directory `dir_live` -- every regular
/// file's content, every symlink's target, and every directory's mode
/// (including empty directories and `dir_live` itself), recursively -- into
/// snapshot `id`, so `mox rollback` can reconstruct the tree. The tree is
/// captured into memory before anything is written: a descendant that cannot
/// be fully preserved makes `error.Unsnapshottable` propagate with nothing
/// written to the snapshot store, so the caller can delete the live directory
/// only once this returns successfully. File content and symlinks go into the
/// mirrored `<id>` store; directory modes go into the `.dirmodes` sidecar.
pub fn saveTree(
    arena: std.mem.Allocator,
    io: Io,
    snapshots_dir: []const u8,
    id: []const u8,
    home: []const u8,
    dir_live: []const u8,
) !void {
    var files: std.ArrayList(TreeFile) = .empty;
    var symlinks: std.ArrayList(TreeSymlink) = .empty;
    var dirs: std.ArrayList(TreeDir) = .empty;
    var total: usize = 0;
    try captureTree(arena, io, dir_live, 0, tree_max_bytes, &total, &files, &symlinks, &dirs);

    for (files.items) |f| try save(arena, io, snapshots_dir, id, home, f.live, f.content);
    for (symlinks.items) |s| try saveSymlink(arena, io, snapshots_dir, id, home, s.live, s.target);

    var manifest: std.ArrayList(u8) = .empty;
    for (dirs.items) |d| {
        const rel = (try source_path.liveKeyUnderHome(arena, home, d.live)) orelse return error.LiveFileOutsideHome;
        try manifest.appendSlice(arena, try std.fmt.allocPrint(arena, "{o} {s}\n", .{ d.mode, rel }));
    }
    const dest = try dirmodesPath(arena, snapshots_dir, id);
    if (std.fs.path.dirname(dest)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    // One run may save several trees into one snapshot: each adds its own.
    const prior = Io.Dir.cwd().readFileAlloc(io, dest, arena, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = try std.mem.concat(arena, u8, &.{ prior, manifest.items }) });
}

/// List snapshot ids, oldest first.
pub fn list(arena: std.mem.Allocator, io: Io, snapshots_dir: []const u8) ![]const []const u8 {
    var dir = Io.Dir.cwd().openDir(io, snapshots_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer dir.close(io);

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(arena);

    for (try dirent.sorted(arena, io, dir)) |entry| {
        if (entry.kind != .directory) continue;
        try ids.append(arena, entry.name);
    }
    // Oldest first, a same-second `-N` suffix by its number: the order
    // prune drops by and `rollback` takes the newest from.
    std.mem.sort([]const u8, ids.items, {}, olderId);
    return ids.toOwnedSlice(arena);
}

fn olderId(_: void, a: []const u8, b: []const u8) bool {
    const sa = splitId(a);
    const sb = splitId(b);
    const o = std.mem.order(u8, sa.base, sb.base);
    if (o != .eq) return o == .lt;
    if (sa.n != sb.n) return sa.n < sb.n;
    return std.mem.lessThan(u8, a, b);
}

fn splitId(id: []const u8) struct { base: []const u8, n: u64 } {
    if (id.len > id_len and id[id_len] == '-') {
        if (std.fmt.parseInt(u64, id[id_len + 1 ..], 10)) |n| return .{ .base = id[0..id_len], .n = n } else |_| {}
    }
    return .{ .base = id, .n = 1 };
}

/// Delete the oldest snapshots so at most `keep` remain. A snapshot a
/// rollback took of what it replaced does not count, and goes when the
/// chain of snapshots it undoes ends at one pruned here.
pub fn prune(arena: std.mem.Allocator, io: Io, snapshots_dir: []const u8, keep: usize) !void {
    var own: std.ArrayList([]const u8) = .empty;
    var undos: std.ArrayList(struct { id: []const u8, of: []const u8 }) = .empty;
    for (try list(arena, io, snapshots_dir)) |id| switch (try undoNote(arena, io, snapshots_dir, id)) {
        .of => |of| try undos.append(arena, .{ .id = id, .of = of }),
        .none, .corrupt => try own.append(arena, id),
    };
    var drop: std.ArrayList([]const u8) = .empty;
    if (own.items.len > keep) try drop.appendSlice(arena, own.items[0 .. own.items.len - keep]);
    var dropped = std.StringHashMap(void).init(arena);
    for (drop.items) |d| try dropped.put(d, {});
    var undo_of = std.StringHashMap([]const u8).init(arena);
    for (undos.items) |u| try undo_of.put(u.id, u.of);
    // An undo goes only when the chain of snapshots it undoes ends at one
    // pruned now. A link that is missing, or a chain that loops, keeps it.
    for (undos.items) |u| {
        var at = u.of;
        var steps: usize = 0;
        const goes = while (steps <= undos.items.len) : (steps += 1) {
            if (dropped.contains(at)) break true;
            at = undo_of.get(at) orelse break false;
        } else false;
        if (goes) try drop.append(arena, u.id);
    }
    if (drop.items.len == 0) return;

    var dir = try Io.Dir.cwd().openDir(io, snapshots_dir, .{ .iterate = true });
    defer dir.close(io);
    for (drop.items) |id| {
        try dir.deleteTree(io, id);
        // Drop the directory-mode sidecar beside the store it described.
        dir.deleteFile(io, try std.fmt.allocPrint(arena, "{s}.dirmodes", .{id})) catch {};
        dir.deleteFile(io, try std.fmt.allocPrint(arena, "{s}.records", .{id})) catch {};
        dir.deleteFile(io, try std.fmt.allocPrint(arena, "{s}.undo", .{id})) catch {};
    }
}

pub const Restored = struct {
    count: usize = 0,
    /// Problems with the snapshot's own notes, which never stop a restore.
    warnings: []const []const u8 = &.{},
    /// Entries not restored because a directory above their live path is a
    /// symlink: each names its live path and the snapshot copy left behind.
    refused: []const Refused = &.{},
};

pub const Refused = struct {
    live_path: []const u8,
    snapshot_path: []const u8,
    why: Why,
    /// For `failed`: what went wrong.
    reason: []const u8 = "",

    pub const Why = enum {
        /// A directory above the live path is a symlink.
        parent_link,
        /// The live path itself is a symlink a restore would destroy.
        is_link,
        /// A symlink sits where the snapshot has a directory.
        dir_over_link,
        /// Restoring it failed; `reason` says how.
        failed,
        /// The snapshot holds a secret line redacted: writing it would put
        /// the placeholder in the live file.
        redacted,
    };
};

fn refusal(io: Io, home: []const u8, live: []const u8) ?Refused.Why {
    if (parent_link.through(io, home, live, null)) return .parent_link;
    if (isSymlink(io, live)) return .is_link;
    return null;
}

/// `refusal` for a file or symlink entry: a live symlink mox planted (its
/// target is the one `state_dir`'s symlink record holds) is replaced, as
/// rollback replaces any other file mox wrote.
fn entryRefusal(arena: std.mem.Allocator, io: Io, home: []const u8, live: []const u8, state_dir: ?[]const u8) !?Refused.Why {
    const why = refusal(io, home, live) orelse return null;
    if (why != .is_link) return why;
    const sd = state_dir orelse return why;
    // A link mox planted counts as planted whether or not rollback put it
    // back since.
    const recorded = (applied.readSymlinkRecord(arena, io, sd, live) catch return why) orelse return why;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().readLink(io, live, &buf) catch return why;
    return if (applied.sameSymlinkTarget(buf[0..n], recorded.target)) null else why;
}

/// The records rollback keeps in step with what it restores.
pub const Records = struct {
    state_dir: []const u8,
    /// The repo a restored link's record names.
    repo: []const u8,
    /// Where an entry the restore replaces is kept first.
    undo: ?*Undo = null,
    /// The links the snapshot notes as planted; `restoreExcept` reads them.
    planted: ?*const std.StringHashMap(Planted) = null,
};

/// The snapshot a rollback keeps the entries it replaces in, taken on the
/// first one. It names the snapshot it undoes in its `<id>.undo` sidecar,
/// and `rollback` with no id never picks it.
pub const Undo = struct {
    snapshots_dir: []const u8,
    /// The snapshot being rolled back.
    of: []const u8,
    id: ?[]const u8 = null,

    pub fn take(u: *Undo, arena: std.mem.Allocator, io: Io) ![]const u8 {
        if (u.id) |id| return id;
        const id = try freshId(arena, io, u.snapshots_dir);
        try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ u.snapshots_dir, id }));
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try undoPath(arena, u.snapshots_dir, id), .data = try std.fmt.allocPrint(arena, "{s}\n", .{u.of}) });
        u.id = id;
        return id;
    }
};

fn undoPath(arena: std.mem.Allocator, snapshots_dir: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.undo", .{try std.fs.path.join(arena, &.{ snapshots_dir, id })});
}

/// What snapshot `id`'s `<id>.undo` sidecar says: none, the snapshot it
/// undoes, or that it cannot be read (the caller warns and treats it as
/// none).
pub const UndoNote = union(enum) { none, of: []const u8, corrupt };

pub fn undoNote(arena: std.mem.Allocator, io: Io, snapshots_dir: []const u8, id: []const u8) !UndoNote {
    const bytes = Io.Dir.cwd().readFileAlloc(io, try undoPath(arena, snapshots_dir, id), arena, .limited(4096)) catch |e| switch (e) {
        error.FileNotFound => return .none,
        error.OutOfMemory => return e,
        else => return .corrupt,
    };
    const of = std.mem.trim(u8, bytes, " \n");
    if (of.len < id_len or of.len > id_len + 8) return .corrupt;
    for (of) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return .corrupt;
    return .{ .of = of };
}

/// Keep `bytes`, what a partial re-patch is about to replace at `live`, in
/// rollback's own snapshot `u`; the caller has masked its secret values.
pub fn keepBytes(arena: std.mem.Allocator, io: Io, u: *Undo, home: []const u8, live: []const u8, bytes: []const u8) !void {
    try save(arena, io, u.snapshots_dir, try u.take(arena, io), home, live, bytes);
}

/// Keep what is at `live` in the rollback's own snapshot before the restore
/// replaces it with `incoming` (null for a link). Nothing is kept when the
/// path is absent, a directory, or already holds exactly what comes in.
fn keepReplaced(arena: std.mem.Allocator, io: Io, r: Records, home: []const u8, live: []const u8, incoming: ?[]const u8) !void {
    const u = r.undo orelse return;
    switch (applied.inspectSymSite(io, arena, live)) {
        .absent, .directory => {},
        .symlink => |target| {
            const id = try u.take(arena, io);
            try saveSymlink(arena, io, u.snapshots_dir, id, home, live, target);
            if (try applied.readSymlinkRecord(arena, io, r.state_dir, live)) |rec| {
                if (applied.sameSymlinkTarget(rec.target, target)) try notePlanted(arena, io, u.snapshots_dir, id, live, target, rec.repo orelse "");
            }
        },
        .other => {
            if (write_mod.guardLiveRead(io, live) == .special) return;
            const bytes = try Io.Dir.cwd().readFileAlloc(io, live, arena, .limited(64 * 1024 * 1024));
            if (incoming) |in| if (std.mem.eql(u8, in, bytes)) return;
            const prior = try prov_map.read(arena, io, r.state_dir, live);
            const kept = if (prior) |m| try prov_map.redactSecretLines(arena, bytes, m.segments) else bytes;
            try save(arena, io, u.snapshots_dir, try u.take(arena, io), home, live, kept);
        },
    }
}

/// A snapshot file whose live path the caller asked to withhold from the
/// whole-file restore, with the snapshot's content for its own handling.
pub const Withheld = struct {
    live_path: []const u8,
    content: []const u8,
};

/// Restore every file in snapshot `id` to its live path under `home`,
/// preserving each snapshot file's mode. Returns how many files were
/// restored; `error.SnapshotNotFound` when the id does not exist.
pub fn restore(
    arena: std.mem.Allocator,
    io: Io,
    snapshots_dir: []const u8,
    id: []const u8,
    home: []const u8,
) !Restored {
    return restoreExcept(arena, io, snapshots_dir, id, home, null, null, null);
}

/// `restore`, withholding every live path in `skip` from the whole-file
/// write. A withheld file's snapshot content is collected into `skipped`
/// instead; the caller decides what to do with it (rollback re-patches a
/// partial target's owned subtree rather than clobbering the remainder).
/// With `records`, a live symlink mox planted is replaced like any file mox
/// wrote, any other symlink at a live path is refused, and the records are
/// left matching what was restored: a restored symlink is a link mox planted,
/// a restored file no longer one.
pub fn restoreExcept(
    arena: std.mem.Allocator,
    io: Io,
    snapshots_dir: []const u8,
    id: []const u8,
    home: []const u8,
    skip: ?*const std.StringHashMap(void),
    skipped: ?*std.ArrayList(Withheld),
    records: ?Records,
) !Restored {
    const snap_dir_path = try std.fs.path.join(arena, &.{ snapshots_dir, id });
    var dir = Io.Dir.cwd().openDir(io, snap_dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return error.SnapshotNotFound,
        else => return e,
    };
    defer dir.close(io);

    var result: Restored = .{};
    var refused: std.ArrayList(Refused) = .empty;
    var book = records;
    var warnings: std.ArrayList([]const u8) = .empty;
    if (book) |*b| {
        var corrupt = false;
        const planted = try arena.create(std.StringHashMap(Planted));
        planted.* = try plantedOf(arena, io, snapshots_dir, id, &corrupt);
        if (corrupt) try warnings.append(arena, try std.fmt.allocPrint(arena, "the planted-link notes of snapshot {s} cannot be read; its links restore with no record", .{id}));
        b.planted = planted;
    }
    try restoreDir(arena, io, dir, snap_dir_path, "", home, skip, skipped, &result, &refused, book);
    result.warnings = try warnings.toOwnedSlice(arena);
    try restoreDirModes(arena, io, snapshots_dir, id, home, &refused);
    result.refused = try refused.toOwnedSlice(arena);
    return result;
}

/// Recreate every captured directory the `.dirmodes` sidecar records, with its
/// mode. Runs after the file/symlink walk so restrictive modes land last:
/// create the directories parent-first (while still writable), then set their
/// modes deepest-first, so a directory going owner-read-only never blocks
/// writing or chmodding what is nested inside it. Absent sidecar (a single-file
/// snapshot, or one written before directory snapshots existed) is a no-op.
fn restoreDirModes(
    arena: std.mem.Allocator,
    io: Io,
    snapshots_dir: []const u8,
    id: []const u8,
    home: []const u8,
    refused: *std.ArrayList(Refused),
) !void {
    const manifest_path = try dirmodesPath(arena, snapshots_dir, id);
    const data = Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };

    const Entry = struct { live: []const u8, mode: u32 };
    var entries: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.CorruptDirmodes;
        const mode = std.fmt.parseInt(u32, line[0..sp], 8) catch return error.CorruptDirmodes;
        const live = try source_path.joinKeyOnto(arena, home, line[sp + 1 ..]);
        if (refusal(io, home, live)) |why| {
            try refused.append(arena, .{ .live_path = live, .snapshot_path = try std.fs.path.join(arena, &.{ snapshots_dir, id, line[sp + 1 ..] }), .why = if (why == .is_link) .dir_over_link else why });
            continue;
        }
        try entries.append(arena, .{ .live = live, .mode = mode });
    }

    for (entries.items) |e| try Io.Dir.cwd().createDirPath(io, e.live);
    var i = entries.items.len;
    while (i > 0) {
        i -= 1;
        try write_mod.setMode(entries.items[i].live, entries.items[i].mode);
    }
}

fn isSymlink(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

fn restoreDir(
    arena: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    abs_prefix: []const u8,
    rel_prefix: []const u8,
    home: []const u8,
    skip: ?*const std.StringHashMap(void),
    skipped: ?*std.ArrayList(Withheld),
    result: *Restored,
    refused: *std.ArrayList(Refused),
    records: ?Records,
) !void {
    // Raw iterate() is sound here: a restore replays EVERY entry to disk, so
    // the order it visits them cannot be observed in the result.
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const rel = if (rel_prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fs.path.join(arena, &.{ rel_prefix, entry.name });

        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                const sub_abs = try std.fs.path.join(arena, &.{ abs_prefix, entry.name });
                try restoreDir(arena, io, sub, sub_abs, rel, home, skip, skipped, result, refused, records);
            },
            .file, .sym_link => {
                const target = try source_path.joinKeyOnto(arena, home, rel);
                const done = if (entry.kind == .file)
                    restoreFileEntry(arena, io, dir, entry.name, abs_prefix, target, home, skip, skipped, result, refused, records)
                else
                    restoreLinkEntry(arena, io, dir, entry.name, abs_prefix, target, home, result, refused, records);
                done catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => try refused.append(arena, .{ .live_path = target, .snapshot_path = try std.fs.path.join(arena, &.{ abs_prefix, entry.name }), .why = .failed, .reason = @errorName(e) }),
                };
            },
            else => {},
        }
    }
}

fn restoreFileEntry(
    arena: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    abs_prefix: []const u8,
    target: []const u8,
    home: []const u8,
    skip: ?*const std.StringHashMap(void),
    skipped: ?*std.ArrayList(Withheld),
    result: *Restored,
    refused: *std.ArrayList(Refused),
    records: ?Records,
) !void {
    const state_dir: ?[]const u8 = if (records) |r| r.state_dir else null;
    // A withheld partial target is re-patched by the caller, through a link
    // the user made; only a symlinked parent stops it here.
    const withheld = skip != null and skip.?.contains(target);
    const why_opt: ?Refused.Why = if (withheld)
        (if (parent_link.through(io, home, target, null)) Refused.Why.parent_link else null)
    else
        try entryRefusal(arena, io, home, target, state_dir);
    if (why_opt) |why| {
        try refused.append(arena, .{ .live_path = target, .snapshot_path = try std.fs.path.join(arena, &.{ abs_prefix, name }), .why = why });
        return;
    }
    const content = try dir.readFileAlloc(io, name, arena, .limited(64 * 1024 * 1024));
    if (!withheld and std.mem.indexOf(u8, content, prov_map.secret_redaction) != null) {
        try refused.append(arena, .{ .live_path = target, .snapshot_path = try std.fs.path.join(arena, &.{ abs_prefix, name }), .why = .redacted });
        return;
    }
    if (withheld) {
        if (skipped) |out| try out.append(arena, .{ .live_path = target, .content = content });
        return;
    }
    const st = try dir.statFile(io, name, .{});
    if (records) |r| try keepReplaced(arena, io, r, home, target, content);
    try write_mod.writeAtomic(io, target, content, write_mod.modeOf(st.permissions));
    if (records) |r| try applied.forgetSymlink(arena, io, r.state_dir, target);
    result.count += 1;
}

fn restoreLinkEntry(
    arena: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    abs_prefix: []const u8,
    target: []const u8,
    home: []const u8,
    result: *Restored,
    refused: *std.ArrayList(Refused),
    records: ?Records,
) !void {
    const state_dir: ?[]const u8 = if (records) |r| r.state_dir else null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.readLink(io, name, &buf);
    // The link is already there: nothing is restored, records and all.
    switch (applied.inspectSymSite(io, arena, target)) {
        .symlink => |cur| if (applied.sameSymlinkTarget(cur, buf[0..n])) return,
        else => {},
    }
    if (try entryRefusal(arena, io, home, target, state_dir)) |why| {
        try refused.append(arena, .{ .live_path = target, .snapshot_path = try std.fs.path.join(arena, &.{ abs_prefix, name }), .why = why });
        return;
    }
    if (std.fs.path.dirname(target)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    if (records) |r| try keepReplaced(arena, io, r, home, target, null);
    switch (applied.inspectSymSite(io, arena, target)) {
        .absent => {},
        else => try Io.Dir.cwd().deleteFile(io, target),
    }
    try Io.Dir.cwd().symLink(io, buf[0..n], target, .{});
    // A link the snapshot notes as planted is recorded as rolled back, with
    // the tag its record named: drift until applied again. Any other link is
    // left with no record, as a link the user made reads.
    if (records) |r| {
        const was = if (r.planted) |p| p.get(target) else null;
        if (was != null and applied.sameSymlinkTarget(was.?.target, buf[0..n])) {
            try applied.recordRolledBackLink(arena, io, r.state_dir, target, buf[0..n], was.?.tag);
        } else try applied.forget(arena, io, r.state_dir, target);
    }
    result.count += 1;
}

test "saveSymlink + restore round-trips a symlink, not a regular file" {
    if (!Io.File.Permissions.has_executable_bit) return; // symlink create is privileged on Windows
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
    const link = try std.fs.path.join(a, &.{ home, ".config", "link" });
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(link).?);

    try saveSymlink(a, io, snaps, "id1", home, link, "../actual/target");
    const res = try restore(a, io, snaps, "id1", home);
    try std.testing.expectEqual(@as(usize, 1), res.count);

    const st = try Io.Dir.cwd().statFile(io, link, .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.sym_link, st.kind);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.cwd().readLink(io, link, &buf);
    try std.testing.expectEqualStrings("../actual/target", buf[0..n]);
}

fn failingReadLinkFor(target: []const u8) type {
    return struct {
        fn dirReadLink(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, buffer: []u8) Io.Dir.ReadLinkError!usize {
            _ = userdata;
            _ = dir;
            _ = buffer;
            if (std.mem.eql(u8, sub_path, target)) return error.Unexpected;
            unreachable; // this fixture snapshots exactly one entry
        }
    };
}

test "restore: a symlink whose readLink fails is that entry's failure, never skipped in silence" {
    if (!Io.File.Permissions.has_executable_bit) return; // symlink create is privileged on Windows
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
    const link = try std.fs.path.join(a, &.{ home, ".config", "link" });
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(link).?);

    try saveSymlink(a, io, snaps, "id1", home, link, "../actual/target");

    var vtable = io.vtable.*;
    vtable.dirReadLink = failingReadLinkFor("link").dirReadLink;
    const faulty: Io = .{ .userdata = io.userdata, .vtable = &vtable };

    // Reported as that entry's failure, never skipped in silence.
    const res = try restore(a, faulty, snaps, "id1", home);
    try std.testing.expectEqual(@as(usize, 1), res.refused.len);
    try std.testing.expect(res.refused[0].why == .failed);
    try std.testing.expectEqualStrings("Unexpected", res.refused[0].reason);
}

var stat_fail_target: []const u8 = "";

fn failingStatFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, opts: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
    if (std.mem.eql(u8, sub_path, stat_fail_target)) return error.Unexpected;
    return std.testing.io.vtable.dirStatFile(userdata, dir, sub_path, opts);
}

test "save: a live-file stat failure propagates instead of degrading the preserved mode to 0644" {
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
    const live = try std.fs.path.join(a, &.{ home, ".secretrc" });
    try write_mod.writeAtomic(io, live, "token\n", 0o600);

    stat_fail_target = live;
    var vtable = io.vtable.*;
    vtable.dirStatFile = failingStatFile;
    const faulty: Io = .{ .userdata = io.userdata, .vtable = &vtable };

    try std.testing.expectError(error.Unexpected, save(a, faulty, snaps, "id1", home, live, "token\n"));
}

test "restore: a snapshot entry's stat failure is that entry's failure, never a restore at 0644" {
    if (!Io.File.Permissions.has_executable_bit) return; // no unix modes to preserve
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
    const live = try std.fs.path.join(a, &.{ home, ".secretrc" });
    try write_mod.writeAtomic(io, live, "token\n", 0o600);
    try save(a, io, snaps, "id1", home, live, "token\n");

    stat_fail_target = ".secretrc";
    var vtable = io.vtable.*;
    vtable.dirStatFile = failingStatFile;
    const faulty: Io = .{ .userdata = io.userdata, .vtable = &vtable };

    // Reported as that entry's failure, never skipped in silence.
    const res = try restore(a, faulty, snaps, "id1", home);
    try std.testing.expectEqual(@as(usize, 1), res.refused.len);
    try std.testing.expect(res.refused[0].why == .failed);
    try std.testing.expectEqualStrings("Unexpected", res.refused[0].reason);
}

fn dirMode(io: Io, path: []const u8) !u32 {
    var d = try Io.Dir.cwd().openDir(io, path, .{});
    defer d.close(io);
    return write_mod.modeOf((try d.stat(io)).permissions);
}

test "saveTree + restore round-trips directory modes and empty subdirs, leaving ancestors untouched" {
    if (!Io.File.Permissions.has_executable_bit) return; // no unix modes to preserve
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

    // An ancestor mox never captured (its mode must survive a rollback), then
    // the captured subtree: a private root, a nested dir with a file, and an
    // empty directory.
    const ancestor = try std.fs.path.join(a, &.{ home, ".config" });
    const root = try std.fs.path.join(a, &.{ ancestor, "app" });
    const nested = try std.fs.path.join(a, &.{ root, "sub" });
    const empty = try std.fs.path.join(a, &.{ root, "hole" });
    try Io.Dir.cwd().createDirPath(io, nested);
    try Io.Dir.cwd().createDirPath(io, empty);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ root, "secret" }), "s\n", 0o600);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ nested, "f" }), "x\n", 0o644);
    try write_mod.setMode(ancestor, 0o701);
    try write_mod.setMode(root, 0o700);
    try write_mod.setMode(nested, 0o750);
    try write_mod.setMode(empty, 0o700);

    try saveTree(a, io, snaps, "id1", home, root);

    // The replace: the live subtree is gone, the ancestor stays.
    try Io.Dir.cwd().deleteTree(io, root);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, root, .{}));

    const res = try restore(a, io, snaps, "id1", home);
    try std.testing.expect(res.count >= 2); // the two files

    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(io, root));
    try std.testing.expectEqual(@as(u32, 0o750), try dirMode(io, nested));
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(io, empty)); // empty dir recreated
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast((try Io.Dir.cwd().statFile(io, try std.fs.path.join(a, &.{ root, "secret" }), .{})).permissions.toMode() & 0o777)));
    // The ancestor mox never captured is left exactly as it was.
    try std.testing.expectEqual(@as(u32, 0o701), try dirMode(io, ancestor));
}

test "saveTree: a second tree in one snapshot keeps the first tree's directory modes" {
    if (!Io.File.Permissions.has_executable_bit) return; // no unix modes to preserve
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
    const one = try std.fs.path.join(a, &.{ home, "one" });
    const two = try std.fs.path.join(a, &.{ home, "two" });
    try Io.Dir.cwd().createDirPath(io, one);
    try Io.Dir.cwd().createDirPath(io, two);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ one, "f" }), "1\n", 0o644);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ two, "f" }), "2\n", 0o644);
    try write_mod.setMode(one, 0o700);
    try write_mod.setMode(two, 0o750);

    try saveTree(a, io, snaps, "id1", home, one);
    try saveTree(a, io, snaps, "id1", home, two);
    try Io.Dir.cwd().deleteTree(io, one);
    try Io.Dir.cwd().deleteTree(io, two);

    _ = try restore(a, io, snaps, "id1", home);
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(io, one));
    try std.testing.expectEqual(@as(u32, 0o750), try dirMode(io, two));
}

test "prune: drops a snapshot's directory-mode sidecar alongside its store" {
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
    const live = try std.fs.path.join(a, &.{ home, ".config", "app" });
    try Io.Dir.cwd().createDirPath(io, live);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ live, "f" }), "x\n", 0o644);

    try saveTree(a, io, snaps, "20260101T000000Z", home, live);
    try saveTree(a, io, snaps, "20260101T000001Z", home, live);

    const old_sidecar = try dirmodesPath(a, snaps, "20260101T000000Z");
    try std.testing.expect((Io.Dir.cwd().statFile(io, old_sidecar, .{}) catch null) != null);

    try prune(a, io, snaps, 1);

    // The older snapshot's store AND its sidecar are gone; the newer pair stays.
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, old_sidecar, .{}));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, try std.fs.path.join(a, &.{ snaps, "20260101T000000Z" }), .{}));
    try std.testing.expect((Io.Dir.cwd().statFile(io, try dirmodesPath(a, snaps, "20260101T000001Z"), .{}) catch null) != null);
}

test "captureTree: a tree past the depth cap refuses instead of recursing without limit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    var deep = try std.fs.path.join(a, &.{ base, "deep" });
    for (0..tree_max_depth + 4) |_| deep = try std.fs.path.join(a, &.{ deep, "d" });
    try Io.Dir.cwd().createDirPath(io, deep);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ deep, "leaf" }), "x\n", 0o644);

    var files: std.ArrayList(TreeFile) = .empty;
    var symlinks: std.ArrayList(TreeSymlink) = .empty;
    var dirs: std.ArrayList(TreeDir) = .empty;
    var total: usize = 0;
    const root = try std.fs.path.join(a, &.{ base, "deep" });
    try std.testing.expectError(
        error.Unsnapshottable,
        captureTree(a, io, root, 0, tree_max_bytes, &total, &files, &symlinks, &dirs),
    );
}

test "captureTree: a tree past the byte cap refuses so a huge directory cannot exhaust memory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const root = try std.fs.path.join(a, &.{ base, "big" });
    try Io.Dir.cwd().createDirPath(io, root);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ root, "a" }), "0123456789", 0o644);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ root, "b" }), "0123456789", 0o644);

    var files: std.ArrayList(TreeFile) = .empty;
    var symlinks: std.ArrayList(TreeSymlink) = .empty;
    var dirs: std.ArrayList(TreeDir) = .empty;
    var total: usize = 0;
    try std.testing.expectError(
        error.Unsnapshottable,
        captureTree(a, io, root, 0, 15, &total, &files, &symlinks, &dirs),
    );
}

test "formatId renders a known epoch" {
    // 2026-07-10 08:15:00 UTC
    const id = formatId(1783671300);
    try std.testing.expectEqualStrings("20260710T081500Z", &id);
}

test "liveKeyUnderHome: the key a snapshot is filed by, and null for a path outside home" {
    const a = std.testing.allocator;
    const one = (try source_path.liveKeyUnderHome(a, "/home/me", "/home/me/.zshrc")).?;
    defer a.free(one);
    try std.testing.expectEqualStrings(".zshrc", one);

    const two = (try source_path.liveKeyUnderHome(a, "/home/me/", "/home/me/.config/git/config")).?;
    defer a.free(two);
    try std.testing.expectEqualStrings(".config/git/config", two);

    try std.testing.expect((try source_path.liveKeyUnderHome(a, "/home/me", "/etc/passwd")) == null);
    try std.testing.expect((try source_path.liveKeyUnderHome(a, "/home/me", "/home/melon/.zshrc")) == null);
}

test "list: a same-second suffix orders by number, and prune keeps rollback's own snapshots out of the count" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "20260101T000000Z", "20260101T000000Z-2", "20260101T000000Z-10", "20260101T000001Z" }) |id| try tmp.dir.createDirPath(io, id);
    const snaps = try tmp.dir.realPathFileAlloc(io, ".", a);
    const ids = try list(a, io, snaps);
    try std.testing.expectEqualStrings("20260101T000000Z-2", ids[1]);
    try std.testing.expectEqualStrings("20260101T000000Z-10", ids[2]);

    // The newest snapshot undoes the one before it: it does not count.
    try tmp.dir.writeFile(io, .{ .sub_path = "20260101T000001Z.undo", .data = "20260101T000000Z-10\n" });
    try prune(a, io, snaps, 1);
    const left = try list(a, io, snaps);
    try std.testing.expectEqual(@as(usize, 2), left.len);
    try std.testing.expectEqualStrings("20260101T000000Z-10", left[0]);
}

test "restore: a planted link is recorded with the tag its snapshot noted, and a corrupt note is a warning" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "state");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const home = try std.fs.path.join(a, &.{ root, "home" });
    const snaps = try std.fs.path.join(a, &.{ root, "snaps" });
    const state = try std.fs.path.join(a, &.{ root, "state" });
    const link = try std.fs.path.join(a, &.{ home, "l" });

    try saveSymlink(a, io, snaps, "id1", home, link, "/t");
    try notePlanted(a, io, snaps, "id1", link, "/t", "repo-then");
    const res = try restoreExcept(a, io, snaps, "id1", home, null, null, .{ .state_dir = state, .repo = "repo-now" });
    try std.testing.expectEqual(@as(usize, 1), res.count);
    const rec = (try applied.readSymlinkRecord(a, io, state, link)).?;
    try std.testing.expect(rec.rolled_back);
    try std.testing.expectEqualStrings("repo-then", rec.repo.?);

    try Io.Dir.cwd().deleteFile(io, link);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try recordsPath(a, snaps, "id1"), .data = "planted %zz\n" });
    const bad = try restoreExcept(a, io, snaps, "id1", home, null, null, .{ .state_dir = state, .repo = "repo-now" });
    try std.testing.expectEqual(@as(usize, 1), bad.count);
    try std.testing.expect(bad.warnings.len == 1);
    try std.testing.expect((try applied.readSymlinkRecord(a, io, state, link)) == null);
}

test "prune: an undo of an undo is kept while its chain reaches a kept snapshot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "20260101T000000Z", "20260101T000001Z", "20260101T000002Z", "20260101T000003Z", "20260101T000004Z" }) |id| try tmp.dir.createDirPath(io, id);
    // 01 undoes 00; 02 undoes 01; 04 undoes a snapshot that is gone; 03 is
    // the snapshot kept.
    try tmp.dir.writeFile(io, .{ .sub_path = "20260101T000001Z.undo", .data = "20260101T000000Z\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "20260101T000002Z.undo", .data = "20260101T000001Z\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "20260101T000004Z.undo", .data = "20250101T000000Z\n" });
    const snaps = try tmp.dir.realPathFileAlloc(io, ".", a);
    try prune(a, io, snaps, 2);
    const left = try list(a, io, snaps);
    try std.testing.expectEqual(@as(usize, 5), left.len);
    // Keep only one own snapshot: 00 goes, and the chain 01 <- 02 with it.
    try prune(a, io, snaps, 1);
    const after = try list(a, io, snaps);
    try std.testing.expectEqual(@as(usize, 2), after.len);
    try std.testing.expectEqualStrings("20260101T000003Z", after[0]);
    try std.testing.expectEqualStrings("20260101T000004Z", after[1]);
}
