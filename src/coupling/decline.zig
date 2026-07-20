const std = @import("std");

/// Records user-declined coupling tokens, either globally (a token never
/// signals a coupling regardless of file pair) or for specific file pairs.
pub const DeclineList = struct {
    arena: std.mem.Allocator,
    global: std.StringHashMap(void),
    pairs: std.StringHashMap(void),

    pub fn init(arena: std.mem.Allocator) DeclineList {
        return .{
            .arena = arena,
            .global = std.StringHashMap(void).init(arena),
            .pairs = std.StringHashMap(void).init(arena),
        };
    }

    pub fn declineGlobal(self: *DeclineList, token: []const u8) !void {
        const owned = try self.arena.dupe(u8, token);
        try self.global.put(owned, {});
    }

    pub fn declinePair(self: *DeclineList, token: []const u8, file_a: []const u8, file_b: []const u8) !void {
        const key = try makePairKey(self.arena, token, file_a, file_b);
        try self.pairs.put(key, {});
    }

    pub fn isPairDeclined(self: *const DeclineList, token: []const u8, file_a: []const u8, file_b: []const u8) bool {
        if (self.global.contains(token)) return true;
        var key_buf: [4096]u8 = undefined;
        const key = formatPairKey(&key_buf, token, file_a, file_b) catch return false;
        return self.pairs.contains(key);
    }
};

/// Self-delimiting pair-key encoding: each field is prefixed with its byte
/// length (`<len>:<bytes>`), so the concatenation is injective even when a
/// token or path contains the `:` / `|` separators. A plain `{token}|{lo}|{hi}`
/// join is NOT injective -- `|` is a valid token character -- and would let one
/// decline suppress an unrelated (token, file-pair).
fn writePairKey(w: *std.Io.Writer, token: []const u8, file_a: []const u8, file_b: []const u8) !void {
    const lo = if (std.mem.lessThan(u8, file_a, file_b)) file_a else file_b;
    const hi = if (std.mem.lessThan(u8, file_a, file_b)) file_b else file_a;
    try w.print("{d}:{s}|{d}:{s}|{d}:{s}", .{ token.len, token, lo.len, lo, hi.len, hi });
}

fn makePairKey(arena: std.mem.Allocator, token: []const u8, file_a: []const u8, file_b: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writePairKey(&aw.writer, token, file_a, file_b);
    return aw.toOwnedSlice();
}

fn formatPairKey(buf: []u8, token: []const u8, file_a: []const u8, file_b: []const u8) ![]u8 {
    var w = std.Io.Writer.fixed(buf);
    try writePairKey(&w, token, file_a, file_b);
    return w.buffered();
}

test "DeclineList: per-pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = DeclineList.init(arena.allocator());
    try d.declinePair("token12345", "src/a", "src/b");
    try std.testing.expect(d.isPairDeclined("token12345", "src/a", "src/b"));
    try std.testing.expect(d.isPairDeclined("token12345", "src/b", "src/a"));
    try std.testing.expect(!d.isPairDeclined("token12345", "src/a", "src/c"));
}

test "DeclineList: a '|' in a token does not collide across pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = DeclineList.init(arena.allocator());
    // `|` is a valid token character (tokens.zig isTokenChar), so a token may
    // contain it. The pair key must stay injective: declining one (token, pair)
    // must never suppress a DIFFERENT (token, pair) that happens to concatenate
    // to the same bytes under a naive "{token}|{lo}|{hi}" encoding.
    try d.declinePair("tok", "aaa|bbb", "ccc");
    try std.testing.expect(d.isPairDeclined("tok", "aaa|bbb", "ccc"));
    // Different triple, same naive concatenation "tok|aaa|bbb|ccc":
    try std.testing.expect(!d.isPairDeclined("tok|aaa", "bbb", "ccc"));
}

test "DeclineList: global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = DeclineList.init(arena.allocator());
    try d.declineGlobal("noisytoken");
    try std.testing.expect(d.isPairDeclined("noisytoken", "src/x", "src/y"));
    try std.testing.expect(d.isPairDeclined("noisytoken", "src/p", "src/q"));
}
