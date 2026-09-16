//! The seam every backend reaches a package manager -- or a plugin -- through.
//!
//! An adapter never spawns a process itself: it asks a `Runner`. Production
//! hands it `Process`; a test hands it a scripted stand-in, so adapter logic
//! is exercised without a package manager installed and without mutating the
//! machine running the suite. Real-manager coverage is a separate integration
//! suite, where actually invoking brew is the point.
//!
//! Every real call is time-bounded, with the same default and kill a setup
//! script gets: a query blocked on a manager's lock is a reported failure,
//! never a hung `mox status`.

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

fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
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
    stderr: []const u8,
    /// The call was killed for exceeding its bound; `code` is meaningless.
    timed_out: bool = false,
};

pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!Result,
    streamFn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!Result,

    /// Run and capture stdout and stderr: for a query whose output mox parses.
    pub fn run(self: Runner, arena: std.mem.Allocator, argv: []const []const u8) anyerror!Result {
        return self.runFn(self.ctx, arena, argv, null);
    }

    /// `run` with bytes on the child's stdin, stdout captured and stderr left
    /// on the terminal: a plugin's own refusal reason reaches the user as
    /// written, and one pipe cannot deadlock against another.
    pub fn runInput(self: Runner, arena: std.mem.Allocator, argv: []const []const u8, stdin: []const u8) anyerror!Result {
        return self.runFn(self.ctx, arena, argv, stdin);
    }

    /// Run with mox's own stdout and stderr: for work the user waits on. An
    /// install compiles, downloads, and asks about disk space; capturing that
    /// would replace minutes of progress with a silent hang and throw the
    /// manager's own diagnostics away. `stdout`/`stderr` come back empty.
    pub fn stream(self: Runner, arena: std.mem.Allocator, argv: []const []const u8) anyerror!Result {
        return self.streamFn(self.ctx, arena, argv, null);
    }

    /// `stream` with bytes on the child's stdin.
    pub fn streamInput(self: Runner, arena: std.mem.Allocator, argv: []const []const u8, stdin: []const u8) anyerror!Result {
        return self.streamFn(self.ctx, arena, argv, stdin);
    }
};

/// Runs the argv as a real child process. `env` is the environment mox itself
/// reads through, so a manager invoked here sees the same HOME and PATH mox
/// resolved its own paths from; null falls back to the process environment.
/// `scratch_dir` backs a child's stdin with a file, which cannot deadlock the
/// way a pipe written alongside a pipe read can.
pub const Process = struct {
    io: Io,
    env: ?*const EnvironMap = null,
    scratch_dir: []const u8 = "",
    timeout_ms: i64 = default_timeout_ms,

    pub fn runner(self: *Process) Runner {
        return .{ .ctx = self, .runFn = runImpl, .streamFn = streamImpl };
    }

    fn timeout(self: *const Process) Io.Timeout {
        if (self.timeout_ms <= 0) return .none;
        return .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(self.timeout_ms), .clock = .awake } };
    }

    fn runImpl(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!Result {
        const self: *Process = @ptrCast(@alignCast(ctx));
        if (stdin) |bytes| return self.spawnWithStdin(arena, argv, bytes, .pipe, .inherit);

        const res = std.process.run(arena, self.io, .{
            .argv = argv,
            .environ_map = self.env,
            .timeout = self.timeout(),
        }) catch |e| switch (e) {
            error.Timeout => return .{ .code = 255, .ok = false, .stdout = "", .stderr = "", .timed_out = true },
            else => return e,
        };
        return fromTerm(res.term, res.stdout, res.stderr);
    }

    fn streamImpl(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!Result {
        const self: *Process = @ptrCast(@alignCast(ctx));
        return self.spawnWithStdin(arena, argv, stdin, .inherit, .inherit);
    }

    /// Spawn with stdin backed by a scratch file holding `stdin` (closed when
    /// null), the given stdout/stderr dispositions, and the timeout kill.
    fn spawnWithStdin(
        self: *Process,
        arena: std.mem.Allocator,
        argv: []const []const u8,
        stdin: ?[]const u8,
        stdout_io: std.process.SpawnOptions.StdIo,
        stderr_io: std.process.SpawnOptions.StdIo,
    ) anyerror!Result {
        const io = self.io;

        var stdin_file: ?Io.File = null;
        defer if (stdin_file) |f| f.close(io);
        var stdin_path: ?[]const u8 = null;
        // Removed once the child has been reaped, so a row file never lingers
        // in state and a second mox running beside this one never reads it.
        defer if (stdin_path) |p| Io.Dir.cwd().deleteFile(io, p) catch {};
        var stdin_io: std.process.SpawnOptions.StdIo = .close;
        if (stdin) |bytes| {
            try Io.Dir.cwd().createDirPath(io, self.scratch_dir);
            // Named per process: two mox runs sharing a state dir (a status
            // beside an apply) must not truncate each other's stdin mid-read.
            const name = try std.fmt.allocPrint(arena, "stdin-{d}.txt", .{processId()});
            const path = try std.fs.path.join(arena, &.{ self.scratch_dir, name });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
            stdin_path = path;
            stdin_file = try Io.Dir.cwd().openFile(io, path, .{});
            stdin_io = .{ .file = stdin_file.? };
        }

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .environ_map = self.env,
            .stdin = stdin_io,
            .stdout = stdout_io,
            .stderr = stderr_io,
        });

        var timed_out = false;
        var killer: ?Io.Future(void) = null;
        if (self.timeout_ms > 0) {
            if (child.id) |id| killer = io.async(run_scripts.killAfter, .{ io, self.timeout(), id, &timed_out });
        }

        var out: []const u8 = "";
        if (child.stdout) |f| {
            var buf: [4096]u8 = undefined;
            var r = f.reader(io, &buf);
            // A read that fails or overruns the bound is an error, never an
            // empty answer: an empty `list` would make every row missing.
            out = r.interface.allocRemaining(arena, .limited(8 << 20)) catch |e| {
                if (killer) |*k| _ = k.cancel(io);
                _ = child.wait(io) catch {};
                return e;
            };
        }

        const term = child.wait(io) catch |e| {
            if (killer) |*k| _ = k.cancel(io);
            return e;
        };
        if (killer) |*k| _ = k.cancel(io);

        var res = fromTerm(term, out, "");
        if (timed_out) {
            res.ok = false;
            res.timed_out = true;
        }
        return res;
    }
};

fn fromTerm(term: std.process.Child.Term, stdout: []const u8, stderr: []const u8) Result {
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{
        .code = code,
        .ok = term == .exited and code == 0,
        .stdout = stdout,
        .stderr = stderr,
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
        stderr: []const u8 = "",
        code: u8 = 0,
        /// Raised instead of answering, for the failures a manager reports by
        /// not being there at all.
        fail: ?anyerror = null,
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
    arena: std.mem.Allocator,

    pub fn runner(self: *Fake) Runner {
        return .{ .ctx = self, .runFn = runImpl, .streamFn = runImpl };
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
        const joined = try std.mem.join(self.arena, " ", argv);
        try self.calls.append(self.arena, joined);
        try self.inputs.append(self.arena, try self.arena.dupe(u8, stdin orelse ""));
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
            if (e.write_after) |flag| {
                for (argv, 0..) |a, j| {
                    if (std.mem.eql(u8, a, flag) and j + 1 < argv.len) {
                        try Io.Dir.cwd().writeFile(e.io.?, .{ .sub_path = argv[j + 1], .data = e.stdout });
                        break;
                    }
                }
                return .{ .code = e.code, .ok = e.code == 0, .stdout = "", .stderr = "" };
            }
            return .{
                .code = e.code,
                .ok = e.code == 0,
                .stdout = try arena.dupe(u8, e.stdout),
                .stderr = try arena.dupe(u8, e.stderr),
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
        .entries = &.{.{ .argv = "brew --version", .code = 127, .stderr = "not found" }},
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

test "Process: a real command that exceeds its bound is killed and reported" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p: Process = .{ .io = std.testing.io, .timeout_ms = 200 };
    const res = try p.runner().stream(a, &.{ "sleep", "5" });
    try testing.expect(res.timed_out);
    try testing.expect(!res.ok);
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
