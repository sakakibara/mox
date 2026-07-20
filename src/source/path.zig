//! Source-tree paths.
//!
//! mox deals in two kinds of path, and they are not interchangeable:
//!
//!   - a *key*: a repo-relative source path (`src/.config/nvim/init.lua`) or a
//!     home-relative live path (`.config/nvim/init.lua`). Keys are compared,
//!     prefix-matched, and persisted -- and the source tree they name is shared
//!     across every machine. A key is therefore ALWAYS `/`-separated, on every
//!     platform, so that the same file has the same key wherever it was written.
//!
//!   - a *filesystem path*: an absolute path handed to the OS. It uses the
//!     platform's own separator and is built with `std.fs.path.join`.
//!
//! Building a key with `std.fs.path.join` is a bug: it yields `src\.zshrc` on
//! Windows, which then matches no `src/` prefix and equals no key any other
//! machine wrote.

const std = @import("std");
const env_path = @import("env").path;

pub const PathError = error{
    NotInSourceTree,
    OutOfMemory,
};

/// The separator inside a key. Never the platform's.
pub const key_sep = env_path.rel_sep;

/// Join `parts` into a key. Always `/`-separated.
pub const joinKey = env_path.joinSegments;

/// Rewrite a filesystem path's separators into key form.
pub const toKey = env_path.toRel;

/// Convert a source-tree key (e.g. `src/.config/nvim/init.lua`) to its live
/// filesystem path (e.g. `/home/me/.config/nvim/init.lua`, or
/// `C:\Users\me\.config\nvim\init.lua`). The returned slice is allocator-owned.
///
/// `source_path` must be a key starting with the literal `src/` prefix.
pub fn toLivePath(allocator: std.mem.Allocator, source_path: []const u8, home_dir: []const u8) PathError![]u8 {
    const prefix = "src/";
    if (!std.mem.startsWith(u8, source_path, prefix)) return error.NotInSourceTree;
    const tail = source_path[prefix.len..];
    return env_path.joinRel(allocator, home_dir, tail);
}

/// Join a key onto a filesystem base, yielding a native path.
pub const joinKeyOnto = env_path.joinRel;

/// A live filesystem path as a home-relative key, or null when it does not sit
/// under `home`.
pub const liveKeyUnderHome = env_path.relUnder;

/// True when `key` would escape its base once joined onto a directory: it is
/// absolute (leading separator) or any `/`- or `\`-separated segment is `..`.
/// `relUnder` matches HOME textually and `std.fs.path.join` does not normalize,
/// so `mox add ~/../../etc/hosts` yields a key like `../../etc/hosts` that
/// resolves outside the source tree. A command building a filesystem path from
/// a user-derived key (add, mv) must refuse a key for which this is true.
pub fn keyEscapes(key: []const u8) bool {
    if (key.len == 0) return false;
    // Absolute on POSIX (leading `/`) or Windows (leading `\`, UNC `\\`, or a
    // `X:` drive). Both separators are checked on every platform: the key may be
    // consumed on a host whose OS honors the one this host treats as literal.
    if (key[0] == '/' or key[0] == '\\') return true;
    if (key.len >= 2 and std.ascii.isAlphabetic(key[0]) and key[1] == ':') return true;
    var it = std.mem.tokenizeAny(u8, key, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

test "keyEscapes: rejects parent refs and absolute keys, accepts normal keys" {
    try testing.expect(keyEscapes("../../etc/hosts"));
    try testing.expect(keyEscapes(".config/../../../etc/x"));
    try testing.expect(keyEscapes("/etc/hosts"));
    try testing.expect(keyEscapes("..\\..\\windows")); // backslash sep + parent ref
    try testing.expect(keyEscapes("C:\\Users\\x")); // drive-letter absolute
    try testing.expect(keyEscapes("\\\\host\\share")); // UNC
    try testing.expect(!keyEscapes(".config/nvim/init.lua"));
    try testing.expect(!keyEscapes(".zshrc"));
    try testing.expect(!keyEscapes("..foo/bar")); // `..foo` is a name, not a parent ref
}

/// A live filesystem path as a home-relative key, or the path itself (as a
/// key, minus any leading separator) when it lies outside home. The result is a
/// key, so it must not carry a platform separator.
pub fn liveKeyRelToHome(allocator: std.mem.Allocator, home: []const u8, path: []const u8) error{OutOfMemory}![]u8 {
    if (try liveKeyUnderHome(allocator, home, path)) |k| return k;
    return toKey(allocator, path);
}

const testing = std.testing;

test "toLivePath: simple" {
    const live = try toLivePath(testing.allocator, "src/.zshrc", "/home/me");
    defer testing.allocator.free(live);

    const want = try std.fs.path.join(testing.allocator, &.{ "/home/me", ".zshrc" });
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, live);
}

test "toLivePath: nested key yields a native path" {
    const arena_alloc = testing.allocator;
    const live = try toLivePath(arena_alloc, "src/.config/foo/bar.lua", "/home/me");
    defer arena_alloc.free(live);

    const want = try std.fs.path.join(arena_alloc, &.{ "/home/me", ".config", "foo", "bar.lua" });
    defer arena_alloc.free(want);
    try testing.expectEqualStrings(want, live);
}

test "toLivePath: not in src tree errors" {
    const result = toLivePath(testing.allocator, "scripts/foo.sh", "/home/me");
    try testing.expectError(error.NotInSourceTree, result);
}

test "joinKey: always slash-separated, skipping empty parts" {
    const k = try joinKey(testing.allocator, &.{ "", "src", ".config", "git", "config" });
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("src/.config/git/config", k);
}

test "toKey: rewrites the platform separator" {
    const native = try std.fs.path.join(testing.allocator, &.{ "src", ".config", "git" });
    defer testing.allocator.free(native);

    const k = try toKey(testing.allocator, native);
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("src/.config/git", k);
}

test "liveKeyRelToHome: strips home and yields a slash key on every platform" {
    const home = try std.fs.path.join(testing.allocator, &.{ "/home", "me" });
    defer testing.allocator.free(home);
    const live = try std.fs.path.join(testing.allocator, &.{ home, ".config", "git", "config" });
    defer testing.allocator.free(live);

    const k = try liveKeyRelToHome(testing.allocator, home, live);
    defer testing.allocator.free(k);
    try testing.expectEqualStrings(".config/git/config", k);
}

test "liveKeyRelToHome: a path outside home is kept whole" {
    const k = try liveKeyRelToHome(testing.allocator, "/home/me", "/etc/hosts");
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("/etc/hosts", k);
}
