const std = @import("std");
const junk = @import("../source/junk.zig");
const Io = std.Io;
const source = @import("../source/root.zig");
const partial = @import("../apply/partial.zig");

const ManagedTree = source.tree.ManagedTree;
const ManagedFile = source.tree.ManagedFile;
const Overlay = source.tree.Overlay;
const Region = source.tree.Region;

/// Merge the private layer at `private_dir` into `base_tree`. The private
/// root mirrors `src/`: its overlays and regions extend the repo file at the
/// same path, and a file that exists only in the private layer is added as
/// it stands. Its `.mox/attributes.toml` may set any key for a private-only
/// path, and only `mode` for a path the repo manages, which then wins over
/// the repo's. A private base at a path the repo manages, any other private
/// attribute there, and a private overlay defining content under a path the
/// repo disowns are that file's error.
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
    return mergeAt(arena, io, base_tree, try std.Io.Dir.realPathFileAbsoluteAlloc(io, private_dir, arena), home_dir);
}

/// `merge` with `private_dir` resolved: the walk does not follow a symlinked
/// root, so a private layer that is a link to a directory is walked there.
fn mergeAt(
    arena: std.mem.Allocator,
    io: std.Io,
    base_tree: ManagedTree,
    private_dir: []const u8,
    home_dir: []const u8,
) !ManagedTree {

    // The private root's `data/` is data (`mox data`, loop sources, the
    // package manifest) and its `.mox/` holds its attributes, never a source:
    // walking either would plan `~/data/...`.
    var base_map = std.StringHashMap(ManagedFile).init(arena);
    defer base_map.deinit();
    var repo_paths = std.StringHashMap(void).init(arena);
    defer repo_paths.deinit();
    for (base_tree.files) |f| {
        try base_map.put(f.source_base_path, f);
        try repo_paths.put(f.source_base_path, {});
    }

    const private_tree = try source.tree.walkExcluding(arena, io, private_dir, private_dir, home_dir, &.{ "data", ".mox" }, &repo_paths, null);
    const private_attrs = try source.attributes.load(arena, io, private_dir);

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
            const target_key = if (std.mem.startsWith(u8, key, "src/")) key["src/".len..] else key;
            if (combined.head_error.len == 0) {
                if (try privateEntryError(arena, &private_attrs, target_key)) |err| {
                    combined.head_error = err;
                    combined.head_error_attrs = true;
                } else if (try repoPathError(arena, io, base_file, pf)) |err| {
                    combined.head_error = err;
                } else if (private_attrs.mode(target_key)) |m| {
                    combined.mode = m;
                    combined.mode_explicit = true;
                }
            }
            try merged.append(arena, combined);
        } else {
            try merged.append(arena, pf);
        }
    }

    for (base_tree.files) |bf| {
        if (seen_in_private.contains(bf.source_base_path)) continue;
        // A private entry for a repo path holds with no private file there.
        var combined = bf;
        const target_key = if (std.mem.startsWith(u8, bf.source_base_path, "src/")) bf.source_base_path["src/".len..] else bf.source_base_path;
        if (combined.head_error.len == 0) {
            if (try privateEntryError(arena, &private_attrs, target_key)) |err| {
                combined.head_error = err;
                combined.head_error_attrs = true;
            } else if (private_attrs.mode(target_key)) |m| {
                combined.mode = m;
                combined.mode_explicit = true;
            }
        }
        try merged.append(arena, combined);
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

    return .{
        .files = out,
        .exact_dirs = try exact.toOwnedSlice(arena),
        .released = try concatPaths(arena, base_tree.released, try privateReleased(arena, private_tree.released, base_tree.files)),
        .entry_errors = try entryErrors(arena, base_tree, private_tree),
    };
}

/// Why the private layer's contribution to a path the repo manages is
/// refused, or null when it is not.
fn repoPathError(
    arena: std.mem.Allocator,
    io: std.Io,
    base_file: ManagedFile,
    pf: ManagedFile,
) !?[]const u8 {
    if (pf.has_base) {
        return try std.fmt.allocPrint(arena, "a private base at a path the repo manages: {s} and {s}; vary it with a private overlay instead", .{
            try source.path.toKey(arena, pf.source_base_abs),
            base_file.source_base_path,
        });
    }
    if (base_file.ownership == .disown) {
        const format = base_file.format orelse return null;
        for (pf.overlays) |o| {
            const text = std.Io.Dir.cwd().readFileAlloc(io, o.path, arena, .limited(4 * 1024 * 1024)) catch continue;
            const doc = partial.OwnedDoc.parse(arena, format, text) catch continue;
            if (try partial.populatedDisownPath(arena, &doc, base_file.own_paths)) |spelled| {
                return try std.fmt.allocPrint(arena, "private overlay {s} defines content under disowned path {s}", .{
                    try source.path.toKey(arena, o.path), spelled,
                });
            }
        }
    }
    return null;
}

/// Why a private attributes entry for a path the repo manages is refused,
/// or null: it may set `mode` alone.
fn privateEntryError(arena: std.mem.Allocator, private_attrs: *const source.attributes.Attributes, target_key: []const u8) !?[]const u8 {
    const e = private_attrs.lookup(target_key) orelse return null;
    if (e.err.len > 0) return try std.fmt.allocPrint(arena, "private {s}", .{e.err});
    var only_mode = e;
    only_mode.mode = null;
    if (!source.attributes.entryEmpty(only_mode))
        return "private .mox/attributes.toml: only mode may be set for a path the repo manages";
    return null;
}

/// The private layer's tombstones, less any at a path the repo manages,
/// where only `mode` is the private layer's to set.
fn privateReleased(arena: std.mem.Allocator, released: []const []const u8, repo_files: []const ManagedFile) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    outer: for (released) |p| {
        for (repo_files) |f| if (std.mem.eql(u8, f.live_path, p)) continue :outer;
        try out.append(arena, p);
    }
    return out.toOwnedSlice(arena);
}

/// The repo's unclaimed broken entries and the private layer's, less any at
/// a path the repo manages, which is that file's error instead.
fn entryErrors(arena: std.mem.Allocator, base_tree: ManagedTree, private_tree: ManagedTree) ![]const source.tree.EntryError {
    var out: std.ArrayList(source.tree.EntryError) = .empty;
    try out.appendSlice(arena, base_tree.entry_errors);
    outer: for (private_tree.entry_errors) |e| {
        for (base_tree.files) |f| if (std.mem.eql(u8, f.live_path, e.live_path)) continue :outer;
        try out.append(arena, .{ .live_path = e.live_path, .err = try std.fmt.allocPrint(arena, "private {s}", .{e.err}) });
    }
    return out.toOwnedSlice(arena);
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

fn concatPaths(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]const []const u8 {
    const result = try arena.alloc([]const u8, a.len + b.len);
    @memcpy(result[0..a.len], a);
    @memcpy(result[a.len..], b);
    return result;
}

/// True when the private layer at `private_dir` is a directory holding a
/// file the source walk would not skip as junk, at any depth.
pub fn holdsSource(arena: std.mem.Allocator, io: Io, private_dir: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(io, private_dir, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (walker.next(io) catch return false) |entry| {
        if (entry.kind == .directory) continue;
        if (junkPath(entry.path)) continue;
        return true;
    }
    return false;
}

fn junkPath(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| if (junk.isJunk(part)) return true;
    return false;
}

test "holdsSource: junk and an evicted iCloud placeholder are no source" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "p/.config/x");
    try tmp.dir.writeFile(io, .{ .sub_path = "p/.DS_Store", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "p/.config/x/..c.icloud", .data = "x" });
    const p = try tmp.dir.realPathFileAlloc(io, "p", a);
    try testing.expect(!try holdsSource(a, io, p));
    try tmp.dir.writeFile(io, .{ .sub_path = "p/.config/x/c", .data = "x" });
    try testing.expect(try holdsSource(a, io, p));
    try testing.expect(!try holdsSource(a, io, try std.fs.path.join(a, &.{ p, "missing" })));
}
