const std = @import("std");
const source = @import("../source/root.zig");

const ManagedTree = source.tree.ManagedTree;
const ManagedFile = source.tree.ManagedFile;
const Overlay = source.tree.Overlay;
const Region = source.tree.Region;

/// Merge private overlays from `private_dir` into `base_tree`. Returns a new
/// tree where each ManagedFile has its overlays/regions extended with private
/// entries. Files that exist only in the private layer are added as
/// has_base=false entries.
///
/// If `private_dir` doesn't exist, returns `base_tree` unchanged.
pub fn merge(
    arena: std.mem.Allocator,
    io: std.Io,
    base_tree: ManagedTree,
    private_dir: []const u8,
    home_dir: []const u8,
) !ManagedTree {
    std.Io.Dir.cwd().access(io, private_dir, .{}) catch |e| switch (e) {
        error.FileNotFound => return base_tree,
        else => return e,
    };

    const private_tree = try source.tree.walk(arena, io, private_dir, home_dir);

    var base_map = std.StringHashMap(ManagedFile).init(arena);
    defer base_map.deinit();
    for (base_tree.files) |f| try base_map.put(f.source_base_path, f);

    var merged: std.ArrayList(ManagedFile) = .empty;
    errdefer merged.deinit(arena);

    var seen_in_private = std.StringHashMap(void).init(arena);
    defer seen_in_private.deinit();

    for (private_tree.files) |pf| {
        const key = pf.source_base_path;
        try seen_in_private.put(key, {});

        if (base_map.get(key)) |base_file| {
            var combined = base_file;
            combined.overlays = try concatOverlays(arena, base_file.overlays, pf.overlays);
            combined.regions = try concatRegions(arena, base_file.regions, pf.regions);
            try merged.append(arena, combined);
        } else {
            try merged.append(arena, pf);
        }
    }

    for (base_tree.files) |bf| {
        if (seen_in_private.contains(bf.source_base_path)) continue;
        try merged.append(arena, bf);
    }

    // Every merged file learns the private root so repo-relative loop data
    // sources resolve there before the repo (private shadows repo).
    const out = try merged.toOwnedSlice(arena);
    for (out) |*f| f.private_dir = private_dir;

    // Exact markers from either layer apply to the merged live tree.
    var exact: std.ArrayList([]const u8) = .empty;
    errdefer exact.deinit(arena);
    for (base_tree.exact_dirs) |d| try exact.append(arena, d);
    for (private_tree.exact_dirs) |d| {
        var dup = false;
        for (base_tree.exact_dirs) |b| {
            if (std.mem.eql(u8, b, d)) {
                dup = true;
                break;
            }
        }
        if (!dup) try exact.append(arena, d);
    }

    return .{ .files = out, .exact_dirs = try exact.toOwnedSlice(arena) };
}

fn concatOverlays(arena: std.mem.Allocator, a: []const Overlay, b: []const Overlay) ![]const Overlay {
    const result = try arena.alloc(Overlay, a.len + b.len);
    @memcpy(result[0..a.len], a);
    @memcpy(result[a.len..], b);
    return result;
}

fn concatRegions(arena: std.mem.Allocator, a: []const Region, b: []const Region) ![]const Region {
    const result = try arena.alloc(Region, a.len + b.len);
    @memcpy(result[0..a.len], a);
    @memcpy(result[a.len..], b);
    return result;
}
