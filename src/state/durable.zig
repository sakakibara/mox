//! Durable writes for the state store: fsync that reaches the drive, a
//! write-then-rename that survives a crash, and a rename that never
//! replaces what is already there.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const is_windows = builtin.os.tag == .windows;
const is_darwin = builtin.os.tag.isDarwin();

/// Flush `file` to the drive: `F_FULLFSYNC` on macOS, whose `fsync` stops at
/// the drive's cache, a plain sync elsewhere. A test build stops at the
/// cache: no test can observe the flush, and it costs one per write.
pub fn syncFile(io: Io, file: Io.File) !void {
    if (is_darwin and !builtin.is_test) {
        if (std.c.fcntl(file.handle, std.c.F.FULLFSYNC) == 0) return;
    }
    try file.sync(io);
}

/// Flush the directory entry list of `dir_path`, so a rename into it is
/// durable. Windows has no directory fsync; its renames write through.
pub fn syncDir(io: Io, dir_path: []const u8) !void {
    if (builtin.is_test) if (synced) |log| log.append(std.testing.allocator, std.testing.allocator.dupe(u8, dir_path) catch unreachable) catch unreachable;
    if (is_windows) return;
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const f: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try syncFile(io, f);
}

/// The test seam that records every directory `syncDir` flushes.
pub var synced: ?*std.ArrayList([]const u8) = null;

var temp_counter: std.atomic.Value(u32) = .init(0);

/// Write `bytes` to `path` as a temp file in the same directory, flushed,
/// then renamed into place, then the directory flushed. Mode 0600.
pub fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buf, "{s}{c}.tmp-{d}-{d}", .{ dir_path, std.fs.path.sep, pid(), temp_counter.fetchAdd(1, .monotonic) });
    {
        const f = try Io.Dir.cwd().createFile(io, tmp, .{ .exclusive = true, .permissions = privateFile() });
        errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        try syncFile(io, f);
    }
    errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try renameReplace(io, tmp, path);
    try syncDir(io, dir_path);
}

pub fn privateFile() Io.File.Permissions {
    return if (Io.File.Permissions.has_executable_bit) .fromMode(0o600) else .default_file;
}

pub fn privateDir() Io.File.Permissions {
    return if (Io.File.Permissions.has_executable_bit) .fromMode(0o700) else .default_dir;
}

/// Create `path` and its parents, 0700, flushing the parent of each one
/// created so its entry is durable.
pub fn makeDir(io: Io, path: []const u8) !void {
    if (Io.Dir.cwd().access(io, path, .{})) |_| return else |_| {}
    const parent = std.fs.path.dirname(path);
    if (parent) |p| try makeDir(io, p);
    Io.Dir.cwd().createDir(io, path, privateDir()) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        else => return e,
    };
    if (parent) |p| try syncDir(io, p);
}

fn pid() u32 {
    if (is_windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

extern "kernel32" fn MoveFileExW(existing: [*:0]const u16, new: ?[*:0]const u16, flags: u32) callconv(.winapi) std.os.windows.BOOL;
const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
const MOVEFILE_WRITE_THROUGH: u32 = 0x8;

fn renameReplace(io: Io, old: []const u8, new: []const u8) !void {
    if (is_windows) return moveWindows(old, new, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    try Io.Dir.rename(Io.Dir.cwd(), old, Io.Dir.cwd(), new, io);
}

fn moveWindows(old: []const u8, new: []const u8, flags: u32) !void {
    var arena_buf: [4 * std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const a = fba.allocator();
    const old_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, old);
    const new_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, new);
    if (MoveFileExW(old_w, new_w, flags).toBool()) return;
    return switch (std.os.windows.GetLastError()) {
        .ALREADY_EXISTS, .FILE_EXISTS => error.PathAlreadyExists,
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .NOT_SAME_DEVICE => error.CrossDevice,
        else => error.Unexpected,
    };
}

extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;
const RENAME_EXCL: c_uint = 0x4;

pub const NoReplaceError = error{ PathAlreadyExists, FileNotFound, CrossDevice, NoReplaceUnsupported, NameTooLong, Unexpected };

/// Rename `old` to `new`, failing with `PathAlreadyExists` rather than
/// replacing anything at `new`. A filesystem with no such rename fails with
/// `NoReplaceUnsupported`.
pub fn renameNoReplace(old: []const u8, new: []const u8) NoReplaceError!void {
    if (is_windows) return moveWindows(old, new, MOVEFILE_WRITE_THROUGH) catch |e| switch (e) {
        error.PathAlreadyExists, error.FileNotFound, error.CrossDevice => |x| x,
        else => error.Unexpected,
    };
    var ob: [std.fs.max_path_bytes + 1]u8 = undefined;
    var nb: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (old.len >= ob.len or new.len >= nb.len) return error.NameTooLong;
    @memcpy(ob[0..old.len], old);
    ob[old.len] = 0;
    @memcpy(nb[0..new.len], new);
    nb[new.len] = 0;
    const o: [*:0]const u8 = @ptrCast(&ob);
    const n: [*:0]const u8 = @ptrCast(&nb);
    if (is_darwin) {
        if (renamex_np(o, n, RENAME_EXCL) == 0) return;
        return switch (std.posix.errno(-1)) {
            .EXIST => error.PathAlreadyExists,
            .NOENT => error.FileNotFound,
            .XDEV => error.CrossDevice,
            .OPNOTSUPP, .INVAL => error.NoReplaceUnsupported,
            else => error.Unexpected,
        };
    }
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.renameat2(linux.AT.FDCWD, o, linux.AT.FDCWD, n, .{ .NOREPLACE = true });
        return switch (linux.errno(rc)) {
            .SUCCESS => {},
            .EXIST => error.PathAlreadyExists,
            .NOENT => error.FileNotFound,
            .XDEV => error.CrossDevice,
            .INVAL, .NOSYS => error.NoReplaceUnsupported,
            else => error.Unexpected,
        };
    }
    return error.NoReplaceUnsupported;
}

/// Move `old` to `base`, or `base-2`, `base-3`, ... when that name is taken,
/// never replacing anything. Returns the name it took.
pub fn moveAside(arena: std.mem.Allocator, old: []const u8, base: []const u8) ![]const u8 {
    var name = base;
    var n: usize = 2;
    while (true) : (n += 1) {
        renameNoReplace(old, name) catch |e| switch (e) {
            error.PathAlreadyExists => {
                name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ base, n });
                continue;
            },
            else => return e,
        };
        return name;
    }
}

test "renameNoReplace: an existing target is never replaced" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const x = try std.fs.path.join(a, &.{ root, "x" });
    const y = try std.fs.path.join(a, &.{ root, "y" });
    try tmp.dir.writeFile(io, .{ .sub_path = "x", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "y", .data = "y" });
    try std.testing.expectError(error.PathAlreadyExists, renameNoReplace(x, y));
    try std.testing.expectEqualStrings("y", try tmp.dir.readFileAlloc(io, "y", a, .limited(8)));
    const took = try moveAside(a, x, y);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}-2", .{y}), took);
    try std.testing.expectEqualStrings("x", try tmp.dir.readFileAlloc(io, "y-2", a, .limited(8)));
}

test "writeFile: replaces the target whole, 0600" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "f" });
    try writeFile(io, p, "one");
    try writeFile(io, p, "two");
    try std.testing.expectEqualStrings("two", try tmp.dir.readFileAlloc(io, "f", a, .limited(8)));
    if (Io.File.Permissions.has_executable_bit) {
        const st = try tmp.dir.statFile(io, "f", .{});
        try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
}

test "makeDir: the parent of every directory it creates is flushed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var log: std.ArrayList([]const u8) = .empty;
    defer {
        for (log.items) |p| std.testing.allocator.free(p);
        log.deinit(std.testing.allocator);
    }
    synced = &log;
    defer synced = null;
    try makeDir(io, try std.fs.path.join(a, &.{ root, "state", "v2", "pending" }));
    const want = [_][]const u8{ root, try std.fs.path.join(a, &.{ root, "state" }), try std.fs.path.join(a, &.{ root, "state", "v2" }) };
    try std.testing.expectEqual(want.len, log.items.len);
    for (want, log.items) |w, got| try std.testing.expectEqualStrings(w, got);
    try makeDir(io, try std.fs.path.join(a, &.{ root, "state", "v2", "pending" }));
    try std.testing.expectEqual(want.len, log.items.len);
}
