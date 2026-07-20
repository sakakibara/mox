const std = @import("std");

/// Returns true if the given filename matches an OS-noise / editor-temp pattern
/// that should be silently ignored when scanning the source tree.
pub fn isJunk(filename: []const u8) bool {
    if (std.mem.eql(u8, filename, ".DS_Store")) return true;
    if (std.mem.eql(u8, filename, ".DS_Store?")) return true;
    if (std.mem.startsWith(u8, filename, "._")) return true;
    if (std.mem.eql(u8, filename, "Thumbs.db")) return true;
    if (std.mem.eql(u8, filename, "desktop.ini")) return true;
    if (std.mem.endsWith(u8, filename, ".swp")) return true;
    if (std.mem.endsWith(u8, filename, ".swo")) return true;
    if (std.mem.endsWith(u8, filename, "~")) return true;
    if (std.mem.startsWith(u8, filename, "#") and std.mem.endsWith(u8, filename, "#")) return true;
    if (std.mem.startsWith(u8, filename, ".#")) return true;
    return false;
}

test "isJunk: macOS metadata" {
    try std.testing.expect(isJunk(".DS_Store"));
    try std.testing.expect(isJunk("._foo.lua"));
}

test "isJunk: windows metadata" {
    try std.testing.expect(isJunk("Thumbs.db"));
    try std.testing.expect(isJunk("desktop.ini"));
}

test "isJunk: vim swap" {
    try std.testing.expect(isJunk(".file.swp"));
    try std.testing.expect(isJunk("file.swo"));
}

test "isJunk: emacs backups" {
    try std.testing.expect(isJunk("file.lua~"));
    try std.testing.expect(isJunk("#file.lua#"));
    try std.testing.expect(isJunk(".#file.lua"));
}

test "isJunk: regular file" {
    try std.testing.expect(!isJunk(".zshrc"));
    try std.testing.expect(!isJunk("config.toml"));
    try std.testing.expect(!isJunk("init.lua"));
}
