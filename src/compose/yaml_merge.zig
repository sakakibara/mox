//! Deep-merge two YAML values for the Cat A composer.
//!
//! Both inputs must be mappings. For each key in either mapping:
//! - If both have the key and both values are mappings, recurse.
//! - Otherwise, the overlay's value wins.
//!
//! Sequences are replaced (not concatenated). This matches the JSON
//! composer's semantics and is the most predictable behavior for users;
//! consumers who want concatenation can structure their overlay tree
//! differently.
//!
//! A YAML mapping is an ordered slice of key/value `Entry` pairs (keys may
//! be any node, not just strings), so the merge walks and rebuilds entry
//! lists rather than a hashmap. Entries are matched by their `.string`
//! key; non-string-keyed entries are carried through from the base and
//! never matched by an overlay.
//!
//! All output (entry lists, sequence items) is allocated on `arena`.
//! String payloads are reused by reference (not duped) -- they remain
//! valid for the same lifetime as the input arenas.

const std = @import("std");
const yaml = @import("yaml");

pub const MergeError = error{
    NotAMapping,
    OutOfMemory,
};

/// Deep-merge `overlay` onto `base`. Both must be mappings. Returns a new
/// `yaml.Value` (also a mapping) allocated on `arena`.
pub fn deepMerge(arena: std.mem.Allocator, base: yaml.Value, overlay: yaml.Value) MergeError!yaml.Value {
    if (base != .map or overlay != .map) return error.NotAMapping;

    var result: std.ArrayList(yaml.Entry) = .empty;

    // Iterate base in insertion order; for each entry, either keep,
    // override, or merge against the overlay's same-key entry.
    for (base.map) |base_entry| {
        const key = entryKey(base_entry) orelse {
            // Non-string key: not addressable by the overlay, carry as-is.
            try result.append(arena, base_entry);
            continue;
        };

        if (mapGet(overlay.map, key)) |overlay_v| {
            const base_v = base_entry.value;
            if (base_v == .map and overlay_v == .map) {
                const merged = try deepMerge(arena, base_v, overlay_v);
                try result.append(arena, .{ .key = base_entry.key, .value = merged });
            } else {
                try result.append(arena, .{ .key = base_entry.key, .value = overlay_v });
            }
        } else {
            try result.append(arena, base_entry);
        }
    }

    // Append overlay-only keys, preserving overlay's insertion order.
    for (overlay.map) |overlay_entry| {
        const key = entryKey(overlay_entry) orelse {
            try result.append(arena, overlay_entry);
            continue;
        };
        if (mapGet(base.map, key) != null) continue;
        try result.append(arena, overlay_entry);
    }

    return .{ .map = try result.toOwnedSlice(arena) };
}

/// The string key of an entry, or null if the entry is keyed by a
/// non-scalar (seq/map) or non-string scalar. Mirrors how `Value.get`
/// only matches `.string` keys.
fn entryKey(e: yaml.Entry) ?[]const u8 {
    return if (e.key == .string) e.key.string else null;
}

/// First entry in `entries` whose key is a `.string` equal to `k`.
fn mapGet(entries: []const yaml.Entry, k: []const u8) ?yaml.Value {
    for (entries) |e| {
        if (e.key == .string and std.mem.eql(u8, e.key.string, k)) return e.value;
    }
    return null;
}

// ---- tests ----

test "yaml merge: mappings recurse, sequences and scalars replace" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = try yaml.parse(a, "user:\n  name: foo\n  age: 30\nshells:\n  - zsh\n", .{});
    const overlay = try yaml.parse(a, "user:\n  name: bar\nshells:\n  - fish\n", .{});
    const merged = try deepMerge(a, base, overlay);
    try std.testing.expectEqualStrings("bar", merged.getT([]const u8, "user.name").?);
    try std.testing.expectEqual(@as(i64, 30), merged.getT(i64, "user.age").?);
    try std.testing.expectEqualStrings("fish", merged.getT([]const u8, "shells[0]").?);
}

test "yaml merge: scalar override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try yaml.parse(a, "name: base\nversion: 1\n", .{});
    const overlay = try yaml.parse(a, "name: overlay\n", .{});
    const merged = try deepMerge(a, base, overlay);

    try std.testing.expectEqualStrings("overlay", merged.getT([]const u8, "name").?);
    try std.testing.expectEqual(@as(i64, 1), merged.getT(i64, "version").?);
}

test "yaml merge: sequence replace (not concat)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try yaml.parse(a, "shells:\n  - zsh\n", .{});
    const overlay = try yaml.parse(a, "shells:\n  - fish\n  - bash\n", .{});
    const merged = try deepMerge(a, base, overlay);

    const seq = merged.get("shells").?.seq;
    try std.testing.expectEqual(@as(usize, 2), seq.len);
    try std.testing.expectEqualStrings("fish", seq[0].string);
}

test "yaml merge: overlay-only keys appended after base keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try yaml.parse(a, "x: 1\n", .{});
    const overlay = try yaml.parse(a, "y: 2\n", .{});
    const merged = try deepMerge(a, base, overlay);

    try std.testing.expectEqual(@as(i64, 1), merged.getT(i64, "x").?);
    try std.testing.expectEqual(@as(i64, 2), merged.getT(i64, "y").?);
    try std.testing.expectEqualStrings("x", merged.map[0].key.string);
    try std.testing.expectEqualStrings("y", merged.map[1].key.string);
}

test "yaml merge: type mismatch (mapping base + scalar overlay) -> overlay wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try yaml.parse(a, "settings:\n  foo: 1\n", .{});
    const overlay = try yaml.parse(a, "settings: disabled\n", .{});
    const merged = try deepMerge(a, base, overlay);

    try std.testing.expectEqualStrings("disabled", merged.getT([]const u8, "settings").?);
}

test "yaml merge: errors on non-mapping inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = yaml.Value{ .int = 1 };
    const overlay = try yaml.parse(a, "x: 2\n", .{});
    try std.testing.expectError(error.NotAMapping, deepMerge(a, base, overlay));
}

test "yaml merge: multi-overlay folds left to right (later overlay wins)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try yaml.parse(a, "a: 1\nb: 1\nc: 1\n", .{});
    const overlay1 = try yaml.parse(a, "b: 2\nc: 2\n", .{});
    const overlay2 = try yaml.parse(a, "c: 3\n", .{});

    var merged = try deepMerge(a, base, overlay1);
    merged = try deepMerge(a, merged, overlay2);

    try std.testing.expectEqual(@as(i64, 1), merged.getT(i64, "a").?);
    try std.testing.expectEqual(@as(i64, 2), merged.getT(i64, "b").?);
    try std.testing.expectEqual(@as(i64, 3), merged.getT(i64, "c").?);
}

test "yaml merge: exact block-style emit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try yaml.parse(a, "user:\n  name: foo\n  age: 30\nshells:\n  - zsh\n", .{});
    const overlay = try yaml.parse(a, "user:\n  name: bar\n", .{});
    const merged = try deepMerge(a, base, overlay);

    var aw: std.Io.Writer.Allocating = .init(a);
    try yaml.emit(&aw.writer, merged, .{});

    const expected =
        \\user:
        \\  name: bar
        \\  age: 30
        \\shells:
        \\  - zsh
        \\
    ;
    try std.testing.expectEqualStrings(expected, aw.written());
}
