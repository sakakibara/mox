//! The single-writer lock: an exclusive, non-blocking kernel lock on
//! `<state>/mox.lock`, which the system releases when its holder dies.
//!
//! The file is never unlinked. Its holder line, `<pid> <start> <boot id>
//! <command>`, says who holds it; it is written once the lock is taken and
//! truncated away on release, so the file is never empty while locked.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const is_windows = builtin.os.tag == .windows;
pub const lock_name = "mox.lock";

pub const Pid = u32;

pub fn selfPid() Pid {
    if (is_windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

pub const Lock = struct {
    io: Io,
    file: Io.File,
    path: []const u8,

    /// Empty the holder line through the locked handle, then unlock.
    pub fn release(self: Lock) void {
        self.file.setLength(self.io, 0) catch {};
        unlockFile(self.io, self.file);
        self.file.close(self.io);
    }
};

pub const Held = struct {
    pid: Pid,
    command: []const u8,
    path: []const u8,
};

pub const Outcome = union(enum) {
    acquired: Lock,
    held: Held,
    /// The filesystem cannot lock: the errno, by name.
    unsupported: []const u8,
};

/// A holder line, parsed.
pub const Holder = struct {
    pid: Pid,
    start: []const u8,
    boot: []const u8,
    command: []const u8,
};

pub fn parseHolder(content: []const u8) ?Holder {
    const line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const line = std.mem.trimEnd(u8, content[0..line_end], " \t\r");
    var it = std.mem.splitScalar(u8, line, ' ');
    const pid = std.fmt.parseInt(Pid, it.next() orelse return null, 10) catch return null;
    const start = it.next() orelse return null;
    const boot = it.next() orelse return null;
    if (start.len == 0 or !isBootId(boot)) return null;
    return .{ .pid = pid, .start = start, .boot = boot, .command = it.rest() };
}

/// A UUID, or `boot-<seconds>`.
pub fn isBootId(s: []const u8) bool {
    if (std.mem.startsWith(u8, s, "boot-")) {
        if (s.len == "boot-".len) return false;
        for (s["boot-".len..]) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    if (s.len != 36) return false;
    for (s, 0..) |c, i| switch (i) {
        8, 13, 18, 23 => if (c != '-') return false,
        else => if (!std.ascii.isHex(c)) return false,
    };
    return true;
}

/// Take the lock under `state_dir` for `command`.
pub fn acquire(arena: std.mem.Allocator, io: Io, state_dir: []const u8, command: []const u8) !Outcome {
    const path = try std.fs.path.join(arena, &.{ state_dir, lock_name });
    Io.Dir.cwd().createDirPath(io, state_dir) catch {};
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    const got = tryLockFile(io, file) catch |e| {
        file.close(io);
        return .{ .unsupported = switch (e) {
            error.FileLocksUnsupported => "ENOTSUP",
            error.SystemResources => "ENOLCK",
            else => @errorName(e),
        } };
    };
    if (!got) {
        defer file.close(io);
        // An empty or unparseable line is a holder's that has not written
        // its line yet.
        const h = parseHolder(readAll(arena, io, file)) orelse return .{ .held = .{ .pid = 0, .command = "", .path = path } };
        return .{ .held = .{ .pid = h.pid, .command = h.command, .path = path } };
    }
    const line = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ try holderStamp(arena, io, selfPid()), command });
    file.writePositionalAll(io, line, 0) catch |e| {
        unlockFile(io, file);
        file.close(io);
        return e;
    };
    file.setLength(io, line.len) catch |e| {
        unlockFile(io, file);
        file.close(io);
        return e;
    };
    return .{ .acquired = .{ .io = io, .file = file, .path = path } };
}

/// `<pid> <start> <boot id>` for `pid`, as a holder line and a journal
/// header name a process.
pub fn holderStamp(arena: std.mem.Allocator, io: Io, pid: Pid) ![]const u8 {
    const start = processStart(arena, io, pid);
    return std.fmt.allocPrint(arena, "{d} {s} {s}", .{ pid, if (start.len > 0) start else "-", try bootId(arena, io) });
}

/// True when the process a `<pid> <start> <boot id>` stamp names still runs:
/// the same boot, a live pid, and the same start time where both are known.
pub fn stampLive(arena: std.mem.Allocator, io: Io, stamp: []const u8) bool {
    var it = std.mem.splitScalar(u8, stamp, ' ');
    const pid = std.fmt.parseInt(Pid, it.next() orelse return false, 10) catch return false;
    const start = it.next() orelse return false;
    const boot = it.next() orelse return false;
    const now_boot = bootId(arena, io) catch return true;
    if (!sameBoot(boot, now_boot)) return false;
    if (!processAlive(pid)) return false;
    const now = processStart(arena, io, pid);
    if (!startKnown(start) or !startKnown(now)) return true;
    return std.mem.eql(u8, start, now);
}

fn readAll(arena: std.mem.Allocator, io: Io, file: Io.File) []const u8 {
    var buf: [4096]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return "";
    return arena.dupe(u8, buf[0..n]) catch "";
}

fn startKnown(s: []const u8) bool {
    return s.len > 0 and !std.mem.eql(u8, s, "-");
}

/// The test seam for a filesystem that cannot lock.
pub var forced_failure: ?anyerror = null;

const windows = std.os.windows;
const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: windows.DWORD = 0,
    offset_high: windows.DWORD = 0,
    event: ?windows.HANDLE = null,
};
extern "kernel32" fn LockFileEx(h: windows.HANDLE, flags: windows.DWORD, reserved: windows.DWORD, low: windows.DWORD, high: windows.DWORD, ov: *Overlapped) callconv(.winapi) windows.BOOL;
extern "kernel32" fn UnlockFileEx(h: windows.HANDLE, reserved: windows.DWORD, low: windows.DWORD, high: windows.DWORD, ov: *Overlapped) callconv(.winapi) windows.BOOL;
const LOCKFILE_FAIL_IMMEDIATELY: windows.DWORD = 0x1;
const LOCKFILE_EXCLUSIVE_LOCK: windows.DWORD = 0x2;
/// The byte range locked on Windows, far past the holder line, so other
/// processes can still read it.
const win_lock_offset_high: windows.DWORD = 0x7fff_ffff;

fn winOverlapped() Overlapped {
    return .{ .offset_high = win_lock_offset_high };
}

fn tryLockFile(io: Io, file: Io.File) !bool {
    if (forced_failure) |e| return e;
    if (is_windows) {
        var ov = winOverlapped();
        if (LockFileEx(file.handle, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov).toBool()) return true;
        return switch (windows.GetLastError()) {
            .LOCK_VIOLATION, .IO_PENDING => false,
            .NOT_SUPPORTED => error.FileLocksUnsupported,
            else => error.Unexpected,
        };
    }
    return file.tryLock(io, .exclusive);
}

fn unlockFile(io: Io, file: Io.File) void {
    if (is_windows) {
        var ov = winOverlapped();
        _ = UnlockFileEx(file.handle, 0, 1, 0, &ov);
        return;
    }
    file.unlock(io);
}

/// The id of this boot: `/proc/sys/kernel/random/boot_id` on Linux,
/// `kern.bootsessionuuid` on macOS, `boot-<seconds>` from the tick count on
/// Windows.
pub fn bootId(arena: std.mem.Allocator, io: Io) ![]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const bytes = try Io.Dir.cwd().readFileAlloc(io, "/proc/sys/kernel/random/boot_id", arena, .limited(128));
            return std.mem.trim(u8, bytes, " \n");
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            var buf: [64]u8 = undefined;
            var len: usize = buf.len;
            if (std.c.sysctlbyname("kern.bootsessionuuid", &buf, &len, null, 0) != 0) return error.NoBootId;
            const s = std.mem.sliceTo(buf[0..len], 0);
            return arena.dupe(u8, s);
        },
        .windows => {
            const now = Io.Clock.real.now(io).toSeconds();
            return std.fmt.allocPrint(arena, "boot-{d}", .{windowsBootSeconds(now, GetTickCount64())});
        },
        else => return error.NoBootId,
    }
}

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub fn windowsBootSeconds(now_secs: i64, ticks_ms: u64) i64 {
    return now_secs - @as(i64, @intCast(@divTrunc(ticks_ms + 500, 1000)));
}

/// Two boot ids name one boot: equal, or two `boot-<seconds>` stamps at
/// most 2 seconds apart.
pub fn sameBoot(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (!std.mem.startsWith(u8, a, "boot-") or !std.mem.startsWith(u8, b, "boot-")) return false;
    const x = std.fmt.parseInt(i64, a["boot-".len..], 10) catch return false;
    const y = std.fmt.parseInt(i64, b["boot-".len..], 10) catch return false;
    return @abs(x - y) <= 2;
}

/// True only when signal 0 to `pid` succeeds; on Windows when the process
/// can be opened and has not exited.
pub fn processAlive(pid: Pid) bool {
    if (is_windows) return windowsProcessAlive(pid);
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch return false;
    return true;
}

extern "kernel32" fn OpenProcess(dwDesiredAccess: windows.DWORD, bInheritHandle: windows.BOOL, dwProcessId: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *windows.DWORD) callconv(.winapi) windows.BOOL;

fn windowsProcessAlive(pid: Pid) bool {
    const process_query_limited_information: windows.DWORD = 0x1000;
    const still_active: windows.DWORD = 259;
    const handle = OpenProcess(process_query_limited_information, .FALSE, pid) orelse return false;
    defer windows.CloseHandle(handle);
    var code: windows.DWORD = 0;
    if (!GetExitCodeProcess(handle, &code).toBool()) return false;
    return code == still_active;
}

/// The moment the process `pid` names was started, as a token with no
/// spaces, or empty where the platform exposes none or nothing answers.
pub fn processStart(arena: std.mem.Allocator, io: Io, pid: Pid) []const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const path = std.fmt.allocPrint(arena, "/proc/{d}/stat", .{pid}) catch return "";
            const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return "";
            // Field 2 may hold spaces and parentheses: count from the last
            // `)`; `starttime` is field 22, the 20th after it.
            const close = std.mem.lastIndexOfScalar(u8, content, ')') orelse return "";
            var fields = std.mem.tokenizeAny(u8, content[close + 1 ..], " \t\r\n");
            var i: usize = 0;
            while (fields.next()) |f| : (i += 1) {
                if (i == 19) return f;
            }
            return "";
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            // `kinfo_proc` opens with the `struct timeval` of its start time.
            var mib = [_]c_int{ 1, 14, 1, @intCast(pid) };
            var buf: [4096]u8 align(8) = undefined;
            var size: usize = buf.len;
            if (std.c.sysctl(&mib, mib.len, &buf, &size, null, 0) != 0) return "";
            if (size < 12) return "";
            var sec: i64 = undefined;
            var usec: i32 = undefined;
            @memcpy(std.mem.asBytes(&sec), buf[0..8]);
            @memcpy(std.mem.asBytes(&usec), buf[8..12]);
            return std.fmt.allocPrint(arena, "{d}.{d}", .{ sec, usec }) catch "";
        },
        else => return "",
    }
}

const testing = std.testing;

fn tmpState(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) ![]const u8 {
    return tmp.dir.realPathFileAlloc(io, ".", a);
}

test "lock: a held lock refuses with the holder; the file is never empty while locked and empty after" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sd = try tmpState(a, io, &tmp);

    const first = try acquire(a, io, sd, "apply");
    try testing.expect(first == .acquired);
    const line = try tmp.dir.readFileAlloc(io, lock_name, a, .limited(4096));
    try testing.expect(std.mem.endsWith(u8, line, " apply\n"));
    try testing.expect(parseHolder(line) != null);

    const second = try acquire(a, io, sd, "commit");
    try testing.expect(second == .held);
    try testing.expectEqual(selfPid(), second.held.pid);
    try testing.expectEqualStrings("apply", second.held.command);
    try testing.expectEqualStrings(line, try tmp.dir.readFileAlloc(io, lock_name, a, .limited(4096)));

    first.acquired.release();
    try testing.expectEqualStrings("", try tmp.dir.readFileAlloc(io, lock_name, a, .limited(4096)));
    const third = try acquire(a, io, sd, "commit");
    try testing.expect(third == .acquired);
    third.acquired.release();
}

test "lock: a filesystem that cannot lock fails closed, naming the errno" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sd = try tmpState(a, io, &tmp);
    for ([_]struct { anyerror, []const u8 }{ .{ error.FileLocksUnsupported, "ENOTSUP" }, .{ error.SystemResources, "ENOLCK" } }) |c| {
        forced_failure = c[0];
        defer forced_failure = null;
        const got = try acquire(a, io, sd, "apply");
        try testing.expectEqualStrings(c[1], got.unsupported);
    }
}

test "sameBoot: a Windows boot stamp matches within 2 seconds and not beyond" {
    try testing.expect(sameBoot("boot-1000", "boot-1002"));
    try testing.expect(sameBoot("boot-1002", "boot-1000"));
    try testing.expect(!sameBoot("boot-1000", "boot-1003"));
    try testing.expectEqual(@as(i64, 1000), windowsBootSeconds(1100, 100_000));
    try testing.expectEqual(@as(i64, 1000), windowsBootSeconds(1100, 99_600));
}

test "parseHolder: a holder line with a command after the boot id; a line with no boot id is none" {
    const nf = parseHolder("321 12.5 6F9619FF-8B86-D011-B42D-00C04FC964FF apply --dry-run\n").?;
    try testing.expectEqualStrings("6F9619FF-8B86-D011-B42D-00C04FC964FF", nf.boot);
    try testing.expectEqualStrings("apply --dry-run", nf.command);
    const win = parseHolder("7 - boot-1700000000 commit").?;
    try testing.expectEqualStrings("boot-1700000000", win.boot);
    try testing.expect(parseHolder("321 12.5 apply\n") == null);
    try testing.expect(parseHolder("321\n") == null);
}

test "lock: a lock file no process holds does not refuse, empty or holding the line of a holder that died" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sd = try tmpState(a, io, &tmp);
    for ([_][]const u8{ "", try std.fmt.allocPrint(a, "{s} apply\n", .{try holderStamp(a, io, selfPid())}) }) |content| {
        try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = content });
        const got = try acquire(a, io, sd, "apply");
        try testing.expect(got == .acquired);
        got.acquired.release();
    }
}
