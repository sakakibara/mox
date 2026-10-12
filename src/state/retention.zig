//! What the store keeps after a commit: displaced history pruned to the
//! retention count, empty generations dropped, and blobs nothing names.

const std = @import("std");
const Io = std.Io;
const generation = @import("generation.zig");
const draft_mod = @import("draft.zig");
const recovery = @import("recovery.zig");
const id_mod = @import("id.zig");

const Generation = generation.Generation;
const Store = draft_mod.Store;

/// Give `g` a parts table holding exactly the parts its records,
/// generators, flags and planted notes name.
pub fn fixParts(arena: std.mem.Allocator, g: *Generation, run_part: generation.Hex, run_info: generation.PartInfo) !void {
    var used: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (g.paths.values()) |e| try used.put(arena, try arena.dupe(u8, &e.part), {});
    for (g.generators.values()) |e| try used.put(arena, try arena.dupe(u8, &e.part), {});
    for (g.flags.keys()) |k| try used.put(arena, k, {});
    for (g.displaced.values()) |d| if (d.planted) |pl| try used.put(arena, try arena.dupe(u8, &pl.part), {});
    var table: generation.Map(generation.PartInfo) = .empty;
    for (used.keys()) |k| {
        if (g.parts.get(k)) |info| {
            try table.put(arena, k, info);
        } else if (std.mem.eql(u8, k, &run_part)) try table.put(arena, k, run_info);
    }
    g.parts = table;
}

pub const Listed = struct { id: []const u8, gen: Generation };

pub const Inventory = struct {
    gens: []Listed,
    /// Any generation file that does not parse or that a newer mox wrote.
    unreadable: []const []const u8,
};

/// Every generation under `gen/`, oldest first.
pub fn inventory(arena: std.mem.Allocator, io: Io, store: Store) !Inventory {
    var gens: std.ArrayList(Listed) = .empty;
    var bad: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, store.gen, .{ .iterate = true }) catch return .{ .gens = gens.items, .unreadable = bad.items };
    defer dir.close(io);
    var ids: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
        const name = e.name[0 .. e.name.len - ".json".len];
        if (!id_mod.isId(name)) continue;
        try ids.append(arena, try arena.dupe(u8, name));
    }
    std.mem.sort([]const u8, ids.items, {}, id_mod.older);
    for (ids.items) |id| {
        if (try recovery.readGeneration(arena, io, store, id, null)) |g| {
            try gens.append(arena, .{ .id = id, .gen = g });
        } else try bad.append(arena, id);
    }
    return .{ .gens = gens.items, .unreadable = bad.items };
}

fn isRollback(g: Generation) bool {
    return g.kind == .rollback or g.run_kind == .rollback;
}

/// Prune, drop empty generations, and collect unreferenced blobs.
pub fn afterCommit(arena: std.mem.Allocator, io: Io, store: Store, prune_keep: ?usize, gc: bool) !void {
    var inv = try inventory(arena, io, store);
    const cur = recovery.parseCurrent(try recovery.readCurrent(arena, io, store));
    var protect = std.StringHashMap(void).init(arena);
    if (cur) |c| try protect.put(c.id, {});
    var gone = std.StringHashMap(void).init(arena);
    if (prune_keep) |keep| try prune(arena, inv.gens, keep, &protect, &gone);
    if (cur) |c| if (c.parent) |p| try protect.put(p, {});
    for (inv.gens) |l| {
        if (l.gen.displaced.count() == 0 and !protect.contains(l.id)) try gone.put(l.id, {});
    }
    var it = gone.keyIterator();
    while (it.next()) |id| Io.Dir.cwd().deleteFile(io, try store.genPath(arena, id.*)) catch {};
    if (!gc or inv.unreadable.len > 0) return;
    inv = try inventory(arena, io, store);
    if (inv.unreadable.len > 0) return;
    try collect(arena, io, store);
}

/// Strip every generation down to its ids, its displaced history and the
/// parts its planted notes name, each rewritten atomically, then collect the
/// blobs only the records named.
pub fn stripRecords(arena: std.mem.Allocator, io: Io, store: Store) !void {
    const inv = try inventory(arena, io, store);
    for (inv.gens) |l| {
        var g = l.gen;
        if (g.paths.count() + g.residue.count() + g.generators.count() + g.flags.count() == 0) continue;
        g.paths = .empty;
        g.residue = .empty;
        g.generators = .empty;
        g.flags = .empty;
        try fixParts(arena, &g, @as(generation.Hex, @splat('-')), .{ .repo = "", .home = "" });
        try recovery.writeGeneration(arena, io, store, g);
    }
    if (inv.unreadable.len > 0) return;
    try collect(arena, io, store);
}

/// Mark for removal the oldest generations that displaced something beyond
/// `keep`, never one `protect` holds; a rollback generation goes when the
/// chain of generations it undoes ends at one marked.
pub fn prune(arena: std.mem.Allocator, gens: []const Listed, keep_in: usize, protect: *const std.StringHashMap(void), gone: *std.StringHashMap(void)) !void {
    const keep = @max(keep_in, 1);
    var own: std.ArrayList([]const u8) = .empty;
    var undo_of = std.StringHashMap([]const u8).init(arena);
    var undos: std.ArrayList([]const u8) = .empty;
    for (gens) |l| {
        if (isRollback(l.gen)) {
            if (l.gen.undoes) |u| try undo_of.put(l.id, u);
            try undos.append(arena, l.id);
        } else if (l.gen.displaced.count() > 0) try own.append(arena, l.id);
    }
    if (own.items.len > keep) {
        for (own.items[0 .. own.items.len - keep]) |id| {
            if (!protect.contains(id)) try gone.put(id, {});
        }
    }
    for (undos.items) |u| {
        var at = undo_of.get(u) orelse continue;
        var steps: usize = 0;
        const goes = while (steps <= undos.items.len) : (steps += 1) {
            if (gone.contains(at)) break true;
            at = undo_of.get(at) orelse break false;
        } else false;
        if (goes and !protect.contains(u)) try gone.put(u, {});
    }
}

/// Delete every blob no generation, journal or quarantined file names.
pub fn collect(arena: std.mem.Allocator, io: Io, store: Store) !void {
    var keep = std.StringHashMap(void).init(arena);
    for ([_][]const u8{ store.gen, store.pending, store.quarantine }) |dir_path| {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file) continue;
            const bytes = Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ dir_path, e.name }), arena, .limited(256 * 1024 * 1024)) catch return;
            try hexTokens(arena, bytes, &keep);
        }
    }
    var dir = Io.Dir.cwd().openDir(io, store.blobs, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var doomed: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        if (generation.parseHex(e.name) == null) continue;
        if (!keep.contains(e.name)) try doomed.append(arena, try arena.dupe(u8, e.name));
    }
    for (doomed.items) |name| dir.deleteFile(io, name) catch {};
}

/// Every run of 64 lowercase hex digits in `bytes`.
fn hexTokens(arena: std.mem.Allocator, bytes: []const u8, out: *std.StringHashMap(void)) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (!isLowerHex(bytes[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < bytes.len and isLowerHex(bytes[i])) i += 1;
        if (i - start == 64) try out.put(try arena.dupe(u8, bytes[start..i]), {});
    }
}

fn isLowerHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

test "prune: keeps the newest, never current, and an undo chain goes with what it undoes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var gens: std.ArrayList(Listed) = .empty;
    const h = @import("../apply/applied.zig").contentHashHex("c");
    for ([_]struct { []const u8, generation.Kind, ?[]const u8 }{
        .{ "20260101T000000Z", .apply, null },
        .{ "20260101T000001Z", .rollback, "20260101T000000Z" },
        .{ "20260101T000002Z", .rollback, "20260101T000001Z" },
        .{ "20260101T000003Z", .apply, null },
        .{ "20260101T000004Z", .rollback, "20250101T000000Z" },
    }) |c| {
        var g: Generation = .{ .id = c[0], .kind = c[1], .run_kind = c[1], .undoes = c[2] };
        try g.displaced.put(a, "f", .{ .type = .file, .blob = h });
        try gens.append(a, .{ .id = c[0], .gen = g });
    }
    var protect = std.StringHashMap(void).init(a);
    var gone = std.StringHashMap(void).init(a);
    try prune(a, gens.items, 2, &protect, &gone);
    try std.testing.expectEqual(@as(usize, 0), gone.count());
    try prune(a, gens.items, 1, &protect, &gone);
    try std.testing.expectEqual(@as(usize, 3), gone.count());
    try std.testing.expect(gone.contains("20260101T000002Z"));
    try std.testing.expect(!gone.contains("20260101T000004Z"));
    gone.clearRetainingCapacity();
    try protect.put("20260101T000000Z", {});
    try prune(a, gens.items, 1, &protect, &gone);
    try std.testing.expectEqual(@as(usize, 0), gone.count());
}

test "collect: nothing is deleted while a generation does not parse, nor any blob a quarantined file names" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const store = try Store.init(a, try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "state" }));
    const blob = @import("blob.zig");
    const kept = try blob.put(a, io, store.blobs, "kept");
    const named = try blob.put(a, io, store.blobs, "named by quarantine");
    const loose = try blob.put(a, io, store.blobs, "loose");
    var g: Generation = .{ .id = "20260101T000000Z", .kind = .apply, .run_kind = .apply };
    try g.residue.put(a, "/p", kept);
    try recovery.writeGeneration(a, io, store, g);
    try @import("durable.zig").writeFile(io, store.current, "20260101T000000Z\n");
    try @import("durable.zig").makeDir(io, store.quarantine);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ store.quarantine, "x.jsonl" }), .data = try std.fmt.allocPrint(a, "{{\"blob\":\"{s}\"}}\n", .{&named}) });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try store.genPath(a, "20260101T000001Z"), .data = "{ torn" });

    try afterCommit(a, io, store, null, true);
    for ([_]generation.Hex{ kept, named, loose }) |h| try std.testing.expect(try blob.get(a, io, store.blobs, h) != null);

    try Io.Dir.cwd().deleteFile(io, try store.genPath(a, "20260101T000001Z"));
    try afterCommit(a, io, store, null, true);
    try std.testing.expect(try blob.get(a, io, store.blobs, kept) != null);
    try std.testing.expect(try blob.get(a, io, store.blobs, named) != null);
    try std.testing.expect(try blob.get(a, io, store.blobs, loose) == null);
}
