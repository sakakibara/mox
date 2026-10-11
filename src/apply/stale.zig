//! Records whose source left the tree.
//!
//! A file mox wrote stays recorded under `<state>/` after its source is
//! deleted or moved. A record names the repo it came from, so one repo's
//! records are found here and another's never are. A record of this repo
//! is stale when no current managed file (repo or private layer, gated-off
//! ones included) and no generator manifest names its path. A record that
//! names no repo is never stale.

const std = @import("std");
const applied = @import("applied.zig");
const write = @import("write.zig");
const dirent = @import("../source/dirent.zig");
const tree_mod = @import("../source/tree.zig");
const parent_link = @import("parent_link.zig");

const Io = std.Io;

pub const Kind = enum {
    /// A whole file mox wrote: removed when unedited.
    whole,
    /// A symlink mox planted: removed when it still points where mox put it.
    symlink,
    /// A partially owned file: never removed, the program owns the rest.
    owned,
};

pub const Candidate = struct {
    live_path: []const u8,
    kind: Kind,
    /// The content hash a whole-file record holds.
    hash: [applied.hash_hex_len]u8 = undefined,
    /// The target a symlink record holds.
    target: []const u8 = "",
};

/// Every stale record of `repo` under `home`, one per live path, sorted by
/// path. `keep` holds the live paths the tree and the generator manifests
/// name. A record outside `home` belongs to a run with another HOME and is
/// never a candidate.
pub fn find(
    arena: std.mem.Allocator,
    io: Io,
    state_dir: []const u8,
    repo: []const u8,
    home: []const u8,
    keep: *const std.StringHashMap(void),
) ![]Candidate {
    var seen = std.StringHashMap(void).init(arena);
    var out: std.ArrayList(Candidate) = .empty;

    for (try recordBytes(arena, io, state_dir, "applied-owned", 64 * 1024 * 1024)) |bytes| {
        const rec = (try applied.parseOwned(arena, bytes)) orelse continue;
        if (!tagged(rec.repo, repo) or !parent_link.underHome(rec.live_path, home)) continue;
        if (keep.contains(rec.live_path) or seen.contains(rec.live_path)) continue;
        try seen.put(rec.live_path, {});
        try out.append(arena, .{ .live_path = rec.live_path, .kind = .owned });
    }
    for (try recordBytes(arena, io, state_dir, "applied-symlink", 1024 * 1024)) |bytes| {
        const rec = try applied.parseSymlink(arena, bytes);
        const live = rec.live_path orelse continue;
        if (!tagged(rec.repo, repo) or !parent_link.underHome(live, home)) continue;
        if (keep.contains(live) or seen.contains(live)) continue;
        try seen.put(live, {});
        try out.append(arena, .{ .live_path = live, .kind = .symlink, .target = rec.target });
    }
    for (try recordBytes(arena, io, state_dir, "applied", 1024 * 1024)) |bytes| {
        const rec = (try applied.parseWhole(arena, bytes)) orelse continue;
        if (!tagged(rec.repo, repo) or !parent_link.underHome(rec.live_path, home)) continue;
        if (keep.contains(rec.live_path)) continue;
        // A path holding both a whole-file and a symlink record is judged by
        // what the record of its live kind says.
        if (seen.contains(rec.live_path)) {
            for (out.items) |*c| {
                if (c.kind == .symlink and std.mem.eql(u8, c.live_path, rec.live_path) and !isSymlink(io, c.live_path)) {
                    c.* = .{ .live_path = rec.live_path, .kind = .whole, .hash = rec.hash };
                }
            }
            continue;
        }
        try seen.put(rec.live_path, {});
        try out.append(arena, .{ .live_path = rec.live_path, .kind = .whole, .hash = rec.hash });
    }
    std.mem.sort(Candidate, out.items, {}, lessByPath);
    return out.toOwnedSlice(arena);
}

fn isSymlink(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

fn tagged(rec_repo: ?[]const u8, repo: []const u8) bool {
    const r = rec_repo orelse return false;
    return std.mem.eql(u8, r, repo);
}

fn lessByPath(_: void, a: Candidate, b: Candidate) bool {
    return std.mem.lessThan(u8, a.live_path, b.live_path);
}

fn recordBytes(arena: std.mem.Allocator, io: Io, state_dir: []const u8, family: []const u8, limit: usize) ![]const []const u8 {
    const dir = try std.fs.path.join(arena, &.{ state_dir, family });
    const entries = dirent.sortedPath(arena, io, dir, .{ .iterate = true }) catch return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        if (e.kind != .file) continue;
        const p = try std.fs.path.join(arena, &.{ dir, e.name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(limit)) catch continue;
        try out.append(arena, bytes);
    }
    return out.toOwnedSlice(arena);
}

/// What the sweep does with one candidate.
pub const Verdict = enum {
    /// Nothing is there any more: forget the records.
    gone,
    /// The same file as a path the tree manages (a case-only rename on a
    /// case-insensitive filesystem, or a hardlink): forget, remove nothing.
    same_file,
    /// Unedited since mox wrote it: remove it, snapshot first.
    remove,
    /// Edited since mox wrote it: drift, kept.
    drift,
    /// A partially owned file: left in place, its records forgotten.
    leave,
    /// Not a regular file or symlink mox could have left: refused.
    special,
    /// A directory above it is a symlink, so the path names a file outside
    /// HOME's own tree: left in place, its records forgotten.
    linked_parent,
};

/// The live paths `files` plants as symlinks.
pub fn managedLinks(arena: std.mem.Allocator, files: []const tree_mod.ManagedFile) !std.StringHashMap(void) {
    var out = std.StringHashMap(void).init(arena);
    for (files) |f| if (f.is_symlink) try out.put(f.live_path, {});
    return out;
}

/// Judge `c` against the live tree. `tree_inodes` holds the inode of every
/// live path the tree manages that exists; `links` the live paths it plants
/// as symlinks.
pub fn judge(
    arena: std.mem.Allocator,
    io: Io,
    c: Candidate,
    tree_inodes: *const std.AutoHashMap(u128, void),
    home: []const u8,
    links: *const std.StringHashMap(void),
) !Verdict {
    if (parent_link.through(io, home, c.live_path, links)) return .linked_parent;
    const st = Io.Dir.cwd().statFile(io, c.live_path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return .gone,
        else => return .special,
    };
    if (tree_inodes.contains(@intCast(st.inode))) return .same_file;
    switch (c.kind) {
        .owned => return .leave,
        .symlink => {
            if (st.kind != .sym_link) return .drift;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = Io.Dir.cwd().readLink(io, c.live_path, &buf) catch return .special;
            return if (applied.sameSymlinkTarget(buf[0..n], c.target)) .remove else .drift;
        },
        .whole => {
            if (st.kind == .sym_link or st.kind == .directory) return .drift;
            if (write.guardLiveRead(io, c.live_path) == .special) return .special;
            const live = Io.Dir.cwd().readFileAlloc(io, c.live_path, arena, .limited(64 * 1024 * 1024)) catch return .special;
            const h = applied.contentHashHex(live);
            return if (std.mem.eql(u8, &h, &c.hash)) .remove else .drift;
        },
    }
}

/// The inode of every path in `paths` that exists, read without following
/// a symlink, so a dangling link still stats.
pub fn inodesOf(arena: std.mem.Allocator, io: Io, paths: []const []const u8) !std.AutoHashMap(u128, void) {
    var out = std.AutoHashMap(u128, void).init(arena);
    for (paths) |p| {
        const st = Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch continue;
        try out.put(@intCast(st.inode), {});
    }
    return out;
}

const testing = std.testing;

test "find: only this repo's tagged records whose path nothing keeps" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const state = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "state" });

    try applied.record(a, io, state, "/h/kept", "x", "/repo");
    try applied.record(a, io, state, "/h/gone", "x", "/repo");
    try applied.record(a, io, state, "/h/other", "x", "/other-repo");
    try applied.recordSymlink(a, io, state, "/h/link", "/t", "/repo");
    // An untagged record is never stale.
    const legacy = try std.fs.path.join(a, &.{ state, "applied", &applied.contentHashHex("/h/legacy") });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = legacy, .data = "0000000000000000000000000000000000000000000000000000000000000000 /h/legacy\n" });

    var keep = std.StringHashMap(void).init(a);
    try keep.put("/h/kept", {});
    const got = try find(a, io, state, "/repo", "/h", &keep);
    try testing.expectEqual(@as(usize, 0), (try find(a, io, state, "/repo", "/elsewhere", &keep)).len);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("/h/gone", got[0].live_path);
    try testing.expectEqual(Kind.whole, got[0].kind);
    try testing.expectEqualStrings("/h/link", got[1].live_path);
    try testing.expectEqualStrings("/t", got[1].target);
}
