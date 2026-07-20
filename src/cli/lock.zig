//! Single-writer lock for mutating commands.
//!
//! A mutating command (apply, commit, rollback, facts set, sync) creates `state/mox.lock`
//! exclusively before touching anything and removes it on exit. The lock
//! records `<pid> <boot-id> <command>` so a second process can report who holds
//! it and can tell whether the pid still names the same process instance. A
//! lock left by a process that no longer exists (crash, kill -9), that belongs
//! to another user (a recycled pid), or that predates a reboot is taken over
//! automatically; a lock held by a live same-boot process is refused.

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

    const boot = bootId(arena, io);

    var attempt: usize = 0;
    while (attempt < max_takeover_attempts) : (attempt += 1) {
        const f = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |e| switch (e) {
            error.PathAlreadyExists => {
                const existing = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch "";
                if (parseHolder(existing)) |h| {
                    if (holderLive(h, boot)) {
                        return .{ .held = .{ .pid = h.pid, .command = h.command, .path = path } };
                    }
                }
                // Stale, unparseable, foreign, or pre-reboot lock: drop and retry.
                Io.Dir.cwd().deleteFile(io, path) catch {};
                continue;
            },
            else => return e,
        };
        {
            defer f.close(io);
            const stamp = if (boot.len > 0) boot else "-";
            const body = try std.fmt.allocPrint(arena, "{d} {s} {s}\n", .{ self_pid, stamp, command });
            try f.writeStreamingAll(io, body);
        }
        return .{ .acquired = .{ .io = io, .path = path } };
    }

    // A live contender kept retaking the lock across every attempt: report it.
    const existing = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch "";
    const h = parseHolder(existing) orelse Holder{ .pid = 0, .boot_id = "", .command = "" };
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
    boot_id: []const u8,
    command: []const u8,
};

fn parseHolder(content: []const u8) ?Holder {
    const line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const line = content[0..line_end];
    if (line.len == 0) return null;
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse {
        const pid = std.fmt.parseInt(Pid, line, 10) catch return null;
        return .{ .pid = pid, .boot_id = "", .command = "" };
    };
    const pid = std.fmt.parseInt(Pid, line[0..sp1], 10) catch return null;
    const rest = line[sp1 + 1 ..];
    // `<pid> <boot-id> <command>`; a legacy `<pid> <command>` lock lands here
    // with `boot_id` holding the command and no command, which reads as a
    // reclaimable pre-upgrade lock.
    if (std.mem.indexOfScalar(u8, rest, ' ')) |sp2| {
        return .{
            .pid = pid,
            .boot_id = rest[0..sp2],
            .command = std.mem.trim(u8, rest[sp2 + 1 ..], " \t\r"),
        };
    }
    return .{ .pid = pid, .boot_id = std.mem.trim(u8, rest, " \t\r"), .command = "" };
}

/// True when the recorded holder is still the live process that took the lock.
/// A boot-id that is known on both sides but differs means the machine rebooted
/// since the lock was written, so the recorded pid cannot be the original
/// holder (reclaim). Otherwise defer to the OS: only a signalable same-user
/// process counts as alive.
fn holderLive(h: Holder, current_boot: []const u8) bool {
    if (bootKnown(h.boot_id) and bootKnown(current_boot) and
        !std.mem.eql(u8, h.boot_id, current_boot)) return false;
    return processAlive(h.pid);
}

fn bootKnown(s: []const u8) bool {
    return s.len > 0 and !std.mem.eql(u8, s, "-");
}

/// True only when signal 0 to `pid` succeeds: the process exists and is ours to
/// signal (same user). ESRCH means the pid is dead; EPERM means it belongs to
/// another user and so is not this per-user lock's holder (a recycled pid) --
/// both are reclaimable. On Windows the equivalent is opening the process and
/// asking whether it is still running.
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

/// A token that is stable for the life of a boot and changes across reboots, so
/// a recorded lock from before a reboot is recognizable. Empty when the host
/// exposes no such source.
pub fn bootId(arena: std.mem.Allocator, io: Io) []const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const content = Io.Dir.cwd().readFileAlloc(io, "/proc/sys/kernel/random/boot_id", arena, .limited(256)) catch return "";
            return std.mem.trim(u8, content, " \t\r\n");
        },
        .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .openbsd, .netbsd, .dragonfly => {
            var buf: [64]u8 = undefined;
            var size: usize = buf.len;
            if (std.c.sysctlbyname("kern.boottime", &buf, &size, null, 0) != 0) return "";
            if (size == 0 or size > buf.len) return "";
            const hex = "0123456789abcdef";
            const out = arena.alloc(u8, size * 2) catch return "";
            for (buf[0..size], 0..) |b, k| {
                out[k * 2] = hex[b >> 4];
                out[k * 2 + 1] = hex[b & 0x0f];
            }
            return out;
        },
        else => return "",
    }
}

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
    // Lock file exists and records pid, boot id, and command.
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

test "lock: live self-held lock at the current boot is refused" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    const own = selfPid();
    const boot = bootId(a, io);
    const stamp = if (boot.len > 0) boot else "-";
    const line = try std.fmt.allocPrint(a, "{d} {s} rollback\n", .{ own, stamp });
    try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = line });

    const outcome = try acquire(a, io, state_dir, "apply", 4242);
    try testing.expect(outcome == .held);
    try testing.expectEqual(own, outcome.held.pid);
    try testing.expectEqualStrings("rollback", outcome.held.command);
}

test "lock: a recycled pid (boot id mismatch) is reclaimed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    // The boot-id detection only applies where a boot id is available; without
    // one, a live self-pid is (correctly) indistinguishable and refused.
    if (!bootKnown(bootId(a, io))) return;

    // Our own pid is live, but the recorded boot id is from a prior boot, so
    // the lock cannot be the process that wrote it: reclaim.
    const own = selfPid();
    const line = try std.fmt.allocPrint(a, "{d} 00000000-dead-beef-0000-000000000000 apply\n", .{own});
    try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = line });

    const outcome = try acquire(a, io, state_dir, "commit", 4242);
    try testing.expect(outcome == .acquired);
    outcome.acquired.release();
}

test "parseHolder: three-field and legacy two-field forms" {
    const three = parseHolder("321 abc-boot apply\n").?;
    try testing.expectEqual(@as(Pid, 321), three.pid);
    try testing.expectEqualStrings("abc-boot", three.boot_id);
    try testing.expectEqualStrings("apply", three.command);

    const legacy = parseHolder("321 apply\n").?;
    try testing.expectEqual(@as(Pid, 321), legacy.pid);
    try testing.expectEqualStrings("apply", legacy.boot_id);
    try testing.expectEqualStrings("", legacy.command);
}
