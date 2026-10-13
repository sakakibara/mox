//! A path quoted as one word for the shell a printed remedy is pasted into.

const std = @import("std");

/// `s` as one word for a POSIX shell.
pub fn sh(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (s) |c| if (c == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, c);
    try out.append(arena, '\'');
    return out.items;
}

/// `s` as one PowerShell string literal. PowerShell takes U+2018 to U+201B
/// as single quotes too, so each is doubled as `'` is.
pub fn ps(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\'') {
            try out.appendSlice(arena, "''");
        } else if (i + 2 < s.len and s[i] == 0xe2 and s[i + 1] == 0x80 and s[i + 2] >= 0x98 and s[i + 2] <= 0x9b) {
            try out.appendSlice(arena, s[i .. i + 3]);
            try out.appendSlice(arena, s[i .. i + 3]);
            i += 2;
        } else try out.append(arena, s[i]);
    }
    try out.append(arena, '\'');
    return out.items;
}

test "sh and ps: a quote in a path stays inside one word" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("'/s/it'\\''s'", try sh(a, "/s/it's"));
    try std.testing.expectEqualStrings("'C:\\it''s'", try ps(a, "C:\\it's"));
    try std.testing.expectEqualStrings("'it\u{2018}\u{2018}s \u{2019}\u{2019}\u{201a}\u{201a}\u{201b}\u{201b}'", try ps(a, "it\u{2018}s \u{2019}\u{201a}\u{201b}"));
}
