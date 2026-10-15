//! How a state directory says it is mox's: the marker `.mox-state`, which
//! mox writes into every state directory it creates. An unmarked directory
//! `MOX_STATE_DIR` names is refused before anything in it is read or
//! changed, unless it holds only what mox makes beside its store, each in
//! its own form; mox's default path is its own whatever it holds.

const std = @import("std");
const Io = std.Io;
const json = @import("json");
const dirent = @import("../source/dirent.zig");
const durable = @import("durable.zig");
const lock = @import("lock.zig");
const quote = @import("quote.zig");
const run_scripts = @import("../apply/run_scripts.zig");
const trigger_state = @import("../trigger/state.zig");

pub const marker_name = ".mox-state";
pub const marker_text = "mox state 1\n";

/// Where the state directory's path came from.
pub const Origin = enum {
    /// `MOX_STATE_DIR`, which may name any directory.
    explicit,
    /// mox's default path, which nothing but mox uses.
    default,
};

pub const Kind = enum {
    /// Absent, or holding only what mox makes beside its store
    /// (`freshEntry`): nothing in it is mox's to lose, and a write makes it
    /// a state directory. At the default path, also one holding anything
    /// else that is not marked.
    fresh,
    marked,
};

pub const Acceptance = union(enum) {
    accepted: Kind,
    /// Why the directory is not used; nothing in it was read or changed.
    refused: []const u8,
};

/// A regular file an operating system's file browser leaves in any
/// directory it shows, which says nothing about whose the directory is.
pub fn isOsFile(e: dirent.Entry) bool {
    if (e.kind != .file) return false;
    for ([_][]const u8{ ".DS_Store", "Thumbs.db", "desktop.ini" }) |n| if (std.mem.eql(u8, e.name, n)) return true;
    return false;
}

/// Whether `state_dir` is mox's, read without creating or changing
/// anything.
pub fn accept(arena: std.mem.Allocator, io: Io, state_dir: []const u8, origin: Origin) !Acceptance {
    const entries = dirent.sortedPath(arena, io, state_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return .{ .accepted = .fresh },
        error.NotDir => return .{ .refused = try std.fmt.allocPrint(arena, "mox: the state directory {s} is not a directory; point MOX_STATE_DIR at a dedicated directory\n", .{state_dir}) },
        error.OutOfMemory => return e,
        else => return .{ .refused = try std.fmt.allocPrint(arena, "mox: cannot read the state directory {s} ({s})\n", .{ state_dir, @errorName(e) }) },
    };
    for (entries) |e| if (std.mem.eql(u8, e.name, marker_name)) switch (try readMarker(arena, io, state_dir)) {
        .current => return .{ .accepted = .marked },
        .newer => |line| return .{ .refused = try std.fmt.allocPrint(arena, "mox: state written by a newer mox ({s} says {s}); upgrade mox to use {s}\n", .{ marker_name, line, state_dir }) },
        .none => {},
    };
    if (origin == .default) return .{ .accepted = .fresh };
    for (entries) |e| if (!try freshEntry(arena, io, state_dir, e)) return .{ .refused = try refusal(arena, state_dir) };
    return .{ .accepted = .fresh };
}

/// The top-level entry `e` of an unmarked directory `MOX_STATE_DIR` names
/// is one mox makes beside its store, in the form it makes it, as
/// a first run can leave it: an OS file, a lock file holding nothing or a
/// holder line, `bin/` holding only the running mox, `coupling/` holding
/// the coupling graph and declines, and the trigger state.
fn freshEntry(arena: std.mem.Allocator, io: Io, state_dir: []const u8, e: dirent.Entry) !bool {
    if (isOsFile(e)) return true;
    const path = try std.fs.path.join(arena, &.{ state_dir, e.name });
    if (isLockFile(e.name)) return e.kind == .file and lockContent(arena, io, path);
    if (std.mem.eql(u8, e.name, run_scripts.bin_dir_name)) return try whyNotOwn(arena, io, path, run_scripts.isBinEntry) == null;
    if (std.mem.eql(u8, e.name, "coupling")) return e.kind == .directory and try couplingOnly(arena, io, path);
    if (std.mem.eql(u8, e.name, trigger_state.state_basename)) return e.kind == .file and triggerForm(arena, io, path);
    return false;
}

fn lockContent(arena: std.mem.Allocator, io: Io, path: []const u8) bool {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return false;
    return lock.isLockContent(bytes);
}

/// `coupling/` holds only `graph.json` and `declines.json` as mox writes
/// them, and OS files.
fn couplingOnly(arena: std.mem.Allocator, io: Io, dir: []const u8) !bool {
    const entries = dirent.sortedPath(arena, io, dir, .{ .iterate = true, .follow_symlinks = false }) catch return false;
    for (entries) |e| {
        if (isOsFile(e)) continue;
        if (e.kind != .file) return false;
        const fields: []const []const u8 = if (std.mem.eql(u8, e.name, "graph.json"))
            &.{"postings"}
        else if (std.mem.eql(u8, e.name, "declines.json"))
            &.{ "global", "pairs" }
        else
            return false;
        const bytes = Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ dir, e.name }), arena, .limited(64 * 1024 * 1024)) catch return false;
        const v = json.parse(arena, bytes, .{}) catch return false;
        if (v != .object) return false;
        const ver = v.object.get("v") orelse return false;
        if (ver != .integer or ver.integer != 1) return false;
        for (fields) |f| if (v.object.get(f) == null) return false;
    }
    return true;
}

/// The trigger state holds only `seen:<key>=`, `hash:<key>=<hex>` and
/// `every:<key>=<seconds>` records, one per line.
fn triggerForm(arena: std.mem.Allocator, io: Io, path: []const u8) bool {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch return false;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        const eq = std.mem.lastIndexOfScalar(u8, line, '=') orelse return false;
        if (eq < colon) return false;
        const ns = line[0..colon];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, ns, "seen")) {
            if (value.len != 0) return false;
        } else if (std.mem.eql(u8, ns, "hash")) {
            if (value.len == 0) return false;
            for (value) |c| if (!std.ascii.isHex(c)) return false;
        } else if (std.mem.eql(u8, ns, "every")) {
            _ = std.fmt.parseInt(i64, value, 10) catch return false;
        } else return false;
    }
    return true;
}

/// `accept`, then for a directory accepted unmarked, the marker written:
/// what a step that writes the state does first.
pub fn acceptForWrite(arena: std.mem.Allocator, io: Io, state_dir: []const u8, origin: Origin) !Acceptance {
    const got = try accept(arena, io, state_dir, origin);
    switch (got) {
        .refused => {},
        .accepted => |k| if (k != .marked) try mark(arena, io, state_dir),
    }
    return got;
}

/// Write the marker, creating the state directory when it is absent.
pub fn mark(arena: std.mem.Allocator, io: Io, state_dir: []const u8) !void {
    const path = try std.fs.path.join(arena, &.{ state_dir, marker_name });
    if (try readMarker(arena, io, state_dir) == .current) return;
    Io.Dir.cwd().access(io, state_dir, .{}) catch |e| switch (e) {
        error.FileNotFound => try Io.Dir.cwd().createDirPath(io, state_dir),
        else => return e,
    };
    try durable.writeFile(io, path, marker_text);
    try durable.syncDir(io, state_dir);
}

/// Why `state_dir` is not used, and the two ways out: another directory,
/// or the marker written by hand when the directory is a mox state.
pub fn refusal(arena: std.mem.Allocator, state_dir: []const u8) ![]const u8 {
    const path = try std.fs.path.join(arena, &.{ state_dir, marker_name });
    return std.fmt.allocPrint(arena,
        \\mox: {s} is not a mox state directory: it holds no {s} marker, so mox leaves it as it is; point MOX_STATE_DIR at a dedicated directory, or, if it is a mox state, mark it as one:
        \\  sh:         (umask 077 && printf 'mox state 1\n' > {s})
        \\  PowerShell: [IO.File]::WriteAllText({s}, "mox state 1`n")
        \\
    , .{ state_dir, marker_name, try quote.sh(arena, path), try quote.ps(arena, path) });
}

pub fn isLockFile(name: []const u8) bool {
    return std.mem.eql(u8, name, lock.lock_name) or std.mem.eql(u8, name, lock.readers_name) or std.mem.eql(u8, name, lock.gate_name);
}

const Marker = union(enum) {
    /// `mox state 1`.
    current,
    /// `mox state <n>` for an `n` above 1: the line.
    newer: []const u8,
    /// Absent, or not a marker.
    none,
};

/// The marker of `state_dir`: a regular file whose first line is
/// `mox state <n>`, `n` a number above 0 written without leading zeros.
fn readMarker(arena: std.mem.Allocator, io: Io, state_dir: []const u8) !Marker {
    const path = try std.fs.path.join(arena, &.{ state_dir, marker_name });
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return .none;
    if (st.kind != .file) return .none;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return .none;
    const line = bytes[0 .. std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len];
    const prefix = "mox state ";
    if (!std.mem.startsWith(u8, line, prefix)) return .none;
    const n = line[prefix.len..];
    if (n.len == 0 or n[0] == '0') return .none;
    for (n) |c| if (!std.ascii.isDigit(c)) return .none;
    return if (std.mem.eql(u8, n, "1")) .current else .{ .newer = line };
}

/// The entries of a state directory, beside the store, the lock files, the
/// private layer and `bin/`, that mox makes: the coupling graph, commit's
/// recovery copies, the scripts' PATH note, the trigger state, zypper's
/// ledger, and a check hook's staging.
pub fn isMadeByMox(name: []const u8) bool {
    const fixed = [_][]const u8{
        "coupling",
        "commit-recovery",
        "mox-path",
        trigger_state.state_basename,
        "zypper.txt",
    };
    for (fixed) |n| if (std.mem.eql(u8, name, n)) return true;
    return run_scripts.isCheckStaging(name);
}

/// Why the entry at `path` is not mox's although its name is: null when it
/// is absent, or a directory every entry of which but OS files `own`
/// accepts, judged by name and kind without following a link.
pub fn whyNotOwn(arena: std.mem.Allocator, io: Io, path: []const u8, own: *const fn (dirent.Entry) bool) !?[]const u8 {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return try std.fmt.allocPrint(arena, "could not be read: {s}", .{@errorName(err)}),
    };
    if (st.kind != .directory) return "not made by mox";
    const held = dirent.sortedPath(arena, io, path, .{ .iterate = true, .follow_symlinks = false }) catch |err|
        return try std.fmt.allocPrint(arena, "could not be read: {s}", .{@errorName(err)});
    var first: ?[]const u8 = null;
    var others: usize = 0;
    for (held) |h| {
        if (own(h) or isOsFile(h)) continue;
        if (first == null) first = h.name else others += 1;
    }
    const name = first orelse return null;
    if (others == 0) return try std.fmt.allocPrint(arena, "holds {s}, which mox did not make", .{name});
    return try std.fmt.allocPrint(arena, "holds {s} and {d} more entr(ies) mox did not make", .{ name, others });
}

const testing = std.testing;

test "accept: absent and empty directories are fresh, a private-only one is not, a marked one is mox's, and names alone are no evidence" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const dir = try std.fs.path.join(a, &.{ root, "s" });
    try testing.expectEqual(Kind.fresh, (try accept(a, io, dir, .explicit)).accepted);
    try tmp.dir.createDirPath(io, "s");
    try testing.expectEqual(Kind.fresh, (try accept(a, io, dir, .explicit)).accepted);
    try tmp.dir.createDirPath(io, "s/private");
    try testing.expect((try accept(a, io, dir, .explicit)) == .refused);
    for ([_][]const u8{ "s/v2/notes", "s/trash/photo" }) |p| {
        if (std.fs.path.dirname(p)) |parent| try tmp.dir.createDirPath(io, parent);
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "x\n" });
    }
    try testing.expect((try accept(a, io, dir, .explicit)) == .refused);
    try tmp.dir.writeFile(io, .{ .sub_path = "s/mox.lock", .data = "123 - 00000000-0000-0000-0000-000000000000 apply\n" });
    try testing.expect((try accept(a, io, dir, .explicit)) == .refused);
    try tmp.dir.writeFile(io, .{ .sub_path = "s/mox.lock", .data = "" });
    try testing.expect((try accept(a, io, dir, .explicit)) == .refused);
    try tmp.dir.deleteFile(io, "s/mox.lock");
    try tmp.dir.writeFile(io, .{ .sub_path = "s/" ++ marker_name, .data = "not a marker\n" });
    try testing.expect((try accept(a, io, dir, .explicit)) == .refused);
    try tmp.dir.deleteFile(io, "s/" ++ marker_name);
    try mark(a, io, dir);
    try testing.expectEqual(Kind.marked, (try accept(a, io, dir, .explicit)).accepted);
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "" });
    try testing.expect((try accept(a, io, try std.fs.path.join(a, &.{ root, "f" }), .explicit)) == .refused);
}

test "accept: an entry named as an OS file that is not a regular file is no OS file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "s" });
    try tmp.dir.createDirPath(io, "s/.DS_Store");
    try testing.expect((try accept(a, io, dir, .explicit)) == .refused);
}

test "accept: a directory holding only lock files and OS files is fresh, and an empty mox.lock is no evidence of a state" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "s" });
    try tmp.dir.createDirPath(io, "s");
    for ([_][]const u8{ "mox.lock", "readers.lock", "readers.gate", ".DS_Store", "Thumbs.db", "desktop.ini" }) |n| {
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ "s", n }), .data = "" });
    }
    try testing.expectEqual(Kind.fresh, (try accept(a, io, dir, .explicit)).accepted);
    try tmp.dir.writeFile(io, .{ .sub_path = "s/mox.lock", .data = "123 - 00000000-0000-0000-0000-000000000000 apply\n" });
    try testing.expectEqual(Kind.fresh, (try accept(a, io, dir, .explicit)).accepted);
    try tmp.dir.writeFile(io, .{ .sub_path = "s/notes.txt", .data = "mine\n" });
    try testing.expect((try accept(a, io, dir, .explicit)) == .refused);
}

test "accept: the default state path is mox's whatever it holds, unless it is not a directory or a newer mox's" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const dir = try std.fs.path.join(a, &.{ root, "s" });
    try tmp.dir.createDirPath(io, "s/v2");
    try tmp.dir.writeFile(io, .{ .sub_path = "s/notes.txt", .data = "mine\n" });
    try testing.expect((try accept(a, io, dir, .explicit)) == .refused);
    try testing.expectEqual(Kind.fresh, (try accept(a, io, dir, .default)).accepted);
    _ = try acceptForWrite(a, io, dir, .default);
    try testing.expectEqual(Kind.marked, (try accept(a, io, dir, .explicit)).accepted);
    try tmp.dir.writeFile(io, .{ .sub_path = "s/" ++ marker_name, .data = "mox state 2\n" });
    const newer = try accept(a, io, dir, .default);
    try testing.expect(std.mem.indexOf(u8, newer.refused, "newer mox") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "" });
    try testing.expect((try accept(a, io, try std.fs.path.join(a, &.{ root, "f" }), .default)) == .refused);
}

test "accept: only `mox state 1` is the marker; a higher number is a newer mox's, and anything else no marker" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "s" });
    try tmp.dir.createDirPath(io, "s");
    try tmp.dir.writeFile(io, .{ .sub_path = "s/notes.txt", .data = "mine\n" });
    for ([_][]const u8{ "mox state 1\n", "mox state 1" }) |text| {
        try tmp.dir.writeFile(io, .{ .sub_path = "s/" ++ marker_name, .data = text });
        try testing.expectEqual(Kind.marked, (try accept(a, io, dir, .explicit)).accepted);
    }
    for ([_][]const u8{ "mox state 2\n", "mox state 10\n", "mox state 99999999999999999999999\n" }) |text| {
        try tmp.dir.writeFile(io, .{ .sub_path = "s/" ++ marker_name, .data = text });
        const got = try accept(a, io, dir, .explicit);
        try testing.expect(std.mem.indexOf(u8, got.refused, "newer mox") != null);
        try testing.expect(std.mem.indexOf(u8, got.refused, dir) != null);
    }
    for ([_][]const u8{ "mox state 0\n", "mox state 01\n", "mox state 1x\n", "mox state \n", "mox state 1 \n" }) |text| {
        try tmp.dir.writeFile(io, .{ .sub_path = "s/" ++ marker_name, .data = text });
        const got = try accept(a, io, dir, .explicit);
        try testing.expect(std.mem.indexOf(u8, got.refused, "is not a mox state directory") != null);
    }
}

test "refusal: names the directory and why, and gives both remedies; the sh command as printed marks it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "it's s" });
    try tmp.dir.createDirPath(io, "it's s");
    try tmp.dir.writeFile(io, .{ .sub_path = "it's s/notes.txt", .data = "mine\n" });
    const why = (try accept(a, io, dir, .explicit)).refused;
    try testing.expect(std.mem.startsWith(u8, why, try std.fmt.allocPrint(a, "mox: {s} is not a mox state directory: it holds no .mox-state marker, so mox leaves it as it is", .{dir})));
    try testing.expect(std.mem.indexOf(u8, why, "point MOX_STATE_DIR at a dedicated directory") != null);
    const sh_at = (std.mem.indexOf(u8, why, "  sh:         ") orelse return error.NoShRemedy) + "  sh:         ".len;
    const sh = why[sh_at..std.mem.indexOfScalarPos(u8, why, sh_at, '\n').?];
    const ps_at = (std.mem.indexOf(u8, why, "  PowerShell: ") orelse return error.NoPowerShellRemedy) + "  PowerShell: ".len;
    const ps = why[ps_at..std.mem.indexOfScalarPos(u8, why, ps_at, '\n').?];
    try testing.expect(std.mem.indexOf(u8, ps, try quote.ps(a, try std.fs.path.join(a, &.{ dir, marker_name }))) != null);
    const r = try std.process.run(a, io, .{ .argv = &.{ "/bin/sh", "-c", sh } });
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expectEqual(Kind.marked, (try accept(a, io, dir, .explicit)).accepted);
    const path = try std.fs.path.join(a, &.{ dir, marker_name });
    try testing.expectEqualStrings(marker_text, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64)));
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}
