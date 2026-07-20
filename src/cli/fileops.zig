//! Shared helpers for the file-lifecycle commands (mv / remove / add-tree):
//! source-file location, trash pathing, rename-target computation, and a
//! recursive copy into the trash backup.

const std = @import("std");
const mox = @import("../root.zig");

const Io = std.Io;
const ManagedFile = mox.source.tree.ManagedFile;

/// Root of a timestamped trash generation: `<state>/trash/<id>`.
pub fn trashRoot(arena: std.mem.Allocator, state_dir: []const u8, id: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ state_dir, "trash", id });
}

/// The managed file whose live path equals `live_path`, or null.
pub fn findByLive(tree: mox.source.tree.ManagedTree, live_path: []const u8) ?ManagedFile {
    for (tree.files) |f| {
        if (std.mem.eql(u8, f.live_path, live_path)) return f;
    }
    return null;
}

/// Absolute path of a file's `.d/` overlay directory, or null when the file
/// has no overlays/regions. For a based file it sits beside the base; for an
/// orphan `.d/` it is the parent of the first overlay/fragment.
pub fn dotDAbs(arena: std.mem.Allocator, file: ManagedFile) !?[]const u8 {
    if (file.has_base and file.source_base_abs.len > 0) {
        return try std.fmt.allocPrint(arena, "{s}.d", .{file.source_base_abs});
    }
    if (file.overlays.len > 0) {
        return std.fs.path.dirname(file.overlays[0].path);
    }
    if (file.regions.len > 0) {
        return std.fs.path.dirname(file.regions[0].path);
    }
    return null;
}

/// Compute the new source base path (repo-relative, starting `src/`) for a
/// move to `new_live`. The source name mirrors the live name verbatim (no
/// filename prefixes); any `.mox/attributes.toml` entry is re-keyed separately.
pub fn newBaseRel(
    arena: std.mem.Allocator,
    new_live: []const u8,
    home: []const u8,
) ![]const u8 {
    const new_rel = try liveRelOrSelf(arena, home, new_live);
    return mox.source.path.joinKey(arena, &.{ "src", new_rel });
}

/// Live path relative to home; if `live_path` is not under `home` it is
/// returned unchanged (a bare relative name), so mv accepts both forms.
fn liveRelOrSelf(arena: std.mem.Allocator, home: []const u8, live_path: []const u8) ![]const u8 {
    return mox.source.path.liveKeyRelToHome(arena, home, live_path);
}

/// Recursively copy `src_abs` (file or directory) to `dst_abs`, creating
/// parents. Used to back a source file (base + `.d/`) into the trash before a
/// destructive rename or delete, so the operation is recoverable.
pub fn copyTree(io: Io, arena: std.mem.Allocator, src_abs: []const u8, dst_abs: []const u8) !void {
    const st = try Io.Dir.cwd().statFile(io, src_abs, .{});
    if (st.kind == .directory) {
        try Io.Dir.cwd().createDirPath(io, dst_abs);
        var dir = try Io.Dir.cwd().openDir(io, src_abs, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            const child_src = try std.fs.path.join(arena, &.{ src_abs, entry.name });
            const child_dst = try std.fs.path.join(arena, &.{ dst_abs, entry.name });
            try copyTree(io, arena, child_src, child_dst);
        }
        return;
    }
    if (std.fs.path.dirname(dst_abs)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    const content = try Io.Dir.cwd().readFileAlloc(io, src_abs, arena, .limited(64 * 1024 * 1024));
    const mode: u32 = mox.apply.write.modeOf(st.permissions);
    try mox.apply.write.writeAtomic(io, dst_abs, content, mode);
}

const testing = std.testing;

test "trashRoot: joins state, trash, id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = try std.fs.path.join(a, &.{ "/state", "trash", "20260711T000000Z" });
    try testing.expectEqualStrings(want, try trashRoot(a, "/state", "20260711T000000Z"));
}

test "newBaseRel: mirrors the live name and relocates the file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Top-level rename.
    try testing.expectEqualStrings(
        "src/.bashrc",
        try newBaseRel(a, "/home/me/.bashrc", "/home/me"),
    );
    // Moved into a subdir.
    try testing.expectEqualStrings(
        "src/.config/other.local",
        try newBaseRel(a, "/home/me/.config/other.local", "/home/me"),
    );
}
