const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("env");
const Env = env_mod.Env;
const dirs = env_mod.dirs;

pub const Paths = struct {
    home: []const u8,
    repo_dir: []const u8,
    state_dir: []const u8,
    private_dir: []const u8,
    triggers_path: []const u8,
    snapshots_dir: []const u8,
    facts_path: []const u8,
};

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
    const home = dirs.home(arena, env) catch try arena.dupe(u8, "/");

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
    const triggers_path = try std.fs.path.join(arena, &.{ state_dir, "triggers.txt" });
    const snapshots_dir = try std.fs.path.join(arena, &.{ state_dir, "snapshots" });

    const config_base = try dirs.baseDirIn(arena, env, os_tag, .config, home);
    const facts_path = try std.fs.path.join(arena, &.{ config_base, "mox", "facts.toml" });

    return .{
        .home = home,
        .repo_dir = repo_dir,
        .state_dir = state_dir,
        .private_dir = private_dir,
        .triggers_path = triggers_path,
        .snapshots_dir = snapshots_dir,
        .facts_path = facts_path,
    };
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
