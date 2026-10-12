//! Whether removing a live path would reach through a symlinked directory.
//!
//! mox removes only what it wrote inside HOME's own directory tree. Once a
//! directory between HOME and a recorded path is a symlink -- one the user
//! made, or one the tree now plants -- the recorded path names a file
//! elsewhere (a repo checkout, a shared folder), and deleting it would
//! destroy that file instead.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// The message every removal that refuses on this ground prints.
pub const reason = "left in place: a parent directory is a symlink";

/// True when `path` lies strictly below `home`.
pub fn underHome(path: []const u8, home: []const u8) bool {
    if (home.len == 0 or path.len <= home.len or !std.mem.startsWith(u8, path, home)) return false;
    return std.fs.path.isSep(path[home.len]) or std.fs.path.isSep(home[home.len - 1]);
}

/// True when removing `live_path` is refused: it lies outside `home`, or a
/// directory between `home` and it is a symlink on disk or a path in
/// `managed_links` (the live paths the tree plants as symlinks).
pub fn through(io: Io, home: []const u8, live_path: []const u8, managed_links: ?*const std.StringHashMap(void)) bool {
    if (!underHome(live_path, home)) return true;
    var i: usize = home.len;
    while (i < live_path.len) : (i += 1) {
        if (!std.fs.path.isSep(live_path[i])) continue;
        if (i == home.len or std.fs.path.isSep(live_path[i - 1])) continue;
        const dir = live_path[0..i];
        if (managed_links) |m| if (m.contains(dir)) return true;
        const st = Io.Dir.cwd().statFile(io, dir, .{ .follow_symlinks = false }) catch return false;
        if (st.kind == .sym_link) return true;
        if (builtin.os.tag == .windows and st.kind == .directory and redirected(io, dir)) return true;
    }
    return false;
}

/// True when the directory `dir` resolves somewhere other than beneath its
/// own parent: a junction or other reparse point Windows reports as a
/// directory.
fn redirected(io: Io, dir: []const u8) bool {
    var buf: [4 * std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    const parent = std.fs.path.dirname(dir) orelse return false;
    const real_dir = Io.Dir.cwd().realPathFileAlloc(io, dir, a) catch return false;
    const real_parent = Io.Dir.cwd().realPathFileAlloc(io, parent, a) catch return false;
    const expected = std.fs.path.join(a, &.{ real_parent, std.fs.path.basename(dir) }) catch return false;
    return !std.ascii.eqlIgnoreCase(real_dir, expected);
}

test "through: a symlinked or managed-link parent, or a path outside home" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const home = try std.fs.path.join(a, &.{ root, "h" });
    try tmp.dir.createDirPath(io, "h/real/sub");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.symLink(io, "../elsewhere", "h/link", .{});

    try testing.expect(!through(io, home, try std.fs.path.join(a, &.{ home, "real", "sub", "f" }), null));
    try testing.expect(!through(io, home, try std.fs.path.join(a, &.{ home, "absent", "f" }), null));
    try testing.expect(through(io, home, try std.fs.path.join(a, &.{ home, "link", "f" }), null));
    try testing.expect(through(io, home, try std.fs.path.join(a, &.{ root, "elsewhere", "f" }), null));

    var links = std.StringHashMap(void).init(a);
    try links.put(try std.fs.path.join(a, &.{ home, "real" }), {});
    try testing.expect(through(io, home, try std.fs.path.join(a, &.{ home, "real", "sub", "f" }), &links));
    try testing.expect(!through(io, home, try std.fs.path.join(a, &.{ home, "real" }), &links));
}

test "through: a directory junction is refused on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const home = try std.fs.path.join(a, &.{ root, "h" });
    try tmp.dir.createDirPath(io, "h/real");
    try tmp.dir.createDirPath(io, "elsewhere");
    const junction = try std.fs.path.join(a, &.{ home, "j" });
    const target = try std.fs.path.join(a, &.{ root, "elsewhere" });
    const res = try std.process.run(a, io, .{ .argv = &.{ "cmd.exe", "/c", "mklink", "/J", junction, target } });
    if (res.term != .exited or res.term.exited != 0) return error.SkipZigTest;

    try testing.expect(through(io, home, try std.fs.path.join(a, &.{ junction, "f" }), null));
    try testing.expect(!through(io, home, try std.fs.path.join(a, &.{ home, "real", "f" }), null));
}
