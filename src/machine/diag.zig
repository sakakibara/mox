const std = @import("std");

/// Bounded diagnostic message for a capture-time collision or malformed-row
/// error, so a caller can report the specifics instead of a bare error name.
/// Shared by every capture-time loader (`facts.zig`, `derived_facts.zig`)
/// that needs to name what went wrong.
pub const Diag = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.buf, fmt, args) catch &self.buf;
        self.len = written.len;
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
