//! Structured-format resolution for managed targets.
//!
//! The formats mox can parse and edit per key. A managed file's format, and
//! for the JSON family its dialect, is resolved once by the tree walk from
//! its path and its `.mox/attributes.toml` entry, and every consumer reads it
//! from the walked file.

const std = @import("std");
const ini = @import("ini");
const json = @import("json");

/// A structured format with a per-key document model. `json` is strict RFC
/// 8259 JSON; `jsonc` is JSON with comments and trailing commas.
pub const Format = enum {
    toml,
    json,
    jsonc,
    yaml,
    ini,
    gitconfig,

    /// True for both JSON dialects.
    pub fn isJson(self: Format) bool {
        return self == .json or self == .jsonc;
    }

    /// The json-zig dialect a JSON-family document is read and written with.
    pub fn jsonDialect(self: Format) json.Dialect {
        return if (self == .jsonc) .jsonc else .json;
    }

    /// The line-comment marker head directives are written in, or null for
    /// strict JSON, which has no comments.
    pub fn marker(self: Format) ?[]const u8 {
        return switch (self) {
            .json => null,
            .jsonc => "//",
            else => "#",
        };
    }
};

/// The dialect an INI or gitconfig document is read with wherever mox matches
/// its sections and keys. The section merge that composes a layered file
/// matches headers by the same dialect, so every reader agrees on which
/// section, and so which layer, a key is in. A generic INI file may hold a
/// bare key (`skip-networking` in `my.cnf`).
pub fn iniDialect(format: Format) ini.Dialect {
    if (format == .gitconfig) return .gitconfig;
    var d = ini.Dialect.generic;
    d.allow_no_value = true;
    return d;
}

/// XDG git config files carry no telling extension: `~/.config/git/config`
/// plus the `.inc` includes git's `[include]`/`[includeIf]` mechanism points
/// at (`personal.inc`, `id-<slug>.inc`). All are gitconfig syntax.
pub fn isGitConfigPath(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, ".config/git/") == null) return false;
    return std.mem.endsWith(u8, path, "/config") or std.mem.endsWith(u8, path, ".inc");
}

/// The format of a managed target key, or null when it is not structured.
/// `jsonc` is the target's `format = "jsonc"` attribute, which only a `.json`
/// path may carry (the attributes loader refuses it anywhere else).
pub fn resolve(key: []const u8, jsonc: bool) ?Format {
    if (isGitConfigPath(key)) return .gitconfig;
    const Pair = struct { ext: []const u8, format: Format };
    const table = [_]Pair{
        .{ .ext = ".toml", .format = .toml },
        .{ .ext = ".yaml", .format = .yaml },
        .{ .ext = ".yml", .format = .yaml },
        .{ .ext = ".json", .format = .json },
        .{ .ext = ".jsonc", .format = .jsonc },
        .{ .ext = ".ini", .format = .ini },
        .{ .ext = ".gitconfig", .format = .gitconfig },
    };
    var longest: ?Format = null;
    var longest_len: usize = 0;
    for (table) |entry| {
        if (std.mem.endsWith(u8, key, entry.ext) and entry.ext.len > longest_len) {
            longest = entry.format;
            longest_len = entry.ext.len;
        }
    }
    if (longest == .json and jsonc) return .jsonc;
    return longest;
}

/// True when `key` names a `.json` path, the only path a `format` attribute
/// may be set on.
pub fn isJsonPath(key: []const u8) bool {
    return std.mem.endsWith(u8, key, ".json") and !isGitConfigPath(key);
}

const testing = std.testing;

test "resolve: structured formats by path, the json dialect by attribute" {
    try testing.expectEqual(Format.toml, resolve("config.toml", false).?);
    try testing.expectEqual(Format.json, resolve("settings.json", false).?);
    try testing.expectEqual(Format.jsonc, resolve("settings.json", true).?);
    try testing.expectEqual(Format.jsonc, resolve("tsconfig.jsonc", false).?);
    try testing.expectEqual(Format.yaml, resolve("c.yaml", false).?);
    try testing.expectEqual(Format.ini, resolve("app.ini", false).?);
    try testing.expectEqual(Format.gitconfig, resolve(".gitconfig", false).?);
    try testing.expect(resolve(".zshrc", false) == null);
}

test "Format.marker: strict JSON has none, jsonc is //, the rest #" {
    try testing.expect(Format.json.marker() == null);
    try testing.expectEqualStrings("//", Format.jsonc.marker().?);
    try testing.expectEqualStrings("#", Format.toml.marker().?);
    try testing.expectEqualStrings("#", Format.ini.marker().?);
}

test "iniDialect: a generic INI file accepts a bare key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try ini.parse(arena.allocator(), "[mysqld]\nskip-networking\nport = 3306\n", .{ .dialect = iniDialect(.ini) });
}

test "isGitConfigPath: xdg config and .inc includes, nothing else" {
    try testing.expect(isGitConfigPath(".config/git/config"));
    try testing.expect(isGitConfigPath("src/.config/git/personal.inc"));
    try testing.expect(!isGitConfigPath(".config/git/README"));
    try testing.expect(!isGitConfigPath(".ssh/config"));
}
