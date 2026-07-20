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
//! stored beside the applied-content snapshot). The privacy invariant is
//! enforced by the origin TAG (`.private` never routes to repo src), not by
//! the path string.

const std = @import("std");
const json = @import("json");

const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

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
    /// 0-based row index; `template` the loop body template (for reverse-parse).
    loop: struct { data_source: []const u8, row: u32, template: []const u8 },
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
};

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
/// to keep the resolved plaintext out of the drift/content cache and snapshots.
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
pub fn serialize(arena: std.mem.Allocator, live_path: []const u8, segments: []const Segment) ![]u8 {
    const seg_values = try arena.alloc(json.Value, segments.len);
    for (segments, 0..) |seg, i| seg_values[i] = try segmentToJson(arena, seg);

    var root: json.ObjectMap = .empty;
    try root.put(arena, "v", .{ .integer = version });
    try root.put(arena, "live_path", .{ .string = live_path });
    try root.put(arena, "segments", .{ .array = seg_values });

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
    return .{ .live_path = try arena.dupe(u8, live), .segments = out };
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

/// Persist provenance for `live_path` under `<state>/provenance/<hash>`.
pub fn persist(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8, segments: []const Segment) !void {
    const path = try recordPath(arena, state_dir, live_path);
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    const bytes = try serialize(arena, live_path, segments);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Read persisted provenance for `live_path`, or null when none / malformed.
pub fn read(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !?Map {
    const path = try recordPath(arena, state_dir, live_path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    return deserialize(arena, bytes) catch null;
}

fn recordPath(arena: std.mem.Allocator, state_dir: []const u8, live_path: []const u8) ![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(live_path, &digest, .{});
    const name = std.fmt.bytesToHex(digest, .lower);
    return std.fs.path.join(arena, &.{ state_dir, "provenance", &name });
}

/// Delete the persisted provenance record for `live_path`. Best-effort: an
/// absent record is not an error. Used when mox stops tracking a path.
pub fn forget(arena: std.mem.Allocator, io: Io, state_dir: []const u8, live_path: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, try recordPath(arena, state_dir, live_path)) catch {};
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
    const bytes = try serialize(a, "/home/me/.zshrc", &segs);
    const parsed = try deserialize(a, bytes);
    try testing.expectEqualStrings("/home/me/.zshrc", parsed.live_path);
    try testing.expectEqual(segs.len, parsed.segments.len);
    try testing.expectEqual(@as(u32, 4), parsed.segments[1].origin.fragment.line);
    try testing.expectEqualStrings("/abs/d.toml", parsed.segments[3].origin.loop.data_source);
    try testing.expectEqualStrings("abbr <entry.key>", parsed.segments[3].origin.loop.template);
    try testing.expect(parsed.segments[4].origin == .secret);
    try testing.expect(parsed.segments[6].origin == .private);
}

test "persist/read round-trip through state dir" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const state_dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

    const segs = [_]Segment{.{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } }};
    try persist(a, io, state_dir, "/home/me/.zshrc", &segs);
    const got = (try read(a, io, state_dir, "/home/me/.zshrc")).?;
    try testing.expectEqual(@as(usize, 1), got.segments.len);
    try testing.expect(try read(a, io, state_dir, "/other/path") == null);
}
