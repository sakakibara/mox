//! Single-writer lock for mutating commands.
//!
//! A mutating command (apply, commit, rollback, facts set, sync) creates `state/mox.lock`
//! exclusively before touching anything and removes it on exit. The lock
//! records `<pid> <start> <command>`, where `<start>` is the holder's process
//! start time, so a second process can report who holds it and can tell
//! whether the pid still names the same process instance. A lock left by a
//! process that no longer exists (crash, kill -9), that belongs to another
//! user, or whose pid the system has since handed to something else -- which
//! a reboot is one way of doing -- is taken over automatically; a lock held
//! by the live process that wrote it is refused.

const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");

const Io = std.Io;

pub const Lock = struct {
    io: Io,
    path: []const u8,

    pub fn release(self: Lock) void {
        Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
    }
};

/// A process id as the lock file records it: a plain integer on every platform.
/// Not `std.posix.pid_t`, which is a process HANDLE on Windows and so can be
/// neither written to nor parsed from the lock file's text format.
pub const Pid = u32;

pub const Held = struct {
    pid: Pid,
    command: []const u8,
    path: []const u8,
};

pub const Outcome = union(enum) {
    acquired: Lock,
    held: Held,
};

const lock_name = "mox.lock";
const max_takeover_attempts = 3;

/// This process's pid, in the type `acquire` expects for `self_pid`.
pub fn selfPid() Pid {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

/// Acquire the lock under `state_dir`, stamping it with `self_pid` and
/// `command`. Returns `.held` (no lock taken) when a live process already
/// holds it; a stale lock from a dead process is removed and retaken.
pub fn acquire(
    arena: std.mem.Allocator,
    io: Io,
    state_dir: []const u8,
    command: []const u8,
    self_pid: Pid,
) !Outcome {
    const path = try std.fs.path.join(arena, &.{ state_dir, lock_name });
    Io.Dir.cwd().createDirPath(io, state_dir) catch {};

    const start = processStart(arena, io, self_pid);

    var attempt: usize = 0;
    while (attempt < max_takeover_attempts) : (attempt += 1) {
        const f = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |e| switch (e) {
            error.PathAlreadyExists => {
                const existing = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch "";
                if (parseHolder(existing)) |h| {
                    if (holderLive(arena, io, h)) {
                        return .{ .held = .{ .pid = h.pid, .command = h.command, .path = path } };
                    }
                }
                // Stale, unparseable, foreign, or recycled-pid lock: drop and retry.
                Io.Dir.cwd().deleteFile(io, path) catch {};
                continue;
            },
            else => return e,
        };
        {
            defer f.close(io);
            const stamp = if (start.len > 0) start else "-";
            const body = try std.fmt.allocPrint(arena, "{d} {s} {s}\n", .{ self_pid, stamp, command });
            try f.writeStreamingAll(io, body);
        }
        return .{ .acquired = .{ .io = io, .path = path } };
    }

    // A live contender kept retaking the lock across every attempt: report it.
    const existing = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch "";
    const h = parseHolder(existing) orelse Holder{ .pid = 0, .start = "", .command = "" };
    return .{ .held = .{ .pid = h.pid, .command = h.command, .path = path } };
}

/// Acquire the lock for `command`, printing the standard "held" diagnostic to
/// stderr and returning null when it cannot be taken. On success the caller
/// owns the returned Lock and must `release()` it (typically via `defer`).
pub fn acquireForCommand(ctx: *app.Ctx, command: []const u8) !?Lock {
    switch (try acquire(ctx.alloc, ctx.io, ctx.context.?.paths.state_dir, command, selfPid())) {
        .acquired => |l| return l,
        .held => |h| {
            try ctx.err.print(
                "lock held by {d} ({s}); wait or remove {s}\n",
                .{ h.pid, h.command, h.path },
            );
            return null;
        },
    }
}

const Holder = struct {
    pid: Pid,
    start: []const u8,
    command: []const u8,
};

fn parseHolder(content: []const u8) ?Holder {
    const line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const line = content[0..line_end];
    if (line.len == 0) return null;
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse {
        const pid = std.fmt.parseInt(Pid, line, 10) catch return null;
        return .{ .pid = pid, .start = "", .command = "" };
    };
    const pid = std.fmt.parseInt(Pid, line[0..sp1], 10) catch return null;
    const rest = line[sp1 + 1 ..];
    // `<pid> <start> <command>`; a two-field `<pid> <command>` line lands here
    // with `start` holding the command and no command, which no live process's
    // start time matches, so it reads as a reclaimable lock.
    if (std.mem.indexOfScalar(u8, rest, ' ')) |sp2| {
        return .{
            .pid = pid,
            .start = rest[0..sp2],
            .command = std.mem.trim(u8, rest[sp2 + 1 ..], " \t\r"),
        };
    }
    return .{ .pid = pid, .start = std.mem.trim(u8, rest, " \t\r"), .command = "" };
}

/// True when the recorded holder is still the live process that took the lock.
/// A pid that answers is only half the question: the system hands a freed pid
/// to something else, and a reboot frees every one of them at once. The start
/// time settles it, naming the exact process instance -- known on both sides
/// and differing, the pid belongs to something that is not the holder
/// (reclaim). Where either side has no start time to compare, a live pid is
/// taken at its word.
fn holderLive(arena: std.mem.Allocator, io: Io, h: Holder) bool {
    if (!processAlive(h.pid)) return false;
    const now = processStart(arena, io, h.pid);
    if (!startKnown(h.start) or !startKnown(now)) return true;
    return std.mem.eql(u8, h.start, now);
}

fn startKnown(s: []const u8) bool {
    return s.len > 0 and !std.mem.eql(u8, s, "-");
}

/// True only when signal 0 to `pid` succeeds: the process exists and is ours to
/// signal (same user). ESRCH means the pid is dead; EPERM means it belongs to
/// another user, and this lock is under a per-user state directory, so no
/// process this user may not signal ever wrote it -- both are reclaimable.
/// (`packages/exec.zig` asks the same question of a scratch file's owner and
/// answers EPERM the other way: what it must not delete is a live process's
/// file, whoever owns that process.) On Windows the equivalent is opening the
/// process and asking whether it is still running.
fn processAlive(pid: Pid) bool {
    if (builtin.os.tag == .windows) return windowsProcessAlive(pid);
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch return false;
    return true;
}

const windows = std.os.windows;

/// Not bound by `std.os.windows`, so declared here.
extern "kernel32" fn OpenProcess(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwProcessId: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// A pid that cannot be opened is gone (or belongs to another user, which for
/// this per-user lock is equally reclaimable). An openable pid may still be a
/// terminated process whose handle someone holds, so its exit code decides:
/// only STILL_ACTIVE counts as live.
fn windowsProcessAlive(pid: Pid) bool {
    const process_query_limited_information: windows.DWORD = 0x1000;
    const still_active: windows.DWORD = 259;

    const handle = OpenProcess(process_query_limited_information, .FALSE, pid) orelse return false;
    defer windows.CloseHandle(handle);

    var code: windows.DWORD = 0;
    if (!GetExitCodeProcess(handle, &code).toBool()) return false;
    return code == still_active;
}

/// The moment the process `pid` names was started, as a token with no spaces
/// in it. The system records it once, at fork, and never revises it, so it
/// names that one process instance for as long as it lives: a pid the system
/// has since handed to something else carries another start time, and a pid
/// from before a reboot carries one nothing live can match. Empty when this
/// platform exposes no such source, or when nothing answers to `pid`.
///
/// A wall-clock reading of the machine's own boot instant is not an
/// alternative: on Darwin `kern.boottime` is `now - uptime`, recomputed
/// whenever the calendar clock is disciplined, and measured on macOS 15 it
/// stepped from `{1785793311, 552209}` to `{1785793311, 643908}` in one
/// session with no reboot -- which a lock keyed on it reads as a machine that
/// rebooted, and a live holder is then reclaimed.
pub fn processStart(arena: std.mem.Allocator, io: Io, pid: Pid) []const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const path = std.fmt.allocPrint(arena, "/proc/{d}/stat", .{pid}) catch return "";
            const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return "";
            // Field 2 is the executable name in parentheses and may hold both
            // spaces and parentheses, so the fields after it are counted from
            // the last `)`: `starttime` is field 22, the 20th of those.
            const close = std.mem.lastIndexOfScalar(u8, content, ')') orelse return "";
            var fields = std.mem.tokenizeAny(u8, content[close + 1 ..], " \t\r\n");
            var i: usize = 0;
            while (fields.next()) |f| : (i += 1) {
                if (i == 19) return f;
            }
            return "";
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            // `kinfo_proc` opens with `extern_proc`, which opens with the
            // union `p_un` whose `__p_starttime` is a `struct timeval`: the
            // start time is the first 12 bytes of the record. Measured on
            // macOS 15 (arm64), the record is 648 bytes and the sysctl
            // refuses a buffer shorter than one; a pid nothing answers to
            // gets a length of 0 rather than an error.
            var mib = [_]c_int{ ctl_kern, kern_proc, kern_proc_pid, @intCast(pid) };
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

const ctl_kern: c_int = 1;
const kern_proc: c_int = 14;
const kern_proc_pid: c_int = 1;

const testing = std.testing;

fn stateDirAbs(alloc: std.mem.Allocator, io: Io, sub_path: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, alloc);
    return std.fs.path.join(alloc, &.{ cwd, ".zig-cache", "tmp", sub_path });
}

test "lock: acquire/release roundtrip" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    const first = try acquire(a, io, state_dir, "apply", 4242);
    try testing.expect(first == .acquired);
    // Lock file exists and records pid, start time, and command.
    const body = try Io.Dir.cwd().readFileAlloc(io, first.acquired.path, a, .limited(4096));
    try testing.expect(std.mem.startsWith(u8, body, "4242 "));
    try testing.expect(std.mem.endsWith(u8, body, " apply\n"));

    first.acquired.release();
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, first.acquired.path, .{}));

    // Re-acquire after release succeeds.
    const second = try acquire(a, io, state_dir, "apply", 4243);
    try testing.expect(second == .acquired);
    second.acquired.release();
}

test "lock: stale pid is taken over" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A pid far beyond any live process (macOS/Linux max is well under this).
    try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = "2000000000 rollback\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    const outcome = try acquire(a, io, state_dir, "apply", 4242);
    try testing.expect(outcome == .acquired);
    const body = try Io.Dir.cwd().readFileAlloc(io, outcome.acquired.path, a, .limited(4096));
    try testing.expect(std.mem.startsWith(u8, body, "4242 "));
    try testing.expect(std.mem.endsWith(u8, body, " apply\n"));
}

test "lock: a live self-held lock is refused" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    const own = selfPid();
    const start = processStart(a, io, own);
    const stamp = if (start.len > 0) start else "-";
    const line = try std.fmt.allocPrint(a, "{d} {s} rollback\n", .{ own, stamp });
    try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = line });

    const outcome = try acquire(a, io, state_dir, "apply", 4242);
    try testing.expect(outcome == .held);
    try testing.expectEqual(own, outcome.held.pid);
    try testing.expectEqualStrings("rollback", outcome.held.command);
}

test "lock: a recycled pid (start time mismatch) is reclaimed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    // The detection only applies where a start time can be read; without one,
    // a live self-pid is (correctly) indistinguishable and refused.
    if (!startKnown(processStart(a, io, selfPid()))) return;

    // Our own pid is live, but it started at a moment the lock does not
    // record, so the process that wrote the lock is gone and the system has
    // handed its pid on: reclaim.
    const own = selfPid();
    const line = try std.fmt.allocPrint(a, "{d} 1 apply\n", .{own});
    try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = line });

    const outcome = try acquire(a, io, state_dir, "commit", 4242);
    try testing.expect(outcome == .acquired);
    outcome.acquired.release();
}

test "lock: a start time the platform cannot read leaves a live pid the holder" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    // `-` is what a platform with no start time to read writes, and there the
    // live pid is the whole of what can be asked.
    const line = try std.fmt.allocPrint(a, "{d} - apply\n", .{selfPid()});
    try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = line });

    const outcome = try acquire(a, io, state_dir, "commit", 4242);
    try testing.expect(outcome == .held);
}

test "processStart: one process's start time is stable, and two differ" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const own = processStart(a, io, selfPid());
    if (!startKnown(own)) return error.SkipZigTest;
    // Read again: what the lock compares must not move under a running
    // process, however the calendar clock is disciplined beneath it.
    try testing.expectEqualStrings(own, processStart(a, io, selfPid()));

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sleep", "30" },
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const child_start = processStart(a, io, @intCast(child.id.?));
    try testing.expect(startKnown(child_start));
    try testing.expect(!std.mem.eql(u8, own, child_start));
    _ = std.posix.kill(child.id.?, .KILL) catch {};
    _ = try child.wait(io);

    // A pid no process answers to has no start time at all.
    try testing.expect(!startKnown(processStart(a, io, 2_000_000_000)));
}

test "parseHolder: three-field and two-field forms" {
    const three = parseHolder("321 12345.678 apply\n").?;
    try testing.expectEqual(@as(Pid, 321), three.pid);
    try testing.expectEqualStrings("12345.678", three.start);
    try testing.expectEqualStrings("apply", three.command);

    const two = parseHolder("321 apply\n").?;
    try testing.expectEqual(@as(Pid, 321), two.pid);
    try testing.expectEqualStrings("apply", two.start);
    try testing.expectEqualStrings("", two.command);
}
