//! Live-file snapshots.
//!
//! Before apply overwrites a live file, the prior content is copied into a
//! per-run snapshot directory (`<snapshots>/<id>/<path-relative-to-home>`)
//! so `mox rollback <id>` can restore it. Snapshot ids are UTC timestamps,
//! so lexicographic order is chronological order. Rollback deliberately
//! leaves the last-applied records stale: the next apply then sees the
//! restored files as drift and refuses to silently overwrite them again.

const std = @import("std");

const Io = std.Io;
const write_mod = @import("write.zig");
const source_path = @import("../source/path.zig");

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
    const mode = blk: {
        const st = Io.Dir.cwd().statFile(io, live_path, .{}) catch break :blk @as(u32, 0o644);
        break :blk write_mod.modeOf(st.permissions);
    };
    try write_mod.writeAtomic(io, dest, content, mode);
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

/// List snapshot ids, oldest first.
pub fn list(arena: std.mem.Allocator, io: Io, snapshots_dir: []const u8) ![]const []const u8 {
    var dir = Io.Dir.cwd().openDir(io, snapshots_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer dir.close(io);

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(arena);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try ids.append(arena, try arena.dupe(u8, entry.name));
    }
    const out = try ids.toOwnedSlice(arena);
    std.mem.sort([]const u8, @constCast(out), {}, lessThan);
    return out;
}

/// Delete the oldest snapshots so at most `keep` remain.
pub fn prune(arena: std.mem.Allocator, io: Io, snapshots_dir: []const u8, keep: usize) !void {
    const ids = try list(arena, io, snapshots_dir);
    if (ids.len <= keep) return;

    var dir = try Io.Dir.cwd().openDir(io, snapshots_dir, .{ .iterate = true });
    defer dir.close(io);
    for (ids[0 .. ids.len - keep]) |id| {
        try dir.deleteTree(io, id);
    }
}

pub const Restored = struct {
    count: usize = 0,
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
    const snap_dir_path = try std.fs.path.join(arena, &.{ snapshots_dir, id });
    var dir = Io.Dir.cwd().openDir(io, snap_dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return error.SnapshotNotFound,
        else => return e,
    };
    defer dir.close(io);

    var result: Restored = .{};
    try restoreDir(arena, io, dir, snap_dir_path, "", home, &result);
    return result;
}

fn restoreDir(
    arena: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    abs_prefix: []const u8,
    rel_prefix: []const u8,
    home: []const u8,
    result: *Restored,
) !void {
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
                try restoreDir(arena, io, sub, sub_abs, rel, home, result);
            },
            .file => {
                const content = try dir.readFileAlloc(io, entry.name, arena, .limited(64 * 1024 * 1024));
                const mode = blk: {
                    const st = dir.statFile(io, entry.name, .{}) catch break :blk @as(u32, 0o644);
                    break :blk write_mod.modeOf(st.permissions);
                };
                const target = try source_path.joinKeyOnto(arena, home, rel);
                try write_mod.writeAtomic(io, target, content, mode);
                result.count += 1;
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = dir.readLink(io, entry.name, &buf) catch continue;
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

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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
