//! Job control: the process group, the controlling terminal, and the signals
//! that end a run, for every child mox spawns and waits on itself.
//!
//! A child leads its own process group, so a bound reaches what the child
//! started and not the child alone. A child that inherits the terminal is
//! handed it for its run, the way a shell hands it to a foreground job, so
//! it can prompt and so Ctrl-C reaches it. A child that was not handed the
//! terminal is never the foreground group, so mox handles the terminal
//! signals for the length of the call and takes the child's group with it.
//!
//! Windows has neither process groups nor these signals: a bound there
//! terminates the direct child, and nothing else here does anything.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

const windows = std.os.windows;
// std has no wrapper for TerminateProcess; declare the one we need to bound a
// child on Windows, where there is no signal to send it.
extern "kernel32" fn TerminateProcess(hProcess: windows.HANDLE, uExitCode: windows.UINT) callconv(.winapi) windows.BOOL;

/// Forcibly end the process `id` names. Operates on a COPY of the OS
/// handle/pid, never the shared Child, so it races safely alongside
/// `child.wait` (which reaps). POSIX sends SIGKILL; Windows forcibly
/// terminates via TerminateProcess. Returns whether the kill reached a
/// process: one already gone is not killed.
pub fn killProcess(id: std.process.Child.Id) bool {
    if (builtin.os.tag == .windows) {
        return TerminateProcess(id, 1).toBool();
    } else {
        std.posix.kill(id, .KILL) catch return false;
        return true;
    }
}

/// Every child leads its own process group everywhere that has one;
/// Windows has no groups, so its kill reaches the direct child only.
pub const own_group: ?std.posix.pid_t = if (builtin.os.tag == .windows) null else 0;

/// The terminal signals handled for as long as a child of this process is
/// running, so that one ending mox ends the child's group with it. A child
/// that was not handed the terminal is never the foreground group, so a
/// Ctrl-C is delivered to mox's group alone: without this, mox dies and a
/// `brew list` or a plugin's `list` runs on with init for a parent, still
/// holding whatever manager lock it took. The handler kills the group and
/// then dies of the signal under its default disposition, so mox ends
/// exactly as it would have with no handler at all.
///
/// A streamed child that was handed the terminal is the foreground group
/// instead, so a Ctrl-C goes to it and never here: that run ends through
/// `dieOfInterrupt` once the child is reaped. The two are one death path,
/// not two -- a signal that does reach mox while the child holds the
/// terminal (an explicit `kill`) ends mox inside the handler, before the
/// wait `dieOfInterrupt` follows can return.
///
/// The four handled are the terminal's own ways of ending a process: INT
/// (Ctrl-C), QUIT (Ctrl-backslash), HUP (the terminal itself going away) and TERM.
/// Each is delivered to mox's group alone whenever the child does not hold
/// the terminal, so each must take the child's group with it.
///
/// An instance saves whatever group was held when it was installed and puts
/// that back, so one live call inside another leaves the outer call's child
/// still reachable rather than disarmed. Nothing nests today; the saving is
/// what makes that a property rather than a coincidence.
///
/// Windows has neither process groups nor these signals.
pub const SpawnSignals = if (builtin.os.tag == .windows) NoSpawnSignals else PosixSpawnSignals;

pub const NoSpawnSignals = struct {
    pub fn install() NoSpawnSignals {
        return .{};
    }
    pub fn hold(_: NoSpawnSignals, _: std.process.Child.Id) void {}
    pub fn release(_: NoSpawnSignals) void {}
    pub fn restore(_: NoSpawnSignals) void {}
};

pub const PosixSpawnSignals = struct {
    /// The group the handler kills, or 0 between calls. A handler may read no
    /// other state of this file: an atomic and `kill` are what it is allowed.
    pub var group: std.atomic.Value(i32) = .init(0);
    /// What the handler puts back before re-raising. Built here because
    /// building it is not something a handler may do.
    var default: std.posix.Sigaction = undefined;

    int: std.posix.Sigaction,
    quit: std.posix.Sigaction,
    term: std.posix.Sigaction,
    hup: std.posix.Sigaction,
    /// The group this instance found held, put back when it is done with it.
    saved: i32,

    pub fn install() PosixSpawnSignals {
        default = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = &onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var self: PosixSpawnSignals = undefined;
        self.saved = group.load(.acquire);
        std.posix.sigaction(.INT, &act, &self.int);
        std.posix.sigaction(.QUIT, &act, &self.quit);
        std.posix.sigaction(.TERM, &act, &self.term);
        std.posix.sigaction(.HUP, &act, &self.hup);
        return self;
    }

    pub fn hold(_: PosixSpawnSignals, id: std.process.Child.Id) void {
        group.store(id, .release);
    }

    /// Let the group go the moment it is reaped, so a signal arriving in the
    /// window before the dispositions are restored cannot reach a pid the
    /// system has already handed to someone else.
    pub fn release(self: PosixSpawnSignals) void {
        group.store(self.saved, .release);
    }

    pub fn restore(self: PosixSpawnSignals) void {
        group.store(self.saved, .release);
        std.posix.sigaction(.INT, &self.int, null);
        std.posix.sigaction(.QUIT, &self.quit, null);
        std.posix.sigaction(.TERM, &self.term, null);
        std.posix.sigaction(.HUP, &self.hup, null);
    }

    pub fn onSignal(sig: std.posix.SIG) callconv(.c) void {
        killHeldGroup();
        _ = std.c.sigaction(sig, &default, null);
        _ = std.c.raise(sig);
    }

    /// The reach of `onSignal`, apart from the death that follows it. The
    /// group is interrupted first, so a manager mid-transaction can unwind,
    /// and killed a moment later, because mox is about to stop existing and
    /// nothing would reap what it left. Both calls and the wait between
    /// them are safe to make from a handler.
    pub fn killHeldGroup() void {
        const pgid = group.load(.acquire);
        if (pgid <= 0) return;
        _ = std.c.kill(-pgid, .INT);
        var pause: std.posix.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&pause, null);
        _ = std.c.kill(-pgid, .KILL);
    }
};

/// The controlling terminal, handed to a streamed child for its run and
/// taken back once it is reaped. Handed over only when stdin is a terminal
/// that mox's own group holds: a mox run in the background must not take
/// it from the job that has it, and a mox without one has nothing to hand.
/// Windows has no job control, so there it is nothing at all.
pub const Terminal = if (builtin.os.tag == .windows) NoTerminal else PosixTerminal;

pub const NoTerminal = struct {
    pub fn handTo(_: std.process.Child.Id) ?NoTerminal {
        return null;
    }
    pub fn takeBack(_: NoTerminal) void {}
};

pub const PosixTerminal = struct {
    owner: std.posix.pid_t,

    pub fn handTo(pgid: std.posix.pid_t) ?PosixTerminal {
        const fd = std.posix.STDIN_FILENO;
        if (std.c.isatty(fd) == 0) return null;
        const owner = libc.tcgetpgrp(fd);
        if (owner < 0 or owner != libc.getpgrp()) return null;
        if (!setForeground(fd, pgid)) return null;
        return .{ .owner = owner };
    }

    pub fn takeBack(self: PosixTerminal) void {
        _ = setForeground(std.posix.STDIN_FILENO, self.owner);
    }

    /// `tcsetpgrp` with SIGTTOU ignored for its duration: the call from a
    /// background group -- which mox is in while the child has the
    /// terminal -- stops the caller otherwise.
    pub fn setForeground(fd: std.posix.fd_t, pgid: std.posix.pid_t) bool {
        const ignore: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.TTOU, &ignore, &previous);
        defer std.posix.sigaction(.TTOU, &previous, null);
        return libc.tcsetpgrp(fd, pgid) == 0;
    }
};

/// What `std.c` leaves undeclared of the job-control calls.
pub const libc = struct {
    pub extern "c" fn getpgrp() std.c.pid_t;
    pub extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;
    pub extern "c" fn tcsetpgrp(fd: std.c.fd_t, pgrp: std.c.pid_t) c_int;
};

/// End this process the way the Ctrl-C the user pressed would have, had
/// the terminal delivered it here: by SIGINT under its default disposition,
/// so the shell reports an interrupt and a caller's own SIGINT handling
/// sees one. Reached only where a terminal was handed over, which is never
/// on Windows.
pub fn dieOfInterrupt() noreturn {
    if (builtin.os.tag != .windows) {
        const default: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &default, null);
        std.posix.raise(.INT) catch {};
    }
    std.process.exit(130);
}

/// The wait a spawn does. Every child is waited on here rather than by
/// `Child.wait`, which asks only for a child that ended: a child that stops
/// is invisible to it, so the wait never returns. A streamed child holding
/// the terminal stops on Ctrl-Z, and mox would hang with the terminal still
/// the child's -- the shell blocked on a mox that is not itself stopped, so
/// not even `fg` reaches it. A child with no terminal stops the moment it
/// reads one (a `sudo` behind a query, a check hook in a background group),
/// and there is nothing to resume it at all.
pub fn waitFor(io: Io, child: *std.process.Child, tty: ?Terminal) anyerror!std.process.Child.Term {
    // Every child is waited for by hand, streamed or captured, terminal or
    // not: a child that stops is invisible to a plain wait, which asks only
    // for one that ended, and the wait would then never return. With a
    // terminal the stop is a job control the user asked for; without one it
    // is a child that wanted a terminal mox cannot give it. A captured child
    // never has one to be given, so a `sudo` behind a query stops there just
    // as surely, and a bound the user disabled would leave it stopped
    // forever.
    if (builtin.os.tag == .windows) return child.wait(io);
    // Whatever the caller piped is closed here, since the hand wait consumes
    // the status itself and never reaches `Child.wait`'s own cleanup.
    defer closePipes(io, child);
    return waitStreamed(child, tty);
}

/// Close what `spawn` opened on mox's side and clear it, the way `Child.wait`
/// does as it reaps. A stream the caller asked to inherit has no handle here
/// and is not touched.
fn closePipes(io: Io, child: *std.process.Child) void {
    for ([_]*?Io.File{ &child.stdin, &child.stdout, &child.stderr }) |slot| {
        if (slot.*) |f| {
            f.close(io);
            slot.* = null;
        }
    }
}

/// Wait for a streamed child, answering a stop the
/// way a shell answers one: the terminal comes back, mox stops itself so the
/// shell regains control of its own job, and once mox is continued the
/// terminal and a SIGCONT go back to the child's group and the wait resumes.
/// The bound is unaffected: its watchdog signals the group, and this loop
/// sees the child die of that.
///
/// The status is consumed here, so `child.id` is cleared and the term built
/// from the status: the caller must not wait again. A streamed child has no
/// pipe of mox's to close, so that is the whole of what reaping owed it.
pub fn waitStreamed(child: *std.process.Child, tty: ?Terminal) error{ Unexpected, StoppedWantingTerminal }!std.process.Child.Term {
    // The child leads its own group, so its pid is that group's id.
    const id = child.id.?;
    while (true) {
        var raw: c_int = undefined;
        const rc = std.c.waitpid(id, &raw, std.c.W.UNTRACED);
        if (rc < 0) {
            if (std.c.errno(rc) == .INTR) continue;
            return error.Unexpected;
        }
        const status: u32 = @bitCast(raw);
        if (std.c.W.IFSTOPPED(status)) {
            const t = tty orelse {
                // No terminal was handed over, so nothing here can answer
                // what the child is waiting for: a `sudo` prompt in a run
                // with no terminal of its own, most often `mox apply &`.
                // Waiting on it would be waiting forever.
                _ = killGroupOf(id);
                _ = std.c.waitpid(id, &raw, 0);
                child.id = null;
                return error.StoppedWantingTerminal;
            };
            t.takeBack();
            stopSelf();
            _ = PosixTerminal.setForeground(std.posix.STDIN_FILENO, id);
            _ = signal(-id, .CONT);
            continue;
        }
        child.id = null;
        return termOfStatus(status);
    }
}

/// Stop mox itself under SIGTSTP's default disposition, the way a shell's
/// foreground job stops, and leave the disposition as it was found.
///
/// This answers a stop the way the thing above mox expects, which assumes
/// there is a job-control shell there to notice and to resume it. Under a
/// terminal with no such shell the stop is discarded (an orphaned group
/// ignores it) and the wait carries on, which is right. The one shape left
/// is a supervisor that holds the terminal without job control: there mox
/// stays stopped, and because it is stopped the bound's watchdog stops with
/// it -- a stopped process runs nothing, so no bound can outlive one.
pub fn stopSelf() void {
    const default: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TSTP, &default, &previous);
    std.posix.raise(.TSTP) catch {};
    std.posix.sigaction(.TSTP, &previous, null);
}

/// A `Term` from the raw wait status of a child this file waited on itself.
pub fn termOfStatus(status: u32) std.process.Child.Term {
    const W = std.c.W;
    if (W.IFEXITED(status)) return .{ .exited = W.EXITSTATUS(status) };
    if (W.IFSIGNALED(status)) return .{ .signal = W.TERMSIG(status) };
    if (W.IFSTOPPED(status)) return .{ .stopped = W.STOPSIG(status) };
    return .{ .unknown = status };
}

/// Shared between the waiter and the deadline task: the waiter marks the
/// child reaped, and the task marks that it fired so the result is reported
/// as a timeout. It fires only when its signal reached the child's GROUP, so
/// a child that exited at the bound is not reported as one -- a pid-directed
/// kill would not do: a zombie still answers one, and the whole point is to
/// tell a child that was killed from one that had already finished.
///
/// The reaped flag narrows the window in which a kill lands on a pid the
/// wait has already freed; it does not close it, because reading the flag
/// and sending the signal are two operations, and the same holds for the
/// straggler sweep that follows the wait.
pub const Guard = struct {
    reaped: std.atomic.Value(bool) = .init(false),
    fired: bool = false,
};

/// Bound a child by killing its whole process group once the deadline
/// passes; never reaps, since the caller's wait does. A canceled sleep (the
/// child finished first) returns without killing.
pub fn killGroupAfter(io: Io, deadline: Io.Timeout, id: std.process.Child.Id, guard: *Guard) void {
    deadline.sleep(io) catch return;
    if (guard.reaped.load(.acquire)) return;
    if (killGroupOf(id)) guard.fired = true;
}

/// Kill what a timed-out child's group still holds after the child itself
/// is reaped: a shell's `cmd &` helper ignores the interrupt by POSIX rule,
/// and the shell exiting on it cancels the watchdog that would have killed
/// the group after the grace. The group id outlives the reaped leader for
/// as long as any member does, so the kill lands on those members alone.
pub fn killStragglersOf(id: std.process.Child.Id) void {
    if (builtin.os.tag == .windows) return;
    _ = signal(-id, .KILL);
}
/// Kill the child's whole process group (its own pid when it leads none),
/// then reap it. `Child.kill` alone sends SIGTERM and waits, which a child
/// that ignores SIGTERM turns into the hang this exists to end.
pub fn killGroup(io: Io, child: *std.process.Child) void {
    if (child.id) |id| _ = killGroupOf(id);
    child.kill(io);
}

/// Whether the kill reached anything still in the child's group. The verdict
/// comes from the group-directed kill, never the pid-directed one: a reaped
/// child is a zombie until its parent waits, and a zombie still answers a
/// pid-directed signal, so that answer cannot tell a child mox killed from
/// one that had already finished. A group holds its id only while a member
/// lives, so it can.
pub fn killGroupOf(id: std.process.Child.Id) bool {
    if (builtin.os.tag == .windows) return killProcess(id);
    const reached = signal(-id, .KILL);
    // The pid too, for a child that somehow leads no group of its own.
    _ = signal(id, .KILL);
    return reached;
}

/// Whether the signal was delivered. A pid nothing answers to (ESRCH) is
/// already gone; anything else is unexpected and reads the same way.
pub fn signal(pid: std.posix.pid_t, sig: std.posix.SIG) bool {
    std.posix.kill(pid, sig) catch return false;
    return true;
}

const testing = std.testing;

/// Whether every member of `pgid` is gone within `ms`.
fn groupGone(io: Io, pgid: std.posix.pid_t, ms: i64) bool {
    const started = Io.Clock.awake.now(io);
    while (started.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < ms) {
        if (!signal(-pgid, @enumFromInt(0))) return true;
        const step: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(10), .clock = .awake } };
        step.sleep(io) catch return false;
    }
    return false;
}

test "SpawnSignals: the terminal's four ways of ending a run are all handled" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var before: [4]std.posix.Sigaction = undefined;
    const sigs = [_]std.posix.SIG{ .INT, .QUIT, .TERM, .HUP };
    for (sigs, 0..) |sig, i| std.posix.sigaction(sig, null, &before[i]);

    const signals = SpawnSignals.install();
    const handler: std.posix.Sigaction.handler_fn = &SpawnSignals.onSignal;
    for (sigs) |sig| {
        var during: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &during);
        try testing.expect(during.handler.handler == handler);
    }

    signals.restore();
    for (sigs, 0..) |sig, i| {
        var after: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &after);
        try testing.expect(after.handler.handler == before[i].handler.handler);
    }
}

test "SpawnSignals: one call inside another leaves the outer child still reachable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const outer = SpawnSignals.install();
    defer outer.restore();
    outer.hold(4242);

    const inner = SpawnSignals.install();
    inner.hold(4243);
    try testing.expectEqual(@as(i32, 4243), SpawnSignals.group.load(.acquire));
    inner.release();
    // The outer call is still running, so its group must be the one a signal
    // arriving now would reach.
    try testing.expectEqual(@as(i32, 4242), SpawnSignals.group.load(.acquire));
    inner.restore();
    try testing.expectEqual(@as(i32, 4242), SpawnSignals.group.load(.acquire));
}

test "killGroupOf: a reaped child that answers a pid signal does not count as reached" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "exit 0" },
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = own_group,
    });
    const id = child.id.?;
    // Reaped by hand, so the group is empty while the pid is still a zombie
    // for as long as nothing waits on it: a pid-directed kill succeeds here
    // and a group-directed one cannot.
    var raw: c_int = undefined;
    _ = std.c.waitpid(id, &raw, 0);
    try testing.expect(!killGroupOf(id));
    child.id = null;
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
}

test "killGroupAfter: a child reaped at the bound is neither killed nor called a timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    // The waiter sets this the moment it has the status, before it cancels
    // the watchdog: a deadline that expires in the window between the two
    // must not report a run that finished as one that was killed, nor send a
    // signal to a pid the system may already have handed on.
    var guard: Guard = .{};
    guard.reaped.store(true, .release);
    const deadline: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(5), .clock = .awake } };
    killGroupAfter(io, deadline.toDeadline(io), std.c.getpid(), &guard);
    try testing.expect(!guard.fired);
}

test "killGroupAfter: a child still running at the bound is reached and reported" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "sleep 300 & sleep 300" },
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = own_group,
    });
    const id = child.id.?;
    var guard: Guard = .{};
    const deadline: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(20), .clock = .awake } };
    killGroupAfter(io, deadline.toDeadline(io), id, &guard);
    try testing.expect(guard.fired);
    _ = try child.wait(io);
    try testing.expect(groupGone(io, id, 20_000));
}

test "waitFor: a captured child that stops is ended, not waited on" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    // A captured call never holds the terminal, so a child that reads one
    // stops with nothing able to answer it.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "kill -STOP $$" },
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = own_group,
    });
    const started = Io.Clock.awake.now(io);
    try testing.expectError(error.StoppedWantingTerminal, waitFor(io, &child, null));
    try testing.expect(started.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 10_000);
    // The pipe mox opened is closed as the wait reaps, exactly as
    // `Child.wait` would have closed it.
    try testing.expect(child.stdout == null);
}
