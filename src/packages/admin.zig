//! Holding the administrator credential a step that elevates by itself needs.
//!
//! Homebrew's installer on macOS, and the Command Line Tools install that
//! comes before a first clone, elevate through `sudo`. Homebrew's installer
//! runs under `NONINTERACTIVE`, where it never prompts: it asks
//! `sudo -n` whether a credential is already cached and stops when none is.
//! So mox asks `sudo -v` on the terminal first, and keeps the timestamp
//! fresh with `sudo -n -v` for as long as the installs it covers run, since
//! one of those can outlast sudo's own timeout.

const std = @import("std");

const Io = std.Io;

/// How a step that needs administrator access can get it on this run.
pub const Elevation = enum {
    /// mox runs as root: nothing to ask.
    root,
    /// stdin is a terminal, so `sudo` can ask for the password there.
    prompt,
    /// No terminal and not root: nothing can answer a password prompt.
    unattended,
};

pub fn elevation(is_root: bool, terminal: bool) Elevation {
    if (is_root) return .root;
    return if (terminal) .prompt else .unattended;
}

/// Asks for the password on the terminal and caches the timestamp.
pub const prime_argv = [_][]const u8{ "sudo", "-v" };

/// Extends a cached timestamp without ever prompting.
pub const refresh_argv = [_][]const u8{ "sudo", "-n", "-v" };

/// Well inside sudo's default five-minute timestamp.
pub const refresh_interval_ms: i64 = 60_000;

/// One refresh of the timestamp. A test substitutes its own, so no suite
/// ever runs `sudo`.
pub const Refresh = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque, io: Io) void,
};

/// `sudo -n -v`, with every stream on the null device. Spawned directly
/// rather than through `exec.Process`: that spawn owns the process-wide
/// signal dispositions and the terminal for the call in flight on the main
/// task, and this one runs beside it. A refresh that is cancelled while it
/// waits is killed and reaped, so none outlives `Keepalive.stop`.
pub const sudo_refresh: Refresh = .{ .run = refreshSudo };

fn refreshSudo(_: ?*anyopaque, io: Io) void {
    var child = std.process.spawn(io, .{
        .argv = &refresh_argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch child.kill(io);
}

/// A task refreshing the timestamp every `interval_ms` until `stop`.
/// Inactive until `start`; `stop` is safe on an inactive one and idempotent.
/// Must not move once started: the task reads `stopping` through a pointer.
pub const Keepalive = struct {
    task: ?Io.Future(void) = null,
    io: Io = undefined,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn active(self: *const Keepalive) bool {
        return self.task != null;
    }

    /// Without a spare thread there is no keepalive, and the installs run on
    /// the timestamp `sudo -v` just cached.
    pub fn start(self: *Keepalive, io: Io, interval_ms: i64, refresh: Refresh) void {
        if (self.task != null) return;
        self.io = io;
        self.stopping.store(false, .release);
        self.task = io.concurrent(loop, .{ io, interval_ms, refresh, &self.stopping }) catch null;
    }

    pub fn stop(self: *Keepalive) void {
        if (self.task) |*t| {
            // The flag covers a cancel a refresh's own wait consumed; the
            // cancel covers the sleep.
            self.stopping.store(true, .release);
            t.cancel(self.io);
            self.task = null;
        }
    }
};

fn loop(io: Io, interval_ms: i64, refresh: Refresh, stopping: *const std.atomic.Value(bool)) void {
    while (true) {
        io.sleep(.fromMilliseconds(interval_ms), .awake) catch return;
        if (stopping.load(.acquire)) return;
        refresh.run(refresh.ctx, io);
        if (stopping.load(.acquire)) return;
    }
}

const testing = std.testing;

test "elevation: root needs nothing, a terminal can prompt, neither is unattended" {
    try testing.expectEqual(Elevation.root, elevation(true, true));
    try testing.expectEqual(Elevation.root, elevation(true, false));
    try testing.expectEqual(Elevation.prompt, elevation(false, true));
    try testing.expectEqual(Elevation.unattended, elevation(false, false));
}

const Counter = struct {
    n: std.atomic.Value(u32) = .init(0),

    fn refresh(self: *Counter) Refresh {
        return .{ .ctx = self, .run = bump };
    }

    fn bump(ctx: ?*anyopaque, _: Io) void {
        const self: *Counter = @ptrCast(@alignCast(ctx.?));
        _ = self.n.fetchAdd(1, .acq_rel);
    }
};

test "Keepalive: refreshes on its interval and stops cleanly" {
    const io = testing.io;
    var counter: Counter = .{};
    var k: Keepalive = .{};
    try testing.expect(!k.active());
    k.start(io, 5, counter.refresh());
    if (!k.active()) return error.SkipZigTest;

    const started = Io.Clock.awake.now(io);
    while (counter.n.load(.acquire) < 3) {
        if (started.durationTo(Io.Clock.awake.now(io)).toMilliseconds() > 10_000) return error.KeepaliveNeverRefreshed;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    k.stop();
    try testing.expect(!k.active());
    const after = counter.n.load(.acquire);
    try io.sleep(.fromMilliseconds(50), .awake);
    try testing.expectEqual(after, counter.n.load(.acquire));
    k.stop();
}

test "Keepalive: stop before the first interval refreshes nothing" {
    const io = testing.io;
    var counter: Counter = .{};
    var k: Keepalive = .{};
    k.start(io, refresh_interval_ms, counter.refresh());
    k.stop();
    try testing.expectEqual(@as(u32, 0), counter.n.load(.acquire));
    var idle: Keepalive = .{};
    idle.stop();
}
