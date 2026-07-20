const std = @import("std");

/// Per-apply cache mapping URI strings to resolved plaintext values.
/// Backed by an arena allocator: keys and values are duped on insert and
/// freed wholesale when the arena is reset.
pub const Cache = struct {
    arena: std.mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(arena: std.mem.Allocator) Cache {
        return .{
            .arena = arena,
            .map = std.StringHashMap([]const u8).init(arena),
        };
    }

    pub fn put(self: *Cache, uri_str: []const u8, value: []const u8) !void {
        const owned_key = try self.arena.dupe(u8, uri_str);
        const owned_val = try self.arena.dupe(u8, value);
        try self.map.put(owned_key, owned_val);
    }

    pub fn get(self: *const Cache, uri_str: []const u8) ?[]const u8 {
        return self.map.get(uri_str);
    }
};

test "Cache: put then get" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var c = Cache.init(arena.allocator());
    try c.put("op://x", "secret-value");
    const got = c.get("op://x");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("secret-value", got.?);
}

test "Cache: missing returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = Cache.init(arena.allocator());
    try std.testing.expect(c.get("nope") == null);
}
