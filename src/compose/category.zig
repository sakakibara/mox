const std = @import("std");

pub const Category = enum { a, b, c };

/// Detect category from filename and (optionally peeking) content.
///
/// `content` may be the full file or just a prefix. If the file is large,
/// passing only the first 4KB is sufficient for content sniffing.
pub fn detect(filename: []const u8, content: []const u8) Category {
    // A known extension is authoritative: a stray control byte (a raw ESC in a
    // color-prompt, an LS_COLORS heredoc) must not demote a text/code file to
    // binary and skip its directives. Only files with no telling extension fall
    // back to a content sniff, where a NUL or a high density of control bytes
    // marks genuine binary.
    if (isGitConfigPath(filename)) return .a;
    if (extensionCategory(filename)) |cat| return cat;
    if (looksBinary(content)) return .c;
    return .b;
}

/// XDG git config files carry no telling extension: `~/.config/git/config`
/// plus the `.inc` includes git's `[include]`/`[includeIf]` mechanism points
/// at (`personal.inc`, `id-<slug>.inc`). All are gitconfig syntax.
pub fn isGitConfigPath(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, ".config/git/") == null) return false;
    return std.mem.endsWith(u8, path, "/config") or std.mem.endsWith(u8, path, ".inc");
}

/// Sniff whether a file with no informative extension is binary. A NUL is a
/// hard signal; otherwise a high fraction of control bytes (excluding the tab,
/// LF, and CR that pervade text) in the first 4KB marks binary.
fn looksBinary(content: []const u8) bool {
    const sample = content[0..@min(content.len, 4096)];
    if (sample.len == 0) return false;
    var controls: usize = 0;
    for (sample) |b| {
        if (b == 0) return true;
        if (isControlByte(b)) controls += 1;
    }
    return controls * 100 > sample.len * 30;
}

fn isControlByte(b: u8) bool {
    if (b == '\t' or b == '\n' or b == '\r') return false;
    return b < 0x20;
}

fn extensionCategory(filename: []const u8) ?Category {
    const Map = struct { ext: []const u8, cat: Category };
    const table = [_]Map{
        // A: structured
        .{ .ext = ".toml", .cat = .a },
        .{ .ext = ".yaml", .cat = .a },
        .{ .ext = ".yml", .cat = .a },
        .{ .ext = ".json", .cat = .a },
        .{ .ext = ".ini", .cat = .a },
        .{ .ext = ".gitconfig", .cat = .a },
        // C: binary
        .{ .ext = ".png", .cat = .c },
        .{ .ext = ".jpg", .cat = .c },
        .{ .ext = ".jpeg", .cat = .c },
        .{ .ext = ".icns", .cat = .c },
        .{ .ext = ".pem", .cat = .c },
        .{ .ext = ".crt", .cat = .c },
        .{ .ext = ".key", .cat = .c },
        .{ .ext = ".so", .cat = .c },
        .{ .ext = ".dylib", .cat = .c },
        .{ .ext = ".woff", .cat = .c },
        .{ .ext = ".woff2", .cat = .c },
        .{ .ext = ".ttf", .cat = .c },
        // B: code/text
        .{ .ext = ".sh", .cat = .b },
        .{ .ext = ".bash", .cat = .b },
        .{ .ext = ".zsh", .cat = .b },
        .{ .ext = ".fish", .cat = .b },
        .{ .ext = ".py", .cat = .b },
        .{ .ext = ".rb", .cat = .b },
        .{ .ext = ".lua", .cat = .b },
        .{ .ext = ".el", .cat = .b },
        .{ .ext = ".vim", .cat = .b },
        .{ .ext = ".js", .cat = .b },
        .{ .ext = ".ts", .cat = .b },
        .{ .ext = ".go", .cat = .b },
        .{ .ext = ".rs", .cat = .b },
        .{ .ext = ".conf", .cat = .b },
    };
    var best_match: ?Category = null;
    var best_len: usize = 0;
    for (table) |entry| {
        if (std.mem.endsWith(u8, filename, entry.ext) and entry.ext.len > best_len) {
            best_match = entry.cat;
            best_len = entry.ext.len;
        }
    }
    return best_match;
}

test "detect: .toml is A" {
    try std.testing.expectEqual(Category.a, detect("config.toml", "[user]\n"));
}

test "detect: .lua is B" {
    try std.testing.expectEqual(Category.b, detect("init.lua", "local M = {}\n"));
}

test "detect: binary content is C" {
    var bin = [_]u8{ 0x89, 0x50, 0x4e, 0x47 };
    try std.testing.expectEqual(Category.c, detect("icon.png", &bin));
}

test "detect: unknown extension text -> B" {
    try std.testing.expectEqual(Category.b, detect("README", "Hello\n"));
}

test "detect: known C extension overrides text content" {
    try std.testing.expectEqual(Category.c, detect("foo.png", "Hello\n"));
}

test "detect: a text extension wins over an isolated control byte" {
    // A .sh whose first 4KB embeds a raw ESC (color-code prompt) is still Cat B,
    // so its `# mox:` directives get processed rather than copied verbatim.
    const content = "# mox: when os=darwin\nexport PS1=$'\x1b[31m%n\x1b[0m'\n";
    try std.testing.expectEqual(Category.b, detect("prompt.sh", content));
}

test "detect: no-extension content with NUL is binary C" {
    const content = [_]u8{ 'a', 'b', 0x00, 'c' };
    try std.testing.expectEqual(Category.c, detect("mystery", &content));
}

test "detect: no-extension content dense with control bytes is C" {
    const content = [_]u8{ 0x1b, 0x1b, 0x1b, 0x1b, 'a', 'b' };
    try std.testing.expectEqual(Category.c, detect("mystery", &content));
}
