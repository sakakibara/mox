//! Deterministic directory enumeration.
//!
//! `Io.Dir.iterate()` yields entries in the filesystem's order, which is not
//! stable across filesystems: APFS and ext4 return the same directory in
//! different orders. Any enumeration whose order can be OBSERVED -- output the
//! user sees, the order a side effect runs in, or a collection handed back to a
//! caller -- must therefore impose a total order, or the tool behaves
//! differently on machines it exists to keep identical.
//!
//! This is the one sanctioned way to enumerate such a directory. Raw
//! `iterate()` is permitted only where the order provably cannot be observed
//! (an emptiness check, a whole-subtree copy, a "does any entry match" bool),
//! and each such use carries a comment saying why.

const std = @import("std");
const Io = std.Io;

pub const Entry = struct {
    name: []const u8,
    kind: Io.File.Kind,
};

/// Every entry of `dir` in a total, filesystem-independent order (by name),
/// each name duped into `arena`.
pub fn sorted(arena: std.mem.Allocator, io: Io, dir: Io.Dir) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        try entries.append(arena, .{ .name = try arena.dupe(u8, e.name), .kind = e.kind });
    }
    const out = try entries.toOwnedSlice(arena);
    std.mem.sort(Entry, out, {}, less);
    return out;
}

/// `sorted` for a directory named by path. Returns an empty slice when the
/// directory does not exist, so a caller enumerating an optional tree need not
/// special-case its absence.
pub fn sortedPath(arena: std.mem.Allocator, io: Io, dir_path: []const u8, opts: Io.Dir.OpenOptions) ![]Entry {
    var dir = Io.Dir.cwd().openDir(io, dir_path, opts) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer dir.close(io);
    return sorted(arena, io, dir);
}

fn less(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

const testing = std.testing;

test "sorted: returns entries name-ordered regardless of creation order" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Created in a deliberately non-sorted order.
    try tmp.dir.writeFile(io, .{ .sub_path = "m", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "z", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "d", .data = "" });

    // `sorted` iterates, so the handle must be opened iterable -- a dir opened
    // without it panics on getdents on Linux (and happens to work on macOS).
    var d = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    const entries = try sorted(a, io, d);
    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqualStrings("a", entries[0].name);
    try testing.expectEqualStrings("d", entries[1].name);
    try testing.expectEqualStrings("m", entries[2].name);
    try testing.expectEqualStrings("z", entries[3].name);
}

test "sortedPath: a missing directory is an empty slice, not an error" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entries = try sortedPath(a, io, "/nonexistent/mox/dir", .{ .iterate = true });
    try testing.expectEqual(@as(usize, 0), entries.len);
}
