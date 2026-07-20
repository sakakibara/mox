const std = @import("std");
const Io = std.Io;
const match = @import("match.zig");
const testing = std.testing;

const max_ignore_bytes: usize = 1 << 20;

fn readOptional(arena: std.mem.Allocator, io: Io, path: []const u8) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_ignore_bytes)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
}

/// Load and merge the repo's ignore files into one RuleSet. `.mox/ignore`
/// contributes first, root `.moxignore` last (so its rules win ties under
/// last-match-wins). A missing file contributes nothing.
pub fn load(arena: std.mem.Allocator, io: Io, repo_dir: []const u8) !match.RuleSet {
    const namespaced = try std.fs.path.join(arena, &.{ repo_dir, ".mox", "ignore" });
    const root = try std.fs.path.join(arena, &.{ repo_dir, ".moxignore" });

    var buf: std.ArrayList(u8) = .empty;
    if (try readOptional(arena, io, namespaced)) |t| {
        try buf.appendSlice(arena, t);
        try buf.append(arena, '\n');
    }
    if (try readOptional(arena, io, root)) |t| {
        try buf.appendSlice(arena, t);
        try buf.append(arena, '\n');
    }
    return match.compile(arena, buf.items);
}

pub const scaffold_moxignore: []const u8 =
    \\# mox ignore file (gitignore syntax). Paths are relative to your home dir.
    \\# These keep credentials out of a synced dotfiles repo. Delete any line
    \\# you want tracked (e.g. if your repo is private and you want secrets in it).
    \\.claude/.credentials.json
    \\.claude/*-cache.json
    \\.claude/settings.local.json
    \\.claude/projects/
    \\.claude/file-history/
    \\.claude/*.jsonl
    \\.ssh/id_*
    \\!.ssh/id_*.pub
    \\*.pem
    \\
;

/// True when a basename looks like a secret, for the non-blocking warn-on-add
/// note (Task 8). Deliberately conservative.
pub fn looksLikeSecret(basename: []const u8) bool {
    const exact = [_][]const u8{ ".credentials.json", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa" };
    for (exact) |e| if (std.mem.eql(u8, basename, e)) return true;
    const suffixes = [_][]const u8{ ".pem", ".key" };
    for (suffixes) |s| if (std.mem.endsWith(u8, basename, s)) return true;
    return false;
}

test "load: merges .mox/ignore and .moxignore, root wins ties" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = pathbuf[0..try tmp.dir.realPath(io, &pathbuf)];

    try tmp.dir.createDirPath(io, ".mox");
    try tmp.dir.writeFile(io, .{ .sub_path = ".mox/ignore", .data = "*.jsonl\n.secret\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".moxignore", .data = "!.secret\n" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const set = try load(a, io, repo);
    try testing.expect(set.isIgnored("a/b.jsonl", false)); // from .mox/ignore
    try testing.expect(!set.isIgnored(".secret", false)); // root negation wins (last)
}

test "load: missing files yield an empty (never-ignoring) set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = pathbuf[0..try tmp.dir.realPath(io, &pathbuf)];

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const set = try load(a, io, repo);
    try testing.expect(!set.isIgnored("anything", false));
}
