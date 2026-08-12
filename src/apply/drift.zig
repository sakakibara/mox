//! Unified drift classifier.
//!
//! The single source `mox status` and `mox apply` both use to decide
//! whether a live path has drifted from what mox composes for it, what kind
//! of drift it is, and what an `--overwrite` of it would replace. Detection
//! itself still runs off the same low-level primitives it always has
//! (`applied.classify`, `owned.classifyMode`, a symlink's recorded target);
//! what this module adds is turning that decision into one comparable
//! `Unit` shape, so a report built from it is deterministic and the two
//! commands cannot silently diverge on what counts as drift.

const std = @import("std");
const applied = @import("applied.zig");
const owned_mod = @import("owned.zig");

/// A drifted unit's kind, and the extra data its report row needs. Closed to
/// the kinds the engine actually emits: no `mode` (apply silently heals an
/// attributed mode on an otherwise-unchanged path; that is not drift), no
/// `whole_dir` (a directory's managed contents are files, symlinks, and
/// generators, each its own unit).
pub const Kind = union(enum) {
    /// A base (whole-file) managed target; overwrite replaces the file.
    whole_file,
    /// A partially-owned file; overwrite replaces only the named key
    /// subtree. Null names a secret-bearing record's whole-scope hash
    /// comparison, which has no single differing key to spell.
    owned_key: ?[]const u8,
    /// A managed symlink; overwrite re-points the link.
    symlink_target,
    /// A `for ... into` generator's produced set; overwrite regenerates the
    /// whole set. Always scoped to the generator's own live path, never an
    /// individual leaf -- a leaf path is not in the managed-file tree, so it
    /// cannot be `--overwrite`-scoped on its own.
    generated_set,
    /// A file mox wrote whose source now composes to nothing (an emptied
    /// template): the live copy was edited, so removing it would lose the
    /// edit. Its resolution REMOVES the file rather than rewriting it -- its
    /// own kind because overwrite deletes here, it does not write.
    vanished,
};

/// One drifted unit: a live path `mox apply` will skip (and `mox status`
/// will flag) until resolved via `mox apply --overwrite` or `mox commit`.
pub const Unit = struct {
    /// The live path. For `generated_set`, the generator's own source path,
    /// not a produced leaf.
    path: []const u8,
    kind: Kind,
    /// True iff mox has no applied record for this path: a file it never
    /// wrote, as opposed to an edit to one it did. Does not apply to
    /// `generated_set` (a generator's leaves may be a mix of first-write and
    /// edited); always false there.
    first_contact: bool,
};

/// The short phrase naming what `--overwrite` replaces for `kind`.
pub fn overwriteScope(kind: Kind) []const u8 {
    return switch (kind) {
        .whole_file => "whole file",
        .owned_key => "that key",
        .symlink_target => "re-point",
        .generated_set => "regenerate the set",
        .vanished => "remove the file",
    };
}

/// The human label naming `kind` for a report row.
pub fn kindLabel(arena: std.mem.Allocator, kind: Kind) ![]const u8 {
    return switch (kind) {
        .whole_file => "whole file",
        .owned_key => |k| if (k) |key| try std.fmt.allocPrint(arena, "owned key '{s}'", .{key}) else "owned content",
        .symlink_target => "symlink target",
        .generated_set => "generated set",
        .vanished => "file to remove",
    };
}

/// The parenthetical explanation for one drifted unit's report row, in the
/// wording `mox apply`'s DRIFT messages have always used (so a script or
/// test matching that text still matches).
pub fn describe(arena: std.mem.Allocator, unit: Unit) ![]const u8 {
    return switch (unit.kind) {
        .whole_file => if (unit.first_contact)
            "mox did not write this file; 'mox commit' it or re-run with --overwrite"
        else
            "live file was edited; 'mox commit' it or re-run with --overwrite",
        .owned_key => |k| blk: {
            const what = if (k) |key| try std.fmt.allocPrint(arena, "owned path {s}", .{key}) else "owned content";
            break :blk try std.fmt.allocPrint(arena, "{s} changed; 'mox commit' it or re-run with --overwrite", .{what});
        },
        .symlink_target => "live entry was not written by mox; 'mox commit' it or re-run with --overwrite",
        .generated_set => "generated set drifted; 'mox commit' it or re-run with --overwrite",
        .vanished => "mox no longer produces this file; re-run with --overwrite to remove it (your copy is snapshotted first), or restore the data that filled it",
    };
}

/// Whole-file drift: wraps `applied.classify`'s disposition into a report
/// unit, null unless it is `.drift`. `first_contact` is read straight off
/// `recorded`, the same last-applied hash lookup `classify` itself takes:
/// true when there is no record, meaning mox never wrote this path.
pub fn wholeFile(live_path: []const u8, recorded: ?[applied.hash_hex_len]u8, live: ?[]const u8, composed: []const u8) ?Unit {
    if (applied.classify(recorded, live, composed) != .drift) return null;
    return .{ .path = live_path, .kind = .whole_file, .first_contact = recorded == null };
}

/// Partially-owned-file drift: wraps an `owned.Class` into a report unit,
/// null unless it is `.drift`. `first_contact` is true when there is no
/// owned record at all for this path.
pub fn ownedFile(live_path: []const u8, class: owned_mod.Class, record: ?applied.OwnedRecord) ?Unit {
    const key = switch (class) {
        .drift => |k| k,
        else => return null,
    };
    return .{ .path = live_path, .kind = .{ .owned_key = key }, .first_contact = record == null };
}

/// Symlink disposition, factored out so `status` and `apply` share one
/// decision instead of two copies that can drift apart: absent is a fresh
/// write; a live symlink matching the composed target is unchanged; one
/// matching the last-applied record but not the current target is a safe
/// reassert (the source moved on, nothing to protect); anything else (a live
/// symlink pointing somewhere mox never recorded, or a non-symlink entry
/// where a link belongs) is drift.
pub fn symlinkDisposition(site: applied.SymSite, recorded_target: ?[]const u8, target: []const u8) applied.Disposition {
    return switch (site) {
        .absent => .fresh_write,
        .symlink => |cur| blk: {
            if (applied.sameSymlinkTarget(cur, target)) break :blk .unchanged;
            if (recorded_target) |rt| if (applied.sameSymlinkTarget(rt, cur)) break :blk .safe_overwrite;
            break :blk .drift;
        },
        // mox never records a non-symlink here, so a directory or any other
        // entry where a link is expected is always drift.
        .directory, .other => .drift,
    };
}

/// Symlink drift: wraps `symlinkDisposition` into a report unit, null unless
/// it is `.drift`. `first_contact` is true when there is no recorded target.
pub fn symlink(live_path: []const u8, site: applied.SymSite, recorded_target: ?[]const u8, target: []const u8) ?Unit {
    if (symlinkDisposition(site, recorded_target, target) != .drift) return null;
    return .{ .path = live_path, .kind = .symlink_target, .first_contact = recorded_target == null };
}

/// A generator's produced-set drift, already known to have happened
/// (a leaf composed differently than its live content, or a prune/orphan
/// pass refused to remove a drifted leaf): always one unit, scoped to the
/// generator's own live path.
pub fn generatedSet(gen_live_path: []const u8) Unit {
    return .{ .path = gen_live_path, .kind = .generated_set, .first_contact = false };
}

/// A file whose source now composes to nothing but whose edited live copy mox
/// must not silently delete. Only ever emitted with a record present (an
/// unrecorded live file mox never wrote is left alone, never vanished), so
/// `first_contact` is always false.
pub fn vanished(live_path: []const u8) Unit {
    return .{ .path = live_path, .kind = .vanished, .first_contact = false };
}

fn lessByPath(_: void, a: Unit, b: Unit) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Sort units by path: the report's sole ordering rule, so it reads the same
/// regardless of tree-walk order and is stable across runs, OSes, and pipes.
pub fn sortByPath(units: []Unit) void {
    std.mem.sort(Unit, units, {}, lessByPath);
}

const testing = std.testing;

test "wholeFile: drift only, carrying first_contact from the record" {
    try testing.expect(wholeFile("/h/.zshrc", null, "same\n", "same\n") == null);

    const edited = wholeFile("/h/.zshrc", applied.contentHashHex("old composed\n"), "hand edit\n", "new composed\n").?;
    try testing.expectEqualStrings("/h/.zshrc", edited.path);
    try testing.expectEqual(Kind.whole_file, edited.kind);
    try testing.expect(!edited.first_contact);

    const first = wholeFile("/h/.zshrc", null, "hand written\n", "composed\n").?;
    try testing.expect(first.first_contact);
}

test "ownedFile: drift only, key spelled from the class, null for a secret whole-scope hash" {
    try testing.expect(ownedFile("/h/app.toml", .clean, null) == null);
    try testing.expect(ownedFile("/h/app.toml", .outdated, null) == null);

    const named = ownedFile("/h/app.toml", .{ .drift = "tui.keymap" }, null).?;
    try testing.expectEqual(Kind{ .owned_key = "tui.keymap" }, named.kind);
    try testing.expect(named.first_contact);

    const rec: applied.OwnedRecord = .{ .canonical = "", .canonical_hash = null, .secret = false, .own_paths = &.{}, .secret_paths = &.{} };
    const whole_scope = ownedFile("/h/app.toml", .{ .drift = null }, rec).?;
    try testing.expectEqual(Kind{ .owned_key = null }, whole_scope.kind);
    try testing.expect(!whole_scope.first_contact);
}

test "symlinkDisposition: matches the disposition rules apply and status both classify by" {
    try testing.expectEqual(applied.Disposition.fresh_write, symlinkDisposition(.absent, null, "/repo/x"));
    try testing.expectEqual(applied.Disposition.unchanged, symlinkDisposition(.{ .symlink = "/repo/x" }, null, "/repo/x"));
    try testing.expectEqual(applied.Disposition.safe_overwrite, symlinkDisposition(.{ .symlink = "/repo/old" }, "/repo/old", "/repo/new"));
    try testing.expectEqual(applied.Disposition.drift, symlinkDisposition(.{ .symlink = "/somewhere/else" }, null, "/repo/x"));
    try testing.expectEqual(applied.Disposition.drift, symlinkDisposition(.directory, null, "/repo/x"));
}

test "symlink: drift only, first_contact from whether a target was ever recorded" {
    try testing.expect(symlink("/h/l", .{ .symlink = "/repo/x" }, null, "/repo/x") == null);

    const foreign = symlink("/h/l", .{ .symlink = "/somewhere/else" }, null, "/repo/x").?;
    try testing.expectEqual(Kind.symlink_target, foreign.kind);
    try testing.expect(foreign.first_contact);

    const moved = symlink("/h/l", .{ .symlink = "/somewhere/else" }, "/repo/old", "/repo/x").?;
    try testing.expect(!moved.first_contact);
}

test "generatedSet: always one unit at the generator's own path, never first contact" {
    const u = generatedSet("/h/.config/gen.inc");
    try testing.expectEqualStrings("/h/.config/gen.inc", u.path);
    try testing.expectEqual(Kind.generated_set, u.kind);
    try testing.expect(!u.first_contact);
}

test "overwriteScope and kindLabel: one phrase per kind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("whole file", overwriteScope(.whole_file));
    try testing.expectEqualStrings("that key", overwriteScope(.{ .owned_key = "k" }));
    try testing.expectEqualStrings("re-point", overwriteScope(.symlink_target));
    try testing.expectEqualStrings("regenerate the set", overwriteScope(.generated_set));

    try testing.expectEqualStrings("whole file", try kindLabel(a, .whole_file));
    try testing.expectEqualStrings("owned key 'tui.keymap'", try kindLabel(a, .{ .owned_key = "tui.keymap" }));
    try testing.expectEqualStrings("owned content", try kindLabel(a, .{ .owned_key = null }));
    try testing.expectEqualStrings("symlink target", try kindLabel(a, .symlink_target));
    try testing.expectEqualStrings("generated set", try kindLabel(a, .generated_set));
}

test "sortByPath: deterministic order regardless of insertion order" {
    var units = [_]Unit{
        .{ .path = "/h/zzz", .kind = .whole_file, .first_contact = false },
        .{ .path = "/h/aaa", .kind = .whole_file, .first_contact = false },
        .{ .path = "/h/mmm", .kind = .whole_file, .first_contact = false },
    };
    sortByPath(&units);
    try testing.expectEqualStrings("/h/aaa", units[0].path);
    try testing.expectEqualStrings("/h/mmm", units[1].path);
    try testing.expectEqualStrings("/h/zzz", units[2].path);
}
