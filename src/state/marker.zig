//! How a state directory says it is mox's: the marker `.mox-state`, which
//! mox writes into every state directory it creates. An unmarked directory
//! holding anything but the private layer and lock files is refused before
//! anything in it is read or changed.

const std = @import("std");
const Io = std.Io;
const json = @import("json");
const dirent = @import("../source/dirent.zig");
const durable = @import("durable.zig");
const lock = @import("lock.zig");

pub const marker_name = ".mox-state";
pub const marker_text = "mox state 1\n";

pub const Kind = enum {
    /// Absent, empty, or holding only the private layer and lock files:
    /// nothing in it is mox's to lose, and a write makes it a state
    /// directory.
    fresh,
    marked,
};

pub const Acceptance = union(enum) {
    accepted: Kind,
    /// Why the directory is not used; nothing in it was read or changed.
    refused: []const u8,
};

/// Whether `state_dir` is mox's, read without creating or changing
/// anything.
pub fn accept(arena: std.mem.Allocator, io: Io, state_dir: []const u8) !Acceptance {
    const entries = dirent.sortedPath(arena, io, state_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return .{ .accepted = .fresh },
        error.NotDir => return .{ .refused = try std.fmt.allocPrint(arena, "mox: the state directory {s} is not a directory; point MOX_STATE_DIR at a dedicated directory\n", .{state_dir}) },
        error.OutOfMemory => return e,
        else => return .{ .refused = try std.fmt.allocPrint(arena, "mox: cannot read the state directory {s} ({s})\n", .{ state_dir, @errorName(e) }) },
    };
    var only_private = true;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, marker_name)) {
            if (try holdsMarker(arena, io, state_dir)) return .{ .accepted = .marked };
        }
        if (!std.mem.eql(u8, e.name, "private") and !isLockFile(e.name)) only_private = false;
    }
    if (only_private) return .{ .accepted = .fresh };
    return .{ .refused = try refusal(arena, state_dir) };
}

fn isLockFile(name: []const u8) bool {
    return std.mem.eql(u8, name, lock.lock_name) or std.mem.eql(u8, name, lock.readers_name) or std.mem.eql(u8, name, lock.gate_name);
}

/// `accept`, then for a directory accepted unmarked, the marker written:
/// what a step that writes the state does first.
pub fn acceptForWrite(arena: std.mem.Allocator, io: Io, state_dir: []const u8) !Acceptance {
    const got = try accept(arena, io, state_dir);
    switch (got) {
        .refused => {},
        .accepted => |k| if (k != .marked) try mark(arena, io, state_dir),
    }
    return got;
}

/// Write the marker, creating the state directory when it is absent.
pub fn mark(arena: std.mem.Allocator, io: Io, state_dir: []const u8) !void {
    const path = try std.fs.path.join(arena, &.{ state_dir, marker_name });
    if (try holdsMarker(arena, io, state_dir)) return;
    Io.Dir.cwd().access(io, state_dir, .{}) catch |e| switch (e) {
        error.FileNotFound => try Io.Dir.cwd().createDirPath(io, state_dir),
        else => return e,
    };
    try durable.writeFile(io, path, marker_text);
    try durable.syncDir(io, state_dir);
}

pub fn refusal(arena: std.mem.Allocator, state_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "mox: {s} is not a mox state directory: it holds no {s} marker, so mox leaves it as it is; point MOX_STATE_DIR at a dedicated directory\n", .{ state_dir, marker_name });
}

/// A regular file whose first line names a state format, `mox state <n>`.
fn holdsMarker(arena: std.mem.Allocator, io: Io, state_dir: []const u8) !bool {
    const path = try std.fs.path.join(arena, &.{ state_dir, marker_name });
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    if (st.kind != .file) return false;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return false;
    const line = bytes[0 .. std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len];
    const prefix = "mox state ";
    if (!std.mem.startsWith(u8, line, prefix) or line.len == prefix.len) return false;
    for (line[prefix.len..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Why the entry at `path` is not mox's although its name is: null when it
/// is absent, or a directory every entry of which `own` accepts, judged by
/// name and kind without following a link.
pub fn whyNotOwn(arena: std.mem.Allocator, io: Io, path: []const u8, own: *const fn (dirent.Entry) bool) !?[]const u8 {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return try std.fmt.allocPrint(arena, "could not be read: {s}", .{@errorName(err)}),
    };
    if (st.kind != .directory) return "not made by mox";
    const held = dirent.sortedPath(arena, io, path, .{ .iterate = true, .follow_symlinks = false }) catch |err|
        return try std.fmt.allocPrint(arena, "could not be read: {s}", .{@errorName(err)});
    var first: ?[]const u8 = null;
    var others: usize = 0;
    for (held) |h| {
        if (own(h)) continue;
        if (first == null) first = h.name else others += 1;
    }
    const name = first orelse return null;
    if (others == 0) return try std.fmt.allocPrint(arena, "holds {s}, which mox did not make", .{name});
    return try std.fmt.allocPrint(arena, "holds {s} and {d} more entr(ies) mox did not make", .{ name, others });
}

const testing = std.testing;

test "accept: absent, empty, private-only and lock-files-only directories are fresh, a marked one is mox's, and names alone are no evidence" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const dir = try std.fs.path.join(a, &.{ root, "s" });
    try testing.expectEqual(Kind.fresh, (try accept(a, io, dir)).accepted);
    try tmp.dir.createDirPath(io, "s/private");
    try testing.expectEqual(Kind.fresh, (try accept(a, io, dir)).accepted);
    try tmp.dir.writeFile(io, .{ .sub_path = "s/mox.lock", .data = "" });
    try testing.expectEqual(Kind.fresh, (try accept(a, io, dir)).accepted);
    for ([_][]const u8{ "s/v2/notes", "s/trash/photo" }) |p| {
        if (std.fs.path.dirname(p)) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "x\n" });
    }
    try testing.expect((try accept(a, io, dir)) == .refused);
    try tmp.dir.writeFile(io, .{ .sub_path = "s/mox.lock", .data = "123 - 00000000-0000-0000-0000-000000000000 apply\n" });
    try testing.expect((try accept(a, io, dir)) == .refused);
    try tmp.dir.writeFile(io, .{ .sub_path = "s/mox.lock", .data = "" });
    try testing.expect((try accept(a, io, dir)) == .refused);
    try tmp.dir.deleteFile(io, "s/mox.lock");
    try tmp.dir.writeFile(io, .{ .sub_path = "s/" ++ marker_name, .data = "not a marker\n" });
    try testing.expect((try accept(a, io, dir)) == .refused);
    try tmp.dir.deleteFile(io, "s/" ++ marker_name);
    try mark(a, io, dir);
    try testing.expectEqual(Kind.marked, (try accept(a, io, dir)).accepted);
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "" });
    try testing.expect((try accept(a, io, try std.fs.path.join(a, &.{ root, "f" }))) == .refused);
}
