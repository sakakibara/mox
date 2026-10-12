//! Content-addressed blobs under `v2/blobs/<sha256>`: displaced content,
//! the commit diff cache, owned canonical text and provenance.

const std = @import("std");
const Io = std.Io;
const applied = @import("../apply/applied.zig");
const durable = @import("durable.zig");
const generation = @import("generation.zig");

pub const Hex = generation.Hex;
const max_bytes: usize = 64 * 1024 * 1024;

/// Store `bytes` and return its name. An existing blob is read back and kept
/// only when it still hashes to its name; otherwise it is rewritten.
pub fn put(arena: std.mem.Allocator, io: Io, blobs_dir: []const u8, bytes: []const u8) !Hex {
    const hex = applied.contentHashHex(bytes);
    const path = try std.fs.path.join(arena, &.{ blobs_dir, &hex });
    if (try get(arena, io, blobs_dir, hex) != null) return hex;
    try durable.makeDir(io, blobs_dir);
    try durable.writeFile(io, path, bytes);
    return hex;
}

/// The bytes of blob `hex`, or null when it is missing or no longer hashes
/// to its name.
pub fn get(arena: std.mem.Allocator, io: Io, blobs_dir: []const u8, hex: Hex) !?[]const u8 {
    const path = try std.fs.path.join(arena, &.{ blobs_dir, &hex });
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null,
    };
    if (!std.mem.eql(u8, &applied.contentHashHex(bytes), &hex)) return null;
    return bytes;
}

/// Where blob `hex` is kept, as refusal lines name it.
pub fn pathOf(arena: std.mem.Allocator, blobs_dir: []const u8, hex: Hex) ![]const u8 {
    return std.fs.path.join(arena, &.{ blobs_dir, &hex });
}

test "blob: a corrupt blob reads as missing and is rewritten by the next put" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "blobs" });
    const h = try put(a, io, dir, "content");
    try std.testing.expectEqualStrings("content", (try get(a, io, dir, h)).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try pathOf(a, dir, h), .data = "tampered" });
    try std.testing.expect(try get(a, io, dir, h) == null);
    _ = try put(a, io, dir, "content");
    try std.testing.expectEqualStrings("content", (try get(a, io, dir, h)).?);
    try std.testing.expect(try get(a, io, dir, applied.contentHashHex("absent")) == null);
}
