//! How a path is shown to a human.
//!
//! A live path is absolute everywhere inside mox -- it is what the source walk
//! derives, what the applied record stores, and what the filesystem is handed.
//! Printed as-is it buries the interesting tail under a home prefix that is
//! the same on every line, so human output contracts it to `~/`.
//!
//! Never for machine-readable output. `--json` and `--porcelain` emit the real
//! path, because their consumer does no tilde expansion.

const std = @import("std");
const mox = @import("../root.zig");

/// A path rendered for a human: `~/x` when it sits under `home`, unchanged
/// otherwise (including when `home` is empty). Format it with `{f}`.
///
/// Allocation-free: the two pieces are written straight through rather than
/// joined, so a print site needs no arena and cannot fail on one.
pub const Path = struct {
    path: []const u8,
    home: []const u8,

    pub fn format(self: Path, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.rel()) |r| {
            try w.writeAll("~");
            // `~` alone names home itself; a tail keeps the separator it had.
            if (r.len > 0) try w.writeAll(r);
            return;
        }
        try w.writeAll(self.path);
    }

    /// The remainder of `path` after `home`, or null when it does not sit
    /// under it. The byte after the match must be a separator, so `/home/mel`
    /// is left alone rather than mangled against `/home/me`.
    fn rel(self: Path) ?[]const u8 {
        const h = std.mem.trimEnd(u8, self.home, "/\\");
        if (h.len == 0) return null;
        if (!std.mem.startsWith(u8, self.path, h)) return null;
        const rest = self.path[h.len..];
        if (rest.len == 0) return "";
        return if (std.fs.path.isSep(rest[0])) rest else null;
    }
};

/// `path` as a human reads it, against `home`.
pub fn of(path: []const u8, home: []const u8) Path {
    return .{ .path = path, .home = home };
}

/// The same contraction as an owned string, for a caller that needs a value
/// rather than a format argument (a table cell measured before it is written,
/// a row assembled into a struct).
pub fn alloc(arena: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    const p = of(path, home);
    if (p.rel()) |r| return std.fmt.allocPrint(arena, "~{s}", .{r});
    return path;
}

const testing = std.testing;

const test_home = if (@import("builtin").os.tag == .windows) "C:\\home\\me" else "/home/me";

fn render(a: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try aw.writer.print("{f}", .{of(path, home)});
    return aw.toOwnedSlice();
}

test "Path: a path under home contracts, keeping its own separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zshrc = try std.fs.path.join(a, &.{ test_home, ".zshrc" });
    const want = try std.fmt.allocPrint(a, "~{c}.zshrc", .{std.fs.path.sep});
    try testing.expectEqualStrings(want, try render(a, zshrc, test_home));
    try testing.expectEqualStrings(want, try alloc(a, zshrc, test_home));
}

test "Path: home itself renders as `~`" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("~", try render(a, test_home, test_home));
    // A trailing separator on home must not defeat the match.
    const trailing = try std.fmt.allocPrint(a, "{s}{c}", .{ test_home, std.fs.path.sep });
    try testing.expectEqualStrings("~", try render(a, test_home, trailing));
}

test "Path: a path outside home is left exactly as it is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const outside = if (@import("builtin").os.tag == .windows) "C:\\etc\\hosts" else "/etc/hosts";
    try testing.expectEqualStrings(outside, try render(a, outside, test_home));
    try testing.expectEqualStrings(outside, try alloc(a, outside, test_home));

    // A sibling whose name merely starts with home's is not under it.
    const sibling = try std.fmt.allocPrint(a, "{s}lon{c}x", .{ test_home, std.fs.path.sep });
    try testing.expectEqualStrings(sibling, try render(a, sibling, test_home));

    // An empty home contracts nothing rather than matching every path.
    try testing.expectEqualStrings(outside, try render(a, outside, ""));
}
