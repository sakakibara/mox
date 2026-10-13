//! Last-applied judgment: how a live file compares to what mox last wrote,
//! the identity a record names, and the encodings records use. What mox
//! last wrote is kept by `src/state/`.

const std = @import("std");
const builtin = @import("builtin");

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

/// The identity records carry: the repo root's real path and the real path
/// of the HOME it was applied under, joined by a NUL (neither path can hold
/// one). A path that cannot be resolved is used as given. A record is one
/// run's only when both match, so a run under another HOME sharing the
/// state directory never takes another HOME's records for its own.
pub fn repoTag(arena: std.mem.Allocator, io: Io, repo_dir: []const u8, home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ try realOrGiven(arena, io, repo_dir), try realOrGiven(arena, io, home) });
}

fn realOrGiven(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    return Io.Dir.realPathFileAbsoluteAlloc(io, path, arena) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return arena.dupe(u8, path),
    };
}

/// `s` percent-encoded: every byte outside `A-Za-z0-9-._~/:` becomes `%XX`,
/// so a record value never holds a space, newline or `%` of its own.
pub fn pctEncode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        const plain = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == '/' or c == ':';
        if (plain) {
            try out.append(arena, c);
        } else {
            var buf: [3]u8 = undefined;
            try out.appendSlice(arena, std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch unreachable);
        }
    }
    return out.toOwnedSlice(arena);
}

/// The inverse of `pctEncode`, or null on a malformed escape.
pub fn pctDecode(arena: std.mem.Allocator, s: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '%') {
            try out.append(arena, s[i]);
            i += 1;
            continue;
        }
        if (i + 3 > s.len) return null;
        const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
        try out.append(arena, v);
        i += 3;
    }
    return try out.toOwnedSlice(arena);
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
    /// The live path the record names.
    live_path: []const u8 = "",
    /// Where the canonical text should be, when it is not secret but is
    /// missing or no longer matches its hash: the record exists, and what
    /// it recorded cannot be compared against.
    canonical_missing: ?[]const u8 = null,
};

/// A symlink record: the target mox planted, and the part that planted it.
pub const SymlinkRecord = struct {
    target: []const u8,
    /// Put back by rollback: drift until it is applied again.
    rolled_back: bool = false,
    part: [hash_hex_len]u8,
};

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
