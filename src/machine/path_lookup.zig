const std = @import("std");
const builtin = @import("builtin");
const Env = @import("env").Env;
const dirent = @import("../source/dirent.zig");

const Io = std.Io;
const Environ = Env;

pub const Found = struct {
    name: []const u8,
    path: []const u8,
};

/// Find which of `candidates` exist on `$PATH`. Returns sorted list of names
/// that exist. All returned strings are arena-owned (duplicated).
///
/// Uses the supplied `environ` to read `$PATH`; an empty or absent `$PATH`
/// produces an empty result.
pub fn findOnPath(
    arena: std.mem.Allocator,
    io: Io,
    environ: Environ,
    candidates: []const []const u8,
) ![]const []const u8 {
    const full = try findOnPathFull(arena, io, environ, candidates);
    var names = try arena.alloc([]const u8, full.len);
    for (full, 0..) |f, i| names[i] = f.name;
    return names;
}

/// Same as `findOnPath` but also returns the absolute path of the first hit.
/// Used to populate `MachineState.tool_paths` for `<machine.tool_path.X>`
/// interpolation (mirrors chezmoi's `lookPath` template function).
pub fn findOnPathFull(
    arena: std.mem.Allocator,
    io: Io,
    environ: Environ,
    candidates: []const []const u8,
) ![]const Found {
    const path_env = environ.getAlloc(arena, "PATH") catch |e| switch (e) {
        error.EnvironmentVariableMissing => return &.{},
        else => return e,
    };
    const exts = try executableExts(arena, environ);

    // Read each PATH directory once and match its entries against the wanted
    // names, rather than probing every (name x directory x extension). The
    // watch list is ~75 names and a Windows PATH carries a PATHEXT of ~8, so
    // probing would be tens of thousands of stats per capture -- fast enough on
    // POSIX to hide, slow enough on Windows to look like a hang.
    var wanted = std.StringHashMap(usize).init(arena);
    for (candidates, 0..) |name, i| {
        try wanted.put(try foldName(arena, name), i);
    }

    const hits = try arena.alloc(?[]const u8, candidates.len);
    @memset(hits, null);

    var dirs = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (dirs.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        // Best-effort, like the `openDir` skip above: a PATH dir that will not
        // enumerate is skipped, not fatal. Sorted so a tie between two names
        // folding to one command (`git` and `git.exe`) resolves the same way
        // on every machine, rather than by filesystem order.
        const entries = dirent.sortedPath(arena, io, dir_path, .{ .iterate = true }) catch continue;
        for (entries) |entry| {
            if (entry.kind == .directory) continue;
            const folded = try foldName(arena, entry.name);

            // The entry as named (`fd`, or `starship.exe` asked for verbatim).
            if (wanted.get(folded)) |i| {
                if (hits[i] == null) hits[i] = try std.fs.path.join(arena, &.{ dir_path, entry.name });
                continue;
            }
            // On Windows, `git` is on disk as `git.exe`: match the stem when
            // the extension is one the shell would have run.
            if (try stemForExecutable(arena, folded, exts)) |stem| {
                if (wanted.get(stem)) |i| {
                    if (hits[i] == null) hits[i] = try std.fs.path.join(arena, &.{ dir_path, entry.name });
                }
            }
        }
    }

    var found: std.ArrayList(Found) = .empty;
    for (candidates, 0..) |name, i| {
        if (hits[i]) |path| {
            try found.append(arena, .{ .name = try arena.dupe(u8, name), .path = path });
        }
    }

    const slice = try found.toOwnedSlice(arena);
    std.mem.sort(Found, slice, {}, struct {
        fn lessThan(_: void, a: Found, b: Found) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return slice;
}

/// The extensions an executable may carry, in the order the shell would try
/// them. Empty on POSIX, where a program is its own name. On Windows a bare
/// `git` lives on disk as `git.exe`, so a lookup that only tried the name
/// verbatim would find nothing and quietly report the tool as absent -- taking
/// every `tool=` axis gated on it down with it. PATHEXT names the extensions;
/// its documented default stands in when it is unset.
fn executableExts(arena: std.mem.Allocator, environ: Environ) ![]const []const u8 {
    if (builtin.os.tag != .windows) return &.{};

    const raw = environ.getAlloc(arena, "PATHEXT") catch "";
    const spec = if (raw.len > 0) raw else ".COM;.EXE;.BAT;.CMD";

    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, spec, ';');
    while (it.next()) |ext| {
        const trimmed = std.mem.trim(u8, ext, " \t\r\n");
        if (trimmed.len == 0) continue;
        try out.append(arena, trimmed);
    }
    return out.toOwnedSlice(arena);
}

/// A name in the form both sides of a comparison agree on. Windows filenames
/// are case-insensitive, so `Git.EXE` must match a `git` the watch list asked
/// for; POSIX names are compared as written.
fn foldName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (builtin.os.tag != .windows) return name;
    const out = try arena.dupe(u8, name);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// The name with its executable extension removed, or null when it carries
/// none that the shell would have run. Always null on POSIX, where a program
/// is its own name.
fn stemForExecutable(arena: std.mem.Allocator, folded: []const u8, exts: []const []const u8) !?[]const u8 {
    _ = arena;
    for (exts) |ext| {
        if (ext.len < folded.len and std.ascii.endsWithIgnoreCase(folded, ext)) {
            return folded[0 .. folded.len - ext.len];
        }
    }
    return null;
}

test "findOnPath: empty candidate list returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try findOnPath(
        arena.allocator(),
        std.testing.io,
        Env{ .process = std.testing.environ },
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "findOnPath: nonexistent name not in result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_][]const u8{"definitely-not-a-real-binary-xyz"};
    const found = try findOnPath(
        arena.allocator(),
        std.testing.io,
        Env{ .process = std.testing.environ },
        &candidates,
    );
    try std.testing.expectEqual(@as(usize, 0), found.len);
}
