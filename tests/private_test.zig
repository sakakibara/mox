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

const testutil = @import("testutil.zig");

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "apply: a .mox-exact marker in the private layer prunes a foreign live file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The marked directory's only managed file comes from the repo; the marker
    // itself exists ONLY in the private layer, so the prune it drives can come
    // from nowhere but the merged tree's private half.
    try writeFile(io, tmp.dir, "repo/src/.config/app/keep.txt", "keep\n");
    try writeFile(io, tmp.dir, "state/private/.config/app/.mox-exact", "");

    const h = try testutil.setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const foreign = try h.homePath(".config/app/foreign.txt");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = foreign, .data = "mine\n" });

    // Exactness refuses a file mox never wrote...
    const refused = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(refused.rc != 0);
    try std.testing.expect(std.mem.indexOf(u8, refused.err, "foreign.txt") != null);
    try std.testing.expect(exists(io, foreign));

    // ... and removes it with --overwrite, leaving the managed file in place.
    const swept = try h.run(&.{ "mox", "apply", "--overwrite" });
    try std.testing.expectEqual(@as(u8, 0), swept.rc);
    try std.testing.expect(!exists(io, foreign));
    try std.testing.expect(exists(io, try h.homePath(".config/app/keep.txt")));
}

test "apply: a Cat C file composes its repo overlay, not the private overlay of the same axis tuple" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Same file, same tuple, one overlay per layer: equal specificity, so the
    // winner is decided by the order the merge concatenates the two layers in.
    try writeFile(io, tmp.dir, "repo/src/.config/site.pem", "base\n");
    try writeFile(io, tmp.dir, "repo/src/.config/site.pem.d/os=darwin.pem", "repo-darwin\n");
    try writeFile(io, tmp.dir, "state/private/.config/site.pem.d/os=darwin.pem", "private-darwin\n");

    const h = try testutil.setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try Io.Dir.cwd().readFileAlloc(io, try h.homePath(".config/site.pem"), a, .limited(1 << 20));
    try std.testing.expectEqualStrings("repo-darwin\n", live);
}
