//! The free-space check an apply makes before it installs anything.
//!
//! An install that runs out of disk does not always fail cleanly: a vendor
//! installer that hit ENOSPC has been seen to hang for good, holding the
//! whole apply with it. So before the first install, each volume the
//! installs write to is measured, and one below the threshold is named with
//! the space it has. A warning, never a refusal: mox cannot know how much a
//! given set of packages needs, and a machine that is short of space may
//! still have enough for what is missing.
//!
//! Measured with `df -P -k`, whose output POSIX fixes, through the same
//! runner every manager query goes through: no filesystem ABI to declare per
//! platform, and a test scripts the answer like any other call.

const std = @import("std");
const exec = @import("exec.zig");

const Io = std.Io;

/// The least free space installs proceed under without a warning. A fresh
/// machine's bundle of a hundred formulae and a few dozen casks downloads
/// several GiB, and a cask is held three times over while it installs -- the
/// download, the copy staged under the temporary directory, the installed
/// app -- so a few GiB free can run out part-way through one large cask.
pub const default_min_free_bytes: u64 = 10 << 30;

/// One volume found short of space, with the paths that live on it.
pub const Low = struct {
    mount: []const u8,
    free_bytes: u64,
    paths: []const []const u8,
};

/// Measure the volume of each of `paths` and answer the ones with less than
/// `min_free` available, in the order their first path was given. A path
/// that cannot be measured is said on `w` and left out.
pub fn lowVolumes(
    arena: std.mem.Allocator,
    runner: exec.Runner,
    paths: []const []const u8,
    min_free: u64,
    w: *Io.Writer,
    prefix: []const u8,
) ![]const Low {
    var mounts: std.ArrayList([]const u8) = .empty;
    var frees: std.ArrayList(u64) = .empty;
    var members: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    outer: for (paths) |path| {
        const res = runner.run(arena, &.{ "df", "-P", "-k", "--", path }) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                try w.print("{s}: the free space under {s} could not be measured (`df -P -k`: {s}); the installs go ahead unchecked\n", .{ prefix, path, exec.errorText(e) });
                continue;
            },
        };
        const got = (if (res.ok and !res.timed_out) parseDf(res.stdout) else null) orelse {
            try w.print("{s}: the free space under {s} could not be measured (`df -P -k` {s}); the installs go ahead unchecked\n", .{
                prefix,
                path,
                if (res.timed_out) "timed out" else if (!res.ok) "failed" else "answered in a shape mox does not read",
            });
            continue;
        };
        for (mounts.items, 0..) |m, i| {
            if (!std.mem.eql(u8, m, got.mount)) continue;
            try members.items[i].append(arena, path);
            continue :outer;
        }
        try mounts.append(arena, try arena.dupe(u8, got.mount));
        try frees.append(arena, got.free_bytes);
        var one: std.ArrayList([]const u8) = .empty;
        try one.append(arena, path);
        try members.append(arena, one);
    }

    var out: std.ArrayList(Low) = .empty;
    for (mounts.items, frees.items, members.items) |m, free, ps| {
        if (free >= min_free) continue;
        try out.append(arena, .{ .mount = m, .free_bytes = free, .paths = ps.items });
    }
    return out.toOwnedSlice(arena);
}

/// Say each low volume on `w`, one line each.
pub fn warn(w: *Io.Writer, prefix: []const u8, lows: []const Low, min_free: u64) !void {
    for (lows) |low| {
        try w.print("{s}: only {f} free on the volume holding ", .{ prefix, gib(low.free_bytes) });
        for (low.paths, 0..) |p, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", p });
        try w.print(" (mounted at {s}); an install that runs out of space can fail part-way or hang, so free at least {f} before going on\n", .{ low.mount, gib(min_free) });
    }
}

const Gib = struct {
    bytes: u64,

    pub fn format(self: Gib, w: *Io.Writer) Io.Writer.Error!void {
        const tenths = self.bytes * 10 / (1 << 30);
        if (tenths % 10 == 0) return w.print("{d} GiB", .{tenths / 10});
        try w.print("{d}.{d} GiB", .{ tenths / 10, tenths % 10 });
    }
};

fn gib(bytes: u64) Gib {
    return .{ .bytes = bytes };
}

pub const Measured = struct {
    mount: []const u8,
    free_bytes: u64,
};

/// The second line of `df -P -k`: filesystem, 1024-blocks, used, available,
/// capacity, then the mount point. Both ends may hold spaces -- macOS's
/// automounter names a filesystem `map auto_home` -- so the line is read
/// from the capacity column, the one token ending in `%`: the available
/// count is the token before it, the mount point everything after it.
pub fn parseDf(text: []const u8) ?Measured {
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next() orelse return null;
    const line = std.mem.trimEnd(u8, lines.next() orelse return null, " \t\r");
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    var before: ?[]const u8 = null;
    while (tokens.next()) |tok| {
        if (tok.len > 1 and tok[tok.len - 1] == '%') {
            const mount = std.mem.trimStart(u8, line[tokens.index..], " \t");
            if (mount.len == 0) return null;
            // Signed: a filesystem holding blocks back for root reports a
            // negative count once ordinary users have overrun it.
            const kib = std.fmt.parseInt(i64, before orelse return null, 10) catch return null;
            return .{ .mount = mount, .free_bytes = @as(u64, @intCast(@max(kib, 0))) * 1024 };
        }
        before = tok;
    }
    return null;
}

const testing = std.testing;

test "parseDf: the available column in bytes, and a mount point that holds a space" {
    const got = parseDf(
        \\Filesystem   1024-blocks      Used Available Capacity Mounted on
        \\/dev/disk3s5   488245288 412345678  3355443    99%    /Volumes/Macintosh HD
        \\
    ).?;
    try testing.expectEqualStrings("/Volumes/Macintosh HD", got.mount);
    try testing.expectEqual(@as(u64, 3355443 * 1024), got.free_bytes);
    // macOS's automounter names its filesystem with a space in it.
    const auto = parseDf(
        \\Filesystem    1024-blocks Used Available Capacity  Mounted on
        \\map auto_home           0    0         0   100%    /System/Volumes/Data/home
        \\
    ).?;
    try testing.expectEqualStrings("/System/Volumes/Data/home", auto.mount);
    try testing.expectEqual(@as(u64, 0), auto.free_bytes);
    // Overrun into the blocks kept for root: no space, never a parse failure.
    const overrun = parseDf(
        \\Filesystem 1024-blocks Used Available Capacity Mounted on
        \\/dev/sda1     1000000 1050000  -50000   106% /
        \\
    ).?;
    try testing.expectEqual(@as(u64, 0), overrun.free_bytes);
    try testing.expect(parseDf("Filesystem 1024-blocks Used Available Capacity Mounted on\n") == null);
    try testing.expect(parseDf("") == null);
}

test "lowVolumes: paths sharing a volume are measured into one line, and a roomy volume says nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const header = "Filesystem 1024-blocks Used Available Capacity Mounted on\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "df -P -k -- /", .stdout = header ++ "/dev/disk3s5 488245288 485000000 3355444 99% /System/Volumes/Data\n" },
        .{ .argv = "df -P -k -- /private/tmp", .stdout = header ++ "/dev/disk3s5 488245288 485000000 3355444 99% /System/Volumes/Data\n" },
    } };
    var said: Io.Writer.Allocating = .init(a);
    const paths = [_][]const u8{ "/", "/private/tmp" };
    const lows = try lowVolumes(a, fake.runner(), &paths, default_min_free_bytes, &said.writer, "mox apply");
    try testing.expectEqual(@as(usize, 1), lows.len);
    try testing.expectEqual(@as(usize, 2), lows[0].paths.len);
    try warn(&said.writer, "mox apply", lows, default_min_free_bytes);
    try testing.expectEqualStrings(
        "mox apply: only 3.2 GiB free on the volume holding /, /private/tmp (mounted at /System/Volumes/Data); an install that runs out of space can fail part-way or hang, so free at least 10 GiB before going on\n",
        said.written(),
    );

    // The same volume against a lower threshold has room, and says nothing.
    said.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), (try lowVolumes(a, fake.runner(), &paths, 1 << 30, &said.writer, "mox apply")).len);
    try testing.expectEqualStrings("", said.written());
}

test "lowVolumes: a volume df cannot answer for is said, and the rest are still measured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "df -P -k -- /", .code = 1 },
    } };
    var said: Io.Writer.Allocating = .init(a);
    const lows = try lowVolumes(a, fake.runner(), &.{"/"}, default_min_free_bytes, &said.writer, "mox apply");
    try testing.expectEqual(@as(usize, 0), lows.len);
    try testing.expectEqualStrings("mox apply: the free space under / could not be measured (`df -P -k` failed); the installs go ahead unchecked\n", said.written());
}
