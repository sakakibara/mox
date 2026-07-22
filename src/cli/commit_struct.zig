//! Diff two structured (Cat A) documents to a set of changed key paths.
//!
//! Parses `live_bytes` and `composed_bytes` with the format lib matching
//! `format`, then walks both trees together: a key present on both sides
//! recurses into nested tables or compares leaves; a key only in `composed`
//! is an addition; a key only in `live` is a removal. `new` always holds
//! `composed`'s value -- the same base/overlay convention the `*_merge.zig`
//! deep-merges use (see `toml_merge.mergeTables`), where the second argument
//! wins and `live` plays the role of `base`.
//!
//! An array that differs from its counterpart only by element order (a
//! permutation, with no stable per-element identity to say what "moved")
//! cannot be expressed as a key-path set; the whole diff fails with
//! `error.Unrepresentable`, which the commit route (Task 9/10) maps to a
//! manual hunk. Any other array difference -- added/removed/changed
//! elements -- is one whole-array `KeyPathChange` at that path.

const std = @import("std");
const toml = @import("toml");
const json = @import("json");
const yaml = @import("yaml");
const ini = @import("ini");
const category = @import("../compose/category.zig");

const Io = std.Io;

pub const Format = enum { toml, json, yaml, ini, gitconfig };

/// The composed-side value for a `KeyPathChange`, tagged by the format lib
/// that produced it. Task 9 applies it back into source with the same lib.
pub const Value = union(enum) {
    toml: toml.Value,
    json: json.Value,
    yaml: yaml.Value,
    /// Shared by both `.ini` and `.gitconfig`: ini-zig's `Value` is the same
    /// Zig type for either dialect.
    ini: ini.Value,
};

pub const KeyPathChange = struct {
    path: []const []const u8,
    new: ?Value,
    removed: bool,
};

/// Diff `live_bytes` against `composed_bytes` under `format`, returning the
/// changed key paths. Returns `error.Unrepresentable` when some difference
/// (a reordered array with no stable identity) cannot be expressed as a
/// key-path set.
pub fn changedKeyPaths(
    arena: std.mem.Allocator,
    format: Format,
    live_bytes: []const u8,
    composed_bytes: []const u8,
) ![]const KeyPathChange {
    var out: std.ArrayList(KeyPathChange) = .empty;
    switch (format) {
        .toml => {
            const live = try toml.parse(arena, live_bytes, .{});
            const composed = try toml.parse(arena, composed_bytes, .{});
            if (live != .table or composed != .table) return error.NotATable;
            try walkToml(arena, &.{}, live, composed, &out);
        },
        .json => {
            const live = try json.parse(arena, live_bytes, .{ .dialect = .jsonc });
            const composed = try json.parse(arena, composed_bytes, .{ .dialect = .jsonc });
            if (live != .object or composed != .object) return error.NotAnObject;
            try walkJson(arena, &.{}, live, composed, &out);
        },
        .yaml => {
            const live = try yaml.parse(arena, live_bytes, .{});
            const composed = try yaml.parse(arena, composed_bytes, .{});
            if (live != .map or composed != .map) return error.NotAMapping;
            try walkYaml(arena, &.{}, live, composed, &out);
        },
        .ini, .gitconfig => {
            const dialect: ini.Dialect = if (format == .gitconfig) .gitconfig else .generic;
            const live = try ini.parse(arena, live_bytes, .{ .dialect = dialect });
            const composed = try ini.parse(arena, composed_bytes, .{ .dialect = dialect });
            if (live != .section or composed != .section) return error.NotASection;
            try walkIni(arena, &.{}, live.section.*, composed.section.*, &out);
        },
    }
    return out.toOwnedSlice(arena);
}

/// Explicit error set for the mutually-recursive per-format walk/diff pairs:
/// Zig cannot infer an error set across a `walk` <-> `diff` recursion loop.
const DiffWalkError = std.mem.Allocator.Error || error{Unrepresentable};

fn appendPath(arena: std.mem.Allocator, prefix: []const []const u8, key: []const u8) ![]const []const u8 {
    const p = try arena.alloc([]const u8, prefix.len + 1);
    @memcpy(p[0..prefix.len], prefix);
    p[prefix.len] = key;
    return p;
}

fn walkToml(
    arena: std.mem.Allocator,
    prefix: []const []const u8,
    live: toml.Value,
    composed: toml.Value,
    out: *std.ArrayList(KeyPathChange),
) DiffWalkError!void {
    var it = live.table.iterator();
    while (it.next()) |entry| {
        const path = try appendPath(arena, prefix, entry.key_ptr.*);
        if (composed.table.get(entry.key_ptr.*)) |cv| {
            try diffTomlValue(arena, path, entry.value_ptr.*, cv, out);
        } else {
            try out.append(arena, .{ .path = path, .new = null, .removed = true });
        }
    }
    var cit = composed.table.iterator();
    while (cit.next()) |entry| {
        if (live.table.contains(entry.key_ptr.*)) continue;
        const path = try appendPath(arena, prefix, entry.key_ptr.*);
        try out.append(arena, .{ .path = path, .new = .{ .toml = entry.value_ptr.* }, .removed = false });
    }
}

fn diffTomlValue(
    arena: std.mem.Allocator,
    path: []const []const u8,
    live_v: toml.Value,
    composed_v: toml.Value,
    out: *std.ArrayList(KeyPathChange),
) DiffWalkError!void {
    if (live_v == .table and composed_v == .table) {
        try walkToml(arena, path, live_v, composed_v, out);
        return;
    }
    if (live_v == .array and composed_v == .array) {
        if (live_v.eql(composed_v)) return;
        if (try isPermutation(toml.Value, arena, live_v.array.items, composed_v.array.items, tomlEql)) return error.Unrepresentable;
        try out.append(arena, .{ .path = path, .new = .{ .toml = composed_v }, .removed = false });
        return;
    }
    if (live_v.eql(composed_v)) return;
    try out.append(arena, .{ .path = path, .new = .{ .toml = composed_v }, .removed = false });
}

fn tomlEql(a: toml.Value, b: toml.Value) bool {
    return a.eql(b);
}

fn walkJson(
    arena: std.mem.Allocator,
    prefix: []const []const u8,
    live: json.Value,
    composed: json.Value,
    out: *std.ArrayList(KeyPathChange),
) DiffWalkError!void {
    var it = live.object.iterator();
    while (it.next()) |entry| {
        const path = try appendPath(arena, prefix, entry.key_ptr.*);
        if (composed.object.get(entry.key_ptr.*)) |cv| {
            try diffJsonValue(arena, path, entry.value_ptr.*, cv, out);
        } else {
            try out.append(arena, .{ .path = path, .new = null, .removed = true });
        }
    }
    var cit = composed.object.iterator();
    while (cit.next()) |entry| {
        if (live.object.contains(entry.key_ptr.*)) continue;
        const path = try appendPath(arena, prefix, entry.key_ptr.*);
        try out.append(arena, .{ .path = path, .new = .{ .json = entry.value_ptr.* }, .removed = false });
    }
}

fn diffJsonValue(
    arena: std.mem.Allocator,
    path: []const []const u8,
    live_v: json.Value,
    composed_v: json.Value,
    out: *std.ArrayList(KeyPathChange),
) DiffWalkError!void {
    if (live_v == .object and composed_v == .object) {
        try walkJson(arena, path, live_v, composed_v, out);
        return;
    }
    if (live_v == .array and composed_v == .array) {
        if (jsonEql(live_v, composed_v)) return;
        if (try isPermutation(json.Value, arena, live_v.array, composed_v.array, jsonEql)) return error.Unrepresentable;
        try out.append(arena, .{ .path = path, .new = .{ .json = composed_v }, .removed = false });
        return;
    }
    if (jsonEql(live_v, composed_v)) return;
    try out.append(arena, .{ .path = path, .new = .{ .json = composed_v }, .removed = false });
}

/// json.Value has no built-in `eql` (unlike toml/yaml), so this deep-compares
/// it by hand for the change/no-change and permutation checks above.
fn jsonEql(a: json.Value, b: json.Value) bool {
    if (@as(std.meta.Tag(json.Value), a) != @as(std.meta.Tag(json.Value), b)) return false;
    return switch (a) {
        .null => true,
        .bool => |av| av == b.bool,
        .integer => |av| av == b.integer,
        .float => |av| av == b.float,
        .string => |av| std.mem.eql(u8, av, b.string),
        .number_raw => |av| std.mem.eql(u8, av, b.number_raw),
        .array => |av| blk: {
            if (av.len != b.array.len) break :blk false;
            for (av, b.array) |x, y| if (!jsonEql(x, y)) break :blk false;
            break :blk true;
        },
        .object => |av| blk: {
            if (av.count() != b.object.count()) break :blk false;
            var it = av.iterator();
            while (it.next()) |e| {
                const bv = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!jsonEql(e.value_ptr.*, bv)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn walkYaml(
    arena: std.mem.Allocator,
    prefix: []const []const u8,
    live: yaml.Value,
    composed: yaml.Value,
    out: *std.ArrayList(KeyPathChange),
) DiffWalkError!void {
    for (live.map) |entry| {
        // Non-string-keyed entries are not addressable by a key path; skip,
        // mirroring yaml_merge.zig's deepMerge (they carry through as-is
        // and are never matched).
        const key = entryKeyYaml(entry) orelse continue;
        const path = try appendPath(arena, prefix, key);
        if (yaml.Value.mapGet(composed.map, key)) |cv| {
            try diffYamlValue(arena, path, entry.value, cv, out);
        } else {
            try out.append(arena, .{ .path = path, .new = null, .removed = true });
        }
    }
    for (composed.map) |entry| {
        const key = entryKeyYaml(entry) orelse continue;
        if (yaml.Value.mapGet(live.map, key) != null) continue;
        const path = try appendPath(arena, prefix, key);
        try out.append(arena, .{ .path = path, .new = .{ .yaml = entry.value }, .removed = false });
    }
}

fn diffYamlValue(
    arena: std.mem.Allocator,
    path: []const []const u8,
    live_v: yaml.Value,
    composed_v: yaml.Value,
    out: *std.ArrayList(KeyPathChange),
) DiffWalkError!void {
    if (live_v == .map and composed_v == .map) {
        try walkYaml(arena, path, live_v, composed_v, out);
        return;
    }
    if (live_v == .seq and composed_v == .seq) {
        if (live_v.eql(composed_v)) return;
        if (try isPermutation(yaml.Value, arena, live_v.seq, composed_v.seq, yamlEql)) return error.Unrepresentable;
        try out.append(arena, .{ .path = path, .new = .{ .yaml = composed_v }, .removed = false });
        return;
    }
    if (live_v.eql(composed_v)) return;
    try out.append(arena, .{ .path = path, .new = .{ .yaml = composed_v }, .removed = false });
}

fn yamlEql(a: yaml.Value, b: yaml.Value) bool {
    return a.eql(b);
}

fn entryKeyYaml(e: yaml.Entry) ?[]const u8 {
    return if (e.key == .string) e.key.string else null;
}

fn walkIni(
    arena: std.mem.Allocator,
    prefix: []const []const u8,
    live: ini.Section,
    composed: ini.Section,
    out: *std.ArrayList(KeyPathChange),
) DiffWalkError!void {
    for (live.entries) |entry| {
        const path = try appendPath(arena, prefix, entry.key);
        if (composed.findValue(entry.key)) |cv| {
            try diffIniValue(arena, path, entry.value, cv, out);
        } else {
            try out.append(arena, .{ .path = path, .new = null, .removed = true });
        }
    }
    for (composed.entries) |entry| {
        if (live.findValue(entry.key) != null) continue;
        const path = try appendPath(arena, prefix, entry.key);
        try out.append(arena, .{ .path = path, .new = .{ .ini = entry.value }, .removed = false });
    }
}

fn diffIniValue(
    arena: std.mem.Allocator,
    path: []const []const u8,
    live_v: ini.Value,
    composed_v: ini.Value,
    out: *std.ArrayList(KeyPathChange),
) DiffWalkError!void {
    if (live_v == .section and composed_v == .section) {
        try walkIni(arena, path, live_v.section.*, composed_v.section.*, out);
        return;
    }
    if (live_v == .list and composed_v == .list) {
        if (iniEql(live_v, composed_v)) return;
        if (try isPermutation([]const u8, arena, live_v.list, composed_v.list, strEql)) return error.Unrepresentable;
        try out.append(arena, .{ .path = path, .new = .{ .ini = composed_v }, .removed = false });
        return;
    }
    if (iniEql(live_v, composed_v)) return;
    try out.append(arena, .{ .path = path, .new = .{ .ini = composed_v }, .removed = false });
}

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// ini.Value has no built-in `eql`, so this deep-compares it by hand.
fn iniEql(a: ini.Value, b: ini.Value) bool {
    if (@as(std.meta.Tag(ini.Value), a) != @as(std.meta.Tag(ini.Value), b)) return false;
    return switch (a) {
        .string => |av| std.mem.eql(u8, av, b.string),
        .list => |av| blk: {
            if (av.len != b.list.len) break :blk false;
            for (av, b.list) |x, y| if (!std.mem.eql(u8, x, y)) break :blk false;
            break :blk true;
        },
        .section => |av| iniSectionEql(av.*, b.section.*),
    };
}

fn iniSectionEql(a: ini.Section, b: ini.Section) bool {
    if (a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |ae, be| {
        if (!std.mem.eql(u8, ae.key, be.key)) return false;
        if (!iniEql(ae.value, be.value)) return false;
    }
    return true;
}

/// Whether `composed` is exactly a reordering of `live` (same length, same
/// multiset of elements under `eqlFn`, in some different order). Callers
/// have already established the two slices are not equal outright, so a
/// permutation match here means the only difference is element order --
/// which has no stable per-element identity to express as a key path.
///
/// Array-diff policy: a same-length reordering of an array (a permutation)
/// is `error.Unrepresentable` (ambiguous: reorder vs. element-wise edits).
/// Any other array difference -- including a mid-insert or a length change
/// -- is a whole-array replacement (a normal `KeyPathChange` setting the
/// path to the composed array), which is correct because arrays replace
/// rather than merge in mox composition.
fn isPermutation(
    comptime T: type,
    arena: std.mem.Allocator,
    live: []const T,
    composed: []const T,
    eqlFn: fn (T, T) bool,
) std.mem.Allocator.Error!bool {
    if (live.len != composed.len) return false;
    const used = try arena.alloc(bool, composed.len);
    @memset(used, false);
    outer: for (live) |lv| {
        for (composed, 0..) |cv, i| {
            if (used[i]) continue;
            if (eqlFn(lv, cv)) {
                used[i] = true;
                continue :outer;
            }
        }
        return false;
    }
    return true;
}

const max_layer_bytes: usize = 64 * 1024 * 1024;

/// Apply one key-path change to a single layer's structured source file
/// (a base or an overlay), writing the result back to `layer_abs`. An
/// absent `layer_abs` starts from an empty document for `format`.
///
/// Every format edits through its lossless `Document` model: the change is
/// spliced in place, so comments and layout outside the touched key survive.
/// A path segment is addressed as one atomic segment even when it contains a
/// character (like TOML's `.`) that would be ambiguous in a joined string.
/// A missing intermediate container, or an absent or empty layer, is
/// created as needed.
pub fn applyToLayer(
    arena: std.mem.Allocator,
    io: Io,
    format: Format,
    layer_abs: []const u8,
    change: KeyPathChange,
) !void {
    if (change.path.len == 0) return error.EmptyPath;
    const existing: ?[]const u8 = Io.Dir.cwd().readFileAlloc(io, layer_abs, arena, .limited(max_layer_bytes)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    const out = switch (format) {
        .toml => try applyTomlLayer(arena, existing, change),
        .json => try applyJsonLayer(arena, existing, change),
        .yaml => try applyYamlLayer(arena, existing, change),
        .ini, .gitconfig => try applyIniLayer(arena, existing, change, format),
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = layer_abs, .data = out });
}

fn applyTomlLayer(arena: std.mem.Allocator, existing: ?[]const u8, change: KeyPathChange) ![]const u8 {
    var doc = if (emptyLayer(existing)) try toml.Document.empty(arena, .{}) else try toml.Document.parse(arena, existing.?, .{});
    if (change.removed) try doc.removeSegments(change.path) else try doc.setValueSegments(change.path, change.new.?.toml);
    return emitDoc(arena, &doc);
}

fn applyJsonLayer(arena: std.mem.Allocator, existing: ?[]const u8, change: KeyPathChange) ![]const u8 {
    var doc = if (emptyLayer(existing)) try json.Document.empty(arena, .{ .dialect = .jsonc }) else try json.Document.parse(arena, existing.?, .{ .dialect = .jsonc });
    if (change.removed) try doc.removeSegments(change.path) else try doc.setValueSegments(change.path, change.new.?.json);
    return emitDoc(arena, &doc);
}

fn applyYamlLayer(arena: std.mem.Allocator, existing: ?[]const u8, change: KeyPathChange) ![]const u8 {
    var doc = if (emptyLayer(existing)) try yaml.Document.empty(arena, .{}) else try yaml.Document.parse(arena, existing.?, .{});
    if (change.removed) try doc.removeSegments(change.path) else try doc.setValueSegments(change.path, change.new.?.yaml);
    return emitDoc(arena, &doc);
}

fn applyIniLayer(arena: std.mem.Allocator, existing: ?[]const u8, change: KeyPathChange, format: Format) ![]const u8 {
    const dialect: ini.Dialect = if (format == .gitconfig) .gitconfig else .generic;
    var doc = if (emptyLayer(existing)) try ini.Document.empty(arena, .{ .dialect = dialect }) else try ini.Document.parse(arena, existing.?, .{ .dialect = dialect });
    if (change.removed) try doc.removeSegments(change.path) else try doc.setValueSegments(change.path, change.new.?.ini);
    return emitDoc(arena, &doc);
}

fn emptyLayer(existing: ?[]const u8) bool {
    return existing == null or existing.?.len == 0;
}

fn emitDoc(arena: std.mem.Allocator, doc: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    return arena.dupe(u8, aw.written());
}

/// Detect the structured format of a managed-file source path, or null when it
/// is not a Cat-A structured format. Mirrors the composer's extension table,
/// with gitconfig recognized by path shape rather than extension.
pub fn formatOfPath(path: []const u8) ?Format {
    if (category.isGitConfigPath(path)) return .gitconfig;
    const Pair = struct { ext: []const u8, format: Format };
    const table = [_]Pair{
        .{ .ext = ".toml", .format = .toml },
        .{ .ext = ".yaml", .format = .yaml },
        .{ .ext = ".yml", .format = .yaml },
        .{ .ext = ".json", .format = .json },
        .{ .ext = ".ini", .format = .ini },
        .{ .ext = ".gitconfig", .format = .gitconfig },
    };
    var longest: ?Format = null;
    var longest_len: usize = 0;
    for (table) |entry| {
        if (std.mem.endsWith(u8, path, entry.ext) and entry.ext.len > longest_len) {
            longest = entry.format;
            longest_len = entry.ext.len;
        }
    }
    return longest;
}

/// Parse one layer's bytes into a `Value` tagged by `format`, for the pure
/// layer-selection walk. INI and gitconfig share ini-zig's `Value`.
pub fn parseLayer(arena: std.mem.Allocator, format: Format, bytes: []const u8) !Value {
    return switch (format) {
        .toml => .{ .toml = try toml.parse(arena, bytes, .{}) },
        .json => .{ .json = try json.parse(arena, bytes, .{ .dialect = .jsonc }) },
        .yaml => .{ .yaml = try yaml.parse(arena, bytes, .{}) },
        .ini => .{ .ini = try ini.parse(arena, bytes, .{ .dialect = .generic }) },
        .gitconfig => .{ .ini = try ini.parse(arena, bytes, .{ .dialect = .gitconfig }) },
    };
}

/// One parsed source layer of a structured file. `layers` passed to
/// `resolveLayer` are ordered least-specific-first (the composer's fold order):
/// index 0 is the base when the file has one, then overlays in increasing
/// specificity, so the LAST layer defining a key is the one that wins it.
pub const StructLayer = struct {
    path: []const u8,
    is_base: bool,
    value: Value,
};

/// Where a `KeyPathChange` should be written, recomputed from the parsed
/// layers rather than stored provenance.
pub const Resolution = struct {
    action: Action,
    /// Index into `layers` of the default target: the winner for a changed key,
    /// the base for a new key, the sole definer for a single-layer removal.
    /// Meaningful only when `action != .skip`.
    target: usize,
    /// Indices of every layer that DEFINES the key, most-specific-first. Empty
    /// for a new key. Drives the pick menu's shadow-deletion annotations.
    definers: []const usize,
    /// Set only when `action == .skip`.
    skip_reason: ?[]const u8,

    pub const Action = enum { set, remove, skip };
};

/// Resolve the layer a single `KeyPathChange` should be written to. Pure over
/// `layers` (already parsed, least-specific-first); mutates nothing.
pub fn resolveLayer(
    arena: std.mem.Allocator,
    format: Format,
    layers: []const StructLayer,
    change: KeyPathChange,
) !Resolution {
    // Every layer that defines the key, most-specific-first.
    var defs: std.ArrayList(usize) = .empty;
    var i: usize = layers.len;
    while (i > 0) {
        i -= 1;
        if (definesPath(format, layers[i].value, change.path)) try defs.append(arena, i);
    }
    const definers = try defs.toOwnedSlice(arena);

    if (change.removed) {
        if (definers.len == 0)
            return .{ .action = .skip, .target = 0, .definers = definers, .skip_reason = "key is not defined by any source layer" };
        if (definers.len > 1)
            return .{ .action = .skip, .target = 0, .definers = definers, .skip_reason = "defined by more than one layer; removing one only surfaces another" };
        return .{ .action = .remove, .target = definers[0], .definers = definers, .skip_reason = null };
    }

    if (definers.len == 0)
        return .{ .action = .set, .target = 0, .definers = definers, .skip_reason = null };

    const winner = definers[0];
    if (layerScalar(format, layers[winner].value, change.path)) |s| {
        if (hasCapture(s))
            return .{ .action = .skip, .target = 0, .definers = definers, .skip_reason = "value is interpolation- or secret-derived" };
    }
    return .{ .action = .set, .target = winner, .definers = definers, .skip_reason = null };
}

/// Paths of every layer more specific than `chosen` that defines the key: the
/// override entries a placement at `chosen` must delete to take effect.
/// `definers` is most-specific-first; layers are least-specific-first, so a
/// definer index greater than `chosen` is more specific.
pub fn shadowers(
    arena: std.mem.Allocator,
    layers: []const StructLayer,
    definers: []const usize,
    chosen: usize,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (definers) |d| {
        if (d > chosen) try out.append(arena, layers[d].path);
    }
    return out.toOwnedSlice(arena);
}

/// Whether `value` defines `path`, walking nested containers per format.
fn definesPath(format: Format, value: Value, path: []const []const u8) bool {
    return switch (format) {
        .toml => tomlHas(value.toml, path),
        .json => jsonHas(value.json, path),
        .yaml => yamlHas(value.yaml, path),
        .ini, .gitconfig => iniHas(value.ini, path),
    };
}

fn tomlHas(v: toml.Value, path: []const []const u8) bool {
    if (path.len == 0) return true;
    if (v != .table) return false;
    const child = v.table.get(path[0]) orelse return false;
    return tomlHas(child, path[1..]);
}

fn jsonHas(v: json.Value, path: []const []const u8) bool {
    if (path.len == 0) return true;
    if (v != .object) return false;
    const child = v.object.get(path[0]) orelse return false;
    return jsonHas(child, path[1..]);
}

fn yamlHas(v: yaml.Value, path: []const []const u8) bool {
    if (path.len == 0) return true;
    if (v != .map) return false;
    const child = yaml.Value.mapGet(v.map, path[0]) orelse return false;
    return yamlHas(child, path[1..]);
}

fn iniHas(v: ini.Value, path: []const []const u8) bool {
    if (path.len == 0) return true;
    if (v != .section) return false;
    const child = v.section.findValue(path[0]) orelse return false;
    return iniHas(child, path[1..]);
}

/// The leaf scalar string at `path` in `value`, or null when the leaf is
/// absent or not a string. Only strings can carry an interpolation capture.
fn layerScalar(format: Format, value: Value, path: []const []const u8) ?[]const u8 {
    return switch (format) {
        .toml => tomlScalar(value.toml, path),
        .json => jsonScalar(value.json, path),
        .yaml => yamlScalar(value.yaml, path),
        .ini, .gitconfig => iniScalar(value.ini, path),
    };
}

fn tomlScalar(v: toml.Value, path: []const []const u8) ?[]const u8 {
    if (path.len == 0) return if (v == .string) v.string else null;
    if (v != .table) return null;
    const child = v.table.get(path[0]) orelse return null;
    return tomlScalar(child, path[1..]);
}

fn jsonScalar(v: json.Value, path: []const []const u8) ?[]const u8 {
    if (path.len == 0) return if (v == .string) v.string else null;
    if (v != .object) return null;
    const child = v.object.get(path[0]) orelse return null;
    return jsonScalar(child, path[1..]);
}

fn yamlScalar(v: yaml.Value, path: []const []const u8) ?[]const u8 {
    if (path.len == 0) return if (v == .string) v.string else null;
    if (v != .map) return null;
    const child = yaml.Value.mapGet(v.map, path[0]) orelse return null;
    return yamlScalar(child, path[1..]);
}

fn iniScalar(v: ini.Value, path: []const []const u8) ?[]const u8 {
    if (path.len == 0) return if (v == .string) v.string else null;
    if (v != .section) return null;
    const child = v.section.findValue(path[0]) orelse return null;
    return iniScalar(child, path[1..]);
}

/// Whether `s` holds any non-empty `<...>` capture. Conservative on purpose: a
/// structured value carrying a capture is interpolation- or secret-derived, and
/// routing its resolved live value into source would bake a fact or secret. The
/// never-bake-a-secret / never-guess-a-fact invariants win over precision here.
fn hasCapture(s: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, s, lt + 1, '>') orelse return false;
        if (gt > lt + 1) return true;
        i = gt + 1;
    }
    return false;
}

/// Render the scalar at `path` in `bytes` (parsed under `format`) as a short
/// display string for the pick confirm's before/after column, or null when the
/// path is absent. A non-scalar leaf (a table or array) renders as a bracketed
/// kind rather than a whole subtree.
pub fn displayAt(arena: std.mem.Allocator, format: Format, bytes: []const u8, path: []const []const u8) !?[]const u8 {
    const v = try parseLayer(arena, format, bytes);
    return switch (format) {
        .toml => tomlDisplay(arena, v.toml, path),
        .json => jsonDisplay(arena, v.json, path),
        .yaml => yamlDisplay(arena, v.yaml, path),
        .ini, .gitconfig => iniDisplay(arena, v.ini, path),
    };
}

fn tomlDisplay(arena: std.mem.Allocator, value: toml.Value, path: []const []const u8) !?[]const u8 {
    var cur = value;
    for (path) |seg| {
        if (cur != .table) return null;
        cur = cur.table.get(seg) orelse return null;
    }
    return switch (cur) {
        .string => |s| s,
        .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .boolean => |b| if (b) "true" else "false",
        .array => "(array)",
        .table => "(table)",
        else => "(value)",
    };
}

fn jsonDisplay(arena: std.mem.Allocator, value: json.Value, path: []const []const u8) !?[]const u8 {
    var cur = value;
    for (path) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return switch (cur) {
        .string => |s| s,
        .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        .number_raw => |s| s,
        .array => "(array)",
        .object => "(object)",
    };
}

fn yamlDisplay(arena: std.mem.Allocator, value: yaml.Value, path: []const []const u8) !?[]const u8 {
    var cur = value;
    for (path) |seg| {
        if (cur != .map) return null;
        cur = yaml.Value.mapGet(cur.map, seg) orelse return null;
    }
    return switch (cur) {
        .string => |s| s,
        .int => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        .seq => "(seq)",
        .map => "(map)",
    };
}

fn iniDisplay(arena: std.mem.Allocator, value: ini.Value, path: []const []const u8) !?[]const u8 {
    var cur = value;
    for (path) |seg| {
        if (cur != .section) return null;
        cur = cur.section.findValue(seg) orelse return null;
    }
    return switch (cur) {
        .string => |s| s,
        .list => |l| try std.mem.join(arena, ", ", l),
        .section => "(section)",
    };
}

// ---- tests ----

const testing = std.testing;

fn diffOne(arena: std.mem.Allocator, format: Format, live: []const u8, composed: []const u8) ![]const KeyPathChange {
    return changedKeyPaths(arena, format, live, composed);
}

test "toml diff: scalar change yields one KeyPathChange" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .toml, "name = \"foo\"\nversion = 1\n", "name = \"bar\"\nversion = 1\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(usize, 1), result[0].path.len);
    try testing.expectEqualStrings("name", result[0].path[0]);
    try testing.expect(!result[0].removed);
    try testing.expectEqualStrings("bar", result[0].new.?.toml.string);
}

test "toml diff: removed key yields removed=true" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .toml, "name = \"foo\"\nversion = 1\n", "name = \"foo\"\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("version", result[0].path[0]);
    try testing.expect(result[0].removed);
    try testing.expect(result[0].new == null);
}

test "toml diff: added key yields normal change with composed value" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .toml, "x = 1\n", "x = 1\ny = 2\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("y", result[0].path[0]);
    try testing.expect(!result[0].removed);
    try testing.expectEqual(@as(i64, 2), result[0].new.?.toml.integer);
}

test "toml diff: nested table change yields the nested path" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .toml, "[user]\nname = \"foo\"\nage = 30\n", "[user]\nname = \"bar\"\nage = 30\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(usize, 2), result[0].path.len);
    try testing.expectEqualStrings("user", result[0].path[0]);
    try testing.expectEqualStrings("name", result[0].path[1]);
    try testing.expectEqualStrings("bar", result[0].new.?.toml.string);
}

test "toml diff: array reorder with no stable identity is unrepresentable" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = diffOne(a, .toml, "shells = [\"zsh\", \"fish\"]\n", "shells = [\"fish\", \"zsh\"]\n");
    try testing.expectError(error.Unrepresentable, result);
}

test "toml diff: whole array replacement yields a normal change" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .toml, "shells = [\"zsh\"]\n", "shells = [\"fish\", \"bash\"]\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("shells", result[0].path[0]);
    try testing.expect(!result[0].removed);
    const arr = result[0].new.?.toml.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    try testing.expectEqualStrings("fish", arr.items[0].string);
}

test "json diff: scalar change yields one KeyPathChange" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .json, "{\"name\":\"foo\"}", "{\"name\":\"bar\"}");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("name", result[0].path[0]);
    try testing.expect(!result[0].removed);
    try testing.expectEqualStrings("bar", result[0].new.?.json.string);
}

test "json diff: removed key yields removed=true" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .json, "{\"name\":\"foo\",\"version\":1}", "{\"name\":\"foo\"}");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("version", result[0].path[0]);
    try testing.expect(result[0].removed);
    try testing.expect(result[0].new == null);
}

test "json diff: nested object change yields the nested path" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .json, "{\"user\":{\"name\":\"foo\",\"age\":30}}", "{\"user\":{\"name\":\"bar\",\"age\":30}}");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("user", result[0].path[0]);
    try testing.expectEqualStrings("name", result[0].path[1]);
    try testing.expectEqualStrings("bar", result[0].new.?.json.string);
}

test "json diff: array reorder with no stable identity is unrepresentable" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = diffOne(a, .json, "{\"shells\":[\"zsh\",\"fish\"]}", "{\"shells\":[\"fish\",\"zsh\"]}");
    try testing.expectError(error.Unrepresentable, result);
}

test "json diff: whole array replacement yields a normal change" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .json, "{\"shells\":[\"zsh\"]}", "{\"shells\":[\"fish\",\"bash\"]}");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("shells", result[0].path[0]);
    const arr = result[0].new.?.json.array;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("fish", arr[0].string);
}

test "yaml diff: scalar change yields one KeyPathChange" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .yaml, "name: foo\n", "name: bar\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("name", result[0].path[0]);
    try testing.expect(!result[0].removed);
    try testing.expectEqualStrings("bar", result[0].new.?.yaml.string);
}

test "yaml diff: removed key yields removed=true" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .yaml, "name: foo\nversion: 1\n", "name: foo\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("version", result[0].path[0]);
    try testing.expect(result[0].removed);
    try testing.expect(result[0].new == null);
}

test "yaml diff: nested mapping change yields the nested path" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .yaml, "user:\n  name: foo\n  age: 30\n", "user:\n  name: bar\n  age: 30\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("user", result[0].path[0]);
    try testing.expectEqualStrings("name", result[0].path[1]);
    try testing.expectEqualStrings("bar", result[0].new.?.yaml.string);
}

test "yaml diff: sequence reorder with no stable identity is unrepresentable" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = diffOne(a, .yaml, "shells:\n  - zsh\n  - fish\n", "shells:\n  - fish\n  - zsh\n");
    try testing.expectError(error.Unrepresentable, result);
}

test "yaml diff: whole sequence replacement yields a normal change" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .yaml, "shells:\n  - zsh\n", "shells:\n  - fish\n  - bash\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("shells", result[0].path[0]);
    const seq = result[0].new.?.yaml.seq;
    try testing.expectEqual(@as(usize, 2), seq.len);
    try testing.expectEqualStrings("fish", seq[0].string);
}

test "yaml diff: duplicate composed key resolves to the last-wins value" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // `composed` has a literal duplicate `name` key; YAML semantics say the
    // later occurrence wins. The diff must compare `live` against "bar"
    // (last-wins), not "foo" (first occurrence).
    const result = try diffOne(a, .yaml, "name: baz\n", "name: foo\nname: bar\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("name", result[0].path[0]);
    try testing.expect(!result[0].removed);
    try testing.expectEqualStrings("bar", result[0].new.?.yaml.string);
}

test "toml diff: mid-insert array yields a normal change with the full composed array" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .toml, "shells = [\"a\", \"c\"]\n", "shells = [\"a\", \"b\", \"c\"]\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("shells", result[0].path[0]);
    try testing.expect(!result[0].removed);
    const arr = result[0].new.?.toml.array;
    try testing.expectEqual(@as(usize, 3), arr.items.len);
    try testing.expectEqualStrings("a", arr.items[0].string);
    try testing.expectEqualStrings("b", arr.items[1].string);
    try testing.expectEqualStrings("c", arr.items[2].string);
}

test "toml diff: same-length array permutation is unrepresentable" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = diffOne(a, .toml, "shells = [\"a\", \"b\"]\n", "shells = [\"b\", \"a\"]\n");
    try testing.expectError(error.Unrepresentable, result);
}

test "json diff: mid-insert array yields a normal change with the full composed array" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .json, "{\"shells\":[\"a\",\"c\"]}", "{\"shells\":[\"a\",\"b\",\"c\"]}");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("shells", result[0].path[0]);
    try testing.expect(!result[0].removed);
    const arr = result[0].new.?.json.array;
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqualStrings("a", arr[0].string);
    try testing.expectEqualStrings("b", arr[1].string);
    try testing.expectEqualStrings("c", arr[2].string);
}

test "json diff: same-length array permutation is unrepresentable" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = diffOne(a, .json, "{\"shells\":[\"a\",\"b\"]}", "{\"shells\":[\"b\",\"a\"]}");
    try testing.expectError(error.Unrepresentable, result);
}

test "json diff: added key at top level yields normal change with composed value" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .json, "{\"x\":1}", "{\"x\":1,\"y\":2}");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("y", result[0].path[0]);
    try testing.expect(!result[0].removed);
    try testing.expectEqual(@as(i64, 2), result[0].new.?.json.integer);
}

test "yaml diff: added key at top level yields normal change with composed value" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .yaml, "x: 1\n", "x: 1\ny: 2\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("y", result[0].path[0]);
    try testing.expect(!result[0].removed);
    try testing.expectEqual(@as(i128, 2), result[0].new.?.yaml.int);
}

test "ini diff: key change yields one KeyPathChange" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .ini, "top=1\n", "top=2\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("top", result[0].path[0]);
    try testing.expect(!result[0].removed);
    try testing.expectEqualStrings("2", result[0].new.?.ini.string);
}

test "ini diff: added key at top level yields normal change with composed value" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .ini, "x=1\n", "x=1\ny=2\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("y", result[0].path[0]);
    try testing.expect(!result[0].removed);
    try testing.expectEqualStrings("2", result[0].new.?.ini.string);
}

test "ini diff: removed key yields removed=true" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .ini, "[user]\nname=foo\nage=30\n", "[user]\nname=foo\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("user", result[0].path[0]);
    try testing.expectEqualStrings("age", result[0].path[1]);
    try testing.expect(result[0].removed);
}

test "ini diff: section-nested key change yields the nested path" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const result = try diffOne(a, .ini, "[user]\nname=foo\n", "[user]\nname=bar\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("user", result[0].path[0]);
    try testing.expectEqualStrings("name", result[0].path[1]);
    try testing.expectEqualStrings("bar", result[0].new.?.ini.string);
}

test "gitconfig diff: multi-value key reorder with no stable identity is unrepresentable" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const live = "[remote \"origin\"]\n\tpush = refs/a\n\tpush = refs/b\n";
    const composed = "[remote \"origin\"]\n\tpush = refs/b\n\tpush = refs/a\n";
    const result = diffOne(a, .gitconfig, live, composed);
    try testing.expectError(error.Unrepresentable, result);
}

test "gitconfig diff: whole multi-value replacement yields the nested path" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const live = "[remote \"origin\"]\n\tpush = refs/a\n\tpush = refs/b\n";
    const composed = "[remote \"origin\"]\n\tpush = refs/c\n\tpush = refs/d\n";
    const result = try diffOne(a, .gitconfig, live, composed);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("remote", result[0].path[0]);
    try testing.expectEqualStrings("origin", result[0].path[1]);
    try testing.expectEqualStrings("push", result[0].path[2]);
    const list = result[0].new.?.ini.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("refs/c", list[0]);
    try testing.expectEqualStrings("refs/d", list[1]);
}

// ---- applyToLayer tests ----

fn layerPath(a: std.mem.Allocator, io: Io, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
}

test "applyToLayer: toml scalar change on an existing base sets the key and keeps a comment" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "# keep me\nname = \"foo\"\nversion = 1\n" });

    try applyToLayer(a, io, .toml, path, .{
        .path = &.{"version"},
        .new = .{ .toml = .{ .integer = 2 } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    try testing.expect(std.mem.indexOf(u8, out, "# keep me") != null);
    const reparsed = try toml.parse(a, out, .{});
    try testing.expectEqual(@as(i64, 2), reparsed.table.get("version").?.integer);
    try testing.expectEqualStrings("foo", reparsed.table.get("name").?.string);
}

test "applyToLayer: toml nested path creates the nested key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "top = 1\n" });

    try applyToLayer(a, io, .toml, path, .{
        .path = &.{ "user", "name" },
        .new = .{ .toml = .{ .string = "bar" } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try toml.parse(a, out, .{});
    try testing.expectEqualStrings("bar", reparsed.table.get("user").?.table.get("name").?.string);
}

test "applyToLayer: toml removed=true deletes the leaf key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "name = \"foo\"\nversion = 1\n" });

    try applyToLayer(a, io, .toml, path, .{ .path = &.{"version"}, .new = null, .removed = true });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try toml.parse(a, out, .{});
    try testing.expect(reparsed.table.get("version") == null);
    try testing.expectEqualStrings("foo", reparsed.table.get("name").?.string);
}

test "applyToLayer: toml absent layer file is created with just that key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "overlay.toml");

    try applyToLayer(a, io, .toml, path, .{
        .path = &.{"x"},
        .new = .{ .toml = .{ .integer = 1 } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try toml.parse(a, out, .{});
    try testing.expectEqual(@as(i64, 1), reparsed.table.get("x").?.integer);
}

test "applyToLayer: json scalar change on an existing base sets the key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.json");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"name\":\"foo\",\"version\":1}" });

    try applyToLayer(a, io, .json, path, .{
        .path = &.{"version"},
        .new = .{ .json = .{ .integer = 2 } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try json.parse(a, out, .{ .dialect = .jsonc });
    try testing.expectEqual(@as(i128, 2), reparsed.object.get("version").?.integer);
    try testing.expectEqualStrings("foo", reparsed.object.get("name").?.string);
}

test "applyToLayer: json nested path creates the nested key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.json");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"top\":1}" });

    try applyToLayer(a, io, .json, path, .{
        .path = &.{ "user", "name" },
        .new = .{ .json = .{ .string = "bar" } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try json.parse(a, out, .{ .dialect = .jsonc });
    try testing.expectEqualStrings("bar", reparsed.object.get("user").?.object.get("name").?.string);
}

test "applyToLayer: json removed=true deletes the leaf key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.json");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"name\":\"foo\",\"version\":1}" });

    try applyToLayer(a, io, .json, path, .{ .path = &.{"version"}, .new = null, .removed = true });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try json.parse(a, out, .{ .dialect = .jsonc });
    try testing.expect(reparsed.object.get("version") == null);
    try testing.expectEqualStrings("foo", reparsed.object.get("name").?.string);
}

test "applyToLayer: json absent layer file is created with just that key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "overlay.json");

    try applyToLayer(a, io, .json, path, .{
        .path = &.{"x"},
        .new = .{ .json = .{ .integer = 1 } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try json.parse(a, out, .{ .dialect = .jsonc });
    try testing.expectEqual(@as(i128, 1), reparsed.object.get("x").?.integer);
}

test "applyToLayer: yaml scalar change on an existing base sets the key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.yaml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "name: foo\nversion: 1\n" });

    try applyToLayer(a, io, .yaml, path, .{
        .path = &.{"version"},
        .new = .{ .yaml = .{ .int = 2 } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try yaml.parse(a, out, .{});
    try testing.expectEqual(@as(i128, 2), yaml.Value.mapGet(reparsed.map, "version").?.int);
    try testing.expectEqualStrings("foo", yaml.Value.mapGet(reparsed.map, "name").?.string);
}

test "applyToLayer: yaml nested path creates the nested key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.yaml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "top: 1\n" });

    try applyToLayer(a, io, .yaml, path, .{
        .path = &.{ "user", "name" },
        .new = .{ .yaml = .{ .string = "bar" } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try yaml.parse(a, out, .{});
    const user = yaml.Value.mapGet(reparsed.map, "user").?;
    try testing.expectEqualStrings("bar", yaml.Value.mapGet(user.map, "name").?.string);
}

test "applyToLayer: yaml removed=true deletes the leaf key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.yaml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "name: foo\nversion: 1\n" });

    try applyToLayer(a, io, .yaml, path, .{ .path = &.{"version"}, .new = null, .removed = true });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try yaml.parse(a, out, .{});
    try testing.expect(yaml.Value.mapGet(reparsed.map, "version") == null);
    try testing.expectEqualStrings("foo", yaml.Value.mapGet(reparsed.map, "name").?.string);
}

test "applyToLayer: yaml absent layer file is created with just that key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "overlay.yaml");

    try applyToLayer(a, io, .yaml, path, .{
        .path = &.{"x"},
        .new = .{ .yaml = .{ .int = 1 } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try yaml.parse(a, out, .{});
    try testing.expectEqual(@as(i128, 1), yaml.Value.mapGet(reparsed.map, "x").?.int);
}

test "applyToLayer: ini scalar change on an existing base sets the key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.ini");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "name=foo\nversion=1\n" });

    try applyToLayer(a, io, .ini, path, .{
        .path = &.{"version"},
        .new = .{ .ini = .{ .string = "2" } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try ini.parse(a, out, .{ .dialect = .generic });
    try testing.expectEqualStrings("2", reparsed.section.findValue("version").?.string);
    try testing.expectEqualStrings("foo", reparsed.section.findValue("name").?.string);
}

test "applyToLayer: ini nested path creates the nested section and key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.ini");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "top=1\n" });

    try applyToLayer(a, io, .ini, path, .{
        .path = &.{ "user", "name" },
        .new = .{ .ini = .{ .string = "bar" } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try ini.parse(a, out, .{ .dialect = .generic });
    const user = reparsed.section.findValue("user").?;
    try testing.expectEqualStrings("bar", user.section.findValue("name").?.string);
}

test "applyToLayer: ini removed=true deletes the leaf key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.ini");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "name=foo\nversion=1\n" });

    try applyToLayer(a, io, .ini, path, .{ .path = &.{"version"}, .new = null, .removed = true });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try ini.parse(a, out, .{ .dialect = .generic });
    try testing.expect(reparsed.section.findValue("version") == null);
    try testing.expectEqualStrings("foo", reparsed.section.findValue("name").?.string);
}

test "applyToLayer: ini absent layer file is created with just that key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "overlay.ini");

    try applyToLayer(a, io, .ini, path, .{
        .path = &.{"x"},
        .new = .{ .ini = .{ .string = "1" } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try ini.parse(a, out, .{ .dialect = .generic });
    try testing.expectEqualStrings("1", reparsed.section.findValue("x").?.string);
}

test "applyToLayer: ini add of a whole new section materializes it and keeps prior content" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.ini");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "top=1\n" });

    // A section that exists only on the composed side is diffed to a whole
    // `.section` value at the section's path (see walkIni).
    var entries = [_]ini.value.Entry{
        .{ .key = "name", .value = .{ .string = "alice" } },
        .{ .key = "email", .value = .{ .string = "a@b.c" } },
    };
    var sec = ini.Section{ .entries = entries[0..] };
    try applyToLayer(a, io, .ini, path, .{
        .path = &.{"user"},
        .new = .{ .ini = .{ .section = &sec } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try ini.parse(a, out, .{ .dialect = .generic });
    try testing.expectEqualStrings("1", reparsed.section.findValue("top").?.string);
    const user = reparsed.section.findValue("user").?.section;
    try testing.expectEqualStrings("alice", user.findValue("name").?.string);
    try testing.expectEqualStrings("a@b.c", user.findValue("email").?.string);
}

test "applyToLayer: ini removed=true on a section path deletes the whole section" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.ini");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "top=1\n[user]\nname=alice\n" });

    try applyToLayer(a, io, .ini, path, .{ .path = &.{"user"}, .new = null, .removed = true });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try ini.parse(a, out, .{ .dialect = .generic });
    try testing.expect(reparsed.section.findValue("user") == null);
    try testing.expectEqualStrings("1", reparsed.section.findValue("top").?.string);
}

test "applyToLayer: toml removed=true on a table path deletes the whole table" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "top = 1\n\n[user]\nname = \"alice\"\n" });

    try applyToLayer(a, io, .toml, path, .{ .path = &.{"user"}, .new = null, .removed = true });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try toml.parse(a, out, .{});
    try testing.expect(reparsed.table.get("user") == null);
    try testing.expectEqual(@as(i64, 1), reparsed.table.get("top").?.integer);
}

test "applyToLayer: gitconfig nested subsection change sets the key under the gitconfig dialect" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, ".gitconfig");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "[user]\n\tname = foo\n" });

    try applyToLayer(a, io, .gitconfig, path, .{
        .path = &.{ "remote", "origin", "url" },
        .new = .{ .ini = .{ .string = "git@example.com:x/y.git" } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    const reparsed = try ini.parse(a, out, .{ .dialect = .gitconfig });
    const remote = reparsed.section.findValue("remote").?;
    const origin = remote.section.findValue("origin").?;
    try testing.expectEqualStrings("git@example.com:x/y.git", origin.section.findValue("url").?.string);
    try testing.expectEqualStrings("foo", reparsed.section.findValue("user").?.section.findValue("name").?.string);
}

test "applyToLayer: toml new key with a dotted quoted key segment never builds the wrong nested chain" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.toml");
    const existing = "[host]\n# note\n";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = existing });

    // "example.com" is one segment (a quoted TOML key containing a literal
    // dot), not two. Addressing it as a path segment rather than a
    // dot-joined string means the Document splices in the leaf
    // "example.com" under host, never the wrong chain host -> example -> com.
    try applyToLayer(a, io, .toml, path, .{
        .path = &.{ "host", "example.com" },
        .new = .{ .toml = .{ .string = "1.2.3.4" } },
        .removed = false,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    try testing.expect(std.mem.indexOf(u8, out, "[host]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "# note") != null);
    const reparsed = try toml.parse(a, out, .{});
    const host = reparsed.table.get("host").?;
    try testing.expect(host.table.get("example") == null);
    try testing.expectEqualStrings("1.2.3.4", host.table.get("example.com").?.string);
}

test "applyToLayer: toml removal of a dotted quoted key segment never builds the wrong nested chain" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.toml");
    const existing = "[host]\n# note\n\"example.com\" = \"1.2.3.4\"\n";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = existing });

    try applyToLayer(a, io, .toml, path, .{
        .path = &.{ "host", "example.com" },
        .new = null,
        .removed = true,
    });

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    try testing.expect(std.mem.indexOf(u8, out, "[host]\n# note\n") != null);
    const reparsed = try toml.parse(a, out, .{});
    const host = reparsed.table.get("host").?;
    try testing.expect(host.table.get("example.com") == null);
    try testing.expect(host.table.get("example") == null);
}

test "applyToLayer: json non-container intermediate is a clean error, not a silent overwrite" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.json");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"foo\":\"scalar\"}" });

    const result = applyToLayer(a, io, .json, path, .{
        .path = &.{ "foo", "bar" },
        .new = .{ .json = .{ .string = "baz" } },
        .removed = false,
    });
    if (result) |_| unreachable else |_| {}

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    try testing.expectEqualStrings("{\"foo\":\"scalar\"}", out);
}

test "applyToLayer: yaml non-container intermediate is a clean error, not a silent overwrite" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.yaml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "foo: scalar\n" });

    const result = applyToLayer(a, io, .yaml, path, .{
        .path = &.{ "foo", "bar" },
        .new = .{ .yaml = .{ .string = "baz" } },
        .removed = false,
    });
    if (result) |_| unreachable else |_| {}

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    try testing.expectEqualStrings("foo: scalar\n", out);
}

test "applyToLayer: ini non-container intermediate is a clean error, not a silent overwrite" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.ini");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "foo=scalar\n" });

    const result = applyToLayer(a, io, .ini, path, .{
        .path = &.{ "foo", "bar" },
        .new = .{ .ini = .{ .string = "baz" } },
        .removed = false,
    });
    if (result) |_| unreachable else |_| {}

    const out = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_layer_bytes));
    try testing.expectEqualStrings("foo=scalar\n", out);
}

test "applyToLayer: empty path is a clean error, not a panic" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const path = try layerPath(a, io, &tmp, "base.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "x = 1\n" });

    const result = applyToLayer(a, io, .toml, path, .{
        .path = &.{},
        .new = .{ .toml = .{ .integer = 2 } },
        .removed = false,
    });
    try testing.expectError(error.EmptyPath, result);
}

test "resolveLayer: changed key won by an overlay targets that overlay" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const base = try toml.parse(a, "theme = \"light\"\nfont = \"mono\"\n", .{});
    const ov = try toml.parse(a, "theme = \"dark\"\n", .{});
    const layers = [_]StructLayer{
        .{ .path = "base.toml", .is_base = true, .value = .{ .toml = base } },
        .{ .path = "os=darwin.toml", .is_base = false, .value = .{ .toml = ov } },
    };
    const change: KeyPathChange = .{ .path = &.{"theme"}, .new = .{ .toml = .{ .string = "solarized" } }, .removed = false };

    const res = try resolveLayer(a, .toml, &layers, change);
    try testing.expectEqual(Resolution.Action.set, res.action);
    try testing.expectEqual(@as(usize, 1), res.target);
    try testing.expectEqual(@as(usize, 2), res.definers.len);
    try testing.expectEqual(@as(usize, 1), res.definers[0]);
    try testing.expectEqual(@as(usize, 0), res.definers[1]);
}

test "resolveLayer: new key with no definer targets the base" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const base = try toml.parse(a, "theme = \"light\"\n", .{});
    const ov = try toml.parse(a, "theme = \"dark\"\n", .{});
    const layers = [_]StructLayer{
        .{ .path = "base.toml", .is_base = true, .value = .{ .toml = base } },
        .{ .path = "os=darwin.toml", .is_base = false, .value = .{ .toml = ov } },
    };
    const change: KeyPathChange = .{ .path = &.{"newkey"}, .new = .{ .toml = .{ .integer = 1 } }, .removed = false };

    const res = try resolveLayer(a, .toml, &layers, change);
    try testing.expectEqual(Resolution.Action.set, res.action);
    try testing.expectEqual(@as(usize, 0), res.target);
    try testing.expectEqual(@as(usize, 0), res.definers.len);
}

test "resolveLayer: single-layer removal targets the sole definer" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const base = try toml.parse(a, "theme = \"light\"\n", .{});
    const ov = try toml.parse(a, "extra = \"x\"\n", .{});
    const layers = [_]StructLayer{
        .{ .path = "base.toml", .is_base = true, .value = .{ .toml = base } },
        .{ .path = "os=darwin.toml", .is_base = false, .value = .{ .toml = ov } },
    };
    const change: KeyPathChange = .{ .path = &.{"extra"}, .new = null, .removed = true };

    const res = try resolveLayer(a, .toml, &layers, change);
    try testing.expectEqual(Resolution.Action.remove, res.action);
    try testing.expectEqual(@as(usize, 1), res.target);
}

test "resolveLayer: multi-layer removal is skipped" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const base = try toml.parse(a, "theme = \"light\"\n", .{});
    const ov = try toml.parse(a, "theme = \"dark\"\n", .{});
    const layers = [_]StructLayer{
        .{ .path = "base.toml", .is_base = true, .value = .{ .toml = base } },
        .{ .path = "os=darwin.toml", .is_base = false, .value = .{ .toml = ov } },
    };
    const change: KeyPathChange = .{ .path = &.{"theme"}, .new = null, .removed = true };

    const res = try resolveLayer(a, .toml, &layers, change);
    try testing.expectEqual(Resolution.Action.skip, res.action);
    try testing.expect(res.skip_reason != null);
}

test "resolveLayer: an interpolation-derived value is skipped, never routed" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const base = try toml.parse(a, "email = \"<machine.email>\"\n", .{});
    const layers = [_]StructLayer{
        .{ .path = "base.toml", .is_base = true, .value = .{ .toml = base } },
    };
    const change: KeyPathChange = .{ .path = &.{"email"}, .new = .{ .toml = .{ .string = "me@x.test" } }, .removed = false };

    const res = try resolveLayer(a, .toml, &layers, change);
    try testing.expectEqual(Resolution.Action.skip, res.action);
}

test "shadowers: entries more specific than the chosen layer are returned" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const base = try toml.parse(a, "theme = \"light\"\n", .{});
    const ov = try toml.parse(a, "theme = \"dark\"\n", .{});
    const layers = [_]StructLayer{
        .{ .path = "base.toml", .is_base = true, .value = .{ .toml = base } },
        .{ .path = "os=darwin.toml", .is_base = false, .value = .{ .toml = ov } },
    };
    // definers most-specific-first: overlay (1), base (0).
    const definers = [_]usize{ 1, 0 };
    const sh = try shadowers(a, &layers, &definers, 0);
    try testing.expectEqual(@as(usize, 1), sh.len);
    try testing.expectEqualStrings("os=darwin.toml", sh[0]);

    const none = try shadowers(a, &layers, &definers, 1);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "resolveLayer: yaml winner and json winner resolve the most-specific layer" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const ybase = try yaml.parse(a, "theme: light\n", .{});
    const yov = try yaml.parse(a, "theme: dark\n", .{});
    const ylayers = [_]StructLayer{
        .{ .path = "base.yaml", .is_base = true, .value = .{ .yaml = ybase } },
        .{ .path = "os=darwin.yaml", .is_base = false, .value = .{ .yaml = yov } },
    };
    const ychange: KeyPathChange = .{ .path = &.{"theme"}, .new = .{ .yaml = .{ .string = "solarized" } }, .removed = false };
    const yres = try resolveLayer(a, .yaml, &ylayers, ychange);
    try testing.expectEqual(@as(usize, 1), yres.target);

    const jbase = try json.parse(a, "{\"theme\":\"light\"}", .{ .dialect = .jsonc });
    const jov = try json.parse(a, "{\"theme\":\"dark\"}", .{ .dialect = .jsonc });
    const jlayers = [_]StructLayer{
        .{ .path = "base.json", .is_base = true, .value = .{ .json = jbase } },
        .{ .path = "os=darwin.json", .is_base = false, .value = .{ .json = jov } },
    };
    const jchange: KeyPathChange = .{ .path = &.{"theme"}, .new = .{ .json = .{ .string = "solarized" } }, .removed = false };
    const jres = try resolveLayer(a, .json, &jlayers, jchange);
    try testing.expectEqual(@as(usize, 1), jres.target);
}

test "resolveLayer: gitconfig nested key resolves through sections" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const base = try ini.parse(a, "[user]\n\tname = base\n", .{ .dialect = .gitconfig });
    const ov = try ini.parse(a, "[user]\n\tname = over\n", .{ .dialect = .gitconfig });
    const layers = [_]StructLayer{
        .{ .path = "base.gitconfig", .is_base = true, .value = .{ .ini = base } },
        .{ .path = "os=darwin.gitconfig", .is_base = false, .value = .{ .ini = ov } },
    };
    const change: KeyPathChange = .{ .path = &.{ "user", "name" }, .new = .{ .ini = .{ .string = "picked" } }, .removed = false };
    const res = try resolveLayer(a, .gitconfig, &layers, change);
    try testing.expectEqual(@as(usize, 1), res.target);
    try testing.expectEqual(@as(usize, 2), res.definers.len);
}

test "formatOfPath: recognizes structured formats and rejects others" {
    try testing.expectEqual(Format.toml, formatOfPath("src/config.toml").?);
    try testing.expectEqual(Format.json, formatOfPath("src/settings.json").?);
    try testing.expectEqual(Format.yaml, formatOfPath("src/c.yaml").?);
    try testing.expectEqual(Format.ini, formatOfPath("src/app.ini").?);
    try testing.expectEqual(Format.gitconfig, formatOfPath("src/.gitconfig").?);
    try testing.expect(formatOfPath("src/.zshrc") == null);
}

test "displayAt: renders the leaf scalar, or null when absent" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    try testing.expectEqualStrings("dark", (try displayAt(a, .toml, "theme = \"dark\"\nn = 3\n", &.{"theme"})).?);
    try testing.expectEqualStrings("3", (try displayAt(a, .toml, "theme = \"dark\"\nn = 3\n", &.{"n"})).?);
    try testing.expect((try displayAt(a, .toml, "theme = \"dark\"\n", &.{"missing"})) == null);
    try testing.expectEqualStrings("picked", (try displayAt(a, .gitconfig, "[user]\n\tname = picked\n", &.{ "user", "name" })).?);
}
