//! Last-applied content state.
//!
//! mox records the sha256 of every regular file it writes, so a later apply
//! can tell "the live file still holds exactly what mox wrote" (safe to
//! overwrite) apart from user drift (refused without --force, so live edits
//! are never silently destroyed). One record file per live path lives under
//! `<state>/applied/`, named by the sha256 of the live path itself; the
//! record holds the content hash in hex plus the live path for
//! debuggability.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const hash_hex_len = Sha256.digest_length * 2;

pub const Disposition = enum {
    /// No live file exists at the target path.
    fresh_write,
    /// Live content already equals the composed output.
    unchanged,
    /// Live content differs from composed but matches the last-applied
    /// record: everything on disk came from mox, overwriting loses nothing.
    safe_overwrite,
    /// Live content differs from composed and is NOT what mox last wrote
    /// (edited since, or never recorded). Refuse unless forced.
    drift,
};

/// Decide what an apply may do with one file, from the last-applied record
/// (null when none exists), the current live content (null when the live
/// file is absent), and the composed output.
pub fn classify(recorded: ?[hash_hex_len]u8, live: ?[]const u8, composed: []const u8) Disposition {
    const live_bytes = live orelse return .fresh_write;
    if (std.mem.eql(u8, live_bytes, composed)) return .unchanged;
    const rec = recorded orelse return .drift;
    const live_hash = contentHashHex(live_bytes);
    return if (std.mem.eql(u8, &rec, &live_hash)) .safe_overwrite else .drift;
}

pub fn contentHashHex(content: []const u8) [hash_hex_len]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Read the recorded content hash for `live_path`, or null when this path
/// has never been recorded. A malformed record is treated as absent (the
/// conservative direction: absent + differing live content = drift).
pub fn read(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !?[hash_hex_len]u8 {
    const rec_path = try recordPath(arena, state_dir, live_path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, rec_path, arena, .limited(4096)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    if (bytes.len < hash_hex_len) return null;
    var hash: [hash_hex_len]u8 = undefined;
    @memcpy(&hash, bytes[0..hash_hex_len]);
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return hash;
}

/// Record `content` as the bytes mox just wrote to `live_path`.
pub fn record(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8, content: []const u8) !void {
    const rec_path = try recordPath(arena, state_dir, live_path);
    if (std.fs.path.dirname(rec_path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }
    const hash = contentHashHex(content);
    const body = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ &hash, live_path });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rec_path, .data = body });
}

fn recordPath(arena: std.mem.Allocator, state_dir: []const u8, live_path: []const u8) ![]u8 {
    const name = contentHashHex(live_path);
    return std.fs.path.join(arena, &.{ state_dir, "applied", &name });
}

const max_content_bytes: usize = 64 * 1024 * 1024;

/// Store the exact composed bytes mox wrote to `live_path` under
/// `<state>/applied-content/`, so a later `mox commit` can diff the user's
/// live edits against the last-applied content (the hash record alone can
/// only detect drift, not attribute it).
pub fn recordContent(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8, content: []const u8) !void {
    const path = try contentPath(arena, state_dir, live_path);
    if (std.fs.path.dirname(path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

/// Read the last-applied content for `live_path`, or null when none exists.
pub fn readContent(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !?[]const u8 {
    const path = try contentPath(arena, state_dir, live_path);
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_content_bytes)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

fn contentPath(arena: std.mem.Allocator, state_dir: []const u8, live_path: []const u8) ![]u8 {
    const name = contentHashHex(live_path);
    return std.fs.path.join(arena, &.{ state_dir, "applied-content", &name });
}

const max_symlink_target_bytes: usize = 64 * 1024;

/// Record the symlink `target` mox last materialized at `live_path`, under
/// `<state>/applied-symlink/`. Lets a later apply tell "mox wrote this link
/// (source target changed, safe to update)" from "the user put something here"
/// (drift), mirroring the content-hash record for regular files.
pub fn recordSymlink(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8, target: []const u8) !void {
    const path = try symlinkPath(arena, state_dir, live_path);
    if (std.fs.path.dirname(path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = target });
}

/// Read the last-applied symlink target for `live_path`, or null when none.
pub fn readSymlink(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !?[]const u8 {
    const path = try symlinkPath(arena, state_dir, live_path);
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_symlink_target_bytes)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

fn symlinkPath(arena: std.mem.Allocator, state_dir: []const u8, live_path: []const u8) ![]u8 {
    const name = contentHashHex(live_path);
    return std.fs.path.join(arena, &.{ state_dir, "applied-symlink", &name });
}

/// Delete every last-applied record for `live_path` (content hash, content
/// cache, and symlink target). Best-effort: an absent record is not an error.
/// Used when mox stops tracking a path (a generator leaf pruned away) so a
/// future unrelated file at the same path is not mistaken for mox-written.
pub fn forget(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, try recordPath(arena, state_dir, live_path)) catch {};
    Io.Dir.cwd().deleteFile(io, try contentPath(arena, state_dir, live_path)) catch {};
    Io.Dir.cwd().deleteFile(io, try symlinkPath(arena, state_dir, live_path)) catch {};
}

/// What currently occupies a live path, inspected without following symlinks.
pub const SymSite = union(enum) {
    absent,
    symlink: []const u8,
    directory,
    /// A regular file or any other non-symlink, non-directory entry.
    other,
};

/// Inspect `live_path` without dereferencing a symlink there. A read/stat
/// failure other than "absent" is reported as `.other` so it is treated as
/// drift (protected), never as an empty/absent path.
pub fn inspectSymSite(io: Io, arena: std.mem.Allocator, live_path: []const u8) SymSite {
    const st = Io.Dir.cwd().statFile(io, live_path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return .absent,
        else => return .other,
    };
    return switch (st.kind) {
        .sym_link => blk: {
            // A target may be up to the platform's path max; a smaller buffer
            // would truncate a long link and misclassify it as drift.
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = Io.Dir.cwd().readLink(io, live_path, &buf) catch break :blk SymSite.other;
            break :blk .{ .symlink = arena.dupe(u8, buf[0..n]) catch return .other };
        },
        .directory => .directory,
        else => .other,
    };
}

/// Compare two symlink targets. On Windows the OS stores a link target with
/// backslash separators, so a forward-slash source (`/tmp/x`, the portable form
/// dotfiles are written in) reads back as `\tmp\x`; treating `\` and `/` as
/// equivalent there keeps drift detection from firing on every apply. On POSIX
/// `\` is an ordinary target byte, so the compare is exact.
pub fn sameSymlinkTarget(a: []const u8, b: []const u8) bool {
    if (builtin.os.tag != .windows) return std.mem.eql(u8, a, b);
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na = if (ca == '\\') '/' else ca;
        const nb = if (cb == '\\') '/' else cb;
        if (na != nb) return false;
    }
    return true;
}

test "classify: no live file is a fresh write" {
    try std.testing.expectEqual(Disposition.fresh_write, classify(null, null, "new\n"));
}

test "classify: live equal to composed is unchanged regardless of record" {
    try std.testing.expectEqual(Disposition.unchanged, classify(null, "same\n", "same\n"));
    try std.testing.expectEqual(Disposition.unchanged, classify(contentHashHex("same\n"), "same\n", "same\n"));
}

test "classify: live matching the record is a safe overwrite" {
    const rec = contentHashHex("old composed\n");
    try std.testing.expectEqual(Disposition.safe_overwrite, classify(rec, "old composed\n", "new composed\n"));
}

test "classify: live differing from the record is drift" {
    const rec = contentHashHex("old composed\n");
    try std.testing.expectEqual(Disposition.drift, classify(rec, "user edited\n", "new composed\n"));
}

test "classify: no record and differing live content is drift" {
    try std.testing.expectEqual(Disposition.drift, classify(null, "hand-written\n", "composed\n"));
}

fn stateDirAbs(alloc: std.mem.Allocator, io: Io, sub_path: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, alloc);
    return std.fs.path.join(alloc, &.{ cwd, ".zig-cache", "tmp", sub_path, "state" });
}

test "recordContent then readContent round-trips the exact bytes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    const content = "export EDITOR=nvim\nexport PAGER=less\n";
    try recordContent(a, io, state_dir, "/home/me/.zshrc", content);

    const got = try readContent(a, io, state_dir, "/home/me/.zshrc");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(content, got.?);
    // A path never recorded reads back null.
    try std.testing.expect(try readContent(a, io, state_dir, "/home/me/.other") == null);
}

test "recordSymlink then readSymlink round-trips the target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    try recordSymlink(a, io, state_dir, "/home/me/.config/nvim", "/repo/nvim");
    const got = try readSymlink(a, io, state_dir, "/home/me/.config/nvim");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("/repo/nvim", got.?);
    try std.testing.expect(try readSymlink(a, io, state_dir, "/home/me/.other") == null);
}
