//! Last-applied content state.
//!
//! mox records the sha256 of every regular file it writes, so a later apply
//! can tell "the live file still holds exactly what mox wrote" (safe to
//! overwrite) apart from user drift (refused without --force, so live edits
//! are never silently destroyed). One record file per live path lives under
//! `<state>/applied/`, named by the sha256 of the live path itself; the
//! record holds the content hash in hex plus the live path for
//! debuggability.

const std = @import("std");
const builtin = @import("builtin");
const json = @import("json");

const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const hash_hex_len = Sha256.digest_length * 2;

pub const Disposition = enum {
    /// No live file exists at the target path.
    fresh_write,
    /// Live content already equals the composed output.
    unchanged,
    /// Live content differs from composed but matches the last-applied
    /// record: everything on disk came from mox, overwriting loses nothing.
    safe_overwrite,
    /// Live content differs from composed and is NOT what mox last wrote
    /// (edited since, or never recorded). Refuse unless forced.
    drift,
};

/// Decide what an apply may do with one file, from the last-applied record
/// (null when none exists), the current live content (null when the live
/// file is absent), and the composed output.
pub fn classify(recorded: ?[hash_hex_len]u8, live: ?[]const u8, composed: []const u8) Disposition {
    const live_bytes = live orelse return .fresh_write;
    if (std.mem.eql(u8, live_bytes, composed)) return .unchanged;
    const rec = recorded orelse return .drift;
    const live_hash = contentHashHex(live_bytes);
    return if (std.mem.eql(u8, &rec, &live_hash)) .safe_overwrite else .drift;
}

pub fn contentHashHex(content: []const u8) [hash_hex_len]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Read the recorded content hash for `live_path`, or null when this path
/// has never been recorded. A malformed record is treated as absent (the
/// conservative direction: absent + differing live content = drift).
pub fn read(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !?[hash_hex_len]u8 {
    const rec_path = try recordPath(arena, state_dir, live_path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, rec_path, arena, .limited(4096)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    if (bytes.len < hash_hex_len) return null;
    var hash: [hash_hex_len]u8 = undefined;
    @memcpy(&hash, bytes[0..hash_hex_len]);
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return hash;
}

/// Record `content` as the bytes mox just wrote to `live_path`.
pub fn record(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8, content: []const u8) !void {
    const rec_path = try recordPath(arena, state_dir, live_path);
    if (std.fs.path.dirname(rec_path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }
    const hash = contentHashHex(content);
    const body = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ &hash, live_path });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = rec_path, .data = body });
}

fn recordPath(arena: std.mem.Allocator, state_dir: []const u8, live_path: []const u8) ![]u8 {
    const name = contentHashHex(live_path);
    return std.fs.path.join(arena, &.{ state_dir, "applied", &name });
}

const max_content_bytes: usize = 64 * 1024 * 1024;

/// Store the exact composed bytes mox wrote to `live_path` under
/// `<state>/applied-content/`, so a later `mox commit` can diff the user's
/// live edits against the last-applied content (the hash record alone can
/// only detect drift, not attribute it).
pub fn recordContent(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8, content: []const u8) !void {
    const path = try contentPath(arena, state_dir, live_path);
    if (std.fs.path.dirname(path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

/// Read the last-applied content for `live_path`, or null when none exists.
pub fn readContent(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !?[]const u8 {
    const path = try contentPath(arena, state_dir, live_path);
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_content_bytes)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

fn contentPath(arena: std.mem.Allocator, state_dir: []const u8, live_path: []const u8) ![]u8 {
    const name = contentHashHex(live_path);
    return std.fs.path.join(arena, &.{ state_dir, "applied-content", &name });
}

/// Last-applied state for a PARTIALLY owned live file. The whole-file
/// hash/content records above never exist for a partial target; drift there
/// is decided against the canonical serialization of the owned subtrees
/// stored here (or its hash when a secret resolved into the owned content --
/// cleartext is never cached, mirroring the whole-file rule).
pub const Mode = enum { own, disown };

pub const OwnedRecord = struct {
    /// Ownership mode at record time: `.own` records the declared subtrees,
    /// `.disown` records the whole document minus them.
    mode: Mode = .own,
    /// Canonical owned serialization at record time; null when `secret`.
    canonical: ?[]const u8,
    /// sha256 hex of the canonical serialization; set when `secret`.
    canonical_hash: ?[hash_hex_len]u8,
    /// True when any owned path's composed value resolved a secret.
    secret: bool,
    /// The `own` declaration in force at record time, raw as written.
    own_paths: []const []const u8,
    /// The declared paths whose composed value resolved a secret, raw.
    secret_paths: []const []const u8,
};

const owned_version: i128 = 1;

/// Record the owned state mox just asserted at `live_path`, under
/// `<state>/applied-owned/`.
pub fn recordOwned(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8, rec: OwnedRecord) !void {
    const path = try ownedPath(arena, state_dir, live_path);
    if (std.fs.path.dirname(path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }

    var root: json.ObjectMap = .empty;
    try root.put(arena, "v", .{ .integer = owned_version });
    try root.put(arena, "live_path", .{ .string = live_path });
    try root.put(arena, "mode", .{ .string = @tagName(rec.mode) });
    try root.put(arena, "secret", .{ .bool = rec.secret });
    if (rec.secret) {
        const hash = rec.canonical_hash orelse return error.MissingCanonicalHash;
        try root.put(arena, "canonical_sha256", .{ .string = try arena.dupe(u8, &hash) });
    } else {
        try root.put(arena, "canonical", .{ .string = rec.canonical orelse return error.MissingCanonical });
    }
    try root.put(arena, "own_paths", .{ .array = try jsonStringArray(arena, rec.own_paths) });
    try root.put(arena, "secret_paths", .{ .array = try jsonStringArray(arena, rec.secret_paths) });

    var aw: Io.Writer.Allocating = .init(arena);
    try json.encode(&aw.writer, .{ .object = root }, .{ .indent = 2 });
    try aw.writer.writeByte('\n');
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

/// Read the owned record for `live_path`, or null when this path has never
/// been recorded. A malformed record reads as absent (conservative: absent
/// plus differing live content classifies as drift, never as clean).
pub fn readOwned(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !?OwnedRecord {
    const path = try ownedPath(arena, state_dir, live_path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_content_bytes)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    const v = json.parse(arena, bytes, .{}) catch return null;
    if (v != .object) return null;
    const secret = switch (v.get("secret") orelse return null) {
        .bool => |b| b,
        else => return null,
    };
    const own_list = (try stringArrayOf(arena, v.get("own_paths"))) orelse return null;
    const secret_list = (try stringArrayOf(arena, v.get("secret_paths"))) orelse return null;
    var rec: OwnedRecord = .{
        .canonical = null,
        .canonical_hash = null,
        .secret = secret,
        .own_paths = own_list,
        .secret_paths = secret_list,
    };
    if (stringOf(v.get("mode"))) |m| {
        rec.mode = std.meta.stringToEnum(Mode, m) orelse return null;
    }
    if (secret) {
        const hex = stringOf(v.get("canonical_sha256")) orelse return null;
        if (hex.len != hash_hex_len) return null;
        var hash: [hash_hex_len]u8 = undefined;
        @memcpy(&hash, hex);
        rec.canonical_hash = hash;
    } else {
        rec.canonical = stringOf(v.get("canonical")) orelse return null;
    }
    return rec;
}

fn jsonStringArray(arena: std.mem.Allocator, items: []const []const u8) ![]json.Value {
    const out = try arena.alloc(json.Value, items.len);
    for (items, out) |s, *o| o.* = .{ .string = s };
    return out;
}

fn stringOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn stringArrayOf(arena: std.mem.Allocator, v: ?json.Value) !?[]const []const u8 {
    const val = v orelse return null;
    if (val != .array) return null;
    const out = try arena.alloc([]const u8, val.array.len);
    for (val.array, out) |elem, *o| o.* = stringOf(elem) orelse return null;
    return out;
}

fn ownedPath(arena: std.mem.Allocator, state_dir: []const u8, live_path: []const u8) ![]u8 {
    const name = contentHashHex(live_path);
    return std.fs.path.join(arena, &.{ state_dir, "applied-owned", &name });
}

const max_symlink_target_bytes: usize = 64 * 1024;

/// Record the symlink `target` mox last materialized at `live_path`, under
/// `<state>/applied-symlink/`. Lets a later apply tell "mox wrote this link
/// (source target changed, safe to update)" from "the user put something here"
/// (drift), mirroring the content-hash record for regular files.
pub fn recordSymlink(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8, target: []const u8) !void {
    const path = try symlinkPath(arena, state_dir, live_path);
    if (std.fs.path.dirname(path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = target });
}

/// Read the last-applied symlink target for `live_path`, or null when none.
pub fn readSymlink(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !?[]const u8 {
    const path = try symlinkPath(arena, state_dir, live_path);
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_symlink_target_bytes)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

fn symlinkPath(arena: std.mem.Allocator, state_dir: []const u8, live_path: []const u8) ![]u8 {
    const name = contentHashHex(live_path);
    return std.fs.path.join(arena, &.{ state_dir, "applied-symlink", &name });
}

/// Delete every last-applied record for `live_path` (content hash, content
/// cache, symlink target, and owned record). Best-effort: an absent record is
/// not an error. Used when mox stops tracking a path (a generator leaf pruned
/// away) so a future unrelated file at the same path is not mistaken for
/// mox-written.
pub fn forget(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, try recordPath(arena, state_dir, live_path)) catch {};
    Io.Dir.cwd().deleteFile(io, try contentPath(arena, state_dir, live_path)) catch {};
    Io.Dir.cwd().deleteFile(io, try symlinkPath(arena, state_dir, live_path)) catch {};
    Io.Dir.cwd().deleteFile(io, try ownedPath(arena, state_dir, live_path)) catch {};
}

/// Delete only the owned record for `live_path`. `mox mv` re-keys the record
/// to the new live path and drops the old one with this; the other records
/// never exist for a partial target, so the full `forget` sweep is not needed.
pub fn forgetOwned(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, try ownedPath(arena, state_dir, live_path)) catch {};
}

/// What currently occupies a live path, inspected without following symlinks.
pub const SymSite = union(enum) {
    absent,
    symlink: []const u8,
    directory,
    /// A regular file or any other non-symlink, non-directory entry.
    other,
};

/// Inspect `live_path` without dereferencing a symlink there. A read/stat
/// failure other than "absent" is reported as `.other` so it is treated as
/// drift (protected), never as an empty/absent path.
pub fn inspectSymSite(io: Io, arena: std.mem.Allocator, live_path: []const u8) SymSite {
    const st = Io.Dir.cwd().statFile(io, live_path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return .absent,
        else => return .other,
    };
    return switch (st.kind) {
        .sym_link => blk: {
            // A target may be up to the platform's path max; a smaller buffer
            // would truncate a long link and misclassify it as drift.
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = Io.Dir.cwd().readLink(io, live_path, &buf) catch break :blk SymSite.other;
            break :blk .{ .symlink = arena.dupe(u8, buf[0..n]) catch return .other };
        },
        .directory => .directory,
        else => .other,
    };
}

/// Compare two symlink targets. On Windows the OS stores a link target with
/// backslash separators, so a forward-slash source (`/tmp/x`, the portable form
/// dotfiles are written in) reads back as `\tmp\x`; treating `\` and `/` as
/// equivalent there keeps drift detection from firing on every apply. On POSIX
/// `\` is an ordinary target byte, so the compare is exact.
pub fn sameSymlinkTarget(a: []const u8, b: []const u8) bool {
    if (builtin.os.tag != .windows) return std.mem.eql(u8, a, b);
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na = if (ca == '\\') '/' else ca;
        const nb = if (cb == '\\') '/' else cb;
        if (na != nb) return false;
    }
    return true;
}

test "classify: no live file is a fresh write" {
    try std.testing.expectEqual(Disposition.fresh_write, classify(null, null, "new\n"));
}

test "classify: live equal to composed is unchanged regardless of record" {
    try std.testing.expectEqual(Disposition.unchanged, classify(null, "same\n", "same\n"));
    try std.testing.expectEqual(Disposition.unchanged, classify(contentHashHex("same\n"), "same\n", "same\n"));
}

test "classify: live matching the record is a safe overwrite" {
    const rec = contentHashHex("old composed\n");
    try std.testing.expectEqual(Disposition.safe_overwrite, classify(rec, "old composed\n", "new composed\n"));
}

test "classify: live differing from the record is drift" {
    const rec = contentHashHex("old composed\n");
    try std.testing.expectEqual(Disposition.drift, classify(rec, "user edited\n", "new composed\n"));
}

test "classify: no record and differing live content is drift" {
    try std.testing.expectEqual(Disposition.drift, classify(null, "hand-written\n", "composed\n"));
}

fn stateDirAbs(alloc: std.mem.Allocator, io: Io, sub_path: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, alloc);
    return std.fs.path.join(alloc, &.{ cwd, ".zig-cache", "tmp", sub_path, "state" });
}

test "recordContent then readContent round-trips the exact bytes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    const content = "export EDITOR=nvim\nexport PAGER=less\n";
    try recordContent(a, io, state_dir, "/home/me/.zshrc", content);

    const got = try readContent(a, io, state_dir, "/home/me/.zshrc");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(content, got.?);
    // A path never recorded reads back null.
    try std.testing.expect(try readContent(a, io, state_dir, "/home/me/.other") == null);
}

test "recordOwned then readOwned round-trips a cleartext record, forget removes it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    const canon = "= tui.keymap.global\n  submit = \"enter\"\n";
    try recordOwned(a, io, state_dir, "/home/me/.codex/config.toml", .{
        .canonical = canon,
        .canonical_hash = null,
        .secret = false,
        .own_paths = &.{ "tui.keymap.global", "projects.\"/tmp/x\"" },
        .secret_paths = &.{},
    });

    const got = (try readOwned(a, io, state_dir, "/home/me/.codex/config.toml")).?;
    try std.testing.expect(!got.secret);
    try std.testing.expectEqualStrings(canon, got.canonical.?);
    try std.testing.expect(got.canonical_hash == null);
    try std.testing.expectEqual(@as(usize, 2), got.own_paths.len);
    try std.testing.expectEqualStrings("tui.keymap.global", got.own_paths[0]);
    try std.testing.expectEqualStrings("projects.\"/tmp/x\"", got.own_paths[1]);
    try std.testing.expectEqual(@as(usize, 0), got.secret_paths.len);
    // A path never recorded reads back null.
    try std.testing.expect(try readOwned(a, io, state_dir, "/home/me/.other") == null);

    try forget(a, io, state_dir, "/home/me/.codex/config.toml");
    try std.testing.expect(try readOwned(a, io, state_dir, "/home/me/.codex/config.toml") == null);
}

test "recordOwned: a secret-bearing record stores the hash and never the canonical text" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    const canon = "= api\n  token = \"cleartext-secret\"\n";
    try recordOwned(a, io, state_dir, "/home/me/app.toml", .{
        .canonical = null,
        .canonical_hash = contentHashHex(canon),
        .secret = true,
        .own_paths = &.{"api"},
        .secret_paths = &.{"api"},
    });

    const got = (try readOwned(a, io, state_dir, "/home/me/app.toml")).?;
    try std.testing.expect(got.secret);
    try std.testing.expect(got.canonical == null);
    const expected = contentHashHex(canon);
    try std.testing.expectEqualStrings(&expected, &got.canonical_hash.?);
    try std.testing.expectEqual(@as(usize, 1), got.secret_paths.len);
    try std.testing.expectEqualStrings("api", got.secret_paths[0]);

    // The stored record file itself never holds the canonical cleartext.
    const rec_file = try ownedPath(a, state_dir, "/home/me/app.toml");
    const bytes = try Io.Dir.cwd().readFileAlloc(io, rec_file, a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "cleartext-secret") == null);
}

test "recordSymlink then readSymlink round-trips the target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state_dir = try stateDirAbs(a, io, &tmp.sub_path);

    try recordSymlink(a, io, state_dir, "/home/me/.config/nvim", "/repo/nvim");
    const got = try readSymlink(a, io, state_dir, "/home/me/.config/nvim");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("/repo/nvim", got.?);
    try std.testing.expect(try readSymlink(a, io, state_dir, "/home/me/.other") == null);
}
