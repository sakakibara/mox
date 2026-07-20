const std = @import("std");

pub const Stripped = struct {
    /// Fragment text with the pacifier line removed (unchanged when absent).
    text: []const u8,
    /// Leading source lines the strip consumed: 1 when a pacifier was removed,
    /// 0 otherwise. Commit uses this to map an emitted fragment line back to
    /// its true source line.
    lines: u32,
};

/// Strip the LSP-pacifier directive at the start of a fragment, if present.
/// Returns the input unchanged (with `lines == 0`) if no pacifier prefix
/// matches.
pub fn strip(content: []const u8, lang: []const u8) Stripped {
    const Map = struct { lang: []const u8, prefix: []const u8 };
    const table = [_]Map{
        .{ .lang = "lua", .prefix = "---@diagnostic disable" },
        .{ .lang = "ts", .prefix = "// @ts-nocheck" },
        .{ .lang = "js", .prefix = "// @ts-nocheck" },
        .{ .lang = "python", .prefix = "# pyright:" },
        .{ .lang = "py", .prefix = "# pyright:" },
        .{ .lang = "shell", .prefix = "# shellcheck disable" },
        .{ .lang = "sh", .prefix = "# shellcheck disable" },
        .{ .lang = "bash", .prefix = "# shellcheck disable" },
        .{ .lang = "zsh", .prefix = "# shellcheck disable" },
    };

    for (table) |entry| {
        if (!std.mem.eql(u8, lang, entry.lang)) continue;
        if (!std.mem.startsWith(u8, content, entry.prefix)) continue;
        const nl = std.mem.indexOfScalar(u8, content, '\n') orelse return .{ .text = "", .lines = 1 };
        return .{ .text = content[nl + 1 ..], .lines = 1 };
    }
    return .{ .text = content, .lines = 0 };
}

test "strip: lua pacifier" {
    const out = strip("---@diagnostic disable: undefined-global\nM.kind = \"work\"\n", "lua");
    try std.testing.expectEqualStrings("M.kind = \"work\"\n", out.text);
    try std.testing.expectEqual(@as(u32, 1), out.lines);
}

test "strip: no pacifier" {
    const input = "M.kind = \"work\"\n";
    const out = strip(input, "lua");
    try std.testing.expectEqualStrings(input, out.text);
    try std.testing.expectEqual(@as(u32, 0), out.lines);
}

test "strip: ts pacifier" {
    const out = strip("// @ts-nocheck\nexport const x = 1;\n", "ts");
    try std.testing.expectEqualStrings("export const x = 1;\n", out.text);
    try std.testing.expectEqual(@as(u32, 1), out.lines);
}

test "strip: pacifier on file with no trailing newline" {
    const out = strip("---@diagnostic disable\nlast line", "lua");
    try std.testing.expectEqualStrings("last line", out.text);
    try std.testing.expectEqual(@as(u32, 1), out.lines);
}
