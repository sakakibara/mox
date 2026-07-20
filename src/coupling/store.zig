//! On-disk persistence for the coupling graph and decline list.
//!
//! `mox commit` needs to know, without rescanning the whole tree, which source
//! files hold a token so that changing it in one file can offer to change it in
//! the others. The graph (token -> source postings) and the user's declines are
//! serialized under `<state>/coupling/`: `mox add` and `mox doctor
//! --rebuild-coupling` write the graph, commit loads it, prompts, and rewrites
//! the postings of any file whose sources changed.

const std = @import("std");
const json = @import("json");
const graph_mod = @import("graph.zig");
const decline_mod = @import("decline.zig");

const Io = std.Io;
const Graph = graph_mod.Graph;
const DeclineList = decline_mod.DeclineList;

const version: i128 = 1;
const max_bytes: usize = 64 * 1024 * 1024;

fn graphPath(arena: std.mem.Allocator, coupling_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ coupling_dir, "graph.json" });
}

fn declinesPath(arena: std.mem.Allocator, coupling_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ coupling_dir, "declines.json" });
}

/// Serialize `graph`'s postings (token -> source occurrences) to
/// `<coupling_dir>/graph.json`.
pub fn saveGraph(arena: std.mem.Allocator, io: Io, coupling_dir: []const u8, graph: *const Graph) !void {
    var postings: json.ObjectMap = .empty;
    var it = graph.map.iterator();
    while (it.next()) |e| {
        const occs = e.value_ptr.*.items;
        const arr = try arena.alloc(json.Value, occs.len);
        for (occs, 0..) |o, i| {
            var om: json.ObjectMap = .empty;
            try om.put(arena, "f", .{ .string = o.file_id });
            try om.put(arena, "o", .{ .integer = @intCast(o.byte_offset) });
            try om.put(arena, "l", .{ .integer = o.length });
            arr[i] = .{ .object = om };
        }
        try postings.put(arena, e.key_ptr.*, .{ .array = arr });
    }
    var root: json.ObjectMap = .empty;
    try root.put(arena, "v", .{ .integer = version });
    try root.put(arena, "postings", .{ .object = postings });
    try writeJson(arena, io, try graphPath(arena, coupling_dir), .{ .object = root });
}

/// Load the postings graph, or an empty graph when none is stored / malformed.
pub fn loadGraph(arena: std.mem.Allocator, io: Io, coupling_dir: []const u8) !Graph {
    var g = Graph.init(arena);
    const bytes = Io.Dir.cwd().readFileAlloc(io, try graphPath(arena, coupling_dir), arena, .limited(max_bytes)) catch |e| switch (e) {
        error.FileNotFound => return g,
        else => return e,
    };
    const v = json.parse(arena, bytes, .{}) catch return g;
    const postings = v.get("postings") orelse return g;
    if (postings != .object) return g;
    var it = postings.object.iterator();
    while (it.next()) |e| {
        const token = e.key_ptr.*;
        if (e.value_ptr.* != .array) continue;
        for (e.value_ptr.*.array) |item| {
            if (item != .object) continue;
            const f = stringOf(item.get("f")) orelse continue;
            const o = intOf(item.get("o")) orelse continue;
            const l = intOf(item.get("l")) orelse continue;
            try g.addOccurrence(token, f, @intCast(o), @intCast(l));
        }
    }
    return g;
}

/// Serialize the global and per-pair declines to `<coupling_dir>/declines.json`.
pub fn saveDeclines(arena: std.mem.Allocator, io: Io, coupling_dir: []const u8, d: *const DeclineList) !void {
    var root: json.ObjectMap = .empty;
    try root.put(arena, "v", .{ .integer = version });
    try root.put(arena, "global", try keysArray(arena, &d.global));
    try root.put(arena, "pairs", try keysArray(arena, &d.pairs));
    try writeJson(arena, io, try declinesPath(arena, coupling_dir), .{ .object = root });
}

/// Load the decline list, or an empty list when none is stored / malformed.
pub fn loadDeclines(arena: std.mem.Allocator, io: Io, coupling_dir: []const u8) !DeclineList {
    var d = DeclineList.init(arena);
    const bytes = Io.Dir.cwd().readFileAlloc(io, try declinesPath(arena, coupling_dir), arena, .limited(max_bytes)) catch |e| switch (e) {
        error.FileNotFound => return d,
        else => return e,
    };
    const v = json.parse(arena, bytes, .{}) catch return d;
    if (v.get("global")) |g| if (g == .array) {
        for (g.array) |item| {
            if (stringOf(item)) |s| try d.global.put(try arena.dupe(u8, s), {});
        }
    };
    if (v.get("pairs")) |p| if (p == .array) {
        for (p.array) |item| {
            if (stringOf(item)) |s| try d.pairs.put(try arena.dupe(u8, s), {});
        }
    };
    return d;
}

fn keysArray(arena: std.mem.Allocator, set: *const std.StringHashMap(void)) !json.Value {
    var arr = try arena.alloc(json.Value, set.count());
    var it = set.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) arr[i] = .{ .string = k.* };
    return .{ .array = arr };
}

fn writeJson(arena: std.mem.Allocator, io: Io, path: []const u8, value: json.Value) !void {
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    var aw: Io.Writer.Allocating = .init(arena);
    try json.encode(&aw.writer, value, .{ .indent = 2 });
    try aw.writer.writeByte('\n');
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try aw.toOwnedSlice() });
}

fn stringOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn intOf(v: ?json.Value) ?i128 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

const testing = std.testing;

fn tmpAbs(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, sub: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, sub });
}

test "graph: save/load round-trips postings" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = Graph.init(a);
    try g.addOccurrence("ada@example.com", "src/.gitconfig", 10, 21);
    try g.addOccurrence("ada@example.com", "src/allowed_signers", 0, 21);

    const dir = try tmpAbs(a, io, &tmp, "coupling");
    try saveGraph(a, io, dir, &g);

    var back = try loadGraph(a, io, dir);
    const occs = back.lookup("ada@example.com").?;
    try testing.expectEqual(@as(usize, 2), occs.len);
    try testing.expectEqual(@as(usize, 2), back.fileCountForToken("ada@example.com"));
}

test "declines: save/load round-trips global and pair declines" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var d = DeclineList.init(a);
    try d.declineGlobal("noisytoken");
    try d.declinePair("token12345", "src/a", "src/b");

    const dir = try tmpAbs(a, io, &tmp, "coupling");
    try saveDeclines(a, io, dir, &d);

    var back = try loadDeclines(a, io, dir);
    try testing.expect(back.isPairDeclined("noisytoken", "src/x", "src/y"));
    try testing.expect(back.isPairDeclined("token12345", "src/a", "src/b"));
    try testing.expect(back.isPairDeclined("token12345", "src/b", "src/a"));
    try testing.expect(!back.isPairDeclined("token12345", "src/a", "src/c"));
}

test "loadGraph: missing store yields an empty graph" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = try loadGraph(a, io, try tmpAbs(a, io, &tmp, "absent"));
    try testing.expect(g.lookup("anything") == null);
}
