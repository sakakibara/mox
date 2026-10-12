//! `.mox-exact` directory enforcement.
//!
//! After apply writes every managed file, each exact directory is swept: live
//! entries mox did not produce are removed so the live directory mirrors the
//! source exactly. Removal is recoverable -- every deleted file is snapshotted
//! first -- but still gated: a file mox itself wrote and that is unchanged is
//! swept automatically, while anything foreign (never recorded) or drifted is
//! refused unless `--overwrite` is given, and reported either way.

const std = @import("std");

const Io = std.Io;
const applied = @import("applied.zig");
const snapshot = @import("snapshot.zig");
const ignore_match = @import("../source/ignore/match.zig");
const source_path = @import("../source/path.zig");
const dirent = @import("../source/dirent.zig");
const parent_link = @import("parent_link.zig");
const live_remove = @import("live_remove.zig");
const state = @import("../state/root.zig");

/// Bound on how deep an unmanaged subdirectory is walked when snapshotting its
/// files before removal. A pathologically deep foreign tree stops here rather
/// than recursing without limit.
const max_depth: usize = 64;

pub const Options = struct {
    st: *state.Draft,
    home: []const u8,
    force: bool,
    dry_run: bool,
    /// Live paths the tree plants as symlinks: nothing below one is swept.
    links: ?*const std.StringHashMap(void) = null,
};

pub const Result = struct {
    /// Entries removed (or, under dry-run, that would be removed).
    removed: usize = 0,
    /// Entries refused only for lacking `--overwrite`: resolvable
    /// by the caller re-running forced.
    drift_refused: usize = 0,
    /// Entries refused for a reason `--overwrite` cannot resolve
    /// (unreadable/unsnapshottable, or a foreign subtree harboring an
    /// ignored entry mox will never delete).
    error_refused: usize = 0,
};

/// The direct child of `dir_live` that `file_live` lives under, or null when
/// `file_live` is not within `dir_live`. `~/.config` + `~/.config/nvim/init.lua`
/// yields `nvim`; `~/.config` + `~/.config/foo` yields `foo`.
pub fn managedChildName(dir_live: []const u8, file_live: []const u8) ?[]const u8 {
    if (!source_path.isUnderDir(file_live, dir_live)) return null;
    // `isUnderDir` admits the directory itself, which names no child.
    if (file_live.len == dir_live.len) return null;
    const tail = file_live[dir_live.len + 1 ..];
    for (tail, 0..) |c, i| {
        if (std.fs.path.isSep(c)) return tail[0..i];
    }
    return tail;
}

/// Sweep each exact directory, removing live entries not among
/// `managed_live`. An entry matching `ruleset` (checked home-relative to
/// `home`) is exempt -- it is not mox's to prune. Returns the removal/refusal
/// tally.
pub fn enforce(
    arena: std.mem.Allocator,
    io: Io,
    exact_dirs: []const []const u8,
    managed_live: []const []const u8,
    opts: Options,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    ruleset: *const ignore_match.RuleSet,
    home: []const u8,
) !Result {
    var result: Result = .{};
    for (exact_dirs) |dir_live| {
        try enforceOne(arena, io, dir_live, managed_live, opts, stdout, stderr, &result, ruleset, home);
    }
    return result;
}

fn enforceOne(
    arena: std.mem.Allocator,
    io: Io,
    dir_live: []const u8,
    managed_live: []const []const u8,
    opts: Options,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    result: *Result,
    ruleset: *const ignore_match.RuleSet,
    home: []const u8,
) !void {
    if (parent_link.through(io, home, try std.fs.path.join(arena, &.{ dir_live, "_" }), opts.links)) {
        try stdout.print("  {s}/: {s}\n", .{ dir_live, parent_link.reason });
        return;
    }
    var dir = Io.Dir.cwd().openDir(io, dir_live, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close(io);

    // Snapshot the entry list before mutating the directory, in a total order
    // so a prune reports (and deletes) the same entries in the same sequence on
    // every machine.
    const entries = try dirent.sorted(arena, io, dir);

    for (entries) |e| {
        if (isManagedChild(dir_live, e.name, managed_live)) continue;
        const live_path = try std.fs.path.join(arena, &.{ dir_live, e.name });
        const rel = try source_path.liveKeyRelToHome(arena, home, live_path);
        if (ruleset.isPathIgnored(rel, e.kind == .directory)) continue; // ignored live entries are not mox's to prune
        switch (e.kind) {
            .file => try sweepFile(arena, io, live_path, opts, stdout, stderr, result),
            .directory => try sweepDir(arena, io, live_path, opts, stdout, stderr, result, ruleset, home),
            else => try sweepOther(arena, io, live_path, opts, stdout, stderr, result),
        }
    }
}

fn isManagedChild(dir_live: []const u8, name: []const u8, managed_live: []const []const u8) bool {
    for (managed_live) |ml| {
        const child = managedChildName(dir_live, ml) orelse continue;
        if (std.mem.eql(u8, child, name)) return true;
    }
    return false;
}

fn sweepFile(
    arena: std.mem.Allocator,
    io: Io,
    live_path: []const u8,
    opts: Options,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    result: *Result,
) !void {
    // A genuinely empty file reads as "" with no error; a read FAILURE (unreadable,
    // I/O error, over the size cap) must never be treated as empty, or the snapshot
    // below would back up nothing and the delete would be unrecoverable. Refuse it,
    // mirroring snapshotTree's refusal one level deeper.
    const content = Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            result.error_refused += 1;
            try stderr.print("  UNSNAPSHOTTABLE {s} (exact dir; not removing, cannot read to back up)\n", .{live_path});
            return;
        },
    };
    const rec = opts.st.read(live_path);
    const clean_leftover = if (rec) |r| std.mem.eql(u8, &r, &applied.contentHashHex(content)) else false;

    if (!clean_leftover and !opts.force) {
        result.drift_refused += 1;
        try stderr.print("  UNMANAGED {s} (exact dir; --overwrite to remove)\n", .{live_path});
        return;
    }
    if (opts.dry_run) {
        result.removed += 1;
        try stdout.print("  would remove {s} (unmanaged, exact dir)\n", .{live_path});
        return;
    }
    try report(liveRemove(arena, io, opts, live_path, .{ .file = content }, content), live_path, "", stdout, stderr, result);
}

fn liveRemove(arena: std.mem.Allocator, io: Io, opts: Options, live_path: []const u8, snap: live_remove.Snap, expect: ?[]const u8) live_remove.Outcome {
    return live_remove.remove(arena, io, .{ .home = opts.home, .st = opts.st, .links = opts.links, .expect = expect }, live_path, snap);
}

/// Count and print one exact-dir removal's outcome.
fn report(outcome: live_remove.Outcome, live_path: []const u8, suffix: []const u8, stdout: *Io.Writer, stderr: *Io.Writer, result: *Result) !void {
    switch (outcome) {
        .removed => {
            result.removed += 1;
            try stdout.print("  removed {s}{s} (unmanaged, exact dir)\n", .{ live_path, suffix });
        },
        .left => |why| try stdout.print("  {s}{s}: {s}\n", .{ live_path, suffix, why }),
        .failed => |why| {
            result.error_refused += 1;
            try stderr.print("  {s}{s}: {s}\n", .{ live_path, suffix, why });
        },
        .changed => {
            result.error_refused += 1;
            try stderr.print("  CONFLICT {s}{s} (changed underneath mox mid-apply; re-run 'mox apply')\n", .{ live_path, suffix });
        },
    }
}

fn sweepDir(
    arena: std.mem.Allocator,
    io: Io,
    live_path: []const u8,
    opts: Options,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    result: *Result,
    ruleset: *const ignore_match.RuleSet,
    home: []const u8,
) !void {
    // The whole-directory exemption above only covers a foreign dir whose OWN
    // path is ignored. A non-ignored foreign dir may still harbor an ignored
    // descendant several levels down; the guarantee that mox never deletes an
    // ignored file is absolute, so the entire subtree is refused rather than
    // deleted around it. `--overwrite` cannot resolve this (mox will never
    // delete an ignored entry): checked BEFORE the force gate below, so a
    // non-forced run names the true reason instead of offering `--overwrite` as a
    // fix that would still refuse.
    if (try subtreeHasIgnored(arena, io, live_path, home, ruleset, 0)) {
        result.error_refused += 1;
        try stderr.print("  UNMANAGED {s}/ contains ignored entries; not removed, even with --overwrite -- clear them manually\n", .{live_path});
        return;
    }
    // A foreign directory is otherwise always "unknown"; removing it needs --overwrite.
    if (!opts.force) {
        result.drift_refused += 1;
        try stderr.print("  UNMANAGED {s}/ (exact dir; --overwrite to remove)\n", .{live_path});
        return;
    }
    if (opts.dry_run) {
        result.removed += 1;
        try stdout.print("  would remove {s}/ (unmanaged, exact dir)\n", .{live_path});
        return;
    }
    // The whole tree -- files, links, and every directory with its mode --
    // is snapshotted before it is removed. If any entry cannot be, refuse the
    // delete: removing it would destroy data with no recoverable copy.
    snapshot.saveTree(arena, io, opts.st, opts.home, live_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            result.error_refused += 1;
            try stderr.print("  UNSNAPSHOTTABLE {s}/ (exact dir; not removing, would lose unsaved data)\n", .{live_path});
            return;
        },
    };
    try report(liveRemove(arena, io, opts, live_path, .taken_tree, null), live_path, "/", stdout, stderr, result);
}

fn sweepOther(
    arena: std.mem.Allocator,
    io: Io,
    live_path: []const u8,
    opts: Options,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    result: *Result,
) !void {
    if (!opts.force) {
        result.drift_refused += 1;
        try stderr.print("  UNMANAGED {s} (exact dir; --overwrite to remove)\n", .{live_path});
        return;
    }
    if (opts.dry_run) {
        result.removed += 1;
        try stdout.print("  would remove {s} (unmanaged, exact dir)\n", .{live_path});
        return;
    }
    // A symlink is kept as a link, so rollback can put it back.
    const snap: live_remove.Snap = switch (applied.inspectSymSite(io, arena, live_path)) {
        .symlink => |target| .{ .link = target },
        else => .special,
    };
    try report(liveRemove(arena, io, opts, live_path, snap, null), live_path, "", stdout, stderr, result);
}

/// True if any entry under `dir_live`, at any depth, is ignored per `ruleset`
/// (checked home-relative, by its own kind). An unreadable or un-openable
/// subdirectory is treated as containing nothing further to check, not as
/// ignored -- it is caught separately by the unsnapshottable-refusal path.
fn subtreeHasIgnored(arena: std.mem.Allocator, io: Io, dir_live: []const u8, home: []const u8, ruleset: *const ignore_match.RuleSet, depth: usize) !bool {
    if (depth >= max_depth) return false;
    var dir = Io.Dir.cwd().openDir(io, dir_live, .{ .iterate = true, .follow_symlinks = false }) catch return false;
    defer dir.close(io);

    for (try dirent.sorted(arena, io, dir)) |e| {
        const child = try std.fs.path.join(arena, &.{ dir_live, e.name });
        const rel = try source_path.liveKeyRelToHome(arena, home, child);
        if (ruleset.isPathIgnored(rel, e.kind == .directory)) return true;
        if (e.kind == .directory and try subtreeHasIgnored(arena, io, child, home, ruleset, depth + 1)) return true;
    }
    return false;
}

test "enforce: an unreadable file is refused, never deleted with an empty snapshot" {
    if (!Io.File.Permissions.has_executable_bit) return; // needs chmod 000 semantics
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const dir_live = try std.fs.path.join(a, &.{ base, "exactdir" });
    const victim = try std.fs.path.join(a, &.{ dir_live, "unreadable" });
    try Io.Dir.cwd().createDirPath(io, dir_live);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = victim, .data = "precious data\n" });

    // Make it unreadable so the pre-delete read-to-snapshot fails.
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..victim.len], victim);
    zbuf[victim.len] = 0;
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(@ptrCast(&zbuf), 0));
    defer _ = std.c.chmod(@ptrCast(&zbuf), 0o644); // restore so tmp.cleanup can remove it

    var out_aw: Io.Writer.Allocating = .init(a);
    var err_aw: Io.Writer.Allocating = .init(a);
    const opts: Options = .{
        .st = try state.draft.testDraft(a, io, try std.fs.path.join(a, &.{ base, "state" })),
        .home = base,
        .force = true, // even forced, an unsnapshottable file must not be lost
        .dry_run = false,
    };
    const empty_ruleset: ignore_match.RuleSet = .{ .rules = &.{} };
    const res = try enforce(a, io, &.{dir_live}, &.{}, opts, &out_aw.writer, &err_aw.writer, &empty_ruleset, base);

    try std.testing.expectEqual(@as(usize, 0), res.removed);
    try std.testing.expectEqual(@as(usize, 1), res.error_refused);
    try std.testing.expectEqual(@as(usize, 0), res.drift_refused);
    // The file survives.
    try std.testing.expect(std.mem.indexOf(u8, err_aw.written(), "UNSNAPSHOTTABLE") != null);
    _ = Io.Dir.cwd().statFile(io, victim, .{}) catch return std.testing.expect(false);
}

test "managedChildName: direct child and nested descendant" {
    try std.testing.expectEqualStrings("foo", managedChildName("/h/.config", "/h/.config/foo").?);
    try std.testing.expectEqualStrings("nvim", managedChildName("/h/.config", "/h/.config/nvim/init.lua").?);
    try std.testing.expect(managedChildName("/h/.config", "/h/.config") == null);
    try std.testing.expect(managedChildName("/h/.config", "/h/.zshrc") == null);
    // A sibling whose name is a prefix of the dir must not match.
    try std.testing.expect(managedChildName("/h/.config", "/h/.configx/y") == null);
}
