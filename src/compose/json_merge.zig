//! Deep-merge two JSON values for the Cat A composer.
//!
//! Both inputs must be objects. For each key in either object:
//! - If both have the key and both values are objects, recurse.
//! - Otherwise, the overlay's value wins.
//!
//! Arrays are replaced (not concatenated). This matches JSON Patch
//! semantics and is the most predictable behavior for users; consumers
//! who want concatenation can structure their overlay tree differently.
//!
//! Input layers are parsed as JSONC (comments and trailing commas
//! accepted); output is always plain JSON.
//!
//! All output (keys, object maps, array items) is allocated on `arena`.
//! String payloads are reused by reference (not duped) -- they remain
//! valid for the same lifetime as the input arenas.

const std = @import("std");
const json = @import("json");

pub const MergeError = error{
    NotAnObject,
    OutOfMemory,
};

/// Deep-merge `overlay` onto `base`. Both must be objects. Returns a new
/// `json.Value` (also an object) allocated on `arena`.
pub fn deepMerge(arena: std.mem.Allocator, base: json.Value, overlay: json.Value) MergeError!json.Value {
    if (base != .object or overlay != .object) return error.NotAnObject;

    var result: json.ObjectMap = .empty;

    // Iterate base in insertion order; for each key, either keep, override, or merge.
    var base_iter = base.object.iterator();
    while (base_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const base_v = entry.value_ptr.*;

        if (overlay.object.get(key)) |overlay_v| {
            if (base_v == .object and overlay_v == .object) {
                const merged = try deepMerge(arena, base_v, overlay_v);
                try result.put(arena, key, merged);
            } else {
                try result.put(arena, key, overlay_v);
            }
        } else {
            try result.put(arena, key, base_v);
        }
    }

    // Append overlay-only keys, preserving overlay's insertion order.
    var overlay_iter = overlay.object.iterator();
    while (overlay_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (base.object.contains(key)) continue;
        try result.put(arena, key, entry.value_ptr.*);
    }

    return .{ .object = result };
}

// ---- tests ----

test "json merge: objects recurse, arrays and scalars replace" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = try json.parse(a, "{\"user\":{\"name\":\"foo\",\"age\":30},\"shells\":[\"zsh\"]}", .{ .dialect = .jsonc });
    const overlay = try json.parse(a, "{\"user\":{\"name\":\"bar\"},\"shells\":[\"fish\"]}", .{ .dialect = .jsonc });
    const merged = try deepMerge(a, base, overlay);
    try std.testing.expectEqualStrings("bar", merged.getT([]const u8, "user.name").?);
    try std.testing.expectEqual(@as(i64, 30), merged.getT(i64, "user.age").?);
    try std.testing.expectEqualStrings("fish", merged.getT([]const u8, "shells[0]").?);
}

test "json merge: scalar override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try json.parse(a, "{\"name\":\"base\",\"version\":1}", .{ .dialect = .jsonc });
    const overlay = try json.parse(a, "{\"name\":\"overlay\"}", .{ .dialect = .jsonc });
    const merged = try deepMerge(a, base, overlay);

    try std.testing.expectEqualStrings("overlay", merged.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 1), merged.object.get("version").?.integer);
}

test "json merge: array replace (not concat)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try json.parse(a, "{\"shells\":[\"zsh\"]}", .{ .dialect = .jsonc });
    const overlay = try json.parse(a, "{\"shells\":[\"fish\",\"bash\"]}", .{ .dialect = .jsonc });
    const merged = try deepMerge(a, base, overlay);

    const arr = merged.object.get("shells").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("fish", arr[0].string);
}

test "json merge: overlay-only keys appended after base keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try json.parse(a, "{\"x\":1}", .{ .dialect = .jsonc });
    const overlay = try json.parse(a, "{\"y\":2}", .{ .dialect = .jsonc });
    const merged = try deepMerge(a, base, overlay);

    try std.testing.expectEqual(@as(i64, 1), merged.object.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 2), merged.object.get("y").?.integer);
    const keys = merged.object.keys();
    try std.testing.expectEqualStrings("x", keys[0]);
    try std.testing.expectEqualStrings("y", keys[1]);
}

test "json merge: type mismatch (object base + scalar overlay) -> overlay wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try json.parse(a, "{\"settings\":{\"foo\":1}}", .{ .dialect = .jsonc });
    const overlay = try json.parse(a, "{\"settings\":\"disabled\"}", .{ .dialect = .jsonc });
    const merged = try deepMerge(a, base, overlay);

    try std.testing.expectEqualStrings("disabled", merged.object.get("settings").?.string);
}

test "json merge: errors on non-object inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = json.Value{ .integer = 1 };
    const overlay = try json.parse(a, "{\"x\":2}", .{ .dialect = .jsonc });
    try std.testing.expectError(error.NotAnObject, deepMerge(a, base, overlay));
}

test "json merge: jsonc input (comments + trailing commas) parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try json.parse(a,
        \\{
        \\  // base editor settings
        \\  "editor": {
        \\    "tabSize": 4, /* spaces */
        \\  },
        \\}
    , .{ .dialect = .jsonc });
    const overlay = try json.parse(a,
        \\{
        \\  "editor": { "tabSize": 2, },
        \\}
    , .{ .dialect = .jsonc });
    const merged = try deepMerge(a, base, overlay);

    try std.testing.expectEqual(@as(i64, 2), merged.getT(i64, "editor.tabSize").?);
}

test "json merge: multi-overlay folds left to right (later overlay wins)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try json.parse(a, "{\"a\":1,\"b\":1,\"c\":1}", .{ .dialect = .jsonc });
    const overlay1 = try json.parse(a, "{\"b\":2,\"c\":2}", .{ .dialect = .jsonc });
    const overlay2 = try json.parse(a, "{\"c\":3}", .{ .dialect = .jsonc });

    var merged = try deepMerge(a, base, overlay1);
    merged = try deepMerge(a, merged, overlay2);

    try std.testing.expectEqual(@as(i64, 1), merged.getT(i64, "a").?);
    try std.testing.expectEqual(@as(i64, 2), merged.getT(i64, "b").?);
    try std.testing.expectEqual(@as(i64, 3), merged.getT(i64, "c").?);
}

test "json merge: exact pretty-printed emit (2-space indent)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try json.parse(a,
        \\{
        \\  // overridden by overlay
        \\  "user": { "name": "foo", "age": 30 },
        \\  "shells": ["zsh"],
        \\}
    , .{ .dialect = .jsonc });
    const overlay = try json.parse(a, "{\"user\":{\"name\":\"bar\"}}", .{ .dialect = .jsonc });
    const merged = try deepMerge(a, base, overlay);

    var aw: std.Io.Writer.Allocating = .init(a);
    try json.encode(&aw.writer, merged, .{ .indent = 2 });

    const expected =
        \\{
        \\  "user": {
        \\    "name": "bar",
        \\    "age": 30
        \\  },
        \\  "shells": [
        \\    "zsh"
        \\  ]
        \\}
    ;
    try std.testing.expectEqualStrings(expected, aw.written());
}
