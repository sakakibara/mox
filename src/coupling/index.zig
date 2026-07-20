const std = @import("std");
const tokens_mod = @import("tokens.zig");
const graph_mod = @import("graph.zig");

pub const FileInput = struct {
    id: []const u8,
    content: []const u8,
};

pub const FILE_SIZE_CAP: usize = 1024 * 1024; // 1 MB
pub const UNIVERSALITY_LIMIT: f32 = 0.5;
pub const COOCCURRENCE_MIN: usize = 2;

/// Build a coupling graph from a list of files. Tokens are filtered to
/// those appearing in at least COOCCURRENCE_MIN files and at most
/// UNIVERSALITY_LIMIT of all files.
pub fn build(arena: std.mem.Allocator, inputs: []const FileInput) !graph_mod.Graph {
    var g = graph_mod.Graph.init(arena);

    for (inputs) |input| {
        if (input.content.len > FILE_SIZE_CAP) continue;
        const toks = try tokens_mod.extract(arena, input.content);
        for (toks) |tok| {
            const off = @intFromPtr(tok.ptr) - @intFromPtr(input.content.ptr);
            try g.addOccurrence(tok, input.id, @intCast(off), @intCast(tok.len));
        }
    }

    if (inputs.len == 0) return g;

    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(arena);

    // Universality filter only kicks in once there are enough files for it
    // to represent a meaningful distinction beyond co-occurrence. With 2-3
    // files, a co-occurring token would be unfairly classified as
    // "universal" by a 0.5 ratio. Require enough files that exceeding the
    // ratio means strictly more than COOCCURRENCE_MIN files share the
    // token: with UNIVERSALITY_LIMIT=0.5 and COOCCURRENCE_MIN=2, that is 4.
    const apply_universality = inputs.len >= 4;

    var iter = g.map.iterator();
    while (iter.next()) |entry| {
        const tok = entry.key_ptr.*;
        const file_count = g.fileCountForToken(tok);
        if (file_count < COOCCURRENCE_MIN) {
            try to_remove.append(arena, tok);
            continue;
        }
        if (apply_universality) {
            const ratio = @as(f32, @floatFromInt(file_count)) / @as(f32, @floatFromInt(inputs.len));
            if (ratio > UNIVERSALITY_LIMIT) {
                try to_remove.append(arena, tok);
                continue;
            }
        }
    }

    for (to_remove.items) |tok| {
        _ = g.map.remove(tok);
    }

    return g;
}

test "build: 2 files sharing email" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const inputs = [_]FileInput{
        .{ .id = "a", .content = "email = ada@example.com" },
        .{ .id = "b", .content = "ada@example.com namespaces=git" },
    };
    var g = try build(arena.allocator(), &inputs);
    try std.testing.expect(g.lookup("ada@example.com") != null);
}

test "build: singleton excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const inputs = [_]FileInput{
        .{ .id = "a", .content = "uniquetoken12345" },
        .{ .id = "b", .content = "completelydifferent here" },
    };
    var g = try build(arena.allocator(), &inputs);
    try std.testing.expect(g.lookup("uniquetoken12345") == null);
}
