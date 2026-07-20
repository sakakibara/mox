const std = @import("std");
const builtin = @import("builtin");
const mox = @import("mox");

const Io = std.Io;

fn writeFile(io: Io, dir: Io.Dir, sub: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub, .data = content });
}

fn chmod(path: []const u8, mode: u32) void {
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    _ = std.c.chmod(@ptrCast(&zbuf), @intCast(mode));
}

fn tmpPathAlloc(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, sub: []const u8) ![]u8 {
    const io = std.testing.io;
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path, sub });
}

test "merge: base file keeps mode, symlink flag, and repo_dir when a private overlay matches" {
    // The base carries its mode via the native exec bit; a filesystem without
    // one cannot express 0o755 and there is nothing to preserve.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "repo/src/.local/bin/theme", "#!/bin/sh\n");
    try writeFile(io, tmp.dir, "private/.local/bin/theme.d/os=darwin", "#!/bin/sh\n# darwin\n");

    const src_dir = try tmpPathAlloc(std.testing.allocator, &tmp, "repo/src");
    defer std.testing.allocator.free(src_dir);
    const private_dir = try tmpPathAlloc(std.testing.allocator, &tmp, "private");
    defer std.testing.allocator.free(private_dir);

    const theme_abs = try tmpPathAlloc(std.testing.allocator, &tmp, "repo/src/.local/bin/theme");
    defer std.testing.allocator.free(theme_abs);
    chmod(theme_abs, 0o755);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base_tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    try std.testing.expectEqual(@as(usize, 1), base_tree.files.len);
    try std.testing.expectEqual(@as(u32, 0o755), base_tree.files[0].mode);

    const merged = try mox.private.layer.merge(arena.allocator(), io, base_tree, private_dir, "/home/me");
    try std.testing.expectEqual(@as(usize, 1), merged.files.len);

    const f = merged.files[0];
    try std.testing.expectEqual(@as(usize, 1), f.overlays.len);
    try std.testing.expectEqual(@as(u32, 0o755), f.mode);
    try std.testing.expect(!f.is_symlink);
    try std.testing.expect(f.repo_dir.len > 0);
    try std.testing.expectEqualStrings(base_tree.files[0].repo_dir, f.repo_dir);
}
