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
