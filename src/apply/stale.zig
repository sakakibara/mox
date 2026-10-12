//! Records whose source left the tree.
//!
//! A file mox wrote stays recorded after its source is deleted or moved. A
//! record names the part -- the repo and HOME -- it came from, so this run's
//! records are found here and another repo's or HOME's never are. A record
//! of this run is stale when no current managed file (repo or private layer,
//! gated-off ones included) and no generator's produced set names its path.

const std = @import("std");
const builtin = @import("builtin");
const applied = @import("applied.zig");
const write = @import("write.zig");
const dirent = @import("../source/dirent.zig");
const tree_mod = @import("../source/tree.zig");
const parent_link = @import("parent_link.zig");
const identity = @import("identity.zig");
const state = @import("../state/root.zig");

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
};

/// Every stale record of this run's part under `home`, one per live path,
/// sorted by path. `keep` holds the live paths the tree and the generators'
/// produced sets name. A record outside `home` belongs to a run with another
/// HOME and is never a candidate.
pub fn find(arena: std.mem.Allocator, st: *const state.Draft, home: []const u8, keep: *const std.StringHashMap(void)) ![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    for (st.gen.paths.keys(), st.gen.paths.values()) |live, e| {
        if (!std.mem.eql(u8, &e.part, &st.part)) continue;
        if (!parent_link.underHome(live, home) or keep.contains(live)) continue;
        try out.append(arena, switch (e.kind) {
            .owned => .{ .live_path = live, .kind = .owned },
            .link => .{ .live_path = live, .kind = .symlink, .target = e.link.?.target, .rolled_back = e.link.?.rolled_back },
            .file => .{ .live_path = live, .kind = .whole, .hash = e.file.?.sha256 },
        });
    }
    std.mem.sort(Candidate, out.items, {}, lessByPath);
    return out.toOwnedSlice(arena);
}

/// The stale records of this run's part under `home` against the whole tree
/// `tree`: what a full apply would sweep, before any generator runs.
pub fn candidatesOf(arena: std.mem.Allocator, st: *const state.Draft, home: []const u8, tree: tree_mod.ManagedTree) ![]Candidate {
    var keep = std.StringHashMap(void).init(arena);
    for (tree.files) |f| try keep.put(f.live_path, {});
    for (try st.allLeaves()) |leaf| try keep.put(leaf, {});
    for (tree.entry_errors) |e| try keep.put(e.live_path, {});
    const released = try releasedSet(arena, tree.released);
    var out: std.ArrayList(Candidate) = .empty;
    for (try find(arena, st, home, &keep)) |c| {
        if (released.contains(try foldCase(arena, c.live_path))) continue;
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

/// A tombstone this machine cannot match: `managed` names a managed file
/// whose path differs from it only in case, else it matches nothing.
pub const Unmatched = struct { live_path: []const u8, managed: ?[]const u8 = null };

/// The tombstones of `tree` that match no record, no generator and no
/// managed file exactly, less those an apply of this part has already seen.
/// One that matches a managed file only by case is always listed.
pub fn unmatchedTombstones(arena: std.mem.Allocator, st: *const state.Draft, tree: tree_mod.ManagedTree) ![]Unmatched {
    if (tree.released.len == 0) return &.{};
    var known = std.StringHashMap(void).init(arena);
    for (st.gen.paths.keys()) |live| try known.put(try foldCase(arena, live), {});
    for (st.gen.generators.keys()) |g| try known.put(try foldCase(arena, g), {});
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
        if (!st.tombstoneSeen(fp)) try out.append(arena, .{ .live_path = p });
    }
    return out.toOwnedSlice(arena);
}

/// Note that an apply of this part has seen every tombstone in `released`,
/// so one that matches nothing is reported once.
pub fn markTombstones(st: *state.Draft, released: []const []const u8) !void {
    try st.markTombstones(released, foldCase);
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

fn lessByPath(_: void, a: Candidate, b: Candidate) bool {
    return std.mem.lessThan(u8, a.live_path, b.live_path);
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

test "find: only this part's records under this HOME whose path nothing keeps" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const st = try state.draft.testDraft(a, io, try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "state" }));

    try st.record("/h/kept", "x", null);
    try st.record("/h/gone", "x", null);
    try st.recordSymlink("/h/link", "/t", null);
    // Another part's record is never stale.
    try st.setPath("/h/other", .{ .part = applied.contentHashHex("other"), .kind = .file, .file = .{ .sha256 = applied.contentHashHex("x") } });

    var keep = std.StringHashMap(void).init(a);
    try keep.put("/h/kept", {});
    const got = try find(a, st, "/h", &keep);
    try testing.expectEqual(@as(usize, 0), (try find(a, st, "/elsewhere", &keep)).len);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("/h/gone", got[0].live_path);
    try testing.expectEqual(Kind.whole, got[0].kind);
    try testing.expectEqualStrings("/h/link", got[1].live_path);
    try testing.expectEqualStrings("/t", got[1].target);
}
