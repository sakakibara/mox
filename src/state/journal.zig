//! A run's journal, `pending/<id>.jsonl`: a header line, then one line per
//! change the run made to its draft, in order.
//!
//! The header is fsynced before anything else is written. A `displaced`
//! line is fsynced too, after its blob, and before the change it backs up is
//! made, which also flushes every line before it; the other lines are not.
//! Only the part after the last fsync can be torn, so a tail that does not
//! parse is ignored.

const std = @import("std");
const Io = std.Io;
const json = @import("json");
const generation = @import("generation.zig");
const durable = @import("durable.zig");

pub const Header = struct {
    holder: []const u8,
    base: []const u8,
    run_kind: generation.Kind,
    undoes: ?[]const u8 = null,
    part: generation.Hex,
    part_info: generation.PartInfo,
    expects_private: bool = false,
};

pub const MapName = enum { paths, residue, generators, flags, parts, displaced };

pub const Op = struct {
    map: MapName,
    key: []const u8,
    /// Null for a delete.
    value: ?json.Value,
};

pub const Journal = struct {
    path: []const u8,
    file: Io.File,

    pub fn close(j: Journal, io: Io) void {
        j.file.close(io);
    }
};

pub fn headerLine(arena: std.mem.Allocator, h: Header) ![]const u8 {
    var o: json.ObjectMap = .empty;
    try o.put(arena, "holder", .{ .string = h.holder });
    try o.put(arena, "base", .{ .string = h.base });
    try o.put(arena, "run_kind", .{ .string = @tagName(h.run_kind) });
    try o.put(arena, "undoes", if (h.undoes) |u| .{ .string = u } else .null);
    try o.put(arena, "part", .{ .string = try arena.dupe(u8, &h.part) });
    try o.put(arena, "parts_entry", try generation.partValue(arena, h.part_info));
    try o.put(arena, "expects_private", .{ .bool = h.expects_private });
    return line(arena, .{ .object = o });
}

pub fn opLine(arena: std.mem.Allocator, op: Op) ![]const u8 {
    var o: json.ObjectMap = .empty;
    try o.put(arena, if (op.value != null) "set" else "delete", .{ .string = @tagName(op.map) });
    try o.put(arena, "key", .{ .string = try generation.encodeKey(arena, op.key) });
    if (op.value) |v| try o.put(arena, "value", v);
    return line(arena, .{ .object = o });
}

fn line(arena: std.mem.Allocator, v_in: json.Value) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var v = v_in;
    try generation.encodeSorted(&aw.writer, &v);
    try aw.writer.writeByte('\n');
    return aw.written();
}

/// Open the claimed, empty journal at `path` and write its header, fsynced.
pub fn begin(arena: std.mem.Allocator, io: Io, path: []const u8, h: Header) !Journal {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only });
    errdefer file.close(io);
    try file.writeStreamingAll(io, try headerLine(arena, h));
    try durable.syncFile(io, file);
    return .{ .path = path, .file = file };
}

pub fn append(arena: std.mem.Allocator, io: Io, j: Journal, op: Op, sync: bool) !void {
    try j.file.writeStreamingAll(io, try opLine(arena, op));
    if (sync) try durable.syncFile(io, j.file);
}

pub const Parsed = struct {
    header: Header,
    ops: []const Op,
};

/// The header and every whole op of `bytes`; null when the header does not
/// parse.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !?Parsed {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first = lines.next() orelse return null;
    const hv = json.parse(arena, first, .{}) catch return null;
    if (hv != .object) return null;
    const ho = hv.object;
    const header: Header = .{
        .holder = strOf(ho.get("holder")) orelse return null,
        .base = strOf(ho.get("base")) orelse return null,
        .run_kind = std.meta.stringToEnum(generation.Kind, strOf(ho.get("run_kind")) orelse return null) orelse return null,
        .undoes = strOf(ho.get("undoes")),
        .part = generation.parseHex(strOf(ho.get("part")) orelse return null) orelse return null,
        .part_info = blk: {
            const pe = ho.get("parts_entry") orelse return null;
            if (pe != .object) return null;
            const repo = (try @import("../apply/applied.zig").pctDecode(arena, strOf(pe.object.get("repo")) orelse return null)) orelse return null;
            const home = (try @import("../apply/applied.zig").pctDecode(arena, strOf(pe.object.get("home")) orelse return null)) orelse return null;
            break :blk .{ .repo = repo, .home = home };
        },
        .expects_private = if (ho.get("expects_private")) |v| v == .bool and v.bool else false,
    };
    var ops: std.ArrayList(Op) = .empty;
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        // Only the tail after the last fsync can be torn: stop at it.
        const v = json.parse(arena, l, .{}) catch break;
        if (v != .object) break;
        const o = v.object;
        const set = strOf(o.get("set"));
        const del = strOf(o.get("delete"));
        const map_name = set orelse del orelse break;
        const map = std.meta.stringToEnum(MapName, map_name) orelse break;
        const key = generation.decodeKey(arena, strOf(o.get("key")) orelse break) catch break;
        try ops.append(arena, .{ .map = map, .key = key, .value = if (set != null) (o.get("value") orelse break) else null });
    }
    return .{ .header = header, .ops = ops.items };
}

fn strOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

test "journal: header and ops round-trip, and a torn tail is ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const part = @import("../apply/applied.zig").contentHashHex("p");
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, try headerLine(a, .{ .holder = "1 - boot-1", .base = "x y\n", .run_kind = .apply, .part = part, .part_info = .{ .repo = "/r", .home = "/h" }, .expects_private = true }));
    try bytes.appendSlice(a, try opLine(a, .{ .map = .residue, .key = "/h/a b", .value = .{ .string = "v" } }));
    try bytes.appendSlice(a, try opLine(a, .{ .map = .paths, .key = "/h/c", .value = null }));
    try bytes.appendSlice(a, "{\"set\":\"paths\",\"ke");
    const got = (try parse(a, bytes.items)).?;
    try std.testing.expectEqualStrings("x y\n", got.header.base);
    try std.testing.expect(got.header.expects_private);
    try std.testing.expectEqual(@as(usize, 2), got.ops.len);
    try std.testing.expectEqualStrings("/h/a b", got.ops[0].key);
    try std.testing.expect(got.ops[1].value == null);
    try std.testing.expect(try parse(a, "") == null);
    try std.testing.expect(try parse(a, "{not json\n") == null);
}
