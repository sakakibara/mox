//! Whether the repo sits part-way through a git operation.
//!
//! A conflicted merge, rebase, cherry-pick, or revert leaves its markers in
//! the source tree, so composing from it writes `<<<<<<<` into live files and
//! runs setup scripts from a half-applied revision. Detection is a marker-file
//! lookup rather than a `git` invocation: mox reaches no subprocess and needs
//! git on no PATH, and a repo that is not a git checkout simply has no marker
//! to find.

const std = @import("std");

const Io = std.Io;

/// Marker git leaves in `.git` for each operation that can stop mid-way with
/// the work tree conflicted. Bisect is absent on purpose: it leaves no
/// conflict, and applying part-way through one is a reasonable thing to do.
const markers = [_]struct { entry: []const u8, operation: []const u8 }{
    .{ .entry = "MERGE_HEAD", .operation = "merge" },
    .{ .entry = "rebase-merge", .operation = "rebase" },
    .{ .entry = "rebase-apply", .operation = "rebase" },
    .{ .entry = "CHERRY_PICK_HEAD", .operation = "cherry-pick" },
    .{ .entry = "REVERT_HEAD", .operation = "revert" },
};

/// The git operation `repo_dir` is part-way through, or null when it is idle
/// or is not a git checkout. A worktree or submodule keeps its git dir
/// elsewhere and reads as idle here: this is a guard against the common way a
/// source tree turns incoherent, not a claim to detect every one.
pub fn inProgress(arena: std.mem.Allocator, io: Io, repo_dir: []const u8) !?[]const u8 {
    for (markers) |m| {
        const path = try std.fs.path.join(arena, &.{ repo_dir, ".git", m.entry });
        Io.Dir.cwd().access(io, path, .{}) catch continue;
        return m.operation;
    }
    return null;
}

const testing = std.testing;

fn tmpRepo(arena: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(testing.io, arena);
    return std.fs.path.join(arena, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
}

test "inProgress: a repo with no .git at all is idle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(@as(?[]const u8, null), try inProgress(a, testing.io, try tmpRepo(a, &tmp)));
}

test "inProgress: an idle git checkout is idle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".git");
    try testing.expectEqual(@as(?[]const u8, null), try inProgress(a, testing.io, try tmpRepo(a, &tmp)));
}

test "inProgress: a conflicted merge names the merge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".git");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".git/MERGE_HEAD", .data = "deadbeef\n" });
    try testing.expectEqualStrings("merge", (try inProgress(a, testing.io, try tmpRepo(a, &tmp))).?);
}

test "inProgress: a rebase is found as a directory, not a file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".git/rebase-merge");
    try testing.expectEqualStrings("rebase", (try inProgress(a, testing.io, try tmpRepo(a, &tmp))).?);
}

test "inProgress: a cherry-pick and a revert are named apart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var picked = testing.tmpDir(.{});
    defer picked.cleanup();
    try picked.dir.createDirPath(testing.io, ".git");
    try picked.dir.writeFile(testing.io, .{ .sub_path = ".git/CHERRY_PICK_HEAD", .data = "d\n" });
    try testing.expectEqualStrings("cherry-pick", (try inProgress(a, testing.io, try tmpRepo(a, &picked))).?);

    var reverted = testing.tmpDir(.{});
    defer reverted.cleanup();
    try reverted.dir.createDirPath(testing.io, ".git");
    try reverted.dir.writeFile(testing.io, .{ .sub_path = ".git/REVERT_HEAD", .data = "d\n" });
    try testing.expectEqualStrings("revert", (try inProgress(a, testing.io, try tmpRepo(a, &reverted))).?);
}
