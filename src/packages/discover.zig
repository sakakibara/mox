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
const junk = @import("../source/junk.zig");
const diag_mod = @import("../machine/diag.zig");
const exec = @import("exec.zig");

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
    /// `scripts/backends/<file>`, for reports.
    label: []const u8,
    /// How to invoke it: the path, or an interpreter and the path.
    argv0: []const []const u8,
    /// Null when this machine can run it. Otherwise why not, printed as a
    /// status note: a MacPorts sh script in a shared repo must not break every
    /// package command on a Windows machine, nor vanish silently there.
    not_runnable: ?[]const u8 = null,
};

/// Every plugin under `<repo>/scripts/backends`, name-ordered. A missing
/// directory is no plugins, and so is anything git keeps in a directory it
/// tracks (`isKeepFile`), which is how an empty one is version-controlled. A name outside `[A-Za-z0-9_-]`
/// or, on a permission-bearing filesystem, a file without its executable bit
/// is an error naming the path: a forgotten `chmod +x` must not read as "no
/// such backend" from the manifest's side.
pub fn discover(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    diag: ?*Diag,
    /// What was in the directory but is not a backend, for the caller to
    /// print as notes. Null when the caller does not want them.
    skipped_out: ?*std.ArrayList([]const u8),
) ![]const Found {
    const dir_path = try std.fs.path.join(arena, &.{ repo_dir, "scripts", "backends" });
    const entries = dirent.sortedPath(arena, io, dir_path, .{ .iterate = true }) catch |e| {
        if (diag) |d| d.set("{s}: cannot read: {s}", .{ dir_path, @errorName(e) });
        return e;
    };

    var out: std.ArrayList(Found) = .empty;
    var ignored: std.ArrayList([]const u8) = .empty;
    const skipped = skipped_out orelse &ignored;
    var seen = std.StringHashMap([]const u8).init(arena);

    for (entries) |e| {
        if (e.kind != .file and e.kind != .sym_link and e.kind != .directory) continue;
        if (junk.isJunk(e.name)) continue;
        const path = try std.fs.path.join(arena, &.{ dir_path, e.name });
        // A backend name never begins with a dot, so nothing here can be one:
        // a directory that holds plugins also holds git's and an editor's own
        // config, and refusing the lot would break every package command over
        // a `.gitattributes`. It is said rather than silently dropped, since
        // the other way a file ends up hidden is a slip -- a `.macports` -- and
        // that must not read as "no such backend" from the manifest's side.
        if (e.name.len > 0 and e.name[0] == '.') {
            if (!isKeepFile(e.name)) {
                try skipped.append(arena, try std.fmt.allocPrint(
                    arena,
                    "scripts/backends/{s}: ignored; a backend name never begins with a dot",
                    .{try diag_mod.oneLine(arena, e.name)},
                ));
            }
            continue;
        }
        const kind = kindOf(e.name);
        const name = stemOf(e.name, kind);
        // The path is spawned as it is and printed escaped: a filename
        // carrying a control byte would otherwise split the one-line
        // diagnostic it is named in, and every note built from the label.
        const shown_path = try diag_mod.oneLine(arena, path);

        if (!nameOk(name)) {
            if (diag) |d| d.set("{s}: not a backend name (use [A-Za-z0-9_-]); move it out of scripts/backends", .{shown_path});
            return Error.BadBackendName;
        }

        var found = try classify(arena, io, path, shown_path, name, kind, e.kind, diag);
        found.label = try std.fmt.allocPrint(arena, "scripts/backends/{s}", .{try diag_mod.oneLine(arena, e.name)});

        if (seen.get(name)) |other| {
            // Two runnable files for one name is ambiguous; a runnable file
            // beside a not-runnable twin (macports + macports.ps1) is the
            // cross-platform case and the runnable one wins.
            const prev = &out.items[indexOf(out.items, name)];
            if (prev.not_runnable != null and found.not_runnable == null) {
                prev.* = found;
                try seen.put(name, shown_path);
                continue;
            }
            if (prev.not_runnable == null and found.not_runnable != null) continue;
            if (diag) |d| d.set("{s} and {s} both name backend \"{s}\"", .{ other, shown_path, name });
            return Error.DuplicateBackend;
        }
        try seen.put(name, shown_path);
        try out.append(arena, found);
    }
    return out.toOwnedSlice(arena);
}

/// A file whose presence needs no remark: git's own placeholders and the
/// rules a directory of shell plugins carries. Anything else beginning with a
/// dot is still skipped, but said, since that is also how a backend ends up
/// hidden by accident.
fn isKeepFile(name: []const u8) bool {
    for ([_][]const u8{ ".gitkeep", ".keep", ".gitignore", ".gitattributes", ".editorconfig" }) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
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
/// has no such bit, so runnability is by kind alone -- `.ps1` through
/// PowerShell (spelled as `pwsh`; the spawn falls back to `powershell`),
/// `.exe`/`.cmd` directly, anything else not runnable here.
fn classify(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    /// `path` as a message may print it: escaped of the control bytes that
    /// would otherwise split a one-line diagnostic.
    shown_path: []const u8,
    name: []const u8,
    kind: Kind,
    entry_kind: Io.File.Kind,
    diag: ?*Diag,
) !Found {
    // A directory reaches here rather than being dropped from the scan: a
    // `macports/` directory left where the plugin belongs must say what it is,
    // not read as "no backend named macports" from the manifest's side. The
    // kind decides it on every OS, since Windows classifies by extension and
    // would otherwise take `macports.exe/` for an executable.
    if (entry_kind == .directory) {
        if (diag) |d| d.set("{s}: not a file; a backend is an executable file", .{shown_path});
        return Error.BackendNotExecutable;
    }
    if (builtin.os.tag == .windows) {
        return switch (kind) {
            .ps1 => .{
                .name = name,
                .path = path,
                .label = "",
                .argv0 = try exec.powerShellArgv(arena, exec.powershell_hosts[0], &.{path}),
            },
            .exe, .cmd => .{ .name = name, .path = path, .label = "", .argv0 = try arena.dupe([]const u8, &.{path}) },
            .plain => .{
                .name = name,
                .path = path,
                .label = "",
                .argv0 = &.{},
                .not_runnable = "not runnable on windows (a backend here is a .ps1, .exe or .cmd)",
            },
        };
    }

    if (kind != .plain) {
        return .{
            .name = name,
            .path = path,
            .label = "",
            .argv0 = &.{},
            .not_runnable = "a windows-only kind; not runnable here",
        };
    }

    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |e| {
        if (diag) |d| d.set("{s}: cannot stat: {s}", .{ shown_path, @errorName(e) });
        return e;
    };
    if (st.kind != .file) {
        if (diag) |d| d.set("{s}: not a file; a backend is an executable file", .{shown_path});
        return Error.BackendNotExecutable;
    }
    if (Io.File.Permissions.has_executable_bit and (st.permissions.toMode() & 0o111) == 0) {
        if (diag) |d| d.set(
            "{s}: not executable; a scripts directory holds executables only (chmod +x it, or move it out)",
            .{shown_path},
        );
        return Error.BackendNotExecutable;
    }
    return .{ .name = name, .path = path, .label = "", .argv0 = try arena.dupe([]const u8, &.{path}) };
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

    const got = try discover(a, io, try tmpRepo(a, io, &tmp.sub_path), null, null);
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

    const got = try discover(a, io, repo, null, null);
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
    try testing.expectError(Error.BackendNotExecutable, discover(a, io, try tmpRepo(a, io, &tmp.sub_path), &d, null));
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

    const got = try discover(a, io, try tmpRepo(a, io, &tmp.sub_path), null, null);
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

    const got = try discover(a, io, repo, null, null);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expect(got[0].not_runnable == null);
}

test "discover: a third file for a name is reported against the file that holds it" {
    // Only Windows sees a not-runnable file before a runnable one in name
    // order: the plain file sorts first and is the not-runnable kind there.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/macports", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/macports.cmd", .data = "exit 0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/macports.exe", .data = "" });
    const repo = try tmpRepo(a, io, &tmp.sub_path);
    const plain = try std.fmt.allocPrint(a, "{s} and ", .{try std.fs.path.join(a, &.{ repo, "scripts", "backends", "macports" })});
    const cmd = try std.fmt.allocPrint(a, "{s} and ", .{try std.fs.path.join(a, &.{ repo, "scripts", "backends", "macports.cmd" })});

    var d: Diag = .{};
    try testing.expectError(Error.DuplicateBackend, discover(a, io, repo, &d, null));
    const msg = d.capture().?;
    try testing.expect(std.mem.indexOf(u8, msg, plain) == null);
    try testing.expect(std.mem.indexOf(u8, msg, cmd) != null);
}

test "discover: finder junk is ignored, not a backend name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/.DS_Store", .data = "" });

    const got = try discover(a, io, try tmpRepo(a, io, &tmp.sub_path), null, null);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "discover: what git keeps in a tracked directory is not read as a backend" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    // An empty directory is kept with a placeholder, and a directory of shell
    // plugins needs the eol rule that keeps them LF-clean on Windows: all of
    // it is git's, none of it a backend.
    for ([_][]const u8{ ".gitkeep", ".keep", ".gitignore", ".gitattributes", ".editorconfig" }) |name| {
        const sub = try std.fs.path.join(a, &.{ "repo/scripts/backends", name });
        try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = "" });
    }

    const got = try discover(a, io, try tmpRepo(a, io, &tmp.sub_path), null, null);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "discover: a hidden plugin is said, not silently dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    // Hidden by an editor, or by a stray `mv`. Dropping it in silence would
    // be reported from the manifest's side as "no backend named macports",
    // the failure the directory case exists to prevent -- but refusing the
    // whole subsystem over it would take a `.gitattributes` with it.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/.macports", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/scripts/backends/.gitattributes", .data = "* text=auto eol=lf\n" });

    const repo = try tmpRepo(a, io, &tmp.sub_path);
    var skipped: std.ArrayList([]const u8) = .empty;
    const got = try discover(a, io, repo, null, &skipped);
    try testing.expectEqual(@as(usize, 0), got.len);
    // The slip is named; what git keeps there is not worth remarking on. The
    // note is repo-relative, as every other note under `packages:` is.
    try testing.expectEqual(@as(usize, 1), skipped.items.len);
    try testing.expectEqualStrings(
        "scripts/backends/.macports: ignored; a backend name never begins with a dot",
        skipped.items[0],
    );
}

test "discover: a directory named like a plugin says what it is, not that no such backend exists" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends/macports");

    var d: Diag = .{};
    const repo = try tmpRepo(a, io, &tmp.sub_path);
    try testing.expectError(Error.BackendNotExecutable, discover(a, io, repo, &d, null));
    const want = try std.fmt.allocPrint(
        a,
        "{s}: not a file; a backend is an executable file",
        .{try std.fs.path.join(a, &.{ repo, "scripts", "backends", "macports" })},
    );
    try testing.expectEqualStrings(want, d.capture().?);
}

test "discover: a symlink to a directory is refused as not a file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    try tmp.dir.createDirPath(io, "repo/elsewhere");
    try tmp.dir.symLink(io, "../../elsewhere", "repo/scripts/backends/macports", .{});

    var d: Diag = .{};
    try testing.expectError(Error.BackendNotExecutable, discover(a, io, try tmpRepo(a, io, &tmp.sub_path), &d, null));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "not a file") != null);
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
    const repo = try tmpRepo(a, io, &tmp.sub_path);
    try testing.expectError(Error.BadBackendName, discover(a, io, repo, &d, null));
    const want = try std.fmt.allocPrint(
        a,
        "{s}: not a backend name (use [A-Za-z0-9_-]); move it out of scripts/backends",
        .{try std.fs.path.join(a, &.{ repo, "scripts", "backends", "mac ports" })},
    );
    try testing.expectEqualStrings(want, d.capture().?);
}

test "discover: an unreadable scripts/backends directory is named" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "repo/scripts/backends");
    const repo = try tmpRepo(a, io, &tmp.sub_path);
    const dir_path = try std.fs.path.join(a, &.{ repo, "scripts", "backends" });
    try Io.Dir.cwd().setFilePermissions(io, dir_path, Io.File.Permissions.fromMode(0o000), .{});
    defer Io.Dir.cwd().setFilePermissions(io, dir_path, Io.File.Permissions.fromMode(0o755), .{}) catch {};

    var d: Diag = .{};
    const got = discover(a, io, repo, &d, null);
    // root opens anything; the check is about the wording when the open fails.
    if (got) |_| return error.SkipZigTest else |e| {
        try testing.expectEqual(error.AccessDenied, e);
        const want = try std.fmt.allocPrint(a, "{s}: cannot read: AccessDenied", .{dir_path});
        try testing.expectEqualStrings(want, d.capture().?);
    }
}
