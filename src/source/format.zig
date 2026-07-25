//! Structured-format detection for managed targets.
//!
//! The formats mox can parse and edit per key. Shared by the source walk
//! (partial-ownership validation) and the per-key commit machinery, so both
//! answer "is this target structured, and as what" from one table.

const std = @import("std");

/// A structured format with a per-key document model.
pub const Format = enum { toml, json, yaml, ini, gitconfig };

/// XDG git config files carry no telling extension: `~/.config/git/config`
/// plus the `.inc` includes git's `[include]`/`[includeIf]` mechanism points
/// at (`personal.inc`, `id-<slug>.inc`). All are gitconfig syntax.
pub fn isGitConfigPath(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, ".config/git/") == null) return false;
    return std.mem.endsWith(u8, path, "/config") or std.mem.endsWith(u8, path, ".inc");
}

/// Detect the structured format of a managed-file source path, or null when it
/// is not a Cat-A structured format. Mirrors the composer's extension table,
/// with gitconfig recognized by path shape rather than extension.
pub fn formatOfPath(path: []const u8) ?Format {
    if (isGitConfigPath(path)) return .gitconfig;
    const Pair = struct { ext: []const u8, format: Format };
    const table = [_]Pair{
        .{ .ext = ".toml", .format = .toml },
        .{ .ext = ".yaml", .format = .yaml },
        .{ .ext = ".yml", .format = .yaml },
        .{ .ext = ".json", .format = .json },
        .{ .ext = ".ini", .format = .ini },
        .{ .ext = ".gitconfig", .format = .gitconfig },
    };
    var longest: ?Format = null;
    var longest_len: usize = 0;
    for (table) |entry| {
        if (std.mem.endsWith(u8, path, entry.ext) and entry.ext.len > longest_len) {
            longest = entry.format;
            longest_len = entry.ext.len;
        }
    }
    return longest;
}

const testing = std.testing;

test "formatOfPath: recognizes structured formats and rejects others" {
    try testing.expectEqual(Format.toml, formatOfPath("src/config.toml").?);
    try testing.expectEqual(Format.json, formatOfPath("src/settings.json").?);
    try testing.expectEqual(Format.yaml, formatOfPath("src/c.yaml").?);
    try testing.expectEqual(Format.ini, formatOfPath("src/app.ini").?);
    try testing.expectEqual(Format.gitconfig, formatOfPath("src/.gitconfig").?);
    try testing.expect(formatOfPath("src/.zshrc") == null);
}

test "isGitConfigPath: xdg config and .inc includes, nothing else" {
    try testing.expect(isGitConfigPath(".config/git/config"));
    try testing.expect(isGitConfigPath("src/.config/git/personal.inc"));
    try testing.expect(!isGitConfigPath(".config/git/README"));
    try testing.expect(!isGitConfigPath(".ssh/config"));
}
