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
        if (mapGetYaml(composed.map, key)) |cv| {
            try diffYamlValue(arena, path, entry.value, cv, out);
        } else {
            try out.append(arena, .{ .path = path, .new = null, .removed = true });
        }
    }
    for (composed.map) |entry| {
        const key = entryKeyYaml(entry) orelse continue;
        if (mapGetYaml(live.map, key) != null) continue;
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

fn mapGetYaml(entries: []const yaml.Entry, k: []const u8) ?yaml.Value {
    for (entries) |e| {
        if (e.key == .string and std.mem.eql(u8, e.key.string, k)) return e.value;
    }
    return null;
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
