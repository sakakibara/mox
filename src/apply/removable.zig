//! The one judgment of whether mox may remove a live path it once wrote.
//!
//! The stale sweep, the orphan sweep, the generator prune, named paths and
//! every preview call `judge`, so what a preview promises is what the run
//! does. The checks run in one order: still produced or managed, the same
//! file as a kept one (device and inode), ignored, behind a symlinked
//! directory, then what is there against what mox recorded.

const std = @import("std");
const Io = std.Io;
const applied = @import("applied.zig");
const stale = @import("stale.zig");
const parent_link = @import("parent_link.zig");
const write = @import("write.zig");
const source_path = @import("../source/path.zig");
const ignore_match = @import("../source/ignore/match.zig");

const max_content_bytes: usize = 64 * 1024 * 1024;

pub const Ctx = struct {
    home: []const u8,
    /// Live paths still produced or managed this run.
    keep: ?*const std.StringHashMap(void) = null,
    /// The identities of the kept paths that exist.
    kept: ?*const stale.Kept = null,
    ruleset: ?*const ignore_match.RuleSet = null,
    /// Live paths the tree plants as symlinks.
    links: ?*const std.StringHashMap(void) = null,
};

/// What mox last put at the path, as its records say.
pub const Wrote = union(enum) {
    /// A whole file with this content hash; null when no record holds one.
    whole: ?[applied.hash_hex_len]u8,
    /// A symlink to this target.
    symlink: []const u8,
    /// A partially owned file: the program owns the rest of it.
    owned,
    /// A link mox planted that rollback put back: drift until applied again.
    rolled_back,
};

/// What is at the path now, as a removal would snapshot it.
pub const Found = union(enum) {
    link: []const u8,
    file: []const u8,
};

pub const Verdict = union(enum) {
    /// Still produced or managed: not a removal at all.
    kept,
    /// The same file as a kept path (a case-only rename, a hard link):
    /// forget its records, remove nothing.
    same_file,
    /// Matched by `.moxignore`: left alone, records and all.
    ignored,
    /// Below a symlinked directory: left in place, its records forgotten.
    linked_parent,
    /// Nothing there any more: forget its records.
    gone,
    /// A directory now, where mox recorded a file or a link: its records are
    /// forgotten, nothing is removed.
    now_dir,
    /// A partially owned file: left in place, its records forgotten.
    leave,
    /// A directory, a special file or an unreadable one: never removed.
    refused: []const u8,
    /// Changed since mox wrote it: removed only with `--overwrite`.
    drift: struct { why: []const u8, found: Found },
    /// Exactly what mox wrote: removed, snapshot first.
    remove: Found,
};

/// What a stale record says mox wrote.
pub fn wroteOf(c: stale.Candidate) Wrote {
    return switch (c.kind) {
        .whole => .{ .whole = c.hash },
        .symlink => if (c.rolled_back) .rolled_back else .{ .symlink = c.target },
        .owned => .owned,
    };
}

pub fn judge(arena: std.mem.Allocator, io: Io, c: Ctx, live_path: []const u8, wrote: Wrote) !Verdict {
    if (c.keep) |k| if (k.contains(live_path)) return .kept;
    if (c.kept) |k| if (stale.sameFile(io, live_path, k)) return .same_file;
    if (c.ruleset) |rs| {
        if (parent_link.underHome(live_path, c.home) and rs.isPathIgnored(try source_path.liveKeyRelToHome(arena, c.home, live_path), false)) return .ignored;
    }
    if (parent_link.through(io, c.home, live_path, c.links)) return .linked_parent;

    const site = applied.inspectSymSite(io, arena, live_path);
    switch (site) {
        .absent => return .gone,
        .directory => return .now_dir,
        .symlink, .other => {},
    }
    if (wrote == .owned) return .leave;
    if (site == .symlink) {
        const target = site.symlink;
        return switch (wrote) {
            .symlink => |want| if (applied.sameSymlinkTarget(target, want)) .{ .remove = .{ .link = target } } else .{ .drift = .{ .why = "points elsewhere", .found = .{ .link = target } } },
            .rolled_back => .{ .drift = .{ .why = "put back by rollback", .found = .{ .link = target } } },
            else => .{ .drift = .{ .why = "now a symlink", .found = .{ .link = target } } },
        };
    }
    if (write.guardLiveRead(io, live_path) == .special) return .{ .refused = "is not a regular file, not removing" };
    const content = Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(max_content_bytes)) catch |e| switch (e) {
        error.FileNotFound => return .gone,
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .refused = "cannot be read to back up, not removing" },
    };
    return switch (wrote) {
        .whole => |h| if (h != null and std.mem.eql(u8, &h.?, &applied.contentHashHex(content))) .{ .remove = .{ .file = content } } else .{ .drift = .{ .why = "edited", .found = .{ .file = content } } },
        .symlink, .rolled_back => .{ .drift = .{ .why = "no longer a symlink", .found = .{ .file = content } } },
        .owned => unreachable,
    };
}

/// How `judge` rules on the symlink mox planted at `live_path`, now that a
/// file belongs there; null when no record names a link mox planted.
pub fn plantedLink(arena: std.mem.Allocator, io: Io, state_dir: []const u8, home: []const u8, live_path: []const u8) !?Verdict {
    const target = (try applied.plantedLink(arena, io, state_dir, live_path)) orelse return null;
    return try judge(arena, io, .{ .home = home }, live_path, .{ .symlink = target });
}

test "judge: the checks run in one order, keep first and the records last" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const home = try std.fs.path.join(a, &.{ root, "h" });
    try tmp.dir.createDirPath(io, "h/d");
    try tmp.dir.writeFile(io, .{ .sub_path = "h/f", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "h/kept", .data = "k\n" });
    try tmp.dir.hardLink("h/kept", tmp.dir, "h/twin", io, .{});
    const f = try std.fs.path.join(a, &.{ home, "f" });
    const kept = try std.fs.path.join(a, &.{ home, "kept" });
    const twin = try std.fs.path.join(a, &.{ home, "twin" });
    const clean: Wrote = .{ .whole = applied.contentHashHex("x\n") };

    var keep = std.StringHashMap(void).init(a);
    try keep.put(kept, {});
    var ids = try stale.inodesOf(a, io, &.{kept});
    const c: Ctx = .{ .home = home, .keep = &keep, .kept = &ids };

    try testing.expect(try judge(a, io, c, kept, clean) == .kept);
    try testing.expect(try judge(a, io, c, twin, clean) == .same_file);
    try testing.expect(try judge(a, io, c, f, clean) == .remove);
    try testing.expect(try judge(a, io, c, f, .{ .whole = null }) == .drift);
    try testing.expect(try judge(a, io, c, f, .owned) == .leave);
    try testing.expect(try judge(a, io, c, try std.fs.path.join(a, &.{ home, "d" }), clean) == .now_dir);
    try testing.expect(try judge(a, io, c, try std.fs.path.join(a, &.{ home, "none" }), clean) == .gone);
}
