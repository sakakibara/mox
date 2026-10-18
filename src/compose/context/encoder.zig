//! The tracker compose carries through one file's emission: it follows the
//! bytes emitted so far and encodes each capture's value for the context at
//! its position.

const std = @import("std");
const types = @import("types.zig");
const encode_mod = @import("encode.zig");
const root = @import("root.zig");

/// The first value that could not be written where its capture sits.
pub const Refused = struct {
    capture: []const u8,
    /// Byte offset of the capture in the emitted output.
    offset: usize,
    refusal: encode_mod.Refusal,
};

pub const Encoder = struct {
    tracker: root.Tracker,
    /// The output the file is emitted into; bytes before `fed` were fed.
    buf: *const std.ArrayList(u8),
    fed: usize = 0,
    /// A compose whose output is never written (secrets withheld): a value
    /// that cannot be encoded is written as it is and nothing is refused.
    lenient: bool,
    captures: u32 = 0,
    refused: ?Refused = null,
    /// Values written into YAML plain scalars, checked once each scalar is
    /// whole: `finish` asks whether the scalar reads back as a string.
    plain: std.ArrayList(Plain) = .empty,
    plain_arena: ?std.mem.Allocator = null,

    const Plain = struct { capture: []const u8, start: usize, len: usize };

    pub fn init(kind: root.Kind, buf: *const std.ArrayList(u8), lenient: bool) Encoder {
        return .{ .tracker = root.Tracker.init(kind), .buf = buf, .lenient = lenient };
    }

    /// Feed every byte emitted before the end of `line`, the part of the
    /// current expansion produced so far, which will follow `buf`.
    fn catchUp(e: *Encoder, line: []const u8) void {
        const base = e.buf.items.len;
        e.feedTo(base);
        const upto = base + line.len;
        if (e.fed < upto) {
            e.tracker.feed(line[e.fed - base ..]);
            e.fed = upto;
        }
    }

    /// The context of a capture that follows `line`.
    pub fn contextAt(e: *Encoder, line: []const u8) types.Context {
        e.catchUp(line);
        return e.tracker.context();
    }

    /// `value`, the value of `capture` at the end of `line`, encoded for its
    /// context. A value that cannot be written there, or whose encoding would
    /// change the context, is recorded (the first one) and returned as it is.
    pub fn encodeAt(e: *Encoder, arena: std.mem.Allocator, line: []const u8, capture: []const u8, value: []const u8, ctx_in: ?types.Context) ![]const u8 {
        const ctx = ctx_in orelse e.contextAt(line);
        e.captures += 1;
        const res = try encode_mod.encode(arena, value, ctx);
        const bytes = switch (res) {
            .bytes => |b| b,
            .refused => |r| {
                if (!e.lenient) e.note(capture, line, r);
                return value;
            },
        };
        if (ctx.enc == .yaml_plain and !e.lenient) {
            try e.plain.append(arena, .{ .capture = capture, .start = e.buf.items.len + line.len, .len = bytes.len });
            e.plain_arena = arena;
        }
        // The re-lex: the encoded value must leave the context as it was.
        var after = e.tracker;
        after.feed(bytes);
        if (!e.lenient and !e.tracker.same(&after))
            e.note(capture, line, .{ .where = encode_mod.name(ctx.enc), .reason = "it would change what follows it", .remedy = "quote it in the source" });
        return bytes;
    }

    /// Check the `# mox: secret` directive's value, the bytes `buf` gained
    /// from `start`: whole lines that begin and end where a line starts
    /// outside every string, heredoc and block.
    pub fn wholeLines(e: *Encoder, capture: []const u8, start: usize) void {
        e.feedTo(start);
        e.captures += 1;
        const begins = e.tracker.atLineTop() and (start == 0 or e.buf.items[start - 1] == '\n');
        e.feedTo(e.buf.items.len);
        if (e.lenient) return;
        const where = encode_mod.name(.lines);
        if (!begins)
            e.noteAt(capture, start, .{ .where = where, .reason = "it does not start a line outside every string, heredoc and block", .remedy = "move the directive out of it" })
        else if (!e.tracker.atLineTop())
            e.noteAt(capture, start, .{ .where = where, .reason = "its lines leave the file inside a string, heredoc or block", .remedy = "make the value whole lines of the file's own syntax" });
    }

    fn feedTo(e: *Encoder, end: usize) void {
        if (e.fed < end) {
            e.tracker.feed(e.buf.items[e.fed..end]);
            e.fed = end;
        }
    }

    fn note(e: *Encoder, capture: []const u8, line: []const u8, r: encode_mod.Refusal) void {
        e.noteAt(capture, e.buf.items.len + line.len, r);
    }

    fn noteAt(e: *Encoder, capture: []const u8, offset: usize, r: encode_mod.Refusal) void {
        if (e.refused != null) return;
        e.refused = .{ .capture = capture, .offset = offset, .refusal = r };
    }

    /// Feed the rest of the output, and say why the file cannot be written:
    /// a value refused, or a file with captures that the tracker could not
    /// follow to its end.
    pub fn finish(e: *Encoder) ?[]const u8 {
        e.catchUp("");
        if (e.lenient or e.captures == 0) return null;
        const why = e.tracker.finish();
        if (why == null) e.checkPlain();
        return why;
    }

    /// Refuse the first value whose YAML plain scalar, as written with the
    /// text around it, would not read back as a string: the check is on the
    /// whole scalar a reader sees, not on the value alone.
    fn checkPlain(e: *Encoder) void {
        if (e.plain.items.len == 0) return;
        const arena = e.plain_arena orelse return;
        const text = e.buf.items;
        const where = encode_mod.name(.yaml_plain);
        const spans = root.yaml.plainScalars(arena, text) catch
            return e.noteAt(e.plain.items[0].capture, e.plain.items[0].start, .{ .where = where, .reason = "mox ran out of memory checking it", .remedy = "try again" });
        for (e.plain.items) |p| {
            if (root.yaml.plainValueProblem(spans, text, p.start, p.len)) |why|
                e.noteAt(p.capture, p.start, .{ .where = where, .reason = why, .remedy = "quote it in the source" });
        }
    }
};

/// Whether `value`, written at the end of `prefix` with `suffix` after it in
/// a YAML file, is refused.
fn yamlRefused(prefix: []const u8, value: []const u8, suffix: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    var e = Encoder.init(.yaml, &buf, false);
    const bytes = try e.encodeAt(a, prefix, "c", value, null);
    try buf.appendSlice(a, prefix);
    try buf.appendSlice(a, bytes);
    try buf.appendSlice(a, suffix);
    _ = e.finish();
    return e.refused != null;
}

test "encoder: a YAML plain value is judged by the whole scalar it lands in" {
    for ([_][3][]const u8{
        .{ "key: ", "10080", "\n" },
        .{ "key: ", "yes", "\n" },
        .{ "key: ", "yEs", "\n" },
        .{ "key: ", "1st", "\n" },
        .{ "key: ", "0123", "\n" },
        .{ "key: ", ":sym", "\n" },
        .{ "key: ", "", "\n" },
        .{ "key: 1", "st", "\n" },
        .{ "key: -", "5", "\n" },
        .{ "key: ", "y", "es # c\n" },
        .{ "- ", "true", "\n" },
        .{ "{a: ", "yes", "}\n" },
        .{ "l: [", "?x", "]\n" },
        .{ "m: {", "?x", ": 1}\n" },
        .{ "l: [", "a:b", "]\n" },
        .{ "l: [", "x?y", "]\n" },
        .{ "l: [x", "?", "y]\n" },
        .{ "", "k" ** 1025, ": v\n" },
    }) |c| try std.testing.expect(try yamlRefused(c[0], c[1], c[2]));
    for ([_][3][]const u8{
        .{ "key: ", "en_US.UTF-8", "\n" },
        .{ "key: ", "Asia/Tokyo", "\n" },
        .{ "key: hello ", "yes", "\n" },
        .{ "key: abc", "", "\n" },
        .{ "key: v", "1.2.3", " # c\n" },
        .{ "- ", "darwin", "\n" },
        .{ "{a: ", "darwin", "}\n" },
        .{ "key: abc ", "", "\n" },
        .{ "key: abc ", "", " # c\n" },
        .{ "key: ", "?x", "\n" },
        .{ "", "k" ** 1024, ": v\n" },
        .{ "key: ", "k" ** 1025, "\n" },
    }) |c| try std.testing.expect(!try yamlRefused(c[0], c[1], c[2]));
}
