const std = @import("std");

pub const Occurrence = struct {
    file_id: []const u8,
    byte_offset: u64,
    length: u32,
};

pub const Graph = struct {
    arena: std.mem.Allocator,
    map: std.StringHashMap(std.ArrayList(Occurrence)),

    pub fn init(arena: std.mem.Allocator) Graph {
        return .{
            .arena = arena,
            .map = std.StringHashMap(std.ArrayList(Occurrence)).init(arena),
        };
    }

    pub fn addOccurrence(self: *Graph, token: []const u8, file_id: []const u8, byte_offset: u64, length: u32) !void {
        const occ = Occurrence{
            .file_id = try self.arena.dupe(u8, file_id),
            .byte_offset = byte_offset,
            .length = length,
        };
        if (self.map.getPtr(token)) |list_ptr| {
            try list_ptr.append(self.arena, occ);
            return;
        }
        const owned_key = try self.arena.dupe(u8, token);
        var new_list: std.ArrayList(Occurrence) = .empty;
        try new_list.append(self.arena, occ);
        try self.map.put(owned_key, new_list);
    }

    pub fn lookup(self: *const Graph, token: []const u8) ?[]const Occurrence {
        const list = self.map.get(token) orelse return null;
        return list.items;
    }

    /// Count distinct files containing this token.
    pub fn fileCountForToken(self: *const Graph, token: []const u8) usize {
        const occs = self.lookup(token) orelse return 0;
        var seen: std.StringHashMap(void) = std.StringHashMap(void).init(self.arena);
        defer seen.deinit();
        var count: usize = 0;
        for (occs) |o| {
            const gop = seen.getOrPut(o.file_id) catch return 0;
            if (!gop.found_existing) count += 1;
        }
        return count;
    }

    /// Total distinct files referenced by any token.
    pub fn totalFiles(self: *const Graph) usize {
        var seen: std.StringHashMap(void) = std.StringHashMap(void).init(self.arena);
        defer seen.deinit();
        var iter = self.map.valueIterator();
        while (iter.next()) |list_ptr| {
            for (list_ptr.items) |o| {
                _ = seen.getOrPut(o.file_id) catch continue;
            }
        }
        return seen.count();
    }
};

test "Graph: add and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    try g.addOccurrence("hello-world-token", "src/a", 0, 17);
    try g.addOccurrence("hello-world-token", "src/b", 100, 17);
    const occs = g.lookup("hello-world-token").?;
    try std.testing.expectEqual(@as(usize, 2), occs.len);
}

test "Graph: lookup missing returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    try std.testing.expect(g.lookup("nonexistent") == null);
}

test "Graph: file count for token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    try g.addOccurrence("token1234", "src/a", 0, 9);
    try g.addOccurrence("token1234", "src/a", 50, 9);
    try g.addOccurrence("token1234", "src/b", 0, 9);
    try std.testing.expectEqual(@as(usize, 2), g.fileCountForToken("token1234"));
}
