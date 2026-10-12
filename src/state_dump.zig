//! A normalized dump of what mox persists about what it applied, for tests.
//!
//! Tests and the differential gate read state only through this: per live
//! path its recorded kinds and provenance, the generators' produced sets,
//! the tombstone and private-layer flags answered for the parts asked about,
//! and every snapshot's entries. A path is keyed by the sha256 of its live
//! path, and content by its sha256, never by where the store keeps it.

const std = @import("std");
const Io = std.Io;
const applied = @import("apply/applied.zig");
const generated = @import("apply/generated.zig");
const snapshot = @import("apply/snapshot.zig");
const stale = @import("apply/stale.zig");
const expect = @import("private/expect.zig");
const dirent = @import("source/dirent.zig");
const source_path = @import("source/path.zig");

const Hex = [applied.hash_hex_len]u8;

/// The entries of the state directory that hold the records this dump
/// reports; everything else there is listed by the caller as it is.
pub const store_entries = [_][]const u8{
    "applied",   "applied-content", "applied-owned", "applied-symlink",  "provenance",
    "generated", "snapshots",       "released",      "expected-private", "mox.lock",
};

/// The directory under `state_dir` that the content a run displaces is
/// written into first, before the run replaces what it held.
pub fn displacedStore(arena: std.mem.Allocator, state_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ state_dir, "snapshots" });
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

const max_bytes: usize = 64 * 1024 * 1024;

pub fn load(arena: std.mem.Allocator, io: Io, opts: Options) !Dump {
    var paths: std.StringArrayHashMapUnmanaged(Path) = .empty;
    const sd = opts.state_dir;
    for (try files(arena, io, sd, "applied")) |f| {
        const rec = (try applied.parseWhole(arena, f.bytes)) orelse continue;
        const p = try pathAt(arena, &paths, f.name);
        const cache = readOpt(arena, io, try std.fs.path.join(arena, &.{ sd, "applied-content", f.name }));
        p.file = .{ .sha256 = rec.hash, .cache = if (cache) |c| applied.contentHashHex(c) else null };
    }
    for (try files(arena, io, sd, "applied-owned")) |f| {
        const rec = (try applied.parseOwned(arena, f.bytes)) orelse continue;
        (try pathAt(arena, &paths, f.name)).owned = .{ .mode = rec.mode, .own_paths = rec.own_paths, .secret_paths = rec.secret_paths };
    }
    for (try files(arena, io, sd, "applied-symlink")) |f| {
        const rec = try applied.parseSymlink(arena, f.bytes);
        (try pathAt(arena, &paths, f.name)).link = .{ .target = rec.target, .rolled_back = rec.rolled_back };
    }
    for (try files(arena, io, sd, "provenance")) |f| {
        (try pathAt(arena, &paths, f.name)).provenance = f.bytes;
    }
    const path_list = paths.values();
    std.mem.sort(Path, path_list, {}, struct {
        fn lt(_: void, a: Path, b: Path) bool {
            return std.mem.lessThan(u8, &a.key, &b.key);
        }
    }.lt);

    var gens: std.ArrayList(Generator) = .empty;
    for (try files(arena, io, sd, "generated")) |f| {
        const key = hexName(f.name) orelse continue;
        var leaves: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, f.bytes, '\n');
        var first = true;
        while (it.next()) |line| {
            defer first = false;
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            if (first and std.mem.startsWith(u8, t, "repo ")) continue;
            if (std.mem.startsWith(u8, t, "generator ")) continue;
            try leaves.append(arena, t);
        }
        std.mem.sort([]const u8, leaves.items, {}, lessStr);
        try gens.append(arena, .{ .key = key, .produced = leaves.items });
    }

    var seen: std.ArrayList(Seen) = .empty;
    var expects: std.ArrayList(bool) = .empty;
    for (opts.parts, 0..) |part, i| {
        const tag = try applied.repoTag(arena, io, part.repo, part.home);
        try expects.append(arena, try expect.expected(arena, io, sd, tag));
        for (opts.tombstones) |t| {
            const name = applied.contentHashHex(try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ tag, try stale.foldCase(arena, t) }));
            const marker = try std.fs.path.join(arena, &.{ sd, "released", &name });
            const there = if (Io.Dir.cwd().access(io, marker, .{})) true else |_| false;
            try seen.append(arena, .{ .part = i, .tombstone = t, .seen = there });
        }
    }

    return .{
        .paths = path_list,
        .generators = gens.items,
        .seen = seen.items,
        .expects_private = expects.items,
        .generations = try snapshots(arena, io, try std.fs.path.join(arena, &.{ sd, "snapshots" })),
    };
}

fn snapshots(arena: std.mem.Allocator, io: Io, dir_path: []const u8) ![]const Generation {
    var id_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (try dirent.sortedPath(arena, io, dir_path, .{ .iterate = true })) |e| {
        if (e.kind == .directory) {
            try id_set.put(arena, e.name, {});
        } else if (e.kind == .file and std.mem.endsWith(u8, e.name, ".dirmodes")) {
            try id_set.put(arena, e.name[0 .. e.name.len - ".dirmodes".len], {});
        }
    }
    const id_list = id_set.keys();
    std.mem.sort([]const u8, id_list, {}, olderId);
    var out: std.ArrayList(Generation) = .empty;
    for (id_list) |id| {
        var entries: std.StringArrayHashMapUnmanaged(Entry) = .empty;
        const root = try std.fs.path.join(arena, &.{ dir_path, id });
        try mirror(arena, io, root, "", &entries);
        if (readOpt(arena, io, try std.fmt.allocPrint(arena, "{s}.dirmodes", .{root}))) |modes| {
            var lines = std.mem.splitScalar(u8, modes, '\n');
            while (lines.next()) |line| {
                const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
                const mode = std.fmt.parseInt(u32, line[0..sp], 8) catch continue;
                const key = line[sp + 1 ..];
                try entries.put(arena, key, .{ .key = key, .kind = .dir, .mode = mode });
            }
        }
        if (entries.count() == 0) continue;
        const list = entries.values();
        std.mem.sort(Entry, list, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lt);
        try out.append(arena, .{ .id = id, .entries = list });
    }
    return out.items;
}

fn mirror(arena: std.mem.Allocator, io: Io, abs: []const u8, rel: []const u8, out: *std.StringArrayHashMapUnmanaged(Entry)) !void {
    for (try dirent.sortedPath(arena, io, abs, .{ .iterate = true })) |e| {
        const child = try std.fs.path.join(arena, &.{ abs, e.name });
        const key = if (rel.len == 0) e.name else try source_path.joinKey(arena, &.{ rel, e.name });
        switch (e.kind) {
            .directory => try mirror(arena, io, child, key, out),
            .file => {
                const bytes = try Io.Dir.cwd().readFileAlloc(io, child, arena, .limited(max_bytes));
                const st = try Io.Dir.cwd().statFile(io, child, .{});
                try out.put(arena, key, .{ .key = key, .kind = .file, .sha256 = applied.contentHashHex(bytes), .mode = @intCast(st.permissions.toMode() & 0o777) });
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = try Io.Dir.cwd().readLink(io, child, &buf);
                try out.put(arena, key, .{ .key = key, .kind = .link, .target = try arena.dupe(u8, buf[0..n]) });
            },
            else => {},
        }
    }
}

fn olderId(_: void, a: []const u8, b: []const u8) bool {
    const sa = splitId(a);
    const sb = splitId(b);
    const o = std.mem.order(u8, sa.base, sb.base);
    if (o != .eq) return o == .lt;
    if (sa.n != sb.n) return sa.n < sb.n;
    return std.mem.lessThan(u8, a, b);
}

fn splitId(id: []const u8) struct { base: []const u8, n: u64 } {
    const n = snapshot.id_len;
    if (id.len > n and id[n] == '-') {
        if (std.fmt.parseInt(u64, id[n + 1 ..], 10)) |v| return .{ .base = id[0..n], .n = v } else |_| {}
    }
    return .{ .base = id, .n = 1 };
}

const Named = struct { name: []const u8, bytes: []const u8 };

fn files(arena: std.mem.Allocator, io: Io, state_dir: []const u8, family: []const u8) ![]const Named {
    const dir = try std.fs.path.join(arena, &.{ state_dir, family });
    var out: std.ArrayList(Named) = .empty;
    for (try dirent.sortedPath(arena, io, dir, .{ .iterate = true })) |e| {
        if (e.kind != .file) continue;
        const bytes = Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ dir, e.name }), arena, .limited(max_bytes)) catch continue;
        try out.append(arena, .{ .name = e.name, .bytes = bytes });
    }
    return out.items;
}

fn readOpt(arena: std.mem.Allocator, io: Io, path: []const u8) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch null;
}

fn hexName(name: []const u8) ?Hex {
    if (name.len != applied.hash_hex_len) return null;
    for (name) |c| if (!std.ascii.isHex(c)) return null;
    var out: Hex = undefined;
    @memcpy(&out, name);
    return out;
}

fn pathAt(arena: std.mem.Allocator, paths: *std.StringArrayHashMapUnmanaged(Path), name: []const u8) !*Path {
    const key = hexName(name) orelse return error.UnnamedRecord;
    const gop = try paths.getOrPut(arena, name);
    if (!gop.found_existing) gop.value_ptr.* = .{ .key = key };
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
