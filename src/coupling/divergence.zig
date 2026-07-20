const std = @import("std");
const index_mod = @import("index.zig");
const decline_mod = @import("decline.zig");

pub const FileSnapshot = struct {
    id: []const u8,
    content: []const u8,
};

/// A coupled token that changed in some files but persisted in others.
pub const Divergence = struct {
    token: []const u8,
    files_changed: []const []const u8,
    files_unchanged: []const []const u8,
};

/// Detect coupling divergences: tokens present in `before` across multiple
/// files where the after-snapshot still contains the token in some files
/// but not others. The returned slice is arena-allocated.
pub fn detect(
    arena: std.mem.Allocator,
    before: []const FileSnapshot,
    after: []const FileSnapshot,
    decline_opt: ?*const decline_mod.DeclineList,
) ![]const Divergence {
    var inputs: std.ArrayList(index_mod.FileInput) = .empty;
    defer inputs.deinit(arena);
    for (before) |s| {
        try inputs.append(arena, .{ .id = s.id, .content = s.content });
    }
    var graph = try index_mod.build(arena, inputs.items);

    var after_map = std.StringHashMap([]const u8).init(arena);
    defer after_map.deinit();
    for (after) |s| try after_map.put(s.id, s.content);

    var result: std.ArrayList(Divergence) = .empty;
    errdefer result.deinit(arena);

    var iter = graph.map.iterator();
    while (iter.next()) |entry| {
        const token = entry.key_ptr.*;

        // Files where the token appears as a substring in the before
        // snapshot. Includes files where the tokenizer didn't extract this
        // exact token (e.g., embedded in a longer token like `K=value`)
        // but the value is still present in the file.
        var files_seen = std.StringHashMap(void).init(arena);
        defer files_seen.deinit();
        for (before) |s| {
            if (std.mem.indexOf(u8, s.content, token) != null) {
                try files_seen.put(s.id, {});
            }
        }

        var files_changed: std.ArrayList([]const u8) = .empty;
        var files_unchanged: std.ArrayList([]const u8) = .empty;

        var file_iter = files_seen.keyIterator();
        while (file_iter.next()) |fid_ptr| {
            const fid = fid_ptr.*;
            const after_content = after_map.get(fid) orelse continue;
            if (std.mem.indexOf(u8, after_content, token) != null) {
                try files_unchanged.append(arena, fid);
            } else {
                try files_changed.append(arena, fid);
            }
        }

        if (files_changed.items.len == 0 or files_unchanged.items.len == 0) continue;

        if (decline_opt) |d| {
            var any_active = false;
            outer: for (files_changed.items) |a| {
                for (files_unchanged.items) |b| {
                    if (!d.isPairDeclined(token, a, b)) {
                        any_active = true;
                        break :outer;
                    }
                }
            }
            if (!any_active) continue;
        }

        try result.append(arena, .{
            .token = token,
            .files_changed = try files_changed.toOwnedSlice(arena),
            .files_unchanged = try files_unchanged.toOwnedSlice(arena),
        });
    }

    return try result.toOwnedSlice(arena);
}

test "detect: divergence flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = [_]FileSnapshot{
        .{ .id = "src/a", .content = "old@example.com" },
        .{ .id = "src/b", .content = "old@example.com" },
    };
    const after = [_]FileSnapshot{
        .{ .id = "src/a", .content = "new@example.com" },
        .{ .id = "src/b", .content = "old@example.com" },
    };
    const divs = try detect(arena.allocator(), &before, &after, null);
    try std.testing.expectEqual(@as(usize, 1), divs.len);
}

test "detect: coherent change not flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const before = [_]FileSnapshot{
        .{ .id = "src/a", .content = "old@example.com" },
        .{ .id = "src/b", .content = "old@example.com" },
    };
    const after = [_]FileSnapshot{
        .{ .id = "src/a", .content = "new@example.com" },
        .{ .id = "src/b", .content = "new@example.com" },
    };
    const divs = try detect(arena.allocator(), &before, &after, null);
    try std.testing.expectEqual(@as(usize, 0), divs.len);
}
