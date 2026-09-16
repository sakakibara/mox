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
    term: std.posix.Sigaction,
    hup: std.posix.Sigaction,

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
        std.posix.sigaction(.INT, &act, &self.int);
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
    pub fn release(_: PosixSpawnSignals) void {
        group.store(0, .release);
    }

    pub fn restore(self: PosixSpawnSignals) void {
        group.store(0, .release);
        std.posix.sigaction(.INT, &self.int, null);
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

/// The wait a spawn does. A streamed child holding the terminal is waited on
/// here rather than by `Child.wait`, which asks only for a child that ended:
/// the Ctrl-Z the terminal sends that child stops it, `wait4` then never
/// returns, and mox hangs forever with the terminal still the child's -- the
/// shell blocked on a mox that is not itself stopped, so not even `fg`
/// reaches it. Every other call keeps the ordinary wait.
pub fn waitFor(io: Io, child: *std.process.Child, tty: ?Terminal, streamed: bool) anyerror!std.process.Child.Term {
    // Every streamed child is waited for by hand, terminal or not: a child
    // that stops is invisible to a plain wait, which would then never
    // return. With a terminal the stop is a job control the user asked for;
    // without one it is a child that wanted a terminal mox cannot give it.
    if (builtin.os.tag != .windows and streamed) return waitStreamed(child, tty);
    return child.wait(io);
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

/// Whether the kill reached the child; a child already gone is not killed.
pub fn killGroupOf(id: std.process.Child.Id) bool {
    if (builtin.os.tag == .windows) return killProcess(id);
    _ = signal(-id, .KILL);
    return signal(id, .KILL);
}

/// Whether the signal was delivered. A pid nothing answers to (ESRCH) is
/// already gone; anything else is unexpected and reads the same way.
pub fn signal(pid: std.posix.pid_t, sig: std.posix.SIG) bool {
    std.posix.kill(pid, sig) catch return false;
    return true;
}
