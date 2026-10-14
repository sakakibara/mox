//! Secret line shapes: how a line that held a resolved secret looked around
//! the secret, kept so a later live copy of that line is recognized without
//! anything derived from the value being stored.
//!
//! A shape is the literal pieces of one output line in order, with a slot
//! between each pair: `pieces[0]` comes before the first slot, the last
//! piece after the last slot, and either may be empty. The pieces are the
//! bytes of the composed output that are not secret. A shape with two empty
//! pieces is a whole-line secret.
//!
//! A line matches a shape when the pieces occur in it in order, each
//! searched for left to right from where the one before ended, the last one
//! at its last occurrence, so a value that holds the text after it is not
//! cut short. The slots are the spans between them; a slot after an empty
//! first piece starts at the start of the line, and one before an empty
//! last piece ends at its end. A whole-line shape matches every line.

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

pub const Span = struct { start: usize, end: usize };

/// The forms in which compose, or a partial target's writer, writes a set
/// of values into a file: as written, JSON-escaped, and TOML- and
/// YAML-quoted (`text`, longest first), and, for a form of several lines,
/// its first and last lines, which share an output line with other text
/// (also in `text`), and its other lines, which fill an output line alone
/// (`lines`).
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
        if (t.len > 0) try set.put(arena, t, {});
    }
    var it = std.mem.splitScalar(u8, form, '\n');
    while (it.next()) |l| {
        const t = std.mem.trimEnd(u8, l, "\r");
        if (t.len > 0) try lines.put(arena, t, {});
    }
}

/// The values of `values` this render wrote: those with a form in a line
/// of `content` a `.secret` segment of `segments` covers.
pub fn renderValues(arena: std.mem.Allocator, content: []const u8, segments: []const map.Segment, values: []const []const u8) ![]const []const u8 {
    if (!map.hasSecret(segments) or values.len == 0) return &.{};
    const lines = try splitLines(arena, content);
    var text: std.ArrayList(u8) = .empty;
    for (segments) |sg| {
        if (sg.origin != .secret) continue;
        var i: usize = sg.out_start;
        while (i < @as(usize, sg.out_start) + sg.out_len and i < lines.len) : (i += 1) {
            try text.appendSlice(arena, lines[i]);
            try text.append(arena, '\n');
        }
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (values) |v| {
        if (v.len == 0) continue;
        for (try formsOf(arena, v)) |f| {
            if (f.len > 0 and std.mem.indexOf(u8, text.items, f) != null) {
                try out.append(arena, v);
                break;
            }
        }
    }
    return out.items;
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
    if (shape.pieces.len < 2) return false;
    var pos: usize = 0;
    const first = shape.pieces[0];
    if (first.len > 0) {
        const at = std.mem.indexOf(u8, line, first) orelse return false;
        pos = at + first.len;
    }
    const mark = out.items.len;
    for (shape.pieces[1..], 1..) |piece, k| {
        if (k == shape.pieces.len - 1 and piece.len == 0) {
            try out.append(arena, .{ .start = pos, .end = line.len });
            break;
        }
        const found = if (k == shape.pieces.len - 1)
            (if (std.mem.lastIndexOf(u8, line, piece)) |at| (if (at >= pos) at else null) else null)
        else
            std.mem.indexOfPos(u8, line, pos, piece);
        const at = found orelse {
            out.shrinkRetainingCapacity(mark);
            return false;
        };
        try out.append(arena, .{ .start = pos, .end = at });
        pos = at + piece.len;
    }
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

/// The distinct shapes of the secret lines of `content`, whose provenance is
/// `segments`, with `values` the secret values its compose resolved.
pub fn shapesOf(arena: std.mem.Allocator, content: []const u8, segments: []const map.Segment, values: []const []const u8) ![]const Shape {
    if (!map.hasSecret(segments)) return &.{};
    const lines = try splitLines(arena, content);
    const spans = try secretSpans(arena, lines, segments, try writtenForms(arena, values));
    var out: std.ArrayList(Shape) = .empty;
    var seen_keys: std.StringHashMapUnmanaged(void) = .empty;
    for (lines, spans) |l, sp| {
        // A shape is kept as JSON text, which holds only UTF-8.
        const s = if (std.unicode.utf8ValidateSlice(l)) try shapeOf(arena, l, sp orelse continue) else if (sp == null) continue else whole_line;
        const key = try shapeKey(arena, s);
        if (seen_keys.contains(key)) continue;
        try seen_keys.put(arena, key, {});
        try out.append(arena, s);
    }
    return out.items;
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

/// `content`, stored prior content of a file, with every line that matches
/// one of `shapes` masked at its slots, and every one of `forms` masked
/// wherever it occurs. A line that matches no shape and holds no form is
/// kept as it is.
pub fn redact(arena: std.mem.Allocator, content: []const u8, shapes: []const Shape, forms: Forms) ![]const u8 {
    if (shapes.len == 0 and forms.text.len == 0 and forms.lines.count() == 0) return content;
    var out: std.ArrayList(u8) = .empty;
    const trailing_nl = content.len > 0 and content[content.len - 1] == '\n';
    var changed = false;
    for (try splitLines(arena, content), 0..) |line, i| {
        if (i > 0) try out.append(arena, '\n');
        var spans: std.ArrayList(Span) = .empty;
        for (shapes) |s| _ = try match(arena, s, line, &spans);
        try formSpans(arena, line, forms, &spans);
        const shown = try mask(arena, line, spans.items, map.secret_redaction);
        if (shown.ptr != line.ptr) changed = true;
        try out.appendSlice(arena, shown);
    }
    if (!changed) return content;
    if (trailing_nl) try out.append(arena, '\n');
    return out.items;
}

const testing = std.testing;

test "match: pieces in order, slots between and around them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spans: std.ArrayList(Span) = .empty;
    const trailing: Shape = .{ .pieces = &.{ "tok=", "" } };
    try testing.expect(try match(a, trailing, "export tok=abc # x", &spans));
    try testing.expectEqualStrings("export tok=<s>", try mask(a, "export tok=abc # x", spans.items, "<s>"));
    spans.clearRetainingCapacity();
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
}

test "shapesOf: a value of several lines gives slot-only middle lines and keeps the text around it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = "a\nkey=BEGIN\nMID\nEND;\nz\n";
    const segs = [_]map.Segment{
        .{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } },
        .{ .out_start = 1, .out_len = 3, .origin = .secret },
        .{ .out_start = 4, .out_len = 1, .origin = .{ .base = .{ .line = 3 } } },
    };
    const shapes = try shapesOf(a, content, &segs, &.{"BEGIN\nMID\nEND"});
    try testing.expectEqual(@as(usize, 3), shapes.len);
    try testing.expectEqualStrings("key=", shapes[0].pieces[0]);
    try testing.expectEqualStrings("", shapes[0].pieces[1]);
    try testing.expect(shapes[1].wholeLine());
    try testing.expectEqualStrings("", shapes[2].pieces[0]);
    try testing.expectEqualStrings(";", shapes[2].pieces[1]);
    for (shapes) |s| for (s.pieces) |p| {
        try testing.expect(std.mem.indexOf(u8, p, "BEGIN") == null);
        try testing.expect(std.mem.indexOf(u8, p, "MID") == null);
    };
}

test "shapesOf: a JSON-escaped value is a slot, and a secret line holding no known value is a whole-line secret" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = [_]map.Segment{.{ .out_start = 0, .out_len = 2, .origin = .secret }};
    const shapes = try shapesOf(a, "{\"pw\": \"ab\\\"cd\"}\nunknown\n", &segs, &.{"ab\"cd"});
    try testing.expectEqual(@as(usize, 2), shapes.len);
    try testing.expectEqualStrings("{\"pw\": \"", shapes[0].pieces[0]);
    try testing.expectEqualStrings("\"}", shapes[0].pieces[1]);
    try testing.expect(shapes[1].wholeLine());
}

test "redact: matching lines are masked at their slots, a value anywhere is masked, other lines are kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shapes = [_]Shape{.{ .pieces = &.{ "token=", "" } }};
    const forms = try writtenForms(a, &.{"v4lue"});
    const out = try redact(a, "keep\ntoken=old # c\ncopy: v4lue!\n", &shapes, forms);
    try testing.expectEqualStrings("keep\ntoken=" ++ map.secret_redaction ++ "\ncopy: " ++ map.secret_redaction ++ "!\n", out);
    const same = "nothing here\n";
    try testing.expect((try redact(a, same, &shapes, forms)).ptr == same.ptr);
}

test "writtenForms: the raw, JSON, TOML and YAML forms, the outer lines of a form of several lines as text, its inner lines whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const forms = try writtenForms(a, &.{ "a\"b\\c", "l1\nmid\nl3", "" });
    var has_json = false;
    var has_outer = false;
    for (forms.text) |f| {
        if (std.mem.eql(u8, f, "a\\\"b\\\\c")) has_json = true;
        if (std.mem.eql(u8, f, "l3")) has_outer = true;
        try testing.expect(f.len > 0);
        try testing.expect(!std.mem.eql(u8, f, "mid"));
    }
    try testing.expect(has_json);
    try testing.expect(has_outer);
    try testing.expect(forms.lines.contains("mid"));
    for (forms.text[1..], forms.text[0 .. forms.text.len - 1]) |f, prev| try testing.expect(f.len <= prev.len);
    var spans: std.ArrayList(Span) = .empty;
    try formSpans(a, "mid", forms, &spans);
    try testing.expectEqual(@as(usize, 1), spans.items.len);
    spans.clearRetainingCapacity();
    try formSpans(a, "amid", forms, &spans);
    try testing.expectEqual(@as(usize, 0), spans.items.len);
}

test "renderValues: only the values a render wrote into its secret lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = [_]map.Segment{
        .{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } },
        .{ .out_start = 1, .out_len = 1, .origin = .secret },
    };
    const got = try renderValues(a, "other\n{\"k\": \"x\\\"y\"}\n", &segs, &.{ "other", "x\"y", "absent" });
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("x\"y", got[0]);
}
