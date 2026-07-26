const std = @import("std");

const Io = std.Io;

const tmp_suffix: []const u8 = ".mox-tmp";

/// The unix mode to carry over when copying an existing file. A filesystem
/// with no mode bits (Windows) exposes no mode to read, so its files take the
/// 0o644 default; a restrictive mode there comes from `.mox/attributes.toml`.
pub fn modeOf(permissions: Io.File.Permissions) u32 {
    if (Io.File.Permissions.has_executable_bit) {
        return @intCast(permissions.toMode() & 0o777);
    }
    return 0o644;
}

/// The mode to write for a regular file, shared by apply and export.
///
/// An explicit `.mox/attributes.toml` mode is applied exactly (it wins). With no
/// explicit mode, a file whose composition resolved a dedicated-manager
/// (op://|pass://) secret must be owner-only so its cleartext is not
/// world-readable: apply 0600 -- but the auto choice is a FLOOR, not an exact
/// value, so a live file the user already made at least as private (no group or
/// other bits, e.g. a hand-set 0400) is respected rather than loosened.
/// `live_mode` is the current mode of the target, or null for a fresh write.
/// Ambiguous schemes (env/file/cmd) never trigger the restriction.
pub fn secretRestrictedMode(manager_secret: bool, mode_explicit: bool, composed_mode: u32, live_mode: ?u32) u32 {
    if (mode_explicit or !manager_secret) return composed_mode;
    if (live_mode) |m| {
        if (m & 0o077 == 0) return m; // already owner-only -> respect (0400/0600/0700)
    }
    return 0o600;
}

test "secretRestrictedMode: manager secret floors at owner-only, explicit wins" {
    // Manager secret, no explicit, no/loose live mode -> 0600.
    try std.testing.expectEqual(@as(u32, 0o600), secretRestrictedMode(true, false, 0o644, null));
    try std.testing.expectEqual(@as(u32, 0o600), secretRestrictedMode(true, false, 0o644, 0o644));
    try std.testing.expectEqual(@as(u32, 0o600), secretRestrictedMode(true, false, 0o644, 0o640));
    // A live mode already at least as private is respected (not loosened).
    try std.testing.expectEqual(@as(u32, 0o400), secretRestrictedMode(true, false, 0o644, 0o400));
    try std.testing.expectEqual(@as(u32, 0o600), secretRestrictedMode(true, false, 0o644, 0o600));
    // An explicit attribute mode always wins, even looser and even for a secret.
    try std.testing.expectEqual(@as(u32, 0o644), secretRestrictedMode(true, true, 0o644, 0o600));
    // No manager secret -> the composed mode stands (a cmd:/env: value).
    try std.testing.expectEqual(@as(u32, 0o644), secretRestrictedMode(false, false, 0o644, 0o644));
    try std.testing.expectEqual(@as(u32, 0o755), secretRestrictedMode(false, false, 0o755, null));
}

/// Set the unix mode of an existing path in place. A no-op on a filesystem
/// with no mode bits (Windows), where a restrictive mode is unenforceable and
/// comes from `.mox/attributes.toml` only. Used to heal mode-only drift on a
/// file whose content already matches (so `writeAtomic` is not otherwise run),
/// e.g. a 0600 secret a tool chmod'd to 0644.
pub fn setMode(live_path: []const u8, mode: u32) !void {
    if (!Io.File.Permissions.has_executable_bit) return;
    var path_z_buf: [4096]u8 = undefined;
    if (live_path.len + 1 > path_z_buf.len) return error.PathTooLong;
    @memcpy(path_z_buf[0..live_path.len], live_path);
    path_z_buf[live_path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_z_buf);
    if (std.c.chmod(path_z, @intCast(mode)) != 0) return error.ChmodFailed;
}

/// Identity of a live file at apply's initial read, for the partial write's
/// post-fsync recheck: any change to (inode, size, mtime) since the parse
/// means an external writer raced the apply.
pub const LiveStat = struct {
    inode: Io.File.INode,
    size: u64,
    mtime_ns: i96,
};

/// Stat `live_path` without following a symlink, or null when absent (or
/// unstattable -- the caller's recheck then refuses, the safe direction).
pub fn liveStat(io: Io, live_path: []const u8) ?LiveStat {
    const st = Io.Dir.cwd().statFile(io, live_path, .{ .follow_symlinks = false }) catch return null;
    return .{ .inode = st.inode, .size = st.size, .mtime_ns = st.mtime.nanoseconds };
}

pub const ResolveLiveError = error{ OutOfMemory, DanglingLink };

/// The path a partial target's byte operations run against. A live path that
/// is a symlink resolves to its FINAL target, so the read, the race stats,
/// and the atomic rename all address one inode and the user's link
/// arrangement survives the write -- renaming onto the link path itself would
/// replace the link with a regular file while the target keeps stale bytes.
/// A plain or absent live path is returned unchanged; a link whose target
/// does not resolve is refused (`error.DanglingLink`).
pub fn resolvePartialLive(alloc: std.mem.Allocator, io: Io, live_path: []const u8) ResolveLiveError![]const u8 {
    const st = Io.Dir.cwd().statFile(io, live_path, .{ .follow_symlinks = false }) catch return live_path;
    if (st.kind != .sym_link) return live_path;
    return Io.Dir.cwd().realPathFileAlloc(io, live_path, alloc) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.DanglingLink,
    };
}

const Recheck = union(enum) {
    /// Whole-file path: the caller's own TOCTOU re-read guards the window.
    none,
    /// Partial creation: the live path must still be absent at rename time.
    absent,
    /// Partial patch: the live file must still match the initial read.
    stat: LiveStat,
};

/// Write `content` to `live_path` atomically with the requested unix mode:
/// write to a `.mox-tmp` sidecar, chmod, then rename to the target. Creates
/// parent directories as needed.
pub fn writeAtomic(io: Io, live_path: []const u8, content: []const u8, mode: u32) !void {
    return writeAtomicImpl(io, live_path, content, mode, .none);
}

/// `writeAtomic` with the partial-apply race discipline: after the temp
/// file's fsync, immediately before the rename, re-stat the live path and
/// refuse (removing the temp file) when it changed since `expected` was
/// captured -- a program's write during mox's window is never silently
/// destroyed. `expected` null means the live path was absent at read time
/// and must still be absent.
pub fn writeAtomicPartial(io: Io, live_path: []const u8, content: []const u8, mode: u32, expected: ?LiveStat) !void {
    return writeAtomicImpl(io, live_path, content, mode, if (expected) |e| .{ .stat = e } else .absent);
}

fn writeAtomicImpl(io: Io, live_path: []const u8, content: []const u8, mode: u32, recheck: Recheck) !void {
    // Create parent directory if needed.
    if (std.fs.path.dirname(live_path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }

    // Build the temp path in a fixed buffer (most paths fit easily).
    var tmp_buf: [4096]u8 = undefined;
    if (live_path.len + tmp_suffix.len > tmp_buf.len) return error.PathTooLong;
    @memcpy(tmp_buf[0..live_path.len], live_path);
    @memcpy(tmp_buf[live_path.len..][0..tmp_suffix.len], tmp_suffix);
    const tmp_path = tmp_buf[0 .. live_path.len + tmp_suffix.len];

    // Write content to tmp, then set the requested mode before rename so
    // the file appears at the target path with the correct permissions
    // atomically.
    {
        var f = try Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, content);
        // Flush the data to disk before the rename so a crash cannot leave the
        // target (and, via snapshot.save, its snapshot) renamed-but-empty --
        // which would destroy both the live file and its only backup.
        f.sync(io) catch {};
    }
    // chmod after close to enforce the exact mode regardless of umask.
    // Zig 0.16's std.posix doesn't expose chmod; std.c.chmod is the
    // cross-POSIX path (linux + darwin + BSDs). A discarded failure would
    // leave a restrictive-mode file (0600/0444) at the umask default (e.g.
    // 0644), exposing a secret: on failure, remove the temp file and fail the
    // write rather than materializing it with the wrong permissions.
    var path_z_buf: [4096]u8 = undefined;
    if (tmp_path.len + 1 > path_z_buf.len) return error.PathTooLong;
    @memcpy(path_z_buf[0..tmp_path.len], tmp_path);
    path_z_buf[tmp_path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_z_buf);
    if (std.c.chmod(path_z, @intCast(mode)) != 0) {
        Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return error.ChmodFailed;
    }

    // Post-fsync, pre-rename recheck (partial targets only): the candidate
    // was spliced from a parse of the live file, so any live change since
    // that read would be overwritten unseen by the rename.
    switch (recheck) {
        .none => {},
        .absent => {
            if (liveStat(io, live_path) != null) {
                Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
                return error.LiveChangedDuringWrite;
            }
        },
        .stat => |expected| {
            const now = liveStat(io, live_path) orelse {
                Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
                return error.LiveChangedDuringWrite;
            };
            if (now.inode != expected.inode or now.size != expected.size or now.mtime_ns != expected.mtime_ns) {
                Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
                return error.LiveChangedDuringWrite;
            }
        },
    }

    // Atomic rename.
    try Io.Dir.rename(Io.Dir.cwd(), tmp_path, Io.Dir.cwd(), live_path, io);
}

test "writeAtomicPartial: refuses when the live file changed between read and rename" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const p = try std.fs.path.join(a, &.{ base, "target" });
    try writeAtomic(io, p, "initial\n", 0o644);
    const initial = liveStat(io, p).?;

    // Unchanged live -> the write lands.
    try writeAtomicPartial(io, p, "candidate one\n", 0o644, initial);
    const after_first = try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(4096));
    try std.testing.expectEqualStrings("candidate one\n", after_first);

    // The first write changed the stat identity; a second write against the
    // stale expectation must refuse and leave the live bytes alone.
    try std.testing.expectError(
        error.LiveChangedDuringWrite,
        writeAtomicPartial(io, p, "candidate two\n", 0o644, initial),
    );
    const still = try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(4096));
    try std.testing.expectEqualStrings("candidate one\n", still);
    // The refused write's temp file is cleaned up.
    const tmp_p = try std.mem.concat(a, u8, &.{ p, tmp_suffix });
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, tmp_p, .{}));

    // A creation (expected absent) refuses when a file appeared meanwhile.
    const created = try std.fs.path.join(a, &.{ base, "appears" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = created, .data = "raced\n" });
    try std.testing.expectError(
        error.LiveChangedDuringWrite,
        writeAtomicPartial(io, created, "candidate\n", 0o644, null),
    );
    const raced = try Io.Dir.cwd().readFileAlloc(io, created, a, .limited(4096));
    try std.testing.expectEqualStrings("raced\n", raced);

    // A creation against a still-absent path lands.
    const fresh = try std.fs.path.join(a, &.{ base, "fresh" });
    try writeAtomicPartial(io, fresh, "made\n", 0o644, null);
    const made = try Io.Dir.cwd().readFileAlloc(io, fresh, a, .limited(4096));
    try std.testing.expectEqualStrings("made\n", made);
}

test "resolvePartialLive: resolves a live symlink to its target, refuses dangling" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const target = try std.fs.path.join(a, &.{ base, "real.toml" });
    try writeAtomic(io, target, "x = 1\n", 0o644);

    // A symlink (relative target) resolves to the target's real path.
    const link = try std.fs.path.join(a, &.{ base, "link.toml" });
    try Io.Dir.cwd().symLink(io, "real.toml", link, .{});
    const resolved = try resolvePartialLive(a, io, link);
    const want = try Io.Dir.cwd().realPathFileAlloc(io, target, a);
    try std.testing.expectEqualStrings(want, resolved);

    // A regular file and an absent path pass through unchanged.
    try std.testing.expectEqualStrings(target, try resolvePartialLive(a, io, target));
    const absent = try std.fs.path.join(a, &.{ base, "absent.toml" });
    try std.testing.expectEqualStrings(absent, try resolvePartialLive(a, io, absent));

    // A dangling link refuses.
    const dangling = try std.fs.path.join(a, &.{ base, "dangling.toml" });
    try Io.Dir.cwd().symLink(io, "missing.toml", dangling, .{});
    try std.testing.expectError(error.DanglingLink, resolvePartialLive(a, io, dangling));
}

test "writeAtomicPartial: guards and replaces the resolved target of a symlinked live path" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const target = try std.fs.path.join(a, &.{ base, "cfg.toml" });
    try writeAtomic(io, target, "orig\n", 0o644);
    const link = try std.fs.path.join(a, &.{ base, "link-cfg.toml" });
    try Io.Dir.cwd().symLink(io, "cfg.toml", link, .{});

    // The patch lands on the target; the link survives and shows the new bytes.
    const resolved = try resolvePartialLive(a, io, link);
    const st0 = liveStat(io, resolved).?;
    try writeAtomicPartial(io, resolved, "patched\n", 0o644, st0);
    const link_st = try Io.Dir.cwd().statFile(io, link, .{ .follow_symlinks = false });
    try std.testing.expect(link_st.kind == .sym_link);
    try std.testing.expectEqualStrings("patched\n", try Io.Dir.cwd().readFileAlloc(io, link, a, .limited(4096)));
    try std.testing.expectEqualStrings("patched\n", try Io.Dir.cwd().readFileAlloc(io, target, a, .limited(4096)));

    // The TARGET mutated after the stat was captured (the write above): a
    // stale expectation must refuse and leave the target's bytes alone.
    try std.testing.expectError(
        error.LiveChangedDuringWrite,
        writeAtomicPartial(io, resolved, "later\n", 0o644, st0),
    );
    try std.testing.expectEqualStrings("patched\n", try Io.Dir.cwd().readFileAlloc(io, target, a, .limited(4096)));
}

test "setMode: heals a drifted mode in place" {
    if (!Io.File.Permissions.has_executable_bit) return; // no unix modes to enforce
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "secret" });
    try writeAtomic(io, path, "token\n", 0o644);
    try setMode(path, 0o600);

    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}
