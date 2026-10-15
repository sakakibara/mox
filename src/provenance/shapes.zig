//! A secret-bearing file's outline: every line of it as mox wrote it, a
//! line a resolved secret was written into kept by its shape, so a later
//! live copy of the file is matched line by line without the value being
//! stored.
//!
//! A shape is the literal pieces of one output line in order, with a slot
//! between each pair: `pieces[0]` comes before the first slot, the last
//! piece after the last slot, and either may be empty. The pieces are the
//! bytes of the composed output that are not secret. A shape with no
//! literal piece is a whole-line secret.
//!
//! A line matches a shape when it starts with the first piece, ends with
//! the last, and holds the pieces between in order in what is left, each
//! searched for from where the one before ended. The slots are the spans
//! between them. A whole-line shape matches every line.
//!
//! A live file is paired with its outline as a line diff pairs two files: an
//! outline line with a live line equal to it, a shape with a live line that
//! matches it. A shape the diff
//! leaves unpaired is then paired with the first free live line that
//! matches it, searched from the line after the one the entry before it is
//! paired with and then from the start, so a secret line moved is still
//! found. A shape paired with no live line is a secret line lost: changed
//! beyond its shape, its value may be anywhere, and every live line paired
//! with nothing is then replaced whole. So is one paired with a live line
//! equal to an outline line left unpaired, which took that line's place.

const std = @import("std");
const toml = @import("toml");
const yaml = @import("yaml");
const map = @import("map.zig");
const json_interp = @import("../compose/json_interp.zig");
const splitLines = @import("../diff/lines.zig").splitLines;

pub const Shape = struct {
    pieces: []const []const u8,

    pub fn wholeLine(s: Shape) bool {
        for (s.pieces) |p| if (p.len > 0) return false;
        return true;
    }
};

pub const whole_line: Shape = .{ .pieces = &.{ "", "" } };

/// One line of an outline.
pub const Entry = union(enum) {
    /// A line no secret was written into, as written.
    line: []const u8,
    /// A line a secret was written into.
    shape: Shape,
};

pub const Span = struct { start: usize, end: usize };

/// The forms in which compose, or a partial target's writer, writes a set
/// of values into a file: as written, JSON-escaped, and TOML- and
/// YAML-quoted (`text`, longest first), and, for a form of several lines,
/// its first and last lines, which share an output line with other text
/// (also in `text`), and its other lines, which fill an output line alone
/// (`lines`). A line of a form of several lines is one only from
/// `min_fragment` bytes: a shorter one, as common as `{`, is found in its
/// own file by the outline's slots.
pub const Forms = struct {
    text: []const []const u8 = &.{},
    lines: std.StringHashMapUnmanaged(void) = .empty,

    pub const none: Forms = .{};
};

pub fn writtenForms(arena: std.mem.Allocator, values: []const []const u8) !Forms {
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    var lines: std.StringHashMapUnmanaged(void) = .empty;
    for (values) |v| {
        if (v.len == 0) continue;
        for (try formsOf(arena, v)) |f| try addForm(arena, &set, &lines, f);
    }
    const text = try arena.dupe([]const u8, set.keys());
    std.mem.sort([]const u8, text, {}, struct {
        fn longer(_: void, x: []const u8, y: []const u8) bool {
            return x.len > y.len;
        }
    }.longer);
    return .{ .text = text, .lines = lines };
}

/// The whole forms of `v`: as written, JSON-escaped, TOML- and YAML-quoted.
fn formsOf(arena: std.mem.Allocator, v: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, v);
    var js: std.ArrayList(u8) = .empty;
    try json_interp.appendJsonString(arena, &js, v);
    try out.append(arena, js.items[1 .. js.items.len - 1]);
    if (try tomlForm(arena, v)) |t| try out.append(arena, t);
    if (try yamlForm(arena, v)) |y| try out.append(arena, y);
    return out.items;
}

fn addForm(arena: std.mem.Allocator, set: *std.StringArrayHashMapUnmanaged(void), lines: *std.StringHashMapUnmanaged(void), form: []const u8) !void {
    if (form.len == 0) return;
    try set.put(arena, form, {});
    if (std.mem.indexOfScalar(u8, form, '\n') == null) return;
    const first = form[0..std.mem.indexOfScalar(u8, form, '\n').?];
    const last = form[std.mem.lastIndexOfScalar(u8, form, '\n').? + 1 ..];
    for ([_][]const u8{ first, last }) |l| {
        const t = std.mem.trimEnd(u8, l, "\r");
        if (t.len >= min_fragment) try set.put(arena, t, {});
    }
    var it = std.mem.splitScalar(u8, form, '\n');
    while (it.next()) |l| {
        const t = std.mem.trimEnd(u8, l, "\r");
        if (t.len >= min_fragment) try lines.put(arena, t, {});
    }
}

/// `v` as TOML's encoder writes it as a string, without its quotes.
fn tomlForm(arena: std.mem.Allocator, v: []const u8) !?[]const u8 {
    var tbl: toml.Value.Table = .empty;
    try tbl.put(arena, "k", .{ .string = v });
    var aw: std.Io.Writer.Allocating = .init(arena);
    toml.encode(&aw.writer, .{ .table = tbl }, .{}) catch return null;
    const text = std.mem.trimEnd(u8, aw.written(), "\n");
    if (!std.mem.startsWith(u8, text, "k = ")) return null;
    return unquote(text["k = ".len..]);
}

/// `v` as YAML's emitter writes it as a string, without its quotes.
fn yamlForm(arena: std.mem.Allocator, v: []const u8) !?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    yaml.emit(&aw.writer, .{ .string = v }, .{}) catch return null;
    return unquote(std.mem.trimEnd(u8, aw.written(), "\n"));
}

fn unquote(text: []const u8) []const u8 {
    var t = text;
    for ([_][]const u8{ "\"\"\"", "'''", "\"", "'" }) |q| {
        if (t.len >= 2 * q.len and std.mem.startsWith(u8, t, q) and std.mem.endsWith(u8, t, q)) {
            t = t[q.len .. t.len - q.len];
            break;
        }
    }
    return t;
}

/// The spans of `line` that hold one of `forms`.
pub fn formSpans(arena: std.mem.Allocator, line: []const u8, forms: Forms, out: *std.ArrayList(Span)) !void {
    if (forms.lines.contains(std.mem.trimEnd(u8, line, "\r"))) try out.append(arena, .{ .start = 0, .end = line.len });
    try textSpans(arena, line, forms.text, out);
}

fn textSpans(arena: std.mem.Allocator, text: []const u8, forms: []const []const u8, out: *std.ArrayList(Span)) !void {
    for (forms) |f| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, f)) |at| {
            try out.append(arena, .{ .start = at, .end = at + f.len });
            i = at + 1;
        }
    }
}

/// The spans of `line` the slots of `shape` cover, or false when the line
/// does not match it.
pub fn match(arena: std.mem.Allocator, shape: Shape, line: []const u8, out: *std.ArrayList(Span)) !bool {
    const mark = out.items.len;
    if (try walk(arena, shape, line, out)) return true;
    out.shrinkRetainingCapacity(mark);
    return false;
}

/// Whether `line` matches `shape`.
pub fn matches(shape: Shape, line: []const u8) bool {
    return walk(undefined, shape, line, null) catch unreachable;
}

fn walk(arena: std.mem.Allocator, shape: Shape, line: []const u8, out: ?*std.ArrayList(Span)) !bool {
    const n = shape.pieces.len;
    if (n < 2) return false;
    const first = shape.pieces[0];
    const last = shape.pieces[n - 1];
    if (line.len < first.len + last.len) return false;
    if (!std.mem.startsWith(u8, line, first) or !std.mem.endsWith(u8, line, last)) return false;
    const end = line.len - last.len;
    var pos = first.len;
    for (shape.pieces[1 .. n - 1]) |piece| {
        const at = std.mem.indexOfPos(u8, line[0..end], pos, piece) orelse return false;
        if (out) |o| try o.append(arena, .{ .start = pos, .end = at });
        pos = at + piece.len;
    }
    if (out) |o| try o.append(arena, .{ .start = pos, .end = end });
    return true;
}

/// `line` with every byte under `spans` replaced: each maximal run by one
/// `marker`. An empty span replaces nothing.
pub fn mask(arena: std.mem.Allocator, line: []const u8, spans: []Span, marker: []const u8) ![]const u8 {
    if (spans.len == 0) return line;
    std.mem.sort(Span, spans, {}, struct {
        fn lt(_: void, x: Span, y: Span) bool {
            return x.start < y.start;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    var i: usize = 0;
    while (i < spans.len) {
        var s = spans[i];
        i += 1;
        if (s.end <= s.start) continue;
        while (i < spans.len and spans[i].start <= s.end) : (i += 1) s.end = @max(s.end, spans[i].end);
        if (s.start < pos) s.start = pos;
        if (s.end <= s.start) continue;
        try out.appendSlice(arena, line[pos..s.start]);
        try out.appendSlice(arena, marker);
        pos = s.end;
    }
    if (pos == 0 and out.items.len == 0) return line;
    try out.appendSlice(arena, line[pos..]);
    return out.items;
}

/// Per output line of `lines`, the spans that hold a secret: null for a line
/// no `.secret` segment covers. A run of secret lines is searched as one
/// text for the whole forms of `forms`, so a value of several lines is
/// found across them; a secret line in which none is found is a secret as a
/// whole.
pub fn secretSpans(
    arena: std.mem.Allocator,
    lines: []const []const u8,
    segments: []const map.Segment,
    forms: Forms,
) ![]const ?[]Span {
    const out = try arena.alloc(?[]Span, lines.len);
    @memset(out, null);
    const secret = try arena.alloc(bool, lines.len);
    @memset(secret, false);
    for (segments) |s| {
        if (s.origin != .secret) continue;
        var i: usize = s.out_start;
        while (i < @as(usize, s.out_start) + s.out_len and i < lines.len) : (i += 1) secret[i] = true;
    }
    var i: usize = 0;
    while (i < lines.len) {
        if (!secret[i]) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < lines.len and secret[j]) j += 1;
        var text: std.ArrayList(u8) = .empty;
        const starts = try arena.alloc(usize, j - i);
        for (lines[i..j], 0..) |l, k| {
            if (k > 0) try text.append(arena, '\n');
            starts[k] = text.items.len;
            try text.appendSlice(arena, l);
        }
        var found: std.ArrayList(Span) = .empty;
        try textSpans(arena, text.items, forms.text, &found);
        const merged = merge(found.items);
        // Spans are disjoint and in order, and so are the lines: one pass.
        var c: usize = 0;
        for (lines[i..j], starts, 0..) |l, start, k| {
            const end = start + l.len;
            while (c < merged.len and merged[c].end < start) c += 1;
            var spans: std.ArrayList(Span) = .empty;
            var x = c;
            while (x < merged.len and merged[x].start <= end) : (x += 1) {
                const lo = @max(merged[x].start, start);
                const hi = @min(merged[x].end, end);
                if (lo < hi or (lo == hi and merged[x].start <= start and merged[x].end >= end)) {
                    try spans.append(arena, .{ .start = lo - start, .end = hi - start });
                }
            }
            if (spans.items.len == 0) try spans.append(arena, .{ .start = 0, .end = l.len });
            out[i + k] = spans.items;
        }
        i = j;
    }
    return out;
}

/// `spans` sorted and with overlapping or touching ones joined, in place.
fn merge(spans: []Span) []Span {
    if (spans.len == 0) return spans;
    std.mem.sort(Span, spans, {}, struct {
        fn lt(_: void, x: Span, y: Span) bool {
            return x.start < y.start;
        }
    }.lt);
    var n: usize = 0;
    for (spans) |sp| {
        if (n > 0 and sp.start <= spans[n - 1].end) {
            spans[n - 1].end = @max(spans[n - 1].end, sp.end);
        } else {
            spans[n] = sp;
            n += 1;
        }
    }
    return spans[0..n];
}

/// The shape of `line` with `spans` as its slots.
pub fn shapeOf(arena: std.mem.Allocator, line: []const u8, spans: []Span) !Shape {
    std.mem.sort(Span, spans, {}, struct {
        fn lt(_: void, x: Span, y: Span) bool {
            return x.start < y.start;
        }
    }.lt);
    var pieces: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    var i: usize = 0;
    while (i < spans.len) {
        var s = spans[i];
        i += 1;
        while (i < spans.len and spans[i].start <= s.end) : (i += 1) s.end = @max(s.end, spans[i].end);
        if (s.start < pos) s.start = pos;
        try pieces.append(arena, line[pos..s.start]);
        pos = @max(pos, s.end);
    }
    try pieces.append(arena, line[pos..]);
    if (pieces.items.len < 2) return whole_line;
    return .{ .pieces = pieces.items };
}

/// The outline of `content`, whose provenance is `segments`, with `values`
/// the secret values its compose resolved: one entry per line. Empty when no
/// segment is a secret. A line no secret segment covers that holds a form
/// of one of `values` is a shape too, with a slot at each form, so no value
/// is kept in a line entry.
pub fn outlineOf(arena: std.mem.Allocator, content: []const u8, segments: []const map.Segment, values: []const []const u8) ![]const Entry {
    if (!map.hasSecret(segments)) return &.{};
    const lines = try splitLines(arena, content);
    const forms = try writtenForms(arena, values);
    const spans = try secretSpans(arena, lines, segments, forms);
    const out = try arena.alloc(Entry, lines.len);
    for (lines, spans, out) |l, sp, *o| {
        var found: std.ArrayList(Span) = .empty;
        if (sp == null) try formSpans(arena, l, forms, &found);
        // An outline is kept as JSON text, which holds only UTF-8.
        o.* = if (!std.unicode.utf8ValidateSlice(l))
            .{ .shape = whole_line }
        else if (sp) |slots|
            .{ .shape = try shapeOf(arena, l, slots) }
        else if (found.items.len > 0)
            .{ .shape = try shapeOf(arena, l, found.items) }
        else
            .{ .line = l };
    }
    return out;
}

/// How the lines of a live file pair with the entries of its outline.
pub const Pairing = struct {
    /// Per live line, the outline entry it is paired with.
    entry_of: []const ?u32,
    /// A shape is paired with no live line, or pairing could not finish:
    /// every live line paired with nothing is replaced whole.
    fail_closed: bool,
    /// The distinct shapes of the outline, which a live line paired with
    /// nothing is masked by.
    shapes: []const Shape,
    /// One of `shapes` is the whole-line shape.
    any_whole: bool,
};

/// The most edits the line diff that pairs a file with its outline looks
/// for, past which its pairs are dropped and every shape is paired one at
/// a time; and the most line comparisons pairing makes, past which it stops
/// and fails closed.
const max_edits: usize = 1024;
const max_comparisons: usize = 64 * 1024 * 1024;

/// Pair `lines`, a live file, with `outline`, the outline mox last wrote it
/// with.
pub fn pair(arena: std.mem.Allocator, outline: []const Entry, lines: []const []const u8) !Pairing {
    const entry_of = try arena.alloc(?u32, lines.len);
    @memset(entry_of, null);
    // With no secret line, a line shows the same paired or not.
    for (outline) |e| {
        if (e == .shape) break;
    } else return .{ .entry_of = entry_of, .fail_closed = false, .shapes = &.{}, .any_whole = false };
    const line_of = try arena.alloc(?u32, outline.len);
    @memset(line_of, null);
    var budget: usize = max_comparisons;
    const Eq = struct {
        outline: []const Entry,
        lines: []const []const u8,
        budget: *usize,
        fn eq(c: @This(), i: usize, j: usize) ?bool {
            if (c.budget.* == 0) return null;
            c.budget.* -= 1;
            return switch (c.outline[i]) {
                .line => |l| std.mem.eql(u8, l, c.lines[j]),
                .shape => |sh| matches(sh, c.lines[j]),
            };
        }
    };
    const ctx: Eq = .{ .outline = outline, .lines = lines, .budget = &budget };
    if (try alignBy(arena, outline.len, lines.len, ctx, Eq.eq)) |pairs| for (pairs) |p| {
        line_of[p[0]] = p[1];
        entry_of[p[1]] = p[0];
    };

    // The live line after the one the entry before pairs with.
    const hint = try arena.alloc(u32, outline.len);
    var next: u32 = 0;
    for (line_of, hint) |l, *h| {
        h.* = next;
        if (l) |j| next = j + 1;
    }
    var free: Free = try .init(arena, lines.len);
    for (entry_of, 0..) |e, j| if (e != null) free.take(j);

    var exhausted = false;
    // The shapes with a literal piece first, so the whole-line shapes, which
    // match any line, take what is left.
    for ([_]bool{ false, true }) |whole| for (outline, 0..) |e, i| {
        if (exhausted) break;
        if (e != .shape or line_of[i] != null or e.shape.wholeLine() != whole) continue;
        const start: usize = @min(hint[i], lines.len);
        var round: usize = 0;
        found: while (round < 2) : (round += 1) {
            const lo: usize = if (round == 0) start else 0;
            const hi: usize = if (round == 0) lines.len else start;
            var j = free.find(lo);
            while (j < hi) : (j = free.find(j + 1)) {
                if (budget == 0) {
                    exhausted = true;
                    break :found;
                }
                budget -= 1;
                if (!matches(e.shape, lines[j])) continue;
                line_of[i] = @intCast(j);
                entry_of[j] = @intCast(i);
                free.take(j);
                break :found;
            }
        }
    };

    // A line left that is equal to an outline line left.
    var by_text: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    for (lines, 0..) |l, j| if (entry_of[j] == null) {
        const gop = try by_text.getOrPut(arena, l);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, @intCast(j));
    };
    var taken_of: std.StringHashMapUnmanaged(usize) = .empty;
    for (outline, 0..) |e, i| {
        if (e != .line or line_of[i] != null) continue;
        const free_lines = by_text.get(e.line) orelse continue;
        const gop = try taken_of.getOrPut(arena, e.line);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        if (gop.value_ptr.* >= free_lines.items.len) continue;
        const j = free_lines.items[gop.value_ptr.*];
        gop.value_ptr.* += 1;
        line_of[i] = j;
        entry_of[j] = @intCast(i);
    }

    var fail_closed = exhausted;
    for (outline, line_of) |e, l| if (e == .shape and l == null) {
        fail_closed = true;
    };
    // A shape paired with a live line equal to an outline line left
    // unpaired took that line's place: the secret line it stands for may
    // be one the user edited, and is lost.
    if (!fail_closed) {
        var left: std.StringHashMapUnmanaged(void) = .empty;
        for (outline, line_of) |e, l| if (e == .line and l == null) try left.put(arena, e.line, {});
        if (left.count() > 0) for (entry_of, lines) |e, l| {
            if (e != null and outline[e.?] == .shape and left.contains(l)) fail_closed = true;
        };
    }
    var distinct: std.ArrayList(Shape) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var any_whole = false;
    for (outline) |e| {
        if (e != .shape) continue;
        if (e.shape.wholeLine()) any_whole = true;
        const key = try shapeKey(arena, e.shape);
        if ((try seen.getOrPut(arena, key)).found_existing) continue;
        try distinct.append(arena, e.shape);
    }
    // Masking each line paired with nothing by every shape must stay within
    // the bound too.
    if (!fail_closed and !any_whole) {
        var unpaired: usize = 0;
        for (entry_of) |e| if (e == null) {
            unpaired += 1;
        };
        if (unpaired > 0 and distinct.items.len > max_comparisons / unpaired) fail_closed = true;
    }
    return .{ .entry_of = entry_of, .fail_closed = fail_closed, .shapes = distinct.items, .any_whole = any_whole };
}

/// The free live lines, each found in amortized constant time.
const Free = struct {
    /// `next[j]` leads to the first free line at `j` or after; `n` for none.
    next: []u32,

    fn init(arena: std.mem.Allocator, n: usize) !Free {
        const next = try arena.alloc(u32, n + 1);
        for (next, 0..) |*x, j| x.* = @intCast(j);
        return .{ .next = next };
    }

    fn take(f: *Free, j: usize) void {
        f.next[j] = @intCast(j + 1);
    }

    fn find(f: *Free, from: usize) usize {
        var j = @min(from, f.next.len - 1);
        while (f.next[j] != j) j = f.next[j];
        var k = @min(from, f.next.len - 1);
        while (f.next[k] != k) {
            const up = f.next[k];
            f.next[k] = @intCast(j);
            k = up;
        }
        return j;
    }
};

/// The pairs of a shortest-edit line diff of `n` entries against `m`
/// lines, entry `i` and line `j` equal when `eq(ctx, i, j)` says so, found
/// by Myers' algorithm: null when it needs more than `max_edits` edits or
/// `eq` says it is out of comparisons.
fn alignBy(arena: std.mem.Allocator, n: usize, m: usize, ctx: anytype, comptime eq: fn (@TypeOf(ctx), usize, usize) ?bool) !?[]const [2]u32 {
    const max = n + m;
    const off: isize = @intCast(max + 1);
    const v = try arena.alloc(isize, 2 * max + 3);
    @memset(v, 0);
    var trace: std.ArrayList([]const isize) = .empty;
    const ni: isize = @intCast(n);
    const mi: isize = @intCast(m);
    var last: usize = 0;
    outer: for (0..@min(max, max_edits) + 1) |d| {
        const di: isize = @intCast(d);
        try trace.append(arena, try arena.dupe(isize, v[@intCast(off - di - 1)..@intCast(off + di + 2)]));
        var k: isize = -di;
        while (k <= di) : (k += 2) {
            var x: isize = if (k == -di or (k != di and v[@intCast(off + k - 1)] < v[@intCast(off + k + 1)]))
                v[@intCast(off + k + 1)]
            else
                v[@intCast(off + k - 1)] + 1;
            var y = x - k;
            while (x < ni and y < mi) {
                if (!(eq(ctx, @intCast(x), @intCast(y)) orelse return null)) break;
                x += 1;
                y += 1;
            }
            v[@intCast(off + k)] = x;
            if (x >= ni and y >= mi) {
                last = d;
                break :outer;
            }
        }
    } else return null;

    var pairs: std.ArrayList([2]u32) = .empty;
    var x: isize = ni;
    var y: isize = mi;
    var d: usize = last + 1;
    while (d > 0) {
        d -= 1;
        const di: isize = @intCast(d);
        if (d == 0) {
            while (x > 0 and y > 0) : ({
                x -= 1;
                y -= 1;
            }) try pairs.append(arena, .{ @intCast(x - 1), @intCast(y - 1) });
            break;
        }
        // `w[k + d + 1]` is the furthest x on diagonal k before edit d.
        const w = trace.items[d];
        const k = x - y;
        const prev_k = if (k == -di or (k != di and w[@intCast(k - 1 + di + 1)] < w[@intCast(k + 1 + di + 1)])) k + 1 else k - 1;
        const prev_x = w[@intCast(prev_k + di + 1)];
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) : ({
            x -= 1;
            y -= 1;
        }) try pairs.append(arena, .{ @intCast(x - 1), @intCast(y - 1) });
        x = prev_x;
        y = prev_y;
    }
    return pairs.items;
}

/// A text naming `s` alone: its pieces, each with its length before it.
fn shapeKey(arena: std.mem.Allocator, s: Shape) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s.pieces) |p| {
        try out.print(arena, "{d}:", .{p.len});
        try out.appendSlice(arena, p);
    }
    return out.items;
}

/// Live line `j`, `line`, of a file paired with `outline` by `p`, as diff
/// shows it: masked at the slots of the shape it
/// is paired with, kept as it is when paired with a line, and, paired with
/// nothing, replaced whole when `p` fails closed, else masked at the slots
/// of every shape of the outline it matches. Every one of `forms` is masked
/// wherever it occurs.
pub fn shown(arena: std.mem.Allocator, outline: []const Entry, p: Pairing, j: usize, line: []const u8, forms: Forms) ![]const u8 {
    var spans: std.ArrayList(Span) = .empty;
    if (p.entry_of[j]) |e| switch (outline[e]) {
        .shape => |sh| _ = try match(arena, sh, line, &spans),
        .line => {},
    } else {
        if (p.fail_closed) return map.line_redaction;
        if (p.any_whole) {
            try spans.append(arena, .{ .start = 0, .end = line.len });
        } else for (p.shapes) |sh| _ = try match(arena, sh, line, &spans);
    }
    try formSpans(arena, line, forms, &spans);
    return mask(arena, line, spans.items, map.secret_redaction);
}

/// The shortest line of a value of several lines that counts, on its own,
/// as a written form of the value outside the slots of its own file, and the
/// shortest form that counts in a file mox wrote no secret into.
pub const min_fragment: usize = 8;

/// Whether `content` holds a written form of one of `values` of at least
/// `min_fragment` bytes: a whole form anywhere, or a line of a form of
/// several lines.
pub fn holdsAny(arena: std.mem.Allocator, content: []const u8, values: []const []const u8) !bool {
    for (values) |v| {
        if (v.len == 0) continue;
        for (try formsOf(arena, v)) |f| {
            if (f.len >= min_fragment and std.mem.indexOf(u8, content, f) != null) return true;
            if (std.mem.indexOfScalar(u8, f, '\n') == null) continue;
            var it = std.mem.splitScalar(u8, f, '\n');
            while (it.next()) |l| {
                const t = std.mem.trimEnd(u8, l, "\r");
                if (t.len >= min_fragment and std.mem.indexOf(u8, content, t) != null) return true;
            }
        }
    }
    return false;
}

/// Whether `line` holds one of `forms` of at least `min_fragment` bytes.
pub fn holdsForm(line: []const u8, forms: Forms) bool {
    if (forms.lines.contains(std.mem.trimEnd(u8, line, "\r"))) return true;
    for (forms.text) |f| {
        if (f.len < min_fragment) break;
        if (std.mem.indexOf(u8, line, f) != null) return true;
    }
    return false;
}

/// `content` with every one of `forms` masked wherever it occurs.
pub fn maskForms(arena: std.mem.Allocator, content: []const u8, forms: Forms) ![]const u8 {
    const lines = try splitLines(arena, content);
    var out: std.ArrayList(u8) = .empty;
    var changed = false;
    for (lines, 0..) |l, j| {
        if (j > 0) try out.append(arena, '\n');
        var spans: std.ArrayList(Span) = .empty;
        try formSpans(arena, l, forms, &spans);
        const kept = try mask(arena, l, spans.items, map.secret_redaction);
        if (kept.ptr != l.ptr) changed = true;
        try out.appendSlice(arena, kept);
    }
    if (!changed) return content;
    if (content.len > 0 and content[content.len - 1] == '\n') try out.append(arena, '\n');
    return out.items;
}

const testing = std.testing;

test "match: a line starts with the first piece and ends with the last, the pieces between in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spans: std.ArrayList(Span) = .empty;
    const trailing: Shape = .{ .pieces = &.{ "tok=", "" } };
    try testing.expect(try match(a, trailing, "tok=abc # x", &spans));
    try testing.expectEqualStrings("tok=<s>", try mask(a, "tok=abc # x", spans.items, "<s>"));
    spans.clearRetainingCapacity();
    try testing.expect(!try match(a, trailing, "export tok=abc", &spans));
    try testing.expect(!matches(.{ .pieces = &.{ "token=", "" } }, "db_token=public"));
    try testing.expect(!matches(.{ .pieces = &.{ "token=", "\r" } }, "token=v"));
    try testing.expect(!matches(.{ .pieces = &.{ "ab", "ba" } }, "aba"));
    const quoted: Shape = .{ .pieces = &.{ "{\"pw\": \"", "\"}" } };
    try testing.expect(try match(a, quoted, "{\"pw\": \"ab\\\"cd\"}", &spans));
    try testing.expectEqualStrings("{\"pw\": \"<s>\"}", try mask(a, "{\"pw\": \"ab\\\"cd\"}", spans.items, "<s>"));
    spans.clearRetainingCapacity();
    try testing.expect(!try match(a, quoted, "pw=ab", &spans));
    try testing.expectEqual(@as(usize, 0), spans.items.len);
    try testing.expect(try match(a, whole_line, "anything", &spans));
    try testing.expectEqualStrings("<s>", try mask(a, "anything", spans.items, "<s>"));
    spans.clearRetainingCapacity();
    const pw: Shape = .{ .pieces = &.{ "pw=\"", "\"" } };
    try testing.expect(try match(a, pw, "pw=\"ab\"cdLEAK\"", &spans));
    try testing.expectEqualStrings("pw=\"<s>\"", try mask(a, "pw=\"ab\"cdLEAK\"", spans.items, "<s>"));
    spans.clearRetainingCapacity();
    const two: Shape = .{ .pieces = &.{ "u=", " p=", ";" } };
    try testing.expect(try match(a, two, "u=me p=pw;", &spans));
    try testing.expectEqualStrings("u=<s> p=<s>;", try mask(a, "u=me p=pw;", spans.items, "<s>"));
}

test "outlineOf: every line, a value of several lines giving slot-only middle lines and keeping the text around it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = "a\nkey=BEGIN\nMID\nEND;\nz\n";
    const segs = [_]map.Segment{
        .{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } },
        .{ .out_start = 1, .out_len = 3, .origin = .secret },
        .{ .out_start = 4, .out_len = 1, .origin = .{ .base = .{ .line = 3 } } },
    };
    const outline = try outlineOf(a, content, &segs, &.{"BEGIN\nMID\nEND"});
    try testing.expectEqual(@as(usize, 5), outline.len);
    try testing.expectEqualStrings("a", outline[0].line);
    try testing.expectEqualStrings("key=", outline[1].shape.pieces[0]);
    try testing.expectEqualStrings("", outline[1].shape.pieces[1]);
    try testing.expect(outline[2].shape.wholeLine());
    try testing.expectEqualStrings("", outline[3].shape.pieces[0]);
    try testing.expectEqualStrings(";", outline[3].shape.pieces[1]);
    try testing.expectEqualStrings("z", outline[4].line);
    for (outline[1..4]) |e| for (e.shape.pieces) |p| {
        try testing.expect(std.mem.indexOf(u8, p, "BEGIN") == null);
        try testing.expect(std.mem.indexOf(u8, p, "MID") == null);
    };
}

test "outlineOf: a JSON-escaped value is a slot, a secret line holding no known value is a whole-line secret, and two lines of one shape are two entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = [_]map.Segment{.{ .out_start = 0, .out_len = 4, .origin = .secret }};
    const outline = try outlineOf(a, "{\"pw\": \"ab\\\"cd\"}\nunknown\nt = x1\nt = x2\n", &segs, &.{ "ab\"cd", "x1", "x2" });
    try testing.expectEqual(@as(usize, 4), outline.len);
    try testing.expectEqualStrings("{\"pw\": \"", outline[0].shape.pieces[0]);
    try testing.expectEqualStrings("\"}", outline[0].shape.pieces[1]);
    try testing.expect(outline[1].shape.wholeLine());
    try testing.expectEqualStrings("t = ", outline[2].shape.pieces[0]);
    try testing.expectEqualStrings("t = ", outline[3].shape.pieces[0]);
}

fn testOutline(a: std.mem.Allocator, content: []const u8, secret_lines: []const u32, values: []const []const u8) ![]const Entry {
    var segs: std.ArrayList(map.Segment) = .empty;
    for (secret_lines) |l| try segs.append(a, .{ .out_start = l, .out_len = 1, .origin = .secret });
    return outlineOf(a, content, segs.items, values);
}

test "pair: a secret line edited beyond its shape fails closed, though another line holds the shape's first piece" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outline = try testOutline(a, "db_token=public\ntoken=OLD\n", &.{1}, &.{"OLD"});
    const lines = [_][]const u8{ "db_token=public", "token = OLD" };
    const p = try pair(a, outline, &lines);
    try testing.expect(p.fail_closed);
    try testing.expectEqualStrings("db_token=public", try shown(a, outline, p, 0, lines[0], .none));
    try testing.expectEqualStrings(map.line_redaction, try shown(a, outline, p, 1, lines[1], .none));
}

test "pair: two secret lines of one shape need a live line each" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outline = try testOutline(a, "[a]\ntoken = A\n[b]\ntoken = B\n", &.{ 1, 3 }, &.{ "A", "B" });
    const edited = [_][]const u8{ "[a]", "token: A", "[b]", "token = B" };
    const p = try pair(a, outline, &edited);
    try testing.expect(p.fail_closed);
    try testing.expectEqualStrings(map.line_redaction, try shown(a, outline, p, 1, edited[1], .none));
    try testing.expectEqualStrings("token = " ++ map.secret_redaction, try shown(a, outline, p, 3, edited[3], .none));
    try testing.expectEqualStrings("[b]", try shown(a, outline, p, 2, edited[2], .none));
    const same = [_][]const u8{ "[a]", "token = A2", "[b]", "token = B2", "added" };
    const q = try pair(a, outline, &same);
    try testing.expect(!q.fail_closed);
    try testing.expectEqualStrings("added", try shown(a, outline, q, 4, same[4], .none));
}

test "pair: a shape paired with a live line equal to an outline line left unpaired fails closed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outline = try testOutline(a, "- token: \"OLD\"\n- token: \"public\"\n", &.{0}, &.{"OLD"});
    const lines = [_][]const u8{ "- token: \"OLD\" # rotated", "- token: \"public\"" };
    const p = try pair(a, outline, &lines);
    try testing.expect(p.fail_closed);
    try testing.expectEqualStrings(map.line_redaction, try shown(a, outline, p, 0, lines[0], .none));
    try testing.expect(std.mem.indexOf(u8, try shown(a, outline, p, 0, lines[0], .none), "OLD") == null);
    const kept = [_][]const u8{ "- token: \"NEW\"", "- token: \"public\"" };
    try testing.expect(!(try pair(a, outline, &kept)).fail_closed);
}

test "pair: a secret line moved below the lines around it is still paired, and a copy of it is masked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outline = try testOutline(a, "a\ntoken=V\nz\n", &.{1}, &.{"V"});
    const lines = [_][]const u8{ "a", "z", "added", "token=OLD", "token=OLD2" };
    const p = try pair(a, outline, &lines);
    try testing.expect(!p.fail_closed);
    try testing.expectEqualStrings("added", try shown(a, outline, p, 2, lines[2], .none));
    try testing.expectEqualStrings("token=" ++ map.secret_redaction, try shown(a, outline, p, 3, lines[3], .none));
    try testing.expectEqualStrings("token=" ++ map.secret_redaction, try shown(a, outline, p, 4, lines[4], .none));
}

test "pair: lines far past the edit bound are paired one shape at a time, within the bound on comparisons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var content: std.ArrayList(u8) = .empty;
    var live: std.ArrayList([]const u8) = .empty;
    for (0..3 * max_edits) |i| {
        try content.print(a, "k{d}\n", .{i});
        try live.append(a, try std.fmt.allocPrint(a, "other{d}", .{i}));
    }
    try content.appendSlice(a, "token=V\n");
    try live.append(a, "token=OLD");
    const outline = try testOutline(a, content.items, &.{@intCast(3 * max_edits)}, &.{"V"});
    const p = try pair(a, outline, live.items);
    try testing.expect(!p.fail_closed);
    try testing.expectEqualStrings("token=" ++ map.secret_redaction, try shown(a, outline, p, live.items.len - 1, "token=OLD", .none));
    try testing.expectEqualStrings("other0", try shown(a, outline, p, 0, "other0", .none));
}

test "pair: an outline no line of a file pairs with stops at the bound on comparisons and fails closed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 9000;
    var outline: std.ArrayList(Entry) = .empty;
    var live: std.ArrayList([]const u8) = .empty;
    for (0..n) |i| {
        try outline.append(a, .{ .shape = .{ .pieces = &.{ try std.fmt.allocPrint(a, "k{d}=", .{i}), "" } } });
        try live.append(a, try std.fmt.allocPrint(a, "x{d}", .{i}));
    }
    try testing.expect(n * n > max_comparisons);
    const p = try pair(a, outline.items, live.items);
    try testing.expect(p.fail_closed);
    try testing.expectEqualStrings(map.line_redaction, try shown(a, outline.items, p, 0, live.items[0], .none));
}

test "alignBy: pairs equal lines in order, as many as the line diff keeps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    const words = [_][]const u8{ "a", "b", "c", "d" };
    const Eq = struct {
        x: []const []const u8,
        y: []const []const u8,
        fn eq(c: @This(), i: usize, j: usize) ?bool {
            return std.mem.eql(u8, c.x[i], c.y[j]);
        }
    };
    for (0..500) |_| {
        const x = try a.alloc([]const u8, r.uintLessThan(usize, 12));
        const y = try a.alloc([]const u8, r.uintLessThan(usize, 12));
        for (x) |*w| w.* = words[r.uintLessThan(usize, words.len)];
        for (y) |*w| w.* = words[r.uintLessThan(usize, words.len)];
        const pairs = (try alignBy(a, x.len, y.len, Eq{ .x = x, .y = y }, Eq.eq)).?;
        var deleted: usize = 0;
        for (try @import("../diff/lines.zig").diff(a, x, y)) |h| deleted += h.a_len;
        try testing.expectEqual(x.len - deleted, pairs.len);
        for (pairs, 0..) |p, i| {
            try testing.expectEqualStrings(x[p[0]], y[p[1]]);
            if (i > 0) try testing.expect(p[0] < pairs[i - 1][0] and p[1] < pairs[i - 1][1]);
        }
    }
}

test "writtenForms: the raw, JSON, TOML and YAML forms, the outer lines of a form of several lines as text, its inner lines whole, a short line of either kind none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const forms = try writtenForms(a, &.{ "a\"b\\c", "line-one\nmiddle-line\nline-three", "{\nmid\n}", "" });
    var has_json = false;
    var has_outer = false;
    for (forms.text) |f| {
        if (std.mem.eql(u8, f, "a\\\"b\\\\c")) has_json = true;
        if (std.mem.eql(u8, f, "line-three")) has_outer = true;
        try testing.expect(f.len > 0);
        try testing.expect(!std.mem.eql(u8, f, "middle-line"));
        try testing.expect(!std.mem.eql(u8, f, "{"));
        try testing.expect(!std.mem.eql(u8, f, "}"));
    }
    try testing.expect(has_json);
    try testing.expect(has_outer);
    try testing.expect(forms.lines.contains("middle-line"));
    try testing.expect(!forms.lines.contains("mid"));
    try testing.expect(!forms.lines.contains("{"));
    for (forms.text[1..], forms.text[0 .. forms.text.len - 1]) |f, prev| try testing.expect(f.len <= prev.len);
    var spans: std.ArrayList(Span) = .empty;
    try formSpans(a, "middle-line", forms, &spans);
    try testing.expectEqual(@as(usize, 1), spans.items.len);
    spans.clearRetainingCapacity();
    try formSpans(a, "a middle-line", forms, &spans);
    try testing.expectEqual(@as(usize, 0), spans.items.len);
    try formSpans(a, "f() {", forms, &spans);
    try testing.expectEqual(@as(usize, 0), spans.items.len);
}

test "outlineOf: a line no secret segment covers that holds a resolved value is a shape with a slot at the value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = [_]map.Segment{
        .{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } },
        .{ .out_start = 1, .out_len = 1, .origin = .secret },
        .{ .out_start = 2, .out_len = 1, .origin = .{ .base = .{ .line = 3 } } },
    };
    const outline = try outlineOf(a, "export TOK=v4lue\ntoken=v4lue\nz\n", &segs, &.{"v4lue"});
    try testing.expectEqual(@as(usize, 3), outline.len);
    try testing.expectEqualStrings("export TOK=", outline[0].shape.pieces[0]);
    try testing.expectEqualStrings("", outline[0].shape.pieces[1]);
    try testing.expectEqualStrings("token=", outline[1].shape.pieces[0]);
    try testing.expectEqualStrings("z", outline[2].line);
}

test "holdsAny: a whole form anywhere and a line of a value of several lines, each only when it is long enough" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try holdsAny(a, "x = \"pa\\\"ssword\"\n", &.{"pa\"ssword"}));
    try testing.expect(!try holdsAny(a, "role = admin\n", &.{"admin"}));
    try testing.expect(!try holdsAny(a, "f() {\n}\n", &.{"{\n  \"k\": \"v\"\n}"}));
    try testing.expect(try holdsAny(a, "pasted MIIBlongline\n", &.{"-----BEGIN-----\nMIIBlongline\n-----END-----"}));
    try testing.expect(!try holdsAny(a, "nothing\n", &.{ "", "absent" }));
}

test "holdsForm: a form of at least 8 bytes within the line, or a middle line of a value of several lines as the whole line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const forms = try writtenForms(a, &.{ "admin", "PASTED-9f3e1a", "-----BEGIN-----\nMIIBlongline\n-----END-----" });
    try testing.expect(holdsForm("copy=PASTED-9f3e1a # x", forms));
    try testing.expect(!holdsForm("role = admin", forms));
    try testing.expect(holdsForm("MIIBlongline\r", forms));
    try testing.expect(!holdsForm("x MIIBlongline", forms));
    try testing.expect(holdsForm("key: -----BEGIN-----", forms));
}

test "maskForms: every form masked on every line, the rest kept byte for byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const forms = try writtenForms(a, &.{"s3cr3t"});
    try testing.expectEqualStrings("a = " ++ map.secret_redaction ++ "\nb\n", try maskForms(a, "a = s3cr3t\nb\n", forms));
    const same = "plain\n";
    try testing.expect((try maskForms(a, same, forms)).ptr == same.ptr);
}
