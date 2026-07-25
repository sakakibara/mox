//! Canonical serialization of owned subtrees.
//!
//! `canonicalOwned` renders the declared subtrees of an owned document as
//! one deterministic byte string: paths sorted, keys sorted at every level,
//! scalar rendering pinned. Two documents with the same owned content
//! produce identical bytes regardless of source spelling, key order, or
//! declaration order, so the owned drift record can be compared (or hashed)
//! byte-wise.
//!
//! STABILITY CONTRACT: this rendering is version-frozen. The owned records
//! mox stores are canonical bytes (or their hash); changing any rule here --
//! ordering, quoting, indentation, a scalar's text -- makes every stored
//! record compare unequal and manufactures phantom drift for every user.
//! The conformance fixtures below freeze the format; a future change must
//! consciously update the goldens and migrate stored records.
//!
//! Shape: one section per populated declared path, in sorted path order.
//! A section is a header line `= <path>` (column 0) followed by the
//! subtree's body, indented two spaces per depth. Container entries render
//! as `key:` with a nested block (`key: {}` when empty); scalar entries as
//! `key = value`; a path whose own value is a scalar renders that scalar as
//! the body. Body lines always start with indentation and scalars never
//! contain a raw newline, so `= ` at column 0 splits sections unambiguously.
//! An unpopulated path contributes nothing.

const std = @import("std");
const toml = @import("toml");
const json = @import("json");
const yaml = @import("yaml");
const ini = @import("ini");

const partial = @import("partial.zig");
const keypath = @import("../source/keypath.zig");

pub const OwnedDoc = partial.OwnedDoc;
pub const AnyValue = partial.AnyValue;
pub const OwnPath = partial.OwnPath;

pub const Error = error{OutOfMemory};

pub fn canonicalOwned(
    arena: std.mem.Allocator,
    doc: *const OwnedDoc,
    own_paths: []const OwnPath,
) Error![]u8 {
    const order = try arena.alloc(usize, own_paths.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, own_paths, pathIdxLess);

    var out: std.ArrayList(u8) = .empty;
    for (order) |i| {
        const p = own_paths[i];
        const sub = doc.subtreeAt(p.segments) orelse continue;
        try out.appendSlice(arena, "= ");
        try out.appendSlice(arena, try pathSpell(arena, p.segments));
        try out.append(arena, '\n');
        try renderBody(arena, &out, sub, 1);
    }
    return out.toOwnedSlice(arena);
}

/// The section for `spelled` (header line included) within a canonical
/// serialization, or null when the blob has no such section. Sections start
/// with `= ` at column 0 and body lines are always indented, so scanning
/// line starts is exact.
pub fn sectionOf(blob: []const u8, spelled: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < blob.len) {
        const line_end = std.mem.indexOfScalarPos(u8, blob, start, '\n') orelse blob.len;
        const line = blob[start..line_end];
        if (line.len >= 2 and std.mem.eql(u8, line[0..2], "= ") and
            std.mem.eql(u8, line[2..], spelled))
        {
            var end = if (line_end < blob.len) line_end + 1 else blob.len;
            while (end < blob.len) {
                if (blob.len - end >= 2 and std.mem.eql(u8, blob[end .. end + 2], "= ")) break;
                end = (std.mem.indexOfScalarPos(u8, blob, end, '\n') orelse return blob[start..blob.len]) + 1;
            }
            return blob[start..end];
        }
        if (line_end >= blob.len) break;
        start = line_end + 1;
    }
    return null;
}

/// Structural view of a canonical blob, parsed back from the pinned text:
/// containers keyed by DECODED segment, leaves holding the pinned inline
/// rendering. Commit diffs two canonical blobs through this per key; values
/// re-enter the format libs from the live document, never from this text.
pub const Node = struct {
    /// Inline text when this node is a scalar leaf; null for a container.
    leaf: ?[]const u8,
    /// Container children; empty for a leaf and for an empty container.
    entries: []const Entry,

    pub const Entry = struct { key: []const u8, node: Node };

    pub fn find(self: Node, key: []const u8) ?Node {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.node;
        }
        return null;
    }
};

pub const TreeError = error{ OutOfMemory, Malformed };

/// Parse a canonical blob (or any concatenation of its sections) back into
/// one tree rooted at the document. Section paths nest into containers, so a
/// section `= a.b` contributes the subtree `a` -> `b`. The grammar is the
/// pinned rendering above and nothing more; any other shape is Malformed.
pub fn parseTree(arena: std.mem.Allocator, blob: []const u8) TreeError!Node {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| try lines.append(arena, line);
    // A trailing newline produces one empty phantom line.
    while (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();

    var root: BNode = .{};
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (line.len < 3 or !std.mem.eql(u8, line[0..2], "= ")) return error.Malformed;
        const segs = keypath.parse(arena, line[2..]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
        i += 1;
        const start = i;
        while (i < lines.items.len and !std.mem.startsWith(u8, lines.items[i], "= ")) i += 1;
        const node = try parseBlock(arena, lines.items[start..i], 1);
        var cur = &root;
        for (segs[0 .. segs.len - 1]) |seg| cur = try bChildContainer(arena, cur, seg);
        if (bFind(cur, segs[segs.len - 1]) != null) return error.Malformed;
        const leaf_node = try arena.create(BNode);
        leaf_node.* = node;
        try cur.entries.append(arena, .{ .key = segs[segs.len - 1], .node = leaf_node });
    }
    return bFinalize(arena, &root);
}

const BNode = struct {
    leaf: ?[]const u8 = null,
    entries: std.ArrayList(BEntry) = .empty,
};
const BEntry = struct { key: []const u8, node: *BNode };

fn bFind(n: *BNode, key: []const u8) ?*BNode {
    for (n.entries.items) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.node;
    }
    return null;
}

fn bChildContainer(arena: std.mem.Allocator, n: *BNode, key: []const u8) TreeError!*BNode {
    if (bFind(n, key)) |child| {
        if (child.leaf != null) return error.Malformed;
        return child;
    }
    const child = try arena.create(BNode);
    child.* = .{};
    try n.entries.append(arena, .{ .key = key, .node = child });
    return child;
}

fn bFinalize(arena: std.mem.Allocator, n: *const BNode) TreeError!Node {
    const out = try arena.alloc(Node.Entry, n.entries.items.len);
    for (n.entries.items, out) |e, *o| o.* = .{ .key = e.key, .node = try bFinalize(arena, e.node) };
    return .{ .leaf = n.leaf, .entries = out };
}

/// One spelled key token at the start of `rest`, or null when `rest` does not
/// begin with a bare or basic-quoted key.
const Token = struct { spell: []const u8, rest: []const u8 };

fn scanToken(rest: []const u8) ?Token {
    if (rest.len == 0) return null;
    if (rest[0] == '"') {
        var i: usize = 1;
        while (i < rest.len) : (i += 1) {
            if (rest[i] == '\\') {
                i += 1;
                continue;
            }
            if (rest[i] == '"') return .{ .spell = rest[0 .. i + 1], .rest = rest[i + 1 ..] };
        }
        return null;
    }
    var i: usize = 0;
    while (i < rest.len and isBareKey(rest[i .. i + 1])) i += 1;
    if (i == 0) return null;
    return .{ .spell = rest[0..i], .rest = rest[i..] };
}

/// Decode one spelled key back to its raw segment. The spell was produced by
/// `keySpell`, whose quoted form is exactly the one-segment key-path grammar.
fn spellDecode(arena: std.mem.Allocator, spell: []const u8) TreeError![]const u8 {
    const segs = keypath.parse(arena, spell) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    if (segs.len != 1) return error.Malformed;
    return segs[0];
}

fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// Parse one section body (or nested block): either a single scalar line or
/// a run of `key = value` / `key:` / `key: {}` entries at `depth`.
fn parseBlock(arena: std.mem.Allocator, lines: []const []const u8, depth: usize) TreeError!BNode {
    const width = depth * 2;
    if (lines.len == 0) return error.Malformed;
    if (leadingSpaces(lines[0]) != width) return error.Malformed;

    const first = lines[0][width..];
    if (std.mem.eql(u8, first, "{}")) {
        if (lines.len != 1) return error.Malformed;
        return .{};
    }
    const first_tok = scanToken(first);
    const is_entries = if (first_tok) |t|
        std.mem.startsWith(u8, t.rest, " = ") or std.mem.eql(u8, t.rest, ":") or std.mem.eql(u8, t.rest, ": {}")
    else
        false;
    if (!is_entries) {
        // A scalar body is always a single line.
        if (lines.len != 1) return error.Malformed;
        return .{ .leaf = first };
    }

    var node: BNode = .{};
    var i: usize = 0;
    while (i < lines.len) {
        const line = lines[i];
        if (leadingSpaces(line) != width) return error.Malformed;
        const rest = line[width..];
        const tok = scanToken(rest) orelse return error.Malformed;
        const key = try spellDecode(arena, tok.spell);
        if (bFind(&node, key) != null) return error.Malformed;
        const child = try arena.create(BNode);
        if (std.mem.startsWith(u8, tok.rest, " = ")) {
            child.* = .{ .leaf = tok.rest[3..] };
            i += 1;
        } else if (std.mem.eql(u8, tok.rest, ": {}")) {
            child.* = .{};
            i += 1;
        } else if (std.mem.eql(u8, tok.rest, ":")) {
            i += 1;
            const sub_start = i;
            while (i < lines.len and leadingSpaces(lines[i]) > width) i += 1;
            child.* = try parseBlock(arena, lines[sub_start..i], depth + 1);
        } else {
            return error.Malformed;
        }
        try node.entries.append(arena, .{ .key = key, .node = child });
    }
    return node;
}

fn pathIdxLess(paths: []const OwnPath, a: usize, b: usize) bool {
    return segsLess(paths[a].segments, paths[b].segments);
}

fn segsLess(a: []const []const u8, b: []const []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        switch (std.mem.order(u8, x, y)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
    return a.len < b.len;
}

/// Canonical spelling of a declared path: decoded segments joined with `.`,
/// each bare when possible and quoted otherwise.
pub fn pathSpell(arena: std.mem.Allocator, segments: []const []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segments, 0..) |seg, i| {
        if (i > 0) try out.append(arena, '.');
        try out.appendSlice(arena, try keySpell(arena, seg));
    }
    return out.toOwnedSlice(arena);
}

fn isBareKey(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

fn keySpell(arena: std.mem.Allocator, s: []const u8) Error![]const u8 {
    if (isBareKey(s)) return s;
    return stringQuote(arena, s);
}

/// Pinned string form: double-quoted, `\"` `\\` `\n` `\r` `\t` escapes,
/// other control bytes as `\u00XX`, all other bytes verbatim.
fn stringQuote(arena: std.mem.Allocator, s: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => {
            if (c < 0x20) {
                try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\\u{x:0>4}", .{c}));
            } else {
                try out.append(arena, c);
            }
        },
    };
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

fn indent(arena: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize) Error!void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(arena, "  ");
}

/// Pinned float form: Zig's shortest decimal, forced to carry a `.0` when it
/// would otherwise read as an integer, so int 1 and float 1.0 never collide.
fn floatText(arena: std.mem.Allocator, f: f64) Error![]const u8 {
    const s = try std.fmt.allocPrint(arena, "{d}", .{f});
    for (s) |c| {
        if (!(std.ascii.isDigit(c) or c == '-')) return s;
    }
    return std.mem.concat(arena, u8, &.{ s, ".0" });
}

fn intText(arena: std.mem.Allocator, v: i128) Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{v});
}

// Sorted-entry helper: index order over a spelled-key slice.

fn spellIdxLess(spells: []const []const u8, a: usize, b: usize) bool {
    return std.mem.order(u8, spells[a], spells[b]) == .lt;
}

fn sortedBySpell(arena: std.mem.Allocator, spells: []const []const u8) Error![]usize {
    const order = try arena.alloc(usize, spells.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, spells, spellIdxLess);
    return order;
}

fn renderBody(arena: std.mem.Allocator, out: *std.ArrayList(u8), v: AnyValue, depth: usize) Error!void {
    switch (v) {
        .toml => |tv| try tomlBody(arena, out, tv, depth),
        .json => |jv| try jsonBody(arena, out, jv, depth),
        .yaml => |yv| try yamlBody(arena, out, yv, depth),
        .ini => |iv| try iniBody(arena, out, iv, depth),
    }
}

// TOML

fn tomlBody(arena: std.mem.Allocator, out: *std.ArrayList(u8), v: toml.Value, depth: usize) Error!void {
    if (v == .table) return tomlTable(arena, out, v.table, depth);
    try indent(arena, out, depth);
    try out.appendSlice(arena, try tomlInline(arena, v));
    try out.append(arena, '\n');
}

fn tomlTable(arena: std.mem.Allocator, out: *std.ArrayList(u8), tbl: toml.Value.Table, depth: usize) Error!void {
    if (tbl.count() == 0) {
        try indent(arena, out, depth);
        try out.appendSlice(arena, "{}\n");
        return;
    }
    const keys = tbl.keys();
    const spells = try arena.alloc([]const u8, keys.len);
    for (keys, spells) |k, *s| s.* = try keySpell(arena, k);
    for (try sortedBySpell(arena, spells)) |i| {
        const val = tbl.values()[i];
        try indent(arena, out, depth);
        try out.appendSlice(arena, spells[i]);
        if (val == .table) {
            if (val.table.count() == 0) {
                try out.appendSlice(arena, ": {}\n");
            } else {
                try out.appendSlice(arena, ":\n");
                try tomlTable(arena, out, val.table, depth + 1);
            }
        } else {
            try out.appendSlice(arena, " = ");
            try out.appendSlice(arena, try tomlInline(arena, val));
            try out.append(arena, '\n');
        }
    }
}

fn tomlInline(arena: std.mem.Allocator, v: toml.Value) Error![]const u8 {
    return switch (v) {
        .string => |s| try stringQuote(arena, s),
        .integer => |i| try intText(arena, i),
        .float => |f| try floatText(arena, f),
        .boolean => |b| if (b) "true" else "false",
        .date => |d| try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day }),
        .time => |t| try tomlTimeText(arena, t),
        .datetime => |dt| blk: {
            const date_s = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ dt.date.year, dt.date.month, dt.date.day });
            const time_s = try tomlTimeText(arena, dt.time);
            const tz: []const u8 = if (dt.tz_offset_minutes) |off| tzblk: {
                if (off == 0) break :tzblk "Z";
                const sign: u8 = if (off < 0) '-' else '+';
                const abs: u16 = @intCast(@abs(off));
                break :tzblk try std.fmt.allocPrint(arena, "{c}{d:0>2}:{d:0>2}", .{ sign, abs / 60, abs % 60 });
            } else "";
            break :blk try std.mem.concat(arena, u8, &.{ date_s, "T", time_s, tz });
        },
        .array => |arr| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '[');
            for (arr.items, 0..) |elem, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, try tomlInline(arena, elem));
            }
            try out.append(arena, ']');
            break :blk try out.toOwnedSlice(arena);
        },
        .table => |tbl| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '{');
            const keys = tbl.keys();
            const spells = try arena.alloc([]const u8, keys.len);
            for (keys, spells) |k, *s| s.* = try keySpell(arena, k);
            for (try sortedBySpell(arena, spells), 0..) |i, n| {
                if (n > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, spells[i]);
                try out.appendSlice(arena, " = ");
                try out.appendSlice(arena, try tomlInline(arena, tbl.values()[i]));
            }
            try out.append(arena, '}');
            break :blk try out.toOwnedSlice(arena);
        },
    };
}

fn tomlTimeText(arena: std.mem.Allocator, t: toml.Time) Error![]const u8 {
    if (t.nanos == 0) {
        return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    }
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}", .{ t.hour, t.minute, t.second, t.nanos });
}

// JSON

fn jsonBody(arena: std.mem.Allocator, out: *std.ArrayList(u8), v: json.Value, depth: usize) Error!void {
    if (v == .object) return jsonObject(arena, out, v.object, depth);
    try indent(arena, out, depth);
    try out.appendSlice(arena, try jsonInline(arena, v));
    try out.append(arena, '\n');
}

fn jsonObject(arena: std.mem.Allocator, out: *std.ArrayList(u8), obj: json.ObjectMap, depth: usize) Error!void {
    if (obj.count() == 0) {
        try indent(arena, out, depth);
        try out.appendSlice(arena, "{}\n");
        return;
    }
    const keys = obj.keys();
    const spells = try arena.alloc([]const u8, keys.len);
    for (keys, spells) |k, *s| s.* = try keySpell(arena, k);
    for (try sortedBySpell(arena, spells)) |i| {
        const val = obj.values()[i];
        try indent(arena, out, depth);
        try out.appendSlice(arena, spells[i]);
        if (val == .object) {
            if (val.object.count() == 0) {
                try out.appendSlice(arena, ": {}\n");
            } else {
                try out.appendSlice(arena, ":\n");
                try jsonObject(arena, out, val.object, depth + 1);
            }
        } else {
            try out.appendSlice(arena, " = ");
            try out.appendSlice(arena, try jsonInline(arena, val));
            try out.append(arena, '\n');
        }
    }
}

fn jsonInline(arena: std.mem.Allocator, v: json.Value) Error![]const u8 {
    return switch (v) {
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer => |i| try intText(arena, i),
        .float => |f| try floatText(arena, f),
        .string => |s| try stringQuote(arena, s),
        .number_raw => |s| s,
        .array => |arr| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '[');
            for (arr, 0..) |elem, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, try jsonInline(arena, elem));
            }
            try out.append(arena, ']');
            break :blk try out.toOwnedSlice(arena);
        },
        .object => |obj| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '{');
            const keys = obj.keys();
            const spells = try arena.alloc([]const u8, keys.len);
            for (keys, spells) |k, *s| s.* = try keySpell(arena, k);
            for (try sortedBySpell(arena, spells), 0..) |i, n| {
                if (n > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, spells[i]);
                try out.appendSlice(arena, " = ");
                try out.appendSlice(arena, try jsonInline(arena, obj.values()[i]));
            }
            try out.append(arena, '}');
            break :blk try out.toOwnedSlice(arena);
        },
    };
}

// YAML

/// A mapping entry list may repeat a key (last-wins in the composed view)
/// and may hold non-string keys; canonical form dedupes to the last value
/// per spelled key and sorts by that spelling.
const YamlEntry = struct { spell: []const u8, value: yaml.Value };

fn yamlDedupe(arena: std.mem.Allocator, entries: []const yaml.Entry) Error![]YamlEntry {
    var out: std.ArrayList(YamlEntry) = .empty;
    for (entries) |e| {
        const spell = switch (e.key) {
            .string => |s| try keySpell(arena, s),
            else => try yamlInline(arena, e.key),
        };
        var replaced = false;
        for (out.items) |*prev| {
            if (std.mem.eql(u8, prev.spell, spell)) {
                prev.value = e.value;
                replaced = true;
                break;
            }
        }
        if (!replaced) try out.append(arena, .{ .spell = spell, .value = e.value });
    }
    return out.toOwnedSlice(arena);
}

fn yamlBody(arena: std.mem.Allocator, out: *std.ArrayList(u8), v: yaml.Value, depth: usize) Error!void {
    if (v == .map) return yamlMap(arena, out, v.map, depth);
    try indent(arena, out, depth);
    try out.appendSlice(arena, try yamlInline(arena, v));
    try out.append(arena, '\n');
}

fn yamlMap(arena: std.mem.Allocator, out: *std.ArrayList(u8), entries: []const yaml.Entry, depth: usize) Error!void {
    const deduped = try yamlDedupe(arena, entries);
    if (deduped.len == 0) {
        try indent(arena, out, depth);
        try out.appendSlice(arena, "{}\n");
        return;
    }
    const spells = try arena.alloc([]const u8, deduped.len);
    for (deduped, spells) |e, *s| s.* = e.spell;
    for (try sortedBySpell(arena, spells)) |i| {
        const val = deduped[i].value;
        try indent(arena, out, depth);
        try out.appendSlice(arena, spells[i]);
        if (val == .map) {
            if ((try yamlDedupe(arena, val.map)).len == 0) {
                try out.appendSlice(arena, ": {}\n");
            } else {
                try out.appendSlice(arena, ":\n");
                try yamlMap(arena, out, val.map, depth + 1);
            }
        } else {
            try out.appendSlice(arena, " = ");
            try out.appendSlice(arena, try yamlInline(arena, val));
            try out.append(arena, '\n');
        }
    }
}

fn yamlInline(arena: std.mem.Allocator, v: yaml.Value) Error![]const u8 {
    return switch (v) {
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .int => |i| try intText(arena, i),
        .float => |f| try floatText(arena, f),
        .string => |s| try stringQuote(arena, s),
        .seq => |elems| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '[');
            for (elems, 0..) |elem, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, try yamlInline(arena, elem));
            }
            try out.append(arena, ']');
            break :blk try out.toOwnedSlice(arena);
        },
        .map => |entries| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '{');
            const deduped = try yamlDedupe(arena, entries);
            const spells = try arena.alloc([]const u8, deduped.len);
            for (deduped, spells) |e, *s| s.* = e.spell;
            for (try sortedBySpell(arena, spells), 0..) |i, n| {
                if (n > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, spells[i]);
                try out.appendSlice(arena, " = ");
                try out.appendSlice(arena, try yamlInline(arena, deduped[i].value));
            }
            try out.append(arena, '}');
            break :blk try out.toOwnedSlice(arena);
        },
    };
}

// INI / gitconfig
//
// Parsed section and key names arrive already case-folded per the dialect,
// so canonical bytes agree across case spellings by construction. A
// repeated key inside one section is a `.list` value at parse time; a
// repeated section entry dedupes last-wins like yaml.

const IniEntry = struct { spell: []const u8, value: ini.Value };

fn iniDedupe(arena: std.mem.Allocator, section: ini.Section) Error![]IniEntry {
    var out: std.ArrayList(IniEntry) = .empty;
    for (section.entries) |e| {
        const spell = try keySpell(arena, e.key);
        var replaced = false;
        for (out.items) |*prev| {
            if (std.mem.eql(u8, prev.spell, spell)) {
                prev.value = e.value;
                replaced = true;
                break;
            }
        }
        if (!replaced) try out.append(arena, .{ .spell = spell, .value = e.value });
    }
    return out.toOwnedSlice(arena);
}

fn iniBody(arena: std.mem.Allocator, out: *std.ArrayList(u8), v: ini.Value, depth: usize) Error!void {
    if (v == .section) return iniSection(arena, out, v.section.*, depth);
    try indent(arena, out, depth);
    try out.appendSlice(arena, try iniInline(arena, v));
    try out.append(arena, '\n');
}

fn iniSection(arena: std.mem.Allocator, out: *std.ArrayList(u8), section: ini.Section, depth: usize) Error!void {
    const deduped = try iniDedupe(arena, section);
    if (deduped.len == 0) {
        try indent(arena, out, depth);
        try out.appendSlice(arena, "{}\n");
        return;
    }
    const spells = try arena.alloc([]const u8, deduped.len);
    for (deduped, spells) |e, *s| s.* = e.spell;
    for (try sortedBySpell(arena, spells)) |i| {
        const val = deduped[i].value;
        try indent(arena, out, depth);
        try out.appendSlice(arena, spells[i]);
        if (val == .section) {
            if ((try iniDedupe(arena, val.section.*)).len == 0) {
                try out.appendSlice(arena, ": {}\n");
            } else {
                try out.appendSlice(arena, ":\n");
                try iniSection(arena, out, val.section.*, depth + 1);
            }
        } else {
            try out.appendSlice(arena, " = ");
            try out.appendSlice(arena, try iniInline(arena, val));
            try out.append(arena, '\n');
        }
    }
}

fn iniInline(arena: std.mem.Allocator, v: ini.Value) Error![]const u8 {
    return switch (v) {
        .string => |s| try stringQuote(arena, s),
        .list => |items| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '[');
            for (items, 0..) |s, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, try stringQuote(arena, s));
            }
            try out.append(arena, ']');
            break :blk try out.toOwnedSlice(arena);
        },
        // A section can only reach here through a malformed tree; render an
        // empty block marker rather than recurse without indentation context.
        .section => "{}",
    };
}

// Tests

const testing = std.testing;

fn testPaths(arena: std.mem.Allocator, raws: []const []const u8) ![]OwnPath {
    const out = try arena.alloc(OwnPath, raws.len);
    for (raws, out) |raw, *o| o.* = .{ .raw = raw, .segments = try keypath.parse(arena, raw) };
    return out;
}

fn canonOf(arena: std.mem.Allocator, format: partial.Format, text: []const u8, raws: []const []const u8) ![]u8 {
    const doc = try OwnedDoc.parse(arena, format, text);
    return canonicalOwned(arena, &doc, try testPaths(arena, raws));
}

test "canonical: identical content in shuffled key and path order is byte-identical" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a_text =
        \\[tui.keymap.global]
        \\zeta = "z"
        \\alpha = 1
        \\
        \\[other]
        \\name = "x"
        \\
    ;
    const b_text =
        \\[other]
        \\name = "x"
        \\
        \\[tui.keymap.global]
        \\alpha = 1
        \\zeta = "z"
        \\
    ;
    const a_canon = try canonOf(arena, .toml, a_text, &.{ "tui.keymap.global", "other" });
    const b_canon = try canonOf(arena, .toml, b_text, &.{ "other", "tui.keymap.global" });
    try testing.expectEqualStrings(a_canon, b_canon);
}

// The five goldens below FREEZE the canonical format. Changing any of them
// invalidates every stored owned record; see the module doc.

test "canonical golden: toml" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\[tui.keymap.global]
        \\zeta = "z"
        \\alpha = 1
        \\pi = 3.5
        \\whole = 2.0
        \\
        \\[tui.keymap.global.sub]
        \\flag = true
        \\
        \\[other]
        \\name = "x y"
        \\list = [1, 2, { b = "t", a = 2 }]
        \\
    ;
    const got = try canonOf(arena, .toml, text, &.{ "tui.keymap.global", "other", "absent" });
    const want =
        \\= other
        \\  list = [1, 2, {a = 2, b = "t"}]
        \\  name = "x y"
        \\= tui.keymap.global
        \\  alpha = 1
        \\  pi = 3.5
        \\  sub:
        \\    flag = true
        \\  whole = 2.0
        \\  zeta = "z"
        \\
    ;
    try testing.expectEqualStrings(want, got);
}

test "canonical golden: json" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "{\"b\": {\"y\": null, \"x\": [1, 2.5, \"s\"], \"empty\": {}}, \"a\": true}";
    const got = try canonOf(arena, .json, text, &.{ "b", "a" });
    const want =
        \\= a
        \\  true
        \\= b
        \\  empty: {}
        \\  x = [1, 2.5, "s"]
        \\  y = null
        \\
    ;
    try testing.expectEqualStrings(want, got);
}

test "canonical golden: yaml" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\b:
        \\  nested:
        \\    k: v
        \\  n: 7
        \\a: [1, two]
        \\
    ;
    const got = try canonOf(arena, .yaml, text, &.{ "a", "b" });
    const want =
        \\= a
        \\  [1, "two"]
        \\= b
        \\  n = 7
        \\  nested:
        \\    k = "v"
        \\
    ;
    try testing.expectEqualStrings(want, got);
}

test "canonical golden: ini" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\[Colors]
        \\FG = red
        \\BG = blue
        \\
    ;
    const got = try canonOf(arena, .ini, text, &.{"colors"});
    const want =
        \\= colors
        \\  bg = "blue"
        \\  fg = "red"
        \\
    ;
    try testing.expectEqualStrings(want, got);
}

test "canonical golden: gitconfig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\[remote "Origin"]
        \\url = a
        \\[User]
        \\name = Some One
        \\email = x@y
        \\
    ;
    const got = try canonOf(arena, .gitconfig, text, &.{ "remote.\"Origin\"", "user" });
    const want =
        \\= remote.Origin
        \\  url = "a"
        \\= user
        \\  email = "x@y"
        \\  name = "Some One"
        \\
    ;
    try testing.expectEqualStrings(want, got);
}

test "canonical: case-folded live spelling matches the declared canonical bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Generic ini folds section and key names, so UPPER and lower spellings
    // canonicalize identically -- the property drift comparison relies on.
    const upper = try canonOf(arena, .ini, "[COLORS]\nFG = red\n", &.{"colors"});
    const lower = try canonOf(arena, .ini, "[colors]\nfg = red\n", &.{"colors"});
    try testing.expectEqualStrings(upper, lower);
}

test "sectionOf: splits a two-section blob and misses an absent path" {
    const blob = "= a\n  true\n= b\n  x = 1\n";
    try testing.expectEqualStrings("= a\n  true\n", sectionOf(blob, "a").?);
    try testing.expectEqualStrings("= b\n  x = 1\n", sectionOf(blob, "b").?);
    try testing.expect(sectionOf(blob, "c") == null);
}

test "canonical: single-path serialization equals that path's section of the full blob" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "[a]\nx = 1\n\n[b]\ny = 2\n";
    const full = try canonOf(arena, .toml, text, &.{ "a", "b" });
    const only_b = try canonOf(arena, .toml, text, &.{"b"});
    try testing.expectEqualStrings(only_b, sectionOf(full, "b").?);
}

test "parseTree: containers, scalars, quoted keys, and empty tables round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\stray = "top"
        \\[tui.keymap]
        \\"a.b" = 1
        \\empty = {}
        \\[tui.keymap.sub]
        \\deep = "x y"
        \\
    ;
    const blob = try canonOf(arena, .toml, text, &.{ "tui.keymap", "stray" });
    const root = try parseTree(arena, blob);

    const stray = root.find("stray").?;
    try testing.expectEqualStrings("\"top\"", stray.leaf.?);

    const keymap = root.find("tui").?.find("keymap").?;
    try testing.expect(keymap.leaf == null);
    try testing.expectEqualStrings("1", keymap.find("a.b").?.leaf.?);
    const empty = keymap.find("empty").?;
    try testing.expect(empty.leaf == null);
    try testing.expectEqual(@as(usize, 0), empty.entries.len);
    try testing.expectEqualStrings("\"x y\"", keymap.find("sub").?.find("deep").?.leaf.?);
}

test "parseTree: a scalar section body that looks like a time is a leaf, not a container" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blob = try canonOf(arena, .toml, "[sched]\nstart = 12:30:00\narr = [1, 2]\n", &.{ "sched.start", "sched.arr" });
    const root = try parseTree(arena, blob);
    try testing.expectEqualStrings("12:30:00", root.find("sched").?.find("start").?.leaf.?);
    try testing.expectEqualStrings("[1, 2]", root.find("sched").?.find("arr").?.leaf.?);
}

test "parseTree: a non-canonical blob is Malformed, never a guess" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.Malformed, parseTree(arena, "not canonical\n"));
    try testing.expectError(error.Malformed, parseTree(arena, "= a\nno indent\n"));
    // An empty blob is a valid empty root.
    const empty = try parseTree(arena, "");
    try testing.expectEqual(@as(usize, 0), empty.entries.len);
}
