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
        // Windows / PowerShell
        .{ .ext = ".ps1", .marker = "#" },
        .{ .ext = ".psm1", .marker = "#" },
        .{ .ext = ".psd1", .marker = "#" },
        // Windows batch (`rem`)
        .{ .ext = ".cmd", .marker = "rem" },
        .{ .ext = ".bat", .marker = "rem" },
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

test "marker for .ps1 is #" {
    try std.testing.expectEqualStrings("#", markerForExtension(".ps1").?);
}

test "marker for .psm1 is #" {
    try std.testing.expectEqualStrings("#", markerForExtension(".psm1").?);
}

test "marker for .psd1 is #" {
    try std.testing.expectEqualStrings("#", markerForExtension(".psd1").?);
}

test "marker for .cmd is rem" {
    try std.testing.expectEqualStrings("rem", markerForExtension(".cmd").?);
}

test "marker for .bat is rem" {
    try std.testing.expectEqualStrings("rem", markerForExtension(".bat").?);
}

test "marker for .psm1 is case-insensitive" {
    try std.testing.expectEqualStrings("#", markerForExtension(".PSM1").?);
}

/// Identifier for `markerForExtension`: a dotfile with no further dot
/// (`.zshrc`) or an un-dotted basename (`Dockerfile`) is itself; otherwise the
/// trailing extension (`.lua`).
fn identForMarker(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (basename.len == 0) return basename;
    if (basename[0] == '.') {
        const rest = basename[1..];
        if (std.mem.indexOfScalar(u8, rest, '.') == null) return basename;
    }
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return basename;
    return basename[dot..];
}

fn eqAny(s: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| if (std.mem.eql(u8, s, c)) return true;
    return false;
}

/// Infer the comment marker from a shebang on line 1, if any. The
/// interpreter name (last path segment) is mapped to its known marker.
/// Returns null when there is no shebang or the interpreter is unrecognized.
fn markerForShebang(content: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, "#!")) return null;
    const eol = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const line = content[2..eol];
    const trimmed = std.mem.trimStart(u8, line, " \t");
    // Take the last path component of the interpreter (skip `env <name>`).
    const first_word_end = std.mem.indexOfAnyPos(u8, trimmed, 0, " \t") orelse trimmed.len;
    const interp_path = trimmed[0..first_word_end];
    const last_slash = std.mem.lastIndexOfScalar(u8, interp_path, '/');
    var interp_name: []const u8 = if (last_slash) |s| interp_path[s + 1 ..] else interp_path;
    // `#!/usr/bin/env <name>` or `#!/usr/bin/env -S <name>` — pick the next word.
    if (std.mem.eql(u8, interp_name, "env")) {
        const rest = std.mem.trimStart(u8, trimmed[first_word_end..], " \t");
        var skip: usize = 0;
        if (std.mem.startsWith(u8, rest, "-S")) {
            const after = std.mem.trimStart(u8, rest[2..], " \t");
            skip = @intFromPtr(after.ptr) - @intFromPtr(rest.ptr);
        }
        const after_skip = rest[skip..];
        const word_end = std.mem.indexOfAnyPos(u8, after_skip, 0, " \t") orelse after_skip.len;
        interp_name = after_skip[0..word_end];
    }
    if (interp_name.len == 0) return null;
    if (eqAny(interp_name, &.{
        // POSIX shells + common alternatives
        "bash",   "sh",      "zsh",     "fish",   "ksh",     "ash",
        "dash",   "mksh",    "yash",    "elvish", "xonsh",   "nushell",
        "nu",     "pwsh",    "rc",
        // Scripting languages with `#` line comments
             "python", "python3", "ruby",
        "perl",   "perl5",   "perl6",   "raku",   "tcl",     "tclsh",
        "node",   "deno",    "bun",     "lua",    "luajit",  "guile",
        "scheme", "racket",  "chicken", "csi",    "gosh",    "expect",
        "wish",
        // Text/data processors
          "awk",     "gawk",    "mawk",   "sed",     "jq",
        "yq",
        // Statistical / scientific
            "Rscript", "julia",   "octave",
    })) return "#";
    return null;
}

/// If `content` has any line of the form `<ws><1-3 non-alnum chars><ws>mox:`,
/// return the marker chars (the comment-prefix preceding `mox:`). Otherwise
/// null. Used to infer the comment marker for files whose extension isn't in
/// the marker table — `# mox: ...` is itself proof that `#` is the marker.
fn markerFromApparentDirective(content: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var rest = std.mem.trimStart(u8, line, " \t");
        if (rest.len == 0 or std.ascii.isAlphanumeric(rest[0])) continue;
        var i: usize = 0;
        while (i < @min(@as(usize, 3), rest.len) and
            !std.ascii.isAlphanumeric(rest[i]) and
            rest[i] != ' ' and rest[i] != '\t') : (i += 1)
        {}
        if (i == 0) continue;
        const candidate_marker = rest[0..i];
        const after = std.mem.trimStart(u8, rest[i..], " \t");
        if (std.mem.startsWith(u8, after, "mox:")) return candidate_marker;
    }
    return null;
}

/// The comment marker for a source file, or null when no signal is available.
/// Tries the extension, then a shebang (extensionless scripts), then an
/// apparent `# mox:` directive (plain config files with no extension/shebang).
/// The single marker-resolution authority both compose and discovery share --
/// whichever marker compose would resolve for a file is exactly the marker
/// discovery resolves for it too, so a file compose composes is never one
/// discovery silently skips.
pub fn markerForFile(source_base_path: []const u8, base_content: []const u8) ?[]const u8 {
    const ident = identForMarker(source_base_path);
    if (markerForExtension(ident)) |m| return m;
    if (markerForShebang(base_content)) |m| return m;
    if (markerFromApparentDirective(base_content)) |m| return m;
    return null;
}

test "markerForFile: extension wins over shebang" {
    try std.testing.expectEqualStrings("#", markerForFile("script.py", "#!/usr/bin/env bash\n").?);
}

test "markerForFile: recognized shebang resolves a marker for an unrecognized extension" {
    try std.testing.expectEqualStrings("#", markerForFile("script", "#!/bin/sh\necho hi\n").?);
}

test "markerForFile: unrecognized shebang interpreter falls through to apparent-directive" {
    try std.testing.expect(markerForFile("script", "#!/opt/custom/interp\necho hi\n") == null);
}

test "markerForFile: apparent `# mox:` directive resolves a marker with no extension or shebang" {
    try std.testing.expectEqualStrings("#", markerForFile("allowed_signers", "user namespaces=\"git\"\n# mox: when profile=work\n").?);
}

test "markerForFile: no extension, shebang, or apparent directive resolves nothing" {
    try std.testing.expect(markerForFile("README.md", "# Title\n\nSome prose.\n") == null);
}
