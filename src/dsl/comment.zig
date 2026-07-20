const std = @import("std");

/// Returns the line-comment marker for the given identifier, or null
/// if it is not recognized.
///
/// `ident` is matched as a whole-string lookup, case-insensitively, against
/// a table of file extensions and compound dotfile names. Examples:
///   - For files with a conventional extension: pass the extension with
///     leading dot (e.g., `.lua`, `.sh`, `.toml`).
///   - For dotfiles named after their tool with no separate extension
///     (e.g., `.zshrc`, `.gitconfig`, `.profile`): pass the full basename.
///   - For compound names (e.g., `.tmux.conf`): pass the full basename or
///     the trailing extension; both are recognized when present in the table.
///   - For special un-dotted names (e.g., `Dockerfile`): pass the basename.
///
/// Returns null when the identifier isn't in the table.
pub fn markerForExtension(ident: []const u8) ?[]const u8 {
    // Normalize to lowercase for matching.
    var buf: [32]u8 = undefined;
    if (ident.len == 0 or ident.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf[0..ident.len], ident);

    const Map = struct { ext: []const u8, marker: []const u8 };
    const table = [_]Map{
        // shell families
        .{ .ext = ".sh", .marker = "#" },
        .{ .ext = ".bash", .marker = "#" },
        .{ .ext = ".zsh", .marker = "#" },
        .{ .ext = ".zshrc", .marker = "#" },
        .{ .ext = ".bashrc", .marker = "#" },
        .{ .ext = ".profile", .marker = "#" },
        .{ .ext = ".zabbr", .marker = "#" },
        .{ .ext = ".fish", .marker = "#" },
        .{ .ext = ".ksh", .marker = "#" },
        // Python / Ruby / Perl / shell-like / other hash-comment formats
        .{ .ext = ".py", .marker = "#" },
        .{ .ext = ".rb", .marker = "#" },
        .{ .ext = ".pl", .marker = "#" },
        .{ .ext = ".tcl", .marker = "#" },
        .{ .ext = ".yaml", .marker = "#" },
        .{ .ext = ".yml", .marker = "#" },
        .{ .ext = ".toml", .marker = "#" },
        .{ .ext = ".conf", .marker = "#" },
        .{ .ext = ".gitconfig", .marker = "#" },
        .{ .ext = ".tmux.conf", .marker = "#" },
        .{ .ext = ".nim", .marker = "#" },
        .{ .ext = ".tf", .marker = "#" },
        .{ .ext = ".ex", .marker = "#" },
        .{ .ext = ".exs", .marker = "#" },
        .{ .ext = ".jl", .marker = "#" },
        .{ .ext = ".r", .marker = "#" },
        .{ .ext = "dockerfile", .marker = "#" },
        // Plain "config" basename: ssh_config(5), various app configs that
        // live as `<dir>/config` with no extension. Hash-comment is the
        // de-facto standard.
        .{ .ext = "config", .marker = "#" },
        // Lua / Haskell / SQL / Elm (`--`)
        .{ .ext = ".lua", .marker = "--" },
        .{ .ext = ".hs", .marker = "--" },
        .{ .ext = ".sql", .marker = "--" },
        .{ .ext = ".elm", .marker = "--" },
        // Lisp family (`;`)
        .{ .ext = ".el", .marker = ";" },
        .{ .ext = ".lisp", .marker = ";" },
        .{ .ext = ".scm", .marker = ";" },
        .{ .ext = ".clj", .marker = ";" },
        .{ .ext = ".cljs", .marker = ";" },
        // Erlang
        .{ .ext = ".erl", .marker = "%" },
        // Vim
        .{ .ext = ".vim", .marker = "\"" },
        .{ .ext = ".vimrc", .marker = "\"" },
        // C-family / JS / TS / Go / Rust / Dart
        .{ .ext = ".c", .marker = "//" },
        .{ .ext = ".cpp", .marker = "//" },
        .{ .ext = ".cc", .marker = "//" },
        .{ .ext = ".h", .marker = "//" },
        .{ .ext = ".hpp", .marker = "//" },
        .{ .ext = ".js", .marker = "//" },
        .{ .ext = ".ts", .marker = "//" },
        .{ .ext = ".jsx", .marker = "//" },
        .{ .ext = ".tsx", .marker = "//" },
        .{ .ext = ".go", .marker = "//" },
        .{ .ext = ".rs", .marker = "//" },
        .{ .ext = ".java", .marker = "//" },
        .{ .ext = ".kt", .marker = "//" },
        .{ .ext = ".scala", .marker = "//" },
        .{ .ext = ".swift", .marker = "//" },
        .{ .ext = ".dart", .marker = "//" },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, lower, entry.ext)) return entry.marker;
    }
    return null;
}

test "marker for .lua is --" {
    try std.testing.expectEqualStrings("--", markerForExtension(".lua").?);
}

test "marker for .sh is #" {
    try std.testing.expectEqualStrings("#", markerForExtension(".sh").?);
}

test "marker for .py is #" {
    try std.testing.expectEqualStrings("#", markerForExtension(".py").?);
}

test "marker for .ts is //" {
    try std.testing.expectEqualStrings("//", markerForExtension(".ts").?);
}

test "marker for .vim is \"" {
    try std.testing.expectEqualStrings("\"", markerForExtension(".vim").?);
}

test "marker is case-insensitive" {
    try std.testing.expectEqualStrings("--", markerForExtension(".LUA").?);
    try std.testing.expectEqualStrings("#", markerForExtension(".Sh").?);
}

test "unknown extension returns null" {
    try std.testing.expect(markerForExtension(".xyz") == null);
    try std.testing.expect(markerForExtension("") == null);
}

test "marker for .md returns null (markdown has no line comments)" {
    try std.testing.expect(markerForExtension(".md") == null);
}

test "marker for .tmux.conf is #" {
    try std.testing.expectEqualStrings("#", markerForExtension(".tmux.conf").?);
}

test "marker for Dockerfile is #" {
    try std.testing.expectEqualStrings("#", markerForExtension("Dockerfile").?);
}

test "marker for config (ssh_config-style) is #" {
    try std.testing.expectEqualStrings("#", markerForExtension("config").?);
}

test "marker for .clj is ;" {
    try std.testing.expectEqualStrings(";", markerForExtension(".clj").?);
}

test "marker for .erl is %" {
    try std.testing.expectEqualStrings("%", markerForExtension(".erl").?);
}
