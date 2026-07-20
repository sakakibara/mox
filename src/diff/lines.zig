//! Myers O(ND) line diff.
//!
//! Produces hunks describing how to turn line-array `a` into line-array `b`.
//! A hunk is a maximal run of changed lines: `a_len` lines starting at
//! `a_start` (in `a`) are replaced by `b_len` lines starting at `b_start`
//! (in `b`). Pure insertions have `a_len == 0`; pure deletions `b_len == 0`.
//! Line indices are 0-based.

const std = @import("std");

/// Hard cap on lines per side. A diff over more than this errors rather than
/// attempting the O(ND) search, whose worst-case memory grows with the edit
/// distance; the cap turns a pathological input into a clean failure.
pub const max_lines: usize = 200_000;

pub const DiffError = error{ TooManyLines, OutOfMemory };

pub const Hunk = struct {
    a_start: u32,
    a_len: u32,
    b_start: u32,
    b_len: u32,
};

/// Split `content` into lines, dropping newline bytes. A single trailing
/// newline does NOT yield an extra empty line; `"a\nb\n"` and `"a\nb"` both
/// split to `{ "a", "b" }`. Empty content yields zero lines. Slices point
/// into `content`, which must outlive the result.
pub fn splitLines(arena: std.mem.Allocator, content: []const u8) ![]const []const u8 {
    if (content.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(arena);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        // Drop the empty segment produced by a trailing newline.
        if (it.peek() == null and line.len == 0) break;
        try out.append(arena, line);
    }
    return out.toOwnedSlice(arena);
}

const Move = struct {
    kind: enum { eq, del, ins },
};

/// Compute the hunks turning `a` into `b`.
pub fn diff(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8) DiffError![]const Hunk {
    if (a.len > max_lines or b.len > max_lines) return error.TooManyLines;
    if (a.len == 0 and b.len == 0) return &.{};

    const trace = try shortestEdit(arena, a, b);
    const moves = try backtrack(arena, trace, a.len, b.len);

    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer hunks.deinit(arena);

    var a_pos: u32 = 0;
    var b_pos: u32 = 0;
    var in_hunk = false;
    var cur: Hunk = undefined;
    for (moves) |m| {
        switch (m.kind) {
            .eq => {
                if (in_hunk) {
                    try hunks.append(arena, cur);
                    in_hunk = false;
                }
                a_pos += 1;
                b_pos += 1;
            },
            .del => {
                if (!in_hunk) {
                    cur = .{ .a_start = a_pos, .a_len = 0, .b_start = b_pos, .b_len = 0 };
                    in_hunk = true;
                }
                cur.a_len += 1;
                a_pos += 1;
            },
            .ins => {
                if (!in_hunk) {
                    cur = .{ .a_start = a_pos, .a_len = 0, .b_start = b_pos, .b_len = 0 };
                    in_hunk = true;
                }
                cur.b_len += 1;
                b_pos += 1;
            },
        }
    }
    if (in_hunk) try hunks.append(arena, cur);

    return hunks.toOwnedSlice(arena);
}

/// Forward pass of Myers' algorithm. Returns the trace: one snapshot of the
/// furthest-reaching-path array `V` per edit-distance step `d`, enough to
/// reconstruct the edit script by backtracking.
fn shortestEdit(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8) DiffError![]const []const isize {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    const max: usize = a.len + b.len;
    const offset: isize = @intCast(max);
    const vlen = 2 * max + 1;

    var v = try arena.alloc(isize, vlen);
    @memset(v, 0);

    var trace: std.ArrayList([]const isize) = .empty;
    errdefer trace.deinit(arena);

    var d: usize = 0;
    while (d <= max) : (d += 1) {
        try trace.append(arena, try arena.dupe(isize, v));
        const di: isize = @intCast(d);
        var k: isize = -di;
        while (k <= di) : (k += 2) {
            var x: isize = undefined;
            if (k == -di or (k != di and v[@intCast(k - 1 + offset)] < v[@intCast(k + 1 + offset)])) {
                x = v[@intCast(k + 1 + offset)]; // down: insertion from b
            } else {
                x = v[@intCast(k - 1 + offset)] + 1; // right: deletion from a
            }
            var y: isize = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[@intCast(k + offset)] = x;
            if (x >= n and y >= m) return trace.toOwnedSlice(arena);
        }
    }
    // Unreachable: an edit distance of at most n+m always exists.
    return error.OutOfMemory;
}

/// Reconstruct the forward edit script from the trace as a list of per-line
/// moves (equal / delete / insert), in forward order.
fn backtrack(arena: std.mem.Allocator, trace: []const []const isize, n_usize: usize, m_usize: usize) DiffError![]const Move {
    const max: usize = n_usize + m_usize;
    const offset: isize = @intCast(max);

    var rev: std.ArrayList(Move) = .empty;
    errdefer rev.deinit(arena);

    var x: isize = @intCast(n_usize);
    var y: isize = @intCast(m_usize);

    var d: isize = @intCast(trace.len);
    while (d > 0) {
        d -= 1;
        const v = trace[@intCast(d)];
        const k = x - y;
        var prev_k: isize = undefined;
        if (k == -d or (k != d and v[@intCast(k - 1 + offset)] < v[@intCast(k + 1 + offset)])) {
            prev_k = k + 1;
        } else {
            prev_k = k - 1;
        }
        const prev_x = v[@intCast(prev_k + offset)];
        const prev_y = prev_x - prev_k;

        while (x > prev_x and y > prev_y) {
            try rev.append(arena, .{ .kind = .eq });
            x -= 1;
            y -= 1;
        }
        if (d > 0) {
            if (x == prev_x) {
                try rev.append(arena, .{ .kind = .ins });
            } else {
                try rev.append(arena, .{ .kind = .del });
            }
        }
        x = prev_x;
        y = prev_y;
    }

    std.mem.reverse(Move, rev.items);
    return rev.toOwnedSlice(arena);
}

const testing = std.testing;

fn expectHunks(expected: []const Hunk, actual: []const Hunk) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, got| try testing.expectEqual(e, got);
}

test "splitLines: trailing newline yields no empty final line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const with_nl = try splitLines(arena.allocator(), "a\nb\n");
    try testing.expectEqual(@as(usize, 2), with_nl.len);
    const without_nl = try splitLines(arena.allocator(), "a\nb");
    try testing.expectEqual(@as(usize, 2), without_nl.len);
    const empty = try splitLines(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), empty.len);
    const blank_mid = try splitLines(arena.allocator(), "a\n\n");
    try testing.expectEqual(@as(usize, 2), blank_mid.len);
    try testing.expectEqualStrings("", blank_mid[1]);
}

test "diff: identical inputs produce no hunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{ "one", "two", "three" };
    const hunks = try diff(arena.allocator(), &a, &a);
    try testing.expectEqual(@as(usize, 0), hunks.len);
}

test "diff: both empty produce no hunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty: []const []const u8 = &.{};
    const hunks = try diff(arena.allocator(), empty, empty);
    try testing.expectEqual(@as(usize, 0), hunks.len);
}

test "diff: pure insertion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{ "one", "three" };
    const b = [_][]const u8{ "one", "two", "three" };
    const hunks = try diff(arena.allocator(), &a, &b);
    try expectHunks(&.{.{ .a_start = 1, .a_len = 0, .b_start = 1, .b_len = 1 }}, hunks);
}

test "diff: insertion into empty a" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a: []const []const u8 = &.{};
    const b = [_][]const u8{ "x", "y" };
    const hunks = try diff(arena.allocator(), a, &b);
    try expectHunks(&.{.{ .a_start = 0, .a_len = 0, .b_start = 0, .b_len = 2 }}, hunks);
}

test "diff: pure deletion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{ "one", "two", "three" };
    const b = [_][]const u8{ "one", "three" };
    const hunks = try diff(arena.allocator(), &a, &b);
    try expectHunks(&.{.{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 0 }}, hunks);
}

test "diff: replace one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{ "one", "two", "three" };
    const b = [_][]const u8{ "one", "TWO", "three" };
    const hunks = try diff(arena.allocator(), &a, &b);
    try expectHunks(&.{.{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 1 }}, hunks);
}

test "diff: interleaved edits produce separate hunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{ "a", "b", "c", "d", "e" };
    const b = [_][]const u8{ "a", "B", "c", "d", "E" };
    const hunks = try diff(arena.allocator(), &a, &b);
    try expectHunks(&.{
        .{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 1 },
        .{ .a_start = 4, .a_len = 1, .b_start = 4, .b_len = 1 },
    }, hunks);
}

test "diff: pathological alternating input completes within a bounded budget" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    // Fully-alternating sequences maximize the Myers edit distance (~2N), the
    // O(ND) worst case. Bound N so a regression that reintroduced unbounded
    // work fails the test's implicit `zig build test` timeout rather than
    // hanging, and assert the search still terminates with a sane result.
    const n = 4000;
    const a = try al.alloc([]const u8, n);
    const b = try al.alloc([]const u8, n);
    for (a, 0..) |*line, i| line.* = if (i % 2 == 0) "x" else "y";
    for (b, 0..) |*line, i| line.* = if (i % 2 == 0) "y" else "x";
    const hunks = try diff(al, a, b);
    // Reconstruct b by splicing the hunks into a: proves the search terminated
    // with a correct edit script, not just that it returned.
    var rebuilt: std.ArrayList([]const u8) = .empty;
    var a_pos: u32 = 0;
    for (hunks) |h| {
        while (a_pos < h.a_start) : (a_pos += 1) try rebuilt.append(al, a[a_pos]);
        try rebuilt.appendSlice(al, b[h.b_start .. h.b_start + h.b_len]);
        a_pos += h.a_len;
    }
    while (a_pos < a.len) : (a_pos += 1) try rebuilt.append(al, a[a_pos]);
    try testing.expectEqual(b.len, rebuilt.items.len);
    for (b, rebuilt.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "diff: exceeding the line cap errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = try arena.allocator().alloc([]const u8, max_lines + 1);
    for (a) |*line| line.* = "x";
    const b = [_][]const u8{"x"};
    try testing.expectError(error.TooManyLines, diff(arena.allocator(), a, &b));
}
