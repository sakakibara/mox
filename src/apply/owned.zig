//! Drift classification for partially owned files, shared by apply, status,
//! and diff.
//!
//! The one rule (D5/D6): the extracted live owned subtree versus the
//! last-applied owned record decides drift, per path over the union of the
//! record-time and current `own` lists. A path in both lists compares against
//! its recorded section; a path only in the current list is first contact
//! (its composed content may be adopted silently, anything else is drift); a
//! path only in the record list is abandoned and never compared. A
//! secret-bearing record stores one hash over its whole path scope, so drift
//! there is per file. Comparisons are canonical-byte on both sides.

const std = @import("std");

const partial = @import("partial.zig");
const canonical = @import("canonical.zig");
const applied = @import("applied.zig");
const tree_mod = @import("../source/tree.zig");
const keypath = @import("../source/keypath.zig");

pub const OwnPath = tree_mod.OwnPath;
pub const OwnedDoc = partial.OwnedDoc;

/// How a partial file's live owned content relates to the record and the
/// composed owned document. `clean`: live owned equals composed owned (an
/// absent record adopts on the next apply). `outdated`: live owned matches
/// the record but the composed content moved on (apply reasserts without
/// consent). `drift`: some owned path changed outside mox; the payload
/// spells it, and is null for a secret record's whole-scope hash
/// comparison, where drift is per file.
pub const Class = union(enum) {
    clean,
    outdated,
    drift: ?[]const u8,
};

pub fn classify(
    arena: std.mem.Allocator,
    owned: *const OwnedDoc,
    live_doc: *const OwnedDoc,
    own_paths: []const OwnPath,
    record: ?applied.OwnedRecord,
    record_paths: []const OwnPath,
) error{OutOfMemory}!Class {
    const composed_canon = try canonical.canonicalOwned(arena, owned, own_paths);
    const live_canon = try canonical.canonicalOwned(arena, live_doc, own_paths);
    if (std.mem.eql(u8, live_canon, composed_canon)) return .clean;
    if (try driftedPath(arena, owned, live_doc, own_paths, record, record_paths)) |d| {
        return .{ .drift = d.path };
    }
    return .outdated;
}

/// What drifted: a spelled owned path, or a null path for the secret
/// whole-scope hash comparison.
pub const Drifted = struct { path: ?[]const u8 };

/// The first owned path whose live content changed outside mox, or null
/// when every path is at its recorded (or, on first contact, composed)
/// state. For a secret record the recorded scope is hash-compared as one
/// unit after the per-path pass.
pub fn driftedPath(
    arena: std.mem.Allocator,
    owned: *const OwnedDoc,
    live_doc: *const OwnedDoc,
    own_paths: []const OwnPath,
    record: ?applied.OwnedRecord,
    record_paths: []const OwnPath,
) error{OutOfMemory}!?Drifted {
    for (own_paths) |p| {
        const spelled = try canonical.pathSpell(arena, p.segments);
        const one = [_]OwnPath{p};
        const live_sec = try canonical.canonicalOwned(arena, live_doc, &one);
        const in_record = record != null and pathInList(p.segments, record_paths);
        if (in_record and record.?.secret) continue; // hash-compared below
        const want = if (in_record)
            canonical.sectionOf(record.?.canonical.?, spelled) orelse ""
        else blk: {
            // First contact for this path: only its composed content may be
            // adopted silently.
            break :blk try canonical.canonicalOwned(arena, owned, &one);
        };
        if (!std.mem.eql(u8, live_sec, want)) return .{ .path = spelled };
    }
    if (record) |r| {
        if (r.secret) {
            // A record whose path set no longer matches the declaration is
            // stale scope, not evidence of a live edit: its hash covers
            // paths apply no longer owns, so the classification falls
            // through to outdated and reassert re-records under the
            // current scope (touching only current paths).
            if (!samePathSet(own_paths, record_paths)) return null;
            // A secret-bearing record stores one hash over its whole path
            // scope; drift there is per file, not per path.
            const live_rec_canon = try canonical.canonicalOwned(arena, live_doc, record_paths);
            const live_hash = applied.contentHashHex(live_rec_canon);
            if (r.canonical_hash == null or !std.mem.eql(u8, &live_hash, &r.canonical_hash.?)) {
                return .{ .path = null };
            }
        }
    }
    return null;
}

/// The phrase a DRIFT message names the changed content with: the spelled
/// owned path, or the whole owned scope for a secret record's per-file
/// comparison.
pub fn driftWhat(arena: std.mem.Allocator, drift: ?[]const u8) error{OutOfMemory}![]const u8 {
    const p = drift orelse return "owned content";
    return std.fmt.allocPrint(arena, "owned path {s}", .{p});
}

/// Segment-set equality of two path lists, order-independent (own lists
/// never hold duplicates: overlapping declarations are refused).
pub fn samePathSet(a: []const OwnPath, b: []const OwnPath) bool {
    if (a.len != b.len) return false;
    for (a) |p| {
        if (!pathInList(p.segments, b)) return false;
    }
    return true;
}

/// Parse raw dotted-path strings (as stored in an owned record) back into
/// OwnPaths. A recorded raw that no longer parses cannot be located; it is
/// treated as abandoned (dropped from the record scope).
pub fn parseRawPaths(arena: std.mem.Allocator, raws: []const []const u8) error{OutOfMemory}![]OwnPath {
    var list: std.ArrayList(OwnPath) = .empty;
    for (raws) |raw| {
        const segs = keypath.parse(arena, raw) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try list.append(arena, .{ .raw = raw, .segments = segs });
    }
    return list.toOwnedSlice(arena);
}

pub fn pathInList(segments: []const []const u8, list: []const OwnPath) bool {
    for (list) |p| {
        if (p.segments.len != segments.len) continue;
        var all = true;
        for (p.segments, segments) |a, b| {
            if (!std.mem.eql(u8, a, b)) all = false;
        }
        if (all) return true;
    }
    return false;
}

/// Set equality over raw path strings, order-independent.
pub fn sameRawSet(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    const as = arena.dupe([]const u8, a) catch return false;
    const bs = arena.dupe([]const u8, b) catch return false;
    std.mem.sort([]const u8, as, {}, stringLess);
    std.mem.sort([]const u8, bs, {}, stringLess);
    for (as, bs) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn stringLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Concatenate two path lists, deduplicating by segments.
pub fn unionPaths(
    arena: std.mem.Allocator,
    a: []const OwnPath,
    b: []const OwnPath,
) error{OutOfMemory}![]OwnPath {
    var out: std.ArrayList(OwnPath) = .empty;
    for (a) |p| try out.append(arena, p);
    for (b) |p| {
        if (!pathInList(p.segments, out.items)) try out.append(arena, p);
    }
    return out.toOwnedSlice(arena);
}

/// The names an ownership walk rejection prints, so a bad head declaration
/// reads as a diagnosis instead of a bare error code.
pub fn ownDiagText(e: anyerror) []const u8 {
    return switch (e) {
        error.OwnOnUnstructuredTarget => "own requires a structured target (toml/json/yaml/ini/gitconfig)",
        error.OwnOnSymlink => "own cannot combine with symlink",
        error.OwnOnSeedOnce => "own cannot combine with seed_once",
        error.OwnOnGenerator => "own cannot apply to a generator source",
        error.InvalidOwnPath => "own path does not parse as a dotted key path",
        error.InvalidCheckDirective => "check takes one or more double-quoted argv items, once",
        error.CheckWithoutOwnership => "check requires an ownership declaration",
        else => @errorName(e),
    };
}

// Tests

const testing = std.testing;

fn testPaths(arena: std.mem.Allocator, raws: []const []const u8) ![]OwnPath {
    const out = try arena.alloc(OwnPath, raws.len);
    for (raws, out) |raw, *o| o.* = .{ .raw = raw, .segments = try keypath.parse(arena, raw) };
    return out;
}

fn classifyToml(
    arena: std.mem.Allocator,
    composed: []const u8,
    live: []const u8,
    raws: []const []const u8,
    record: ?applied.OwnedRecord,
) !Class {
    const owned = try OwnedDoc.parse(arena, .toml, composed);
    const live_doc = try OwnedDoc.parse(arena, .toml, live);
    const paths = try testPaths(arena, raws);
    const record_paths: []const OwnPath = if (record) |r| try parseRawPaths(arena, r.own_paths) else &.{};
    return classify(arena, &owned, &live_doc, paths, record, record_paths);
}

fn recordOf(arena: std.mem.Allocator, composed: []const u8, raws: []const []const u8) !applied.OwnedRecord {
    const doc = try OwnedDoc.parse(arena, .toml, composed);
    return .{
        .canonical = try canonical.canonicalOwned(arena, &doc, try testPaths(arena, raws)),
        .canonical_hash = null,
        .secret = false,
        .own_paths = raws,
        .secret_paths = &.{},
    };
}

test "classify: clean, outdated, and drifted live owned content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raws = [_][]const u8{"tui"};
    const rec = try recordOf(arena, "[tui]\nk = 1\n", &raws);
    const live = "[tui]\nk = 1\n\n[program]\nstate = 42\n";

    // Live owned == composed owned: clean, program noise invisible.
    try testing.expect(try classifyToml(arena, "[tui]\nk = 1\n", live, &raws, rec) == .clean);
    // Live owned == record, composed moved on: outdated.
    try testing.expect(try classifyToml(arena, "[tui]\nk = 2\n", live, &raws, rec) == .outdated);
    // Live owned changed past the record: drift, naming the path.
    const c = try classifyToml(arena, "[tui]\nk = 1\n", "[tui]\nk = 9\n", &raws, rec);
    try testing.expectEqualStrings("tui", c.drift.?);
}

test "classify: no record differing from composed is drift (first contact), never outdated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raws = [_][]const u8{"tui"};
    const c = try classifyToml(arena, "[tui]\nk = 1\n", "[tui]\nk = 9\n", &raws, null);
    try testing.expectEqualStrings("tui", c.drift.?);
    try testing.expect(try classifyToml(arena, "[tui]\nk = 1\n", "[tui]\nk = 1\n", &raws, null) == .clean);
}

test "classify: a secret record hash-compares its whole recorded scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raws = [_][]const u8{"api"};
    const composed = "[api]\ntoken = \"s3cr3t\"\n";
    const doc = try OwnedDoc.parse(arena, .toml, composed);
    const canon = try canonical.canonicalOwned(arena, &doc, try testPaths(arena, &raws));
    const rec: applied.OwnedRecord = .{
        .canonical = null,
        .canonical_hash = applied.contentHashHex(canon),
        .secret = true,
        .own_paths = &raws,
        .secret_paths = &raws,
    };
    // Live matches the recorded hash, composed changed: outdated.
    try testing.expect(try classifyToml(arena, "[api]\ntoken = \"rotated\"\n", composed, &raws, rec) == .outdated);
    // Live changed past the hash: drift, per file (a null path).
    const c = try classifyToml(arena, composed, "[api]\ntoken = \"leaked\"\n", &raws, rec);
    try testing.expect(c.drift == null);
    // Live matches composed exactly: clean regardless of the record.
    try testing.expect(try classifyToml(arena, composed, composed, &raws, rec) == .clean);
}

test "classify: a secret record with a stale path scope is outdated, never drift" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Record time: own = [api, b], secret, hash over both scopes.
    const old_raws = [_][]const u8{ "api", "b" };
    const old_composed = "[api]\ntoken = \"old\"\n\n[b]\nx = 1\n";
    const old_doc = try OwnedDoc.parse(arena, .toml, old_composed);
    const old_canon = try canonical.canonicalOwned(arena, &old_doc, try testPaths(arena, &old_raws));
    const rec: applied.OwnedRecord = .{
        .canonical = null,
        .canonical_hash = applied.contentHashHex(old_canon),
        .secret = true,
        .own_paths = &old_raws,
        .secret_paths = &.{"api"},
    };

    // Now: own shrank to [api], the secret rotated, and the abandoned b was
    // edited live. The record's hash can no longer be honored (its scope
    // covers a path mox no longer owns), so this is a stale record --
    // outdated -- not a live edit inside the owned scope.
    const raws = [_][]const u8{"api"};
    const live = "[api]\ntoken = \"old\"\n\n[b]\nx = 999\n";
    try testing.expect(try classifyToml(arena, "[api]\ntoken = \"new\"\n", live, &raws, rec) == .outdated);
}
