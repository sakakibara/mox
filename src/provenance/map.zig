//! Provenance map: where each line of a composed file came from.
//!
//! Compose records, for every run of output lines, the source that produced
//! it (a base-file line, a fragment, a loop data row, a secret, ...). `mox
//! commit` diffs a user-edited live file against the last-composed content and
//! uses this map to route each changed hunk back to the right source: a base
//! edit to `src/`, a fragment edit to its fragment file, a loop-row edit to
//! the data source. Private-origin and secret hunks never route into `src/`.
//!
//! Origin paths are absolute on-disk paths (this map is machine-local state,
//! kept with the last-applied content). The privacy invariant is
//! enforced by the origin TAG (`.private` never routes to repo src), not by
//! the path string.

const std = @import("std");
const json = @import("json");

const Io = std.Io;

pub const Origin = union(enum) {
    /// Verbatim base-file passthrough. `line` is the 1-based base line of the
    /// segment's first output line.
    base: struct { line: u32 },
    /// Fragment emission (include / append / prepend / replace-from / from).
    /// `path` is the absolute fragment file; `line` the 1-based line within it.
    fragment: struct { path: []const u8, line: u32 },
    /// Whole-layer origin for structural (Cat A) / binary (Cat C) files, or a
    /// directive literal body: no line-level attribution, so commit reports it
    /// as manual.
    overlay: struct { path: []const u8 },
    /// A loop body row. `data_source` is the absolute data file; `row` the
    /// 0-based row index; `template` the loop body template a live line is
    /// split against.
    /// `variable` and `site` are known only on a fresh compose and never
    /// persisted: the loop variable, and the loop's index in the compose's
    /// loop list when one was requested.
    loop: struct {
        data_source: []const u8,
        row: u32,
        template: []const u8,
        variable: []const u8 = "",
        site: ?u32 = null,
    },
    /// A resolved secret value: never routed.
    secret,
    /// A base line whose text was changed by `<machine.X>` interpolation:
    /// never routed (would bake the expanded value back into source).
    interpolated: struct { origin_line: u32 },
    /// Private-layer fragment. Routes ONLY to the private layer file at `path`.
    private: struct { path: []const u8, line: u32 },
};

pub const Segment = struct {
    out_start: u32,
    out_len: u32,
    origin: Origin,
};

pub const Map = struct {
    live_path: []const u8,
    segments: []const Segment,
    /// The digests of the secret values the file was written with, when the
    /// map was written with them.
    secret_windows: ?SecretWindows = null,

    /// The digests of the secret values the file was written with, or null
    /// when the map has secret segments but was written without them.
    pub fn secretWindows(m: Map) ?SecretWindows {
        if (m.secret_windows) |w| return w;
        if (!hasSecret(m.segments)) return .{ .key_id = null, .sets = &.{} };
        return null;
    }
};

pub const key_len = 32;
pub const Digest = [2 * std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8;

/// A line of a secret value shorter than this is not looked for.
pub const min_fragment = 4;
/// The longest window of a value's line that is digested.
pub const max_window = 8;

/// The digests of every `k`-byte window of the value lines whose window
/// length is `k`. Sorted, without repeats.
pub const WindowSet = struct {
    k: u32,
    digests: []const Digest,

    fn has(s: WindowSet, d: Digest) bool {
        var lo: usize = 0;
        var hi: usize = s.digests.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, &s.digests[mid], &d)) {
                .eq => return true,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return false;
    }
};

/// Keyed digests of short windows of secret values, so a line holding one
/// is recognized wherever it sits and however it was edited around the
/// value, without the value being kept.
pub const SecretWindows = struct {
    /// Which key made them; null when there are none.
    key_id: ?Digest,
    /// One set per window length, ascending.
    sets: []const WindowSet,

    /// Whether `line` holds a window these digests name.
    pub fn matches(w: SecretWindows, key: *const [key_len]u8, line: []const u8) bool {
        for (w.sets) |s| {
            if (line.len < s.k) continue;
            var i: usize = 0;
            while (i + s.k <= line.len) : (i += 1) {
                if (s.has(windowDigest(key, line[i .. i + s.k]))) return true;
            }
        }
        return false;
    }
};

/// HMAC-SHA256 of `bytes` under `key`, as hex.
pub fn windowDigest(key: *const [key_len]u8, bytes: []const u8) Digest {
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, bytes, key);
    return std.fmt.bytesToHex(mac, .lower);
}

/// The name of `key` that digests record, which says nothing of the key.
pub fn keyId(key: *const [key_len]u8) Digest {
    return windowDigest(key, "mox secret-lines key");
}

/// The window digests of `values` under `key`, together with those of
/// `with`, which `key` made too. Each value is split at newlines; a line of
/// length L shorter than `min_fragment` is skipped, and every window of
/// min(`max_window`, L) bytes of the others is digested.
pub fn windowsOf(arena: std.mem.Allocator, key: *const [key_len]u8, values: []const []const u8, with: ?SecretWindows) !SecretWindows {
    var by_k: [max_window + 1]std.ArrayList(Digest) = @splat(.empty);
    if (with) |w| for (w.sets) |s| {
        if (s.k > max_window) continue;
        try by_k[s.k].appendSlice(arena, s.digests);
    };
    for (values) |v| {
        var it = std.mem.splitScalar(u8, v, '\n');
        while (it.next()) |frag| {
            if (frag.len < min_fragment) continue;
            const k = @min(max_window, frag.len);
            var i: usize = 0;
            while (i + k <= frag.len) : (i += 1) try by_k[k].append(arena, windowDigest(key, frag[i .. i + k]));
        }
    }
    var sets: std.ArrayList(WindowSet) = .empty;
    for (&by_k, 0..) |*list, k| {
        if (list.items.len == 0) continue;
        std.mem.sort(Digest, list.items, {}, struct {
            fn lt(_: void, x: Digest, y: Digest) bool {
                return std.mem.order(u8, &x, &y) == .lt;
            }
        }.lt);
        var n: usize = 0;
        for (list.items) |d| {
            if (n > 0 and std.mem.eql(u8, &list.items[n - 1], &d)) continue;
            list.items[n] = d;
            n += 1;
        }
        try sets.append(arena, .{ .k = @intCast(k), .digests = list.items[0..n] });
    }
    return .{ .key_id = if (sets.items.len > 0) keyId(key) else null, .sets = sets.items };
}

/// Return the single segment fully containing the output-line range
/// `[a_start, a_start + a_len)`. A zero-length range (pure insertion) is
/// covered by the segment whose span includes its position; a range straddling
/// two segments has no single covering segment (caller treats as manual).
pub fn covering(segments: []const Segment, a_start: u32, a_len: u32) ?Segment {
    const a_end = a_start + a_len;
    for (segments) |s| {
        const s_end = s.out_start + s.out_len;
        if (a_len == 0) {
            if (s.out_start <= a_start and a_start <= s_end) return s;
        } else {
            if (s.out_start <= a_start and a_end <= s_end) return s;
        }
    }
    return null;
}

/// Append `origin` covering `n` output lines starting at `line`, coalescing
/// with the previous segment when they form one line-contiguous base or
/// interpolated run (so a multi-line base edit maps to a single segment).
pub fn append(arena: std.mem.Allocator, list: *std.ArrayList(Segment), line: u32, n: u32, origin: Origin) !void {
    if (list.items.len > 0) {
        const last = &list.items[list.items.len - 1];
        if (last.out_start + last.out_len == line) {
            switch (origin) {
                .base => |o| if (last.origin == .base and last.origin.base.line + last.out_len == o.line) {
                    last.out_len += n;
                    return;
                },
                .interpolated => |o| if (last.origin == .interpolated and
                    last.origin.interpolated.origin_line + last.out_len == o.origin_line)
                {
                    last.out_len += n;
                    return;
                },
                else => {},
            }
        }
    }
    try list.append(arena, .{ .out_start = line, .out_len = n, .origin = origin });
}

/// Trim trailing provenance so the total covered output lines equal
/// `target`. Compose emits every split segment (including the phantom empty
/// final segment) plus a per-directive newline, then pops the one extra
/// trailing newline to match the input's final-newline shape; that pop drops
/// exactly one output line the provenance already counted. Shrinking the tail
/// to `target` keeps segments aligned 1:1 with the diff line splitter. Never
/// grows (a shortfall would be a compose bug, left as-is).
pub fn truncateTo(list: *std.ArrayList(Segment), target: u32) void {
    var total: u32 = 0;
    for (list.items) |s| total += s.out_len;
    while (total > target and list.items.len > 0) {
        const last = &list.items[list.items.len - 1];
        const over = total - target;
        if (over >= last.out_len) {
            total -= last.out_len;
            _ = list.pop();
        } else {
            last.out_len -= over;
            total -= over;
        }
    }
}

/// Number of logical lines in `bytes`, using the same rule as the diff line
/// splitter: a single trailing newline does not add an empty final line.
pub fn lineCount(bytes: []const u8) u32 {
    if (bytes.len == 0) return 0;
    var n: u32 = 0;
    for (bytes) |c| {
        if (c == '\n') n += 1;
    }
    if (bytes[bytes.len - 1] != '\n') n += 1;
    return n;
}

/// True when any segment attributes output to a resolved secret. Used by apply
/// to keep the resolved plaintext out of the content cache and snapshots.
pub fn hasSecret(segments: []const Segment) bool {
    for (segments) |s| {
        if (s.origin == .secret) return true;
    }
    return false;
}

/// Placeholder written over a secret's output lines in a redacted snapshot.
pub const secret_redaction = "<mox:redacted-secret>";

/// Return a copy of `content` with every line covered by a `.secret` segment
/// replaced by `secret_redaction`, so a snapshot of secret-bearing content
/// never stores the resolved plaintext. When no secret segment is present the
/// input is returned unchanged (no allocation). Line indices follow the same
/// logical-line rule as `lineCount` (a single trailing newline adds no line).
pub fn redactSecretLines(arena: std.mem.Allocator, content: []const u8, segments: []const Segment) ![]const u8 {
    if (!hasSecret(segments)) return content;

    const total = lineCount(content);
    const redacted = try arena.alloc(bool, total);
    @memset(redacted, false);
    for (segments) |s| {
        if (s.origin != .secret) continue;
        var i: u32 = s.out_start;
        while (i < s.out_start + s.out_len and i < total) : (i += 1) redacted[i] = true;
    }

    var out: std.ArrayList(u8) = .empty;
    const trailing_nl = content.len > 0 and content[content.len - 1] == '\n';
    var lines = std.mem.splitScalar(u8, content, '\n');
    var idx: u32 = 0;
    var first = true;
    while (lines.next()) |line| {
        // The empty final segment after a trailing newline is not a line.
        if (lines.peek() == null and line.len == 0 and trailing_nl) break;
        if (!first) try out.append(arena, '\n');
        first = false;
        if (idx < total and redacted[idx]) {
            try out.appendSlice(arena, secret_redaction);
        } else {
            try out.appendSlice(arena, line);
        }
        idx += 1;
    }
    if (trailing_nl) try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

const version: i128 = 1;

/// Serialize a provenance map to versioned JSON bytes (arena-owned).
/// `secret_windows` is written only when a segment is a secret.
pub fn serialize(arena: std.mem.Allocator, live_path: []const u8, segments: []const Segment, secret_windows: ?SecretWindows) ![]u8 {
    const seg_values = try arena.alloc(json.Value, segments.len);
    for (segments, 0..) |seg, i| seg_values[i] = try segmentToJson(arena, seg);

    var root: json.ObjectMap = .empty;
    try root.put(arena, "v", .{ .integer = version });
    try root.put(arena, "live_path", .{ .string = live_path });
    try root.put(arena, "segments", .{ .array = seg_values });
    if (secret_windows) |w| if (hasSecret(segments)) {
        const sets = try arena.alloc(json.Value, w.sets.len);
        for (w.sets, sets) |set, *out| {
            const digests = try arena.alloc(json.Value, set.digests.len);
            for (set.digests, 0..) |*d, i| digests[i] = .{ .string = d };
            var so: json.ObjectMap = .empty;
            try so.put(arena, "k", .{ .integer = set.k });
            try so.put(arena, "digests", .{ .array = digests });
            out.* = .{ .object = so };
        }
        var obj: json.ObjectMap = .empty;
        try obj.put(arena, "key", if (w.key_id) |*k| .{ .string = k } else .null);
        try obj.put(arena, "sets", .{ .array = sets });
        try root.put(arena, "secret_windows", .{ .object = obj });
    };

    var aw: Io.Writer.Allocating = .init(arena);
    try json.encode(&aw.writer, .{ .object = root }, .{ .indent = 2 });
    try aw.writer.writeByte('\n');
    return aw.toOwnedSlice();
}

fn segmentToJson(arena: std.mem.Allocator, seg: Segment) !json.Value {
    var origin: json.ObjectMap = .empty;
    switch (seg.origin) {
        .base => |o| {
            try origin.put(arena, "kind", .{ .string = "base" });
            try origin.put(arena, "line", .{ .integer = o.line });
        },
        .fragment => |o| {
            try origin.put(arena, "kind", .{ .string = "fragment" });
            try origin.put(arena, "path", .{ .string = o.path });
            try origin.put(arena, "line", .{ .integer = o.line });
        },
        .overlay => |o| {
            try origin.put(arena, "kind", .{ .string = "overlay" });
            try origin.put(arena, "path", .{ .string = o.path });
        },
        .loop => |o| {
            try origin.put(arena, "kind", .{ .string = "loop" });
            try origin.put(arena, "data_source", .{ .string = o.data_source });
            try origin.put(arena, "row", .{ .integer = o.row });
            try origin.put(arena, "template", .{ .string = o.template });
        },
        .secret => try origin.put(arena, "kind", .{ .string = "secret" }),
        .interpolated => |o| {
            try origin.put(arena, "kind", .{ .string = "interpolated" });
            try origin.put(arena, "origin_line", .{ .integer = o.origin_line });
        },
        .private => |o| {
            try origin.put(arena, "kind", .{ .string = "private" });
            try origin.put(arena, "path", .{ .string = o.path });
            try origin.put(arena, "line", .{ .integer = o.line });
        },
    }

    var obj: json.ObjectMap = .empty;
    try obj.put(arena, "out_start", .{ .integer = seg.out_start });
    try obj.put(arena, "out_len", .{ .integer = seg.out_len });
    try obj.put(arena, "origin", .{ .object = origin });
    return .{ .object = obj };
}

pub const ParseError = error{ InvalidProvenance, OutOfMemory } || json.Error;

/// Parse serialized provenance bytes back into a Map. Arena-owned.
pub fn deserialize(arena: std.mem.Allocator, bytes: []const u8) ParseError!Map {
    const v = try json.parse(arena, bytes, .{});
    if (v != .object) return error.InvalidProvenance;
    const live = stringOf(v.get("live_path")) orelse return error.InvalidProvenance;
    const segs_v = v.get("segments") orelse return error.InvalidProvenance;
    if (segs_v != .array) return error.InvalidProvenance;

    var out = try arena.alloc(Segment, segs_v.array.len);
    for (segs_v.array, 0..) |sv, i| out[i] = try segmentFromJson(arena, sv);
    return .{ .live_path = try arena.dupe(u8, live), .segments = out, .secret_windows = try secretWindowsFromJson(arena, v.get("secret_windows")) };
}

fn secretWindowsFromJson(arena: std.mem.Allocator, v: ?json.Value) ParseError!?SecretWindows {
    const val = v orelse return null;
    if (val != .object) return error.InvalidProvenance;
    const key: ?Digest = if (val.get("key")) |k| switch (k) {
        .null => null,
        .string => |str| try digestOf(str),
        else => return error.InvalidProvenance,
    } else return error.InvalidProvenance;
    const sv = val.get("sets") orelse return error.InvalidProvenance;
    if (sv != .array) return error.InvalidProvenance;
    const sets = try arena.alloc(WindowSet, sv.array.len);
    for (sv.array, sets) |set, *out| {
        if (set != .object) return error.InvalidProvenance;
        const k = intOf(set.get("k")) orelse return error.InvalidProvenance;
        if (k == 0 or k > max_window) return error.InvalidProvenance;
        const ds = set.get("digests") orelse return error.InvalidProvenance;
        if (ds != .array) return error.InvalidProvenance;
        const digests = try arena.alloc(Digest, ds.array.len);
        for (ds.array, digests) |d, *o| o.* = try digestOf(stringOf(d) orelse return error.InvalidProvenance);
        out.* = .{ .k = @intCast(k), .digests = digests };
    }
    return .{ .key_id = key, .sets = sets };
}

fn digestOf(s: []const u8) ParseError!Digest {
    if (s.len != @sizeOf(Digest)) return error.InvalidProvenance;
    for (s) |c| if (!std.ascii.isHex(c)) return error.InvalidProvenance;
    return s[0..@sizeOf(Digest)].*;
}

fn segmentFromJson(arena: std.mem.Allocator, sv: json.Value) ParseError!Segment {
    const out_start = intOf(sv.get("out_start")) orelse return error.InvalidProvenance;
    const out_len = intOf(sv.get("out_len")) orelse return error.InvalidProvenance;
    const ov = sv.get("origin") orelse return error.InvalidProvenance;
    const kind = stringOf(ov.get("kind")) orelse return error.InvalidProvenance;

    const origin: Origin = if (std.mem.eql(u8, kind, "base"))
        .{ .base = .{ .line = @intCast(intOf(ov.get("line")) orelse return error.InvalidProvenance) } }
    else if (std.mem.eql(u8, kind, "fragment"))
        .{ .fragment = .{
            .path = try arena.dupe(u8, stringOf(ov.get("path")) orelse return error.InvalidProvenance),
            .line = @intCast(intOf(ov.get("line")) orelse return error.InvalidProvenance),
        } }
    else if (std.mem.eql(u8, kind, "overlay"))
        .{ .overlay = .{ .path = try arena.dupe(u8, stringOf(ov.get("path")) orelse return error.InvalidProvenance) } }
    else if (std.mem.eql(u8, kind, "loop"))
        .{ .loop = .{
            .data_source = try arena.dupe(u8, stringOf(ov.get("data_source")) orelse return error.InvalidProvenance),
            .row = @intCast(intOf(ov.get("row")) orelse return error.InvalidProvenance),
            .template = try arena.dupe(u8, stringOf(ov.get("template")) orelse return error.InvalidProvenance),
        } }
    else if (std.mem.eql(u8, kind, "secret"))
        .secret
    else if (std.mem.eql(u8, kind, "interpolated"))
        .{ .interpolated = .{ .origin_line = @intCast(intOf(ov.get("origin_line")) orelse return error.InvalidProvenance) } }
    else if (std.mem.eql(u8, kind, "private"))
        .{ .private = .{
            .path = try arena.dupe(u8, stringOf(ov.get("path")) orelse return error.InvalidProvenance),
            .line = @intCast(intOf(ov.get("line")) orelse return error.InvalidProvenance),
        } }
    else
        return error.InvalidProvenance;

    return .{ .out_start = @intCast(out_start), .out_len = @intCast(out_len), .origin = origin };
}

fn stringOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn intOf(v: ?json.Value) ?i128 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

const testing = std.testing;

test "hasSecret: detects a secret segment" {
    const with = [_]Segment{
        .{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } },
        .{ .out_start = 1, .out_len = 1, .origin = .secret },
    };
    const without = [_]Segment{
        .{ .out_start = 0, .out_len = 2, .origin = .{ .base = .{ .line = 1 } } },
    };
    try testing.expect(hasSecret(&with));
    try testing.expect(!hasSecret(&without));
}

test "redactSecretLines: blanks secret lines, keeps the rest, preserves trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content = "export FOO=bar\nsupersecret\nexport BAZ=qux\n";
    const segs = [_]Segment{
        .{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } },
        .{ .out_start = 1, .out_len = 1, .origin = .secret },
        .{ .out_start = 2, .out_len = 1, .origin = .{ .base = .{ .line = 3 } } },
    };
    const out = try redactSecretLines(a, content, &segs);
    try testing.expectEqualStrings("export FOO=bar\n" ++ secret_redaction ++ "\nexport BAZ=qux\n", out);
    // "supersecret" must not survive anywhere.
    try testing.expect(std.mem.indexOf(u8, out, "supersecret") == null);

    // With no secret segment the input is returned as-is.
    const clean = [_]Segment{.{ .out_start = 0, .out_len = 3, .origin = .{ .base = .{ .line = 1 } } }};
    try testing.expectEqualStrings(content, try redactSecretLines(a, content, &clean));
}

test "covering: finds fully-contained range, rejects straddling" {
    const segs = [_]Segment{
        .{ .out_start = 0, .out_len = 3, .origin = .{ .base = .{ .line = 1 } } },
        .{ .out_start = 3, .out_len = 2, .origin = .secret },
    };
    try testing.expect(covering(&segs, 1, 1) != null);
    try testing.expect(covering(&segs, 0, 3) != null);
    // Straddles both segments.
    try testing.expect(covering(&segs, 2, 2) == null);
    // Zero-length insertion at the boundary attributes to the first segment.
    const ins = covering(&segs, 3, 0).?;
    try testing.expect(ins.origin == .base);
}

test "append: coalesces contiguous base lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var list: std.ArrayList(Segment) = .empty;
    try append(arena.allocator(), &list, 0, 1, .{ .base = .{ .line = 1 } });
    try append(arena.allocator(), &list, 1, 1, .{ .base = .{ .line = 2 } });
    try append(arena.allocator(), &list, 2, 1, .{ .base = .{ .line = 3 } });
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(u32, 3), list.items[0].out_len);
}

test "append: does not coalesce across origin kinds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var list: std.ArrayList(Segment) = .empty;
    try append(arena.allocator(), &list, 0, 1, .{ .base = .{ .line = 1 } });
    try append(arena.allocator(), &list, 1, 1, .secret);
    try append(arena.allocator(), &list, 2, 1, .{ .base = .{ .line = 2 } });
    try testing.expectEqual(@as(usize, 3), list.items.len);
}

test "truncateTo: trims trailing overflow, splitting a segment when needed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var list: std.ArrayList(Segment) = .empty;
    try list.append(arena.allocator(), .{ .out_start = 0, .out_len = 2, .origin = .{ .base = .{ .line = 1 } } });
    try list.append(arena.allocator(), .{ .out_start = 2, .out_len = 2, .origin = .secret });

    // Drop the one extra line the final-newline pop removed.
    truncateTo(&list, 3);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(@as(u32, 1), list.items[1].out_len);

    // Trimming to a segment boundary drops the whole trailing segment.
    truncateTo(&list, 2);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(u32, 2), list.items[0].out_len);

    // Target at or above the total is a no-op (never grows).
    truncateTo(&list, 9);
    try testing.expectEqual(@as(u32, 2), list.items[0].out_len);
}

test "serialize/deserialize round-trip preserves every origin kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = [_]Segment{
        .{ .out_start = 0, .out_len = 2, .origin = .{ .base = .{ .line = 1 } } },
        .{ .out_start = 2, .out_len = 1, .origin = .{ .fragment = .{ .path = "/abs/frag", .line = 4 } } },
        .{ .out_start = 3, .out_len = 1, .origin = .{ .overlay = .{ .path = "/abs/layer" } } },
        .{ .out_start = 4, .out_len = 1, .origin = .{ .loop = .{ .data_source = "/abs/d.toml", .row = 2, .template = "abbr <entry.key>" } } },
        .{ .out_start = 5, .out_len = 1, .origin = .secret },
        .{ .out_start = 6, .out_len = 1, .origin = .{ .interpolated = .{ .origin_line = 9 } } },
        .{ .out_start = 7, .out_len = 1, .origin = .{ .private = .{ .path = "/priv/frag", .line = 3 } } },
    };
    const bytes = try serialize(a, "/home/me/.zshrc", &segs, null);
    const parsed = try deserialize(a, bytes);
    try testing.expectEqualStrings("/home/me/.zshrc", parsed.live_path);
    try testing.expectEqual(segs.len, parsed.segments.len);
    try testing.expectEqual(@as(u32, 4), parsed.segments[1].origin.fragment.line);
    try testing.expectEqualStrings("/abs/d.toml", parsed.segments[3].origin.loop.data_source);
    try testing.expectEqualStrings("abbr <entry.key>", parsed.segments[3].origin.loop.template);
    try testing.expect(parsed.segments[4].origin == .secret);
    try testing.expect(parsed.segments[6].origin == .private);
}

test "windowsOf: a line holding a window of a value is found, edited around it, under the key that made it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key: [key_len]u8 = @splat(7);
    const segs = [_]Segment{
        .{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } },
        .{ .out_start = 1, .out_len = 1, .origin = .secret },
    };
    const w = try windowsOf(a, &key, &.{ "tok-4c1d-SECRET", "abc", "first-AAAA\nqz7k1" }, null);
    try testing.expect(w.matches(&key, "export T=tok-4c1d-SECRET # x"));
    try testing.expect(w.matches(&key, "..1d-SECRE.."));
    try testing.expect(!w.matches(&key, "...d-SECRE..."));
    try testing.expect(w.matches(&key, "pin qz7k1."));
    try testing.expect(!w.matches(&key, "pin qz7k"));
    try testing.expect(!w.matches(&key, "abc"));
    try testing.expect(!w.matches(&key, "token=other"));
    const other: [key_len]u8 = @splat(8);
    try testing.expect(!w.matches(&other, "tok-4c1d-SECRET"));
    const back = try deserialize(a, try serialize(a, "/h/f", &segs, w));
    try testing.expect(back.secretWindows().?.matches(&key, "tok-4c1d-SECRET"));
    try testing.expectEqual(keyId(&key), back.secretWindows().?.key_id.?);
    const merged = try windowsOf(a, &key, &.{"zzzz-yyyy"}, back.secretWindows().?);
    try testing.expect(merged.matches(&key, "tok-4c1d-SECRET"));
    try testing.expect(merged.matches(&key, "zzzz-yyyy"));
    // Written without them: unknown, unless no segment is a secret.
    try testing.expect((try deserialize(a, try serialize(a, "/h/f", &segs, null))).secretWindows() == null);
    try testing.expectEqual(@as(usize, 0), (try deserialize(a, try serialize(a, "/h/f", segs[0..1], null))).secretWindows().?.sets.len);
}
