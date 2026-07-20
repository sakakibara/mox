const std = @import("std");

/// A data value read from a TOML data source. Storage is arena-allocated
/// by the reader; copy if you need to outlive the arena.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
    array_of_strings: []const []const u8,

    /// Format the value as its string representation. Returns arena-owned
    /// bytes. Strings are emitted as-is (NOT quoted); ints in base-10;
    /// bools as "true" / "false"; string arrays as comma-joined.
    pub fn format(self: Value, arena: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .string => |s| try arena.dupe(u8, s),
            .int => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
            .bool => |b| try arena.dupe(u8, if (b) "true" else "false"),
            .array_of_strings => |arr| blk: {
                var total: usize = 0;
                for (arr, 0..) |s, i| total += s.len + (if (i > 0) @as(usize, 1) else 0);
                var buf = try arena.alloc(u8, total);
                var pos: usize = 0;
                for (arr, 0..) |s, i| {
                    if (i > 0) {
                        buf[pos] = ',';
                        pos += 1;
                    }
                    @memcpy(buf[pos .. pos + s.len], s);
                    pos += s.len;
                }
                break :blk buf;
            },
        };
    }

    /// Treat this value as a "set" for membership tests. String values are
    /// a singleton set; arrays are the set of their elements; ints and
    /// bools format-and-singleton. Returns true when `needle` is in the set.
    pub fn contains(self: Value, needle: []const u8) bool {
        return switch (self) {
            .string => |s| std.mem.eql(u8, s, needle),
            .array_of_strings => |arr| {
                for (arr) |s| if (std.mem.eql(u8, s, needle)) return true;
                return false;
            },
            .int => |i| blk: {
                var buf: [32]u8 = undefined;
                const formatted = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break :blk false;
                break :blk std.mem.eql(u8, formatted, needle);
            },
            .bool => |b| std.mem.eql(u8, if (b) "true" else "false", needle),
        };
    }

    /// True when the value carries no meaningful content: empty string or
    /// empty array. Used by per-row predicates that treat absent / empty as
    /// "field unset".
    pub fn isEmpty(self: Value) bool {
        return switch (self) {
            .string => |s| s.len == 0,
            .array_of_strings => |arr| arr.len == 0,
            .int, .bool => false,
        };
    }
};

test "Value: string" {
    const v = Value{ .string = "hello" };
    try std.testing.expect(v == .string);
}

test "Value: int" {
    const v = Value{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

test "Value: format string" {
    var allocator_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const v = Value{ .string = "foo" };
    const s = try v.format(fba.allocator());
    try std.testing.expectEqualStrings("foo", s);
}

test "Value: format int" {
    var allocator_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const v = Value{ .int = -123 };
    const s = try v.format(fba.allocator());
    try std.testing.expectEqualStrings("-123", s);
}

test "Value: format bool" {
    var allocator_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const v_true = Value{ .bool = true };
    const v_false = Value{ .bool = false };
    try std.testing.expectEqualStrings("true", try v_true.format(fba.allocator()));
    try std.testing.expectEqualStrings("false", try v_false.format(fba.allocator()));
}
