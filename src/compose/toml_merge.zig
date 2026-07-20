//! Deep-merge two TOML values for the Cat A composer.
//!
//! Both inputs must be tables. For each key in either table:
//! - If both have the key and both values are tables, recurse.
//! - Otherwise, the overlay's value wins.
//!
//! Arrays are replaced (not concatenated). This matches JSON Patch
//! semantics and is the most predictable behavior for users; consumers
//! who want concatenation can structure their overlay tree differently.
//!
//! All output (keys, table maps, array items) is allocated on `arena`.
//! String payloads are reused by reference (not duped) — they remain
//! valid for the same lifetime as the input arenas.

const std = @import("std");
const toml = @import("toml");

pub const MergeError = error{
    NotATable,
    OutOfMemory,
};

/// Deep-merge `overlay` onto `base`. Both must be tables. Returns a new
/// `toml.Value` (also a table) allocated on `arena`.
pub fn mergeTables(arena: std.mem.Allocator, base: toml.Value, overlay: toml.Value) MergeError!toml.Value {
    if (base != .table or overlay != .table) return error.NotATable;

    var result: std.array_hash_map.String(toml.Value) = .empty;

    // Iterate base in insertion order; for each key, either keep, override, or merge.
    var base_iter = base.table.iterator();
    while (base_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const base_v = entry.value_ptr.*;

        if (overlay.table.get(key)) |overlay_v| {
            if (base_v == .table and overlay_v == .table) {
                const merged = try mergeTables(arena, base_v, overlay_v);
                try result.put(arena, key, merged);
            } else {
                try result.put(arena, key, overlay_v);
            }
        } else {
            try result.put(arena, key, base_v);
        }
    }

    // Append overlay-only keys, preserving overlay's insertion order.
    var overlay_iter = overlay.table.iterator();
    while (overlay_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (base.table.contains(key)) continue;
        try result.put(arena, key, entry.value_ptr.*);
    }

    return .{ .table = result };
}

// ---- tests ----

test "merge: scalar override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try toml.parse(a, "name = \"base\"\nversion = 1\n", .{});
    const overlay = try toml.parse(a, "name = \"overlay\"\n", .{});
    const merged = try mergeTables(a, base, overlay);

    try std.testing.expectEqualStrings("overlay", merged.table.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 1), merged.table.get("version").?.integer);
}

test "merge: nested table merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try toml.parse(a, "[user]\nname = \"foo\"\nage = 30\n", .{});
    const overlay = try toml.parse(a, "[user]\nname = \"bar\"\n", .{});
    const merged = try mergeTables(a, base, overlay);

    const user = merged.table.get("user").?.table;
    try std.testing.expectEqualStrings("bar", user.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 30), user.get("age").?.integer);
}

test "merge: array replace (not concat)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try toml.parse(a, "shells = [\"zsh\"]\n", .{});
    const overlay = try toml.parse(a, "shells = [\"fish\", \"bash\"]\n", .{});
    const merged = try mergeTables(a, base, overlay);

    const arr = merged.table.get("shells").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("fish", arr.items[0].string);
}

test "merge: overlay-only keys appended" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try toml.parse(a, "x = 1\n", .{});
    const overlay = try toml.parse(a, "y = 2\n", .{});
    const merged = try mergeTables(a, base, overlay);

    try std.testing.expectEqual(@as(i64, 1), merged.table.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 2), merged.table.get("y").?.integer);
}

test "merge: type mismatch (table base + scalar overlay) -> overlay wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try toml.parse(a, "[settings]\nfoo = 1\n", .{});
    const overlay = try toml.parse(a, "settings = \"disabled\"\n", .{});
    const merged = try mergeTables(a, base, overlay);

    try std.testing.expectEqualStrings("disabled", merged.table.get("settings").?.string);
}

test "merge: errors on non-table inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = toml.Value{ .integer = 1 };
    const overlay = try toml.parse(a, "x = 2\n", .{});
    try std.testing.expectError(error.NotATable, mergeTables(a, base, overlay));
}
