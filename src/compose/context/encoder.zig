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
        return e.tracker.finish();
    }
};
