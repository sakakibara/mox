//! A generation: everything mox knows about what it applied, as of one
//! commit, and what that commit displaced.
//!
//! Path-valued strings are percent-encoded on disk. In memory a `paths`,
//! `residue` or `generators` key is the live path itself; a `displaced` key
//! is HOME-relative. A displaced directory's members are kept flat, each
//! under its full key and naming the key of the tree it belongs to; on disk
//! they are grouped into that directory's `tree`.

const std = @import("std");
const json = @import("json");
const applied = @import("../apply/applied.zig");

pub const version: i128 = 2;
pub const Hex = [applied.hash_hex_len]u8;

pub const Kind = enum { apply, rollback, commit, remove, doctor, private, uninstall, recovered };
pub const RecordKind = enum { file, owned, link };
pub const Mode = applied.Mode;

pub const FileRec = struct {
    sha256: Hex,
    cache_blob: ?Hex = null,
    provenance_blob: ?Hex = null,
};

pub const OwnedRec = struct {
    mode: Mode = .own,
    secret: bool = false,
    canonical_blob: ?Hex = null,
    canonical_sha256: ?Hex = null,
    own_paths: []const []const u8 = &.{},
    secret_paths: []const []const u8 = &.{},
};

pub const LinkRec = struct {
    target: []const u8,
    rolled_back: bool = false,
};

pub const PathEntry = struct {
    part: Hex,
    source_key: ?[]const u8 = null,
    kind: RecordKind,
    file: ?FileRec = null,
    owned: ?OwnedRec = null,
    link: ?LinkRec = null,
};

pub const GeneratorEntry = struct {
    part: Hex,
    source_key: ?[]const u8 = null,
    produced: []const []const u8 = &.{},
};

pub const Flags = struct {
    expects_private: bool = false,
    tombstones_seen: []const []const u8 = &.{},
};

pub const PartInfo = struct { repo: []const u8, home: []const u8 };

pub const EntryType = enum { file, link, dir };

pub const Planted = struct {
    live: []const u8,
    target: []const u8,
    part: Hex,
};

/// One displaced entry, flat: `root` is the key of the directory tree it was
/// captured in, null for an entry of its own.
pub const Displaced = struct {
    type: EntryType,
    blob: ?Hex = null,
    target: ?[]const u8 = null,
    mode: ?u32 = null,
    planted: ?Planted = null,
    root: ?[]const u8 = null,
};

pub fn Map(comptime T: type) type {
    return std.StringArrayHashMapUnmanaged(T);
}

pub const Generation = struct {
    id: []const u8,
    parent: ?[]const u8 = null,
    kind: Kind,
    run_kind: Kind,
    undoes: ?[]const u8 = null,
    parts: Map(PartInfo) = .empty,
    flags: Map(Flags) = .empty,
    paths: Map(PathEntry) = .empty,
    residue: Map(Hex) = .empty,
    generators: Map(GeneratorEntry) = .empty,
    displaced: Map(Displaced) = .empty,

    /// A copy whose maps can change without touching `g`'s.
    pub fn clone(g: Generation, arena: std.mem.Allocator) !Generation {
        var out = g;
        out.parts = try g.parts.clone(arena);
        out.flags = try g.flags.clone(arena);
        out.paths = try g.paths.clone(arena);
        out.residue = try g.residue.clone(arena);
        out.generators = try g.generators.clone(arena);
        out.displaced = try g.displaced.clone(arena);
        return out;
    }
};

pub const ParseError = error{ Malformed, OutOfMemory };

/// Why a generation's bytes were not read: they do not parse, or a newer mox
/// wrote them.
pub const Unread = union(enum) { malformed, newer: i128 };

pub fn parse(arena: std.mem.Allocator, bytes: []const u8, unread: ?*Unread) ParseError!Generation {
    if (unread) |u| u.* = .malformed;
    const root = json.parse(arena, bytes, .{}) catch return malformed(unread);
    if (root != .object) return malformed(unread);
    const o = root.object;
    const ver = intOf(o.get("v")) orelse return malformed(unread);
    if (ver != version) {
        if (unread) |u| u.* = .{ .newer = ver };
        return error.Malformed;
    }
    var g: Generation = .{
        .id = strOf(o.get("id")) orelse return malformed(unread),
        .parent = try optStr(o.get("parent"), unread),
        .kind = enumOf(Kind, o.get("kind")) orelse return malformed(unread),
        .run_kind = enumOf(Kind, o.get("run_kind")) orelse return malformed(unread),
        .undoes = try optStr(o.get("undoes"), unread),
    };
    if (try objOf(o.get("parts"))) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            const po = (try objOf(e.value_ptr.*)) orelse return error.Malformed;
            try g.parts.put(arena, e.key_ptr.*, .{ .repo = try pathStr(arena, po.get("repo")), .home = try pathStr(arena, po.get("home")) });
        }
    }
    if (try objOf(o.get("flags"))) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            const fo = (try objOf(e.value_ptr.*)) orelse return error.Malformed;
            try g.flags.put(arena, e.key_ptr.*, .{
                .expects_private = boolOf(fo.get("expects_private")) orelse false,
                .tombstones_seen = try pathList(arena, fo.get("tombstones_seen")),
            });
        }
    }
    if (try objOf(o.get("paths"))) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            const po = (try objOf(e.value_ptr.*)) orelse return error.Malformed;
            try g.paths.put(arena, try decodeKey(arena, e.key_ptr.*), try parsePathEntry(arena, po));
        }
    }
    if (try objOf(o.get("residue"))) |m| {
        var it = m.iterator();
        while (it.next()) |e| try g.residue.put(arena, try decodeKey(arena, e.key_ptr.*), try hexOf(e.value_ptr.*));
    }
    if (try objOf(o.get("generators"))) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            const go = (try objOf(e.value_ptr.*)) orelse return error.Malformed;
            try g.generators.put(arena, try decodeKey(arena, e.key_ptr.*), .{
                .part = try hexOf(go.get("part") orelse return error.Malformed),
                .source_key = try optPath(arena, go.get("source_key")),
                .produced = try pathList(arena, go.get("produced")),
            });
        }
    }
    if (try objOf(o.get("displaced"))) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            const key = try decodeKey(arena, e.key_ptr.*);
            const d = (try objOf(e.value_ptr.*)) orelse return error.Malformed;
            try g.displaced.put(arena, key, try parseDisplaced(arena, d, null));
            if (d.get("tree")) |tv| {
                if (tv != .array) return error.Malformed;
                for (tv.array) |mv| {
                    if (mv != .object) return error.Malformed;
                    const rel = try pathStr(arena, mv.object.get("rel"));
                    const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ key, rel });
                    try g.displaced.put(arena, full, try parseDisplaced(arena, mv.object, key));
                }
            }
        }
    }
    return g;
}

fn malformed(unread: ?*Unread) ParseError {
    if (unread) |u| u.* = .malformed;
    return error.Malformed;
}

fn parsePathEntry(arena: std.mem.Allocator, o: json.ObjectMap) ParseError!PathEntry {
    const e: PathEntry = .{
        .part = try hexOf(o.get("part") orelse return error.Malformed),
        .source_key = try optPath(arena, o.get("source_key")),
        .kind = enumOf(RecordKind, o.get("kind")) orelse return error.Malformed,
        .file = try parseFile(o.get("file")),
        .owned = try parseOwned(arena, o.get("owned")),
        .link = try parseLink(arena, o.get("link")),
    };
    const present: usize = @as(usize, @intFromBool(e.file != null)) + @intFromBool(e.owned != null) + @intFromBool(e.link != null);
    if (present != 1) return error.Malformed;
    const ok = switch (e.kind) {
        .file => e.file != null,
        .owned => e.owned != null,
        .link => e.link != null,
    };
    if (!ok) return error.Malformed;
    return e;
}

fn parseFile(v: ?json.Value) ParseError!?FileRec {
    const o = (try objOf(v)) orelse return null;
    return .{
        .sha256 = try hexOf(o.get("sha256") orelse return error.Malformed),
        .cache_blob = try optHex(o.get("cache_blob")),
        .provenance_blob = try optHex(o.get("provenance_blob")),
    };
}

fn parseOwned(arena: std.mem.Allocator, v: ?json.Value) ParseError!?OwnedRec {
    const o = (try objOf(v)) orelse return null;
    return .{
        .mode = enumOf(Mode, o.get("mode")) orelse return error.Malformed,
        .secret = boolOf(o.get("secret")) orelse return error.Malformed,
        .canonical_blob = try optHex(o.get("canonical_blob")),
        .canonical_sha256 = try optHex(o.get("canonical_sha256")),
        .own_paths = try pathList(arena, o.get("own_paths")),
        .secret_paths = try pathList(arena, o.get("secret_paths")),
    };
}

fn parseLink(arena: std.mem.Allocator, v: ?json.Value) ParseError!?LinkRec {
    const o = (try objOf(v)) orelse return null;
    return .{ .target = try pathStr(arena, o.get("target")), .rolled_back = boolOf(o.get("rolled_back")) orelse false };
}

fn parseDisplaced(arena: std.mem.Allocator, o: json.ObjectMap, root: ?[]const u8) ParseError!Displaced {
    var d: Displaced = .{
        .type = enumOf(EntryType, o.get("type")) orelse return error.Malformed,
        .blob = try optHex(o.get("blob")),
        .target = try optPath(arena, o.get("target")),
        .mode = if (o.get("mode")) |m| switch (m) {
            .null => null,
            .integer => |i| std.math.cast(u32, i) orelse return error.Malformed,
            else => return error.Malformed,
        } else null,
        .root = root,
    };
    if (try objOf(o.get("planted"))) |p| {
        d.planted = .{ .live = try pathStr(arena, p.get("live")), .target = try pathStr(arena, p.get("target")), .part = try hexOf(p.get("part") orelse return error.Malformed) };
    }
    return d;
}

/// The bytes `g` is stored as.
pub fn serialize(arena: std.mem.Allocator, g: Generation) ![]const u8 {
    var root: json.ObjectMap = .empty;
    try root.put(arena, "v", .{ .integer = version });
    try root.put(arena, "id", .{ .string = g.id });
    try root.put(arena, "parent", optString(g.parent));
    try root.put(arena, "kind", .{ .string = @tagName(g.kind) });
    try root.put(arena, "run_kind", .{ .string = @tagName(g.run_kind) });
    try root.put(arena, "undoes", optString(g.undoes));

    var parts: json.ObjectMap = .empty;
    for (g.parts.keys(), g.parts.values()) |k, p| {
        var o: json.ObjectMap = .empty;
        try o.put(arena, "repo", .{ .string = try applied.pctEncode(arena, p.repo) });
        try o.put(arena, "home", .{ .string = try applied.pctEncode(arena, p.home) });
        try parts.put(arena, k, .{ .object = o });
    }
    try root.put(arena, "parts", .{ .object = parts });

    var flags: json.ObjectMap = .empty;
    for (g.flags.keys(), g.flags.values()) |k, f| try flags.put(arena, k, try flagsValue(arena, f));
    try root.put(arena, "flags", .{ .object = flags });

    var paths: json.ObjectMap = .empty;
    for (g.paths.keys(), g.paths.values()) |k, e| try paths.put(arena, try encodeKey(arena, k), try pathEntryValue(arena, e));
    try root.put(arena, "paths", .{ .object = paths });

    var residue: json.ObjectMap = .empty;
    for (g.residue.keys(), g.residue.values()) |k, h| try residue.put(arena, try encodeKey(arena, k), .{ .string = try arena.dupe(u8, &h) });
    try root.put(arena, "residue", .{ .object = residue });

    var gens: json.ObjectMap = .empty;
    for (g.generators.keys(), g.generators.values()) |k, e| try gens.put(arena, try encodeKey(arena, k), try generatorValue(arena, e));
    try root.put(arena, "generators", .{ .object = gens });

    try root.put(arena, "displaced", .{ .object = try displacedValue(arena, g.displaced) });

    var aw: std.Io.Writer.Allocating = .init(arena);
    try json.encode(&aw.writer, .{ .object = root }, .{ .sort_keys = true });
    try aw.writer.writeByte('\n');
    return aw.written();
}

pub fn flagsValue(arena: std.mem.Allocator, f: Flags) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(arena, "expects_private", .{ .bool = f.expects_private });
    try o.put(arena, "tombstones_seen", try pathArray(arena, f.tombstones_seen));
    return .{ .object = o };
}

pub fn partValue(arena: std.mem.Allocator, p: PartInfo) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(arena, "repo", .{ .string = try applied.pctEncode(arena, p.repo) });
    try o.put(arena, "home", .{ .string = try applied.pctEncode(arena, p.home) });
    return .{ .object = o };
}

pub fn pathEntryValue(arena: std.mem.Allocator, e: PathEntry) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(arena, "part", .{ .string = try arena.dupe(u8, &e.part) });
    try o.put(arena, "source_key", try optPathValue(arena, e.source_key));
    try o.put(arena, "kind", .{ .string = @tagName(e.kind) });
    if (e.file) |f| try o.put(arena, "file", try fileValue(arena, f));
    if (e.owned) |ow| try o.put(arena, "owned", try ownedValue(arena, ow));
    if (e.link) |l| try o.put(arena, "link", try linkValue(arena, l));
    return .{ .object = o };
}

fn fileValue(arena: std.mem.Allocator, f: FileRec) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(arena, "sha256", .{ .string = try arena.dupe(u8, &f.sha256) });
    try o.put(arena, "cache_blob", optHexValue(arena, f.cache_blob));
    try o.put(arena, "provenance_blob", optHexValue(arena, f.provenance_blob));
    return .{ .object = o };
}

fn ownedValue(arena: std.mem.Allocator, r: OwnedRec) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(arena, "mode", .{ .string = @tagName(r.mode) });
    try o.put(arena, "secret", .{ .bool = r.secret });
    try o.put(arena, "canonical_blob", optHexValue(arena, r.canonical_blob));
    try o.put(arena, "canonical_sha256", optHexValue(arena, r.canonical_sha256));
    try o.put(arena, "own_paths", try pathArray(arena, r.own_paths));
    try o.put(arena, "secret_paths", try pathArray(arena, r.secret_paths));
    return .{ .object = o };
}

fn linkValue(arena: std.mem.Allocator, l: LinkRec) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(arena, "target", .{ .string = try applied.pctEncode(arena, l.target) });
    try o.put(arena, "rolled_back", .{ .bool = l.rolled_back });
    return .{ .object = o };
}

pub fn generatorValue(arena: std.mem.Allocator, e: GeneratorEntry) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(arena, "part", .{ .string = try arena.dupe(u8, &e.part) });
    try o.put(arena, "source_key", try optPathValue(arena, e.source_key));
    try o.put(arena, "produced", try pathArray(arena, e.produced));
    return .{ .object = o };
}

/// One flat displaced entry as a journal line carries it.
pub fn flatDisplacedValue(arena: std.mem.Allocator, d: Displaced) !json.Value {
    var o = try displacedFields(arena, d);
    try o.put(arena, "root", try optPathValue(arena, d.root));
    return .{ .object = o };
}

pub fn parseFlatDisplaced(arena: std.mem.Allocator, v: json.Value) ParseError!Displaced {
    if (v != .object) return error.Malformed;
    return parseDisplaced(arena, v.object, try optPath(arena, v.object.get("root")));
}

fn displacedFields(arena: std.mem.Allocator, d: Displaced) !json.ObjectMap {
    var o: json.ObjectMap = .empty;
    try o.put(arena, "type", .{ .string = @tagName(d.type) });
    if (d.blob) |b| try o.put(arena, "blob", .{ .string = try arena.dupe(u8, &b) });
    if (d.target) |t| try o.put(arena, "target", .{ .string = try applied.pctEncode(arena, t) });
    if (d.mode) |m| try o.put(arena, "mode", .{ .integer = m });
    if (d.planted) |p| {
        var po: json.ObjectMap = .empty;
        try po.put(arena, "live", .{ .string = try applied.pctEncode(arena, p.live) });
        try po.put(arena, "target", .{ .string = try applied.pctEncode(arena, p.target) });
        try po.put(arena, "part", .{ .string = try arena.dupe(u8, &p.part) });
        try o.put(arena, "planted", .{ .object = po });
    }
    return o;
}

fn displacedValue(arena: std.mem.Allocator, m: Map(Displaced)) !json.ObjectMap {
    var out: json.ObjectMap = .empty;
    var trees = std.StringArrayHashMapUnmanaged(std.ArrayList(json.Value)).empty;
    for (m.keys(), m.values()) |k, d| {
        const root = treeOf(m, d) orelse continue;
        var fields = try displacedFields(arena, d);
        try fields.put(arena, "rel", .{ .string = try applied.pctEncode(arena, k[root.len + 1 ..]) });
        const gop = try trees.getOrPut(arena, root);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, .{ .object = fields });
    }
    for (m.keys(), m.values()) |k, d| {
        if (treeOf(m, d) != null) continue;
        var fields = try displacedFields(arena, d);
        if (trees.getPtr(k)) |members| {
            std.mem.sort(json.Value, members.items, {}, lessRel);
            try fields.put(arena, "tree", .{ .array = members.items });
        }
        try out.put(arena, try encodeKey(arena, k), .{ .object = fields });
    }
    return out;
}

/// The tree a member is written under: its root, when that is a directory
/// of its own; else none, and the member is written as an entry of its own.
fn treeOf(m: Map(Displaced), d: Displaced) ?[]const u8 {
    const root = d.root orelse return null;
    const r = m.get(root) orelse return null;
    if (r.type != .dir or r.root != null) return null;
    return root;
}

fn lessRel(_: void, a: json.Value, b: json.Value) bool {
    return std.mem.lessThan(u8, a.object.get("rel").?.string, b.object.get("rel").?.string);
}

pub fn encodeKey(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    return applied.pctEncode(arena, key);
}

pub fn decodeKey(arena: std.mem.Allocator, key: []const u8) ParseError![]const u8 {
    return (try applied.pctDecode(arena, key)) orelse error.Malformed;
}

fn optString(s: ?[]const u8) json.Value {
    return if (s) |v| .{ .string = v } else .null;
}

fn optHexValue(arena: std.mem.Allocator, h: ?Hex) json.Value {
    const v = h orelse return .null;
    return .{ .string = arena.dupe(u8, &v) catch return .null };
}

fn optPathValue(arena: std.mem.Allocator, s: ?[]const u8) !json.Value {
    return if (s) |v| .{ .string = try applied.pctEncode(arena, v) } else .null;
}

fn pathArray(arena: std.mem.Allocator, items: []const []const u8) !json.Value {
    const out = try arena.alloc(json.Value, items.len);
    for (items, out) |s, *o| o.* = .{ .string = try applied.pctEncode(arena, s) };
    return .{ .array = out };
}

fn objOf(v: ?json.Value) ParseError!?json.ObjectMap {
    const val = v orelse return null;
    return switch (val) {
        .null => null,
        .object => |o| o,
        else => error.Malformed,
    };
}

fn strOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

fn optStr(v: ?json.Value, unread: ?*Unread) ParseError!?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .null => null,
        .string => |s| s,
        else => malformed(unread),
    };
}

fn intOf(v: ?json.Value) ?i128 {
    const val = v orelse return null;
    return if (val == .integer) val.integer else null;
}

fn boolOf(v: ?json.Value) ?bool {
    const val = v orelse return null;
    return if (val == .bool) val.bool else null;
}

fn enumOf(comptime E: type, v: ?json.Value) ?E {
    const s = strOf(v) orelse return null;
    return std.meta.stringToEnum(E, s);
}

pub fn hexOf(v: json.Value) ParseError!Hex {
    if (v != .string) return error.Malformed;
    return parseHex(v.string) orelse error.Malformed;
}

pub fn parseHex(s: []const u8) ?Hex {
    if (s.len != applied.hash_hex_len) return null;
    for (s) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return null;
    var out: Hex = undefined;
    @memcpy(&out, s);
    return out;
}

fn optHex(v: ?json.Value) ParseError!?Hex {
    const val = v orelse return null;
    if (val == .null) return null;
    return try hexOf(val);
}

fn pathStr(arena: std.mem.Allocator, v: ?json.Value) ParseError![]const u8 {
    const s = strOf(v) orelse return error.Malformed;
    return (try applied.pctDecode(arena, s)) orelse error.Malformed;
}

fn optPath(arena: std.mem.Allocator, v: ?json.Value) ParseError!?[]const u8 {
    const val = v orelse return null;
    if (val == .null) return null;
    return try pathStr(arena, val);
}

fn pathList(arena: std.mem.Allocator, v: ?json.Value) ParseError![]const []const u8 {
    const val = v orelse return &.{};
    if (val != .array) return error.Malformed;
    const out = try arena.alloc([]const u8, val.array.len);
    for (val.array, out) |e, *o| o.* = try pathStr(arena, e);
    return out;
}

test "generation: serialize then parse round-trips every map, members grouped under their tree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const h = applied.contentHashHex("x");
    var g: Generation = .{ .id = "20260101T000000Z", .parent = null, .kind = .apply, .run_kind = .apply };
    try g.parts.put(a, &h, .{ .repo = "/r e", .home = "/h" });
    try g.flags.put(a, &h, .{ .expects_private = true, .tombstones_seen = &.{"/h/.t"} });
    try g.paths.put(a, "/h/.a b", .{ .part = h, .source_key = "src/.a b", .kind = .file, .file = .{ .sha256 = h, .cache_blob = h } });
    try g.paths.put(a, "/h/link", .{ .part = h, .kind = .link, .link = .{ .target = "/t" } });
    try g.residue.put(a, "/h/.gone", h);
    try g.generators.put(a, "/h/gen", .{ .part = h, .produced = &.{ "/h/a", "/h/b" } });
    try g.displaced.put(a, "d", .{ .type = .dir, .mode = 0o700 });
    try g.displaced.put(a, "d/f", .{ .type = .file, .blob = h, .mode = 0o644, .root = "d" });
    try g.displaced.put(a, "l", .{ .type = .link, .target = "/x", .planted = .{ .live = "/h/l", .target = "/x", .part = h } });

    const bytes = try serialize(a, g);
    const back = try parse(a, bytes, null);
    try std.testing.expectEqualStrings(bytes, try serialize(a, back));
    try std.testing.expectEqualStrings("d", back.displaced.get("d/f").?.root.?);
    try std.testing.expectEqual(@as(u32, 0o700), back.displaced.get("d").?.mode.?);
    try std.testing.expectEqualStrings("/r e", back.parts.get(&h).?.repo);
    try std.testing.expect(back.paths.get("/h/link").?.kind == .link);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"tree\"") != null);
}

test "generation: a newer version is reported, and a path with no part, no kind, or a kind with no matching record is malformed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var why: Unread = .malformed;
    try std.testing.expectError(error.Malformed, parse(a, "{\"v\":3,\"id\":\"x\"}", &why));
    try std.testing.expectEqual(@as(i128, 3), why.newer);
    const part = "\"part\":\"" ++ "0" ** 64 ++ "\"";
    for ([_][]const u8{ "{\"kind\":\"file\"," ++ part ++ "}", "{\"kind\":\"file\",\"link\":{\"target\":\"/t\"}," ++ part ++ "}", "{\"kind\":\"link\",\"link\":{\"target\":\"/t\"}}", "{\"link\":{\"target\":\"/t\"}," ++ part ++ "}" }) |entry| {
        try std.testing.expectError(error.Malformed, parse(a, try std.fmt.allocPrint(a, "{{\"v\":2,\"id\":\"x\",\"kind\":\"apply\",\"run_kind\":\"apply\",\"paths\":{{\"/p\":{s}}}}}", .{entry}), &why));
        try std.testing.expect(why == .malformed);
    }
}
