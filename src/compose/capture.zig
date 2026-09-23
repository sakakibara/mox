//! The `<...>` capture grammar: where a capture ends, how its
//! `| default "..."` suffix splits off, and how a fallback chain divides into
//! members. Pure syntax, shared by the interpolator that RESOLVES a capture
//! (`compose.interp`) and the discovery scan that has to find every machine
//! fact one references (`machine.dimensions`) -- one definition, so the two
//! can never disagree about what a chain is.

const std = @import("std");

/// The separator between fallback-chain members, and between a capture body
/// and its `default "..."` suffix.
pub const separator = " | ";

const default_marker = separator ++ "default \"";

/// Index of the `>` that closes the capture opened at `open` (a `<`), null when
/// unclosed. A `| default "..."` value may itself contain `>`, so when that
/// marker is present the close is taken to be the `>` immediately after the
/// default's closing quote (`">`) rather than the first `>` seen.
pub fn closeIndex(template: []const u8, open: usize) ?usize {
    // A `<secret:URI>` capture runs the URI verbatim to the first UNESCAPED `>`:
    // `"` and a literal ` | default "` inside a cmd: URI are payload, not
    // capture syntax, and a `\>` is a literal `>` in the payload (see
    // secretCloseIndex).
    if (std.mem.startsWith(u8, template[open + 1 ..], "secret:"))
        return secretCloseIndex(template, open + 1);
    const naive = std.mem.indexOfScalarPos(u8, template, open + 1, '>') orelse return null;
    // Search only within this capture (up to the first `>`): a marker after it
    // belongs to a later capture. Bounding the scan keeps a template with many
    // captures from being O(n^2).
    const mpos = std.mem.indexOfPos(u8, template[0..naive], open + 1, default_marker) orelse return naive;
    const qstart = mpos + default_marker.len;
    var k = qstart;
    while (k + 1 < template.len) : (k += 1) {
        if (template[k] == '"' and template[k + 1] == '>') return k + 1;
    }
    // Malformed or unusual default (no `">`): fall back to the first `>`.
    return naive;
}

/// Index of the `>` closing a `<secret:URI>` capture, scanning from `start` =
/// the first URI byte. Inside the URI a backslash escapes the next byte, so a
/// `\>` is a literal `>` in the payload (letting a `cmd:` URI carry a shell
/// redirect such as `2>&1`) and does NOT close the capture, and `\\` is a
/// literal backslash; any other backslash stands for itself. Returns null when
/// no unescaped `>` is found.
fn secretCloseIndex(template: []const u8, start: usize) ?usize {
    var k = start;
    while (k < template.len) {
        const ch = template[k];
        if (ch == '\\' and k + 1 < template.len and
            (template[k + 1] == '>' or template[k + 1] == '\\'))
        {
            k += 2;
            continue;
        }
        if (ch == '>') return k;
        k += 1;
    }
    return null;
}

/// Namespace heads a capture body (or one fallback-chain member) may carry. A
/// body starting with none of these, and holding no chain, is not a capture on
/// its own: `compose.interp` resolves it against a loop/record scope or passes
/// it through literally.
pub const namespaces = [_][]const u8{ "machine.", "entry.", "data.", "env." };

/// Whether `field` (a `splitDefault` field, or one chain member) starts with a
/// namespace head.
pub fn hasNamespace(field: []const u8) bool {
    for (namespaces) |ns| {
        if (std.mem.startsWith(u8, field, ns)) return true;
    }
    return false;
}

pub const Split = struct { field: []const u8, default: ?[]const u8 };

/// Split a `<...>` capture body into (field, default). Recognizes the suffix
/// ` | default "..."` and strips it from the field reference.
pub fn splitDefault(inner: []const u8) Split {
    const idx = std.mem.indexOf(u8, inner, default_marker) orelse return .{ .field = inner, .default = null };
    const after = inner[idx + default_marker.len ..];
    const close = std.mem.lastIndexOfScalar(u8, after, '"') orelse return .{ .field = inner, .default = null };
    const field = std.mem.trimEnd(u8, inner[0..idx], " \t");
    return .{ .field = field, .default = after[0..close] };
}

/// Iterator over a capture body's fallback-chain members, each trimmed. A body
/// with no separator yields exactly one member: itself. Feed it
/// `splitDefault(inner).field`, never the raw body -- the `default "..."`
/// suffix is not a member.
pub const MemberIter = struct {
    it: std.mem.SplitIterator(u8, .sequence),

    pub fn next(self: *MemberIter) ?[]const u8 {
        const raw = self.it.next() orelse return null;
        return std.mem.trim(u8, raw, " \t");
    }
};

pub fn members(field: []const u8) MemberIter {
    return .{ .it = std.mem.splitSequence(u8, field, separator) };
}

/// Whether `field` (a `splitDefault` field) holds more than one member.
pub fn isChain(field: []const u8) bool {
    return std.mem.indexOf(u8, field, separator) != null;
}

test "hasNamespace: only a namespace head counts" {
    try std.testing.expect(hasNamespace("machine.email"));
    try std.testing.expect(hasNamespace("env.EDITOR"));
    try std.testing.expect(!hasNamespace("entryname.field"));
}

test "splitDefault: no default" {
    const r = splitDefault("machine.email");
    try std.testing.expectEqualStrings("machine.email", r.field);
    try std.testing.expect(r.default == null);
}

test "splitDefault: with default" {
    const r = splitDefault("machine.email | default \"x@y.com\"");
    try std.testing.expectEqualStrings("machine.email", r.field);
    try std.testing.expectEqualStrings("x@y.com", r.default.?);
}

test "splitDefault: empty default value is fine" {
    const r = splitDefault("env.HTTP_PROXY | default \"\"");
    try std.testing.expectEqualStrings("env.HTTP_PROXY", r.field);
    try std.testing.expectEqualStrings("", r.default.?);
}

test "members: a body with no separator is one member" {
    var it = members("machine.email");
    try std.testing.expectEqualStrings("machine.email", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "members: each chain member is yielded trimmed, in written order" {
    var it = members("env.EDITOR | machine.editor | data.tools.editor");
    try std.testing.expectEqualStrings("env.EDITOR", it.next().?);
    try std.testing.expectEqualStrings("machine.editor", it.next().?);
    try std.testing.expectEqualStrings("data.tools.editor", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "isChain: true only when the body holds a separator" {
    try std.testing.expect(!isChain("machine.email"));
    try std.testing.expect(isChain("env.A | machine.email"));
}
