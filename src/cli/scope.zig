//! Resolves `status`/`diff`/`apply`/`commit`'s optional path arguments to the
//! `ManagedFile` entries they name, so those commands can act on a subset of
//! the tree instead of every managed file.

const std = @import("std");
const mox = @import("../root.zig");
const edit = @import("edit.zig");

const ManagedFile = mox.source.tree.ManagedFile;

/// Carries the argument that failed to resolve when `filterTree` returns
/// `error.NotManaged`. Fixed-size like `compose.interp.Diag`: no allocation
/// on the error path.
pub const Diag = struct {
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diag, text: []const u8) void {
        const n = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
    }

    pub fn capture(self: *const Diag) ?[]const u8 {
        return if (self.len == 0) null else self.buf[0..self.len];
    }
};

/// Resolve each of `paths` (a live absolute path, a shell-`~`-expanded
/// absolute path, or a src-relative name like `.zshrc`) to the managed file
/// in `tree_files` whose `live_path` it names. Every path must match; the
/// first that matches none sets `diag` to that argument and returns
/// `error.NotManaged`. A path repeated in `paths` contributes its file only
/// once. Result order follows `paths`, not `tree_files`.
pub fn filterTree(
    arena: std.mem.Allocator,
    io: std.Io,
    tree_files: []const ManagedFile,
    home: []const u8,
    paths: []const []const u8,
    diag: *Diag,
) ![]const ManagedFile {
    _ = io;
    var out: std.ArrayList(ManagedFile) = .empty;
    var seen: std.StringHashMap(void) = .init(arena);
    for (paths) |p| {
        const live = try edit.liveTarget(arena, p, home);
        const file = findByLive(tree_files, live) orelse {
            diag.set(p);
            return error.NotManaged;
        };
        const gop = try seen.getOrPut(file.live_path);
        if (!gop.found_existing) try out.append(arena, file);
    }
    return out.toOwnedSlice(arena);
}

fn findByLive(tree_files: []const ManagedFile, live: []const u8) ?ManagedFile {
    for (tree_files) |f| {
        if (std.mem.eql(u8, f.live_path, live)) return f;
    }
    return null;
}

const testing = std.testing;

/// A home root that is absolute on the HOST. `std.fs.path.isAbsolute` is
/// platform-specific -- `/home/me` is not absolute on Windows, so a POSIX-only
/// literal would take the src-relative branch there and resolve to nothing.
const test_home = if (@import("builtin").os.tag == .windows) "C:\\home\\me" else "/home/me";

/// `test_home` joined with a src-relative key, in the host's native form.
fn testHomePath(a: std.mem.Allocator, rel: []const u8) ![]const u8 {
    return mox.source.path.joinKeyOnto(a, test_home, rel);
}

fn testFile(live_path: []const u8) ManagedFile {
    return .{
        .source_base_path = "",
        .source_base_abs = "",
        .live_path = live_path,
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
    };
}

test "filterTree: an absolute path and a src-relative name both resolve to their managed file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zshrc = try testHomePath(a, ".zshrc");
    const init_lua = try testHomePath(a, ".config/nvim/init.lua");
    const files = [_]ManagedFile{ testFile(zshrc), testFile(init_lua) };
    var diag: Diag = .{};

    const abs = try filterTree(a, testing.io, &files, test_home, &.{zshrc}, &diag);
    try testing.expectEqual(@as(usize, 1), abs.len);
    try testing.expectEqualStrings(zshrc, abs[0].live_path);

    const rel = try filterTree(a, testing.io, &files, test_home, &.{".config/nvim/init.lua"}, &diag);
    try testing.expectEqual(@as(usize, 1), rel.len);
    try testing.expectEqualStrings(init_lua, rel[0].live_path);
}

test "filterTree: an unmanaged path errors and diag captures the argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nope = try testHomePath(a, ".nope");
    const files = [_]ManagedFile{testFile(try testHomePath(a, ".zshrc"))};
    var diag: Diag = .{};

    try testing.expectError(error.NotManaged, filterTree(a, testing.io, &files, test_home, &.{nope}, &diag));
    try testing.expectEqualStrings(nope, diag.capture().?);
}

test "filterTree: a path repeated in the arg list contributes its file once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zshrc = try testHomePath(a, ".zshrc");
    const files = [_]ManagedFile{ testFile(zshrc), testFile(try testHomePath(a, ".bashrc")) };
    var diag: Diag = .{};

    const got = try filterTree(a, testing.io, &files, test_home, &.{ zshrc, ".zshrc" }, &diag);
    try testing.expectEqual(@as(usize, 1), got.len);
}

test "filterTree: no paths given returns an empty slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const files = [_]ManagedFile{testFile(try testHomePath(a, ".zshrc"))};
    var diag: Diag = .{};

    const got = try filterTree(a, testing.io, &files, test_home, &.{}, &diag);
    try testing.expectEqual(@as(usize, 0), got.len);
}
