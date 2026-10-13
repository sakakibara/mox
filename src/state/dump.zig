//! A normalized dump of what mox persists about what it applied, for tests.
//!
//! Tests and the differential gate read state only through this: per live
//! path its recorded kinds and provenance, the generators' produced sets,
//! the tombstone and private-layer flags answered for the parts asked about,
//! and every snapshot's entries. A path is keyed by the sha256 of its live
//! path, and content by its sha256, never by where the store keeps it.

const std = @import("std");
const Io = std.Io;
const applied = @import("../apply/applied.zig");
const stale = @import("../apply/stale.zig");
const generation = @import("generation.zig");
const blob = @import("blob.zig");
const draft = @import("draft.zig");
const recovery = @import("recovery.zig");
const retention = @import("retention.zig");
const prov_map = @import("../provenance/map.zig");

const Hex = [applied.hash_hex_len]u8;

/// The entries of the state directory that hold the records this dump
/// reports; everything else there is listed by the caller as it is.
pub const store_entries = [_][]const u8{ "v2", "mox.lock", "readers.lock" };

/// The directory under `state_dir` a run's journal is created in, at its
/// first change: what the run displaces is recorded there before the run
/// replaces it.
pub fn displacedStore(arena: std.mem.Allocator, state_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ state_dir, "v2", "pending" });
}

/// A repo and the HOME it is applied under: what the flags are asked of.
pub const Part = struct { repo: []const u8, home: []const u8 };

pub const Options = struct {
    state_dir: []const u8,
    parts: []const Part = &.{},
    /// The tombstones of the current tree, as live paths.
    tombstones: []const []const u8 = &.{},
};

pub const File = struct { sha256: Hex, cache: ?Hex };
pub const Owned = struct {
    mode: applied.Mode,
    own_paths: []const []const u8,
    secret_paths: []const []const u8,
};
pub const Link = struct { target: []const u8, rolled_back: bool };

pub const Path = struct {
    key: Hex,
    file: ?File = null,
    owned: ?Owned = null,
    link: ?Link = null,
    /// The provenance bytes, when any are kept for the path.
    provenance: ?[]const u8 = null,
};

pub const Generator = struct { key: Hex, produced: []const []const u8 };

pub const Seen = struct { part: usize, tombstone: []const u8, seen: bool };

pub const EntryKind = enum { file, link, dir };

/// One displaced entry, keyed HOME-relative; a directory's members are
/// entries of their own.
pub const Entry = struct {
    key: []const u8,
    kind: EntryKind,
    sha256: ?Hex = null,
    mode: ?u32 = null,
    target: ?[]const u8 = null,
};

pub const Generation = struct { id: []const u8, entries: []const Entry };

pub const Dump = struct {
    paths: []const Path,
    generators: []const Generator,
    seen: []const Seen,
    expects_private: []const bool,
    /// Oldest first; only those that displaced something.
    generations: []const Generation,

    pub fn path(d: Dump, live: []const u8) ?Path {
        const key = applied.contentHashHex(live);
        for (d.paths) |p| if (std.mem.eql(u8, &p.key, &key)) return p;
        return null;
    }

    pub fn generator(d: Dump, live: []const u8) ?Generator {
        const key = applied.contentHashHex(live);
        for (d.generators) |g| if (std.mem.eql(u8, &g.key, &key)) return g;
        return null;
    }

    pub fn newest(d: Dump) ?Generation {
        if (d.generations.len == 0) return null;
        return d.generations[d.generations.len - 1];
    }

    pub fn ids(d: Dump, arena: std.mem.Allocator) ![]const []const u8 {
        const out = try arena.alloc([]const u8, d.generations.len);
        for (d.generations, out) |g, *o| o.* = g.id;
        return out;
    }
};

pub fn entryOf(g: Generation, key: []const u8) ?Entry {
    for (g.entries) |e| if (std.mem.eql(u8, e.key, key)) return e;
    return null;
}

pub fn load(arena: std.mem.Allocator, io: Io, opts: Options) !Dump {
    const store = try draft.Store.init(arena, opts.state_dir);
    var report: recovery.Report = .{};
    const loaded = try recovery.loadCurrent(arena, io, store, &report);
    const g: generation.Generation = loaded.gen orelse .{ .id = "", .kind = .apply, .run_kind = .apply };

    var paths: std.StringArrayHashMapUnmanaged(Path) = .empty;
    for (g.paths.keys(), g.paths.values()) |k, e| {
        const p = try pathAt(arena, &paths, k);
        if (e.file) |f| p.file = .{ .sha256 = f.sha256, .cache = f.cache_blob };
        if (e.owned) |o| p.owned = .{ .mode = o.mode, .own_paths = o.own_paths, .secret_paths = o.secret_paths };
        if (e.link) |l| p.link = .{ .target = l.target, .rolled_back = l.rolled_back };
        if (e.file) |f| if (f.provenance_blob) |h| {
            p.provenance = try withoutDigests(arena, try blob.get(arena, io, store.blobs, h));
        };
    }
    for (g.residue.keys(), g.residue.values()) |k, h| {
        const p = try pathAt(arena, &paths, k);
        if (p.provenance == null) p.provenance = try withoutDigests(arena, try blob.get(arena, io, store.blobs, h));
    }
    const path_list = paths.values();
    std.mem.sort(Path, path_list, {}, struct {
        fn lt(_: void, a: Path, b: Path) bool {
            return std.mem.lessThan(u8, &a.key, &b.key);
        }
    }.lt);

    var gens: std.ArrayList(Generator) = .empty;
    for (g.generators.keys(), g.generators.values()) |k, e| {
        const leaves = try arena.dupe([]const u8, e.produced);
        std.mem.sort([]const u8, leaves, {}, lessStr);
        try gens.append(arena, .{ .key = applied.contentHashHex(k), .produced = leaves });
    }
    std.mem.sort(Generator, gens.items, {}, struct {
        fn lt(_: void, a: Generator, b: Generator) bool {
            return std.mem.lessThan(u8, &a.key, &b.key);
        }
    }.lt);

    var seen: std.ArrayList(Seen) = .empty;
    var expects: std.ArrayList(bool) = .empty;
    for (opts.parts, 0..) |part, i| {
        const ph = (try draft.partOf(arena, io, part.repo, part.home)).hex;
        const f: generation.Flags = g.flags.get(&ph) orelse .{};
        try expects.append(arena, f.expects_private);
        for (opts.tombstones) |t| {
            const folded = try stale.foldCase(arena, t);
            var there = false;
            for (f.tombstones_seen) |s| there = there or std.mem.eql(u8, s, folded);
            try seen.append(arena, .{ .part = i, .tombstone = t, .seen = there });
        }
    }

    var out_gens: std.ArrayList(Generation) = .empty;
    const inv = try retention.inventory(arena, io, store);
    for (inv.gens) |l| {
        if (l.gen.displaced.count() == 0) continue;
        var entries: std.ArrayList(Entry) = .empty;
        for (l.gen.displaced.keys(), l.gen.displaced.values()) |k, d| {
            try entries.append(arena, .{
                .key = k,
                .kind = switch (d.type) {
                    .file => .file,
                    .link => .link,
                    .dir => .dir,
                },
                .sha256 = d.blob,
                .mode = if (d.type == .link) null else d.mode,
                .target = d.target,
            });
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lt);
        try out_gens.append(arena, .{ .id = l.id, .entries = entries.items });
    }

    return .{
        .paths = path_list,
        .generators = gens.items,
        .seen = seen.items,
        .expects_private = expects.items,
        .generations = out_gens.items,
    };
}

fn pathAt(arena: std.mem.Allocator, paths: *std.StringArrayHashMapUnmanaged(Path), key: []const u8) !*Path {
    const h = applied.contentHashHex(key);
    const name = try arena.dupe(u8, &h);
    const gop = try paths.getOrPut(arena, name);
    if (!gop.found_existing) gop.value_ptr.* = .{ .key = h };
    return gop.value_ptr;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Render `d` as text. `t` rewrites text before it is printed or hashed:
/// `t.apply(arena, text)` returns the rewritten text.
pub fn render(arena: std.mem.Allocator, d: Dump, t: anytype) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (d.paths) |p| {
        try out.print(arena, "path {s}\n", .{&p.key});
        if (p.file) |f| {
            try out.print(arena, "  file {s} cache {s}\n", .{ &f.sha256, if (f.cache) |c| &c else "none" });
        }
        if (p.link) |l| {
            try out.print(arena, "  link {s}{s}\n", .{ try applied.pctEncode(arena, try t.apply(arena, l.target)), if (l.rolled_back) " rolled-back" else "" });
        }
        if (p.owned) |o| {
            try out.print(arena, "  owned {t}", .{o.mode});
            for (o.own_paths) |op| try out.print(arena, " {s}", .{try applied.pctEncode(arena, op)});
            try out.appendSlice(arena, " secret");
            for (o.secret_paths) |sp| try out.print(arena, " {s}", .{try applied.pctEncode(arena, sp)});
            try out.append(arena, '\n');
        }
        if (p.provenance) |prov| {
            try out.print(arena, "  provenance {s}\n", .{&applied.contentHashHex(try t.apply(arena, prov))});
        }
    }
    for (d.generators) |g| {
        try out.print(arena, "generator {s}\n", .{&g.key});
        for (g.produced) |leaf| try out.print(arena, "  produced {s}\n", .{try applied.pctEncode(arena, try t.apply(arena, leaf))});
    }
    for (d.expects_private, 0..) |e, i| try out.print(arena, "part {d} expects-private {s}\n", .{ i, if (e) "yes" else "no" });
    for (d.seen) |s| try out.print(arena, "part {d} tombstone {s} seen {s}\n", .{ s.part, try applied.pctEncode(arena, try t.apply(arena, s.tombstone)), if (s.seen) "yes" else "no" });
    for (d.generations) |g| {
        try out.print(arena, "generation {s}\n", .{g.id});
        for (g.entries) |e| {
            try out.print(arena, "  {s} {t}", .{ try applied.pctEncode(arena, e.key), e.kind });
            if (e.sha256) |h| try out.print(arena, " {s}", .{&h});
            if (e.mode) |m| try out.print(arena, " {o}", .{m});
            if (e.target) |tg| try out.print(arena, " -> {s}", .{try applied.pctEncode(arena, try t.apply(arena, tg))});
            try out.append(arena, '\n');
        }
    }
    return out.items;
}

/// The identity rewrite for `render`.
pub const verbatim = struct {
    pub fn apply(_: @This(), _: std.mem.Allocator, text: []const u8) ![]const u8 {
        return text;
    }
}{};

/// Provenance bytes as they read without their secret-value digests, which
/// depend on this state's key.
fn withoutDigests(arena: std.mem.Allocator, bytes: ?[]const u8) !?[]const u8 {
    const b = bytes orelse return null;
    const m = prov_map.deserialize(arena, b) catch return b;
    if (m.secret_windows == null) return b;
    return try prov_map.serialize(arena, m.live_path, m.segments, null);
}
