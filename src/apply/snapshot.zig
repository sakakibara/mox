//! Live content a run displaces, kept so `mox rollback` can put it back.
//!
//! A file or link is kept through the run's draft before it is replaced.
//! `saveTree` keeps a whole directory -- every descendant file, symlink and
//! directory with its mode -- captured into memory first, so a descendant it
//! cannot keep refuses the whole tree and nothing is kept. `restoreExcept`
//! puts a generation's displaced entries back onto the running HOME, parents
//! first, with directory modes set last, deepest first.

const std = @import("std");

const Io = std.Io;
const parent_link = @import("parent_link.zig");
const applied = @import("applied.zig");
const write_mod = @import("write.zig");
const source_path = @import("../source/path.zig");
const dirent = @import("../source/dirent.zig");
const prov_map = @import("../provenance/root.zig").map;
const state = @import("../state/root.zig");

/// Bound on directory-tree snapshot recursion depth, matching the bound
/// `exact.snapshotTree` uses for the same reason: a pathologically deep tree
/// refuses rather than recursing without limit.
const tree_max_depth: usize = 64;

/// Total live-file bytes a single directory snapshot holds in memory before
/// keeping it. The whole tree is buffered so a descendant it cannot preserve
/// refuses with nothing kept, but that peak must be bounded: a directory
/// larger than this refuses (the live directory is left untouched, so nothing
/// is lost) rather than risking the process to snapshot, e.g., a cache dir.
const tree_max_bytes: usize = 256 * 1024 * 1024;

const TreeFile = state.draft.TreeFile;
const TreeSymlink = state.draft.TreeLink;
const TreeDir = state.draft.TreeDir;

/// Collect every regular file, symlink, and directory under `dir_live`
/// (including `dir_live` itself and any empty directory), recursively, into
/// `files`/`symlinks`/`dirs`. `dirs` is filled parent-first with each
/// directory's own mode. Returns `error.Unsnapshottable` the instant it meets
/// a descendant with no recoverable byte representation (a fifo, socket,
/// device, or other special inode), a read/open failure (permission denied,
/// past the depth cap), or a cumulative size past `max_bytes`.
fn captureTree(
    arena: std.mem.Allocator,
    io: Io,
    dir_live: []const u8,
    depth: usize,
    max_bytes: usize,
    total: *usize,
    files: *std.ArrayList(TreeFile),
    symlinks: *std.ArrayList(TreeSymlink),
    dirs: *std.ArrayList(TreeDir),
) !void {
    if (depth >= tree_max_depth) return error.Unsnapshottable;
    var dir = Io.Dir.cwd().openDir(io, dir_live, .{ .iterate = true, .follow_symlinks = false }) catch return error.Unsnapshottable;
    defer dir.close(io);

    try dirs.append(arena, .{ .live = dir_live, .mode = write_mod.modeOf((try dir.stat(io)).permissions) });

    for (try dirent.sorted(arena, io, dir)) |e| {
        const child = try std.fs.path.join(arena, &.{ dir_live, e.name });
        switch (e.kind) {
            .file => {
                const content = Io.Dir.cwd().readFileAlloc(io, child, arena, .limited(64 * 1024 * 1024)) catch return error.Unsnapshottable;
                total.* += content.len;
                if (total.* > max_bytes) return error.Unsnapshottable;
                const st = try Io.Dir.cwd().statFile(io, child, .{});
                try files.append(arena, .{ .live = child, .content = content, .mode = write_mod.modeOf(st.permissions) });
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = Io.Dir.cwd().readLink(io, child, &buf) catch return error.Unsnapshottable;
                try symlinks.append(arena, .{ .live = child, .target = try arena.dupe(u8, buf[0..n]) });
            },
            .directory => try captureTree(arena, io, child, depth + 1, max_bytes, total, files, symlinks, dirs),
            // A fifo, socket, device, or other special inode carries no
            // recoverable byte content: refuse the whole tree rather than
            // silently dropping it, since the caller is about to delete the
            // directory this snapshot is the only copy of.
            else => return error.Unsnapshottable,
        }
    }
}

/// Keep every descendant of the live directory `dir_live` through `st`,
/// captured into memory before anything is kept: a descendant that cannot
/// be kept makes `error.Unsnapshottable` propagate with nothing kept, so the
/// caller deletes the live directory only once this returns.
pub fn saveTree(arena: std.mem.Allocator, io: Io, st: *state.Draft, home: []const u8, dir_live: []const u8) !void {
    var files: std.ArrayList(TreeFile) = .empty;
    var symlinks: std.ArrayList(TreeSymlink) = .empty;
    var dirs: std.ArrayList(TreeDir) = .empty;
    var total: usize = 0;
    try captureTree(arena, io, dir_live, 0, tree_max_bytes, &total, &files, &symlinks, &dirs);
    try st.saveTree(home, dir_live, .{ .files = files.items, .symlinks = symlinks.items, .dirs = dirs.items });
}

pub const Restored = struct {
    count: usize = 0,
    /// Entries not restored: each names its live path and where the
    /// generation keeps it.
    refused: []const Refused = &.{},
};

/// Where a refused entry's content is: a file's kept copy, the target a
/// link held, or the generation and key a directory is kept under.
pub const Copy = union(enum) {
    blob: []const u8,
    target: []const u8,
    entry: struct { gen: []const u8, key: []const u8 },

    pub fn format(c: Copy, w: *Io.Writer) Io.Writer.Error!void {
        switch (c) {
            .blob => |p| try w.print("the snapshot copy is at {s}", .{p}),
            .target => |t| try w.print("the link it held points to {s}", .{t}),
            .entry => |e| try w.print("generation {s} keeps it under key {s}", .{ e.gen, e.key }),
        }
    }
};

pub const Refused = struct {
    live_path: []const u8,
    /// Where what it held is.
    copy: Copy,
    why: Why,
    /// For `failed`: what went wrong.
    reason: []const u8 = "",

    pub const Why = enum {
        /// A directory above the live path is a symlink.
        parent_link,
        /// The live path itself is a symlink a restore would destroy.
        is_link,
        /// A symlink sits where the snapshot has a directory.
        dir_over_link,
        /// Restoring it failed; `reason` says how.
        failed,
        /// The snapshot holds a secret line redacted: writing it would put
        /// the placeholder in the live file.
        redacted,
        /// The kept content is missing or no longer matches its name.
        missing,
    };
};

fn refusal(io: Io, home: []const u8, live: []const u8) ?Refused.Why {
    if (parent_link.through(io, home, live, null)) return .parent_link;
    if (isSymlink(io, live)) return .is_link;
    return null;
}

/// `refusal` for a file or symlink entry: a live symlink mox planted (its
/// target is the one the link record holds) is replaced, as rollback
/// replaces any other file mox wrote.
fn entryRefusal(io: Io, st: *const state.Draft, home: []const u8, live: []const u8) ?Refused.Why {
    const why = refusal(io, home, live) orelse return null;
    if (why != .is_link) return why;
    // A link mox planted counts as planted whether or not rollback put it
    // back since.
    const recorded = st.readSymlinkRecord(live) orelse return why;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().readLink(io, live, &buf) catch return why;
    return if (applied.sameSymlinkTarget(buf[0..n], recorded.target)) null else why;
}

/// Keep `bytes`, what a partial re-patch is about to replace at `live`, in
/// the rollback's own displaced history; the caller has masked its secret
/// values.
pub fn keepBytes(st: *state.Draft, home: []const u8, live: []const u8, bytes: []const u8) !void {
    try st.save(home, live, bytes);
}

/// Keep what is at `live` in the rollback's own displaced history before
/// the restore replaces it with `incoming` (null for a link). Nothing is kept
/// when the path is absent, a directory, or already holds exactly what comes
/// in.
fn keepReplaced(arena: std.mem.Allocator, io: Io, st: *state.Draft, home: []const u8, live: []const u8, incoming: ?[]const u8) !void {
    switch (applied.inspectSymSite(io, arena, live)) {
        .absent, .directory => {},
        .symlink => |target| {
            try st.saveSymlink(home, live, target);
            if (st.readSymlinkRecord(live)) |rec| {
                if (applied.sameSymlinkTarget(rec.target, target)) try st.notePlanted(home, live, target, rec.part);
            }
        },
        .other => {
            if (write_mod.guardLiveRead(io, live) == .special) return;
            const bytes = try Io.Dir.cwd().readFileAlloc(io, live, arena, .limited(64 * 1024 * 1024));
            if (incoming) |in| if (std.mem.eql(u8, in, bytes)) return;
            try st.save(home, live, try st.redactPrior(live, bytes, null));
        },
    }
}

/// A displaced file whose live path the caller asked to withhold from the
/// whole-file restore, with its content for its own handling.
pub const Withheld = struct {
    live_path: []const u8,
    content: []const u8,
};

/// Restore every entry generation `src` displaced onto `home`, records kept
/// in step through `st`: a restored file is no longer a link mox planted, a
/// restored link is one when the generation noted it planted, else no link
/// is recorded. A live path in `skip` is withheld from the whole-file write
/// and handed to `skipped` instead; what the restore replaces is kept in
/// `st`'s own displaced history.
pub fn restoreExcept(
    arena: std.mem.Allocator,
    io: Io,
    st: *state.Draft,
    src: state.generation.Generation,
    home: []const u8,
    skip: ?*const std.StringHashMap(void),
    skipped: ?*std.ArrayList(Withheld),
) !Restored {
    var result: Restored = .{};
    var refused: std.ArrayList(Refused) = .empty;
    var planted = std.StringHashMap(state.generation.Planted).init(arena);
    for (src.displaced.values()) |d| if (d.planted) |p| try planted.put(p.live, p);

    const keys = try arena.dupe([]const u8, src.displaced.keys());
    std.mem.sort([]const u8, keys, {}, lessKey);
    const DirEntry = struct { live: []const u8, mode: u32 };
    var dirs: std.ArrayList(DirEntry) = .empty;
    for (keys) |key| {
        const d = src.displaced.get(key).?;
        const live = try source_path.joinKeyOnto(arena, home, key);
        switch (d.type) {
            .dir => {
                if (refusal(io, home, live)) |why| {
                    try refused.append(arena, .{ .live_path = live, .copy = .{ .entry = .{ .gen = src.id, .key = key } }, .why = if (why == .is_link) .dir_over_link else why });
                    continue;
                }
                try dirs.append(arena, .{ .live = live, .mode = d.mode orelse 0o755 });
            },
            .file => {
                const copy: Copy = .{ .blob = try st.blobPath(d.blob orelse continue) };
                restoreFile(arena, io, st, d, live, home, skip, skipped, &result, &refused) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => try refused.append(arena, .{ .live_path = live, .copy = copy, .why = .failed, .reason = @errorName(e) }),
                };
            },
            .link => restoreLink(arena, io, st, d, live, home, &planted, &result, &refused) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => try refused.append(arena, .{ .live_path = live, .copy = .{ .target = d.target orelse "" }, .why = .failed, .reason = @errorName(e) }),
            },
        }
    }
    // Directories last, parents first, then their modes deepest first: a
    // directory going owner-read-only never blocks what is nested inside it.
    for (dirs.items) |e| try Io.Dir.cwd().createDirPath(io, e.live);
    var i = dirs.items.len;
    while (i > 0) {
        i -= 1;
        try write_mod.setMode(dirs.items[i].live, dirs.items[i].mode);
    }
    result.refused = try refused.toOwnedSlice(arena);
    return result;
}

/// Keys with a parent before its children.
fn lessKey(_: void, a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '/');
    var ib = std.mem.splitScalar(u8, b, '/');
    while (true) {
        const x = ia.next() orelse return ib.peek() != null;
        const y = ib.next() orelse return false;
        switch (std.mem.order(u8, x, y)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
}

fn isSymlink(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

fn restoreFile(
    arena: std.mem.Allocator,
    io: Io,
    st: *state.Draft,
    d: state.generation.Displaced,
    live: []const u8,
    home: []const u8,
    skip: ?*const std.StringHashMap(void),
    skipped: ?*std.ArrayList(Withheld),
    result: *Restored,
    refused: *std.ArrayList(Refused),
) !void {
    const copy: Copy = .{ .blob = try st.blobPath(d.blob.?) };
    // A withheld partial target is re-patched by the caller, through a link
    // the user made; only a symlinked parent stops it here.
    const withheld = skip != null and skip.?.contains(live);
    const why_opt: ?Refused.Why = if (withheld)
        (if (parent_link.through(io, home, live, null)) Refused.Why.parent_link else null)
    else
        entryRefusal(io, st, home, live);
    if (why_opt) |why| {
        try refused.append(arena, .{ .live_path = live, .copy = copy, .why = why });
        return;
    }
    const content = (try st.readBlob(d.blob.?)) orelse {
        try refused.append(arena, .{ .live_path = live, .copy = copy, .why = .missing });
        return;
    };
    if (!withheld and std.mem.indexOf(u8, content, prov_map.secret_redaction) != null) {
        try refused.append(arena, .{ .live_path = live, .copy = copy, .why = .redacted });
        return;
    }
    if (withheld) {
        if (skipped) |out| try out.append(arena, .{ .live_path = live, .content = content });
        return;
    }
    try keepReplaced(arena, io, st, home, live, content);
    try write_mod.writeAtomic(io, live, content, d.mode orelse 0o644);
    try st.forgetSymlink(live);
    result.count += 1;
}

fn restoreLink(
    arena: std.mem.Allocator,
    io: Io,
    st: *state.Draft,
    d: state.generation.Displaced,
    live: []const u8,
    home: []const u8,
    planted: *const std.StringHashMap(state.generation.Planted),
    result: *Restored,
    refused: *std.ArrayList(Refused),
) !void {
    const target = d.target orelse return;
    // The link is already there: nothing is restored, records and all.
    switch (applied.inspectSymSite(io, arena, live)) {
        .symlink => |cur| if (applied.sameSymlinkTarget(cur, target)) return,
        else => {},
    }
    if (entryRefusal(io, st, home, live)) |why| {
        try refused.append(arena, .{ .live_path = live, .copy = .{ .target = target }, .why = why });
        return;
    }
    if (std.fs.path.dirname(live)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try keepReplaced(arena, io, st, home, live, null);
    switch (applied.inspectSymSite(io, arena, live)) {
        .absent => {},
        else => try Io.Dir.cwd().deleteFile(io, live),
    }
    try Io.Dir.cwd().symLink(io, target, live, .{});
    // A link the generation notes as planted is recorded as rolled back,
    // under the part its planting named: drift until applied again. Any
    // other link is left with no record, as a link the user made reads.
    const was = planted.get(live);
    if (was != null and applied.sameSymlinkTarget(was.?.target, target)) {
        try st.recordRolledBackLink(live, target, was.?.part);
    } else try st.forget(live);
    result.count += 1;
}

test "lessKey: a parent sorts before its children and its siblings by name" {
    var keys = [_][]const u8{ "a/b", "a.b", "a", "a/b/c", "b" };
    std.mem.sort([]const u8, &keys, {}, lessKey);
    try std.testing.expectEqualStrings("a", keys[0]);
    try std.testing.expectEqualStrings("a/b", keys[1]);
    try std.testing.expectEqualStrings("a/b/c", keys[2]);
    try std.testing.expectEqualStrings("a.b", keys[3]);
}

fn dirMode(io: Io, path: []const u8) !u32 {
    var d = try Io.Dir.cwd().openDir(io, path, .{});
    defer d.close(io);
    return write_mod.modeOf((try d.stat(io)).permissions);
}

test "saveTree + restore round-trips directory modes and empty subdirs, leaving ancestors untouched" {
    if (!Io.File.Permissions.has_executable_bit) return; // no unix modes to preserve
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const home = try std.fs.path.join(a, &.{ base, "home" });
    const st = try state.draft.testDraft(a, io, try std.fs.path.join(a, &.{ base, "state" }));

    const ancestor = try std.fs.path.join(a, &.{ home, ".config" });
    const root = try std.fs.path.join(a, &.{ ancestor, "app" });
    const nested = try std.fs.path.join(a, &.{ root, "sub" });
    const empty = try std.fs.path.join(a, &.{ root, "hole" });
    try Io.Dir.cwd().createDirPath(io, nested);
    try Io.Dir.cwd().createDirPath(io, empty);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ root, "secret" }), "s\n", 0o600);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ nested, "f" }), "x\n", 0o644);
    try write_mod.setMode(ancestor, 0o701);
    try write_mod.setMode(root, 0o700);
    try write_mod.setMode(nested, 0o750);
    try write_mod.setMode(empty, 0o700);

    try saveTree(a, io, st, home, root);
    try Io.Dir.cwd().deleteTree(io, root);

    const back = try state.draft.testDraft(a, io, try std.fs.path.join(a, &.{ base, "state" }));
    const res = try restoreExcept(a, io, back, st.gen, home, null, null);
    try std.testing.expect(res.count >= 2);
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(io, root));
    try std.testing.expectEqual(@as(u32, 0o750), try dirMode(io, nested));
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(io, empty));
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast((try Io.Dir.cwd().statFile(io, try std.fs.path.join(a, &.{ root, "secret" }), .{})).permissions.toMode() & 0o777)));
    try std.testing.expectEqual(@as(u32, 0o701), try dirMode(io, ancestor));
}

test "saveTree: a second tree in one run keeps the first tree's directory modes" {
    if (!Io.File.Permissions.has_executable_bit) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const home = try std.fs.path.join(a, &.{ base, "home" });
    const st = try state.draft.testDraft(a, io, try std.fs.path.join(a, &.{ base, "state" }));
    const one = try std.fs.path.join(a, &.{ home, "one" });
    const two = try std.fs.path.join(a, &.{ home, "two" });
    try Io.Dir.cwd().createDirPath(io, one);
    try Io.Dir.cwd().createDirPath(io, two);
    try write_mod.setMode(one, 0o700);
    try write_mod.setMode(two, 0o750);
    try saveTree(a, io, st, home, one);
    try saveTree(a, io, st, home, two);
    try Io.Dir.cwd().deleteTree(io, one);
    try Io.Dir.cwd().deleteTree(io, two);
    const back = try state.draft.testDraft(a, io, try std.fs.path.join(a, &.{ base, "state" }));
    _ = try restoreExcept(a, io, back, st.gen, home, null, null);
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(io, one));
    try std.testing.expectEqual(@as(u32, 0o750), try dirMode(io, two));
}

test "captureTree: a tree past the depth cap refuses instead of recursing without limit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    var deep = try std.fs.path.join(a, &.{ base, "deep" });
    for (0..tree_max_depth + 4) |_| deep = try std.fs.path.join(a, &.{ deep, "d" });
    try Io.Dir.cwd().createDirPath(io, deep);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ deep, "leaf" }), "x\n", 0o644);
    var files: std.ArrayList(TreeFile) = .empty;
    var symlinks: std.ArrayList(TreeSymlink) = .empty;
    var dirs: std.ArrayList(TreeDir) = .empty;
    var total: usize = 0;
    try std.testing.expectError(error.Unsnapshottable, captureTree(a, io, try std.fs.path.join(a, &.{ base, "deep" }), 0, tree_max_bytes, &total, &files, &symlinks, &dirs));
}

test "captureTree: a tree past the byte cap refuses so a huge directory cannot exhaust memory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const root = try std.fs.path.join(a, &.{ base, "big" });
    try Io.Dir.cwd().createDirPath(io, root);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ root, "a" }), "0123456789", 0o644);
    try write_mod.writeAtomic(io, try std.fs.path.join(a, &.{ root, "b" }), "0123456789", 0o644);
    var files: std.ArrayList(TreeFile) = .empty;
    var symlinks: std.ArrayList(TreeSymlink) = .empty;
    var dirs: std.ArrayList(TreeDir) = .empty;
    var total: usize = 0;
    try std.testing.expectError(error.Unsnapshottable, captureTree(a, io, root, 0, 15, &total, &files, &symlinks, &dirs));
}

test "liveKeyUnderHome: the key a snapshot is filed by, and null for a path outside home" {
    const a = std.testing.allocator;
    const one = (try source_path.liveKeyUnderHome(a, "/home/me", "/home/me/.zshrc")).?;
    defer a.free(one);
    try std.testing.expectEqualStrings(".zshrc", one);
    const two = (try source_path.liveKeyUnderHome(a, "/home/me/", "/home/me/.config/git/config")).?;
    defer a.free(two);
    try std.testing.expectEqualStrings(".config/git/config", two);
    try std.testing.expect((try source_path.liveKeyUnderHome(a, "/home/me", "/etc/passwd")) == null);
    try std.testing.expect((try source_path.liveKeyUnderHome(a, "/home/me", "/home/melon/.zshrc")) == null);
}
