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
/// `dieOf` once the child is reaped. The two are one death path,
/// not two -- a signal that does reach mox while the child holds the
/// terminal (an explicit `kill`) ends mox inside the handler, before the
/// wait `dieOf` follows can return.
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
        writeStagedNote();
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

/// The one sentence a run that ends of a signal leaves behind, staged before
/// the call it describes and dropped when that call returns.
///
/// A run ended by INT, HUP, QUIT or TERM dies under the signal's default
/// disposition, and a run whose streamed child took the user's Ctrl-C dies
/// of SIGINT the same way: no `defer` runs on either, so anything mox has not
/// already said is never said. What an install was part-way through when that
/// happened is exactly what the user needs and exactly what is lost -- the
/// last line of an interrupted apply is `installing`, and nothing after it
/// says whether the package landed.
///
/// Staged as rendered bytes in a fixed buffer, because the handler that reads
/// them may not format, allocate, or lock: one `write` to standard error is
/// the whole of what it does here.
var note_buf: [512]u8 = undefined;
var note_len: std.atomic.Value(usize) = .init(0);

/// Stage `text` (a whole line, newline included) as that sentence, or clear
/// it when empty. Longer than the buffer is truncated rather than dropped: a
/// batch named as far as it fits still says which install was running.
pub fn stageNote(text: []const u8) void {
    if (text.len <= note_buf.len) {
        @memcpy(note_buf[0..text.len], text);
        note_len.store(text.len, .release);
        return;
    }
    const cut = "...\n";
    const keep = note_buf.len - cut.len;
    @memcpy(note_buf[0..keep], text[0..keep]);
    @memcpy(note_buf[keep..], cut);
    note_len.store(note_buf.len, .release);
}

pub fn clearNote() void {
    note_len.store(0, .release);
}

/// The staged sentence, copied, so a narrower one can stand in for it while
/// one call runs and it can be put back after.
pub const SavedNote = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const SavedNote) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn saveNote() SavedNote {
    var saved: SavedNote = .{};
    const now = stagedNote();
    @memcpy(saved.buf[0..now.len], now);
    saved.len = now.len;
    return saved;
}

pub fn restoreNote(saved: *const SavedNote) void {
    if (saved.len == 0) return clearNote();
    stageNote(saved.text());
}

/// What a note begins with: the command whose run it ends (`mox apply`).
pub var run_name: []const u8 = "mox";

/// Stage the note for one call holding the user's terminal: the step it is,
/// named as precisely as its caller knows it.
pub fn stageStepNote(arena: std.mem.Allocator, step: []const u8) !void {
    stageNote(try std.fmt.allocPrint(arena, "{s}: interrupted while running {s}; it may have been left part-done\n", .{ run_name, step }));
}

/// What is staged, for a caller that wants to assert on it.
pub fn stagedNote() []const u8 {
    return note_buf[0..note_len.load(.acquire)];
}

/// Write the staged sentence to standard error, if there is one. Async-signal
/// safe: no formatting, no allocation, no lock, and the buffered writers mox
/// uses are empty for the length of a call -- a spawn flushes them before the
/// child that inherits those streams can write a byte. Windows has none of
/// the signals that reach this, so nothing there ever asks.
pub fn writeStagedNote() void {
    if (builtin.os.tag == .windows) return;
    const n = note_len.load(.acquire);
    if (n == 0) return;
    _ = std.c.write(2, &note_buf, n);
}

/// The controlling terminal, handed to a streamed child for its run (by
/// `spawnForeground`, which launches the child holding it) and taken back
/// once it is reaped. Handed over only when stdin is a terminal that mox's
/// own group holds: a mox run in the background must not take it from the
/// job that has it, and a mox without one has nothing to hand. Windows has
/// no job control, so there it is nothing at all.
pub const Terminal = if (builtin.os.tag == .windows) NoTerminal else PosixTerminal;

pub const NoTerminal = struct {
    pub fn takeBack(_: NoTerminal) void {}
};

pub const PosixTerminal = struct {
    /// The group the terminal goes back to: mox's own.
    owner: std.posix.pid_t,

    /// The group holding the terminal on stdin, when that is mox's own: the
    /// terminal there is to hand over. Null for no terminal, or one another
    /// job holds.
    pub fn heldOwner() ?std.posix.pid_t {
        const fd = std.posix.STDIN_FILENO;
        if (std.c.isatty(fd) == 0) return null;
        const owner = libc.tcgetpgrp(fd);
        if (owner < 0 or owner != libc.getpgrp()) return null;
        return owner;
    }

    pub fn takeBack(self: PosixTerminal) void {
        _ = setForeground(std.posix.STDIN_FILENO, self.owner);
    }

    /// `tcsetpgrp` with SIGTTOU blocked for its duration: the call from a
    /// background group -- which mox is in while the child has the
    /// terminal -- stops the caller otherwise. Blocked in this thread alone,
    /// never ignored process-wide, so no other thread's write can slip
    /// through a disposition flipped under it.
    pub fn setForeground(fd: std.posix.fd_t, pgid: std.posix.pid_t) bool {
        const mask = blockTtou();
        defer restoreThreadMask(mask);
        return libc.tcsetpgrp(fd, pgid) == 0;
    }
};

/// The calling thread's signal mask, as `blockTtou` found it.
pub const ThreadMask = if (builtin.os.tag == .windows) void else std.posix.sigset_t;

/// Block SIGTTOU in the calling thread and answer the mask to put back with
/// `restoreThreadMask`. A terminal write or `tcsetpgrp` from a background
/// group raises SIGTTOU -- a write only under `stty tostop` -- and the
/// default action stops the whole of mox; blocked, the call goes through.
/// The thread's mask alone changes, never a process-wide disposition.
pub fn blockTtou() ThreadMask {
    if (builtin.os.tag == .windows) return {};
    var set = std.posix.sigemptyset();
    std.posix.sigaddset(&set, .TTOU);
    var old: std.posix.sigset_t = undefined;
    _ = std.c.pthread_sigmask(std.posix.SIG.BLOCK, &set, &old);
    return old;
}

pub fn restoreThreadMask(old: ThreadMask) void {
    if (builtin.os.tag == .windows) return;
    var ignored: std.posix.sigset_t = undefined;
    _ = std.c.pthread_sigmask(std.posix.SIG.SETMASK, &old, &ignored);
}

/// Whether stdin is a terminal a streamed child can read: on POSIX one mox's
/// own group holds, so it is handed to the child for its run; on Windows a
/// console, which has no foreground group to hold.
pub fn terminalStdin() bool {
    if (builtin.os.tag == .windows) {
        var mode: windows.DWORD = undefined;
        return console.GetConsoleMode(windows.peb().ProcessParameters.hStdInput, &mode).toBool();
    }
    return PosixTerminal.heldOwner() != null;
}

// In a struct so the winapi declaration is analyzed only on the Windows build.
const console = struct {
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
};

/// The terminal's own end of the run, when a child that held the terminal
/// ended of one, or null. SIGINT is the user's Ctrl-C; SIGHUP is the
/// terminal going away (an ssh session closing), which the kernel delivers
/// to the group holding the terminal -- the child's, not mox's. Either ends
/// the run: going on without the terminal would run every later install and
/// script with nobody there to answer it. A child that catches the signal to
/// clean up reports it by exiting 128 + the signal, the shell convention --
/// Homebrew's `brew.rb` answers `Interrupt` with `exit 130` (7.0.8) -- so
/// that exit counts too; a run that read only the signal would go on to the
/// next install after the user asked it to stop.
pub fn terminalEnded(term: std.process.Child.Term) ?std.posix.SIG {
    if (builtin.os.tag == .windows) return switch (term) {
        .signal => |sig| if (sig == .INT) .INT else null,
        .exited => |code| if (code == 130) .INT else null,
        else => null,
    };
    return switch (term) {
        .signal => |sig| if (sig == .INT or sig == .HUP) sig else null,
        .exited => |code| switch (code) {
            130 => .INT,
            129 => .HUP,
            else => null,
        },
        else => null,
    };
}

/// What `std.c` leaves undeclared of the job-control calls.
pub const libc = struct {
    pub extern "c" fn getpgrp() std.c.pid_t;
    pub extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;
    pub extern "c" fn tcsetpgrp(fd: std.c.fd_t, pgrp: std.c.pid_t) c_int;
};

/// End this process the way `sig` -- the user's Ctrl-C, or the terminal's
/// hangup -- would have, had the terminal delivered it here: by that signal
/// under its default disposition, so the shell reports it and a caller's
/// own handling of it sees one. What the run was part-way through is said
/// first, from the staged note. Reached only where a terminal was handed
/// over, which is never on Windows.
pub fn dieOf(sig: std.posix.SIG) noreturn {
    writeStagedNote();
    if (builtin.os.tag != .windows) {
        const default: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(sig, &default, null);
        var only = std.posix.sigemptyset();
        std.posix.sigaddset(&only, sig);
        _ = std.c.pthread_sigmask(std.posix.SIG.UNBLOCK, &only, &only);
        std.posix.raise(sig) catch {};
    }
    std.process.exit(128 + @as(u8, @intCast(@intFromEnum(sig))));
}

/// What a child is doing at this instant, without blocking.
///
/// A child mox reads from is not a child mox is waiting on, so the wait that
/// answers a stop is not reached until the read is over -- and a stopped
/// child writes nothing, so the read is never over. Asking here, between
/// reads, is what lets that child be answered at all.
///
/// A stop is consumed by the asking, which costs nothing: the only answer to
/// a captured child that stopped is to end it. An exit is consumed too, so it
/// is returned rather than discarded -- the caller must use this term instead
/// of waiting again.
pub const Peek = union(enum) {
    running,
    stopped,
    done: std.process.Child.Term,
};

pub fn peek(child: *std.process.Child) Peek {
    if (builtin.os.tag == .windows) return .running;
    const id = child.id orelse return .running;
    var raw: c_int = undefined;
    const rc = std.c.waitpid(id, &raw, std.c.W.UNTRACED | std.c.W.NOHANG);
    if (rc <= 0) return .running;
    const status: u32 = @bitCast(raw);
    if (std.c.W.IFSTOPPED(status)) return .stopped;
    child.id = null;
    return .{ .done = termOfStatus(status) };
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
pub fn closePipes(io: Io, child: *std.process.Child) void {
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
            // A read or a write that reached the terminal before the child's
            // group held it stops the child on SIGTTIN or SIGTTOU. Its group
            // holds the terminal now, so that is no stop the user asked for:
            // continued, the child repeats the call as the foreground job.
            // `spawnForeground` makes this unreachable for a child it
            // launched; it stays for any other way one comes to be here.
            if (stoppedBeforeHandover(std.c.W.STOPSIG(status), libc.tcgetpgrp(std.posix.STDIN_FILENO), id)) {
                _ = signal(-id, .CONT);
                continue;
            }
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

/// Whether a child that stopped on `sig` stopped for touching the terminal
/// before its group was handed it, the terminal now being `holder`'s: a
/// terminal stop of a group that holds the terminal is not one the user
/// asked for with Ctrl-Z, which stops it on SIGTSTP instead.
pub fn stoppedBeforeHandover(sig: std.posix.SIG, holder: std.posix.pid_t, child_group: std.posix.pid_t) bool {
    return (sig == .TTIN or sig == .TTOU) and holder == child_group;
}

/// What a child launched by `spawnForeground` reads on stdin.
pub const ForegroundStdin = union(enum) {
    /// mox's own: the terminal being handed over.
    inherit,
    close,
    /// A descriptor of mox's, read by the child as its stdin.
    file: std.posix.fd_t,
};

/// A child launched holding the terminal, and the terminal to take back
/// once it is reaped.
pub const Foreground = struct {
    child: std.process.Child,
    tty: Terminal,
};

/// Spawn `argv` leading its own process group and holding the terminal from
/// before its first instruction, or answer null when stdin is no terminal
/// mox's own group holds (the caller spawns as usual, with no handover).
///
/// `std.process.spawn` cannot do this: its child leaves the terminal with
/// mox's group, and a handover made by mox after the spawn returns races the
/// child -- one that reads the terminal first is stopped by SIGTTIN, and the
/// read it was making comes back interrupted. So the child takes it, the way
/// a shell's child does, between fork and exec: with every signal blocked
/// (inherited from the fork), it resets every disposition mox may have
/// changed, makes its own group, takes the terminal, and only then clears
/// its mask and execs. The parent makes the same group (whichever of the two
/// runs first, the group exists before either signals it) but never touches
/// the terminal: it waits for the exec, and a late handover of its own could
/// pull the terminal back from a job the exec'd program set up.
///
/// The parent blocks every signal across the fork and records the child's
/// group in `signals` before unblocking, so the terminal's signals never run
/// mox's handler in the child, and a Ctrl-C landing just after the fork
/// already reaches the child's group.
///
/// The wait for the exec is a poll of a close-on-exec pipe beside a
/// non-blocking wait: a child stopped before its exec (Ctrl-Z in the instant
/// after it took the terminal) is continued rather than waited on forever.
/// An exec that fails reports its errno over the pipe; the child is killed
/// and reaped, the terminal taken back, and the spawn answers the error
/// `std.process.spawn` would have. A child ended by a signal before its exec
/// is answered the same way, as `KilledBySignal` -- or, for the user's Ctrl-C,
/// the run ends of it as it would have had the Ctrl-C reached mox.
///
/// `argv[0]` without a `/` is looked up on mox's own PATH, as
/// `std.process.spawn` looks it up, and the child gets `environ_map` (null:
/// mox's own environment) without `ZIG_PROGRESS`, as that spawn leaves it.
/// Everything the child needs is allocated before the fork, so between fork
/// and exec it makes async-signal-safe calls alone. stdout and stderr are
/// mox's own. POSIX only: Windows has no job control, and answers null.
pub fn spawnForeground(
    arena: std.mem.Allocator,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    stdin: ForegroundStdin,
    signals: SpawnSignals,
) anyerror!?Foreground {
    if (builtin.os.tag == .windows) return null;
    const owner = PosixTerminal.heldOwner() orelse return null;

    const argv_buf = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;
    const process_environ = std.Io.Threaded.global_single_threaded.environ.process_environ;
    const envp = if (environ_map) |m|
        try m.createPosixBlock(arena, .{ .zig_progress_fd = -1 })
    else
        try process_environ.createPosixBlock(arena, .{ .zig_progress_fd = -1 });
    const candidates = try programCandidates(arena, argv[0], pathOf(arena, process_environ));

    var dfl: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var empty = std.posix.sigemptyset();
    var all = std.posix.sigfillset();

    // Close-on-exec from the start where the system can (`pipe2`), so no
    // other thread's child inherits it; set just after where it cannot.
    const err_pipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });

    var saved_mask: std.posix.sigset_t = undefined;
    _ = std.c.pthread_sigmask(std.posix.SIG.SETMASK, &all, &saved_mask);
    const forked = std.c.fork();
    if (forked == 0) {
        // The child. Async-signal-safe calls alone from here to the exec,
        // with every signal blocked until the mask is cleared just before it.
        const report = err_pipe[1];
        for (std.enums.values(std.posix.SIG)) |sig| {
            if (sig == .KILL or sig == .STOP) continue;
            _ = std.c.sigaction(sig, &dfl, null);
        }
        if (std.c.setpgid(0, 0) != 0) childFail(report, std.c._errno().*);
        _ = libc.tcsetpgrp(std.posix.STDIN_FILENO, std.c.getpid());
        _ = std.c.sigprocmask(std.posix.SIG.SETMASK, &empty, null);
        switch (stdin) {
            .inherit => {},
            .close => _ = std.c.close(std.posix.STDIN_FILENO),
            .file => |fd| if (std.c.dup2(fd, std.posix.STDIN_FILENO) < 0) childFail(report, std.c._errno().*),
        }
        var last: c_int = @intFromEnum(std.posix.E.NOENT);
        var denied = false;
        for (candidates) |path| {
            _ = std.c.execve(path, argv_buf.ptr, envp.slice.ptr);
            const e = std.c._errno().*;
            switch (@as(std.posix.E, @enumFromInt(e))) {
                .ACCES => denied = true,
                .NOENT, .NOTDIR => {},
                else => childFail(report, e),
            }
            last = e;
        }
        childFail(report, if (denied) @intFromEnum(std.posix.E.ACCES) else last);
    }
    if (forked > 0) {
        // The parent's half: the group exists whichever side runs first, and
        // it is the group a signal from here on is sent to.
        _ = std.c.setpgid(forked, forked);
        signals.hold(forked);
    }
    var blocked: std.posix.sigset_t = undefined;
    _ = std.c.pthread_sigmask(std.posix.SIG.SETMASK, &saved_mask, &blocked);
    _ = std.c.close(err_pipe[1]);
    if (forked < 0) {
        _ = std.c.close(err_pipe[0]);
        return error.SystemResources;
    }
    const pid: std.posix.pid_t = forked;

    const outcome = awaitExec(pid, err_pipe[0]);
    _ = std.c.close(err_pipe[0]);
    switch (outcome) {
        .execed => return .{
            .child = .{
                .id = pid,
                .thread_handle = {},
                .stdin = null,
                .stdout = null,
                .stderr = null,
                .request_resource_usage_statistics = false,
            },
            .tty = .{ .owner = owner },
        },
        .failed => |f| {
            if (!f.reaped) {
                _ = signal(pid, .KILL);
                reap(pid);
            }
            signals.release();
            _ = PosixTerminal.setForeground(std.posix.STDIN_FILENO, owner);
            return execError(@enumFromInt(f.errno));
        },
        .ended => |term| {
            signals.release();
            _ = PosixTerminal.setForeground(std.posix.STDIN_FILENO, owner);
            if (terminalEnded(term)) |sig| dieOf(sig);
            return error.KilledBySignal;
        },
    }
}

/// How a launched child's way to its exec ended.
pub const ExecOutcome = union(enum) {
    /// The exec happened: the pipe closed with nothing on it.
    execed,
    /// The exec failed with this errno; `reaped` when the child's exit was
    /// already collected while waiting for it.
    failed: struct { errno: c_int, reaped: bool },
    /// The child ended before its exec, and is reaped.
    ended: std.process.Child.Term,
};

/// Wait for child `pid` to exec, or to report on `fd` why it could not. A
/// stop before the exec is answered with SIGCONT rather than waited out: a
/// child stopped there holds the pipe open and would never get to it.
pub fn awaitExec(pid: std.posix.pid_t, fd: std.posix.fd_t) ExecOutcome {
    var got: [@sizeOf(c_int)]u8 = undefined;
    var n: usize = 0;
    while (true) {
        var fds = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 50) > 0) {
            const rc = std.c.read(fd, got[n..].ptr, got.len - n);
            if (rc > 0) {
                n += @intCast(rc);
                if (n == got.len) return .{ .failed = .{ .errno = std.mem.readInt(c_int, &got, builtin.cpu.arch.endian()), .reaped = false } };
                continue;
            }
            if (rc == 0) return .execed;
            if (std.c._errno().* != @intFromEnum(std.posix.E.INTR)) return .execed;
        }
        var raw: c_int = undefined;
        const rc = std.c.waitpid(pid, &raw, std.c.W.UNTRACED | std.c.W.NOHANG);
        if (rc != pid) continue;
        const status: u32 = @bitCast(raw);
        if (std.c.W.IFSTOPPED(status)) {
            _ = signal(pid, .CONT);
            continue;
        }
        // Ended. What it wrote before it did is still on the pipe.
        const more = std.c.read(fd, got[n..].ptr, got.len - n);
        if (more > 0) n += @intCast(more);
        if (n == got.len) return .{ .failed = .{ .errno = std.mem.readInt(c_int, &got, builtin.cpu.arch.endian()), .reaped = true } };
        return .{ .ended = termOfStatus(status) };
    }
}

/// Reap `pid`, retrying an interrupted wait.
fn reap(pid: std.posix.pid_t) void {
    var raw: c_int = undefined;
    while (std.c.waitpid(pid, &raw, 0) < 0) {
        if (std.c._errno().* != @intFromEnum(std.posix.E.INTR)) return;
    }
}

/// Report `errno` to the parent and end the fork child without running
/// anything of mox's.
fn childFail(fd: std.posix.fd_t, errno: c_int) noreturn {
    var buf: [@sizeOf(c_int)]u8 = undefined;
    std.mem.writeInt(c_int, &buf, errno, builtin.cpu.arch.endian());
    _ = std.c.write(fd, &buf, buf.len);
    std.c._exit(127);
}

/// The error `std.process.spawn` raises for the same failed exec (its
/// `posixExecvPath`, Zig 0.16), so a report reads the same whichever way the
/// child was launched.
fn execError(e: std.posix.E) anyerror {
    return switch (e) {
        .@"2BIG" => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .INVAL => error.InvalidExe,
        .NOEXEC => error.InvalidExe,
        .IO => error.FileSystem,
        .LOOP => error.FileSystem,
        .ISDIR => error.IsDir,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .TXTBSY => error.FileBusy,
        else => switch (builtin.os.tag) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => switch (e) {
                .BADEXEC, .BADARCH => error.InvalidExe,
                else => error.Unexpected,
            },
            .linux => switch (e) {
                .LIBBAD => error.InvalidExe,
                else => error.Unexpected,
            },
            else => error.Unexpected,
        },
    };
}

/// mox's own PATH, which a program name is looked up on: the parent's, as
/// `std.process.spawn` looks it up, never the one handed to the child.
fn pathOf(arena: std.mem.Allocator, environ: std.process.Environ) []const u8 {
    var map = std.process.Environ.createMap(environ, arena) catch return std.Io.Threaded.default_PATH;
    return map.get("PATH") orelse std.Io.Threaded.default_PATH;
}

/// The paths an exec of `name` tries, in order: `name` itself when it holds
/// a `/`, else `<dir>/<name>` for each directory of `path`, empty ones
/// skipped.
pub fn programCandidates(arena: std.mem.Allocator, name: []const u8, path: []const u8) ![]const [*:0]const u8 {
    var out: std.ArrayList([*:0]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        try out.append(arena, try arena.dupeZ(u8, name));
        return out.toOwnedSlice(arena);
    }
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        try out.append(arena, try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, name }, 0));
    }
    return out.toOwnedSlice(arena);
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
/// as a timeout. The reaped flag is what tells a child the bound killed from
/// one that had already finished: the waiter sets it before it cancels this
/// task, so a deadline that passes after the child was reaped reports
/// nothing. It narrows rather than closes the window -- reading the flag and
/// sending the signal are two operations -- and the same holds for the
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

/// Whether the kill reached anything in the child's group. The verdict comes
/// from the group-directed kill rather than the pid-directed one, which
/// cannot discriminate at all: a child stays a zombie until its parent waits
/// for it, and a zombie answers a signal addressed to its pid. Addressing the
/// group is better but not decisive either, and differs by system -- Darwin
/// refuses a group whose only member is a zombie, Linux accepts it -- so this
/// narrows the window in which a finished child reads as a killed one without
/// closing it. What actually discriminates is `Guard.reaped`, which the
/// waiter sets before it cancels the watchdog.
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

test "stageNote: what a run ended by a signal has left to say reaches standard error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "note.txt" });
    defer clearNote();

    // With nothing staged the handler writes nothing: a run that was between
    // calls has nothing to report about one.
    clearNote();
    try testing.expectEqualStrings("", stagedNote());
    try testing.expectEqualStrings("", try writtenToStderr(io, a, path));

    const note = "mox apply: interrupted installing brew: ripgrep (row(s) in this batch may have landed)\n";
    stageNote(note);
    try testing.expectEqualStrings(note, stagedNote());
    try testing.expectEqualStrings(note, try writtenToStderr(io, a, path));

    // A batch too long for the buffer is cut, not dropped: which install was
    // running is the first thing in the line and survives either way.
    const long = "mox apply: interrupted installing brew:" ++ (" ripgrep," ** 200);
    stageNote(long);
    try testing.expectEqual(@as(usize, note_buf.len), stagedNote().len);
    try testing.expect(std.mem.startsWith(u8, stagedNote(), "mox apply: interrupted installing brew:"));
    try testing.expect(std.mem.endsWith(u8, stagedNote(), "...\n"));
}

/// What `writeStagedNote` puts on descriptor 2, captured by pointing that
/// descriptor at a file for the length of the call.
fn writtenToStderr(io: Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    const saved = std.c.dup(2);
    if (saved < 0) return error.Unexpected;
    _ = std.c.dup2(f.handle, 2);
    writeStagedNote();
    _ = std.c.dup2(saved, 2);
    _ = std.c.close(saved);
    f.close(io);
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
}

fn ttouBlocked() bool {
    var none = std.posix.sigemptyset();
    var now: std.posix.sigset_t = undefined;
    _ = std.c.pthread_sigmask(std.posix.SIG.BLOCK, &none, &now);
    return std.posix.sigismember(&now, .TTOU);
}

test "blockTtou: SIGTTOU is blocked in this thread until the mask is put back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testing.expect(!ttouBlocked());
    const mask = blockTtou();
    try testing.expect(ttouBlocked());
    restoreThreadMask(mask);
    try testing.expect(!ttouBlocked());
}

test "stoppedBeforeHandover: a terminal stop of the group holding the terminal is not the user's Ctrl-Z" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testing.expect(stoppedBeforeHandover(.TTIN, 42, 42));
    try testing.expect(stoppedBeforeHandover(.TTOU, 42, 42));
    // Ctrl-Z stops the foreground group on SIGTSTP: that is the user's.
    try testing.expect(!stoppedBeforeHandover(.TSTP, 42, 42));
    // A terminal stop while another group holds the terminal is a child
    // that wants a terminal it was not given.
    try testing.expect(!stoppedBeforeHandover(.TTIN, 7, 42));
}

test "programCandidates: a name is tried in each PATH directory, a path as given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const looked = try programCandidates(a, "brew", "/opt/homebrew/bin::/usr/bin");
    try testing.expectEqual(@as(usize, 2), looked.len);
    try testing.expectEqualStrings("/opt/homebrew/bin/brew", std.mem.span(looked[0]));
    try testing.expectEqualStrings("/usr/bin/brew", std.mem.span(looked[1]));
    const direct = try programCandidates(a, "./x/brew", "/usr/bin");
    try testing.expectEqual(@as(usize, 1), direct.len);
    try testing.expectEqualStrings("./x/brew", std.mem.span(direct[0]));
}

test "spawnForeground: without a terminal mox holds, there is nothing to hand over" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // The test runner's stdin is the build system's pipe, never a terminal.
    if (PosixTerminal.heldOwner() != null) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try spawnForeground(arena.allocator(), &.{"true"}, null, .inherit, SpawnSignals.install())) == null);
}

fn killAfter(io: Io, pid: std.posix.pid_t, ms: i64) Io.Cancelable!void {
    const t: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(ms), .clock = .awake } };
    try t.sleep(io);
    _ = signal(pid, .KILL);
}

test "awaitExec: a child stopped before its exec is continued, not waited on for ever" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const pipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "exit 3" };
    const envp = [_:null]?[*:0]const u8{};

    // Stopped between fork and exec, as Ctrl-Z there would leave it: the
    // pipe stays open and silent until something continues it.
    const pid = std.c.fork();
    if (pid == 0) {
        _ = std.c.kill(std.c.getpid(), .STOP);
        _ = std.c.execve("/bin/sh", &argv, &envp);
        std.c._exit(127);
    }
    try testing.expect(pid > 0);
    _ = std.c.close(pipe[1]);
    defer _ = std.c.close(pipe[0]);

    // A wait that never continued it would block until this kill, and fail
    // on the time it took rather than hang the suite.
    var watchdog = try io.concurrent(killAfter, .{ io, pid, 10_000 });
    const started = Io.Clock.awake.now(io);
    const outcome = awaitExec(pid, pipe[0]);
    const elapsed = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    watchdog.cancel(io) catch {};

    try testing.expect(outcome == .execed);
    try testing.expect(elapsed < 5_000);
    var raw: c_int = undefined;
    try testing.expectEqual(pid, std.c.waitpid(pid, &raw, 0));
    const term = termOfStatus(@bitCast(raw));
    try testing.expect(term == .exited and term.exited == 3);
}

test "awaitExec: a failed exec is its errno, with the child left to reap" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const pipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const pid = std.c.fork();
    if (pid == 0) childFail(pipe[1], @intFromEnum(std.posix.E.NOENT));
    try testing.expect(pid > 0);
    _ = std.c.close(pipe[1]);
    defer _ = std.c.close(pipe[0]);
    const outcome = awaitExec(pid, pipe[0]);
    try testing.expect(outcome == .failed);
    try testing.expectEqual(@as(c_int, @intFromEnum(std.posix.E.NOENT)), outcome.failed.errno);
    if (!outcome.failed.reaped) reap(pid);
    try testing.expectEqual(error.FileNotFound, execError(.NOENT));
}

const pty = struct {
    extern "c" fn posix_openpt(flags: c_int) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
    /// TIOCSCTTY: macOS's `_IO('t', 97)`; Linux's from its own table.
    const set_controlling = if (builtin.os.tag == .linux) std.os.linux.T.IOCSCTTY else 0x20007461;
};

const PtyRun = struct { status: u32, out: []const u8 };

/// Run `body` in a helper process that leads a session on a fresh
/// pseudo-terminal -- its stdin, stdout, stderr and controlling terminal,
/// which its group holds in the foreground, as a terminal's shell does --
/// with `input` typed ahead, and answer its exit status and what was written
/// to the terminal. The helper is a fork of this multithreaded process, so
/// `body` allocates from pages alone and calls nothing that locks. Bounded:
/// a helper still running after 30 seconds is killed and reported.
fn inPtySession(a: std.mem.Allocator, io: Io, input: []const u8, body: *const fn () u8) !PtyRun {
    const master = pty.posix_openpt(@bitCast(std.c.O{ .ACCMODE = .RDWR, .NOCTTY = true }));
    if (master < 0) return error.SkipZigTest;
    defer _ = std.c.close(master);
    if (pty.grantpt(master) != 0 or pty.unlockpt(master) != 0) return error.SkipZigTest;
    _ = std.c.fcntl(master, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    _ = std.c.fcntl(master, std.c.F.SETFL, std.c.fcntl(master, std.c.F.GETFL) | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
    const slave = try a.dupeZ(u8, std.mem.span(pty.ptsname(master) orelse return error.SkipZigTest));
    // Held open so the typed-ahead line has a terminal to wait in.
    const held = std.c.open(slave.ptr, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
    if (held < 0) return error.SkipZigTest;
    defer _ = std.c.close(held);
    if (std.c.write(master, input.ptr, input.len) != input.len) return error.TypeAheadFailed;

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        if (std.c.setsid() < 0) std.c._exit(120);
        const fd = std.c.open(slave.ptr, .{ .ACCMODE = .RDWR });
        if (fd < 0) std.c._exit(121);
        _ = std.c.ioctl(fd, @intCast(pty.set_controlling), @as(c_int, 0));
        for ([_]c_int{ 0, 1, 2 }) |n| _ = std.c.dup2(fd, n);
        if (fd > 2) _ = std.c.close(fd);
        std.c._exit(body());
    }

    var out: std.ArrayList(u8) = .empty;
    var raw: c_int = 0;
    const started = Io.Clock.awake.now(io);
    while (true) {
        var fds = [_]std.c.pollfd{.{ .fd = master, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 50) > 0) {
            var buf: [4096]u8 = undefined;
            const n = std.c.read(master, &buf, buf.len);
            if (n > 0) try out.appendSlice(a, buf[0..@intCast(n)]);
        }
        if (std.c.waitpid(pid, &raw, std.c.W.NOHANG) == pid) break;
        if (started.durationTo(Io.Clock.awake.now(io)).toMilliseconds() > 30_000) {
            _ = std.c.kill(-pid, .KILL);
            reap(pid);
            return error.PtySessionNeverFinished;
        }
    }
    return .{ .status = @bitCast(raw), .out = out.items };
}

/// Launch `argv` holding the terminal, wait for it as a streamed call does,
/// take the terminal back, and answer 0 when it exited `want` and the
/// terminal is the helper's again; a distinct code for each way it was not.
fn launchHeld(argv: []const []const u8, want: u8) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const signals = SpawnSignals.install();
    defer signals.restore();
    const fg = (spawnForeground(a, argv, null, .inherit, signals) catch return 10) orelse return 11;
    var child = fg.child;
    const term = waitStreamed(&child, fg.tty) catch return 12;
    fg.tty.takeBack();
    if (libc.tcgetpgrp(0) != libc.getpgrp()) return 13;
    if (term != .exited) return 14;
    if (term.exited != want) return 15;
    return 0;
}

fn bodyReadsAtOnce() u8 {
    return launchHeld(&.{ "/bin/sh", "-c", "IFS= read -r l </dev/tty; [ \"$l\" = typed ]" }, 0);
}

fn bodyFailedExec() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const signals = SpawnSignals.install();
    defer signals.restore();
    if (spawnForeground(arena.allocator(), &.{"/nonexistent/mox-test-program"}, null, .inherit, signals)) |_| {
        return 20;
    } else |e| if (e != error.FileNotFound) return 21;
    if (libc.tcgetpgrp(0) != libc.getpgrp()) return 22;
    return 0;
}

fn bodyStopsOnTstp() u8 {
    return launchHeld(&.{ "/bin/sh", "-c", "kill -TSTP $$; exit 7" }, 7);
}

fn bodyStopsOnTtin() u8 {
    return launchHeld(&.{ "/bin/sh", "-c", "kill -TTIN $$; exit 5" }, 5);
}

/// The child's descriptors are checked against the helper's own inheritable
/// ones: what every exec from this process carries is the process's, not
/// the launch's (Zig's spawn caches a `/dev/null` without close-on-exec).
fn bodyCleanState() u8 {
    if (launchHeld(&.{ "/bin/sh", "-c", "exec grep SigBlk /proc/self/status" }, 0) != 0) return 30;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll("for n in $(seq 3 64); do case \" ") catch return 32;
    for (3..65) |n| {
        const flags = std.c.fcntl(@intCast(n), std.posix.F.GETFD);
        if (flags >= 0 and flags & std.posix.FD_CLOEXEC == 0) w.print("{d} ", .{n}) catch return 32;
    }
    w.writeAll("\" in *\" $n \"*) continue ;; esac; [ -e /proc/$$/fd/$n ] && echo LEAKED$n; done; exit 0") catch return 32;
    if (launchHeld(&.{ "/bin/sh", "-c", w.buffered() }, 0) != 0) return 31;
    return 0;
}

test "spawnForeground on a terminal: a child that reads it the moment it starts gets the line" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try inPtySession(arena.allocator(), testing.io, "typed\n", bodyReadsAtOnce);
    errdefer std.debug.print("terminal said:\n{s}\n", .{r.out});
    try testing.expect(std.c.W.IFEXITED(r.status));
    try testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(r.status));
}

test "spawnForeground on a terminal: a failed exec is its error, with the terminal taken back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try inPtySession(arena.allocator(), testing.io, "", bodyFailedExec);
    errdefer std.debug.print("terminal said:\n{s}\n", .{r.out});
    try testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(r.status));
}

test "spawnForeground on a terminal: Ctrl-Z's stop and a stray terminal stop both end in the child's own exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The helper leads its session, so the stop mox makes of itself on
    // Ctrl-Z is discarded, as under a terminal with no job-control shell,
    // and the wait goes on to the child's exit.
    const tstp = try inPtySession(arena.allocator(), testing.io, "", bodyStopsOnTstp);
    try testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(tstp.status));
    const ttin = try inPtySession(arena.allocator(), testing.io, "", bodyStopsOnTtin);
    try testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(ttin.status));
}

test "spawnForeground on a terminal: the child starts with no signal blocked and no descriptor the launch opened" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try inPtySession(arena.allocator(), testing.io, "", bodyCleanState);
    errdefer std.debug.print("terminal said:\n{s}\n", .{r.out});
    try testing.expectEqual(@as(u32, 0), std.c.W.EXITSTATUS(r.status));
    try testing.expect(std.mem.indexOf(u8, r.out, "SigBlk:\t0000000000000000") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "LEAKED") == null);
}

test "terminalEnded: Ctrl-C and the terminal's hangup, by signal or by the 128 + signal exit, and nothing else" {
    try testing.expectEqual(@as(?std.posix.SIG, .INT), terminalEnded(.{ .signal = .INT }));
    try testing.expectEqual(@as(?std.posix.SIG, .INT), terminalEnded(.{ .exited = 130 }));
    try testing.expectEqual(@as(?std.posix.SIG, null), terminalEnded(.{ .exited = 1 }));
    try testing.expectEqual(@as(?std.posix.SIG, null), terminalEnded(.{ .exited = 0 }));
    try testing.expectEqual(@as(?std.posix.SIG, null), terminalEnded(.{ .signal = .TERM }));
    if (builtin.os.tag == .windows) return;
    try testing.expectEqual(@as(?std.posix.SIG, .HUP), terminalEnded(.{ .signal = .HUP }));
    try testing.expectEqual(@as(?std.posix.SIG, .HUP), terminalEnded(.{ .exited = 129 }));
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

test "killGroupOf: a pid the system has freed is not reached" {
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
    var raw: c_int = undefined;
    _ = std.c.waitpid(id, &raw, 0);
    // Freed, not merely finished: nothing answers either address. A child
    // that has finished but not yet been waited for is a different case, and
    // one systems do not agree on -- Darwin refuses its group, Linux accepts
    // it -- which is why `Guard.reaped`, and not this, is what tells a
    // killed child from a finished one.
    try testing.expect(!killGroupOf(id));
    child.id = null;
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
}

test "killStragglersOf: only the group is addressed, never the bare pid" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    // Left in the caller's own group, so its pid names no process group: a
    // kill that reached it could only have been addressed to the pid. Every
    // caller of this sweeps a group whose leader the wait has already reaped,
    // and a reaped pid is the system's to hand to something else.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "sleep 300" },
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const id = child.id.?;
    killStragglersOf(id);

    const step: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(50), .clock = .awake } };
    try step.sleep(io);
    var raw: c_int = undefined;
    try testing.expectEqual(@as(std.c.pid_t, 0), std.c.waitpid(id, &raw, std.c.W.NOHANG));

    _ = killGroupOf(id);
    _ = try child.wait(io);
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
