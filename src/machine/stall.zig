//! Saying so when a child that holds the user's terminal goes quiet.
//!
//! A streamed install, a manager's installer, and a setup script all write
//! straight to mox's own stdout and stderr, so mox never sees a byte of what
//! they print. A vendor installer that wedges -- one stuck after the disk
//! filled -- then stalls the whole apply with nothing on the screen to say
//! that anything is still waiting. A streamed call is unbounded by default
//! (an install may compile for hours), so a notice is what this adds, never
//! a kill: `MOX_INSTALL_TIMEOUT_MS` stays the one way to ask for that.
//!
//! What the child prints is observed without being intercepted. Putting a
//! pipe between the child and the terminal would turn its stdout into a
//! non-terminal, and installers then drop their progress bars and colour,
//! and some change what they ask; a pseudo-terminal would keep that but
//! takes the real terminal's modes, size, and job control into mox's hands.
//! Instead the watcher reads the modification time and size of mox's own
//! stdout and stderr: a write to a terminal, a pipe, or a regular file
//! advances them (measured on macOS 15 for a pty and a pipe; Linux updates a
//! tty's mtime at most every 8 seconds, which a notice measured in minutes
//! does not notice). Where neither stream can be observed that way -- a
//! character device that is not a terminal, such as `/dev/null`, a socket,
//! or any stream on Windows -- the notice falls back to elapsed time and
//! says the child has been running that long, not that it has been silent.

const std = @import("std");
const builtin = @import("builtin");

const job = @import("job.zig");

const Io = std.Io;

/// The first notice after this much silence, and one more every time as
/// much again has passed. Long enough that a slow download or a compile
/// that prints between steps never sets it off; short enough that a wedged
/// run is named while the user is still there to read it.
pub const default_after_ms: i64 = 5 * 60 * 1000;

/// How often the streams are looked at. A fraction of `after_ms`, so a
/// notice lands within a few seconds of its threshold.
pub const default_poll_ms: i64 = 10 * 1000;

/// What the watcher compares between looks: a value that changes whenever
/// the child writes, or null when the streams cannot be observed.
pub const Probe = struct {
    ctx: ?*anyopaque = null,
    stampFn: *const fn (ctx: ?*anyopaque, io: Io) ?u64,

    pub fn stamp(self: Probe, io: Io) ?u64 {
        return self.stampFn(self.ctx, io);
    }
};

pub const Config = struct {
    /// `<= 0` turns the notice off.
    after_ms: i64 = default_after_ms,
    poll_ms: i64 = default_poll_ms,
    probe: Probe = output_probe,
};

/// One watched call. `label` names the step in the notice
/// (`mox apply: brew: logi-options+`); `out` is written by the watcher alone
/// for the length of the call, so it never shares a buffer with the writer
/// the caller goes back to once the child is reaped.
pub const Watch = struct {
    io: Io,
    config: Config,
    label: []const u8,
    out: *Io.Writer,

    /// Watch until canceled. Run with `io.concurrent` beside the wait for
    /// the child, and canceled once the child is reaped. The sleep is the
    /// one cancelation point: a look at the streams and a notice swallow
    /// their errors, and a cancel they consumed would leave every later
    /// sleep uncancelable.
    pub fn run(self: *Watch) Io.Cancelable!void {
        const cfg = self.config;
        if (cfg.after_ms <= 0) return;
        const poll_ms = @max(@min(cfg.poll_ms, cfg.after_ms), 1);
        const started = Io.Clock.awake.now(self.io);
        var last = self.look();
        const observed = last != null;
        var quiet_since = started;
        var said: i64 = 0;
        while (true) {
            try sleepMs(self.io, poll_ms);
            const now = Io.Clock.awake.now(self.io);
            if (observed) {
                const seen = self.look();
                if (seen != last) {
                    last = seen;
                    quiet_since = now;
                    said = 0;
                    continue;
                }
            }
            const threshold = cfg.after_ms * (said + 1);
            if (quiet_since.durationTo(now).toMilliseconds() < threshold) continue;
            said += 1;
            self.say(threshold, observed);
            // The notice is itself a write to the stream being watched, and
            // must not read as the child having spoken.
            if (observed) last = self.look();
        }
    }

    /// Written with SIGTTOU blocked in this thread: mox is a background
    /// group while the child holds the terminal, and under `stty tostop` a
    /// write from there would stop mox.
    fn look(self: *Watch) ?u64 {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        return self.config.probe.stamp(self.io);
    }

    fn say(self: *Watch, after_ms: i64, observed: bool) void {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        const mask = job.blockTtou();
        defer job.restoreThreadMask(mask);
        writeNotice(self.out, self.label, after_ms, observed) catch {};
        self.out.flush() catch {};
    }
};

/// The notice for a watch labelled `label` passing `after_ms`.
pub fn writeNotice(w: *Io.Writer, label: []const u8, after_ms: i64, observed: bool) Io.Writer.Error!void {
    var buf: [32]u8 = undefined;
    const span = formatSpan(&buf, after_ms);
    if (observed) {
        try w.print("{s} has printed nothing for {s}; it may be waiting for an answer on the terminal (Ctrl-C stops the run)\n", .{ label, span });
    } else {
        try w.print("{s} has been running for {s}; it may be waiting for an answer on the terminal (Ctrl-C stops the run)\n", .{ label, span });
    }
}

/// Whether `said` is exactly the first `n` notices of a quiet watch every
/// `after_ms`, for some `n` from `least` up: what a watch over a child that
/// ran past `least` thresholds says, however much longer a loaded machine
/// kept it running.
pub fn isNoticeRun(arena: std.mem.Allocator, said: []const u8, label: []const u8, after_ms: i64, least: usize) !bool {
    var want: Io.Writer.Allocating = .init(arena);
    var n: usize = 0;
    while (want.written().len <= said.len) : (n += 1) {
        if (n >= least and std.mem.eql(u8, want.written(), said)) return true;
        try writeNotice(&want.writer, label, after_ms * @as(i64, @intCast(n + 1)), true);
    }
    return false;
}

fn sleepMs(io: Io, ms: i64) Io.Cancelable!void {
    const t: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(ms), .clock = .awake } };
    try t.sleep(io);
}

/// `ms` in the coarsest whole unit that states it exactly: `5m`, `90s`,
/// `250ms`. A notice names a threshold it passed, never a measured time, so
/// the same run prints the same words.
pub fn formatSpan(buf: []u8, ms: i64) []const u8 {
    if (ms > 0 and @rem(ms, 60_000) == 0) return std.fmt.bufPrint(buf, "{d}m", .{@divExact(ms, 60_000)}) catch "";
    if (ms > 0 and @rem(ms, 1000) == 0) return std.fmt.bufPrint(buf, "{d}s", .{@divExact(ms, 1000)}) catch "";
    return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch "";
}

/// The production probe: mox's own stdout and stderr, which the child
/// inherits and writes through.
pub const output_probe: Probe = .{ .stampFn = outputStamp };

fn outputStamp(_: ?*anyopaque, io: Io) ?u64 {
    if (builtin.os.tag == .windows) return null;
    var st: [2]?Io.File.Stat = undefined;
    for ([_]Io.File{ .stdout(), .stderr() }, [_]c_int{ 1, 2 }, &st) |f, fd, *slot| {
        const got = f.stat(io) catch null;
        slot.* = if (got) |g| (if (observable(g.kind, std.c.isatty(fd) != 0)) g else null) else null;
    }
    return streamsStamp(st);
}

/// A stamp over the streams that can be observed, or null when neither can.
/// One that cannot (`mox apply > /dev/null`) is left out rather than
/// voiding the other: a child writing to the terminal on stderr is still
/// seen to write.
fn streamsStamp(streams: [2]?Io.File.Stat) ?u64 {
    var h = std.hash.Wyhash.init(0);
    var any = false;
    for (streams) |maybe| {
        const s = maybe orelse continue;
        any = true;
        h.update(std.mem.asBytes(&s.mtime.nanoseconds));
        h.update(std.mem.asBytes(&s.size));
    }
    return if (any) h.final() else null;
}

/// Whether a write to a stream of this kind moves its modification time:
/// a terminal, a pipe, and a regular file do; `/dev/null` and other
/// character devices that are not terminals do not, and a socket is not
/// known to.
pub fn observable(kind: Io.File.Kind, is_tty: bool) bool {
    return switch (kind) {
        .file, .named_pipe => true,
        .character_device => is_tty,
        else => false,
    };
}

const testing = std.testing;

/// A probe whose stamp is whatever the test last set.
const ScriptedProbe = struct {
    value: std.atomic.Value(u64) = .init(0),
    observed: bool = true,

    fn probe(self: *ScriptedProbe) Probe {
        return .{ .ctx = self, .stampFn = stampOf };
    }

    fn stampOf(ctx: ?*anyopaque, _: Io) ?u64 {
        const self: *ScriptedProbe = @ptrCast(@alignCast(ctx.?));
        if (!self.observed) return null;
        return self.value.load(.acquire);
    }
};

/// Run a watch for `ms`, then cancel it, and answer with what it said.
fn watchFor(a: std.mem.Allocator, cfg: Config, ms: i64, poke: ?*ScriptedProbe) ![]const u8 {
    const io = testing.io;
    var out: Io.Writer.Allocating = .init(a);
    var w: Watch = .{ .io = io, .config = cfg, .label = "mox apply: brew: logi-options+", .out = &out.writer };
    var fut = try io.concurrent(Watch.run, .{&w});
    if (poke) |p| {
        // Output arrives halfway through, then stops again.
        try sleepMs(io, @divTrunc(ms, 2));
        _ = p.value.fetchAdd(1, .acq_rel);
        try sleepMs(io, ms - @divTrunc(ms, 2));
    } else {
        try sleepMs(io, ms);
    }
    fut.cancel(io) catch {};
    return out.written();
}

test "formatSpan: the coarsest unit that states the span exactly" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("5m", formatSpan(&buf, 300_000));
    try testing.expectEqualStrings("90s", formatSpan(&buf, 90_000));
    try testing.expectEqualStrings("250ms", formatSpan(&buf, 250));
}

test "Watch: a silent child is named once per interval, each naming the silence so far" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p: ScriptedProbe = .{};
    const said = try watchFor(arena.allocator(), .{ .after_ms = 500, .poll_ms = 20, .probe = p.probe() }, 1250, null);
    try testing.expectStringStartsWith(said, "mox apply: brew: logi-options+ has printed nothing for 500ms; it may be waiting for an answer on the terminal (Ctrl-C stops the run)\n" ++
        "mox apply: brew: logi-options+ has printed nothing for 1s; it may be waiting for an answer on the terminal (Ctrl-C stops the run)\n");
    // A loaded machine may run the watch past a third threshold, never
    // say anything else.
    try testing.expect(try isNoticeRun(arena.allocator(), said, "mox apply: brew: logi-options+", 500, 2));
}

test "Watch: output restarts the silence, so a child that keeps printing is never named" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p: ScriptedProbe = .{};
    // 750ms of silence, output, then 750ms more: neither stretch reaches
    // 1s, so nothing is said.
    const said = try watchFor(arena.allocator(), .{ .after_ms = 1000, .poll_ms = 20, .probe = p.probe() }, 1500, &p);
    try testing.expectEqualStrings("", said);
}

test "Watch: streams that cannot be observed fall back to elapsed time, and say so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p: ScriptedProbe = .{ .observed = false };
    const said = try watchFor(arena.allocator(), .{ .after_ms = 500, .poll_ms = 20, .probe = p.probe() }, 750, null);
    try testing.expectEqualStrings(
        "mox apply: brew: logi-options+ has been running for 500ms; it may be waiting for an answer on the terminal (Ctrl-C stops the run)\n",
        said,
    );
}

test "Watch: a notice turned off says nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var p: ScriptedProbe = .{};
    const said = try watchFor(arena.allocator(), .{ .after_ms = 0, .poll_ms = 20, .probe = p.probe() }, 100, null);
    try testing.expectEqualStrings("", said);
}

fn statAt(ns: i96, size: u64) Io.File.Stat {
    var st: Io.File.Stat = undefined;
    st.mtime = .{ .nanoseconds = ns };
    st.size = size;
    return st;
}

test "streamsStamp: one stream that cannot be observed leaves the other watched" {
    try testing.expect(streamsStamp(.{ null, null }) == null);
    const before = streamsStamp(.{ null, statAt(1, 10) }).?;
    try testing.expectEqual(before, streamsStamp(.{ null, statAt(1, 10) }).?);
    try testing.expect(before != streamsStamp(.{ null, statAt(2, 12) }).?);
    try testing.expect(streamsStamp(.{ statAt(1, 10), null }) != null);
}

test "isNoticeRun: the first n notices, from the least on, and nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = "x has printed nothing for 1s; it may be waiting for an answer on the terminal (Ctrl-C stops the run)\n";
    const two = one ++ "x has printed nothing for 2s; it may be waiting for an answer on the terminal (Ctrl-C stops the run)\n";
    try testing.expect(try isNoticeRun(a, one, "x", 1000, 1));
    try testing.expect(try isNoticeRun(a, two, "x", 1000, 1));
    try testing.expect(!try isNoticeRun(a, one, "x", 1000, 2));
    try testing.expect(!try isNoticeRun(a, "", "x", 1000, 1));
    try testing.expect(!try isNoticeRun(a, one ++ "noise\n", "x", 1000, 1));
}

test "observable: a terminal, a pipe and a file are; /dev/null and a socket are not" {
    try testing.expect(observable(.character_device, true));
    try testing.expect(observable(.named_pipe, false));
    try testing.expect(observable(.file, false));
    try testing.expect(!observable(.character_device, false));
    try testing.expect(!observable(.unix_domain_socket, false));
}

/// A probe that does cancelable work and swallows its errors, the way the
/// production probe's `stat` does, and panics once the watch outlives a
/// cancel by more looks than a single poll can take.
const SwallowingProbe = struct {
    canceled: std.atomic.Value(bool) = .init(false),
    looks_since: std.atomic.Value(u32) = .init(0),

    fn probe(self: *SwallowingProbe) Probe {
        return .{ .ctx = self, .stampFn = stampOf };
    }

    fn stampOf(ctx: ?*anyopaque, io: Io) ?u64 {
        const self: *SwallowingProbe = @ptrCast(@alignCast(ctx.?));
        if (self.canceled.load(.acquire) and self.looks_since.fetchAdd(1, .acq_rel) >= 3)
            @panic("the watch kept looking after it was canceled");
        sleepMs(io, 200) catch {};
        return 0;
    }
};

test "Watch: a cancel that lands while the streams are looked at still ends the watch" {
    const io = testing.io;
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var p: SwallowingProbe = .{};
    var w: Watch = .{ .io = io, .config = .{ .after_ms = 60_000, .poll_ms = 1, .probe = p.probe() }, .label = "x", .out = &out.writer };
    var fut = try io.concurrent(Watch.run, .{&w});
    try sleepMs(io, 50);
    p.canceled.store(true, .release);
    fut.cancel(io) catch {};
    try testing.expect(p.looks_since.load(.acquire) <= 1);
}
