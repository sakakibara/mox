//! The one way mox removes or replaces a path in HOME.
//!
//! Every sweep, prune and replacement goes through `remove`: it refuses a
//! path outside HOME or behind a symlinked directory, takes the snapshot
//! that lets `mox rollback` recover the path, deletes it, and reports a
//! per-file outcome. It never returns an error that would abort the run: a
//! failure is that one file's.

const std = @import("std");
const Io = std.Io;
const parent_link = @import("parent_link.zig");
const snapshot = @import("snapshot.zig");
const write = @import("write.zig");
const applied = @import("applied.zig");
const state = @import("../state/root.zig");

pub const Ctx = struct {
    home: []const u8,
    /// The run's draft: it keeps what is removed, and a link mox planted is
    /// noted as one.
    st: *state.Draft,
    /// Live paths the tree plants as symlinks: nothing below one is removed.
    links: ?*const std.StringHashMap(void) = null,
    /// Report what would happen, and touch nothing.
    dry_run: bool = false,
    /// The bytes the caller read and judged: once the snapshot is taken the
    /// file must still hold exactly these, or it is left as `changed`.
    expect: ?[]const u8 = null,
};

/// What is at the live path and how it is kept for rollback.
pub const Snap = union(enum) {
    /// A file: these bytes are what it holds, kept as `Draft.keepPrior`
    /// keeps them.
    file: []const u8,
    /// A file whose copy the caller judged before it forgot the records
    /// that say how to keep it.
    copy: state.Copy,
    /// A symlink to this target.
    link: []const u8,
    /// A directory, snapshotted whole.
    tree,
    /// A directory or file the caller has already snapshotted.
    taken_tree,
    taken_file,
    /// A special file with no bytes to keep.
    special,
};

pub const Outcome = union(enum) {
    /// Removed (or, under `dry_run`, would be).
    removed,
    /// Left in place on purpose; the reason says why.
    left: []const u8,
    /// Could not be removed; the reason says why. The file is untouched.
    failed: []const u8,
    /// Changed after the caller read it: left, since its snapshot holds the
    /// older bytes.
    changed,
};

/// Remove `live_path`, snapshot first.
pub fn remove(arena: std.mem.Allocator, io: Io, c: Ctx, live_path: []const u8, snap: Snap) Outcome {
    if (parent_link.through(io, c.home, live_path, c.links)) return .{ .left = parent_link.reason };
    if (c.dry_run) return .removed;
    const saved: anyerror!void = switch (snap) {
        .file => |bytes| c.st.keepPrior(c.home, live_path, bytes, .gone),
        .copy => |cp| c.st.keepCopy(c.home, live_path, cp, .gone),
        .link => |target| c.st.saveSymlink(c.home, live_path, target),
        .tree => snapshot.saveTree(arena, io, c.st, c.home, live_path),
        .taken_tree, .taken_file, .special => {},
    };
    saved catch |e| return .{ .failed = reasonOf(arena, "snapshot failed, not removing", e) };
    if (snap == .link) notePlanted(c, live_path, snap.link) catch |e|
        return .{ .failed = reasonOf(arena, "snapshot failed, not removing", e) };
    // The snapshot took time: the directories above may have moved since.
    if (parent_link.through(io, c.home, live_path, c.links)) return .{ .left = parent_link.reason };
    if (c.expect) |want| if (!holds(arena, io, live_path, want)) return .changed;
    // A file, link or directory must still be what was snapshotted, read
    // without following a link.
    switch (snap) {
        .file, .copy, .taken_file => switch (applied.inspectSymSite(io, arena, live_path)) {
            .symlink, .directory => return .changed,
            .absent, .other => {},
        },
        .link => |target| switch (applied.inspectSymSite(io, arena, live_path)) {
            .symlink => |now| if (!applied.sameSymlinkTarget(now, target)) return .changed,
            else => return .changed,
        },
        .tree, .taken_tree => if (applied.inspectSymSite(io, arena, live_path) != .directory) return .changed,
        else => {},
    }
    const deleted: anyerror!void = switch (snap) {
        .tree, .taken_tree => Io.Dir.cwd().deleteTree(io, live_path),
        else => Io.Dir.cwd().deleteFile(io, live_path),
    };
    deleted catch |e| return .{ .failed = reasonOf(arena, "could not remove", e) };
    return .removed;
}

fn notePlanted(c: Ctx, live_path: []const u8, target: []const u8) !void {
    const rec = c.st.readSymlinkRecord(live_path) orelse return;
    if (applied.sameSymlinkTarget(rec.target, target)) try c.st.notePlanted(c.home, live_path, target, rec.part);
}

fn holds(arena: std.mem.Allocator, io: Io, live_path: []const u8, want: []const u8) bool {
    if (applied.inspectSymSite(io, arena, live_path) != .other) return false;
    if (write.guardLiveRead(io, live_path) != .readable) return false;
    const now = Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(64 * 1024 * 1024)) catch return false;
    return std.mem.eql(u8, now, want);
}

fn reasonOf(arena: std.mem.Allocator, what: []const u8, e: anyerror) []const u8 {
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ what, @errorName(e) }) catch what;
}

test "remove: a path behind a symlinked directory is left in place, and a failure is the file's" {
    const builtin = @import("builtin");
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
    try tmp.dir.createDirPath(io, "h/real");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/f", .data = "x\n" });
    try tmp.dir.symLink(io, "../elsewhere", "h/link", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "h/real/f", .data = "y\n" });
    const st = try state.draft.testDraft(a, io, try std.fs.path.join(a, &.{ root, "state" }));
    const c: Ctx = .{ .home = home, .st = st };

    const through = remove(a, io, c, try std.fs.path.join(a, &.{ home, "link", "f" }), .{ .file = "x\n" });
    try testing.expect(through == .left);
    try testing.expectEqualStrings("x\n", try tmp.dir.readFileAlloc(io, "elsewhere/f", a, .limited(64)));

    const gone = remove(a, io, c, try std.fs.path.join(a, &.{ home, "real", "missing" }), .taken_file);
    try testing.expect(gone == .failed);

    try testing.expect(remove(a, io, c, try std.fs.path.join(a, &.{ home, "real", "f" }), .{ .file = "y\n" }) == .removed);

    // A link that points elsewhere than was judged is left as changed.
    try tmp.dir.symLink(io, "../elsewhere/f", "h/real/l", .{});
    try testing.expect(remove(a, io, c, try std.fs.path.join(a, &.{ home, "real", "l" }), .{ .link = "../other" }) == .changed);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.readLink(io, "h/real/l", &buf);
    try testing.expectEqualStrings("../elsewhere/f", buf[0..n]);

    // A file judged as a file that is a link by the time it is removed is
    // left as changed, link and target both.
    try tmp.dir.symLink(io, try std.fs.path.join(a, &.{ root, "elsewhere", "f" }), "h/real/fl", .{});
    try testing.expect(remove(a, io, c, try std.fs.path.join(a, &.{ home, "real", "fl" }), .{ .file = "x\n" }) == .changed);
    try testing.expectEqualStrings("x\n", try tmp.dir.readFileAlloc(io, "elsewhere/f", a, .limited(64)));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "h/real/f", .{}));
}
