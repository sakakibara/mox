//! Loading the current generation, recovering what dead runs left in their
//! journals, and the commit point that makes a draft current.
//!
//! One routine serves both uses: a state command runs it with writes on,
//! under the lock, before claiming its own journal; a reader or a dry run
//! runs it with writes off and reaches the same state in memory.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const json = @import("json");
const generation = @import("generation.zig");
const journal = @import("journal.zig");
const durable = @import("durable.zig");
const draft_mod = @import("draft.zig");
const lock = @import("lock.zig");
const id_mod = @import("id.zig");
const retention = @import("retention.zig");

const Generation = generation.Generation;
const Store = draft_mod.Store;
const Draft = draft_mod.Draft;

pub const Report = struct {
    warnings: std.ArrayList([]const u8) = .empty,
    /// Ids of the generations recovery folded from dead journals.
    recovered: std.ArrayList([]const u8) = .empty,
    /// Files recovery moved to `quarantine/`.
    quarantined: std.ArrayList([]const u8) = .empty,
    /// `current` named a generation that could not be read.
    torn: bool = false,
    /// The generation `current` named, when torn, and the one read instead.
    torn_id: ?[]const u8 = null,
    fallback_id: ?[]const u8 = null,
    /// No generation could be read: reads are empty and writes refuse.
    exhausted: bool = false,
    /// A generation a newer mox wrote.
    newer: ?i128 = null,
    /// `doctor --fix` started over from an empty state.
    restarted: bool = false,
    /// With writes off: the generations recovery would have written.
    unwritten: std.ArrayList(Generation) = .empty,
};

/// What `current` holds: the generation it names and that one's parent.
pub const Current = struct { id: []const u8, parent: ?[]const u8 };

pub fn parseCurrent(bytes: []const u8) ?Current {
    const line = std.mem.trim(u8, bytes, " \r\n");
    var it = std.mem.splitScalar(u8, line, ' ');
    const first = it.next() orelse return null;
    if (!id_mod.isId(first)) return null;
    const second = it.next();
    if (it.next() != null) return null;
    if (second) |p| if (!id_mod.isId(p)) return null;
    return .{ .id = first, .parent = second };
}

/// The test seam each read of `current` passes.
pub var on_read_current: ?*const fn (Io, Store) void = null;

pub fn readCurrent(arena: std.mem.Allocator, io: Io, store: Store) ![]const u8 {
    if (builtin.is_test) if (on_read_current) |f| f(io, store);
    return Io.Dir.cwd().readFileAlloc(io, store.current, arena, .limited(4096)) catch |e| switch (e) {
        error.FileNotFound => "",
        error.OutOfMemory => return e,
        else => return e,
    };
}

pub fn readGeneration(arena: std.mem.Allocator, io: Io, store: Store, id: []const u8, why: ?*generation.Unread) !?Generation {
    const bytes = Io.Dir.cwd().readFileAlloc(io, try store.genPath(arena, id), arena, .limited(256 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return null,
        error.OutOfMemory => return e,
        else => {
            if (why) |w| w.* = .malformed;
            return null;
        },
    };
    return generation.parse(arena, bytes, why) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.Malformed => null,
    };
}

pub const Loaded = struct {
    gen: ?Generation,
    base: []const u8,
};

/// The generation `current` names, else the parent it names, with a warning;
/// none when `current` is absent. `report.exhausted` when neither reads.
pub fn loadCurrent(arena: std.mem.Allocator, io: Io, store: Store, report: *Report) !Loaded {
    const base = try readCurrent(arena, io, store);
    if (base.len == 0) return .{ .gen = null, .base = base };
    const cur = parseCurrent(base) orelse {
        report.exhausted = true;
        try report.warnings.append(arena, "the state's current generation cannot be read; run `mox doctor --fix`");
        return .{ .gen = null, .base = base };
    };
    var why: generation.Unread = .malformed;
    if (try readGeneration(arena, io, store, cur.id, &why)) |g| return .{ .gen = g, .base = base };
    if (why == .newer) {
        report.newer = why.newer;
        return .{ .gen = null, .base = base };
    }
    report.torn = true;
    report.torn_id = cur.id;
    if (cur.parent) |p| {
        var pwhy: generation.Unread = .malformed;
        if (try readGeneration(arena, io, store, p, &pwhy)) |g| {
            report.fallback_id = p;
            try report.warnings.append(arena, try std.fmt.allocPrint(arena, "generation {s} cannot be read; using {s}, the one before it (`mox doctor --fix` moves it aside)", .{ cur.id, p }));
            return .{ .gen = g, .base = base };
        }
        if (pwhy == .newer) {
            report.newer = pwhy.newer;
            return .{ .gen = null, .base = base };
        }
    }
    report.exhausted = true;
    try report.warnings.append(arena, try std.fmt.allocPrint(arena, "generation {s} and every one before it cannot be read; the state reads as empty, and every command that writes refuses until `mox doctor --fix`", .{cur.id}));
    return .{ .gen = null, .base = base };
}

pub const RecoverOptions = struct {
    writes: bool,
    /// Judge each journal's holder by pid, start time and boot id; without
    /// the lock, a live run's journal is not read.
    unlocked: bool = false,
};

/// Fold, adopt, delete or quarantine every dead journal, oldest first, each
/// against what the ones before it produced. Returns the generation then
/// current and the bytes of `current`.
pub fn recover(arena: std.mem.Allocator, io: Io, store: Store, start: Loaded, opts: RecoverOptions, report: *Report) !Loaded {
    var at = start;
    const names = try journalIds(arena, io, store);
    for (names) |jid| {
        const path = try store.journalPath(arena, jid);
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024)) catch continue;
        const parsed = try journal.parse(arena, bytes);
        if (opts.unlocked) {
            if (parsed) |p| if (lock.stampLive(arena, io, p.header.holder)) continue;
        }
        const j = parsed orelse {
            if (opts.writes) Io.Dir.cwd().deleteFile(io, path) catch {};
            continue;
        };
        const loaded_id: ?[]const u8 = if (at.gen) |g| g.id else null;
        var why: generation.Unread = .malformed;
        const gen_path = try store.genPath(arena, jid);
        const gen_there = if (Io.Dir.cwd().access(io, gen_path, .{})) true else |_| false;
        if (try readGeneration(arena, io, store, jid, &why)) |g| {
            const cur = parseCurrent(at.base);
            if (cur != null and std.mem.eql(u8, cur.?.id, jid)) {
                if (opts.writes) Io.Dir.cwd().deleteFile(io, path) catch {};
                continue;
            }
            if (eqlOpt(g.parent, loaded_id)) {
                const cur_bytes = try currentLine(arena, jid, g.parent);
                if (opts.writes) {
                    try durable.writeFile(io, store.current, cur_bytes);
                    Io.Dir.cwd().deleteFile(io, path) catch {};
                }
                at = .{ .gen = g, .base = cur_bytes };
                try report.recovered.append(arena, jid);
                continue;
            }
            if (opts.writes) try quarantine(arena, io, store, path, report);
            continue;
        }
        if (gen_there) {
            if (opts.writes) try quarantine(arena, io, store, path, report);
            continue;
        }
        if (!std.mem.eql(u8, j.header.base, at.base)) {
            if (opts.writes) try quarantine(arena, io, store, path, report);
            continue;
        }
        var folded = if (at.gen) |g| try g.clone(arena) else Generation{ .id = jid, .kind = .recovered, .run_kind = j.header.run_kind };
        folded.displaced = .empty;
        var changed = j.header.expects_private;
        for (j.ops) |op| {
            try applyOp(arena, &folded, op);
            changed = true;
        }
        if (j.header.expects_private) {
            var f = folded.flags.get(&j.header.part) orelse generation.Flags{};
            f.expects_private = true;
            try folded.flags.put(arena, try arena.dupe(u8, &j.header.part), f);
        }
        if (!changed and folded.displaced.count() == 0) {
            if (opts.writes) Io.Dir.cwd().deleteFile(io, path) catch {};
            continue;
        }
        folded.id = jid;
        folded.parent = loaded_id;
        folded.kind = .recovered;
        folded.run_kind = j.header.run_kind;
        folded.undoes = j.header.undoes;
        try retention.fixParts(arena, &folded, j.header.part, j.header.part_info);
        const cur_bytes = try currentLine(arena, jid, loaded_id);
        if (opts.writes) {
            try writeGeneration(arena, io, store, folded);
            try durable.writeFile(io, store.current, cur_bytes);
            Io.Dir.cwd().deleteFile(io, path) catch {};
        } else try report.unwritten.append(arena, folded);
        at = .{ .gen = folded, .base = cur_bytes };
        try report.recovered.append(arena, jid);
    }
    return at;
}

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn currentLine(arena: std.mem.Allocator, id: []const u8, parent: ?[]const u8) ![]const u8 {
    return if (parent) |p| std.fmt.allocPrint(arena, "{s} {s}\n", .{ id, p }) else std.fmt.allocPrint(arena, "{s}\n", .{id});
}

/// Every journal id under `pending/`, oldest first.
pub fn journalIds(arena: std.mem.Allocator, io: Io, store: Store) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, store.pending, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".jsonl")) continue;
        const name = e.name[0 .. e.name.len - ".jsonl".len];
        if (!id_mod.isId(name)) continue;
        try out.append(arena, try arena.dupe(u8, name));
    }
    std.mem.sort([]const u8, out.items, {}, id_mod.older);
    return out.items;
}

/// Move `path` into `quarantine/`, never replacing a file there.
pub fn quarantine(arena: std.mem.Allocator, io: Io, store: Store, path: []const u8, report: *Report) !void {
    try durable.makeDir(io, store.quarantine);
    const dest = try durable.moveAside(arena, path, try std.fs.path.join(arena, &.{ store.quarantine, std.fs.path.basename(path) }));
    try durable.syncDir(io, store.quarantine);
    try report.quarantined.append(arena, dest);
}

fn applyOp(arena: std.mem.Allocator, g: *Generation, op: journal.Op) !void {
    switch (op.map) {
        .paths => if (op.value) |v| {
            const parsed = try parseOne(arena, "paths", op.key, v);
            try g.paths.put(arena, op.key, parsed.paths.get(op.key).?);
        } else {
            _ = g.paths.orderedRemove(op.key);
        },
        .residue => if (op.value) |v| {
            try g.residue.put(arena, op.key, try generation.hexOf(v));
        } else {
            _ = g.residue.orderedRemove(op.key);
        },
        .generators => if (op.value) |v| {
            const parsed = try parseOne(arena, "generators", op.key, v);
            try g.generators.put(arena, op.key, parsed.generators.get(op.key).?);
        } else {
            _ = g.generators.orderedRemove(op.key);
        },
        .flags => if (op.value) |v| {
            const parsed = try parseOne(arena, "flags", op.key, v);
            try g.flags.put(arena, op.key, parsed.flags.get(op.key).?);
        } else {
            _ = g.flags.orderedRemove(op.key);
        },
        .parts => {},
        .displaced => if (op.value) |v| {
            try g.displaced.put(arena, op.key, try generation.parseFlatDisplaced(arena, v));
        } else {
            _ = g.displaced.orderedRemove(op.key);
        },
    }
}

/// One map entry parsed through a generation holding only it.
fn parseOne(arena: std.mem.Allocator, map: []const u8, key: []const u8, v: json.Value) !Generation {
    var inner: json.ObjectMap = .empty;
    try inner.put(arena, try generation.encodeKey(arena, key), v);
    var root: json.ObjectMap = .empty;
    try root.put(arena, "v", .{ .integer = generation.version });
    try root.put(arena, "id", .{ .string = "x" });
    try root.put(arena, "kind", .{ .string = "recovered" });
    try root.put(arena, "run_kind", .{ .string = "recovered" });
    try root.put(arena, map, .{ .object = inner });
    var aw: Io.Writer.Allocating = .init(arena);
    try json.encode(&aw.writer, .{ .object = root }, .{});
    return generation.parse(arena, aw.written(), null);
}

pub fn writeGeneration(arena: std.mem.Allocator, io: Io, store: Store, g: Generation) !void {
    try durable.makeDir(io, store.gen);
    try durable.writeFile(io, try store.genPath(arena, g.id), try generation.serialize(arena, g));
}

/// The test seam just before a commit compares `current` with its base.
pub var before_commit_point: ?*const fn (Io) void = null;

pub const CommitOptions = struct {
    /// Prune displaced history down to this many generations.
    prune_keep: ?usize = null,
    /// Leave unreferenced blobs for the caller to collect.
    skip_gc: bool = false,
};

/// Make the draft's changes the current generation: refuse when `current`
/// moved since the draft was loaded, else write the generation, then
/// `current`, then remove the journal. A run that changed nothing commits
/// nothing.
pub fn commit(d: *Draft, opts: CommitOptions) !?[]const u8 {
    if (d.committed) return null;
    d.committed = true;
    const j = d.jnl orelse return null;
    defer j.close(d.io);
    const arena = d.arena;
    const io = d.io;
    if (!d.changed and !d.hasDisplaced()) {
        Io.Dir.cwd().deleteFile(io, j.path) catch {};
        return null;
    }
    if (builtin.is_test) if (before_commit_point) |f| f(io);
    const now = try readCurrent(arena, io, d.store);
    if (!std.mem.eql(u8, now, d.base)) {
        var report: Report = .{};
        try quarantine(arena, io, d.store, j.path, &report);
        return error.StateChanged;
    }
    var g = d.gen;
    g.id = d.run_id.?;
    g.parent = d.loaded;
    g.kind = d.run_kind;
    g.run_kind = d.run_kind;
    g.undoes = d.undoes;
    try retention.fixParts(arena, &g, d.part, d.part_info);
    try writeGeneration(arena, io, d.store, g);
    try durable.writeFile(io, d.store.current, try currentLine(arena, g.id, g.parent));
    Io.Dir.cwd().deleteFile(io, j.path) catch {};
    d.cleanup_warning = retention.afterCommit(arena, io, d.store, opts.prune_keep, !opts.skip_gc) catch null;
    return g.id;
}

const testing = std.testing;

const Fixture = struct {
    a: std.mem.Allocator,
    io: Io,
    root: []const u8,
    store: Store,

    fn init(a: std.mem.Allocator, io: Io, tmp: *testing.TmpDir) !Fixture {
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        try tmp.dir.createDirPath(io, "home");
        return .{ .a = a, .io = io, .root = root, .store = try Store.init(a, try std.fs.path.join(a, &.{ root, "state" })) };
    }

    fn home(f: Fixture) ![]const u8 {
        return std.fs.path.join(f.a, &.{ f.root, "home" });
    }

    /// A draft loaded as a run would load it, writes off, so nothing it
    /// finds is recovered.
    fn draft(f: Fixture, base: []const u8, loaded: ?Generation) !*Draft {
        const d = try draft_mod.testDraft(f.a, f.io, f.store.state_dir);
        d.base = base;
        if (loaded) |g| {
            d.gen = try g.clone(f.a);
            d.gen.displaced = .empty;
            d.loaded = g.id;
        }
        return d;
    }

    fn load(f: Fixture, writes: bool, unlocked: bool) !struct { at: Loaded, report: Report } {
        var report: Report = .{};
        const start = try loadCurrent(f.a, f.io, f.store, &report);
        const at = try recover(f.a, f.io, f.store, start, .{ .writes = writes, .unlocked = unlocked }, &report);
        return .{ .at = at, .report = report };
    }

    fn exists(f: Fixture, path: []const u8) bool {
        Io.Dir.cwd().access(f.io, path, .{}) catch return false;
        return true;
    }
};

test "recovery: a dead run's journal folds records, residue, generators, flags and what it displaced" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, io, &tmp);
    const home = try f.home();
    const live = try std.fs.path.join(a, &.{ home, "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/x", .data = "old\n" });

    const d = try f.draft("", null);
    try d.save(home, live, "old\n");
    try d.record(live, "new\n", "src/x");
    try d.persistProvenance(live, "", &.{});
    try d.setProduced("/g", &.{"/g/a"}, "src/g");
    try d.recordSymlink("/l", "/t", "src/l");
    try d.markTombstones(&.{"/gone"}, @import("../apply/stale.zig").foldCase);
    try d.notePrivate();
    const jid = d.run_id.?;
    d.jnl.?.close(io);

    const r = try f.load(true, false);
    const g = r.at.gen.?;
    try testing.expectEqualStrings(jid, g.id);
    try testing.expect(g.kind == .recovered and g.run_kind == .apply);
    try testing.expect(g.paths.get(live).?.file.?.provenance_blob != null);
    try testing.expectEqualStrings("/t", g.paths.get("/l").?.link.?.target);
    try testing.expectEqualStrings("/g/a", g.generators.get("/g").?.produced[0]);
    const flags = g.flags.get(&d.part).?;
    try testing.expect(flags.expects_private);
    try testing.expectEqualStrings("/gone", flags.tombstones_seen[0]);
    try testing.expect(g.displaced.get("x").?.blob != null);
    try testing.expect(!f.exists(try f.store.journalPath(a, jid)));
    try testing.expectEqualStrings(try currentLine(a, jid, null), try readCurrent(a, io, f.store));
}

test "recovery: two dead journals fold in id order, the second against the first's result, with writes on and off alike" {
    const io = testing.io;
    for ([_]bool{ false, true }) |writes| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const f = try Fixture.init(a, io, &tmp);

        const first = try f.draft("", null);
        try first.record("/h/a", "1\n", null);
        const id1 = first.run_id.?;
        first.jnl.?.close(io);
        // The second run loaded what the first would have committed.
        var folded = try f.load(false, false);
        const second = try f.draft(folded.at.base, folded.at.gen);
        try second.record("/h/b", "2\n", null);
        const id2 = second.run_id.?;
        second.jnl.?.close(io);

        const r = try f.load(writes, false);
        const g = r.at.gen.?;
        try testing.expectEqualStrings(id2, g.id);
        try testing.expectEqualStrings(id1, g.parent.?);
        try testing.expect(g.paths.contains("/h/a") and g.paths.contains("/h/b"));
        try testing.expectEqual(writes, !f.exists(try f.store.journalPath(a, id1)));
        try testing.expectEqual(writes, f.exists(f.store.current));
        folded = r;
    }
}

test "recovery: a finished commit's journal is deleted, a headerless one too" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, io, &tmp);

    const d = try f.draft("", null);
    try d.record("/h/a", "1\n", null);
    const jid = d.run_id.?;
    // The commit wrote its generation and `current`, then died before the
    // journal went.
    var g = d.gen;
    g.id = jid;
    g.kind = .apply;
    try writeGeneration(a, io, f.store, g);
    try durable.writeFile(io, f.store.current, try currentLine(a, jid, null));
    d.jnl.?.close(io);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try f.store.journalPath(a, "20200101T000000Z"), .data = "" });

    const r = try f.load(true, false);
    try testing.expectEqualStrings(jid, r.at.gen.?.id);
    try testing.expectEqual(@as(usize, 0), r.report.recovered.items.len);
    try testing.expect(!f.exists(try f.store.journalPath(a, jid)));
    try testing.expect(!f.exists(try f.store.journalPath(a, "20200101T000000Z")));
}

test "recovery: a written generation is adopted only when its parent is the one loaded, a torn current and a fresh install included" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, io, &tmp);

    // A fresh install's first commit wrote its generation, not `current`.
    const d1 = try f.draft("", null);
    try d1.record("/h/a", "1\n", null);
    const id1 = d1.run_id.?;
    var g1 = d1.gen;
    g1.id = id1;
    g1.kind = .apply;
    try writeGeneration(a, io, f.store, g1);
    d1.jnl.?.close(io);
    const r1 = try f.load(true, false);
    try testing.expectEqualStrings(id1, r1.at.gen.?.id);
    try testing.expectEqualStrings(try currentLine(a, id1, null), try readCurrent(a, io, f.store));

    // Under a torn `current`, the loader falls back to the parent: a run
    // that loaded the parent wrote its generation, and is adopted.
    const d2 = try f.draft(r1.at.base, r1.at.gen);
    try d2.record("/h/b", "2\n", null);
    const id2 = d2.run_id.?;
    var g2 = d2.gen;
    g2.id = id2;
    g2.parent = id1;
    g2.kind = .apply;
    try writeGeneration(a, io, f.store, g2);
    try durable.writeFile(io, f.store.current, try currentLine(a, "20990101T000000Z", id1));
    d2.jnl.?.close(io);
    const r2 = try f.load(true, false);
    try testing.expect(r2.report.torn);
    try testing.expectEqualStrings(id2, r2.at.gen.?.id);

    // A written generation whose parent is not the one loaded is
    // quarantined, never adopted.
    const d3 = try f.draft(r2.at.base, r2.at.gen);
    try d3.record("/h/c", "3\n", null);
    const id3 = d3.run_id.?;
    var g3 = d3.gen;
    g3.id = id3;
    g3.parent = "20000101T000000Z";
    g3.kind = .apply;
    try writeGeneration(a, io, f.store, g3);
    d3.jnl.?.close(io);
    const r3 = try f.load(true, false);
    try testing.expectEqualStrings(id2, r3.at.gen.?.id);
    try testing.expectEqual(@as(usize, 1), r3.report.quarantined.items.len);
}

test "recovery: a journal made against another current is quarantined, and readers do not overlay it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, io, &tmp);
    const d = try f.draft("20200101T000000Z\n", null);
    try d.record("/h/a", "1\n", null);
    const jid = d.run_id.?;
    d.jnl.?.close(io);

    const read_only = try f.load(false, false);
    try testing.expect(read_only.at.gen == null);
    try testing.expect(f.exists(try f.store.journalPath(a, jid)));
    const fixed = try f.load(true, false);
    try testing.expect(fixed.at.gen == null);
    try testing.expectEqual(@as(usize, 1), fixed.report.quarantined.items.len);
    try testing.expect(!f.exists(try f.store.journalPath(a, jid)));
}

test "recovery: an unlocked reader never folds the journal of a run still alive" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, io, &tmp);
    const d = try f.draft("", null);
    try d.record("/h/a", "1\n", null);
    d.jnl.?.close(io);
    // This process wrote the journal and is alive.
    const reader = try f.load(false, true);
    try testing.expect(reader.at.gen == null);
    const locked = try f.load(false, false);
    try testing.expect(locked.at.gen != null);
}

test "commit: a run that changed nothing commits nothing and removes its journal" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, io, &tmp);
    const d = try f.draft("", null);
    const jid = try d.claim();
    try testing.expect((try commit(d, .{})) == null);
    try testing.expect(!f.exists(try f.store.journalPath(a, jid)));
    try testing.expect(!f.exists(f.store.current));
}

test "commit: a current that moved since the load refuses, and the run's journal goes to quarantine" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, io, &tmp);
    const d = try f.draft("", null);
    try d.record("/h/a", "1\n", null);
    try durable.makeDir(io, f.store.v2);
    try durable.writeFile(io, f.store.current, "20200101T000000Z\n");
    try testing.expectError(error.StateChanged, commit(d, .{}));
    try testing.expect(f.exists(try std.fs.path.join(a, &.{ f.store.quarantine, try std.fmt.allocPrint(a, "{s}.jsonl", .{d.run_id.?}) })));
}

test "quarantine: a move never replaces a file already there" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, io, &tmp);
    try durable.makeDir(io, f.store.pending);
    try durable.makeDir(io, f.store.quarantine);
    const there = try std.fs.path.join(a, &.{ f.store.quarantine, "20200101T000000Z.jsonl" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = there, .data = "first" });
    const path = try f.store.journalPath(a, "20200101T000000Z");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "second" });
    var report: Report = .{};
    try quarantine(a, io, f.store, path, &report);
    try testing.expectEqualStrings("first", try Io.Dir.cwd().readFileAlloc(io, there, a, .unlimited));
    try testing.expect(!std.mem.eql(u8, there, report.quarantined.items[0]));
    try testing.expectEqualStrings("second", try Io.Dir.cwd().readFileAlloc(io, report.quarantined.items[0], a, .unlimited));
}
