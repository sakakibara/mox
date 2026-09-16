//! The seam every backend reaches a package manager -- or a plugin -- through.
//!
//! An adapter never spawns a process itself: it asks a `Runner`. Production
//! hands it `Process`; a test hands it a scripted stand-in, so adapter logic
//! is exercised without a package manager installed and without mutating the
//! machine running the suite. Real-manager coverage is a separate integration
//! suite, where actually invoking brew is the point.
//!
//! Every captured call is time-bounded, with the same default and kill a
//! setup script gets: a query blocked on a manager's lock is a reported
//! failure, never a hung `mox status`. A streamed call -- an install, a
//! bootstrap -- has its own bound, unbounded by default, and is interrupted
//! before it is killed so the manager behind `sudo` can roll back.

const std = @import("std");
const builtin = @import("builtin");

const run_scripts = @import("../apply/run_scripts.zig");

const Io = std.Io;
const EnvironMap = std.process.Environ.Map;

/// Whether this process already has the privilege an install needs. A
/// container and a root WSL install commonly ship no `sudo` at all, where
/// elevating unconditionally turns every install into
/// "sudo: command not found".
pub fn isRoot() bool {
    return switch (builtin.os.tag) {
        .linux, .macos => std.c.geteuid() == 0,
        else => false,
    };
}

/// The bound every backend call runs under: the setup-script one, read the
/// same way (`MOX_SCRIPT_TIMEOUT_MS`, `<= 0` disables), so one variable governs
/// everything mox runs on the user's behalf.
pub const default_timeout_ms: i64 = run_scripts.default_script_timeout_ms;

pub fn timeoutFromEnv(env: ?*const EnvironMap, stderr: *std.Io.Writer) i64 {
    return run_scripts.scriptTimeoutMs(env, stderr);
}

/// The bound a streamed call -- an install, a bootstrap -- runs under.
/// Unbounded by default: an install may legitimately compile for hours,
/// and a bound that fires mid-transaction is worse than none.
pub const default_install_timeout_ms: i64 = 0;

/// How long a streamed child gets to wind down after the interrupt its
/// bound sends, before it is killed outright.
pub const default_grace_ms: i64 = 10_000;

/// `MOX_INSTALL_TIMEOUT_MS`, read the way the setup-script bound is: a
/// present but unparseable value warns on each read and falls back to the default.
pub fn installTimeoutMs(env: ?*const EnvironMap, stderr: *std.Io.Writer) i64 {
    const m = env orelse return default_install_timeout_ms;
    const v = m.get("MOX_INSTALL_TIMEOUT_MS") orelse return default_install_timeout_ms;
    if (v.len == 0) return default_install_timeout_ms;
    const trimmed = std.mem.trim(u8, v, " \t\r\n");
    return std.fmt.parseInt(i64, trimmed, 10) catch {
        stderr.print("mox: MOX_INSTALL_TIMEOUT_MS={s}: not an integer; using default ({d}ms)\n", .{ trimmed, default_install_timeout_ms }) catch {};
        return default_install_timeout_ms;
    };
}

/// This process's id, for naming a scratch file that a second mox running
/// beside this one must not share.
pub fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

/// Where a call's scratch files are staged under the scratch directory: a
/// child's stdin, a manager's export. Named per process, and swept of what
/// a dead process left by `sweepScratch`.
pub const tmp_subdir = "tmp";

pub fn scratchTmpDir(arena: std.mem.Allocator, scratch_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ scratch_dir, tmp_subdir });
}

/// Remove what an interrupted mox left under `<scratch_dir>/tmp`: a stdin
/// file or an export whose owning process is gone. This process's own files
/// and a live process's are left alone. Windows cannot ask whether a pid is
/// alive, so there only a file older than an hour goes. Best effort: a
/// sweep that cannot run is not a failed command.
pub fn sweepScratch(io: Io, arena: std.mem.Allocator, scratch_dir: []const u8) void {
    const dir_path = scratchTmpDir(arena, scratch_dir) catch return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var stale: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const pid = scratchPidOf(e.name) orelse continue;
        if (pid == processId()) continue;
        if (builtin.os.tag == .windows) {
            const st = dir.statFile(io, e.name, .{}) catch continue;
            const age_ms = st.mtime.durationTo(Io.Timestamp.now(io, .real)).toMilliseconds();
            if (age_ms < 3_600_000) continue;
        } else if (processAlive(pid)) continue;
        stale.append(arena, arena.dupe(u8, e.name) catch return) catch return;
    }
    for (stale.items) |name| dir.deleteFile(io, name) catch {};
}

/// The pid a scratch file is named for, or null for any other file.
fn scratchPidOf(name: []const u8) ?u32 {
    const digits = for ([_][2][]const u8{
        .{ "stdin-", ".txt" },
        .{ "winget-export-", ".json" },
    }) |shape| {
        if (name.len <= shape[0].len + shape[1].len) continue;
        if (!std.mem.startsWith(u8, name, shape[0])) continue;
        if (!std.mem.endsWith(u8, name, shape[1])) continue;
        break name[shape[0].len .. name.len - shape[1].len];
    } else return null;
    return std.fmt.parseInt(u31, digits, 10) catch null;
}

/// Signal 0 delivers nothing and answers whether the pid exists. A pid
/// this user may not signal still exists.
fn processAlive(pid: u32) bool {
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |e| return e == error.PermissionDenied;
    return true;
}

/// A kill for exceeding the bound must be named as such, never read as the
/// manager's own failure.
pub fn checkTimedOut(res: Result) error{TimedOut}!void {
    if (res.timed_out) return error.TimedOut;
}

pub const Result = struct {
    code: u8,
    ok: bool,
    stdout: []const u8,
    /// The call was killed for exceeding its bound; `code` is meaningless.
    timed_out: bool = false,
};

pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!Result,
    streamFn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!Result,

    /// Run and capture stdout: for a query whose output mox parses. stderr
    /// is the terminal's, so a manager's or plugin's own diagnostics reach
    /// the user as written.
    pub fn run(self: Runner, arena: std.mem.Allocator, argv: []const []const u8) anyerror!Result {
        return self.runFn(self.ctx, arena, argv, null);
    }

    /// `run` with bytes on the child's stdin.
    pub fn runInput(self: Runner, arena: std.mem.Allocator, argv: []const []const u8, stdin: []const u8) anyerror!Result {
        return self.runFn(self.ctx, arena, argv, stdin);
    }

    /// Run with mox's own stdout and stderr: for work the user waits on. An
    /// install compiles, downloads, and asks about disk space; capturing that
    /// would replace minutes of progress with a silent hang and throw the
    /// manager's own diagnostics away. `stdout` comes back empty.
    pub fn stream(self: Runner, arena: std.mem.Allocator, argv: []const []const u8) anyerror!Result {
        return self.streamFn(self.ctx, arena, argv, null);
    }

    /// `stream` with bytes on the child's stdin.
    pub fn streamInput(self: Runner, arena: std.mem.Allocator, argv: []const []const u8, stdin: []const u8) anyerror!Result {
        return self.streamFn(self.ctx, arena, argv, stdin);
    }

    /// `run` or `stream` by flag. An argv that is a PowerShell script
    /// invocation (`pwsh ... -File <script> ...`) goes through the host
    /// fallback, so a `.ps1` plugin or a scoop shim runs on a machine that
    /// has only Windows PowerShell.
    pub fn invoke(self: Runner, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8, streamed: bool) anyerror!Result {
        if (powerShellScriptOf(argv)) |script| return runPowerShell(self, arena, script, stdin, streamed);
        return self.call(arena, argv, stdin, streamed);
    }

    fn call(self: Runner, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8, streamed: bool) anyerror!Result {
        return if (streamed) self.streamFn(self.ctx, arena, argv, stdin) else self.runFn(self.ctx, arena, argv, stdin);
    }
};

/// The PowerShell hosts in the order they are tried: `pwsh` is PowerShell 7,
/// which a fresh Windows machine does not have; `powershell` is the 5.1
/// every Windows ships.
pub const powershell_hosts = [_][]const u8{ "pwsh", "powershell" };

/// What every script invocation carries between the host and the script:
/// no profile, and a policy that lets a repo's script run at all.
pub const powershell_flags = [_][]const u8{ "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" };

/// `<host> -NoProfile -ExecutionPolicy Bypass -File <script_args...>`.
pub fn powerShellArgv(arena: std.mem.Allocator, host: []const u8, script_args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, host);
    try out.appendSlice(arena, &powershell_flags);
    try out.appendSlice(arena, script_args);
    return out.toOwnedSlice(arena);
}

/// The script and its arguments of an argv built by `powerShellArgv` for
/// the first host, or null for any other argv.
pub fn powerShellScriptOf(argv: []const []const u8) ?[]const []const u8 {
    const head = 1 + powershell_flags.len;
    if (argv.len <= head) return null;
    if (!std.mem.eql(u8, argv[0], powershell_hosts[0])) return null;
    for (powershell_flags, argv[1..head]) |want, got| {
        if (!std.mem.eql(u8, want, got)) return null;
    }
    return argv[head..];
}

/// Run a PowerShell script through the first host that exists: `pwsh`,
/// then `powershell` when `pwsh` is not on PATH. Which host a machine has
/// is only known by trying, and a script must not fail to run for want of
/// the newer one.
pub fn runPowerShell(runner: Runner, arena: std.mem.Allocator, script_args: []const []const u8, stdin: ?[]const u8, streamed: bool) anyerror!Result {
    const first = try powerShellArgv(arena, powershell_hosts[0], script_args);
    return runner.call(arena, first, stdin, streamed) catch |e| switch (e) {
        error.FileNotFound => {
            const second = try powerShellArgv(arena, powershell_hosts[1], script_args);
            return runner.call(arena, second, stdin, streamed);
        },
        else => return e,
    };
}

/// The most stdout a query may answer with. A manager's explicit-install
/// list is kilobytes; megabytes is a manager that never stops writing.
pub const max_capture_bytes: usize = 8 << 20;

/// Runs the argv as a real child process. `env` is the environment mox itself
/// reads through, so a manager invoked here sees the same HOME and PATH mox
/// resolved its own paths from; null falls back to the process environment.
/// `scratch_dir` backs a child's stdin with a file, which cannot deadlock the
/// way a pipe written alongside a pipe read can. `out`/`err` are mox's own
/// buffered writers, flushed before every spawn so what mox said about a
/// call reaches the terminal before the call's own output does.
pub const Process = struct {
    io: Io,
    env: ?*const EnvironMap = null,
    scratch_dir: []const u8 = "",
    /// The bound on a captured call.
    timeout_ms: i64 = default_timeout_ms,
    /// The bound on a streamed call; `<= 0` is none.
    install_timeout_ms: i64 = default_install_timeout_ms,
    /// What a streamed child gets between the interrupt and the kill.
    grace_ms: i64 = default_grace_ms,
    out: ?*Io.Writer = null,
    err: ?*Io.Writer = null,

    pub fn runner(self: *Process) Runner {
        return .{ .ctx = self, .runFn = runImpl, .streamFn = streamImpl };
    }

    fn timeoutOf(ms: i64) Io.Timeout {
        if (ms <= 0) return .none;
        return .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(ms), .clock = .awake } };
    }

    fn runImpl(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!Result {
        const self: *Process = @ptrCast(@alignCast(ctx));
        return self.spawn(arena, argv, stdin, .pipe);
    }

    fn streamImpl(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!Result {
        const self: *Process = @ptrCast(@alignCast(ctx));
        return self.spawn(arena, argv, stdin, .inherit);
    }

    /// Spawn with stdin backed by a scratch file holding `stdin` (closed
    /// when null), stderr on the terminal, and stdout captured or inherited.
    /// One deadline bounds the whole call: reading what the child writes and
    /// waiting for it to exit.
    ///
    /// Every child leads its own process group, so a bound reaches the whole
    /// tree: a query blocked behind a helper it spawned (`port | awk`) and an
    /// install behind a shell (`sh -c 'sudo port install ...'`) go together,
    /// never the shell alone with the manager left running. A captured call
    /// exceeding its bound has the group killed. A streamed call has the
    /// group interrupted, then killed after the grace, and whatever survived
    /// the child's own exit is killed once the child is reaped.
    ///
    /// A streamed child is handed the terminal for its run, the way a shell
    /// hands it to a foreground job: `sudo` may prompt (a background group
    /// stops on SIGTTOU the moment it touches the terminal), and Ctrl-C goes
    /// to the child's group, not to mox. A streamed child that dies of a
    /// SIGINT mox did not send was interrupted by the user, so once mox has
    /// the terminal back it dies of SIGINT itself: the run ends exactly as
    /// a Ctrl-C delivered to mox would have ended it. A SIGINT the bound
    /// sent is a timeout, reported as one. Without a terminal on stdin
    /// (CI, a pipe) there is no handover: nothing can prompt there. Windows
    /// has neither groups nor an interrupt: a bound terminates the direct
    /// child.
    fn spawn(
        self: *Process,
        arena: std.mem.Allocator,
        argv: []const []const u8,
        stdin: ?[]const u8,
        stdout_io: std.process.SpawnOptions.StdIo,
    ) anyerror!Result {
        const io = self.io;

        var stdin_file: ?Io.File = null;
        defer if (stdin_file) |f| f.close(io);
        var stdin_io: std.process.SpawnOptions.StdIo = .close;
        if (stdin) |bytes| {
            const tmp_dir = try scratchTmpDir(arena, self.scratch_dir);
            try Io.Dir.cwd().createDirPath(io, tmp_dir);
            // Named per process: two mox runs sharing a state dir (a status
            // beside an apply) must not truncate each other's stdin mid-read.
            const name = try std.fmt.allocPrint(arena, "stdin-{d}.txt", .{processId()});
            const path = try std.fs.path.join(arena, &.{ tmp_dir, name });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
            stdin_file = try Io.Dir.cwd().openFile(io, path, .{});
            // Unlinked as soon as it is open: the child inherits the open
            // descriptor, and a mox that dies mid-call leaves nothing behind.
            Io.Dir.cwd().deleteFile(io, path) catch {};
            stdin_io = .{ .file = stdin_file.? };
        }

        if (self.out) |w| w.flush() catch {};
        if (self.err) |w| w.flush() catch {};

        const captured = stdout_io == .pipe;
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .environ_map = self.env,
            .stdin = stdin_io,
            .stdout = stdout_io,
            .stderr = .inherit,
            .pgid = own_group,
        });
        const deadline = timeoutOf(if (captured) self.timeout_ms else self.install_timeout_ms).toDeadline(io);
        var tty: ?Terminal = null;
        if (!captured) {
            if (child.id) |id| tty = Terminal.handTo(id);
        }

        var out: []const u8 = "";
        if (child.stdout) |f| {
            var streams: Io.File.MultiReader.Buffer(1) = undefined;
            var mr: Io.File.MultiReader = undefined;
            mr.init(arena, io, streams.toStreams(), &.{f});
            defer mr.deinit();
            const rd = mr.reader(0);
            // A read that fails, overruns the cap, or outlives the bound is an
            // error, never an empty answer: an empty `list` would make every
            // row missing.
            while (mr.fill(4096, deadline)) |_| {
                if (rd.buffered().len > max_capture_bytes) {
                    killGroup(io, &child);
                    return error.StreamTooLong;
                }
            } else |e| switch (e) {
                error.EndOfStream => {},
                error.Timeout => {
                    killGroup(io, &child);
                    return .{ .code = 255, .ok = false, .stdout = "", .timed_out = true };
                },
                else => {
                    killGroup(io, &child);
                    return e;
                },
            }
            mr.checkAnyError() catch |e| {
                killGroup(io, &child);
                return e;
            };
            out = try mr.toOwnedSlice(0);
        }

        // The wait is bounded too: a child that closed stdout and lingers
        // must not hold `mox status` any longer than the read may. The
        // watchdog must really run alongside the wait: `io.async` may run
        // it inline when no thread is spare, which would sleep out the
        // whole bound before the wait even began.
        var guard: Guard = .{};
        var killer: ?Io.Future(void) = null;
        if (deadline != .none) {
            if (child.id) |id| {
                const spawned = if (captured)
                    io.concurrent(killGroupAfter, .{ io, deadline, id, &guard })
                else
                    io.concurrent(interruptAfter, .{ io, deadline, id, timeoutOf(self.grace_ms), &guard });
                // No thread for the watchdog: an unbounded wait beats a
                // running child nobody reaps.
                killer = spawned catch |e| switch (e) {
                    error.ConcurrencyUnavailable => null,
                };
            }
        }
        // `wait` clears `child.id` as it reaps, so the group to sweep must
        // be remembered before it.
        const group = child.id;
        const term = child.wait(io) catch |e| {
            guard.reaped.store(true, .release);
            if (killer) |*k| _ = k.cancel(io);
            if (tty) |t| t.takeBack();
            return e;
        };
        guard.reaped.store(true, .release);
        if (killer) |*k| _ = k.cancel(io);
        if (tty) |t| t.takeBack();
        // A shell reaped on the interrupt leaves whatever it backgrounded
        // in its group; the call is over, so nothing there may outlive it.
        if (guard.fired) {
            if (group) |id| killStragglersOf(id);
        }

        var res = fromTerm(term, out);
        if (guard.fired) {
            res.ok = false;
            res.timed_out = true;
        } else if (tty != null and term == .signal and term.signal == .INT) {
            if (self.out) |w| w.flush() catch {};
            if (self.err) |w| w.flush() catch {};
            dieOfInterrupt();
        }
        return res;
    }
};

/// Every child leads its own process group everywhere that has one;
/// Windows has no groups, so its kill reaches the direct child only.
const own_group: ?std.posix.pid_t = if (builtin.os.tag == .windows) null else 0;

/// The controlling terminal, handed to a streamed child for its run and
/// taken back once it is reaped. Handed over only when stdin is a terminal
/// that mox's own group holds: a mox run in the background must not take
/// it from the job that has it, and a mox without one has nothing to hand.
/// Windows has no job control, so there it is nothing at all.
const Terminal = if (builtin.os.tag == .windows) NoTerminal else PosixTerminal;

const NoTerminal = struct {
    fn handTo(_: std.process.Child.Id) ?NoTerminal {
        return null;
    }
    fn takeBack(_: NoTerminal) void {}
};

const PosixTerminal = struct {
    owner: std.posix.pid_t,

    fn handTo(pgid: std.posix.pid_t) ?PosixTerminal {
        const fd = std.posix.STDIN_FILENO;
        if (std.c.isatty(fd) == 0) return null;
        const owner = libc.tcgetpgrp(fd);
        if (owner < 0 or owner != libc.getpgrp()) return null;
        if (!setForeground(fd, pgid)) return null;
        return .{ .owner = owner };
    }

    fn takeBack(self: PosixTerminal) void {
        _ = setForeground(std.posix.STDIN_FILENO, self.owner);
    }

    /// `tcsetpgrp` with SIGTTOU ignored for its duration: the call from a
    /// background group -- which mox is in while the child has the
    /// terminal -- stops the caller otherwise.
    fn setForeground(fd: std.posix.fd_t, pgid: std.posix.pid_t) bool {
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
const libc = struct {
    extern "c" fn getpgrp() std.c.pid_t;
    extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;
    extern "c" fn tcsetpgrp(fd: std.c.fd_t, pgrp: std.c.pid_t) c_int;
};

/// End this process the way the Ctrl-C the user pressed would have, had
/// the terminal delivered it here: by SIGINT under its default disposition,
/// so the shell reports an interrupt and a caller's own SIGINT handling
/// sees one. Reached only where a terminal was handed over, which is never
/// on Windows.
fn dieOfInterrupt() noreturn {
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

/// Kill what a timed-out child's group still holds after the child itself
/// is reaped: a shell's `cmd &` helper ignores the interrupt by POSIX rule,
/// and the shell exiting on it cancels the watchdog that would have killed
/// the group after the grace. The group id outlives the reaped leader for
/// as long as any member does, so the kill lands on those members alone.
fn killStragglersOf(id: std.process.Child.Id) void {
    if (builtin.os.tag == .windows) return;
    _ = signal(-id, .KILL);
}

/// Shared between the waiter and the deadline task: the waiter marks the
/// child reaped so a kill never lands on a recycled pid, and the task marks
/// that it fired so the result is reported as a timeout. It fires only when
/// its signal reached a process: a child that exited at the bound is not a
/// timeout, and its recycled pid is never signaled.
const Guard = struct {
    reaped: std.atomic.Value(bool) = .init(false),
    fired: bool = false,
};

/// Kill the child's whole process group (its own pid when it leads none),
/// then reap it. `Child.kill` alone sends SIGTERM and waits, which a child
/// that ignores SIGTERM turns into the hang this exists to end.
fn killGroup(io: Io, child: *std.process.Child) void {
    if (child.id) |id| _ = killGroupOf(id);
    child.kill(io);
}

/// Whether the kill reached the child; a child already gone is not killed.
fn killGroupOf(id: std.process.Child.Id) bool {
    if (builtin.os.tag == .windows) return run_scripts.killProcess(id);
    _ = signal(-id, .KILL);
    return signal(id, .KILL);
}

/// Whether the signal was delivered. A pid nothing answers to (ESRCH) is
/// already gone; anything else is unexpected and reads the same way.
fn signal(pid: std.posix.pid_t, sig: std.posix.SIG) bool {
    std.posix.kill(pid, sig) catch return false;
    return true;
}

fn killGroupAfter(io: Io, deadline: Io.Timeout, id: std.process.Child.Id, guard: *Guard) void {
    deadline.sleep(io) catch return;
    if (guard.reaped.load(.acquire)) return;
    if (killGroupOf(id)) guard.fired = true;
}

/// The streamed counterpart: an interrupt to the whole group first -- the
/// shell in front of a manager defers it until its foreground child exits,
/// so only a signal that reaches the manager itself lets `sudo`'s
/// transaction roll back -- then a kill of the group once the grace has
/// passed. Windows has neither, so it terminates the direct child.
fn interruptAfter(io: Io, deadline: Io.Timeout, id: std.process.Child.Id, grace: Io.Timeout, guard: *Guard) void {
    deadline.sleep(io) catch return;
    if (guard.reaped.load(.acquire)) return;
    if (builtin.os.tag == .windows) {
        if (run_scripts.killProcess(id)) guard.fired = true;
        return;
    }
    if (!signal(-id, .INT)) return;
    guard.fired = true;
    if (grace != .none) grace.sleep(io) catch return;
    if (guard.reaped.load(.acquire)) return;
    _ = signal(-id, .KILL);
}

fn fromTerm(term: std.process.Child.Term, stdout: []const u8) Result {
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{
        .code = code,
        .ok = term == .exited and code == 0,
        .stdout = stdout,
    };
}

/// A scripted runner: answers each argv from a table, records every call and
/// its stdin, and fails the call rather than inventing output when no entry
/// matches, so a test can never pass on a command the adapter was not
/// supposed to run.
pub const Fake = struct {
    pub const Match = enum { exact, prefix, suffix };

    pub const Entry = struct {
        /// Matched against the argv joined by spaces.
        argv: []const u8,
        match: Match = .exact,
        stdout: []const u8 = "",
        code: u8 = 0,
        /// Raised instead of answering, for the failures a manager reports by
        /// not being there at all.
        fail: ?anyerror = null,
        /// Answer as a call killed at its bound.
        timed_out: bool = false,
        /// Write `stdout` to the file the argument after this flag names,
        /// instead of returning it: what `curl -o <path>` does.
        write_after: ?[]const u8 = null,
        io: ?Io = null,
        /// Answers the first matching call only, then steps aside for a
        /// later entry: a manager absent before a bootstrap and present after.
        once: bool = false,
    };

    entries: []const Entry,
    spent: std.ArrayList(bool) = .empty,
    calls: std.ArrayList([]const u8) = .empty,
    /// The stdin handed to each call, in call order ("" when none).
    inputs: std.ArrayList([]const u8) = .empty,
    /// Whether each call was streamed rather than captured, in call order.
    streamed: std.ArrayList(bool) = .empty,
    arena: std.mem.Allocator,

    pub fn runner(self: *Fake) Runner {
        return .{ .ctx = self, .runFn = runImpl, .streamFn = streamImpl };
    }

    pub fn called(self: *const Fake, argv: []const u8) bool {
        for (self.calls.items) |c| {
            if (std.mem.eql(u8, c, argv)) return true;
        }
        return false;
    }

    /// The stdin the first call matching `argv` received, or null.
    pub fn inputTo(self: *const Fake, argv: []const u8) ?[]const u8 {
        for (self.calls.items, 0..) |c, i| {
            if (std.mem.eql(u8, c, argv)) return self.inputs.items[i];
        }
        return null;
    }

    fn runImpl(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.answer(arena, argv, stdin, false);
    }

    fn streamImpl(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.answer(arena, argv, stdin, true);
    }

    fn answer(self: *Fake, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8, is_streamed: bool) anyerror!Result {
        const joined = try std.mem.join(self.arena, " ", argv);
        try self.calls.append(self.arena, joined);
        try self.inputs.append(self.arena, try self.arena.dupe(u8, stdin orelse ""));
        try self.streamed.append(self.arena, is_streamed);
        if (self.spent.items.len == 0) {
            for (self.entries) |_| try self.spent.append(self.arena, false);
        }
        for (self.entries, 0..) |e, i| {
            if (self.spent.items[i]) continue;
            const hit = switch (e.match) {
                .exact => std.mem.eql(u8, e.argv, joined),
                .prefix => std.mem.startsWith(u8, joined, e.argv),
                .suffix => std.mem.endsWith(u8, joined, e.argv),
            };
            if (!hit) continue;
            if (e.once) self.spent.items[i] = true;
            if (e.fail) |err| return err;
            if (e.timed_out) return .{ .code = 255, .ok = false, .stdout = "", .timed_out = true };
            if (e.write_after) |flag| {
                for (argv, 0..) |a, j| {
                    if (std.mem.eql(u8, a, flag) and j + 1 < argv.len) {
                        try Io.Dir.cwd().writeFile(e.io.?, .{ .sub_path = argv[j + 1], .data = e.stdout });
                        break;
                    }
                }
                return .{ .code = e.code, .ok = e.code == 0, .stdout = "" };
            }
            return .{
                .code = e.code,
                .ok = e.code == 0,
                .stdout = try arena.dupe(u8, e.stdout),
            };
        }
        return error.UnexpectedCommand;
    }
};

const testing = std.testing;

test "Fake: answers a scripted argv and records the call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew list --full-name --installed-on-request", .stdout = "ripgrep\n" }},
    };
    const r = fake.runner();

    const res = try r.run(a, &.{ "brew", "list", "--full-name", "--installed-on-request" });
    try testing.expect(res.ok);
    try testing.expectEqualStrings("ripgrep\n", res.stdout);
    try testing.expect(fake.called("brew list --full-name --installed-on-request"));
}

test "Fake: an unscripted command fails rather than returning empty output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: Fake = .{ .arena = a, .entries = &.{} };
    const r = fake.runner();

    try testing.expectError(error.UnexpectedCommand, r.run(a, &.{ "brew", "install", "ripgrep" }));
}

test "Fake: a scripted failure is raised, not answered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew --version", .fail = error.FileNotFound }},
    };
    const r = fake.runner();

    try testing.expectError(error.FileNotFound, r.run(a, &.{ "brew", "--version" }));
}

test "Fake: a nonzero scripted code is not ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew --version", .code = 127 }},
    };
    const r = fake.runner();

    const res = try r.run(a, &.{ "brew", "--version" });
    try testing.expect(!res.ok);
    try testing.expectEqual(@as(u8, 127), res.code);
}

test "Fake: stdin handed to a call is recorded against it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: Fake = .{ .arena = a, .entries = &.{.{ .argv = "plugin id", .stdout = "x\n" }} };
    const r = fake.runner();

    _ = try r.runInput(a, &.{ "plugin", "id" }, "{ name = \"x\" }\n");
    try testing.expectEqualStrings("{ name = \"x\" }\n", fake.inputTo("plugin id").?);
}

test "Fake: records whether each call was captured or streamed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew list", .stdout = "x\n" },
        .{ .argv = "brew install x" },
        .{ .argv = "plugin bootstrap" },
    } };
    const r = fake.runner();

    _ = try r.run(a, &.{ "brew", "list" });
    _ = try r.stream(a, &.{ "brew", "install", "x" });
    _ = try r.streamInput(a, &.{ "plugin", "bootstrap" }, "y\n");
    _ = try r.invoke(a, &.{ "brew", "list" }, null, false);
    try testing.expectEqualSlices(bool, &.{ false, true, true, false }, fake.streamed.items);
    try testing.expectEqual(@as(usize, 4), fake.calls.items.len);
}

test "Process: a real command that exceeds its bound is killed and reported" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p: Process = .{ .io = std.testing.io, .timeout_ms = 200 };
    const res = try p.runner().run(a, &.{ "sleep", "5" });
    try testing.expect(res.timed_out);
    try testing.expect(!res.ok);
}

test "Process: a streamed call is not bounded by the captured bound" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The captured bound is far shorter than the child; the streamed one
    // is the default, none.
    var p: Process = .{ .io = std.testing.io, .timeout_ms = 100 };
    const res = try p.runner().stream(a, &.{ "sleep", "0.5" });
    try testing.expect(res.ok);
    try testing.expect(!res.timed_out);
}

test "Process: a streamed child that honours the interrupt ends before the grace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var p: Process = .{ .io = io, .install_timeout_ms = 200, .grace_ms = 20_000 };
    const started = Io.Clock.awake.now(io);
    const res = try p.runner().stream(a, &.{ "sleep", "30" });
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(res.timed_out);
    try testing.expect(!res.ok);
    // SIGINT ended it; a kill after the 20s grace would show here.
    try testing.expect(elapsed_ms < 5000);
}

test "Process: a streamed child that ignores the interrupt is killed after the grace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    // `exec` so the sleeping process is the direct child: the kill ends it
    // rather than orphaning a sleep that outlives the test.
    var p: Process = .{ .io = io, .install_timeout_ms = 200, .grace_ms = 500 };
    const started = Io.Clock.awake.now(io);
    const res = try p.runner().stream(a, &.{ "sh", "-c", "trap '' INT; exec sleep 30" });
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(res.timed_out);
    try testing.expect(!res.ok);
    // Ended by the kill: after the grace, and well before the child's own 30s.
    try testing.expect(elapsed_ms >= 700);
    try testing.expect(elapsed_ms < 5000);
}

/// A scratch path for a child to write its own pid (`$$`) to, so a test can
/// ask afterwards whether that child's group still has a member.
fn pidFilePath(a: std.mem.Allocator, io: Io, tmp: *const std.testing.TmpDir) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "pid" });
}

fn pidIn(a: std.mem.Allocator, io: Io, path: []const u8) !std.posix.pid_t {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64));
    return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, " \t\r\n"), 10);
}

/// Whether nothing answers to the process group `pgid` within `ms`. Polled:
/// a member the child left behind is reaped by init a moment after it dies,
/// and until then a zombie may still answer to signal 0 on some systems.
fn groupGone(io: Io, pgid: std.posix.pid_t, ms: i64) bool {
    if (builtin.os.tag == .windows) return true;
    const started = Io.Clock.awake.now(io);
    while (true) {
        if (!signal(-pgid, @enumFromInt(0))) return true;
        if (started.durationTo(Io.Clock.awake.now(io)).toMilliseconds() > ms) return false;
        Process.timeoutOf(20).sleep(io) catch return false;
    }
}

test "Process: a streamed shell's foreground child dies with it at the bound" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const pid_file = try pidFilePath(a, io, &tmp);

    // The shell defers the interrupt until `sleep` exits; only a signal to
    // the whole group reaches the sleep. With the shell alone signaled, the
    // grace passes, the shell is killed, and the sleep runs on for 30s.
    var p: Process = .{ .io = io, .install_timeout_ms = 300, .grace_ms = 500 };
    const started = Io.Clock.awake.now(io);
    const res = try p.runner().stream(a, &.{ "sh", "-c", "echo $$ > \"$0\"; sleep 30", pid_file });
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(res.timed_out);
    try testing.expect(!res.ok);
    try testing.expect(elapsed_ms < 3000);
    try testing.expect(groupGone(io, try pidIn(a, io, pid_file), 2000));
}

test "Process: a streamed shell's background helper is killed once the shell is reaped" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const pid_file = try pidFilePath(a, io, &tmp);

    // A `cmd &` child of a non-interactive shell ignores SIGINT, so the
    // group interrupt ends only the shell's `wait`; the shell exiting on it
    // cancels the grace kill, and the helper would outlive the call.
    var p: Process = .{ .io = io, .install_timeout_ms = 300, .grace_ms = 20_000 };
    const started = Io.Clock.awake.now(io);
    const res = try p.runner().stream(a, &.{ "sh", "-c", "echo $$ > \"$0\"; sleep 30 & wait", pid_file });
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(res.timed_out);
    try testing.expect(!res.ok);
    try testing.expect(elapsed_ms < 5000);
    try testing.expect(groupGone(io, try pidIn(a, io, pid_file), 2000));
}

test "Process: a streamed shell that traps the interrupt ends before the grace, and is a timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const pid_file = try pidFilePath(a, io, &tmp);

    // `wait` is interruptible where a foreground `sleep` is not: the trap
    // runs as soon as the interrupt lands, and the shell exits 3 on its
    // own -- reported as the timeout it is, not as exit 3.
    var p: Process = .{ .io = io, .install_timeout_ms = 300, .grace_ms = 20_000 };
    const started = Io.Clock.awake.now(io);
    const res = try p.runner().stream(a, &.{ "sh", "-c", "trap 'exit 3' INT; echo $$ > \"$0\"; sleep 30 & wait", pid_file });
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(res.timed_out);
    try testing.expect(!res.ok);
    try testing.expect(elapsed_ms < 5000);
    try testing.expect(groupGone(io, try pidIn(a, io, pid_file), 2000));
}

test "Process: a streamed child that exits in time is neither a timeout nor an interrupt" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p: Process = .{ .io = std.testing.io, .install_timeout_ms = 10_000, .grace_ms = 500 };
    const res = try p.runner().stream(a, &.{ "sh", "-c", "exit 4" });
    try testing.expect(!res.timed_out);
    try testing.expect(!res.ok);
    try testing.expectEqual(@as(u8, 4), res.code);
}

test "installTimeoutMs: unset is unbounded, and a non-integer warns and falls back" {
    var map: EnvironMap = .init(testing.allocator);
    defer map.deinit();
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try testing.expectEqual(@as(i64, 0), installTimeoutMs(&map, &w));
    try testing.expectEqual(@as(i64, 0), installTimeoutMs(null, &w));
    try testing.expectEqual(@as(usize, 0), w.buffered().len);

    try map.put("MOX_INSTALL_TIMEOUT_MS", " 1500\n");
    try testing.expectEqual(@as(i64, 1500), installTimeoutMs(&map, &w));
    try testing.expectEqual(@as(usize, 0), w.buffered().len);

    try map.put("MOX_INSTALL_TIMEOUT_MS", "soon");
    try testing.expectEqual(@as(i64, 0), installTimeoutMs(&map, &w));
    try testing.expectEqualStrings("mox: MOX_INSTALL_TIMEOUT_MS=soon: not an integer; using default (0ms)\n", w.buffered());
}

test "killGroupAfter: a child already gone at the bound is not reported timed out" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    // No process has this pid, so the kill reaches nothing and must not
    // count as a timeout.
    var guard: Guard = .{};
    const deadline: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(20), .clock = .awake } };
    killGroupAfter(io, deadline.toDeadline(io), 2_147_483_000, &guard);
    try testing.expect(!guard.fired);
}

test "killGroupOf: reaches a live child, and reports a pid nothing answers to as already gone" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    try testing.expect(!killGroupOf(2_147_483_000));

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sleep", "30" },
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = own_group,
    });
    try testing.expect(killGroupOf(child.id.?));
    _ = try child.wait(io);
}

test "sweepScratch: a dead process's files go, this process's and a live one's stay" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const scratch = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "state" });
    const tmp_dir = try scratchTmpDir(a, scratch);
    try Io.Dir.cwd().createDirPath(io, tmp_dir);

    const mine = try std.fmt.allocPrint(a, "stdin-{d}.txt", .{processId()});
    const files = [_][]const u8{ "stdin-2147483000.txt", "winget-export-2147483000.json", mine, "stdin-1.txt", "notes.txt" };
    for (files) |f| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ tmp_dir, f }), .data = "x" });
    }

    sweepScratch(io, a, scratch);

    // pid 1 is always alive; the impossible pid never is; a file not named
    // for a pid is not this sweep's to touch.
    for (files, [_]bool{ false, false, true, true, true }) |f, remains| {
        const path = try std.fs.path.join(a, &.{ tmp_dir, f });
        const present = if (Io.Dir.cwd().access(io, path, .{})) |_| true else |_| false;
        try testing.expectEqual(remains, present);
    }
}

test "sweepScratch: a scratch directory that does not exist is nothing to sweep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    sweepScratch(std.testing.io, arena.allocator(), "/nonexistent/mox-scratch");
}

test "runPowerShell: pwsh is tried first, and powershell answers when it is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\\r\\x.ps1 available", .fail = error.FileNotFound },
        .{ .argv = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\r\\x.ps1 available", .stdout = "ok\n" },
    } };
    const res = try runPowerShell(fake.runner(), a, &.{ "C:\\r\\x.ps1", "available" }, null, false);
    try testing.expect(res.ok);
    try testing.expectEqualStrings("ok\n", res.stdout);
    try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try testing.expectEqualStrings("pwsh -NoProfile -ExecutionPolicy Bypass -File C:\\r\\x.ps1 available", fake.calls.items[0]);
    try testing.expectEqualStrings("powershell -NoProfile -ExecutionPolicy Bypass -File C:\\r\\x.ps1 available", fake.calls.items[1]);
}

test "runPowerShell: a pwsh that exists is not retried, and another failure is not an absent host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var present: Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pwsh -NoProfile -ExecutionPolicy Bypass -File x.ps1", .code = 3 },
    } };
    const res = try runPowerShell(present.runner(), a, &.{"x.ps1"}, null, true);
    try testing.expectEqual(@as(u8, 3), res.code);
    try testing.expectEqual(@as(usize, 1), present.calls.items.len);

    var denied: Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pwsh -NoProfile -ExecutionPolicy Bypass -File x.ps1", .fail = error.AccessDenied },
    } };
    try testing.expectError(error.AccessDenied, runPowerShell(denied.runner(), a, &.{"x.ps1"}, null, true));
    try testing.expectEqual(@as(usize, 1), denied.calls.items.len);
}

test "Runner.invoke: only a pwsh script invocation goes through the host fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const script = try powerShellArgv(a, "pwsh", &.{ "x.ps1", "list" });
    try testing.expectEqualStrings("list", powerShellScriptOf(script).?[1]);
    try testing.expect(powerShellScriptOf(&.{ "pwsh", "-Command", "x" }) == null);
    try testing.expect(powerShellScriptOf(&.{ "scoop", "export" }) == null);

    var fake: Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pwsh -NoProfile -ExecutionPolicy Bypass -File x.ps1 list", .fail = error.FileNotFound },
        .{ .argv = "powershell -NoProfile -ExecutionPolicy Bypass -File x.ps1 list", .stdout = "a\n" },
        .{ .argv = "scoop export", .fail = error.FileNotFound },
    } };
    const res = try fake.runner().invoke(a, script, "", false);
    try testing.expectEqualStrings("a\n", res.stdout);
    try testing.expectError(error.FileNotFound, fake.runner().invoke(a, &.{ "scoop", "export" }, null, false));
}

test "Process: a helper the child left holding the pipe dies with it at the bound" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    // `sleep` keeps the pipe's write end after `sh` would have exited; a
    // kill that reached only `sh` would leave the read blocked for 5s.
    var p: Process = .{ .io = io, .timeout_ms = 300 };
    const started = Io.Clock.awake.now(io);
    const res = try p.runner().run(a, &.{ "sh", "-c", "sleep 5 | cat" });
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(res.timed_out);
    try testing.expect(elapsed_ms < 3000);
}

test "Process: a child that never stops writing is ended at the cap, not waited on" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var p: Process = .{ .io = io, .timeout_ms = 10_000 };
    const started = Io.Clock.awake.now(io);
    try testing.expectError(error.StreamTooLong, p.runner().run(a, &.{ "sh", "-c", "yes" }));
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(elapsed_ms < 8000);
}

test "Process: a child that ignores SIGTERM is still ended at the bound" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var p: Process = .{ .io = io, .timeout_ms = 300 };
    const started = Io.Clock.awake.now(io);
    const res = try p.runner().run(a, &.{ "sh", "-c", "trap '' TERM; sleep 5" });
    const elapsed_ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(res.timed_out);
    try testing.expect(elapsed_ms < 3000);
}

test "Process: stdin bytes reach the child and stdout is captured" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    const scratch = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    var p: Process = .{ .io = std.testing.io, .scratch_dir = scratch };
    const res = try p.runner().runInput(a, &.{"cat"}, "hello from stdin\n");
    try testing.expect(res.ok);
    try testing.expectEqualStrings("hello from stdin\n", res.stdout);
}
