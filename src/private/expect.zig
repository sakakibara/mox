//! Whether this repo and HOME expect a private layer.
//!
//! An apply that finds a private layer holding a source -- any file the
//! source walk would not skip as junk, its data and attributes included --
//! notes it under `<state>/expected-private/`. From then on a private layer
//! that is absent, not a directory, or holds no source is unavailable, and
//! every command that composes refuses to run until it is back or the
//! expectation is retired: a run without it would compose without its
//! private part and remove what only it provides.

const std = @import("std");
const Io = std.Io;
const junk = @import("../source/junk.zig");
const applied = @import("../apply/applied.zig");

fn markerPath(arena: std.mem.Allocator, state_dir: []const u8, repo_tag: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ state_dir, "expected-private", &applied.contentHashHex(repo_tag) });
}

/// True when an apply noted that this repo and HOME have a private layer.
pub fn expected(arena: std.mem.Allocator, io: Io, state_dir: []const u8, repo_tag: []const u8) !bool {
    Io.Dir.cwd().access(io, try markerPath(arena, state_dir, repo_tag), .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

/// Note that this repo and HOME have a private layer.
pub fn note(arena: std.mem.Allocator, io: Io, state_dir: []const u8, repo_tag: []const u8) !void {
    const path = try markerPath(arena, state_dir, repo_tag);
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.fmt.allocPrint(arena, "repo {s}\n", .{try applied.pctEncode(arena, repo_tag)}) });
}

/// Stop expecting a private layer: true when there was an expectation.
pub fn retire(arena: std.mem.Allocator, io: Io, state_dir: []const u8, repo_tag: []const u8, dry_run: bool) !bool {
    if (!try expected(arena, io, state_dir, repo_tag)) return false;
    if (!dry_run) try Io.Dir.cwd().deleteFile(io, try markerPath(arena, state_dir, repo_tag));
    return true;
}

/// True when the private layer at `private_dir` is a directory holding a
/// file the source walk would not skip as junk, at any depth.
pub fn holdsSource(arena: std.mem.Allocator, io: Io, private_dir: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(io, private_dir, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (walker.next(io) catch return false) |entry| {
        if (entry.kind == .directory) continue;
        if (junkPath(entry.path)) continue;
        return true;
    }
    return false;
}

fn junkPath(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| if (junk.isJunk(part)) return true;
    return false;
}

/// True when this repo and HOME expect a private layer that is not there.
pub fn unavailable(arena: std.mem.Allocator, io: Io, state_dir: []const u8, private_dir: []const u8, repo_tag: []const u8) !bool {
    if (!try expected(arena, io, state_dir, repo_tag)) return false;
    return !try holdsSource(arena, io, private_dir);
}

test "holdsSource: junk and an evicted iCloud placeholder are no source" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "p/.config/x");
    try tmp.dir.writeFile(io, .{ .sub_path = "p/.DS_Store", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "p/.config/x/..c.icloud", .data = "x" });
    const p = try tmp.dir.realPathFileAlloc(io, "p", a);
    try testing.expect(!try holdsSource(a, io, p));
    try tmp.dir.writeFile(io, .{ .sub_path = "p/.config/x/c", .data = "x" });
    try testing.expect(try holdsSource(a, io, p));
    try testing.expect(!try holdsSource(a, io, try std.fs.path.join(a, &.{ p, "missing" })));
}
