const std = @import("std");
const testing = std.testing;

pub const ColorFlag = enum { auto, always, never };

pub fn enabled(out_is_tty: bool, no_color_set: bool, flag: ColorFlag) bool {
    return switch (flag) {
        .always => true,
        .never => false,
        .auto => out_is_tty and !no_color_set,
    };
}

pub const Style = struct {
    on: bool,

    pub fn open(self: Style, comptime code: []const u8, out: *std.Io.Writer) !void {
        if (self.on) try out.writeAll("\x1b[" ++ code ++ "m");
    }
    pub fn close(self: Style, out: *std.Io.Writer) !void {
        if (self.on) try out.writeAll("\x1b[0m");
    }

    pub fn red(self: Style, out: *std.Io.Writer) !void {
        try self.open("31", out);
    }
    pub fn green(self: Style, out: *std.Io.Writer) !void {
        try self.open("32", out);
    }
    pub fn dim(self: Style, out: *std.Io.Writer) !void {
        try self.open("2", out);
    }
    pub fn bold(self: Style, out: *std.Io.Writer) !void {
        try self.open("1", out);
    }
    pub fn cyan(self: Style, out: *std.Io.Writer) !void {
        try self.open("36", out);
    }
};

test "enabled: TTY x NO_COLOR x flag truth table" {
    try testing.expect(enabled(true, false, .auto)); // tty, no NO_COLOR, auto -> on
    try testing.expect(!enabled(false, false, .auto)); // not a tty -> off
    try testing.expect(!enabled(true, true, .auto)); // NO_COLOR set -> off
    try testing.expect(enabled(false, true, .always)); // always forces on
    try testing.expect(!enabled(true, false, .never)); // never forces off
}

test "Style: writes ANSI codes when on, nothing when off" {
    var on_buf: [64]u8 = undefined;
    var on_w: std.Io.Writer = .fixed(&on_buf);
    const on = Style{ .on = true };
    try on.open("31", &on_w);
    try testing.expectEqualStrings("\x1b[31m", on_w.buffered());
    on_w.end = 0;
    try on.close(&on_w);
    try testing.expectEqualStrings("\x1b[0m", on_w.buffered());

    var off_buf: [64]u8 = undefined;
    var off_w: std.Io.Writer = .fixed(&off_buf);
    const off = Style{ .on = false };
    try off.open("31", &off_w);
    try off.close(&off_w);
    try testing.expectEqualStrings("", off_w.buffered());
}

test "Style: palette helpers emit the right code" {
    const cases = .{
        .{ "red", "\x1b[31m" },
        .{ "green", "\x1b[32m" },
        .{ "dim", "\x1b[2m" },
        .{ "bold", "\x1b[1m" },
        .{ "cyan", "\x1b[36m" },
    };
    const on = Style{ .on = true };
    inline for (cases) |case| {
        var buf: [16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try @field(Style, case[0])(on, &w);
        try testing.expectEqualStrings(case[1], w.buffered());
    }
}
