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

/// Write `content` to `live_path` atomically with the requested unix mode:
/// write to a `.mox-tmp` sidecar, chmod, then rename to the target. Creates
/// parent directories as needed.
pub fn writeAtomic(io: Io, live_path: []const u8, content: []const u8, mode: u32) !void {
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

    // Atomic rename.
    try Io.Dir.rename(Io.Dir.cwd(), tmp_path, Io.Dir.cwd(), live_path, io);
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
