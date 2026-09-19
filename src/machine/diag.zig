const std = @import("std");

/// Bounded diagnostic message for a capture-time collision or malformed-row
/// error, so a caller can report the specifics instead of a bare error name.
/// Shared by every loader (`facts.zig`, `derived_facts.zig`, the package
/// manifest) that needs to name what went wrong. A message the buffer cannot
/// hold keeps its head and ends in `...`, so a cut is never mistaken for the
/// whole message.
pub const Diag = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(&self.buf);
        w.print(fmt, args) catch {
            self.len = self.buf.len;
            @memcpy(self.buf[self.buf.len - 3 ..], "...");
            return;
        };
        self.len = w.buffered().len;
    }

    pub fn capture(self: *const Diag) ?[]const u8 {
        return if (self.len > 0) self.buf[0..self.len] else null;
    }
};

/// `s` with every control byte spelled `\xNN`, for a filename or a path on
/// its way into a message. A diagnostic is one line, and a newline in a name
/// the message interpolates splits it across two: a reader loses the frame,
/// and a wrapper that keeps the first line loses the reason. Returned
/// unchanged when there is nothing to escape, which is every real name.
///
/// A backslash is left alone. Every Windows path carries several, and
/// doubling them to make this reversible would cost every message its
/// readability to disambiguate a filename nobody has.
pub fn oneLine(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const clean = for (s) |c| {
        if (std.ascii.isControl(c)) break false;
    } else true;
    if (clean) return s;

    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isControl(c)) {
            try out.print(arena, "\\x{x:0>2}", .{c});
        } else {
            try out.append(arena, c);
        }
    }
    return out.toOwnedSlice(arena);
}

test "oneLine: a control byte is spelled out, and an ordinary name is untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain = "data/packages/darwin.toml";
    try std.testing.expectEqual(plain.ptr, (try oneLine(a, plain)).ptr);
    // A backslash survives, so a Windows path reads as itself.
    const win = "C:\\Users\\x\\darwin.toml";
    try std.testing.expectEqual(win.ptr, (try oneLine(a, win)).ptr);

    try std.testing.expectEqualStrings(
        "dar\\x0awin\\x09.toml\\x7f",
        try oneLine(a, "dar\nwin\t.toml\x7f"),
    );
}

test "Diag: set then capture round-trips; capture null before any set" {
    var d: Diag = .{};
    try std.testing.expect(d.capture() == null);
    d.set("bad row {d}: {s}", .{ 3, "no name" });
    try std.testing.expectEqualStrings("bad row 3: no name", d.capture().?);
}

test "Diag: a message the buffer cannot hold keeps its head and is visibly cut" {
    var d: Diag = .{};
    const long = "x" ** 2000;
    d.set("{s}: not executable (chmod +x it)", .{long});
    const got = d.capture().?;
    try std.testing.expectEqual(d.buf.len, got.len);
    try std.testing.expect(std.mem.startsWith(u8, got, "xxxx"));
    try std.testing.expect(std.mem.endsWith(u8, got, "..."));
}
