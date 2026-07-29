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
const write_mod = @import("write.zig");
const source_path = @import("../source/path.zig");
const dirent = @import("../source/dirent.zig");

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

pub fn idNow(io: Io) [id_len]u8 {
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
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = manifest.items });
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

    // dirent.sorted gives a total order, so ids come out oldest-first by their
    // timestamped names -- the order prune relies on to drop the oldest.
    for (try dirent.sorted(arena, io, dir)) |entry| {
        if (entry.kind != .directory) continue;
        try ids.append(arena, entry.name);
    }
    return ids.toOwnedSlice(arena);
}

/// Delete the oldest snapshots so at most `keep` remain.
pub fn prune(arena: std.mem.Allocator, io: Io, snapshots_dir: []const u8, keep: usize) !void {
    const ids = try list(arena, io, snapshots_dir);
    if (ids.len <= keep) return;

    var dir = try Io.Dir.cwd().openDir(io, snapshots_dir, .{ .iterate = true });
    defer dir.close(io);
    for (ids[0 .. ids.len - keep]) |id| {
        try dir.deleteTree(io, id);
        // Drop the directory-mode sidecar beside the store it described.
        dir.deleteFile(io, try std.fmt.allocPrint(arena, "{s}.dirmodes", .{id})) catch {};
    }
}

pub const Restored = struct {
    count: usize = 0,
};

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
    return restoreExcept(arena, io, snapshots_dir, id, home, null, null);
}

/// `restore`, withholding every live path in `skip` from the whole-file
/// write. A withheld file's snapshot content is collected into `skipped`
/// instead; the caller decides what to do with it (rollback re-patches a
/// partial target's owned subtree rather than clobbering the remainder).
pub fn restoreExcept(
    arena: std.mem.Allocator,
    io: Io,
    snapshots_dir: []const u8,
    id: []const u8,
    home: []const u8,
    skip: ?*const std.StringHashMap(void),
    skipped: ?*std.ArrayList(Withheld),
) !Restored {
    const snap_dir_path = try std.fs.path.join(arena, &.{ snapshots_dir, id });
    var dir = Io.Dir.cwd().openDir(io, snap_dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return error.SnapshotNotFound,
        else => return e,
    };
    defer dir.close(io);

    var result: Restored = .{};
    try restoreDir(arena, io, dir, snap_dir_path, "", home, skip, skipped, &result);
    try restoreDirModes(arena, io, snapshots_dir, id, home);
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
        try entries.append(arena, .{ .live = live, .mode = mode });
    }

    for (entries.items) |e| try Io.Dir.cwd().createDirPath(io, e.live);
    var i = entries.items.len;
    while (i > 0) {
        i -= 1;
        try write_mod.setMode(entries.items[i].live, entries.items[i].mode);
    }
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
                try restoreDir(arena, io, sub, sub_abs, rel, home, skip, skipped, result);
            },
            .file => {
                const content = try dir.readFileAlloc(io, entry.name, arena, .limited(64 * 1024 * 1024));
                const target = try source_path.joinKeyOnto(arena, home, rel);
                if (skip != null and skip.?.contains(target)) {
                    if (skipped) |out| try out.append(arena, .{ .live_path = target, .content = content });
                    continue;
                }
                const st = try dir.statFile(io, entry.name, .{});
                try write_mod.writeAtomic(io, target, content, write_mod.modeOf(st.permissions));
                result.count += 1;
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = try dir.readLink(io, entry.name, &buf);
                const target = try source_path.joinKeyOnto(arena, home, rel);
                if (std.fs.path.dirname(target)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
                Io.Dir.cwd().deleteFile(io, target) catch {};
                try Io.Dir.cwd().symLink(io, buf[0..n], target, .{});
                result.count += 1;
            },
            else => {},
        }
    }
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

test "restore: a symlink whose readLink fails propagates instead of silently skipping it" {
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

    try std.testing.expectError(error.Unexpected, restore(a, faulty, snaps, "id1", home));
}

var stat_fail_target: []const u8 = "";

fn failingStatFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, opts: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
    _ = userdata;
    _ = dir;
    _ = opts;
    if (std.mem.eql(u8, sub_path, stat_fail_target)) return error.Unexpected;
    unreachable; // this fixture stats exactly one path
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

test "restore: a snapshot entry's stat failure propagates instead of degrading the restored mode to 0644" {
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

    try std.testing.expectError(error.Unexpected, restore(a, faulty, snaps, "id1", home));
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

test "relToHome strips the home prefix" {
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
