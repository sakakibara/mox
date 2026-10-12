//! Run ids: `YYYYMMDDTHHMMSSZ`, with a `-N` suffix when that second is taken.
//! One id names a run's journal, its generation and its trash directory.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const durable = @import("durable.zig");

pub const id_len = "YYYYMMDDTHHMMSSZ".len;

/// Format an epoch-seconds value as an id, e.g. `20260710T081500Z`.
pub fn formatId(epoch_secs: u64) [id_len]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = epoch_secs };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    var out: [id_len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

/// The epoch seconds `idNow` gives instead of the real clock, set from
/// `MOX_TEST_CLOCK` in a test build or one made with `-Dtest-clock`, and
/// never otherwise.
pub var test_clock: ?u64 = null;
pub const takes_test_clock = build_options.test_clock or @import("builtin").is_test;

pub fn idNow(io: Io) [id_len]u8 {
    if (takes_test_clock) if (test_clock) |secs| return formatId(secs);
    const now = Io.Clock.real.now(io).toSeconds();
    return formatId(if (now > 0) @intCast(now) else 0);
}

/// Oldest first, a same-second `-N` suffix by its number.
pub fn older(_: void, a: []const u8, b: []const u8) bool {
    const sa = split(a);
    const sb = split(b);
    const o = std.mem.order(u8, sa.base, sb.base);
    if (o != .eq) return o == .lt;
    if (sa.n != sb.n) return sa.n < sb.n;
    return std.mem.lessThan(u8, a, b);
}

fn split(id: []const u8) struct { base: []const u8, n: u64 } {
    if (id.len > id_len and id[id_len] == '-') {
        if (std.fmt.parseInt(u64, id[id_len + 1 ..], 10)) |n| return .{ .base = id[0..id_len], .n = n } else |_| {}
    }
    return .{ .base = id, .n = 1 };
}

/// True when `s` has the shape of an id.
pub fn isId(s: []const u8) bool {
    if (s.len < id_len) return false;
    for (s[0..id_len], 0..) |c, i| switch (i) {
        8 => if (c != 'T') return false,
        id_len - 1 => if (c != 'Z') return false,
        else => if (!std.ascii.isDigit(c)) return false,
    };
    if (s.len == id_len) return true;
    if (s[id_len] != '-' or s.len == id_len + 1) return false;
    for (s[id_len + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

pub const Dirs = struct {
    gen: []const u8,
    pending: []const u8,
    quarantine: []const u8,
    trash: []const u8,
};

/// What claims the id.
pub const Claim = enum { journal, trash };

/// An id of this second past every one already in `gen/`, `pending/`,
/// `trash/` and `quarantine/`, claimed by exclusive creation of its journal or
/// of its trash directory. Past, not only free: a dropped generation frees
/// its id, and taking it again would put this run before ones made after it.
pub fn claim(arena: std.mem.Allocator, io: Io, dirs: Dirs, how: Claim) ![]const u8 {
    return claimFrom(arena, io, dirs, how, idNow(io));
}

/// `claim`, with `base` as the second.
pub fn claimFrom(arena: std.mem.Allocator, io: Io, dirs: Dirs, how: Claim, base: [id_len]u8) ![]const u8 {
    var n = (try newestOf(io, dirs, &base)) + 1;
    while (true) : (n += 1) {
        const candidate = if (n == 1) try arena.dupe(u8, &base) else try std.fmt.allocPrint(arena, "{s}-{d}", .{ &base, n });
        switch (how) {
            .journal => {
                try durable.makeDir(io, dirs.pending);
                const path = try std.fmt.allocPrint(arena, "{s}{c}{s}.jsonl", .{ dirs.pending, std.fs.path.sep, candidate });
                const f = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = durable.privateFile() }) catch |e| switch (e) {
                    error.PathAlreadyExists => continue,
                    else => return e,
                };
                f.close(io);
            },
            .trash => {
                try Io.Dir.cwd().createDirPath(io, dirs.trash);
                Io.Dir.cwd().createDir(io, try std.fs.path.join(arena, &.{ dirs.trash, candidate }), .default_dir) catch |e| switch (e) {
                    error.PathAlreadyExists => continue,
                    else => return e,
                };
            },
        }
        return candidate;
    }
}

/// The highest suffix any entry of the four directories has for the second
/// `base`, the plain id counting as 1; 0 when none has it.
fn newestOf(io: Io, dirs: Dirs, base: []const u8) !u64 {
    var newest: u64 = 0;
    for ([_][]const u8{ dirs.gen, dirs.pending, dirs.trash, dirs.quarantine }) |dir_path| {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (!std.mem.startsWith(u8, e.name, base)) continue;
            const end = std.mem.indexOfScalarPos(u8, e.name, base.len, '.') orelse e.name.len;
            const name = e.name[0..end];
            if (!isId(name)) continue;
            const sp = split(name);
            if (!std.mem.eql(u8, sp.base, base)) continue;
            newest = @max(newest, sp.n);
        }
    }
    return newest;
}

test "formatId renders a known epoch" {
    const got = formatId(1783671300);
    try std.testing.expectEqualStrings("20260710T081500Z", &got);
}

test "older: a same-second suffix orders by number" {
    var ids = [_][]const u8{ "20260101T000001Z", "20260101T000000Z-10", "20260101T000000Z", "20260101T000000Z-2" };
    std.mem.sort([]const u8, &ids, {}, older);
    try std.testing.expectEqualStrings("20260101T000000Z", ids[0]);
    try std.testing.expectEqualStrings("20260101T000000Z-2", ids[1]);
    try std.testing.expectEqualStrings("20260101T000000Z-10", ids[2]);
    try std.testing.expect(isId("20260101T000000Z-10"));
    try std.testing.expect(!isId("20260101T000000Z-"));
    try std.testing.expect(!isId("current"));
}

test "claim: an id is past every one taken in any of the four directories" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const dirs: Dirs = .{
        .gen = try std.fs.path.join(a, &.{ root, "gen" }),
        .pending = try std.fs.path.join(a, &.{ root, "pending" }),
        .quarantine = try std.fs.path.join(a, &.{ root, "quarantine" }),
        .trash = try std.fs.path.join(a, &.{ root, "trash" }),
    };
    try tmp.dir.createDirPath(io, "gen");
    try tmp.dir.createDirPath(io, "quarantine");
    try tmp.dir.createDirPath(io, "trash/20260710T081500Z-3");
    try tmp.dir.writeFile(io, .{ .sub_path = "gen/20260710T081500Z.json", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "quarantine/20260710T081500Z-2.jsonl", .data = "" });
    const base = formatId(1783671300);
    try std.testing.expectEqualStrings("20260710T081500Z-4", try claimFrom(a, io, dirs, .journal, base));
    try std.testing.expectEqualStrings("20260710T081500Z-5", try claimFrom(a, io, dirs, .trash, base));
    // An id freed by a dropped generation is not taken again.
    try tmp.dir.deleteFile(io, "gen/20260710T081500Z.json");
    try std.testing.expectEqualStrings("20260710T081500Z-6", try claimFrom(a, io, dirs, .journal, base));
}
