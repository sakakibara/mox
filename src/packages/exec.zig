//! The seam every backend adapter reaches a package manager through.
//!
//! An adapter never spawns a process itself: it asks a `Runner`. Production
//! hands it `Process`; a test hands it a scripted stand-in, so adapter logic
//! is exercised without a package manager installed and without mutating the
//! machine running the suite. Real-manager coverage is a separate integration
//! suite, where actually invoking brew is the point.

const std = @import("std");

const Io = std.Io;
const EnvironMap = std.process.Environ.Map;

pub const Result = struct {
    code: u8,
    ok: bool,
    stdout: []const u8,
    stderr: []const u8,
};

pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8) anyerror!Result,

    pub fn run(self: Runner, arena: std.mem.Allocator, argv: []const []const u8) anyerror!Result {
        return self.runFn(self.ctx, arena, argv);
    }
};

/// Runs the argv as a real child process. `env` is the environment mox itself
/// reads through, so a manager invoked here sees the same HOME and PATH mox
/// resolved its own paths from; null falls back to the process environment.
pub const Process = struct {
    io: Io,
    env: ?*const EnvironMap = null,

    pub fn runner(self: *Process) Runner {
        return .{ .ctx = self, .runFn = runImpl };
    }

    fn runImpl(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8) anyerror!Result {
        const self: *Process = @ptrCast(@alignCast(ctx));
        const res = try std.process.run(arena, self.io, .{
            .argv = argv,
            .environ_map = self.env,
        });
        const code: u8 = switch (res.term) {
            .exited => |c| c,
            else => 255,
        };
        return .{
            .code = code,
            .ok = res.term == .exited and code == 0,
            .stdout = res.stdout,
            .stderr = res.stderr,
        };
    }
};

/// A scripted runner: answers each argv from a table, records every call, and
/// fails the call rather than inventing output when no entry matches, so a
/// test can never pass on a command the adapter was not supposed to run.
pub const Fake = struct {
    pub const Entry = struct {
        /// Matched against the argv joined by spaces.
        argv: []const u8,
        stdout: []const u8 = "",
        stderr: []const u8 = "",
        code: u8 = 0,
    };

    entries: []const Entry,
    calls: std.ArrayList([]const u8) = .empty,
    arena: std.mem.Allocator,

    pub fn runner(self: *Fake) Runner {
        return .{ .ctx = self, .runFn = runImpl };
    }

    pub fn called(self: *const Fake, argv: []const u8) bool {
        for (self.calls.items) |c| {
            if (std.mem.eql(u8, c, argv)) return true;
        }
        return false;
    }

    fn runImpl(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8) anyerror!Result {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const joined = try std.mem.join(self.arena, " ", argv);
        try self.calls.append(self.arena, joined);
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.argv, joined)) {
                return .{
                    .code = e.code,
                    .ok = e.code == 0,
                    .stdout = try arena.dupe(u8, e.stdout),
                    .stderr = try arena.dupe(u8, e.stderr),
                };
            }
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
        .entries = &.{.{ .argv = "brew leaves --installed-on-request", .stdout = "ripgrep\n" }},
    };
    const r = fake.runner();

    const res = try r.run(a, &.{ "brew", "leaves", "--installed-on-request" });
    try testing.expect(res.ok);
    try testing.expectEqualStrings("ripgrep\n", res.stdout);
    try testing.expect(fake.called("brew leaves --installed-on-request"));
}

test "Fake: an unscripted command fails rather than returning empty output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: Fake = .{ .arena = a, .entries = &.{} };
    const r = fake.runner();

    try testing.expectError(error.UnexpectedCommand, r.run(a, &.{ "brew", "install", "ripgrep" }));
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
