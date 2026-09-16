//! Finding the repo's package backends: `scripts/backends/<name>`.
//!
//! Flat and repo-only. Not axis-gated: a plugin hidden under `os=windows/`
//! would be undiscovered on a mac, and every shared-manifest row naming it
//! would then read as a typo there. Whether a backend is usable on this
//! machine is the plugin's own `available` verb, and nothing else. Not the
//! private layer: mox does not shadow scripts, and this adds no such thing.
//!
//! `scripts/` already means "repo executables mox invokes under a contract"
//! -- check hooks live there -- so a backend belongs beside them rather than
//! in a new root directory for one feature.

const std = @import("std");
const builtin = @import("builtin");

const dirent = @import("../source/dirent.zig");
const diag_mod = @import("../machine/diag.zig");

const Io = std.Io;

pub const Diag = diag_mod.Diag;

pub const Error = error{
    BadBackendName,
    BackendNotExecutable,
    DuplicateBackend,
};

pub const Found = struct {
    /// The filename stem: `macports` and `macports.ps1` both name `macports`.
    name: []const u8,
    path: []const u8,
    /// How to invoke it: the path, or an interpreter and the path.
    argv0: []const []const u8,
    /// Null when this machine can run it. Otherwise why not, printed as a
    /// status note: a MacPorts sh script in a shared repo must not break every
    /// package command on a Windows machine, nor vanish silently there.
    not_runnable: ?[]const u8 = null,
};

const ps_pwsh = "pwsh";

/// Every plugin under `<repo>/scripts/backends`, name-ordered. A missing
/// directory is no plugins. A name outside `[A-Za-z0-9_-]` or, on a
/// permission-bearing filesystem, a file without its executable bit is an
/// error naming the path: a forgotten `chmod +x` must not read as "no such
/// backend" from the manifest's side.
pub fn discover(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    diag: ?*Diag,
) ![]const Found {
    const dir_path = try std.fs.path.join(arena, &.{ repo_dir, "scripts", "backends" });
    const entries = try dirent.sortedPath(arena, io, dir_path, .{ .iterate = true });

    var out: std.ArrayList(Found) = .empty;
    var seen = std.StringHashMap([]const u8).init(arena);

    for (entries) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        const path = try std.fs.path.join(arena, &.{ dir_path, e.name });
        const kind = kindOf(e.name);
        const name = stemOf(e.name, kind);

        if (!nameOk(name)) {
            if (diag) |d| d.set("{s}: not a backend name (use [A-Za-z0-9_-])", .{path});
            return Error.BadBackendName;
        }

        const found = try classify(arena, io, path, name, kind, diag);

        if (seen.get(name)) |other| {
            // Two runnable files for one name is ambiguous; a runnable file
            // beside a not-runnable twin (macports + macports.ps1) is the
            // cross-platform case and the runnable one wins.
            const prev = &out.items[indexOf(out.items, name)];
            if (prev.not_runnable != null and found.not_runnable == null) {
                prev.* = found;
                continue;
            }
            if (prev.not_runnable == null and found.not_runnable != null) continue;
            if (diag) |d| d.set("{s} and {s} both name backend \"{s}\"", .{ other, path, name });
            return Error.DuplicateBackend;
        }
        try seen.put(name, path);
        try out.append(arena, found);
    }
    return out.toOwnedSlice(arena);
}

const Kind = enum { plain, ps1, exe, cmd };

fn kindOf(filename: []const u8) Kind {
    if (std.mem.endsWith(u8, filename, ".ps1")) return .ps1;
    if (std.mem.endsWith(u8, filename, ".exe")) return .exe;
    if (std.mem.endsWith(u8, filename, ".cmd")) return .cmd;
    return .plain;
}

fn stemOf(filename: []const u8, kind: Kind) []const u8 {
    return switch (kind) {
        .plain => filename,
        .ps1, .exe, .cmd => filename[0 .. filename.len - 4],
    };
}

fn nameOk(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn indexOf(items: []const Found, name: []const u8) usize {
    for (items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return i;
    }
    unreachable;
}

/// Decide how, or whether, this machine runs the file. Unix: a `.ps1` is a
/// Windows-only kind and a plain file needs its executable bit. Windows: NTFS
/// has no such bit, so runnability is by kind alone -- `.ps1` through pwsh,
/// `.exe`/`.cmd` directly, anything else not runnable here.
fn classify(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    name: []const u8,
    kind: Kind,
    diag: ?*Diag,
) !Found {
    if (builtin.os.tag == .windows) {
        return switch (kind) {
            .ps1 => .{
                .name = name,
                .path = path,
                .argv0 = try arena.dupe([]const u8, &.{ ps_pwsh, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path }),
            },
            .exe, .cmd => .{ .name = name, .path = path, .argv0 = try arena.dupe([]const u8, &.{path}) },
            .plain => .{
                .name = name,
                .path = path,
                .argv0 = &.{},
                .not_runnable = "not runnable on windows (a backend here is a .ps1, .exe or .cmd)",
            },
        };
    }

    if (kind != .plain) {
        return .{
            .name = name,
            .path = path,
            .argv0 = &.{},
            .not_runnable = "a windows-only kind; not runnable here",
        };
    }

    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |e| {
        if (diag) |d| d.set("{s}: cannot stat: {s}", .{ path, @errorName(e) });
        return e;
    };
    if (Io.File.Permissions.has_executable_bit and (st.permissions.toMode() & 0o111) == 0) {
        if (diag) |d| d.set(
            "{s}: not executable; a scripts directory holds executables only (chmod +x it, or move it out)",
            .{path},
        );
        return Error.BackendNotExecutable;
    }
    return .{ .name = name, .path = path, .argv0 = try arena.dupe([]const u8, &.{path}) };
}

const testing = std.testing;

fn tmpRepo(a: std.mem.Allocator, io: Io, sub: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", sub, "repo" });
}

test "discover: a missing directory is no plugins" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo");

    const got = try discover(a, io, try tmpRepo(a, io, &tmp.sub_path), null);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "discover: an executable plain file is a plugin named by its stem" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/macports", .data = "#!/bin/sh\n" });
    const repo = try tmpRepo(a, io, &tmp.sub_path);
    const p = try std.fs.path.join(a, &.{ repo, "scripts", "backends", "macports" });
    try Io.Dir.cwd().setFilePermissions(io, p, Io.File.Permissions.fromMode(0o755), .{});

    const got = try discover(a, io, repo, null);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("macports", got[0].name);
    try testing.expect(got[0].not_runnable == null);
    try testing.expectEqualStrings(p, got[0].argv0[0]);
}

test "discover: a file without its executable bit is a named error, not an absent backend" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/macports", .data = "#!/bin/sh\n" });

    var d: Diag = .{};
    try testing.expectError(Error.BackendNotExecutable, discover(a, io, try tmpRepo(a, io, &tmp.sub_path), &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "chmod +x") != null);
}

test "discover: a .ps1 on unix is not runnable here, and says so rather than vanishing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/scoopish.ps1", .data = "exit 0\n" });

    const got = try discover(a, io, try tmpRepo(a, io, &tmp.sub_path), null);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("scoopish", got[0].name);
    try testing.expect(got[0].not_runnable != null);
}

test "discover: a runnable file beside its not-runnable twin wins the name" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/macports", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/macports.ps1", .data = "exit 0\n" });
    const repo = try tmpRepo(a, io, &tmp.sub_path);
    try Io.Dir.cwd().setFilePermissions(io, try std.fs.path.join(a, &.{ repo, "scripts", "backends", "macports" }), Io.File.Permissions.fromMode(0o755), .{});

    const got = try discover(a, io, repo, null);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expect(got[0].not_runnable == null);
}

test "discover: a name outside the charset is refused with its path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/mac ports", .data = "" });

    var d: Diag = .{};
    try testing.expectError(Error.BadBackendName, discover(a, io, try tmpRepo(a, io, &tmp.sub_path), &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "mac ports") != null);
}
