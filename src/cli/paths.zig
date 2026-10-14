const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("env");
const trigger_state = @import("../trigger/state.zig");
const Env = env_mod.Env;
const dirs = env_mod.dirs;

pub const Paths = struct {
    home: []const u8,
    /// False when the environment named no home and `home` holds the
    /// placeholder that keeps the rest resolvable. A command that acts on a
    /// live path must refuse rather than take the filesystem root for the
    /// user's home and capture whatever sits under it.
    home_named: bool,
    repo_dir: []const u8,
    state_dir: []const u8,
    private_dir: []const u8,
    triggers_path: []const u8,
    facts_path: []const u8,
};

/// The home in the one spelling everything else must agree on.
///
/// Every managed file's live path is this home joined with the file's key, and
/// a path argument is compared against that string exactly. `std.fs.path`
/// canonicalizes as it resolves -- upper-casing a Windows drive letter, among
/// other things -- so a home spelled `c:\Users\me` would have the walk key a
/// file `c:\...` while every argument resolved to `C:\...`, and a managed
/// file would read as unmanaged. `USERPROFILE` is never spelled that way, but
/// a hand-set `HOME` may be. Canonicalizing here, once, is what makes the two
/// sides agree by construction rather than by luck.
fn canonical(arena: std.mem.Allocator, home: []const u8, os_tag: std.Target.Os.Tag) []const u8 {
    const resolved = if (os_tag == .windows)
        std.fs.path.resolveWindows(arena, &.{home})
    else
        std.fs.path.resolvePosix(arena, &.{home});
    // A home that will not resolve is left as it came: it is the caller's
    // string either way, and refusing here would trade a working odd spelling
    // for no home at all.
    return resolved catch home;
}

/// Resolve all mox paths from the process environment for the host OS.
/// All returned strings are arena-owned.
pub fn resolve(arena: std.mem.Allocator, env: Env) !Paths {
    return resolveFrom(arena, env, builtin.os.tag);
}

/// OS-parameterized core, so path resolution stays table-testable across
/// linux/macos/windows env sets from whichever host runs the tests.
///
/// Where each base directory lives is `env.dirs`' business (XDG on every OS,
/// `%LOCALAPPDATA%` on Windows, `~/.local` and `~/.config` on POSIX); what mox
/// nests inside it is this function's.
pub fn resolveFrom(arena: std.mem.Allocator, env: Env, os_tag: std.Target.Os.Tag) !Paths {
    // A machine with no home named at all still gets a resolvable (if useless)
    // root rather than an error, so `mox --help` runs anywhere.
    //
    // `homeFor`, not `home`: this function is parameterized by `os_tag` so a
    // test can pin every platform's answer from whichever host runs it, and
    // resolving the home against the HOST instead would leave that promise
    // half-kept. It matters -- on Windows a POSIX-form `HOME` names no stable
    // location and is rejected in favour of `USERPROFILE`, so a linux-tagged
    // resolution run from a Windows runner would otherwise find no home at all.
    var home_named = true;
    const home = canonical(arena, dirs.homeFor(arena, env, os_tag) catch blk: {
        home_named = false;
        break :blk try arena.dupe(u8, "/");
    }, os_tag);

    const repo_dir = blk: {
        if (env.get(arena, "MOX_REPO")) |v| break :blk v;
        const base = try dirs.baseDirIn(arena, env, os_tag, .data, home);
        break :blk try std.fs.path.join(arena, &.{ base, "mox", "dotfiles" });
    };

    const state_dir = blk: {
        if (env.get(arena, "MOX_STATE_DIR")) |v| break :blk v;
        const base = try dirs.baseDirIn(arena, env, os_tag, .state, home);
        break :blk try std.fs.path.join(arena, &.{ base, "mox" });
    };

    const private_dir = try std.fs.path.join(arena, &.{ state_dir, "private" });
    const triggers_path = try std.fs.path.join(arena, &.{ state_dir, trigger_state.state_basename });

    const config_base = try dirs.baseDirIn(arena, env, os_tag, .config, home);
    const facts_path = try std.fs.path.join(arena, &.{ config_base, "mox", "facts.toml" });

    return .{
        .home = home,
        .home_named = home_named,
        .repo_dir = repo_dir,
        .state_dir = state_dir,
        .private_dir = private_dir,
        .triggers_path = triggers_path,
        .facts_path = facts_path,
    };
}

/// `p` with a relative repo and a relative state directory made absolute
/// against `cwd`, and the paths under the state directory with it, so every
/// message, part, sibling and printed command names one place whatever
/// directory a later step runs in. On Windows, a path relative to a drive's
/// current directory (`C:x`) or to the current drive's root (`\x`) names
/// no one place: it is refused, with `why` naming the variable.
pub fn absolutePaths(arena: std.mem.Allocator, p: Paths, cwd: []const u8, why: *?[]const u8) !Paths {
    return absolutePathsFor(arena, p, cwd, builtin.os.tag, why);
}

fn absolutePathsFor(arena: std.mem.Allocator, p: Paths, cwd: []const u8, os_tag: std.Target.Os.Tag, why: *?[]const u8) !Paths {
    var out = p;
    out.repo_dir = try underCwd(arena, cwd, p.repo_dir, os_tag, "MOX_REPO", why);
    const state_dir = try underCwd(arena, cwd, p.state_dir, os_tag, "MOX_STATE_DIR", why);
    if (state_dir.ptr == p.state_dir.ptr) return out;
    out.state_dir = state_dir;
    out.private_dir = try std.fs.path.join(arena, &.{ out.state_dir, "private" });
    out.triggers_path = try std.fs.path.join(arena, &.{ out.state_dir, trigger_state.state_basename });
    return out;
}

/// `path` as the kernel resolves it from `cwd`: an absolute path as given,
/// else `cwd` joined with it, dropping only `.` segments and repeated
/// separators. A `..` is kept, since it steps out of whatever a symlink
/// before it names, which a lexical collapse would get wrong.
fn underCwd(arena: std.mem.Allocator, cwd: []const u8, path: []const u8, os_tag: std.Target.Os.Tag, name: []const u8, why: *?[]const u8) ![]const u8 {
    const seps: []const u8 = if (os_tag == .windows) "/\\" else "/";
    if (os_tag == .windows) switch (std.fs.path.getWin32PathType(u8, path)) {
        .relative => {},
        .drive_relative, .rooted => {
            why.* = try std.fmt.allocPrint(arena, "{s} is {s}, which names a place relative to a drive's current directory or root; set it to an absolute path, such as C:\\Users\\you\\mox", .{ name, path });
            return error.PathNotAbsolute;
        },
        else => return path,
    } else if (std.fs.path.isAbsolutePosix(path)) return path;
    const sep: u8 = if (os_tag == .windows) '\\' else '/';
    const base = std.mem.trimEnd(u8, cwd, seps);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, base);
    var it = std.mem.tokenizeAny(u8, path, seps);
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        try out.append(arena, sep);
        try out.appendSlice(arena, seg);
    }
    if (out.items.len == base.len) return cwd;
    return out.items;
}

test "absolutePaths: a relative state directory, and every path under it, resolve against the cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = std.process.Environ.Map.init(a);
    try m.put("HOME", if (builtin.os.tag == .windows) "C:\\Users\\alice" else "/home/alice");
    try m.put("MOX_STATE_DIR", ".");
    var why: ?[]const u8 = null;
    const p = try absolutePaths(a, try resolveFrom(a, Env{ .map = &m }, builtin.os.tag), if (builtin.os.tag == .windows) "C:\\w\\st" else "/w/st", &why);
    const root = if (builtin.os.tag == .windows) "C:\\w\\st" else "/w/st";
    try std.testing.expectEqualStrings(root, p.state_dir);
    try expectJoined(a, &.{ root, "private" }, p.private_dir);
    try expectJoined(a, &.{ root, trigger_state.state_basename }, p.triggers_path);
}

test "absolutePaths: a relative repo resolves against the cwd, and an absolute one is kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = if (builtin.os.tag == .windows) "C:\\w\\st" else "/w/st";
    const elsewhere = if (builtin.os.tag == .windows) "C:\\r\\dots" else "/r/dots";
    var m = std.process.Environ.Map.init(a);
    try m.put("HOME", "/home/alice");
    try m.put("MOX_STATE_DIR", elsewhere);
    try m.put("MOX_REPO", "dots");
    var why: ?[]const u8 = null;
    try expectJoined(a, &.{ cwd, "dots" }, (try absolutePaths(a, try resolveFrom(a, Env{ .map = &m }, builtin.os.tag), cwd, &why)).repo_dir);
    try m.put("MOX_REPO", elsewhere);
    try std.testing.expectEqualStrings(elsewhere, (try absolutePaths(a, try resolveFrom(a, Env{ .map = &m }, builtin.os.tag), cwd, &why)).repo_dir);
}

test "underCwd: joins as the kernel resolves, keeping `..` and dropping only `.` and repeated separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: ?[]const u8 = null;
    try std.testing.expectEqualStrings("/w/lnk/../st", try underCwd(a, "/w", "lnk/../st", .linux, "MOX_STATE_DIR", &why));
    try std.testing.expectEqualStrings("/w/a/b", try underCwd(a, "/w/", "./a//./b/", .linux, "MOX_STATE_DIR", &why));
    try std.testing.expectEqualStrings("/w", try underCwd(a, "/w", ".", .linux, "MOX_STATE_DIR", &why));
    try std.testing.expectEqualStrings("/st", try underCwd(a, "/", "st", .macos, "MOX_STATE_DIR", &why));
    try std.testing.expectEqualStrings("/abs/../x", try underCwd(a, "/w", "/abs/../x", .linux, "MOX_STATE_DIR", &why));
    try std.testing.expectEqualStrings("C:\\w\\lnk\\..\\st", try underCwd(a, "C:\\w", "lnk/../st", .windows, "MOX_STATE_DIR", &why));
    try std.testing.expectEqualStrings("D:\\x", try underCwd(a, "C:\\w", "D:\\x", .windows, "MOX_STATE_DIR", &why));
    for ([_][]const u8{ "C:foo", "\\foo", "/foo" }) |bad| {
        why = null;
        try std.testing.expectError(error.PathNotAbsolute, underCwd(a, "C:\\w", bad, .windows, "MOX_REPO", &why));
        try std.testing.expect(std.mem.indexOf(u8, why.?, "MOX_REPO is ") != null);
        try std.testing.expect(std.mem.indexOf(u8, why.?, "absolute path") != null);
    }
}

test "resolve with Env{ .process = std.testing.environ }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try resolve(arena.allocator(), Env{ .process = std.testing.environ });
    try std.testing.expect(p.repo_dir.len > 0);
    try std.testing.expect(p.state_dir.len > 0);
}

/// Expected paths are built the same way the code builds them, so an
/// assertion tests which base directory was chosen rather than which
/// separator the platform uses.
fn expectJoined(a: std.mem.Allocator, parts: []const []const u8, actual: []const u8) !void {
    const want = try std.fs.path.join(a, parts);
    try std.testing.expectEqualStrings(want, actual);
}

test "resolveFrom: linux defaults root under ~/.local and ~/.config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = std.process.Environ.Map.init(arena.allocator());
    try m.put("HOME", "/home/alice");
    const p = try resolveFrom(arena.allocator(), Env{ .map = &m }, .linux);
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/home/alice", p.home);
    try expectJoined(a, &.{ "/home/alice", ".local", "share", "mox", "dotfiles" }, p.repo_dir);
    try expectJoined(a, &.{ "/home/alice", ".local", "state", "mox" }, p.state_dir);
    try expectJoined(a, &.{ "/home/alice", ".config", "mox", "facts.toml" }, p.facts_path);
}

test "resolveFrom: macos honors XDG_* over home defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = std.process.Environ.Map.init(arena.allocator());
    try m.put("HOME", "/Users/alice");
    try m.put("XDG_CONFIG_HOME", "/Users/alice/xdgcfg");
    const p = try resolveFrom(arena.allocator(), Env{ .map = &m }, .macos);
    // XDG_CONFIG_HOME wins for facts; unset XDG_DATA_HOME falls back to ~/.local.
    const a = arena.allocator();
    try expectJoined(a, &.{ "/Users/alice/xdgcfg", "mox", "facts.toml" }, p.facts_path);
    try expectJoined(a, &.{ "/Users/alice", ".local", "share", "mox", "dotfiles" }, p.repo_dir);
}

test "resolveFrom: windows roots under LOCALAPPDATA with USERPROFILE home" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = std.process.Environ.Map.init(arena.allocator());
    const local = "C:\\Users\\bob\\AppData\\Local";
    try m.put("USERPROFILE", "C:\\Users\\bob");
    try m.put("LOCALAPPDATA", local);
    const p = try resolveFrom(arena.allocator(), Env{ .map = &m }, .windows);
    try std.testing.expectEqualStrings("C:\\Users\\bob", p.home);
    try std.testing.expect(std.mem.startsWith(u8, p.repo_dir, local));
    try std.testing.expect(std.mem.endsWith(u8, p.repo_dir, "dotfiles"));
    try std.testing.expect(std.mem.startsWith(u8, p.state_dir, local));
    try std.testing.expect(std.mem.endsWith(u8, p.state_dir, "mox"));
    try std.testing.expect(std.mem.startsWith(u8, p.facts_path, local));
}

test "resolveFrom: an empty XDG var falls back to the home default, not cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = std.process.Environ.Map.init(arena.allocator());
    try m.put("HOME", "/home/alice");
    // Present but empty: must be treated as unset.
    try m.put("XDG_STATE_HOME", "");
    try m.put("XDG_DATA_HOME", "");
    const p = try resolveFrom(arena.allocator(), Env{ .map = &m }, .linux);
    try expectJoined(arena.allocator(), &.{ "/home/alice", ".local", "state", "mox" }, p.state_dir);
    try expectJoined(arena.allocator(), &.{ "/home/alice", ".local", "share", "mox", "dotfiles" }, p.repo_dir);
}

test "resolveFrom: a home's drive letter is canonicalized, so lookups agree with the walk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = std.process.Environ.Map.init(arena.allocator());
    // Hand-set, lower-case drive: a legal Windows home that `std.fs.path`
    // would upper-case the moment any argument was resolved through it.
    try m.put("HOME", "c:\\Users\\bob");
    const p = try resolveFrom(arena.allocator(), Env{ .map = &m }, .windows);
    try std.testing.expectEqualStrings("C:\\Users\\bob", p.home);
    try std.testing.expect(p.home_named);
}

test "resolveFrom: a trailing separator on the home is normalized away" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = std.process.Environ.Map.init(arena.allocator());
    try m.put("HOME", "/home/alice/");
    const p = try resolveFrom(arena.allocator(), Env{ .map = &m }, .linux);
    try std.testing.expectEqualStrings("/home/alice", p.home);
}

test "resolveFrom: windows still honors XDG_DATA_HOME when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = std.process.Environ.Map.init(arena.allocator());
    try m.put("USERPROFILE", "C:\\Users\\bob");
    try m.put("LOCALAPPDATA", "C:\\Users\\bob\\AppData\\Local");
    try m.put("XDG_DATA_HOME", "D:\\xdg");
    const p = try resolveFrom(arena.allocator(), Env{ .map = &m }, .windows);
    try std.testing.expect(std.mem.startsWith(u8, p.repo_dir, "D:\\xdg"));
}
