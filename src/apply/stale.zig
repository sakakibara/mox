//! Records whose source left the tree.
//!
//! A file mox wrote stays recorded under `<state>/` after its source is
//! deleted or moved. A record names the repo and HOME it came from, so this
//! run's records are found here and another repo's or HOME's never are. A
//! record of this run is stale when no current managed file (repo or private
//! layer, gated-off ones included) and no generator manifest names its path.
//! A record that names no repo is never stale.

const std = @import("std");
const builtin = @import("builtin");
const applied = @import("applied.zig");
const write = @import("write.zig");
const dirent = @import("../source/dirent.zig");
const tree_mod = @import("../source/tree.zig");
const parent_link = @import("parent_link.zig");
const identity = @import("identity.zig");
const generated = @import("generated.zig");

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
    /// A symlink record of a link rollback put back: drift, never removed
    /// without `--overwrite`.
    rolled_back: bool = false,
    /// Written for a file only the private layer holds.
    private: bool = false,
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
        try out.append(arena, .{ .live_path = rec.live_path, .kind = .owned, .private = isPrivate(rec.repo, repo) });
    }
    for (try recordBytes(arena, io, state_dir, "applied-symlink", 1024 * 1024)) |bytes| {
        const rec = try applied.parseSymlink(arena, bytes);
        const live = rec.live_path orelse continue;
        if (!tagged(rec.repo, repo) or !parent_link.underHome(live, home)) continue;
        if (keep.contains(live) or seen.contains(live)) continue;
        try seen.put(live, {});
        try out.append(arena, .{ .live_path = live, .kind = .symlink, .target = rec.target, .rolled_back = rec.rolled_back, .private = isPrivate(rec.repo, repo) });
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
                    c.* = .{ .live_path = rec.live_path, .kind = .whole, .hash = rec.hash, .private = isPrivate(rec.repo, repo) };
                }
            }
            continue;
        }
        try seen.put(rec.live_path, {});
        try out.append(arena, .{ .live_path = rec.live_path, .kind = .whole, .hash = rec.hash, .private = isPrivate(rec.repo, repo) });
    }
    std.mem.sort(Candidate, out.items, {}, lessByPath);
    return out.toOwnedSlice(arena);
}

/// True when the private layer at `private_dir` cannot be trusted to hold
/// what it held: it is absent, or holds no file, while records of `repo`
/// under `home` name it. An empty mountpoint or an unsynced folder reads
/// the same as a missing one.
pub fn privateUnavailable(arena: std.mem.Allocator, io: Io, private_dir: []const u8, state_dir: []const u8, repo: []const u8, home: []const u8) !bool {
    if (try holdsAFile(arena, io, private_dir)) return false;
    return privateRecords(arena, io, state_dir, repo, home);
}

fn holdsAFile(arena: std.mem.Allocator, io: Io, dir_path: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (walker.next(io) catch return false) |entry| {
        if (entry.kind != .directory) return true;
    }
    return false;
}

/// True when any record or generator manifest of `repo` under `home` was
/// written for a file only the private layer holds.
pub fn privateRecords(arena: std.mem.Allocator, io: Io, state_dir: []const u8, repo: []const u8, home: []const u8) !bool {
    var none = std.StringHashMap(void).init(arena);
    for (try find(arena, io, state_dir, repo, home, &none)) |c| if (c.private) return true;
    for (try recordBytes(arena, io, state_dir, "generated", 64 * 1024 * 1024)) |bytes| {
        if (applied.layerOf(try generated.repoOf(arena, bytes), repo) == .private) return true;
    }
    return false;
}

/// The stale records of `repo` under `home` against the whole tree `tree`:
/// what a full apply would sweep, before any generator runs.
pub fn candidatesOf(arena: std.mem.Allocator, io: Io, state_dir: []const u8, repo: []const u8, home: []const u8, tree: tree_mod.ManagedTree) ![]Candidate {
    var keep = std.StringHashMap(void).init(arena);
    for (tree.files) |f| try keep.put(f.live_path, {});
    for (try generated.allLeaves(arena, io, state_dir)) |leaf| try keep.put(leaf, {});
    for (tree.entry_errors) |e| try keep.put(e.live_path, {});
    const released = try releasedSet(arena, tree.released);
    var out: std.ArrayList(Candidate) = .empty;
    for (try find(arena, io, state_dir, repo, home, &keep)) |c| {
        if (released.contains(try foldCase(arena, c.live_path))) continue;
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

/// A tombstone this machine cannot match: `managed` names a managed file
/// whose path differs from it only in case, else it matches nothing.
pub const Unmatched = struct { live_path: []const u8, managed: ?[]const u8 = null };

/// The tombstones of `tree` that match no record, no generator manifest and
/// no managed file exactly, less those an apply has already seen. One that
/// matches a managed file only by case is always listed.
pub fn unmatchedTombstones(arena: std.mem.Allocator, io: Io, state_dir: []const u8, repo: []const u8, tree: tree_mod.ManagedTree) ![]Unmatched {
    if (tree.released.len == 0) return &.{};
    var known = std.StringHashMap(void).init(arena);
    for (try recordBytes(arena, io, state_dir, "applied-owned", 64 * 1024 * 1024)) |bytes| {
        const rec = (try applied.parseOwned(arena, bytes)) orelse continue;
        try known.put(try foldCase(arena, rec.live_path), {});
    }
    for (try recordBytes(arena, io, state_dir, "applied-symlink", 1024 * 1024)) |bytes| {
        const rec = try applied.parseSymlink(arena, bytes);
        if (rec.live_path) |l| try known.put(try foldCase(arena, l), {});
    }
    for (try recordBytes(arena, io, state_dir, "applied", 1024 * 1024)) |bytes| {
        const rec = (try applied.parseWhole(arena, bytes)) orelse continue;
        try known.put(try foldCase(arena, rec.live_path), {});
    }
    for (try generated.allGenerators(arena, io, state_dir)) |g| try known.put(try foldCase(arena, g), {});
    var out: std.ArrayList(Unmatched) = .empty;
    outer: for (tree.released) |p| {
        const fp = try foldCase(arena, p);
        for (tree.files) |f| {
            if (std.mem.eql(u8, try foldCase(arena, f.live_path), fp)) {
                try out.append(arena, .{ .live_path = p, .managed = f.live_path });
                continue :outer;
            }
        }
        if (known.contains(fp)) continue;
        Io.Dir.cwd().access(io, try markerPath(arena, state_dir, repo, fp), .{}) catch {
            try out.append(arena, .{ .live_path = p });
        };
    }
    return out.toOwnedSlice(arena);
}

/// Note that an apply of `repo` (its repo-and-HOME tag) has seen every
/// tombstone in `released`, so one that matches nothing is reported once.
pub fn markTombstones(arena: std.mem.Allocator, io: Io, state_dir: []const u8, repo: []const u8, released: []const []const u8) !void {
    for (released) |p| {
        const path = try markerPath(arena, state_dir, repo, try foldCase(arena, p));
        if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "" });
    }
}

fn markerPath(arena: std.mem.Allocator, state_dir: []const u8, repo: []const u8, folded: []const u8) ![]const u8 {
    const name = applied.contentHashHex(try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ repo, folded }));
    return std.fs.path.join(arena, &.{ state_dir, "released", &name });
}

/// `paths` as a set matched through `foldCase`.
pub fn releasedSet(arena: std.mem.Allocator, paths: []const []const u8) !std.StringHashMap(void) {
    var out = std.StringHashMap(void).init(arena);
    for (paths) |p| try out.put(try foldCase(arena, p), {});
    return out;
}

/// `path` as a case-insensitive filesystem compares it: ASCII-lowercased on
/// macOS and Windows, unchanged elsewhere. A tombstone written for `.foo`
/// releases a record of `~/.Foo` there, since both name one file.
pub fn foldCase(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (builtin.os.tag != .macos and builtin.os.tag != .windows) return path;
    return std.ascii.allocLowerString(arena, path);
}

/// The candidate in `cands` at `live_path`, or null.
pub fn at(cands: []const Candidate, live_path: []const u8) ?Candidate {
    for (cands) |c| if (std.mem.eql(u8, c.live_path, live_path)) return c;
    return null;
}

fn isSymlink(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

fn tagged(rec_repo: ?[]const u8, repo: []const u8) bool {
    return applied.layerOf(rec_repo, repo) != null;
}

fn isPrivate(rec_repo: ?[]const u8, repo: []const u8) bool {
    return applied.layerOf(rec_repo, repo) == .private;
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

/// The live paths `files` plants as symlinks.
pub fn managedLinks(arena: std.mem.Allocator, files: []const tree_mod.ManagedFile) !std.StringHashMap(void) {
    var out = std.StringHashMap(void).init(arena);
    for (files) |f| if (f.is_symlink) try out.put(f.live_path, {});
    return out;
}

/// The identities of kept paths: device and inode, so two files on
/// different devices that share an inode number are never one file.
pub const Kept = std.AutoHashMap(identity.Identity, void);

/// True when `path` is the same file as one `kept` holds: a case-only
/// rename on a case-insensitive filesystem, or a hardlink. Both sweeps then
/// forget the record and remove nothing.
pub fn sameFile(io: Io, path: []const u8, kept: *const Kept) bool {
    const id = identity.of(io, path, .no_follow) orelse return false;
    return kept.contains(id);
}

/// The identity of every path in `paths` that exists, read without
/// following a symlink, so a dangling link still has one.
pub fn inodesOf(arena: std.mem.Allocator, io: Io, paths: []const []const u8) !Kept {
    var out = Kept.init(arena);
    for (paths) |p| {
        const id = identity.of(io, p, .no_follow) orelse continue;
        try out.put(id, {});
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
