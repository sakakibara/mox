//! Coverage for the unified drift classifier and `mox apply`'s non-interactive
//! core: the clean-tree differential, one fixture per drift kind (plus
//! first-contact) asserting skip-and-collect and `--overwrite` convergence,
//! the 0/1/2 exit-code split, and `status`/`apply` agreement on the drift set
//! for the same tree.

const std = @import("std");
const mox = @import("mox");
const testutil = @import("testutil.zig");

const Io = std.Io;
const Cli = testutil.Harness;
const builtin = @import("builtin");

fn cliSetup(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !Cli {
    return testutil.setup(a, io, tmp, .{});
}

fn read(io: Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn isSymlink(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

fn chmod(io: Io, a: std.mem.Allocator, path: []const u8, mode: u32) !void {
    _ = io;
    const z = try a.dupeZ(u8, path);
    _ = std.c.chmod(z.ptr, @intCast(mode));
}

fn modeOf(io: Io, path: []const u8) !u32 {
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    return @intCast(st.permissions.toMode() & 0o777);
}

const script_ext = if (builtin.os.tag == .windows) ".ps1" else ".sh";

fn writeExecScript(io: Io, dir: Io.Dir, sub: []const u8, content: []const u8, abs_path: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub, .data = content });
    if (builtin.os.tag == .windows) return; // no exec bit to set
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..abs_path.len], abs_path);
    zbuf[abs_path.len] = 0;
    _ = std.c.chmod(@ptrCast(&zbuf), 0o755);
}

// -- clean-tree differential --
//
// The key safety gate: an apply over a tree with no drift must behave
// exactly as it did before this fold (no report block, no behavior change).

test "clean tree: apply writes, reports no drift, exit 0" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc", .data = "export A=1\n" });
    const c = try cliSetup(a, io, &tmp);

    const r1 = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r1.rc);
    try std.testing.expect(std.mem.indexOf(u8, r1.out, "DRIFT") == null);
    try std.testing.expect(std.mem.indexOf(u8, r1.out, "Applied: 1 written, 0 removed, 0 unchanged, 0 skipped, 0 drifted, 0 failed") != null);

    // Second apply: nothing to write, still no drift report, exit 0.
    const r2 = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r2.rc);
    try std.testing.expect(std.mem.indexOf(u8, r2.out, "DRIFT") == null);
    try std.testing.expect(std.mem.indexOf(u8, r2.out, "Applied: 0 written, 0 removed, 1 unchanged, 0 skipped, 0 drifted, 0 failed") != null);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "status" })).rc);
}

// -- kind matrix: one fixture per drift kind + first-contact --

test "kind matrix: whole_file edited -- skip, report, --overwrite converges" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/a.conf", .data = "source\n" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    const live = try c.homePath("a.conf");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "hand edited\n" });

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqualStrings("hand edited\n", try read(io, a, live)); // skipped, not written
    try std.testing.expect(std.mem.indexOf(u8, r.out, "a.conf") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "whole file") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "first contact") == null);

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply", "--overwrite", live })).rc);
    try std.testing.expectEqualStrings("source\n", try read(io, a, live));
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc); // converges
}

test "kind matrix: whole_file first-contact -- skip, report as first contact (never 'edited'), --overwrite converges" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/a.conf", .data = "source\n" });
    const c = try cliSetup(a, io, &tmp);

    // Mox never wrote this file (no applied record): pre-existing live
    // content with no prior apply.
    const live = try c.homePath("a.conf");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "already here\n" });

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqualStrings("already here\n", try read(io, a, live));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "not written by mox") != null);
    // Never the "edited since mox wrote it" phrasing, wrong for a file mox
    // never wrote in the first place.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "edited since mox wrote it") == null);

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply", "--overwrite", live })).rc);
    try std.testing.expectEqualStrings("source\n", try read(io, a, live));
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
}

test "kind matrix: owned_key -- skip, report the key, --overwrite converges" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/app.toml", .data = "# mox: own tui\n[tui]\nk = 1\n" });
    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("app.toml");
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "[tui]\nk = 9\n" });

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqualStrings("[tui]\nk = 9\n", try read(io, a, live));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "owned key 'tui'") != null);

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply", "--overwrite", live })).rc);
    try std.testing.expectEqualStrings("[tui]\nk = 1\n", try read(io, a, live));
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
}

test "kind matrix: symlink_target -- skip, report, --overwrite converges" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/mylink", .data = "/tmp/mox-drift-target-a\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.mox/attributes.toml",
        .data = "[\"mylink\"]\nsymlink = true\n",
    });
    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("mylink");
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(isSymlink(io, live));

    // Re-point the live link somewhere mox never recorded: drift.
    try Io.Dir.cwd().deleteFile(io, live);
    try Io.Dir.cwd().symLink(io, "/tmp/mox-drift-target-b", live, .{});

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "symlink target") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "mylink") != null);

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply", "--overwrite", live })).rc);
    var buf: [512]u8 = undefined;
    const n = try Io.Dir.cwd().readLink(io, live, &buf);
    try std.testing.expectEqualStrings("/tmp/mox-drift-target-a", buf[0..n]);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
}

test "kind matrix: symlink over a directory -- --overwrite backs it up, replaces it, and converges" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/mylink", .data = "/tmp/mox-drift-target-a\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.mox/attributes.toml",
        .data = "[\"mylink\"]\nsymlink = true\n",
    });
    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("mylink");
    // A directory already occupies the live path, never a symlink mox wrote:
    // a top-level file, a subdirectory, and a nested symlink inside it.
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ live, "sub" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ live, "top.txt" }), .data = "top content\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ live, "sub", "nested.txt" }), .data = "nested content\n" });
    try Io.Dir.cwd().symLink(io, "/tmp/somewhere-else", try std.fs.path.join(a, &.{ live, "sub", "link.txt" }), .{});

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "symlink target") != null);

    // --overwrite snapshots the directory, deletes it, and plants the link.
    const forced = try c.run(&.{ "mox", "apply", "--overwrite", live });
    try std.testing.expectEqual(@as(u8, 0), forced.rc);
    try std.testing.expect(isSymlink(io, live));
    var buf: [512]u8 = undefined;
    const n = try Io.Dir.cwd().readLink(io, live, &buf);
    try std.testing.expectEqualStrings("/tmp/mox-drift-target-a", buf[0..n]);

    // Converges: a second apply is clean.
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
}

test "kind matrix: symlink over a directory -- mox rollback reconstructs the tree exactly" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/mylink", .data = "/tmp/mox-drift-target-a\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.mox/attributes.toml",
        .data = "[\"mylink\"]\nsymlink = true\n",
    });
    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("mylink");

    const top = try std.fs.path.join(a, &.{ live, "top.txt" });
    const sub_dir = try std.fs.path.join(a, &.{ live, "sub" });
    const nested = try std.fs.path.join(a, &.{ sub_dir, "nested.txt" });
    const nested_link = try std.fs.path.join(a, &.{ sub_dir, "link.txt" });

    try Io.Dir.cwd().createDirPath(io, sub_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = top, .data = "top content\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = nested, .data = "nested content\n" });
    try chmod(io, a, nested, 0o640);
    try Io.Dir.cwd().symLink(io, "/tmp/somewhere-else", nested_link, .{});

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply", "--overwrite", live })).rc);
    try std.testing.expect(isSymlink(io, live));

    const snaps = try std.fs.path.join(a, &.{ c.state, "snapshots" });
    const ids = try mox.apply.snapshot.list(a, io, snaps);
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    const listed = try c.run(&.{ "mox", "snapshot", "list" });
    try std.testing.expectEqual(@as(u8, 0), listed.rc);
    try std.testing.expect(std.mem.indexOf(u8, listed.out, ids[0]) != null);

    // The link must go so rollback recreates a real directory at the same path.
    try Io.Dir.cwd().deleteFile(io, live);
    const r = try c.run(&.{ "mox", "rollback", ids[0] });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    try std.testing.expect(!isSymlink(io, live));
    try std.testing.expectEqualStrings("top content\n", try read(io, a, top));
    try std.testing.expectEqualStrings("nested content\n", try read(io, a, nested));
    try std.testing.expectEqual(@as(u32, 0o640), try modeOf(io, nested));
    var buf: [512]u8 = undefined;
    const n = try Io.Dir.cwd().readLink(io, nested_link, &buf);
    try std.testing.expectEqualStrings("/tmp/somewhere-else", buf[0..n]);
}

test "kind matrix: symlink over a directory -- an unsnapshottable descendant refuses, directory untouched" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/mylink", .data = "/tmp/mox-drift-target-a\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.mox/attributes.toml",
        .data = "[\"mylink\"]\nsymlink = true\n",
    });
    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("mylink");

    const readable = try std.fs.path.join(a, &.{ live, "readable.txt" });
    const locked = try std.fs.path.join(a, &.{ live, "locked.txt" });
    try Io.Dir.cwd().createDirPath(io, live);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = readable, .data = "r\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = locked, .data = "cannot snapshot\n" });
    try chmod(io, a, locked, 0o000);
    defer chmod(io, a, locked, 0o644) catch {};

    // Cannot fully back up the tree (one entry is unreadable): refused
    // outright, nothing deleted, nothing written to the snapshot store.
    const r = try c.run(&.{ "mox", "apply", "--overwrite", live });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expect(!isSymlink(io, live));
    try std.testing.expect(exists(io, readable));
    try std.testing.expect(exists(io, locked));
    try std.testing.expectEqualStrings("r\n", try read(io, a, readable));

    const snaps = try std.fs.path.join(a, &.{ c.state, "snapshots" });
    const ids = try mox.apply.snapshot.list(a, io, snaps);
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "kind matrix: generated_set -- one row for the whole generator despite two drifted leaves, --overwrite converges" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen.inc",
        .data = "# mox: for id in \"data/ids.toml\" into \"id-<id.slug>.inc\"\nkey=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "[[ids]]\nslug = \"a\"\n\n[[ids]]\nslug = \"b\"\n" });
    const c = try cliSetup(a, io, &tmp);
    const gen_live = try c.homePath(".config/gen.inc");
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // Both produced leaves edited by hand: two drifted leaves, one generator.
    const leaf_a = try c.homePath(".config/id-a.inc");
    const leaf_b = try c.homePath(".config/id-b.inc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = leaf_a, .data = "hand-a\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = leaf_b, .data = "hand-b\n" });

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqualStrings("hand-a\n", try read(io, a, leaf_a));
    try std.testing.expectEqualStrings("hand-b\n", try read(io, a, leaf_b));
    // ONE row, scoped to the generator's own source path, not the leaves.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "generated set") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "gen.inc") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "id-a.inc") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "id-b.inc") == null);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, r.out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "generated set drifted") != null) lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), lines);
    // One scopeable unit (the generator itself), even though it carries two
    // drifted leaves: the safe scoped pre-fill still applies.
    try std.testing.expect(std.mem.indexOf(u8, r.out, try std.fmt.allocPrint(a, "overwrite it:  mox apply --overwrite {s}\n", .{gen_live})) != null);
    // The stats line and the drift report must not contradict each other:
    // one generator drifted, so both count it once, not once per leaf.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Applied: 0 written, 0 removed, 0 unchanged, 0 skipped, 1 drifted, 0 failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "1 drifted, left untouched") != null);

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply", "--overwrite", gen_live })).rc);
    try std.testing.expectEqualStrings("key=a\n", try read(io, a, leaf_a));
    try std.testing.expectEqualStrings("key=b\n", try read(io, a, leaf_b));
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
}

test "migration: many pre-existing first-contact files collapse into one block on a real apply" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    const names = [_][]const u8{ "f0", "f1", "f2", "f3", "f4", "f5", "f6" };
    for (names) |n| {
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "repo/src/{s}", .{n}), .data = "source\n" });
    }
    const c = try cliSetup(a, io, &tmp);
    // A fresh machine: every one of the 7 files already exists, pre-dating
    // mox entirely (no prior apply, so no applied record for any of them).
    for (names) |n| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try c.homePath(n), .data = "pre-existing\n" });
    }

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "first apply / migration") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "not written by mox") == null);

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply", "--overwrite" })).rc);
    for (names) |n| try std.testing.expectEqualStrings("source\n", try read(io, a, try c.homePath(n)));
}

test "migration: a collapsed first-contact block still scopes guidance to an edited managed file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    const names = [_][]const u8{ "f0", "f1", "f2", "f3", "f4", "f5", "f6" };
    for (names) |n| {
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "repo/src/{s}", .{n}), .data = "source\n" });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/edited.conf", .data = "source\n" });
    const c = try cliSetup(a, io, &tmp);
    // The 7 collapse into a migration block; edited.conf has no live file yet,
    // so this first apply writes it cleanly (not first-contact).
    for (names) |n| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try c.homePath(n), .data = "pre-existing\n" });
    }
    const r1 = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r1.rc);

    // Hand-edit the file mox just wrote: drift, but not first-contact.
    const edited_live = try c.homePath("edited.conf");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edited_live, .data = "hand-edited\n" });

    const r2 = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r2.rc);
    try std.testing.expect(std.mem.indexOf(u8, r2.out, "first apply / migration") != null);
    // The edited file is not swallowed by the migration collapse: it still
    // gets its own scoped overwrite pre-fill, not only the migration
    // block's unscoped one.
    try std.testing.expect(std.mem.indexOf(u8, r2.out, try std.fmt.allocPrint(a, "overwrite it:  mox apply --overwrite {s}\n", .{edited_live})) != null);
}

// -- exit codes: 0, 1, 2, asserted distinctly --

test "exit codes: 0 clean, 1 drift, 2 a genuine failure -- distinct on the same command" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/a.conf", .data = "source\n" });
    const c = try cliSetup(a, io, &tmp);

    // 0: a clean apply.
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // 1: drift, skipped and reported, nothing forced.
    const live = try c.homePath("a.conf");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "edited\n" });
    try std.testing.expectEqual(@as(u8, 1), (try c.run(&.{ "mox", "apply" })).rc);

    // Resolve the drift so the next run's rc isolates the failure below.
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply", "--overwrite", live })).rc);

    // 2: a compose failure (structural walk error) is a genuine failure, not
    // drift -- distinct from both 0 and 1.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.gitconfig", .data = "[user]\n" });
    try tmp.dir.createDirPath(io, "repo/src/.gitconfig.d");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.gitconfig.d/os=.toml", .data = "[gpg]\n" });
    try std.testing.expectEqual(@as(u8, 2), (try c.run(&.{ "mox", "apply" })).rc);
}

test "exit codes: 2 -- a failed setup script is a genuine failure, never counted as drift" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/a.conf", .data = "source\n" });
    const rel = try std.fmt.allocPrint(a, "repo/scripts/pre/00-fails{s}", .{script_ext});
    const content = if (builtin.os.tag == .windows) "exit 1\n" else "#!/bin/sh\nexit 1\n";
    try writeExecScript(io, tmp.dir, rel, content, try std.fs.path.join(a, &.{ root, rel }));

    const c = try cliSetup(a, io, &tmp);
    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    // The file still applied: a failed script does not abort the file pass,
    // and its clean write must not be misread as drift.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "DRIFT") == null);
    try std.testing.expectEqualStrings("source\n", try read(io, a, try c.homePath("a.conf")));
}

test "exit codes: 2 -- an unsnapshottable forced removal is a genuine failure, never drift" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config/app");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/keep.txt", .data = "keep\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/.mox-exact", .data = "" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // A foreign file --force cannot back up before deleting: chmod 000 makes
    // it unreadable, so the pre-delete snapshot read fails.
    const locked = try c.homePath(".config/app/locked.txt");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = locked, .data = "cannot snapshot\n" });
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..locked.len], locked);
    zbuf[locked.len] = 0;
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(@ptrCast(&zbuf), 0));
    defer _ = std.c.chmod(@ptrCast(&zbuf), 0o644);

    const r = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "UNSNAPSHOTTABLE") != null);
    try std.testing.expect(exists(io, locked));
}

// -- status and apply agree on the drift set --

test "status and apply agree on the drift set for the same tree" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/a.conf", .data = "source\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/app.toml", .data = "# mox: own tui\n[tui]\nk = 1\n" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    const whole_live = try c.homePath("a.conf");
    const owned_live = try c.homePath("app.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = whole_live, .data = "edited\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = owned_live, .data = "[tui]\nk = 9\n" });

    const ar = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), ar.rc);
    const sr = try c.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 1), sr.rc);

    // Every path apply reports as drifted, status flags as a problem too
    // (DRIFT/OUTDATED/MISSING all count against status's exit code).
    try std.testing.expect(std.mem.indexOf(u8, ar.out, "a.conf") != null);
    try std.testing.expect(std.mem.indexOf(u8, sr.out, "a.conf") != null);
    try std.testing.expect(std.mem.indexOf(u8, ar.out, "app.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, sr.out, "app.toml") != null);

    // The shared renderer's own rows -- one per drifted unit -- are byte-
    // identical between the two commands: same paths, same "what drifted",
    // same overwrite/keep guidance, same order. (Apply's stats line above the
    // rows and status's per-file table above ITS rows legitimately differ;
    // only the renderer's own output has to agree.)
    try std.testing.expectEqualStrings(try driftRows(a, ar.out), try driftRows(a, sr.out));

    // Resolving every unit apply named leaves both commands clean.
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply", "--overwrite" })).rc);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "status" })).rc);
}

/// Every line of the shared drift-report renderer's own unit table (each
/// line ends in the row's fixed "keep: mox commit" suffix), newline-joined in
/// the order they appeared -- used to compare `apply` and `status` renderer
/// output directly, ignoring the different, legitimately caller-specific
/// content each prints around it.
fn driftRows(a: std.mem.Allocator, out: []const u8) ![]const u8 {
    var rows: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, "keep: mox commit")) {
            try rows.appendSlice(a, line);
            try rows.append(a, '\n');
        }
    }
    return rows.toOwnedSlice(a);
}
