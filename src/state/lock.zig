//! The single-writer lock: an exclusive, non-blocking kernel lock on
//! `<state>/mox.lock`, which the system releases when its holder dies.
//!
//! The file is never unlinked. Its holder line, `<pid> <start> <boot id>
//! <command>`, says who holds it; it is written once the lock is taken and
//! truncated away on release, so the file is never empty while locked.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const marker = @import("marker.zig");

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
    /// The directory is not a mox state directory; nothing was created.
    refused: []const u8,
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

/// Take the lock under `state_dir` for `command`, once the directory is
/// accepted as mox's and marked.
pub fn acquire(arena: std.mem.Allocator, io: Io, state_dir: []const u8, origin: marker.Origin, command: []const u8) !Outcome {
    const path = try std.fs.path.join(arena, &.{ state_dir, lock_name });
    switch (try marker.acceptForWrite(arena, io, state_dir, origin)) {
        .refused => |why| return .{ .refused = why },
        .accepted => {},
    }
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

/// The content of a lock file is what mox leaves in one: nothing, or one
/// holder line.
pub fn isLockContent(content: []const u8) bool {
    if (content.len == 0) return true;
    const end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    if (end + 1 < content.len) return false;
    return parseHolder(content) != null;
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
pub var forced_failure: ?Io.File.LockError = null;

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

fn tryLockFile(io: Io, file: Io.File) Io.File.LockError!bool {
    if (builtin.is_test) if (forced_failure) |e| return e;
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

/// The file in the state directory, next to `mox.lock`, that every command
/// reading the state without writing it holds shared while it reads, and
/// that every step deleting or moving generations, blobs or `v2/` itself
/// holds exclusive. It is never unlinked, moved or renamed.
pub const readers_name = "readers.lock";

/// The file next to `readers.lock` that orders the readers behind a step
/// waiting for them: a reader takes it shared until it holds the readers
/// lock, and the waiting step holds it exclusive while it waits and works,
/// so readers that keep overlapping cannot keep the readers lock from it.
/// It is never unlinked, moved or renamed.
pub const gate_name = "readers.gate";

pub const Readers = struct {
    io: Io,
    file: Io.File,
    /// A shared hold this process counts.
    counted: bool,
    /// The gate a waiting step holds with it.
    gate: ?Io.File = null,
    /// This process already held the lock exclusive when it asked: the
    /// outer hold releases it.
    nested: bool = false,
    /// Held exclusive.
    exclusive: bool = false,

    pub fn release(self: Readers) void {
        if (self.nested) return;
        if (self.exclusive) exclusive_held = false;
        unlockFile(self.io, self.file);
        self.file.close(self.io);
        if (self.gate) |g| {
            unlockFile(self.io, g);
            g.close(self.io);
        }
        if (self.counted) shared_holds -= 1;
    }
};

/// The shared holds this process has: it asks for the exclusive lock only
/// once it has released them all.
var shared_holds: usize = 0;

/// This process holds the lock exclusive: a step inside the one that took
/// it holds it already.
var exclusive_held = false;

pub const Shared = union(enum) {
    held: Readers,
    /// There is no `v2/`: nothing to hold.
    no_store,
    /// The file is missing and the directory does not let it be created:
    /// the read goes ahead without it.
    unavailable,
    failed: anyerror,
};

pub const Exclusive = union(enum) {
    held: Readers,
    /// A reader holds it.
    busy,
    /// There is no `v2/`: no reader can hold it.
    no_store,
    failed: anyerror,
};

/// How a step that must not skip says it waits for the readers, once.
pub const Wait = struct {
    ctx: *anyopaque,
    notice: *const fn (ctx: *anyopaque, path: []const u8) void,
};

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The lock file at `path`, opened for reading only, created 0600 first
/// when missing: `no_store` when the store at `store` or the lock's
/// directory is missing, `unavailable` when the directory will not take it.
fn openReaders(io: Io, path: []const u8, store: ?[]const u8) union(enum) { file: Io.File, no_store, unavailable, failed: anyerror } {
    if (store) |s| if (!exists(io, s)) return .no_store;
    if (Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false })) |f| return .{ .file = f } else |e| switch (e) {
        error.FileNotFound => {},
        else => return .{ .failed = e },
    }
    const made = Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = @import("durable.zig").privateFile() }) catch |e| return switch (e) {
        error.FileNotFound => .no_store,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => .unavailable,
        else => .{ .failed = e },
    };
    made.close(io);
    if (Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false })) |f| return .{ .file = f } else |e| return .{ .failed = e };
}

/// The gate beside the readers lock at `path`.
fn gatePath(buf: *[std.fs.max_path_bytes]u8, path: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, gate_name });
}

/// The gate beside the readers lock at `path` held as `exclusive` asks,
/// waiting; null when it is missing and cannot be created, as the readers
/// lock is then read without.
fn takeGate(io: Io, path: []const u8, store: ?[]const u8, exclusive: bool, wait: ?Wait, noticed: *bool) union(enum) { held: ?Io.File, no_store, failed: anyerror } {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const gate = gatePath(&buf, path) catch |e| return .{ .failed = e };
    const file = switch (openReaders(io, gate, store)) {
        .file => |f| f,
        .no_store => return .no_store,
        .unavailable => return .{ .held = null },
        .failed => |e| return .{ .failed = e },
    };
    if (exclusive) {
        const got = lockReaders(io, file, true, false) catch |e| {
            file.close(io);
            return .{ .failed = e };
        };
        if (got) return .{ .held = file };
        if (wait) |w| w.notice(w.ctx, path);
        noticed.* = true;
    }
    _ = lockReaders(io, file, exclusive, true) catch |e| {
        file.close(io);
        return .{ .failed = e };
    };
    return .{ .held = file };
}

fn dropGate(io: Io, gate: ?Io.File) void {
    const g = gate orelse return;
    unlockFile(io, g);
    g.close(io);
}

fn lockReaders(io: Io, file: Io.File, exclusive: bool, wait: bool) Io.File.LockError!bool {
    if (is_windows) {
        var ov = winOverlapped();
        const flags = (if (exclusive) LOCKFILE_EXCLUSIVE_LOCK else 0) | (if (wait) 0 else LOCKFILE_FAIL_IMMEDIATELY);
        if (LockFileEx(file.handle, flags, 0, 1, 0, &ov).toBool()) return true;
        return switch (windows.GetLastError()) {
            .LOCK_VIOLATION, .IO_PENDING => false,
            .NOT_SUPPORTED => error.FileLocksUnsupported,
            else => error.Unexpected,
        };
    }
    const mode: Io.File.Lock = if (exclusive) .exclusive else .shared;
    if (wait) {
        try file.lock(io, mode);
        return true;
    }
    return file.tryLock(io, mode);
}

/// Hold the readers lock at `path` shared for the store at `store`, waiting
/// while a step that deletes holds it exclusive. A store that step removed
/// is `no_store`.
pub fn holdReaders(io: Io, path: []const u8, store: []const u8) Shared {
    // A process already holding the readers lock shared passes no gate: a
    // step waiting at it waits for that very hold.
    var noticed = false;
    const gate: ?Io.File = if (shared_holds > 0) null else switch (takeGate(io, path, store, false, null, &noticed)) {
        .held => |g| g,
        .no_store => return .no_store,
        .failed => |e| return .{ .failed = e },
    };
    defer dropGate(io, gate);
    const file = switch (openReaders(io, path, store)) {
        .file => |f| f,
        .no_store => return .no_store,
        .unavailable => return .unavailable,
        .failed => |e| return .{ .failed = e },
    };
    _ = lockReaders(io, file, false, true) catch |e| {
        file.close(io);
        return .{ .failed = e };
    };
    if (!exists(io, store)) {
        unlockFile(io, file);
        file.close(io);
        return .no_store;
    }
    shared_holds += 1;
    return .{ .held = .{ .io = io, .file = file, .counted = true } };
}

pub const Mode = union(enum) {
    /// `busy` while any reader holds it.
    try_once,
    /// Wait for the readers, giving the notice once when there are any.
    wait: ?Wait,
};

/// The readers lock at `path` held exclusive for the store at `store`. A
/// step that waits takes the gate exclusive first, and holds it until it
/// releases the lock, so no reader that comes after it gets ahead. A try
/// passes no gate. A process holding the lock shared must release that
/// first.
pub fn excludeReaders(io: Io, path: []const u8, store: []const u8, mode: Mode) error{HoldingShared}!Exclusive {
    if (shared_holds > 0) return error.HoldingShared;
    if (exclusive_held) return .{ .held = .{ .io = io, .file = undefined, .counted = false, .nested = true, .exclusive = true } };
    const wait: ?Wait = switch (mode) {
        .try_once => null,
        .wait => |w| w,
    };
    var noticed = false;
    const gate: ?Io.File = switch (mode) {
        .try_once => null,
        .wait => switch (takeGate(io, path, store, true, wait, &noticed)) {
            .held => |g| g,
            .no_store => return .no_store,
            .failed => |e| return .{ .failed = e },
        },
    };
    const file = switch (openReaders(io, path, store)) {
        .file => |f| f,
        .no_store => {
            dropGate(io, gate);
            return .no_store;
        },
        .unavailable => {
            dropGate(io, gate);
            return .{ .failed = error.AccessDenied };
        },
        .failed => |e| {
            dropGate(io, gate);
            return .{ .failed = e };
        },
    };
    const got = (if (builtin.is_test and forced_exclusive_failure != null) forced_exclusive_failure.? else lockReaders(io, file, true, false)) catch |e| {
        file.close(io);
        dropGate(io, gate);
        return .{ .failed = e };
    };
    if (!got) {
        if (mode == .try_once) {
            file.close(io);
            return .busy;
        }
        if (!noticed) if (wait) |w| w.notice(w.ctx, path);
        if (builtin.is_test) if (before_readers_wait) |f| f(io, path);
        _ = lockReaders(io, file, true, true) catch |e| {
            file.close(io);
            dropGate(io, gate);
            return .{ .failed = e };
        };
    }
    exclusive_held = true;
    return .{ .held = .{ .io = io, .file = file, .counted = false, .gate = gate, .exclusive = true } };
}

pub const Failure = struct { path: []const u8, err: anyerror };

/// Why the last step that waits for the readers could not take their lock.
pub var exclusive_failure: ?Failure = null;

/// The readers lock at `path` held exclusive for a step that must not skip,
/// waiting for the readers; null when there is no store. When it cannot be
/// taken, `exclusive_failure` says why.
pub fn waitExclusive(io: Io, path: []const u8, store: []const u8, wait: ?Wait) !?Readers {
    return switch (try excludeReaders(io, path, store, .{ .wait = wait })) {
        .held => |r| r,
        .no_store => null,
        .busy => unreachable,
        .failed => |e| {
            exclusive_failure = .{ .path = path, .err = e };
            return error.ReadersLockFailed;
        },
    };
}

/// The test seam for a readers lock that cannot be taken exclusive.
pub var forced_exclusive_failure: ?Io.File.LockError = null;
/// The test seam between the notice and the wait for the readers.
pub var before_readers_wait: ?*const fn (Io, []const u8) void = null;

/// The readers lock held shared as another process holds it: outside this
/// process's count. Tests only.
pub fn foreignReader(io: Io, path: []const u8) !Readers {
    if (!builtin.is_test) @compileError("a test seam");
    const file = switch (openReaders(io, path, null)) {
        .file => |f| f,
        else => return error.NoReadersLock,
    };
    _ = try lockReaders(io, file, false, true);
    return .{ .io = io, .file = file, .counted = false };
}

/// The kernel lock on an open `mox.lock`, taken on the range another mox
/// locks, which leaves the holder line readable. Tests only.
pub fn lockAsHolder(io: Io, file: Io.File) Io.File.LockError!bool {
    if (!builtin.is_test) @compileError("a test seam");
    return tryLockFile(io, file);
}

/// Release a lock `lockAsHolder` took. Tests only.
pub fn unlockAsHolder(io: Io, file: Io.File) void {
    if (!builtin.is_test) @compileError("a test seam");
    unlockFile(io, file);
}

/// Whether any process holds the readers lock at `path`, judged as another
/// process would. Tests only.
pub fn readersHeld(io: Io, path: []const u8) bool {
    if (!builtin.is_test) @compileError("a test seam");
    const file = switch (openReaders(io, path, null)) {
        .file => |f| f,
        else => return false,
    };
    defer file.close(io);
    const free = lockReaders(io, file, true, false) catch return false;
    if (free) unlockFile(io, file);
    return !free;
}

/// The id of this boot: `/proc/sys/kernel/random/boot_id` on Linux,
/// `kern.bootsessionuuid` on macOS, `boot-<seconds>` from the tick count on
/// Windows.
pub fn bootId(arena: std.mem.Allocator, io: Io) ![]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const bytes = try readProcFile(arena, io, "/proc/sys/kernel/random/boot_id");
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

/// A procfs file read to its end. Its size reads as 0, so a positional read
/// that stops at the size reads nothing.
fn readProcFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var r = file.readerStreaming(io, &.{});
    return r.interface.allocRemaining(arena, .limited(4096)) catch |e| switch (e) {
        error.ReadFailed => return r.err.?,
        else => |x| return x,
    };
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
            const content = readProcFile(arena, io, path) catch return "";
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

test "bootId and processStart: this boot and this process are named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    try testing.expect(isBootId(try bootId(a, testing.io)));
    try testing.expect(processStart(a, testing.io, selfPid()).len > 0);
}

test "lock: a held lock refuses with the holder; the file is never empty while locked and empty after" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sd = try tmpState(a, io, &tmp);

    const first = try acquire(a, io, sd, .explicit, "apply");
    try testing.expect(first == .acquired);
    const line = try tmp.dir.readFileAlloc(io, lock_name, a, .limited(4096));
    try testing.expect(std.mem.endsWith(u8, line, " apply\n"));
    try testing.expect(parseHolder(line) != null);

    const second = try acquire(a, io, sd, .explicit, "commit");
    try testing.expect(second == .held);
    try testing.expectEqual(selfPid(), second.held.pid);
    try testing.expectEqualStrings("apply", second.held.command);
    try testing.expectEqualStrings(line, try tmp.dir.readFileAlloc(io, lock_name, a, .limited(4096)));

    first.acquired.release();
    try testing.expectEqualStrings("", try tmp.dir.readFileAlloc(io, lock_name, a, .limited(4096)));
    const third = try acquire(a, io, sd, .explicit, "commit");
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
    for ([_]struct { Io.File.LockError, []const u8 }{ .{ error.FileLocksUnsupported, "ENOTSUP" }, .{ error.SystemResources, "ENOLCK" } }) |c| {
        forced_failure = c[0];
        defer forced_failure = null;
        const got = try acquire(a, io, sd, .explicit, "apply");
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
        const got = try acquire(a, io, sd, .explicit, "apply");
        try testing.expect(got == .acquired);
        got.acquired.release();
    }
}

test "lock: a held kernel lock refuses, whatever its line holds" {
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sd = try tmpState(a, io, &tmp);
    for ([_][]const u8{ "", "not a holder\n", "2000000000 12.5 apply\n" }) |content| {
        try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = content });
        const holder = try tmp.dir.openFile(io, lock_name, .{ .mode = .read_write });
        defer holder.close(io);
        try testing.expect(try holder.tryLock(io, .exclusive));
        defer holder.unlock(io);
        const got = try acquire(a, io, sd, .explicit, "apply");
        try testing.expect(got == .held);
        try testing.expectEqual(@as(Pid, 0), got.held.pid);
    }
}

test "readers: a process asks for the exclusive lock only after releasing its shared one" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sd = try tmpState(a, io, &tmp);
    const path = try std.fs.path.join(a, &.{ sd, readers_name });
    const shared = holdReaders(io, path, sd).held;
    try testing.expectError(error.HoldingShared, excludeReaders(io, path, sd, .try_once));
    try testing.expectError(error.HoldingShared, waitExclusive(io, path, sd, null));
    shared.release();
    const excl = (try waitExclusive(io, path, sd, null)).?;
    try testing.expect(readersHeld(io, path));
    excl.release();
    try testing.expect(!readersHeld(io, path));
}
