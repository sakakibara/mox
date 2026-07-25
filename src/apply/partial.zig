//! Span-based partial-ownership operations on live structured files.
//!
//! A partial file is owned per key-path: mox manages the declared subtrees
//! and never changes a byte outside them. This module locates each declared
//! path's byte span in the live text, splices the composed owned content
//! over those spans (remainder carried verbatim), and verifies the result
//! with the two-part invariant: per-path content equality against the owned
//! document, and byte equality of the remainders.
//!
//! Span rules per format:
//! - toml: a declared table's span runs from its `[header]` line through the
//!   start of the next header that is not under the path (or end of file),
//!   sub-tables included. A blank/comment run preceding the header belongs
//!   to the remainder. A declared leaf key's span is its `key = value` line.
//! - json: a declared member's span is its key and value plus the separator
//!   comma needed for a clean splice (trailing comma for a non-last member,
//!   leading comma for a last member, container interior for a sole member).
//! - yaml: a declared member's span is the full line range of its key and
//!   block value. Flow-style containers on the path are refused.
//! - ini/gitconfig: a declared section's span covers its `[section]` /
//!   `[section "sub"]` block to the next header (or end of file); a declared
//!   key's span is its entry line including continuations. Section and key
//!   names match with the dialect's case rules; subsections are verbatim.
//!
//! Shapes the span model cannot address are refused with a named error and
//! a diagnostic naming the path; nothing is guessed.

const std = @import("std");
const toml = @import("toml");
const json = @import("json");
const yaml = @import("yaml");
const ini = @import("ini");

const format_mod = @import("../source/format.zig");
const tree_mod = @import("../source/tree.zig");
const provmap = @import("../provenance/map.zig");

pub const Format = format_mod.Format;
pub const OwnPath = tree_mod.OwnPath;

pub const Diag = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

fn diagSet(diag: ?*Diag, comptime fmt: []const u8, args: anytype) void {
    const d = diag orelse return;
    if (std.fmt.bufPrint(&d.buf, fmt, args)) |s| {
        d.len = s.len;
    } else |_| {
        d.len = d.buf.len;
    }
}

pub const LocateError = error{
    OutOfMemory,
    LiveUnparseable,
    OwnedPathUnaddressable,
    OwnedPathDottedSpelling,
    OwnedPathAliased,
    OwnedPathMergeKey,
    OwnedPathNonStringKey,
    OwnedPathDuplicate,
};

pub const ReplaceError = LocateError || error{OwnedRenderFailed};

pub const VerifyError = ReplaceError || error{
    CandidateUnparseable,
    OwnedContentMismatch,
    RemainderMismatch,
};

/// Half-open byte range into the text a locate ran against.
pub const Span = struct { start: usize, end: usize };

pub const Located = struct {
    /// Parallel to the declared paths; null means no live presence.
    spans: []const ?Span,
    /// Container framing (section headers, wrapper members) whose content
    /// is provably all owned but which no single path's span covers. Used
    /// by the remainder byte check only. Accepted narrow blind spot: the
    /// framing bytes themselves are excluded from that check, so a
    /// discrepancy confined to a wrapper's own line (its spelling or a
    /// same-line comment) would pass it.
    wrappers: []const Span,
};

/// The parsed value tree of one format.
pub const AnyValue = union(enum) {
    toml: toml.Value,
    json: json.Value,
    yaml: yaml.Value,
    ini: ini.Value,
};

fn iniDialect(format: Format) ini.Dialect {
    return if (format == .gitconfig) ini.Dialect.gitconfig else ini.Dialect.generic;
}

/// The composed owned document: the parse of the composed source text,
/// queried per declared path. Later folds reuse this as the record and
/// canonicalization input.
pub const OwnedDoc = struct {
    format: Format,
    root: AnyValue,

    pub fn parse(arena: std.mem.Allocator, format: Format, text: []const u8) error{ OutOfMemory, OwnedUnparseable }!OwnedDoc {
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            // An empty composed source populates nothing; not every format
            // parser accepts empty input, so represent it directly.
            const empty_root: AnyValue = switch (format) {
                .toml => .{ .toml = .{ .table = .empty } },
                .json => .{ .json = .{ .object = .empty } },
                .yaml => .{ .yaml = .null },
                .ini, .gitconfig => blk: {
                    const root = try arena.create(ini.Section);
                    root.* = .{ .entries = &.{} };
                    break :blk .{ .ini = .{ .section = root } };
                },
            };
            return .{ .format = format, .root = empty_root };
        }
        const root: AnyValue = switch (format) {
            .toml => .{ .toml = toml.parse(arena, text, .{}) catch |e| return parseFail(e) },
            .json => .{ .json = json.parse(arena, text, .{ .dialect = .jsonc }) catch |e| return parseFail(e) },
            .yaml => .{ .yaml = yaml.parse(arena, text, .{}) catch |e| return parseFail(e) },
            .ini, .gitconfig => .{ .ini = ini.parse(arena, text, .{ .dialect = iniDialect(format) }) catch |e| return parseFail(e) },
        };
        return .{ .format = format, .root = root };
    }

    fn parseFail(e: anyerror) error{ OutOfMemory, OwnedUnparseable } {
        return if (e == error.OutOfMemory) error.OutOfMemory else error.OwnedUnparseable;
    }

    /// The owned value under `segments`, or null when the composed document
    /// does not populate the path.
    pub fn subtreeAt(self: *const OwnedDoc, segments: []const []const u8) ?AnyValue {
        return subtreeOf(self.format, self.root, segments);
    }

    pub fn populated(self: *const OwnedDoc, segments: []const []const u8) bool {
        return self.subtreeAt(segments) != null;
    }
};

/// Walk `segments` through a parsed value tree, dialect-aware for ini.
fn subtreeOf(format: Format, root: AnyValue, segments: []const []const u8) ?AnyValue {
    switch (root) {
        .toml => |v| {
            var cur = v;
            for (segments) |seg| {
                if (cur != .table) return null;
                cur = cur.table.get(seg) orelse return null;
            }
            return .{ .toml = cur };
        },
        .json => |v| {
            var cur = v;
            for (segments) |seg| {
                if (cur != .object) return null;
                cur = cur.object.get(seg) orelse return null;
            }
            return .{ .json = cur };
        },
        .yaml => |v| {
            var cur = v;
            for (segments) |seg| {
                if (cur != .map) return null;
                cur = yamlMapGet(cur.map, seg) orelse return null;
            }
            return .{ .yaml = cur };
        },
        .ini => |v| {
            const dialect = iniDialect(format);
            var cur = v;
            for (segments, 0..) |seg, depth| {
                if (cur != .section) return null;
                cur = iniFindEntry(cur.section.*, dialect, seg, depth) orelse return null;
            }
            return .{ .ini = cur };
        },
    }
}

/// Last entry with a string key equal to `k` (yaml duplicate keys are
/// last-wins in the composed view).
fn yamlMapGet(map: []const yaml.Entry, k: []const u8) ?yaml.Value {
    var found: ?yaml.Value = null;
    for (map) |e| {
        if (e.key == .string and std.mem.eql(u8, e.key.string, k)) found = e.value;
    }
    return found;
}

/// One segment comparison, optionally case-folded -- the comparison every
/// dialect-aware matcher (value lookup, declaration check) shares.
fn segEqFold(stored: []const u8, declared: []const u8, fold: bool) bool {
    return if (fold) std.ascii.eqlIgnoreCase(stored, declared) else std.mem.eql(u8, stored, declared);
}

/// Fold rule for one ini entry by its role: sections fold at the root, a
/// nested section (gitconfig subsection) is verbatim, keys fold per the
/// dialect. Stored section and key names are already case-folded by the
/// parser; subsection names are stored verbatim.
fn iniEntryFold(dialect: ini.Dialect, is_section: bool, depth: usize) bool {
    return if (is_section)
        depth == 0 and dialect.case_insensitive_sections
    else
        dialect.case_insensitive_keys;
}

/// Dialect-aware entry lookup: the declared segment matches by the role the
/// entry has.
fn iniFindEntry(section: ini.Section, dialect: ini.Dialect, seg: []const u8, depth: usize) ?ini.Value {
    for (section.entries) |e| {
        if (segEqFold(e.key, seg, iniEntryFold(dialect, e.value == .section, depth))) return e.value;
    }
    return null;
}

// Shared segment helpers

fn segsEq(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// True when `p` is a segment-prefix of `full` (equality included).
fn segsPrefix(p: []const []const u8, full: []const []const u8) bool {
    if (p.len > full.len) return false;
    for (p, full[0..p.len]) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn lineStartOf(src: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and src[j - 1] != '\n') j -= 1;
    return j;
}

/// Offset just past the newline ending the line containing `i` (or len).
fn lineEndOf(src: []const u8, i: usize) usize {
    var j = i;
    while (j < src.len and src[j] != '\n') j += 1;
    return if (j < src.len) j + 1 else j;
}

/// Declared paths must address disjoint subtrees: one path nested under
/// another would locate the same bytes twice.
fn checkPathOverlap(own_paths: []const OwnPath, diag: ?*Diag) LocateError!void {
    for (own_paths, 0..) |a, i| {
        for (own_paths[i + 1 ..]) |b| {
            if (segsPrefix(a.segments, b.segments) or segsPrefix(b.segments, a.segments)) {
                diagSet(diag, "{s}: overlaps declared path {s}", .{ a.raw, b.raw });
                return error.OwnedPathDuplicate;
            }
        }
    }
}

/// Internal locate result: the public span/wrapper view plus the per-path
/// shape replaceOwned splices by.
const Form = enum { none, block, kv, member };

const FullLocated = struct {
    spans: []?Span,
    forms: []Form,
    wrappers: []Span,
};

pub fn locateSpans(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    own_paths: []const OwnPath,
    diag: ?*Diag,
) LocateError!Located {
    const full = try locateFull(arena, format, live, own_paths, diag);
    return .{ .spans = full.spans, .wrappers = full.wrappers };
}

fn locateFull(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    own_paths: []const OwnPath,
    diag: ?*Diag,
) LocateError!FullLocated {
    try checkPathOverlap(own_paths, diag);
    return switch (format) {
        .toml => tomlLocate(arena, live, own_paths, diag),
        .json => jsonLocate(arena, live, own_paths, diag),
        .yaml => yamlLocate(arena, live, own_paths, diag),
        .ini, .gitconfig => iniLocate(arena, format, live, own_paths, diag),
    };
}

/// Build the candidate text: remainder bytes verbatim, each populated
/// declared path's live span replaced by the owned document's rendering of
/// that path (block form), unpopulated spans removed, populated paths with
/// no live span appended per the format's placement rule.
pub fn replaceOwned(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    own_paths: []const OwnPath,
    owned: *const OwnedDoc,
    diag: ?*Diag,
) ReplaceError![]u8 {
    // Refusal shapes surface before any construction.
    _ = try locateFull(arena, format, live, own_paths, diag);
    return switch (format) {
        .toml => tomlReplace(arena, live, own_paths, owned, diag),
        .json => jsonReplace(arena, live, own_paths, owned, diag),
        .yaml => yamlReplace(arena, live, own_paths, owned, diag),
        .ini, .gitconfig => iniReplace(arena, format, live, own_paths, owned, diag),
    };
}

/// The executable core invariant, both parts:
/// 1. per declared path, the candidate's parsed content equals the owned
///    document's content (deep value equality; fold 3 upgrades this to a
///    canonical-byte comparison);
/// 2. live bytes minus owned spans equal candidate bytes minus owned spans
///    (appended spans count only on the candidate side).
pub fn verifyInvariant(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    candidate: []const u8,
    own_paths: []const OwnPath,
    owned: *const OwnedDoc,
    diag: ?*Diag,
) VerifyError!void {
    const cand_root: AnyValue = switch (format) {
        .toml => .{ .toml = toml.parse(arena, candidate, .{}) catch |e| return verifyParseFail(e) },
        .json => .{ .json = json.parse(arena, candidate, .{ .dialect = .jsonc }) catch |e| return verifyParseFail(e) },
        .yaml => .{ .yaml = yaml.parse(arena, candidate, .{}) catch |e| return verifyParseFail(e) },
        .ini, .gitconfig => .{ .ini = ini.parse(arena, candidate, .{ .dialect = iniDialect(format) }) catch |e| return verifyParseFail(e) },
    };

    for (own_paths) |p| {
        const owned_sub = owned.subtreeAt(p.segments);
        const cand_sub = subtreeOf(format, cand_root, p.segments);
        if (owned_sub == null and cand_sub == null) continue;
        if (owned_sub == null or cand_sub == null or !anyValueEql(owned_sub.?, cand_sub.?)) {
            diagSet(diag, "{s}: candidate content does not match the owned document", .{p.raw});
            return error.OwnedContentMismatch;
        }
    }

    const live_loc = try locateFull(arena, format, live, own_paths, diag);
    const cand_loc = locateFull(arena, format, candidate, own_paths, diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LiveUnparseable => return error.CandidateUnparseable,
        else => return e,
    };

    const live_rest = try remainderBytes(arena, live, live_loc);
    const cand_rest = try remainderBytes(arena, candidate, cand_loc);

    if (live.len == 0 and format == .json) {
        // A missing live JSON file gains the root braces with the first
        // append; they are appended structure, not remainder.
        if (std.mem.eql(u8, cand_rest, "") or std.mem.eql(u8, cand_rest, "{}")) return;
        diagSet(diag, "remainder gained bytes beyond the created root object", .{});
        return error.RemainderMismatch;
    }
    if (std.mem.eql(u8, live_rest, cand_rest)) return;
    // A splice after live content with no final newline owns its separator
    // newline: the live remainder keeps its missing final newline
    // byte-exactly, and the one joining byte belongs to the owned region it
    // introduces. Attribute one such byte and retry; anything else refuses.
    if (live.len > 0 and live[live.len - 1] != '\n' and
        try separatorAttributedMatch(arena, candidate, cand_loc, live_rest)) return;
    diagSet(diag, "candidate changed bytes outside the owned spans", .{});
    return error.RemainderMismatch;
}

/// True when attributing one separator newline to some owned region of the
/// candidate makes the remainders byte-equal. Every region preceded by a
/// newline is tried, and the moved byte must account for the entire
/// difference, so nothing beyond the separator rule can pass here.
fn separatorAttributedMatch(
    arena: std.mem.Allocator,
    candidate: []const u8,
    loc: FullLocated,
    live_rest: []const u8,
) error{OutOfMemory}!bool {
    const regions = try collectRegions(arena, loc);
    for (regions, 0..) |r, i| {
        if (r.start == 0 or candidate[r.start - 1] != '\n') continue;
        const adjusted = try arena.dupe(Span, regions);
        adjusted[i].start -= 1;
        if (std.mem.eql(u8, live_rest, try remainderOfRegions(arena, candidate, adjusted))) return true;
    }
    return false;
}

fn verifyParseFail(e: anyerror) VerifyError {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.CandidateUnparseable;
}

/// D2 leaf rule: every leaf the composed document defines must sit under a
/// declared path. Returns the spelled path of the first undeclared leaf, or
/// null when the document lies within the declaration. A leaf is a
/// non-container value, or an empty container that is not a pure
/// intermediate on a declared route; intermediate containers implied by the
/// syntax are traversal, not violations.
pub fn undeclaredLeaf(
    arena: std.mem.Allocator,
    owned: *const OwnedDoc,
    own_paths: []const OwnPath,
) error{OutOfMemory}!?[]const u8 {
    var path: std.ArrayList([]const u8) = .empty;
    var folds: std.ArrayList(bool) = .empty;
    // A yaml document with no content parses to null at the root; it
    // defines nothing.
    if (owned.root == .yaml and owned.root.yaml == .null) return null;
    return undeclaredWalk(arena, owned.format, owned.root, own_paths, &path, &folds);
}

fn undeclaredWalk(
    arena: std.mem.Allocator,
    format: Format,
    v: AnyValue,
    own_paths: []const OwnPath,
    path: *std.ArrayList([]const u8),
    folds: *std.ArrayList(bool),
) error{OutOfMemory}!?[]const u8 {
    if (pathAtOrUnderDeclaredFold(own_paths, path.items, folds.items)) return null;
    const is_container = switch (v) {
        .toml => |tv| tv == .table,
        .json => |jv| jv == .object,
        .yaml => |yv| yv == .map,
        .ini => |iv| iv == .section,
    };
    if (!is_container) return try diagPathSpell(arena, path.items);

    var count: usize = 0;
    switch (v) {
        .toml => |tv| {
            count = tv.table.count();
            for (tv.table.keys(), tv.table.values()) |k, sub| {
                try path.append(arena, k);
                try folds.append(arena, false);
                defer _ = path.pop();
                defer _ = folds.pop();
                if (try undeclaredWalk(arena, format, .{ .toml = sub }, own_paths, path, folds)) |hit| return hit;
            }
        },
        .json => |jv| {
            count = jv.object.count();
            for (jv.object.keys(), jv.object.values()) |k, sub| {
                try path.append(arena, k);
                try folds.append(arena, false);
                defer _ = path.pop();
                defer _ = folds.pop();
                if (try undeclaredWalk(arena, format, .{ .json = sub }, own_paths, path, folds)) |hit| return hit;
            }
        },
        .yaml => |yv| {
            count = yv.map.len;
            for (yv.map) |entry| {
                if (entry.key != .string) return try diagPathSpell(arena, path.items);
                try path.append(arena, entry.key.string);
                try folds.append(arena, false);
                defer _ = path.pop();
                defer _ = folds.pop();
                if (try undeclaredWalk(arena, format, .{ .yaml = entry.value }, own_paths, path, folds)) |hit| return hit;
            }
        },
        .ini => |iv| {
            count = iv.section.entries.len;
            for (iv.section.entries) |entry| {
                const fold = iniEntryFold(iniDialect(format), entry.value == .section, path.items.len);
                try path.append(arena, entry.key);
                try folds.append(arena, fold);
                defer _ = path.pop();
                defer _ = folds.pop();
                if (try undeclaredWalk(arena, format, .{ .ini = entry.value }, own_paths, path, folds)) |hit| return hit;
            }
        },
    }
    if (count == 0 and !pathStrictPrefixOfDeclaredFold(own_paths, path.items, folds.items)) {
        return try diagPathSpell(arena, path.items);
    }
    return null;
}

/// `segsPrefix` with a per-position fold flag parallel to `stored` -- how a
/// declared path matches a walked document path under the format's dialect
/// (the same role rules `iniFindEntry` applies).
fn segsPrefixFold(declared: []const []const u8, stored: []const []const u8, folds: []const bool) bool {
    if (declared.len > stored.len) return false;
    for (declared, stored[0..declared.len], folds[0..declared.len]) |d, s, fold| {
        if (!segEqFold(s, d, fold)) return false;
    }
    return true;
}

fn pathAtOrUnderDeclaredFold(own_paths: []const OwnPath, stored: []const []const u8, folds: []const bool) bool {
    for (own_paths) |p| if (segsPrefixFold(p.segments, stored, folds)) return true;
    return false;
}

fn pathStrictPrefixOfDeclaredFold(own_paths: []const OwnPath, stored: []const []const u8, folds: []const bool) bool {
    for (own_paths) |p| {
        if (stored.len >= p.segments.len) continue;
        var all = true;
        for (stored, folds, p.segments[0..stored.len]) |s, fold, d| {
            if (!segEqFold(s, d, fold)) all = false;
        }
        if (all) return true;
    }
    return false;
}

/// Diagnostic spelling of a key path: segments joined with `.`, quoted when
/// not bare. For messages only; canonical spelling lives in canonical.zig.
fn diagPathSpell(arena: std.mem.Allocator, segments: []const []const u8) error{OutOfMemory}![]const u8 {
    if (segments.len == 0) return "(root)";
    var out: std.ArrayList(u8) = .empty;
    for (segments, 0..) |seg, i| {
        if (i > 0) try out.append(arena, '.');
        var bare = seg.len > 0;
        for (seg) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) bare = false;
        }
        if (bare) {
            try out.appendSlice(arena, seg);
        } else {
            try out.append(arena, '"');
            try out.appendSlice(arena, seg);
            try out.append(arena, '"');
        }
    }
    return out.toOwnedSlice(arena);
}

/// Placeholder written over owned secret values in a pre-write snapshot.
pub const secret_mask = "<mox:secret>";

/// A copy of `live` with every leaf value under the given paths replaced by
/// `secret_mask`, edited through the format's lossless Document model so
/// the rest of the file survives byte-for-byte. A path with no live
/// presence contributes nothing. Any shape the edit cannot address fails
/// the mask (the caller must then refuse rather than snapshot cleartext).
pub fn maskSecretPaths(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    secret_paths: []const OwnPath,
) error{ OutOfMemory, MaskFailed }![]u8 {
    if (secret_paths.len == 0 or live.len == 0) return arena.dupe(u8, live);
    const doc_vals = OwnedDoc.parse(arena, format, live) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => return error.MaskFailed,
    };

    var leaves: std.ArrayList([]const []const u8) = .empty;
    for (secret_paths) |p| {
        const sub = doc_vals.subtreeAt(p.segments) orelse continue;
        try collectLeafPaths(arena, sub, p.segments, &leaves);
    }
    if (leaves.items.len == 0) return arena.dupe(u8, live);

    switch (format) {
        .toml => {
            var doc = toml.Document.parse(arena, live, .{}) catch return error.MaskFailed;
            for (leaves.items) |lp| doc.setValueSegments(lp, .{ .string = secret_mask }) catch return error.MaskFailed;
            return emitMasked(arena, &doc);
        },
        .json => {
            var doc = json.Document.parse(arena, live, .{ .dialect = .jsonc }) catch return error.MaskFailed;
            for (leaves.items) |lp| doc.setValueSegments(lp, .{ .string = secret_mask }) catch return error.MaskFailed;
            return emitMasked(arena, &doc);
        },
        .yaml => {
            var doc = yaml.Document.parse(arena, live, .{}) catch return error.MaskFailed;
            for (leaves.items) |lp| doc.setValueSegments(lp, .{ .string = secret_mask }) catch return error.MaskFailed;
            return emitMasked(arena, &doc);
        },
        .ini, .gitconfig => {
            var doc = ini.Document.parse(arena, live, .{ .dialect = iniDialect(format) }) catch return error.MaskFailed;
            for (leaves.items) |lp| doc.setValueSegments(lp, .{ .string = secret_mask }) catch return error.MaskFailed;
            return emitMasked(arena, &doc);
        },
    }
}

/// Every leaf key path at or under `base` within `v`. A non-string yaml key
/// cannot be addressed by the Document edit; fail rather than leave its
/// value unmasked.
fn collectLeafPaths(
    arena: std.mem.Allocator,
    v: AnyValue,
    base: []const []const u8,
    out: *std.ArrayList([]const []const u8),
) error{ OutOfMemory, MaskFailed }!void {
    const is_container = switch (v) {
        .toml => |tv| tv == .table,
        .json => |jv| jv == .object,
        .yaml => |yv| yv == .map,
        .ini => |iv| iv == .section,
    };
    if (!is_container) {
        try out.append(arena, try arena.dupe([]const u8, base));
        return;
    }
    switch (v) {
        .toml => |tv| for (tv.table.keys(), tv.table.values()) |k, sub| {
            try collectLeafPaths(arena, .{ .toml = sub }, try childPath(arena, base, k), out);
        },
        .json => |jv| for (jv.object.keys(), jv.object.values()) |k, sub| {
            try collectLeafPaths(arena, .{ .json = sub }, try childPath(arena, base, k), out);
        },
        .yaml => |yv| for (yv.map) |entry| {
            if (entry.key != .string) return error.MaskFailed;
            try collectLeafPaths(arena, .{ .yaml = entry.value }, try childPath(arena, base, entry.key.string), out);
        },
        .ini => |iv| for (iv.section.entries) |entry| {
            try collectLeafPaths(arena, .{ .ini = entry.value }, try childPath(arena, base, entry.key), out);
        },
    }
}

fn childPath(arena: std.mem.Allocator, base: []const []const u8, key: []const u8) error{OutOfMemory}![]const []const u8 {
    const out = try arena.alloc([]const u8, base.len + 1);
    @memcpy(out[0..base.len], base);
    out[base.len] = key;
    return out;
}

fn emitMasked(arena: std.mem.Allocator, doc: anytype) error{ OutOfMemory, MaskFailed }![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    doc.emit(&aw.writer) catch return error.MaskFailed;
    return arena.dupe(u8, aw.written());
}

/// Which declared paths hold a resolved secret, from the composed TEXT's
/// line provenance: a path is secret-bearing when any line of its span in
/// the composed text is covered by a `.secret` segment. Returns a flag
/// slice parallel to `own_paths`. Line indices are the provenance map's
/// 0-based logical lines.
pub fn secretPathFlags(
    arena: std.mem.Allocator,
    format: Format,
    composed: []const u8,
    own_paths: []const OwnPath,
    segments: []const provmap.Segment,
    diag: ?*Diag,
) LocateError![]bool {
    const flags = try arena.alloc(bool, own_paths.len);
    @memset(flags, false);
    if (!provmap.hasSecret(segments)) return flags;

    const loc = try locateSpans(arena, format, composed, own_paths, diag);

    // Byte offset where each logical line starts.
    var starts: std.ArrayList(usize) = .empty;
    try starts.append(arena, 0);
    for (composed, 0..) |c, i| {
        if (c == '\n' and i + 1 < composed.len) try starts.append(arena, i + 1);
    }

    for (segments) |s| {
        if (s.origin != .secret) continue;
        const first: usize = s.out_start;
        if (first >= starts.items.len) continue;
        const past: usize = s.out_start + s.out_len;
        const byte_start = starts.items[first];
        const byte_end = if (past < starts.items.len) starts.items[past] else composed.len;
        for (loc.spans, flags) |span_opt, *flag| {
            const span = span_opt orelse continue;
            if (span.start < byte_end and byte_start < span.end) flag.* = true;
        }
    }
    return flags;
}

/// The extracted source must parse on its own, so span concatenation runs
/// over newline-terminated text (the live file is never written from it).
fn ensureTrailingNewline(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len == 0 or text[text.len - 1] == '\n') return text;
    return std.mem.concat(arena, u8, &.{ text, "\n" });
}

/// Splice `insertion` into `text` at `at`, joined with a separator newline
/// when the preceding byte does not end a line. The separator belongs to
/// the inserted owned content, never to the remainder: a live file with no
/// final newline keeps that state byte-exactly.
fn insertWithSeparator(arena: std.mem.Allocator, text: []const u8, at: usize, insertion: []const u8) ![]const u8 {
    const sep: []const u8 = if (at > 0 and text[at - 1] != '\n') "\n" else "";
    return std.mem.concat(arena, u8, &.{ text[0..at], sep, insertion, text[at..] });
}

/// Text minus the union of every located span and wrapper region. Regions
/// of adjacent owned members may share separator bytes; the union is what
/// the byte check owns.
fn remainderBytes(arena: std.mem.Allocator, text: []const u8, loc: FullLocated) ![]u8 {
    return remainderOfRegions(arena, text, try collectRegions(arena, loc));
}

fn collectRegions(arena: std.mem.Allocator, loc: FullLocated) ![]Span {
    var regions: std.ArrayList(Span) = .empty;
    for (loc.spans) |s| if (s) |sp| try regions.append(arena, sp);
    for (loc.wrappers) |w| try regions.append(arena, w);
    return regions.toOwnedSlice(arena);
}

fn remainderOfRegions(arena: std.mem.Allocator, text: []const u8, regions: []Span) ![]u8 {
    std.mem.sort(Span, regions, {}, spanLess);
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (regions) |r| {
        if (r.start > cursor) try out.appendSlice(arena, text[cursor..r.start]);
        cursor = @max(cursor, r.end);
    }
    try out.appendSlice(arena, text[cursor..]);
    return out.toOwnedSlice(arena);
}

fn spanLess(_: void, a: Span, b: Span) bool {
    return a.start < b.start;
}

// Value equality

fn anyValueEql(a: AnyValue, b: AnyValue) bool {
    if (@as(std.meta.Tag(AnyValue), a) != @as(std.meta.Tag(AnyValue), b)) return false;
    return switch (a) {
        .toml => |v| v.eql(b.toml),
        .yaml => |v| v.eql(b.yaml),
        .json => |v| jsonEql(v, b.json),
        .ini => |v| iniEql(v, b.ini),
    };
}

fn jsonEql(a: json.Value, b: json.Value) bool {
    if (@as(std.meta.Tag(json.Value), a) != @as(std.meta.Tag(json.Value), b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .string => |v| std.mem.eql(u8, v, b.string),
        .number_raw => |v| std.mem.eql(u8, v, b.number_raw),
        .array => |v| blk: {
            if (v.len != b.array.len) break :blk false;
            for (v, b.array) |x, y| if (!jsonEql(x, y)) break :blk false;
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count()) break :blk false;
            for (v.keys(), v.values()) |k, x| {
                const y = b.object.get(k) orelse break :blk false;
                if (!jsonEql(x, y)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn iniEql(a: ini.Value, b: ini.Value) bool {
    if (@as(std.meta.Tag(ini.Value), a) != @as(std.meta.Tag(ini.Value), b)) return false;
    return switch (a) {
        .string => |v| std.mem.eql(u8, v, b.string),
        .list => |v| blk: {
            if (v.len != b.list.len) break :blk false;
            for (v, b.list) |x, y| if (!std.mem.eql(u8, x, y)) break :blk false;
            break :blk true;
        },
        .section => |v| blk: {
            if (v.entries.len != b.section.entries.len) break :blk false;
            for (v.entries, b.section.entries) |x, y| {
                if (!std.mem.eql(u8, x.key, y.key)) break :blk false;
                if (!iniEql(x.value, y.value)) break :blk false;
            }
            break :blk true;
        },
    };
}

// TOML

const TomlScan = struct {
    doc: toml.Document,
    /// Byte offset of each item; items concatenated reproduce the source.
    offs: []usize,
    ends: []usize,
    /// Enclosing header item index per item, null for the root section.
    encl: []?usize,
    len: usize,
};

fn tomlScan(arena: std.mem.Allocator, live: []const u8) LocateError!TomlScan {
    const doc = toml.Document.parse(arena, live, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LiveUnparseable,
    };
    const n = doc.items.items.len;
    const offs = try arena.alloc(usize, n);
    const ends = try arena.alloc(usize, n);
    const encl = try arena.alloc(?usize, n);
    var off: usize = 0;
    var cur: ?usize = null;
    for (doc.items.items, 0..) |item, i| {
        offs[i] = off;
        off += item.rawBytes().len;
        ends[i] = off;
        encl[i] = cur;
        if (item == .header) cur = i;
    }
    return .{ .doc = doc, .offs = offs, .ends = ends, .encl = encl, .len = off };
}

fn tomlHeaderSegs(scan: *const TomlScan, idx: ?usize) []const []const u8 {
    const i = idx orelse return &.{};
    return scan.doc.items.items[i].header.path_segments;
}

fn tomlLocate(
    arena: std.mem.Allocator,
    live: []const u8,
    own_paths: []const OwnPath,
    diag: ?*Diag,
) LocateError!FullLocated {
    const scan = try tomlScan(arena, live);
    return tomlLocateScanned(arena, &scan, own_paths, diag);
}

fn tomlLocateScanned(
    arena: std.mem.Allocator,
    scan: *const TomlScan,
    own_paths: []const OwnPath,
    diag: ?*Diag,
) LocateError!FullLocated {
    const items = scan.doc.items.items;
    const spans = try arena.alloc(?Span, own_paths.len);
    const forms = try arena.alloc(Form, own_paths.len);

    for (own_paths, spans, forms) |p, *span, *form| {
        span.* = null;
        form.* = .none;
        const P = p.segments;

        // Structural refusals against every kv line.
        var kv_idx: ?usize = null;
        for (items, 0..) |item, i| {
            switch (item) {
                .header => |h| {
                    if (h.is_array and segsPrefix(h.path_segments, P)) {
                        diagSet(diag, "{s}: path runs through an array of tables", .{p.raw});
                        return error.OwnedPathUnaddressable;
                    }
                },
                .kv => |kv| {
                    const full = kv.full_path_segments;
                    if (segsPrefix(P, full)) {
                        const encl_segs = tomlHeaderSegs(scan, scan.encl[i]);
                        if (segsPrefix(P, encl_segs)) continue; // inside the table span
                        if (full.len == P.len and full.len - encl_segs.len == 1) {
                            if (kv_idx != null) {
                                diagSet(diag, "{s}: key defined more than once", .{p.raw});
                                return error.OwnedPathDuplicate;
                            }
                            kv_idx = i;
                            continue;
                        }
                        diagSet(diag, "{s}: content is spelled with dotted keys outside the path's own table", .{p.raw});
                        return error.OwnedPathDottedSpelling;
                    }
                    if (full.len < P.len and segsPrefix(full, P)) {
                        diagSet(diag, "{s}: path lies inside the value of key {s}", .{ p.raw, kv.full_path });
                        return error.OwnedPathUnaddressable;
                    }
                },
                else => {},
            }
        }

        // Header-form: contributing headers are those at or under P.
        var first: ?usize = null;
        for (items, 0..) |item, i| {
            if (item != .header) continue;
            if (segsPrefix(P, item.header.path_segments)) {
                first = i;
                break;
            }
        }
        if (first) |f| {
            if (kv_idx != null) {
                diagSet(diag, "{s}: addressed as both a key and a table", .{p.raw});
                return error.OwnedPathDuplicate;
            }
            var j = f + 1;
            while (j < items.len) : (j += 1) {
                if (items[j] == .header and !segsPrefix(P, items[j].header.path_segments)) break;
            }
            var k = j;
            while (k < items.len) : (k += 1) {
                if (items[k] == .header and segsPrefix(P, items[k].header.path_segments)) {
                    diagSet(diag, "{s}: table is split across disjoint regions of the file", .{p.raw});
                    return error.OwnedPathDuplicate;
                }
            }
            // Span end mirrors the span-start rule: the last kv or header
            // line of the owned run ends it, so a trailing blank/comment run
            // before the next header (or end of file) is remainder.
            var last = f;
            var m = f + 1;
            while (m < j) : (m += 1) {
                if (items[m] == .kv or items[m] == .header) last = m;
            }
            span.* = .{ .start = scan.offs[f], .end = scan.ends[last] };
            form.* = .block;
        } else if (kv_idx) |ki| {
            span.* = .{ .start = scan.offs[ki], .end = scan.ends[ki] };
            form.* = .kv;
        }
    }

    // Wrapper headers: a section strictly above a declared path whose kv
    // lines are all owned frames only owned content; its header line joins
    // the byte check as a region no single path claims.
    var wrappers: std.ArrayList(Span) = .empty;
    for (items, 0..) |item, i| {
        if (item != .header) continue;
        const H = item.header.path_segments;
        var strict_prefix = false;
        var at_or_under = false;
        for (own_paths) |p| {
            if (segsPrefix(p.segments, H)) at_or_under = true;
            if (H.len < p.segments.len and segsPrefix(H, p.segments)) strict_prefix = true;
        }
        if (at_or_under or !strict_prefix) continue;
        var all_owned = true;
        for (items, 0..) |it2, j| {
            if (it2 != .kv or scan.encl[j] != i) continue;
            var owned_kv = false;
            for (own_paths) |p| {
                if (segsPrefix(p.segments, it2.kv.full_path_segments)) owned_kv = true;
            }
            if (!owned_kv) all_owned = false;
        }
        if (all_owned) try wrappers.append(arena, .{ .start = scan.offs[i], .end = scan.ends[i] });
    }

    return .{ .spans = spans, .forms = forms, .wrappers = try wrappers.toOwnedSlice(arena) };
}

fn tomlReplace(
    arena: std.mem.Allocator,
    live: []const u8,
    own_paths: []const OwnPath,
    owned: *const OwnedDoc,
    diag: ?*Diag,
) ReplaceError![]u8 {
    var text: []const u8 = live;
    for (own_paths, 0..) |p, pi| {
        const scan = try tomlScan(arena, text);
        const loc = try tomlLocateScanned(arena, &scan, own_paths, diag);
        const sub = owned.subtreeAt(p.segments);
        const span = loc.spans[pi];

        if (sub == null) {
            if (span) |sp| text = try spliceBytes(arena, text, sp, "");
            continue;
        }
        const value = sub.?.toml;

        if (span) |sp| {
            const replacement = switch (loc.forms[pi]) {
                .kv => try tomlRenderKv(arena, p.segments[p.segments.len - 1], value),
                .block => blk: {
                    if (value != .table) {
                        diagSet(diag, "{s}: live table cannot take a non-table owned value", .{p.raw});
                        return error.OwnedRenderFailed;
                    }
                    break :blk try tomlRenderBlock(arena, p.segments, value.table);
                },
                else => unreachable,
            };
            text = try spliceBytes(arena, text, sp, replacement);
            continue;
        }

        // Append. Tables become a header block at end of file; a leaf value
        // becomes a kv line in its parent's section, creating the section
        // block at end of file when the parent has no header yet.
        if (value == .table) {
            const block = try tomlRenderBlock(arena, p.segments, value.table);
            text = try insertWithSeparator(arena, text, text.len, block);
            continue;
        }
        const kv_line = try tomlRenderKv(arena, p.segments[p.segments.len - 1], value);
        const parent = p.segments[0 .. p.segments.len - 1];
        if (parent.len == 0) {
            text = try insertWithSeparator(arena, text, tomlRootInsertOffset(&scan), kv_line);
            continue;
        }
        if (tomlSectionInsertOffset(&scan, parent)) |at| {
            text = try insertWithSeparator(arena, text, at, kv_line);
        } else {
            const header = try tomlPathSpell(arena, parent);
            const block = try std.mem.concat(arena, u8, &.{ "[", header, "]\n", kv_line });
            text = try insertWithSeparator(arena, text, text.len, block);
        }
    }
    return @constCast(text);
}

/// End of the root section's last kv line (or the file start when the root
/// section has no keys) -- where a new root-level key goes.
fn tomlRootInsertOffset(scan: *const TomlScan) usize {
    var at: usize = 0;
    for (scan.doc.items.items, 0..) |item, i| {
        if (item == .header) break;
        if (item == .kv) at = scan.ends[i];
    }
    return at;
}

/// End of the named section's last kv line (or of its header line when the
/// section is empty), or null when the section has no header.
fn tomlSectionInsertOffset(scan: *const TomlScan, parent: []const []const u8) ?usize {
    for (scan.doc.items.items, 0..) |item, i| {
        if (item != .header or item.header.is_array) continue;
        if (!segsEq(item.header.path_segments, parent)) continue;
        var at = scan.ends[i];
        var j = i + 1;
        while (j < scan.doc.items.items.len) : (j += 1) {
            const it2 = scan.doc.items.items[j];
            if (it2 == .header) break;
            if (it2 == .kv) at = scan.ends[j];
        }
        return at;
    }
    return null;
}

fn spliceBytes(arena: std.mem.Allocator, text: []const u8, span: Span, replacement: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ text[0..span.start], replacement, text[span.end..] });
}

/// The span's trailing run of blank lines. A block span reaches to the next
/// header, so the blank separation before it is span content; a replacement
/// re-emits the run to keep the sections visually separated.
fn trailingBlankRun(text: []const u8, span: Span) []const u8 {
    var j = span.end;
    while (j > span.start) {
        const k = lineStartOf(text[0..j], j - 1);
        if (k < span.start) break;
        const line = text[k..j];
        if (std.mem.trim(u8, line, " \t\r\n").len != 0) break;
        j = k;
    }
    return text[j..span.end];
}

/// Spell one key segment as TOML source (bare or quoted). The encoder owns
/// the quoting rules; a one-entry probe table borrows them.
fn tomlKeySpell(arena: std.mem.Allocator, seg: []const u8) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    var tbl: toml.Value.Table = .empty;
    try tbl.put(arena, seg, .{ .boolean = true });
    var aw: std.Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    toml.encode(&aw.writer, .{ .table = tbl }, .{}) catch return error.OwnedRenderFailed;
    const line = aw.written();
    const suffix = " = true\n";
    if (line.len < suffix.len + 1) return error.OwnedRenderFailed;
    return arena.dupe(u8, line[0 .. line.len - suffix.len]);
}

fn tomlPathSpell(arena: std.mem.Allocator, segments: []const []const u8) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segments, 0..) |seg, i| {
        if (i > 0) try out.append(arena, '.');
        try out.appendSlice(arena, try tomlKeySpell(arena, seg));
    }
    return out.toOwnedSlice(arena);
}

/// A value's inline TOML literal. Scalars and scalar arrays come from the
/// encoder via a one-entry probe table; tables and arrays holding tables
/// render inline recursively (the probe would emit them in header form).
fn tomlValueLiteral(arena: std.mem.Allocator, v: toml.Value) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    switch (v) {
        .table => |tbl| {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, "{ ");
            for (tbl.keys(), tbl.values(), 0..) |k, sub, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, try tomlKeySpell(arena, k));
                try out.appendSlice(arena, " = ");
                try out.appendSlice(arena, try tomlValueLiteral(arena, sub));
            }
            try out.appendSlice(arena, if (tbl.count() == 0) "}" else " }");
            return out.toOwnedSlice(arena);
        },
        .array => |arr| {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '[');
            for (arr.items, 0..) |elem, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, try tomlValueLiteral(arena, elem));
            }
            try out.append(arena, ']');
            return out.toOwnedSlice(arena);
        },
        else => {
            var tbl: toml.Value.Table = .empty;
            try tbl.put(arena, "k", v);
            var aw: std.Io.Writer.Allocating = .init(arena);
            defer aw.deinit();
            toml.encode(&aw.writer, .{ .table = tbl }, .{}) catch return error.OwnedRenderFailed;
            const line = aw.written();
            const prefix = "k = ";
            if (line.len < prefix.len + 1 or line[line.len - 1] != '\n') return error.OwnedRenderFailed;
            return arena.dupe(u8, line[prefix.len .. line.len - 1]);
        },
    }
}

fn tomlRenderKv(arena: std.mem.Allocator, leaf: []const u8, v: toml.Value) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    return std.mem.concat(arena, u8, &.{
        try tomlKeySpell(arena, leaf), " = ", try tomlValueLiteral(arena, v), "\n",
    });
}

/// Header-block rendering: `[path]`, its scalar keys, then each sub-table
/// as its own header block. Arrays render inline, tables included.
fn tomlRenderBlock(arena: std.mem.Allocator, segments: []const []const u8, tbl: toml.Value.Table) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    try out.appendSlice(arena, try tomlPathSpell(arena, segments));
    try out.appendSlice(arena, "]\n");
    for (tbl.keys(), tbl.values()) |k, v| {
        if (v == .table) continue;
        try out.appendSlice(arena, try tomlKeySpell(arena, k));
        try out.appendSlice(arena, " = ");
        try out.appendSlice(arena, try tomlValueLiteral(arena, v));
        try out.append(arena, '\n');
    }
    for (tbl.keys(), tbl.values()) |k, v| {
        if (v != .table) continue;
        var sub_path: std.ArrayList([]const u8) = .empty;
        try sub_path.appendSlice(arena, segments);
        try sub_path.append(arena, k);
        try out.append(arena, '\n');
        try out.appendSlice(arena, try tomlRenderBlock(arena, sub_path.items, v.table));
    }
    return out.toOwnedSlice(arena);
}

// JSON

fn jsonParseDoc(arena: std.mem.Allocator, live: []const u8) LocateError!json.Document {
    return json.Document.parse(arena, live, .{ .dialect = .jsonc }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LiveUnparseable,
    };
}

fn jsonLocate(
    arena: std.mem.Allocator,
    live: []const u8,
    own_paths: []const OwnPath,
    diag: ?*Diag,
) LocateError!FullLocated {
    const spans = try arena.alloc(?Span, own_paths.len);
    const forms = try arena.alloc(Form, own_paths.len);
    @memset(spans, null);
    @memset(forms, .none);
    if (live.len == 0) return .{ .spans = spans, .forms = forms, .wrappers = &.{} };

    const doc = try jsonParseDoc(arena, live);
    const root = doc.root;
    if (root.data != .object) {
        diagSet(diag, "root of the document is not an object", .{});
        return error.OwnedPathUnaddressable;
    }

    for (own_paths, spans, forms) |p, *span, *form| {
        var cur = root;
        for (p.segments, 0..) |seg, i| {
            if (cur.data != .object) break;
            const members = cur.data.object.items;
            var found: ?usize = null;
            for (members, 0..) |m, mi| {
                if (!std.mem.eql(u8, m.key.decoded, seg)) continue;
                if (found != null) {
                    diagSet(diag, "{s}: key defined more than once", .{p.raw});
                    return error.OwnedPathDuplicate;
                }
                found = mi;
            }
            const mi = found orelse break;
            if (i == p.segments.len - 1) {
                span.* = jsonMemberSpan(live, cur, mi);
                form.* = .member;
                break;
            }
            cur = members[mi].value;
        }
    }

    const wrappers = try jsonWrappers(arena, live, root, own_paths);
    return .{ .spans = spans, .forms = forms, .wrappers = wrappers };
}

/// Member span with the separator needed for a clean splice: trailing comma
/// plus same-line trivia for a non-last member, leading comma for a last
/// member, the container interior for a sole member.
fn jsonMemberSpan(src: []const u8, parent: anytype, idx: usize) Span {
    const members = parent.data.object.items;
    if (members.len == 1) {
        return .{ .start = parent.outer.start + 1, .end = parent.outer.end - 1 };
    }
    if (idx + 1 < members.len) {
        return .{ .start = members[idx].key.outer.start, .end = jsonMemberSpanEnd(src, members[idx].value.outer.end) };
    }
    return .{ .start = members[idx - 1].value.outer.end, .end = members[idx].value.outer.end };
}

/// End of a non-last member's span: its value, the separator comma, and the
/// same-line trivia after the comma. The scan stops before a newline, so a
/// standalone comment line between members stays with the remainder.
fn jsonMemberSpanEnd(src: []const u8, value_end: usize) usize {
    var i = value_end;
    while (i < src.len and src[i] != ',') i += 1;
    if (i < src.len) i += 1;
    var j = i;
    while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
    if (j + 1 < src.len and src[j] == '/' and src[j + 1] == '/') {
        while (j < src.len and src[j] != '\n') j += 1;
        return j;
    }
    return if (j < src.len and (src[j] == '\n' or src[j] == '\r')) i else j;
}

fn jsonWrappers(arena: std.mem.Allocator, src: []const u8, root: anytype, own_paths: []const OwnPath) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    var path: std.ArrayList([]const u8) = .empty;
    try jsonWrapperWalk(arena, src, root, own_paths, &path, &out);
    return out.toOwnedSlice(arena);
}

fn jsonWrapperWalk(
    arena: std.mem.Allocator,
    src: []const u8,
    node: anytype,
    own_paths: []const OwnPath,
    path: *std.ArrayList([]const u8),
    out: *std.ArrayList(Span),
) !void {
    if (node.data != .object) return;
    const members = node.data.object.items;
    for (members, 0..) |m, mi| {
        try path.append(arena, m.key.decoded);
        defer _ = path.pop();
        if (pathAtOrUnderDeclared(own_paths, path.items)) continue;
        if (try jsonFullyOwned(arena, m.value, own_paths, path)) {
            try out.append(arena, jsonMemberSpan(src, node, mi));
        } else {
            try jsonWrapperWalk(arena, src, m.value, own_paths, path, out);
        }
    }
}

fn pathAtOrUnderDeclared(own_paths: []const OwnPath, path: []const []const u8) bool {
    for (own_paths) |p| if (segsPrefix(p.segments, path)) return true;
    return false;
}

fn pathStrictPrefixOfDeclared(own_paths: []const OwnPath, path: []const []const u8) bool {
    for (own_paths) |p| {
        if (path.len < p.segments.len and segsPrefix(path, p.segments)) return true;
    }
    return false;
}

/// True when everything under this node is owned content: every scalar leaf
/// sits at or under a declared path, and an empty container is a pure
/// intermediate on a declared route.
fn jsonFullyOwned(arena: std.mem.Allocator, node: anytype, own_paths: []const OwnPath, path: *std.ArrayList([]const u8)) error{OutOfMemory}!bool {
    if (pathAtOrUnderDeclared(own_paths, path.items)) return true;
    if (node.data != .object) return false;
    const members = node.data.object.items;
    if (members.len == 0) return pathStrictPrefixOfDeclared(own_paths, path.items);
    for (members) |m| {
        try path.append(arena, m.key.decoded);
        const owned_child = try jsonFullyOwned(arena, m.value, own_paths, path);
        _ = path.pop();
        if (!owned_child) return false;
    }
    return true;
}

fn jsonReplace(
    arena: std.mem.Allocator,
    live: []const u8,
    own_paths: []const OwnPath,
    owned: *const OwnedDoc,
    diag: ?*Diag,
) ReplaceError![]u8 {
    var doc = if (live.len == 0)
        json.Document.empty(arena, .{ .dialect = .jsonc }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OwnedRenderFailed,
        }
    else
        try jsonParseDoc(arena, live);

    // Populated paths first: the document model replaces value bytes in
    // place and appends missing members with the surrounding style.
    for (own_paths) |p| {
        const sub = owned.subtreeAt(p.segments) orelse continue;
        doc.setValueSegments(p.segments, sub.json) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                diagSet(diag, "{s}: cannot place owned value into the live document", .{p.raw});
                return error.OwnedRenderFailed;
            },
        };
    }
    var text: []const u8 = doc.source;

    // Enforced absence: splice the member's span out by hand -- the
    // document model's removal collapses interiors, which would disturb
    // remainder bytes the invariant pins.
    for (own_paths, 0..) |p, pi| {
        if (owned.populated(p.segments)) continue;
        const loc = try jsonLocate(arena, text, own_paths, diag);
        if (loc.spans[pi]) |sp| text = try spliceBytes(arena, text, sp, "");
    }
    return @constCast(text);
}

// YAML

const YamlScan = struct {
    doc: yaml.Document,
    empty: bool,
};

fn yamlScan(arena: std.mem.Allocator, live: []const u8) LocateError!YamlScan {
    if (std.mem.trim(u8, live, " \t\r\n").len == 0) {
        return .{ .doc = undefined, .empty = true };
    }
    const doc = yaml.Document.parse(arena, live, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LiveUnparseable,
    };
    return .{ .doc = doc, .empty = false };
}

fn yamlLocate(
    arena: std.mem.Allocator,
    live: []const u8,
    own_paths: []const OwnPath,
    diag: ?*Diag,
) LocateError!FullLocated {
    const spans = try arena.alloc(?Span, own_paths.len);
    const forms = try arena.alloc(Form, own_paths.len);
    @memset(spans, null);
    @memset(forms, .none);

    const scan = try yamlScan(arena, live);
    if (scan.empty or scan.doc.roots.len == 0) {
        return .{ .spans = spans, .forms = forms, .wrappers = &.{} };
    }
    const doc = scan.doc;
    const root = doc.roots[0];
    const src = doc.source;
    if (root.data != .mapping) {
        if (root.data == .scalar and root.outer.start == root.outer.end) {
            return .{ .spans = spans, .forms = forms, .wrappers = &.{} };
        }
        diagSet(diag, "root of the document is not a mapping", .{});
        return error.OwnedPathUnaddressable;
    }

    for (own_paths, spans, forms) |p, *span, *form| {
        var cur = root;
        var composed: ?yaml.Value = if (doc.docs.len > 0) doc.docs[0] else null;
        for (p.segments, 0..) |seg, i| {
            if (cur.data != .mapping) break;
            if (src[cur.outer.start] == '{') {
                diagSet(diag, "{s}: path runs through a flow-style mapping", .{p.raw});
                return error.OwnedPathUnaddressable;
            }
            const members = cur.data.mapping.items;
            var found: ?usize = null;
            for (members, 0..) |m, mi| {
                if (!std.mem.eql(u8, m.key.decoded, seg)) continue;
                if (found != null) {
                    diagSet(diag, "{s}: key defined more than once", .{p.raw});
                    return error.OwnedPathDuplicate;
                }
                found = mi;
            }
            const composed_child: ?yaml.Value = if (composed != null and composed.? == .map)
                yamlMapGet(composed.?.map, seg)
            else
                null;
            const mi = found orelse {
                // The node tree has no such member. Content reachable only
                // through the composed view arrived via a merge key.
                if (composed_child != null) {
                    diagSet(diag, "{s}: content crosses a merge key", .{p.raw});
                    return error.OwnedPathMergeKey;
                }
                break;
            };
            if (composed_child == null) {
                diagSet(diag, "{s}: segment {s} matches a non-string key", .{ p.raw, seg });
                return error.OwnedPathNonStringKey;
            }
            const m = members[mi];
            try yamlCheckMemberProps(src, m, p.raw, diag);
            if (i == p.segments.len - 1) {
                try yamlCheckSubtree(src, m.value, p.raw, diag);
                span.* = .{
                    .start = lineStartOf(src, m.key.outer.start),
                    .end = lineEndOf(src, m.value.outer.end),
                };
                form.* = .member;
                break;
            }
            cur = m.value;
            composed = composed_child;
        }
    }

    const wrappers = try yamlWrappers(arena, src, root, own_paths);
    return .{ .spans = spans, .forms = forms, .wrappers = wrappers };
}

/// Refuse node properties on a member of the declared chain: an anchor or
/// tag between the key and its value (or before the key) decorates content
/// the splice could not reproduce, and an alias value shares it.
fn yamlCheckMemberProps(src: []const u8, m: anytype, raw_path: []const u8, diag: ?*Diag) LocateError!void {
    const key_line = lineStartOf(src, m.key.outer.start);
    for (src[key_line..m.key.outer.start]) |c| {
        if (c != ' ' and c != '\t') {
            diagSet(diag, "{s}: key does not start its line", .{raw_path});
            return error.OwnedPathUnaddressable;
        }
    }
    const gap_start = m.sep_end orelse m.key.outer.end;
    const gap_end = @min(@max(m.value.outer.start, gap_start), src.len);
    try yamlCheckGap(src[@min(gap_start, gap_end)..gap_end], raw_path, diag);
    if (m.value.outer.start < m.value.outer.end and src[m.value.outer.start] == '*') {
        diagSet(diag, "{s}: value is an alias", .{raw_path});
        return error.OwnedPathAliased;
    }
}

fn yamlCheckGap(gap: []const u8, raw_path: []const u8, diag: ?*Diag) LocateError!void {
    var i: usize = 0;
    while (i < gap.len) : (i += 1) {
        switch (gap[i]) {
            '#' => {
                while (i < gap.len and gap[i] != '\n') i += 1;
            },
            '&', '!' => {
                diagSet(diag, "{s}: anchored or tagged content on the owned path", .{raw_path});
                return error.OwnedPathAliased;
            },
            else => {},
        }
    }
}

/// Refuse anchors, tags, aliases, and merge keys anywhere inside an owned
/// subtree: their meaning reaches outside the bytes the span replaces.
fn yamlCheckSubtree(src: []const u8, node: anytype, raw_path: []const u8, diag: ?*Diag) LocateError!void {
    if (node.outer.start < src.len and node.outer.start < node.outer.end and src[node.outer.start] == '*') {
        diagSet(diag, "{s}: owned content contains an alias", .{raw_path});
        return error.OwnedPathAliased;
    }
    switch (node.data) {
        .scalar => {},
        .sequence => |elems| for (elems.items) |e| try yamlCheckSubtree(src, e, raw_path, diag),
        .mapping => |members| for (members.items) |m| {
            if (std.mem.eql(u8, m.key.decoded, "<<")) {
                diagSet(diag, "{s}: owned content contains a merge key", .{raw_path});
                return error.OwnedPathMergeKey;
            }
            const gap_start = m.sep_end orelse m.key.outer.end;
            try yamlCheckGap(src[gap_start..@min(m.value.outer.start, src.len)], raw_path, diag);
            try yamlCheckSubtree(src, m.value, raw_path, diag);
        },
    }
}

fn yamlWrappers(arena: std.mem.Allocator, src: []const u8, root: anytype, own_paths: []const OwnPath) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    var path: std.ArrayList([]const u8) = .empty;
    try yamlWrapperWalk(arena, src, root, own_paths, &path, &out);
    return out.toOwnedSlice(arena);
}

fn yamlWrapperWalk(
    arena: std.mem.Allocator,
    src: []const u8,
    node: anytype,
    own_paths: []const OwnPath,
    path: *std.ArrayList([]const u8),
    out: *std.ArrayList(Span),
) !void {
    if (node.data != .mapping) return;
    if (node.outer.start < src.len and src[node.outer.start] == '{') return;
    for (node.data.mapping.items) |m| {
        try path.append(arena, m.key.decoded);
        defer _ = path.pop();
        if (pathAtOrUnderDeclared(own_paths, path.items)) continue;
        if (try yamlFullyOwned(arena, m.value, own_paths, path)) {
            try out.append(arena, .{
                .start = lineStartOf(src, m.key.outer.start),
                .end = lineEndOf(src, m.value.outer.end),
            });
        } else {
            try yamlWrapperWalk(arena, src, m.value, own_paths, path, out);
        }
    }
}

fn yamlFullyOwned(arena: std.mem.Allocator, node: anytype, own_paths: []const OwnPath, path: *std.ArrayList([]const u8)) error{OutOfMemory}!bool {
    if (pathAtOrUnderDeclared(own_paths, path.items)) return true;
    if (node.data != .mapping) return false;
    const members = node.data.mapping.items;
    if (members.len == 0) return pathStrictPrefixOfDeclared(own_paths, path.items);
    for (members) |m| {
        try path.append(arena, m.key.decoded);
        const owned_child = try yamlFullyOwned(arena, m.value, own_paths, path);
        _ = path.pop();
        if (!owned_child) return false;
    }
    return true;
}

fn yamlReplace(
    arena: std.mem.Allocator,
    live: []const u8,
    own_paths: []const OwnPath,
    owned: *const OwnedDoc,
    diag: ?*Diag,
) ReplaceError![]u8 {
    var text: []const u8 = live;
    for (own_paths, 0..) |p, pi| {
        const loc = try yamlLocate(arena, text, own_paths, diag);
        const sub = owned.subtreeAt(p.segments);

        if (sub == null) {
            const sp = loc.spans[pi] orelse continue;
            const hoisted = try yamlHoistRemoval(arena, text, p.segments, sp);
            text = try spliceBytes(arena, text, hoisted, "");
            continue;
        }

        if (loc.spans[pi]) |sp| {
            const indent = text[lineStartOf(text, sp.start)..firstNonWs(text, lineStartOf(text, sp.start))];
            const rendered = try yamlRenderMember(arena, indent, p.segments[p.segments.len - 1], sub.?.yaml, diag);
            text = try spliceBytes(arena, text, sp, rendered);
            continue;
        }

        text = try yamlAppend(arena, text, p, sub.?.yaml, diag);
    }
    return @constCast(text);
}

fn firstNonWs(src: []const u8, line_start: usize) usize {
    var i = line_start;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    return i;
}

/// A removal ascends while the member is its parent mapping's only entry:
/// deleting the sole member of a block mapping would leave the parent key
/// with a null value the remainder check rightly rejects.
fn yamlHoistRemoval(arena: std.mem.Allocator, text: []const u8, segments: []const []const u8, sp: Span) LocateError!Span {
    const scan = try yamlScan(arena, text);
    if (scan.empty or scan.doc.roots.len == 0) return sp;
    const src = scan.doc.source;
    const root = scan.doc.roots[0];
    if (root.data != .mapping) return sp;

    var depth = segments.len;
    while (depth > 1) : (depth -= 1) {
        // Parent mapping of the member at segments[0..depth].
        var cur = root;
        var ok = true;
        for (segments[0 .. depth - 1]) |seg| {
            if (cur.data != .mapping) {
                ok = false;
                break;
            }
            var next: ?@TypeOf(cur) = null;
            for (cur.data.mapping.items) |m| {
                if (std.mem.eql(u8, m.key.decoded, seg)) next = m.value;
            }
            cur = next orelse {
                ok = false;
                break;
            };
        }
        if (!ok or cur.data != .mapping) return sp;
        if (cur.data.mapping.items.len > 1) {
            // Member at this depth has siblings: remove just it.
            for (cur.data.mapping.items) |m| {
                if (std.mem.eql(u8, m.key.decoded, segments[depth - 1])) {
                    return .{
                        .start = lineStartOf(src, m.key.outer.start),
                        .end = lineEndOf(src, m.value.outer.end),
                    };
                }
            }
            return sp;
        }
    }
    // Sole-member chain all the way up: remove the top-level member.
    for (root.data.mapping.items) |m| {
        if (std.mem.eql(u8, m.key.decoded, segments[0])) {
            return .{
                .start = lineStartOf(src, m.key.outer.start),
                .end = lineEndOf(src, m.value.outer.end),
            };
        }
    }
    return sp;
}

fn yamlAppend(
    arena: std.mem.Allocator,
    text: []const u8,
    p: OwnPath,
    value: yaml.Value,
    diag: ?*Diag,
) ReplaceError![]const u8 {
    const scan = try yamlScan(arena, text);
    if (scan.empty or scan.doc.roots.len == 0) {
        const rendered = try yamlRenderChain(arena, "", p.segments, value, diag);
        return insertWithSeparator(arena, text, text.len, rendered);
    }
    const src = scan.doc.source;
    const root = scan.doc.roots[0];
    if (root.data == .scalar and root.outer.start == root.outer.end) {
        const rendered = try yamlRenderChain(arena, "", p.segments, value, diag);
        return insertWithSeparator(arena, text, text.len, rendered);
    }
    if (root.data != .mapping) {
        diagSet(diag, "{s}: root of the document is not a mapping", .{p.raw});
        return error.OwnedPathUnaddressable;
    }

    // Deepest existing ancestor mapping.
    var cur = root;
    var depth: usize = 0;
    while (depth < p.segments.len - 1) {
        if (cur.data != .mapping) break;
        var next: ?@TypeOf(cur) = null;
        for (cur.data.mapping.items) |m| {
            if (std.mem.eql(u8, m.key.decoded, p.segments[depth])) next = m.value;
        }
        const n = next orelse break;
        cur = n;
        depth += 1;
    }
    if (cur.data != .mapping) {
        diagSet(diag, "{s}: path runs through a non-mapping value", .{p.raw});
        return error.OwnedPathUnaddressable;
    }
    if (src.len > cur.outer.start and src[cur.outer.start] == '{') {
        diagSet(diag, "{s}: path runs through a flow-style mapping", .{p.raw});
        return error.OwnedPathUnaddressable;
    }
    const members = cur.data.mapping.items;
    const last = members[members.len - 1];
    const key_line = lineStartOf(src, last.key.outer.start);
    const indent = src[key_line..firstNonWs(src, key_line)];
    const at = lineEndOf(src, last.value.outer.end);
    const rendered = try yamlRenderChain(arena, indent, p.segments[depth..], value, diag);
    return insertWithSeparator(arena, text, at, rendered);
}

/// One scalar's YAML text, with the emitter's round-trip-safe quoting.
fn yamlScalarText(arena: std.mem.Allocator, v: yaml.Value, diag: ?*Diag) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    yaml.emit(&aw.writer, v, .{}) catch return error.OwnedRenderFailed;
    const line = std.mem.trimEnd(u8, aw.written(), "\n");
    if (std.mem.indexOfScalar(u8, line, '\n') != null) {
        diagSet(diag, "owned scalar does not render on one line", .{});
        return error.OwnedRenderFailed;
    }
    return arena.dupe(u8, line);
}

fn yamlRenderMember(
    arena: std.mem.Allocator,
    indent: []const u8,
    key: []const u8,
    value: yaml.Value,
    diag: ?*Diag,
) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    const key_text = try yamlScalarText(arena, .{ .string = key }, diag);
    const is_empty = switch (value) {
        .map => |m| m.len == 0,
        .seq => |s| s.len == 0,
        else => false,
    };
    switch (value) {
        .map, .seq => {
            if (is_empty) {
                const flow = if (value == .map) "{}" else "[]";
                return std.mem.concat(arena, u8, &.{ indent, key_text, ": ", flow, "\n" });
            }
            var aw: std.Io.Writer.Allocating = .init(arena);
            defer aw.deinit();
            yaml.emit(&aw.writer, value, .{}) catch return error.OwnedRenderFailed;
            const child_indent = try std.mem.concat(arena, u8, &.{ indent, "  " });
            const body = try indentLines(arena, aw.written(), child_indent);
            return std.mem.concat(arena, u8, &.{ indent, key_text, ":\n", body });
        },
        else => {
            const value_text = try yamlScalarText(arena, value, diag);
            return std.mem.concat(arena, u8, &.{ indent, key_text, ": ", value_text, "\n" });
        },
    }
}

fn yamlRenderChain(
    arena: std.mem.Allocator,
    indent: []const u8,
    segments: []const []const u8,
    value: yaml.Value,
    diag: ?*Diag,
) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pad = indent;
    for (segments[0 .. segments.len - 1]) |seg| {
        const key_text = try yamlScalarText(arena, .{ .string = seg }, diag);
        try out.appendSlice(arena, pad);
        try out.appendSlice(arena, key_text);
        try out.appendSlice(arena, ":\n");
        pad = try std.mem.concat(arena, u8, &.{ pad, "  " });
    }
    try out.appendSlice(arena, try yamlRenderMember(arena, pad, segments[segments.len - 1], value, diag));
    return out.toOwnedSlice(arena);
}

fn indentLines(arena: std.mem.Allocator, body: []const u8, indent: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try out.appendSlice(arena, indent);
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

// INI / gitconfig

const IniLineKind = enum { header, kv, other };

const IniLine = struct {
    kind: IniLineKind,
    start: usize,
    /// Past the final newline; for a kv this covers its continuation lines.
    end: usize,
    /// Folded identity: [name] or [name, subsection] for a header, the
    /// header path plus the folded key for a kv.
    path: []const []const u8,
    /// gitconfig `[section] key = value`: an entry lives on the header line.
    inline_key: ?[]const u8 = null,
};

const IniScan = struct {
    lines: []IniLine,
    src: []const u8,
    /// Leading BOM bytes carried as remainder prefix.
    bom: usize,
};

fn iniScan(arena: std.mem.Allocator, format: Format, live: []const u8) LocateError!IniScan {
    const dialect = iniDialect(format);
    const bom: usize = if (std.mem.startsWith(u8, live, "\xEF\xBB\xBF")) 3 else 0;
    const src = live[bom..];

    // The strict parser decides parseability (and backs the value view).
    _ = ini.parse(arena, src, .{ .dialect = dialect }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LiveUnparseable,
    };

    var lines: std.ArrayList(IniLine) = .empty;
    var current: []const []const u8 = &.{};
    var toks = ini.Tokenizer.init(src, dialect);
    while (toks.next()) |tok| {
        const start: usize = @intCast(tok.span.start);
        const end = lineEndOf(src, start);
        const raw = src[start..@intCast(tok.span.end)];
        switch (tok.kind) {
            .section_header => {
                const parts = ini.parser.splitHeader(raw, dialect) catch return error.LiveUnparseable;
                var path: std.ArrayList([]const u8) = .empty;
                try path.append(arena, try foldAlloc(arena, parts.name, dialect.case_insensitive_sections));
                if (parts.subsection) |sub| try path.append(arena, try unescapeSubsection(arena, sub));
                current = path.items;
                var inline_key: ?[]const u8 = null;
                if (parts.rest.len > 0 and std.mem.indexOfScalar(u8, dialect.comment_chars, parts.rest[0]) == null) {
                    const key_end = ini.tokenizer.findAssign(parts.rest, dialect.assign_chars) orelse parts.rest.len;
                    const key = std.mem.trim(u8, parts.rest[0..key_end], " \t");
                    if (key.len > 0) inline_key = try foldAlloc(arena, key, dialect.case_insensitive_keys);
                }
                try lines.append(arena, .{
                    .kind = .header,
                    .start = bom + start,
                    .end = bom + end,
                    .path = current,
                    .inline_key = inline_key,
                });
            },
            .key_value => {
                const key_end = ini.tokenizer.findAssign(raw, dialect.assign_chars) orelse raw.len;
                const key = std.mem.trim(u8, raw[0..key_end], " \t");
                var path: std.ArrayList([]const u8) = .empty;
                try path.appendSlice(arena, current);
                try path.append(arena, try foldAlloc(arena, key, dialect.case_insensitive_keys));
                try lines.append(arena, .{ .kind = .kv, .start = bom + start, .end = bom + end, .path = path.items });
            },
            .continuation => {
                if (lines.items.len > 0 and lines.items[lines.items.len - 1].kind == .kv) {
                    lines.items[lines.items.len - 1].end = bom + end;
                } else {
                    try lines.append(arena, .{ .kind = .other, .start = bom + start, .end = bom + end, .path = &.{} });
                }
            },
            .blank, .comment => {
                try lines.append(arena, .{ .kind = .other, .start = bom + start, .end = bom + end, .path = &.{} });
            },
        }
    }
    return .{ .lines = try lines.toOwnedSlice(arena), .src = live, .bom = bom };
}

fn foldAlloc(arena: std.mem.Allocator, s: []const u8, fold: bool) ![]const u8 {
    return if (fold) ini.parser.toLowerAlloc(arena, s) else s;
}

/// Git subsection names escape `"` and `\` with a backslash; drop it.
fn unescapeSubsection(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) i += 1;
        try out.append(arena, s[i]);
    }
    return out.toOwnedSlice(arena);
}

/// Fold a declared path for matching against a scan identity of the given
/// shape: section name folded, subsection verbatim, key folded.
fn iniFoldDeclared(
    arena: std.mem.Allocator,
    dialect: ini.Dialect,
    segments: []const []const u8,
    last_is_key: bool,
) ![]const []const u8 {
    const out = try arena.alloc([]const u8, segments.len);
    for (segments, 0..) |seg, i| {
        const fold = if (i == 0 and !(last_is_key and segments.len == 1))
            dialect.case_insensitive_sections
        else if (i == segments.len - 1 and last_is_key)
            dialect.case_insensitive_keys
        else
            false;
        out[i] = try foldAlloc(arena, seg, fold);
    }
    return out;
}

fn iniLocate(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    own_paths: []const OwnPath,
    diag: ?*Diag,
) LocateError!FullLocated {
    const scan = try iniScan(arena, format, live);
    return iniLocateScanned(arena, format, &scan, live, own_paths, diag);
}

fn iniLocateScanned(
    arena: std.mem.Allocator,
    format: Format,
    scan: *const IniScan,
    live: []const u8,
    own_paths: []const OwnPath,
    diag: ?*Diag,
) LocateError!FullLocated {
    const dialect = iniDialect(format);
    const spans = try arena.alloc(?Span, own_paths.len);
    const forms = try arena.alloc(Form, own_paths.len);
    const max_depth: usize = if (dialect.subsections == .quoted) 3 else 2;

    for (own_paths, spans, forms) |p, *span, *form| {
        span.* = null;
        form.* = .none;
        if (p.segments.len > max_depth) {
            diagSet(diag, "{s}: path is deeper than the format allows", .{p.raw});
            return error.OwnedPathUnaddressable;
        }
        const as_section = try iniFoldDeclared(arena, dialect, p.segments, false);
        const as_key = try iniFoldDeclared(arena, dialect, p.segments, true);

        // Section-form: contiguous run of headers at or under the path.
        var first: ?usize = null;
        for (scan.lines, 0..) |line, i| {
            if (line.kind != .header) continue;
            if (segsPrefix(as_section, line.path)) {
                first = i;
                break;
            }
        }
        var section_span: ?Span = null;
        if (first) |f| {
            var j = f + 1;
            while (j < scan.lines.len) : (j += 1) {
                if (scan.lines[j].kind == .header and !segsPrefix(as_section, scan.lines[j].path)) break;
            }
            var k = j;
            while (k < scan.lines.len) : (k += 1) {
                if (scan.lines[k].kind == .header and segsPrefix(as_section, scan.lines[k].path)) {
                    diagSet(diag, "{s}: section appears in disjoint regions of the file", .{p.raw});
                    return error.OwnedPathDuplicate;
                }
            }
            section_span = .{
                .start = scan.lines[f].start,
                .end = if (j < scan.lines.len) scan.lines[j].start else live.len,
            };
        }

        // Key-form: entry lines whose full path equals the declared path.
        var kv_span: ?Span = null;
        for (scan.lines) |line| {
            if (line.kind == .header) {
                if (line.inline_key != null and line.path.len + 1 == as_key.len and
                    segsPrefix(line.path, as_key[0..line.path.len]) and
                    std.mem.eql(u8, line.inline_key.?, as_key[as_key.len - 1]))
                {
                    diagSet(diag, "{s}: entry sits on a section header line", .{p.raw});
                    return error.OwnedPathUnaddressable;
                }
                continue;
            }
            if (line.kind != .kv or !segsEq(line.path, as_key)) continue;
            if (kv_span) |prev| {
                if (prev.end == line.start) {
                    kv_span = .{ .start = prev.start, .end = line.end };
                } else {
                    diagSet(diag, "{s}: entries for the key are not contiguous", .{p.raw});
                    return error.OwnedPathDuplicate;
                }
            } else {
                kv_span = .{ .start = line.start, .end = line.end };
            }
        }

        if (section_span != null and kv_span != null) {
            diagSet(diag, "{s}: addressed as both a section and a key", .{p.raw});
            return error.OwnedPathDuplicate;
        }
        if (section_span) |sp| {
            span.* = sp;
            form.* = .block;
        } else if (kv_span) |sp| {
            span.* = sp;
            form.* = .kv;
        }
    }

    // Wrapper headers: a section strictly above declared key paths whose
    // entries are all owned.
    var wrappers: std.ArrayList(Span) = .empty;
    for (scan.lines, 0..) |line, i| {
        if (line.kind != .header) continue;
        var strict_prefix = false;
        var at_or_under = false;
        for (own_paths) |p| {
            const as_section = try iniFoldDeclared(arena, dialect, p.segments, false);
            const as_key = try iniFoldDeclared(arena, dialect, p.segments, true);
            if (segsPrefix(as_section, line.path)) at_or_under = true;
            if (line.path.len < as_key.len and segsPrefix(line.path, as_key[0..line.path.len])) strict_prefix = true;
        }
        if (at_or_under or !strict_prefix) continue;
        var all_owned = line.inline_key == null;
        var j = i + 1;
        while (j < scan.lines.len and scan.lines[j].kind != .header) : (j += 1) {
            if (scan.lines[j].kind != .kv) continue;
            var owned_kv = false;
            for (own_paths) |p| {
                const as_key = try iniFoldDeclared(arena, dialect, p.segments, true);
                if (segsPrefix(as_key, scan.lines[j].path)) owned_kv = true;
            }
            if (!owned_kv) all_owned = false;
        }
        if (all_owned) try wrappers.append(arena, .{ .start = line.start, .end = line.end });
    }

    return .{ .spans = spans, .forms = forms, .wrappers = try wrappers.toOwnedSlice(arena) };
}

fn iniReplace(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    own_paths: []const OwnPath,
    owned: *const OwnedDoc,
    diag: ?*Diag,
) ReplaceError![]u8 {
    const dialect = iniDialect(format);
    var text: []const u8 = live;
    for (own_paths, 0..) |p, pi| {
        const scan = try iniScan(arena, format, text);
        const loc = try iniLocateScanned(arena, format, &scan, text, own_paths, diag);
        const sub = owned.subtreeAt(p.segments);
        const span = loc.spans[pi];

        if (sub == null) {
            if (span) |sp| text = try spliceBytes(arena, text, sp, "");
            continue;
        }
        const value = sub.?.ini;

        if (span) |sp| {
            const replacement = switch (loc.forms[pi]) {
                .kv => try iniRenderKv(arena, format, p.segments[p.segments.len - 1], value, diag),
                .block => blk: {
                    if (value != .section) {
                        diagSet(diag, "{s}: live section cannot take a non-section owned value", .{p.raw});
                        return error.OwnedRenderFailed;
                    }
                    const block = try iniRenderBlock(arena, format, p.segments, value.section.*, diag);
                    break :blk try std.mem.concat(arena, u8, &.{ block, trailingBlankRun(text, sp) });
                },
                else => unreachable,
            };
            text = try spliceBytes(arena, text, sp, replacement);
            continue;
        }

        // Append: sections at end of file; a leaf entry goes to the end of
        // its parent section, creating the section block when absent.
        if (value == .section) {
            const block = try iniRenderBlock(arena, format, p.segments, value.section.*, diag);
            text = try insertWithSeparator(arena, text, text.len, block);
            continue;
        }
        const kv_lines = try iniRenderKv(arena, format, p.segments[p.segments.len - 1], value, diag);
        const parent = p.segments[0 .. p.segments.len - 1];
        if (parent.len == 0) {
            if (!dialect.global_keys) {
                diagSet(diag, "{s}: dialect does not allow keys outside a section", .{p.raw});
                return error.OwnedRenderFailed;
            }
            var at: usize = scan.bom;
            for (scan.lines) |line| {
                if (line.kind == .header) break;
                if (line.kind == .kv) at = line.end;
            }
            text = try insertWithSeparator(arena, text, at, kv_lines);
            continue;
        }
        const parent_folded = try iniFoldDeclared(arena, dialect, parent, false);
        if (iniSectionInsertOffset(&scan, parent_folded)) |at| {
            text = try insertWithSeparator(arena, text, at, kv_lines);
        } else {
            const header = try iniHeaderSpell(arena, parent);
            const block = try std.mem.concat(arena, u8, &.{ header, kv_lines });
            text = try insertWithSeparator(arena, text, text.len, block);
        }
    }
    return @constCast(text);
}

fn iniSectionInsertOffset(scan: *const IniScan, parent: []const []const u8) ?usize {
    for (scan.lines, 0..) |line, i| {
        if (line.kind != .header or !segsEq(line.path, parent)) continue;
        var at = line.end;
        var j = i + 1;
        while (j < scan.lines.len and scan.lines[j].kind != .header) : (j += 1) {
            if (scan.lines[j].kind == .kv) at = scan.lines[j].end;
        }
        return at;
    }
    return null;
}

fn iniHeaderSpell(arena: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    if (segments.len == 1) return std.mem.concat(arena, u8, &.{ "[", segments[0], "]\n" });
    var sub: std.ArrayList(u8) = .empty;
    for (segments[1]) |c| {
        if (c == '"' or c == '\\') try sub.append(arena, '\\');
        try sub.append(arena, c);
    }
    return std.mem.concat(arena, u8, &.{ "[", segments[0], " \"", sub.items, "\"]\n" });
}

fn iniRenderValueText(arena: std.mem.Allocator, format: Format, s: []const u8, diag: ?*Diag) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    if (format != .gitconfig) {
        if (std.mem.indexOfAny(u8, s, "\r\n") != null) {
            diagSet(diag, "value contains a newline the dialect cannot carry", .{});
            return error.OwnedRenderFailed;
        }
        return s;
    }
    const needs_quote = s.len == 0 or
        s[0] == ' ' or s[0] == '\t' or
        s[s.len - 1] == ' ' or s[s.len - 1] == '\t' or
        std.mem.indexOfAny(u8, s, "#;\"\\\n\t") != null;
    if (!needs_quote) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => try out.append(arena, c),
    };
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

fn iniRenderKv(arena: std.mem.Allocator, format: Format, key: []const u8, v: ini.Value, diag: ?*Diag) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    switch (v) {
        .string => |s| {
            const value_text = try iniRenderValueText(arena, format, s, diag);
            return std.mem.concat(arena, u8, &.{ key, " = ", value_text, "\n" });
        },
        .list => |items| {
            var out: std.ArrayList(u8) = .empty;
            for (items) |s| {
                const value_text = try iniRenderValueText(arena, format, s, diag);
                try out.appendSlice(arena, key);
                try out.appendSlice(arena, " = ");
                try out.appendSlice(arena, value_text);
                try out.append(arena, '\n');
            }
            return out.toOwnedSlice(arena);
        },
        .section => {
            diagSet(diag, "{s}: section value in key position", .{key});
            return error.OwnedRenderFailed;
        },
    }
}

fn iniRenderBlock(
    arena: std.mem.Allocator,
    format: Format,
    segments: []const []const u8,
    section: ini.Section,
    diag: ?*Diag,
) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var direct: usize = 0;
    for (section.entries) |e| {
        if (e.value != .section) direct += 1;
    }
    if (direct > 0 or direct == section.entries.len) {
        try out.appendSlice(arena, try iniHeaderSpell(arena, segments));
        for (section.entries) |e| {
            if (e.value == .section) continue;
            try out.appendSlice(arena, try iniRenderKv(arena, format, e.key, e.value, diag));
        }
    }
    for (section.entries) |e| {
        if (e.value != .section) continue;
        if (segments.len >= 2) {
            diagSet(diag, "{s}: subsection nested deeper than the format allows", .{e.key});
            return error.OwnedRenderFailed;
        }
        var sub_path: std.ArrayList([]const u8) = .empty;
        try sub_path.appendSlice(arena, segments);
        try sub_path.append(arena, e.key);
        try out.appendSlice(arena, try iniRenderBlock(arena, format, sub_path.items, e.value.section.*, diag));
    }
    return out.toOwnedSlice(arena);
}

// Onboarding extraction (`mox add --own`)

pub const ExtractError = LocateError || error{ OwnedPathMissing, OwnedRenderFailed };

/// Assemble a source file's text from the live file's RAW BYTE SPANS of the
/// declared paths, in declaration order, with the minimal structure the
/// format needs so the result parses on its own (a nested leaf gains its
/// parent header, JSON and YAML gain their ancestor containers). Comments
/// and layout inside the spans survive verbatim. A declared path with no
/// live presence is an error: absence is declared explicitly, never
/// inferred. The caller validates the result (parse, declaration coverage,
/// canonical equality with the live owned content) before writing it.
pub fn extractOwnedSource(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    own_paths: []const OwnPath,
    diag: ?*Diag,
) ExtractError![]u8 {
    const text = try ensureTrailingNewline(arena, live);
    const loc = try locateFull(arena, format, text, own_paths, diag);
    for (own_paths, loc.spans) |p, span| {
        if (span == null) {
            diagSet(diag, "{s}: not present in the live file (declare enforced absence with --own-absent)", .{p.raw});
            return error.OwnedPathMissing;
        }
    }
    return switch (format) {
        .toml, .ini, .gitconfig => extractHeaderForm(arena, format, text, own_paths, loc),
        .json => extractJson(arena, text, own_paths, loc),
        .yaml => extractYaml(arena, text, own_paths, loc, diag),
    };
}

/// TOML and ini share the header-block shape: block spans carry their own
/// headers verbatim; a root-level kv line goes first (after a block it would
/// silently join the preceding table); a nested kv line gains a generated
/// parent header, one per parent in first-use order.
fn extractHeaderForm(
    arena: std.mem.Allocator,
    format: Format,
    text: []const u8,
    own_paths: []const OwnPath,
    loc: FullLocated,
) ExtractError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (own_paths, loc.spans, loc.forms) |p, span, form| {
        if (form != .kv or p.segments.len != 1) continue;
        try out.appendSlice(arena, text[span.?.start..span.?.end]);
    }
    var emitted: std.ArrayList([]const []const u8) = .empty;
    for (own_paths, 0..) |p, i| {
        const form = loc.forms[i];
        if (form == .block) {
            try out.appendSlice(arena, text[loc.spans[i].?.start..loc.spans[i].?.end]);
            continue;
        }
        if (form != .kv or p.segments.len == 1) continue;
        const parent = p.segments[0 .. p.segments.len - 1];
        var seen = false;
        for (emitted.items) |e| {
            if (segsEq(e, parent)) seen = true;
        }
        if (seen) continue;
        try emitted.append(arena, parent);
        const header = switch (format) {
            .toml => try std.mem.concat(arena, u8, &.{ "[", try tomlPathSpell(arena, parent), "]\n" }),
            else => try iniHeaderSpell(arena, parent),
        };
        try out.appendSlice(arena, header);
        // Every declared kv under the same parent joins this one header.
        for (own_paths, loc.spans, loc.forms) |q, qspan, qform| {
            if (qform != .kv or q.segments.len != p.segments.len) continue;
            if (!segsEq(q.segments[0 .. q.segments.len - 1], parent)) continue;
            try out.appendSlice(arena, text[qspan.?.start..qspan.?.end]);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Declaration tree for the container formats: leaves hold their raw span
/// text, interior nodes are the generated ancestor containers. Overlapping
/// declared paths are already rejected, so a leaf never gains children.
const ExtractNode = struct {
    seg: []const u8 = "",
    children: std.ArrayList(*ExtractNode) = .empty,
    span_text: ?[]const u8 = null,
};

fn extractTree(
    arena: std.mem.Allocator,
    own_paths: []const OwnPath,
    span_texts: []const []const u8,
) error{OutOfMemory}!*ExtractNode {
    const root = try arena.create(ExtractNode);
    root.* = .{};
    for (own_paths, span_texts) |p, span_text| {
        var cur = root;
        for (p.segments[0 .. p.segments.len - 1]) |seg| {
            var next: ?*ExtractNode = null;
            for (cur.children.items) |c| {
                if (std.mem.eql(u8, c.seg, seg)) next = c;
            }
            if (next == null) {
                const n = try arena.create(ExtractNode);
                n.* = .{ .seg = seg };
                try cur.children.append(arena, n);
                next = n;
            }
            cur = next.?;
        }
        const leaf = try arena.create(ExtractNode);
        leaf.* = .{ .seg = p.segments[p.segments.len - 1], .span_text = span_text };
        try cur.children.append(arena, leaf);
    }
    return root;
}

fn extractJson(
    arena: std.mem.Allocator,
    text: []const u8,
    own_paths: []const OwnPath,
    loc: FullLocated,
) ExtractError![]u8 {
    const spans = try arena.alloc([]const u8, own_paths.len);
    for (loc.spans, spans) |span, *s| {
        // Member spans carry splice separators; the extracted member stands
        // alone, so strip surrounding commas and whitespace.
        s.* = std.mem.trim(u8, text[span.?.start..span.?.end], " \t\r\n,");
    }
    const root = try extractTree(arena, own_paths, spans);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\n");
    try extractJsonNode(arena, &out, root);
    try out.appendSlice(arena, "\n}\n");
    return out.toOwnedSlice(arena);
}

fn extractJsonNode(arena: std.mem.Allocator, out: *std.ArrayList(u8), node: *const ExtractNode) ExtractError!void {
    for (node.children.items, 0..) |c, i| {
        if (i > 0) try out.appendSlice(arena, ",\n");
        if (c.span_text) |span| {
            try out.appendSlice(arena, span);
            continue;
        }
        try out.appendSlice(arena, try jsonKeyLiteral(arena, c.seg));
        try out.appendSlice(arena, ": {");
        try extractJsonNode(arena, out, c);
        try out.append(arena, '}');
    }
}

fn jsonKeyLiteral(arena: std.mem.Allocator, seg: []const u8) error{ OutOfMemory, OwnedRenderFailed }![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    json.encode(&aw.writer, .{ .string = seg }, .{}) catch return error.OwnedRenderFailed;
    return arena.dupe(u8, aw.written());
}

fn extractYaml(
    arena: std.mem.Allocator,
    text: []const u8,
    own_paths: []const OwnPath,
    loc: FullLocated,
    diag: ?*Diag,
) ExtractError![]u8 {
    const spans = try arena.alloc([]const u8, own_paths.len);
    for (loc.spans, spans) |span, *s| s.* = text[span.?.start..span.?.end];
    const root = try extractTree(arena, own_paths, spans);
    var out: std.ArrayList(u8) = .empty;
    try extractYamlNode(arena, &out, root, 0, diag);
    return out.toOwnedSlice(arena);
}

/// Generated ancestors indent one space per depth. A live block member at
/// depth n starts at column >= n (each live level indents at least one), so
/// its raw span is always deeper than its generated parent at column n-1.
fn extractYamlNode(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    node: *const ExtractNode,
    depth: usize,
    diag: ?*Diag,
) ExtractError!void {
    for (node.children.items) |c| {
        if (c.span_text) |span| {
            try out.appendSlice(arena, span);
            continue;
        }
        for (0..depth) |_| try out.append(arena, ' ');
        try out.appendSlice(arena, try yamlScalarText(arena, .{ .string = c.seg }, diag));
        try out.appendSlice(arena, ":\n");
        try extractYamlNode(arena, out, c, depth + 1, diag);
    }
}

/// Top-level live entries with no ownership relation to any declared path:
/// neither at or under a declared path nor an ancestor of one. Reported by
/// `mox add --own` as what stays the program's.
pub fn unownedTopLevelCount(doc: *const OwnedDoc, own_paths: []const OwnPath) usize {
    var count: usize = 0;
    switch (doc.root) {
        .toml => |v| {
            if (v != .table) return 0;
            for (v.table.keys()) |k| count += @intFromBool(rootKeyUnowned(own_paths, k));
        },
        .json => |v| {
            if (v != .object) return 0;
            for (v.object.keys()) |k| count += @intFromBool(rootKeyUnowned(own_paths, k));
        },
        .yaml => |v| {
            if (v != .map) return 0;
            for (v.map) |e| {
                if (e.key != .string) {
                    count += 1;
                    continue;
                }
                count += @intFromBool(rootKeyUnowned(own_paths, e.key.string));
            }
        },
        .ini => |v| {
            for (v.section.entries) |e| count += @intFromBool(rootKeyUnowned(own_paths, e.key));
        },
    }
    return count;
}

fn rootKeyUnowned(own_paths: []const OwnPath, key: []const u8) bool {
    const one = [_][]const u8{key};
    return !pathAtOrUnderDeclared(own_paths, &one) and !pathStrictPrefixOfDeclared(own_paths, &one);
}

/// True when any leaf under a declared path is the snapshot secret mask --
/// evidence the text came from a secret-masked snapshot, whose placeholders
/// must never be written live.
pub fn ownedHasSecretMask(doc: *const OwnedDoc, own_paths: []const OwnPath) bool {
    for (own_paths) |p| {
        const sub = doc.subtreeAt(p.segments) orelse continue;
        if (valueHasMask(sub)) return true;
    }
    return false;
}

fn valueHasMask(v: AnyValue) bool {
    switch (v) {
        .toml => |tv| switch (tv) {
            .string => |s| return std.mem.eql(u8, s, secret_mask),
            .table => |tbl| for (tbl.values()) |sub| {
                if (valueHasMask(.{ .toml = sub })) return true;
            },
            .array => |arr| for (arr.items) |sub| {
                if (valueHasMask(.{ .toml = sub })) return true;
            },
            else => {},
        },
        .json => |jv| switch (jv) {
            .string => |s| return std.mem.eql(u8, s, secret_mask),
            .object => |obj| for (obj.values()) |sub| {
                if (valueHasMask(.{ .json = sub })) return true;
            },
            .array => |arr| for (arr) |sub| {
                if (valueHasMask(.{ .json = sub })) return true;
            },
            else => {},
        },
        .yaml => |yv| switch (yv) {
            .string => |s| return std.mem.eql(u8, s, secret_mask),
            .map => |m| for (m) |e| {
                if (valueHasMask(.{ .yaml = e.value })) return true;
            },
            .seq => |sq| for (sq) |sub| {
                if (valueHasMask(.{ .yaml = sub })) return true;
            },
            else => {},
        },
        .ini => |iv| switch (iv) {
            .string => |s| return std.mem.eql(u8, s, secret_mask),
            .list => |items| for (items) |s| {
                if (std.mem.eql(u8, s, secret_mask)) return true;
            },
            .section => |sec| for (sec.entries) |e| {
                if (valueHasMask(.{ .ini = e.value })) return true;
            },
        },
    }
    return false;
}

// Disown mode: the roles invert. The owned document is the ENTIRE composed
// source; the declared paths' spans in the live file are the protected
// remainder. The candidate is the composed TEXT with the live disowned
// spans spliced in at the format's placement point, and the invariant
// verifies (a) the candidate minus the disowned subtrees equals the
// composed document, (b) each disowned span survives byte-identically from
// live to candidate, and (c) the candidate minus the disowned spans equals
// the composed text byte-for-byte.

/// D2 inverted: the first declared path the composed document populates
/// (spelled), or null. Composed content under a disowned path can never be
/// asserted; refusing names the contradiction.
pub fn populatedDisownPath(
    arena: std.mem.Allocator,
    owned: *const OwnedDoc,
    disown_paths: []const OwnPath,
) error{OutOfMemory}!?[]const u8 {
    for (disown_paths) |p| {
        if (owned.subtreeAt(p.segments) != null) return try diagPathSpell(arena, p.segments);
    }
    return null;
}

/// The document with the declared subtrees removed. A container left empty
/// by a removal (pure framing of disowned content) is removed with it; a
/// container that was already empty stays.
pub fn withoutSubtrees(
    arena: std.mem.Allocator,
    doc: *const OwnedDoc,
    paths: []const OwnPath,
) error{OutOfMemory}!OwnedDoc {
    var stored: std.ArrayList([]const u8) = .empty;
    var folds: std.ArrayList(bool) = .empty;
    const pruned = try pruneValue(arena, doc.format, doc.root, paths, &stored, &folds);
    const root = pruned orelse switch (doc.format) {
        .toml => AnyValue{ .toml = .{ .table = .empty } },
        .json => AnyValue{ .json = .{ .object = .empty } },
        .yaml => AnyValue{ .yaml = .null },
        .ini, .gitconfig => blk: {
            const sec = try arena.create(ini.Section);
            sec.* = .{ .entries = &.{} };
            break :blk AnyValue{ .ini = .{ .section = sec } };
        },
    };
    return .{ .format = doc.format, .root = root };
}

fn pathEqualsDeclaredFold(paths: []const OwnPath, stored: []const []const u8, folds: []const bool) bool {
    for (paths) |p| {
        if (p.segments.len == stored.len and segsPrefixFold(p.segments, stored, folds)) return true;
    }
    return false;
}

/// Returns null when this node is removed whole. Containers rebuild their
/// entry lists; one emptied by a removal is dropped too.
fn pruneValue(
    arena: std.mem.Allocator,
    format: Format,
    v: AnyValue,
    paths: []const OwnPath,
    stored: *std.ArrayList([]const u8),
    folds: *std.ArrayList(bool),
) error{OutOfMemory}!?AnyValue {
    if (pathEqualsDeclaredFold(paths, stored.items, folds.items)) return null;
    if (!pathStrictPrefixOfDeclaredFold(paths, stored.items, folds.items)) return v;

    switch (v) {
        .toml => |tv| {
            if (tv != .table) return v;
            var out: toml.Value.Table = .empty;
            var removed = false;
            for (tv.table.keys(), tv.table.values()) |k, sub| {
                try stored.append(arena, k);
                try folds.append(arena, false);
                const kept = try pruneValue(arena, format, .{ .toml = sub }, paths, stored, folds);
                _ = stored.pop();
                _ = folds.pop();
                if (kept) |kv| try out.put(arena, k, kv.toml) else removed = true;
            }
            if (removed and out.count() == 0 and tv.table.count() != 0) return null;
            return .{ .toml = .{ .table = out } };
        },
        .json => |jv| {
            if (jv != .object) return v;
            var out: json.ObjectMap = .empty;
            var removed = false;
            for (jv.object.keys(), jv.object.values()) |k, sub| {
                try stored.append(arena, k);
                try folds.append(arena, false);
                const kept = try pruneValue(arena, format, .{ .json = sub }, paths, stored, folds);
                _ = stored.pop();
                _ = folds.pop();
                if (kept) |kv| try out.put(arena, k, kv.json) else removed = true;
            }
            if (removed and out.count() == 0 and jv.object.count() != 0) return null;
            return .{ .json = .{ .object = out } };
        },
        .yaml => |yv| {
            if (yv != .map) return v;
            var out: std.ArrayList(yaml.Entry) = .empty;
            var removed = false;
            for (yv.map) |entry| {
                if (entry.key != .string) {
                    try out.append(arena, entry);
                    continue;
                }
                try stored.append(arena, entry.key.string);
                try folds.append(arena, false);
                const kept = try pruneValue(arena, format, .{ .yaml = entry.value }, paths, stored, folds);
                _ = stored.pop();
                _ = folds.pop();
                if (kept) |kv| {
                    try out.append(arena, .{ .key = entry.key, .value = kv.yaml });
                } else removed = true;
            }
            if (removed and out.items.len == 0 and yv.map.len != 0) return null;
            return .{ .yaml = .{ .map = try out.toOwnedSlice(arena) } };
        },
        .ini => |iv| {
            if (iv != .section) return v;
            var out: std.ArrayList(ini.value.Entry) = .empty;
            var removed = false;
            for (iv.section.entries) |entry| {
                const fold = iniEntryFold(iniDialect(format), entry.value == .section, stored.items.len);
                try stored.append(arena, entry.key);
                try folds.append(arena, fold);
                const kept = try pruneValue(arena, format, .{ .ini = entry.value }, paths, stored, folds);
                _ = stored.pop();
                _ = folds.pop();
                if (kept) |kv| {
                    try out.append(arena, .{ .key = entry.key, .value = kv.ini });
                } else removed = true;
            }
            if (removed and out.items.len == 0 and iv.section.entries.len != 0) return null;
            const sec = try arena.create(ini.Section);
            sec.* = .{ .entries = try out.toOwnedSlice(arena) };
            return .{ .ini = .{ .section = sec } };
        },
    }
}

/// Dialect-aware one-segment match against a stored key of the given role,
/// shared with the canonical record tree's subtraction.
pub fn segMatchesStored(format: Format, stored: []const u8, declared: []const u8, is_container: bool, depth: usize) bool {
    const fold = switch (format) {
        .ini, .gitconfig => iniEntryFold(iniDialect(format), is_container, depth),
        else => false,
    };
    return segEqFold(stored, declared, fold);
}

/// True when the document holds the snapshot secret mask anywhere OUTSIDE
/// the declared (disowned) subtrees -- the disown-mode twin of
/// `ownedHasSecretMask`.
pub fn complementHasSecretMask(
    arena: std.mem.Allocator,
    doc: *const OwnedDoc,
    disown_paths: []const OwnPath,
) error{OutOfMemory}!bool {
    const pruned = try withoutSubtrees(arena, doc, disown_paths);
    return valueHasMask(pruned.root);
}

/// Build the disown-mode candidate: the composed text with each disowned
/// path's live span inserted at the format's placement point (raw bytes, so
/// the program's content survives verbatim). A path with no live presence
/// contributes nothing. Refusal shapes surface from the live locate.
pub fn replaceDisowned(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    disown_paths: []const OwnPath,
    composed_text: []const u8,
    diag: ?*Diag,
) ReplaceError![]u8 {
    if (live.len == 0) return arena.dupe(u8, composed_text);
    const loc = try locateFull(arena, format, live, disown_paths, diag);
    var text: []const u8 = composed_text;
    for (disown_paths, loc.spans, loc.forms) |p, span_opt, form| {
        const sp = span_opt orelse continue;
        const raw = live[sp.start..sp.end];
        text = switch (format) {
            .toml => try tomlInsertRaw(arena, text, p, raw, form, diag),
            .ini, .gitconfig => try iniInsertRaw(arena, format, text, p, raw, form, diag),
            .json => try jsonInsertRaw(arena, text, p, raw, diag),
            .yaml => try yamlInsertRaw(arena, text, p, raw, diag),
        };
    }
    return @constCast(text);
}

fn tomlInsertRaw(
    arena: std.mem.Allocator,
    text: []const u8,
    p: OwnPath,
    raw: []const u8,
    form: Form,
    diag: ?*Diag,
) ReplaceError![]const u8 {
    const raw_nl = try ensureTrailingNewline(arena, raw);
    if (form == .block) return insertWithSeparator(arena, text, text.len, raw_nl);
    const scan = tomlScan(arena, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagSet(diag, "{s}: composed text does not parse for the splice", .{p.raw});
            return error.OwnedRenderFailed;
        },
    };
    const parent = p.segments[0 .. p.segments.len - 1];
    if (parent.len == 0) {
        return insertWithSeparator(arena, text, tomlRootInsertOffset(&scan), raw_nl);
    }
    if (tomlSectionInsertOffset(&scan, parent)) |at| {
        return insertWithSeparator(arena, text, at, raw_nl);
    }
    const header = try tomlPathSpell(arena, parent);
    const block = try std.mem.concat(arena, u8, &.{ "[", header, "]\n", raw_nl });
    return insertWithSeparator(arena, text, text.len, block);
}

fn iniInsertRaw(
    arena: std.mem.Allocator,
    format: Format,
    text: []const u8,
    p: OwnPath,
    raw: []const u8,
    form: Form,
    diag: ?*Diag,
) ReplaceError![]const u8 {
    const dialect = iniDialect(format);
    const raw_nl = try ensureTrailingNewline(arena, raw);
    if (form == .block) return insertWithSeparator(arena, text, text.len, raw_nl);
    const scan = iniScan(arena, format, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagSet(diag, "{s}: composed text does not parse for the splice", .{p.raw});
            return error.OwnedRenderFailed;
        },
    };
    const parent = p.segments[0 .. p.segments.len - 1];
    if (parent.len == 0) {
        if (!dialect.global_keys) {
            diagSet(diag, "{s}: dialect does not allow keys outside a section", .{p.raw});
            return error.OwnedRenderFailed;
        }
        var at: usize = scan.bom;
        for (scan.lines) |line| {
            if (line.kind == .header) break;
            if (line.kind == .kv) at = line.end;
        }
        return insertWithSeparator(arena, text, at, raw_nl);
    }
    const parent_folded = try iniFoldDeclared(arena, dialect, parent, false);
    if (iniSectionInsertOffset(&scan, parent_folded)) |at| {
        return insertWithSeparator(arena, text, at, raw_nl);
    }
    const header = try iniHeaderSpell(arena, parent);
    const block = try std.mem.concat(arena, u8, &.{ header, raw_nl });
    return insertWithSeparator(arena, text, text.len, block);
}

fn jsonInsertRaw(
    arena: std.mem.Allocator,
    text: []const u8,
    p: OwnPath,
    raw: []const u8,
    diag: ?*Diag,
) ReplaceError![]const u8 {
    const member = std.mem.trim(u8, raw, " \t\r\n,");
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        return std.mem.concat(arena, u8, &.{ "{\n  ", member, "\n}\n" });
    }
    const doc = json.Document.parse(arena, text, .{ .dialect = .jsonc }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagSet(diag, "{s}: composed text does not parse for the splice", .{p.raw});
            return error.OwnedRenderFailed;
        },
    };
    if (doc.root.data != .object) {
        diagSet(diag, "{s}: root of the composed document is not an object", .{p.raw});
        return error.OwnedRenderFailed;
    }

    // Deepest existing ancestor object along the declared path. Ancestors
    // the composed document does not populate are created around the
    // spliced member, so the leaf keeps its declared path.
    var cur = doc.root;
    var depth: usize = 0;
    while (depth < p.segments.len - 1) {
        if (cur.data != .object) break;
        var next: ?@TypeOf(cur) = null;
        for (cur.data.object.items) |m| {
            if (std.mem.eql(u8, m.key.decoded, p.segments[depth])) next = m.value;
        }
        cur = next orelse break;
        depth += 1;
    }
    if (cur.data != .object) {
        diagSet(diag, "{s}: path runs through a non-object value", .{p.raw});
        return error.OwnedRenderFailed;
    }
    var wrapped: []const u8 = member;
    var lvl = p.segments.len - 1;
    while (lvl > depth) : (lvl -= 1) {
        wrapped = try std.mem.concat(arena, u8, &.{
            try jsonKeyLiteral(arena, p.segments[lvl - 1]), ": {", wrapped, "}",
        });
    }
    const members = cur.data.object.items;
    if (members.len == 0) {
        return std.mem.concat(arena, u8, &.{
            text[0 .. cur.outer.start + 1], wrapped, text[cur.outer.end - 1 ..],
        });
    }
    const last = members[members.len - 1];
    const value_end = last.value.outer.end;
    if (value_end < text.len and text[value_end] == ',') {
        diagSet(diag, "{s}: composed object carries a trailing comma the splice cannot keep", .{p.raw});
        return error.OwnedRenderFailed;
    }
    const key_line = lineStartOf(text, last.key.outer.start);
    const indent = text[key_line..firstNonWs(text, key_line)];
    return std.mem.concat(arena, u8, &.{
        text[0..value_end], ",\n", indent, wrapped, text[value_end..],
    });
}

fn yamlInsertRaw(
    arena: std.mem.Allocator,
    text: []const u8,
    p: OwnPath,
    raw: []const u8,
    diag: ?*Diag,
) ReplaceError![]const u8 {
    const raw_nl = try ensureTrailingNewline(arena, raw);
    const raw_indent = raw_nl[0..firstNonWs(raw_nl, 0)];
    const scan = yamlScan(arena, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagSet(diag, "{s}: composed text does not parse for the splice", .{p.raw});
            return error.OwnedRenderFailed;
        },
    };
    if (scan.empty or scan.doc.roots.len == 0) {
        if (raw_indent.len != 0) {
            diagSet(diag, "{s}: live span indentation does not fit an empty composed document", .{p.raw});
            return error.OwnedRenderFailed;
        }
        return insertWithSeparator(arena, text, text.len, raw_nl);
    }
    const src = scan.doc.source;
    const root = scan.doc.roots[0];
    if (root.data != .mapping) {
        diagSet(diag, "{s}: root of the composed document is not a mapping", .{p.raw});
        return error.OwnedRenderFailed;
    }

    // Deepest existing ancestor mapping. Ancestors the composed document
    // does not populate are created around the spliced member, so the leaf
    // keeps its declared path.
    var cur = root;
    var depth: usize = 0;
    while (depth < p.segments.len - 1) {
        if (cur.data != .mapping) break;
        var next: ?@TypeOf(cur) = null;
        for (cur.data.mapping.items) |m| {
            if (std.mem.eql(u8, m.key.decoded, p.segments[depth])) next = m.value;
        }
        cur = next orelse break;
        depth += 1;
    }
    if (cur.data != .mapping) {
        diagSet(diag, "{s}: path runs through a non-mapping value", .{p.raw});
        return error.OwnedRenderFailed;
    }
    if (src.len > cur.outer.start and src[cur.outer.start] == '{') {
        diagSet(diag, "{s}: path runs through a flow-style mapping", .{p.raw});
        return error.OwnedRenderFailed;
    }
    const members = cur.data.mapping.items;
    if (members.len == 0) {
        diagSet(diag, "{s}: the composed parent mapping has no block members to splice beside", .{p.raw});
        return error.OwnedRenderFailed;
    }
    const last = members[members.len - 1];
    const key_line = lineStartOf(src, last.key.outer.start);
    const indent = src[key_line..firstNonWs(src, key_line)];
    const at = lineEndOf(src, last.value.outer.end);
    if (depth == p.segments.len - 1) {
        if (!std.mem.eql(u8, raw_indent, indent)) {
            diagSet(diag, "{s}: live span indentation does not match the composed parent mapping", .{p.raw});
            return error.OwnedRenderFailed;
        }
        return insertWithSeparator(arena, text, at, raw_nl);
    }
    var chain: std.ArrayList(u8) = .empty;
    var pad: []const u8 = indent;
    for (p.segments[depth .. p.segments.len - 1]) |seg| {
        try chain.appendSlice(arena, pad);
        try chain.appendSlice(arena, try yamlScalarText(arena, .{ .string = seg }, diag));
        try chain.appendSlice(arena, ":\n");
        pad = try std.mem.concat(arena, u8, &.{ pad, "  " });
    }
    // The live span's lines must nest under the innermost created key.
    if (raw_indent.len <= pad.len - 2) {
        diagSet(diag, "{s}: live span indentation does not fit under the created parent chain", .{p.raw});
        return error.OwnedRenderFailed;
    }
    try chain.appendSlice(arena, raw_nl);
    return insertWithSeparator(arena, text, at, chain.items);
}

/// `text` minus every located span and wrapper region: the public remainder,
/// for callers reconstructing a disown-mode owned complement (`add --disown`
/// extraction, rollback's snapshot re-patch). Unlike the raw remainder the
/// invariant compares, this splice tidies the separator bytes the removal
/// orphans: a suffix run of JSON members takes the now-dangling comma of the
/// preceding member with it, a removed member's emptied line goes whole, and
/// blank separation lines never stack or trail.
pub fn textWithoutSpans(arena: std.mem.Allocator, format: Format, text: []const u8, loc: Located) error{OutOfMemory}![]u8 {
    var regions: std.ArrayList(Span) = .empty;
    for (loc.spans) |s| if (s) |sp| try regions.append(arena, sp);
    for (loc.wrappers) |w| try regions.append(arena, w);
    std.mem.sort(Span, regions.items, {}, spanLess);
    var merged: std.ArrayList(Span) = .empty;
    for (regions.items) |r| {
        if (merged.items.len > 0 and r.start <= merged.items[merged.items.len - 1].end) {
            merged.items[merged.items.len - 1].end = @max(merged.items[merged.items.len - 1].end, r.end);
        } else {
            try merged.append(arena, r);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (merged.items) |r0| {
        var r = r0;
        if (format == .json) {
            jsonAbsorbDanglingComma(text, &r);
            jsonAbsorbEmptiedLine(text, &r);
        }
        if (r.start > cursor) try out.appendSlice(arena, text[cursor..r.start]);
        cursor = @max(cursor, r.end);
        if (endsWithBlankLine(out.items)) cursor = skipBlankLines(text, cursor);
    }
    if (cursor < text.len) try out.appendSlice(arena, text[cursor..]);

    // A removed final span leaves the blank separation before it trailing.
    const last_end = if (merged.items.len > 0) merged.items[merged.items.len - 1].end else 0;
    if (merged.items.len > 0 and std.mem.trim(u8, text[@min(last_end, text.len)..], " \t\r\n").len == 0) {
        trimTrailingBlankLines(&out);
    }
    return out.toOwnedSlice(arena);
}

/// When removing this member run leaves its object's remaining last member
/// followed by a separator comma (the run was the object's suffix), the
/// comma belongs to the removal.
fn jsonAbsorbDanglingComma(text: []const u8, r: *Span) void {
    var i = r.end;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) i += 1;
    if (i >= text.len or text[i] != '}') return;
    var j = r.start;
    while (j > 0) : (j -= 1) {
        const c = text[j - 1];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
        if (c == ',') r.start = j - 1;
        return;
    }
}

/// A removed member that owned its whole line (only indentation before it,
/// only whitespace after it) takes the line entire, newline included, so
/// the next member slides into its place instead of leaving an emptied
/// indentation-only line behind.
fn jsonAbsorbEmptiedLine(text: []const u8, r: *Span) void {
    const line_start = lineStartOf(text, r.start);
    for (text[line_start..r.start]) |c| {
        if (c != ' ' and c != '\t') return;
    }
    var i = r.end;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r')) i += 1;
    if (i >= text.len or text[i] != '\n') return;
    r.start = line_start;
    r.end = i + 1;
}

/// True when the spliced output so far ends on a completed blank line (or is
/// still empty), so blank separation carried by the following remainder
/// would stack.
fn endsWithBlankLine(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s[s.len - 1] != '\n') return false;
    const body = s[0 .. s.len - 1];
    const line_start = if (std.mem.lastIndexOfScalar(u8, body, '\n')) |i| i + 1 else 0;
    return std.mem.trim(u8, body[line_start..], " \t\r").len == 0;
}

fn skipBlankLines(text: []const u8, pos: usize) usize {
    var cursor = pos;
    while (cursor < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, cursor, '\n') orelse break;
        if (std.mem.trim(u8, text[cursor..nl], " \t\r").len != 0) break;
        cursor = nl + 1;
    }
    return cursor;
}

fn trimTrailingBlankLines(out: *std.ArrayList(u8)) void {
    var n = out.items.len;
    while (n > 0 and out.items[n - 1] == '\n') {
        const body = out.items[0 .. n - 1];
        const line_start = if (std.mem.lastIndexOfScalar(u8, body, '\n')) |i| i + 1 else 0;
        if (std.mem.trim(u8, body[line_start..], " \t\r").len != 0) break;
        n = line_start;
    }
    out.shrinkRetainingCapacity(n);
}

/// A located span narrowed to its structural bounds: JSON members run
/// key-start to value-end with at most one separator comma stripped from
/// each side; line-format spans drop trailing blank lines and the final
/// line terminator. Interior bytes -- trailing spaces on a content line
/// included -- are compared exactly; only separator bytes the splice owns
/// fall outside the bounds.
fn structuralSpan(format: Format, bytes: []const u8) []const u8 {
    if (format == .json) {
        var s = std.mem.trim(u8, bytes, " \t\r\n");
        if (s.len > 0 and s[0] == ',') s = std.mem.trimStart(u8, s[1..], " \t\r\n");
        if (s.len > 0 and s[s.len - 1] == ',') s = std.mem.trimEnd(u8, s[0 .. s.len - 1], " \t\r\n");
        return s;
    }
    var s = bytes;
    while (s.len > 0 and s[s.len - 1] == '\n') {
        const body = s[0 .. s.len - 1];
        const line_start = if (std.mem.lastIndexOfScalar(u8, body, '\n')) |i| i + 1 else 0;
        if (std.mem.trim(u8, body[line_start..], " \t\r").len != 0) break;
        s = s[0..line_start];
    }
    if (s.len > 0 and s[s.len - 1] == '\n') {
        s = s[0 .. s.len - 1];
        if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    }
    return s;
}

/// The disown-mode executable invariant, all three parts (see the section
/// comment above). Protected spans are compared at their structural bounds
/// (`structuralSpan`): interior bytes are pinned exactly; only separator
/// bytes the splice owns may differ.
pub fn verifyDisownInvariant(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    candidate: []const u8,
    disown_paths: []const OwnPath,
    composed_text: []const u8,
    composed_doc: *const OwnedDoc,
    diag: ?*Diag,
) VerifyError!void {
    const cand_doc = OwnedDoc.parse(arena, format, candidate) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => return error.CandidateUnparseable,
    };

    // (a) Everything outside the disowned subtrees equals the composed
    // document.
    const cand_pruned = try withoutSubtrees(arena, &cand_doc, disown_paths);
    const composed_pruned = try withoutSubtrees(arena, composed_doc, disown_paths);
    if (!anyValueEql(cand_pruned.root, composed_pruned.root)) {
        diagSet(diag, "candidate owned content does not match the composed document", .{});
        return error.OwnedContentMismatch;
    }

    // (b) Each disowned span survives byte-identically live -> candidate.
    const live_loc = if (live.len == 0)
        FullLocated{ .spans = try arena.alloc(?Span, disown_paths.len), .forms = try arena.alloc(Form, disown_paths.len), .wrappers = &.{} }
    else
        try locateFull(arena, format, live, disown_paths, diag);
    if (live.len == 0) @memset(live_loc.spans, null);
    const cand_loc = locateFull(arena, format, candidate, disown_paths, diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LiveUnparseable => return error.CandidateUnparseable,
        else => return e,
    };
    for (disown_paths, live_loc.spans, cand_loc.spans) |p, lsp, csp| {
        if ((lsp == null) != (csp == null)) {
            diagSet(diag, "{s}: disowned content was gained or lost", .{p.raw});
            return error.RemainderMismatch;
        }
        const l = lsp orelse continue;
        const c = csp.?;
        const lb = structuralSpan(format, live[l.start..l.end]);
        const cb = structuralSpan(format, candidate[c.start..c.end]);
        if (!std.mem.eql(u8, lb, cb)) {
            diagSet(diag, "{s}: disowned content was not preserved byte-for-byte", .{p.raw});
            return error.RemainderMismatch;
        }
    }

    // (c) The candidate minus the disowned spans is the composed text. The
    // splice owns its separator bytes (a suffix run's dangling comma, an
    // emptied member line, blank separation), so the remainder is also
    // accepted with those absorbed -- the same cut the extraction makes.
    const rest = try remainderBytes(arena, candidate, cand_loc);
    if (std.mem.eql(u8, rest, composed_text)) return;
    const tidied = try textWithoutSpans(arena, format, candidate, .{
        .spans = cand_loc.spans,
        .wrappers = cand_loc.wrappers,
    });
    if (std.mem.eql(u8, tidied, composed_text)) return;
    if (composed_text.len > 0 and composed_text[composed_text.len - 1] != '\n' and
        try separatorAttributedMatch(arena, candidate, cand_loc, composed_text)) return;
    diagSet(diag, "candidate changed bytes outside the disowned spans", .{});
    return error.RemainderMismatch;
}

const testing = std.testing;
const keypath = @import("../source/keypath.zig");

fn testOwn(arena: std.mem.Allocator, raws: []const []const u8) ![]OwnPath {
    const out = try arena.alloc(OwnPath, raws.len);
    for (raws, out) |raw, *o| o.* = .{ .raw = raw, .segments = try keypath.parse(arena, raw) };
    return out;
}

/// Run the full pipeline and prove the invariant on the result.
fn testApply(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    raws: []const []const u8,
    owned_text: []const u8,
) ![]u8 {
    const paths = try testOwn(arena, raws);
    const owned = try OwnedDoc.parse(arena, format, owned_text);
    var diag: Diag = .{};
    const cand = replaceOwned(arena, format, live, paths, &owned, &diag) catch |e| {
        std.debug.print("replace failed: {s} ({t})\n", .{ diag.text(), e });
        return e;
    };
    verifyInvariant(arena, format, live, cand, paths, &owned, &diag) catch |e| {
        std.debug.print("verify failed: {s} ({t})\ncandidate:\n{s}\n", .{ diag.text(), e, cand });
        return e;
    };
    return cand;
}

fn testLocateError(
    format: Format,
    live: []const u8,
    raws: []const []const u8,
    expected: anyerror,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try testOwn(arena, raws);
    var diag: Diag = .{};
    try testing.expectError(expected, locateSpans(arena, format, live, paths, &diag));
    try testing.expect(diag.len > 0);
}

test "toml: header table replace covers sub-tables and preserves the remainder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\# codex config
        \\model = "gpt"
        \\
        \\[tui.keymap.global]
        \\old = "x"
        \\
        \\[tui.keymap.global.sub]
        \\y = 2
        \\
        \\[profiles.fast]
        \\speed = 1
        \\
    ;
    const owned_text =
        \\[tui.keymap.global]
        \\open_transcript = "ctrl-shift-t"
        \\
        \\[tui.keymap.global.sub]
        \\x = 1
        \\
    ;
    const cand = try testApply(arena, .toml, live, &.{"tui.keymap.global"}, owned_text);
    const expected =
        \\# codex config
        \\model = "gpt"
        \\
        \\[tui.keymap.global]
        \\open_transcript = "ctrl-shift-t"
        \\
        \\[tui.keymap.global.sub]
        \\x = 1
        \\
        \\[profiles.fast]
        \\speed = 1
        \\
    ;
    try testing.expectEqualStrings(expected, cand);
}

test "toml: comment run trailing the preceding table survives byte-for-byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\[keep]
        \\x = 1
        \\# trailing note
        \\
        \\[tui.keymap.global]
        \\a = 1
        \\
    ;
    const cand = try testApply(arena, .toml, live, &.{"tui.keymap.global"}, "[tui.keymap.global]\na = 2\n");
    const expected =
        \\[keep]
        \\x = 1
        \\# trailing note
        \\
        \\[tui.keymap.global]
        \\a = 2
        \\
    ;
    try testing.expectEqualStrings(expected, cand);
}

test "toml: nested quoted path addresses its header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\[projects."/tmp/example"]
        \\status = "old"
        \\
        \\[other]
        \\z = 1
        \\
    ;
    const cand = try testApply(
        arena,
        .toml,
        live,
        &.{"projects.\"/tmp/example\""},
        "[projects.\"/tmp/example\"]\nstatus = \"new\"\n",
    );
    const expected =
        \\[projects."/tmp/example"]
        \\status = "new"
        \\
        \\[other]
        \\z = 1
        \\
    ;
    try testing.expectEqualStrings(expected, cand);
}

test "toml: enforced absence removes the live span" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\[keep]
        \\x = 1
        \\
        \\[tui.keymap.global]
        \\a = 1
        \\
    ;
    const cand = try testApply(arena, .toml, live, &.{"tui.keymap.global"}, "");
    try testing.expectEqualStrings("[keep]\nx = 1\n\n", cand);
}

test "toml: append to an existing file and to empty text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const owned_text = "[tui.keymap.global]\nsubmit = \"enter\"\n";

    const cand = try testApply(arena, .toml, "model = \"gpt\"\n", &.{"tui.keymap.global"}, owned_text);
    try testing.expectEqualStrings("model = \"gpt\"\n[tui.keymap.global]\nsubmit = \"enter\"\n", cand);

    const from_empty = try testApply(arena, .toml, "", &.{"tui.keymap.global"}, owned_text);
    try testing.expectEqualStrings("[tui.keymap.global]\nsubmit = \"enter\"\n", from_empty);
}

test "toml: leaf key replace and append in kv form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const replaced = try testApply(
        arena,
        .toml,
        "model = \"old\"\n\n[tables]\nx = 1\n",
        &.{"model"},
        "model = \"new\"\n",
    );
    try testing.expectEqualStrings("model = \"new\"\n\n[tables]\nx = 1\n", replaced);

    const appended = try testApply(
        arena,
        .toml,
        "[tui]\ntheme = \"dark\"\n\n[zz]\nq = 1\n",
        &.{"tui.model"},
        "[tui]\nmodel = \"opus\"\n",
    );
    try testing.expectEqualStrings("[tui]\ntheme = \"dark\"\nmodel = \"opus\"\n\n[zz]\nq = 1\n", appended);
}

test "toml: a live file with no final newline keeps its remainder byte-exact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The unowned tail ends without a final newline; a reassert of the owned
    // table must not normalize it.
    const live = "[tui]\na = 1\n\n[program]\nstate = 1";
    const cand = try testApply(arena, .toml, live, &.{"tui"}, "[tui]\na = 2\n");
    try testing.expectEqualStrings("[tui]\na = 2\n\n[program]\nstate = 1", cand);
}

test "toml: an append after non-newline-terminated live content owns its separator newline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cand = try testApply(arena, .toml, "state = 1", &.{"tui"}, "[tui]\na = 1\n");
    try testing.expectEqualStrings("state = 1\n[tui]\na = 1\n", cand);
}

test "toml: a trailing comment run between an owned table and the next header is remainder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\[tui]
        \\a = 1
        \\
        \\# program comment
        \\[profiles.fast]
        \\speed = 1
        \\
    ;
    const replaced = try testApply(arena, .toml, live, &.{"tui"}, "[tui]\na = 2\n");
    const expected =
        \\[tui]
        \\a = 2
        \\
        \\# program comment
        \\[profiles.fast]
        \\speed = 1
        \\
    ;
    try testing.expectEqualStrings(expected, replaced);

    const removed = try testApply(arena, .toml, live, &.{"tui"}, "");
    try testing.expectEqualStrings("\n# program comment\n[profiles.fast]\nspeed = 1\n", removed);
}

test "toml: dotted-key spelling of a declared table is refused" {
    try testLocateError(.toml, "[tui]\nkeymap.global.x = 1\n", &.{"tui.keymap.global"}, error.OwnedPathDottedSpelling);
}

test "toml: a table split across disjoint regions is refused" {
    const live =
        \\[tui.keymap.global]
        \\a = 1
        \\
        \\[other]
        \\b = 1
        \\
        \\[tui.keymap.global.sub]
        \\c = 1
        \\
    ;
    try testLocateError(.toml, live, &.{"tui.keymap.global"}, error.OwnedPathDuplicate);
}

test "toml: a path inside an inline table value is refused" {
    try testLocateError(.toml, "tui = { keymap = { global = 1 } }\n", &.{"tui.keymap.global"}, error.OwnedPathUnaddressable);
}

test "overlapping declared paths are refused" {
    try testLocateError(.toml, "", &.{ "a", "a.b" }, error.OwnedPathDuplicate);
}

test "json: comma correctness at first, middle, and last member removals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live = "{\"a\": 1, \"b\": 2, \"c\": 3}";

    const no_first = try testApply(arena, .json, live, &.{"a"}, "{}");
    try testing.expectEqualStrings("{\"b\": 2, \"c\": 3}", no_first);

    const no_middle = try testApply(arena, .json, live, &.{"b"}, "{}");
    try testing.expectEqualStrings("{\"a\": 1, \"c\": 3}", no_middle);

    const no_last = try testApply(arena, .json, live, &.{"c"}, "{}");
    try testing.expectEqualStrings("{\"a\": 1, \"b\": 2}", no_last);
}

test "json: replace, nested member, append, and creation from empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const replaced = try testApply(arena, .json, "{\"a\": 1, \"b\": 2}", &.{"b"}, "{\"b\": 9}");
    try testing.expectEqualStrings("{\"a\": 1, \"b\": 9}", replaced);

    const nested = try testApply(
        arena,
        .json,
        "{\"editor\": {\"fontSize\": 12, \"theme\": \"d\"}, \"x\": 0}",
        &.{"editor.fontSize"},
        "{\"editor\": {\"fontSize\": 14}}",
    );
    try testing.expectEqualStrings("{\"editor\": {\"fontSize\": 14, \"theme\": \"d\"}, \"x\": 0}", nested);

    const appended = try testApply(arena, .json, "{\"a\": 1}", &.{"model"}, "{\"model\": \"opus\"}");
    try testing.expectEqualStrings("{\"a\": 1, \"model\": \"opus\"}", appended);

    const created = try testApply(arena, .json, "", &.{ "model", "z" }, "{\"model\": \"opus\", \"z\": 1}");
    try testing.expectEqualStrings("{\"model\": \"opus\", \"z\": 1}", created);
}

test "json: removing a non-last member keeps a standalone comment between members" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\{
        \\  "a": 1,
        \\  "gone": 1,
        \\  // program comment
        \\  "c": 3
        \\}
    ;
    const cand = try testApply(arena, .json, live, &.{"gone"}, "{}");
    try testing.expect(std.mem.indexOf(u8, cand, "// program comment") != null);
    try testing.expect(std.mem.indexOf(u8, cand, "\"gone\"") == null);
}

test "json: a duplicate key on the declared path is refused" {
    try testLocateError(.json, "{\"a\": 1, \"a\": 2}", &.{"a"}, error.OwnedPathDuplicate);
}

test "yaml: block mapping replace preserves siblings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\program: state
        \\tui:
        \\  keymap:
        \\    old: 1
        \\next: 2
        \\
    ;
    const owned_text =
        \\tui:
        \\  keymap:
        \\    submit: enter
        \\
    ;
    const cand = try testApply(arena, .yaml, live, &.{"tui"}, owned_text);
    const expected =
        \\program: state
        \\tui:
        \\  keymap:
        \\    submit: enter
        \\next: 2
        \\
    ;
    try testing.expectEqualStrings(expected, cand);
}

test "yaml: append into an existing mapping and creation from empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const appended = try testApply(
        arena,
        .yaml,
        "top: a\nsec:\n  k: v\n",
        &.{"sec.newkey"},
        "sec:\n  newkey: val\n",
    );
    try testing.expectEqualStrings("top: a\nsec:\n  k: v\n  newkey: val\n", appended);

    const created = try testApply(arena, .yaml, "", &.{"a.b"}, "a:\n  b: 1\n");
    try testing.expectEqualStrings("a:\n  b: 1\n", created);
}

test "yaml: enforced absence removes the sole-member chain, not just the leaf" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cand = try testApply(arena, .yaml, "a:\n  b: 1\nz: 2\n", &.{"a.b"}, "");
    try testing.expectEqualStrings("z: 2\n", cand);
}

test "yaml: anchors, aliases, merge keys, and non-string keys are refused" {
    try testLocateError(.yaml, "tui: &t\n  a: 1\n", &.{"tui"}, error.OwnedPathAliased);
    try testLocateError(.yaml, "base: &b 1\ntui:\n  key: *b\n", &.{"tui"}, error.OwnedPathAliased);
    try testLocateError(
        .yaml,
        "defaults: &d\n  keymap: x\ntui:\n  <<: *d\n",
        &.{"tui.keymap"},
        error.OwnedPathMergeKey,
    );
    try testLocateError(.yaml, "tui:\n  1: x\n", &.{"tui.1"}, error.OwnedPathNonStringKey);
}

test "ini: section match is case-insensitive under the dialect" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\[Colors]
        \\FG = red
        \\other = x
        \\
        \\[Keep]
        \\k = 1
        \\
    ;
    const cand = try testApply(arena, .ini, live, &.{"colors"}, "[colors]\nfg = blue\n");
    const expected =
        \\[colors]
        \\fg = blue
        \\
        \\[Keep]
        \\k = 1
        \\
    ;
    try testing.expectEqualStrings(expected, cand);
}

test "ini: a section appearing in disjoint regions is refused" {
    try testLocateError(
        .gitconfig,
        "[user]\na = 1\n[core]\nx = 1\n[user]\nb = 2\n",
        &.{"user"},
        error.OwnedPathDuplicate,
    );
}

test "gitconfig: quoted subsection replace, case-sensitive subsection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live = "[core]\n\teditor = vim\n[remote \"my origin\"]\n\turl = old\n" ++
        "[branch \"main\"]\n\tremote = my origin\n";
    const owned_text = "[remote \"my origin\"]\nurl = new\nfetch = +refs/heads/*\n";
    const cand = try testApply(arena, .gitconfig, live, &.{"remote.\"my origin\""}, owned_text);
    const expected = "[core]\n\teditor = vim\n[remote \"my origin\"]\nurl = new\n" ++
        "fetch = +refs/heads/*\n[branch \"main\"]\n\tremote = my origin\n";
    try testing.expectEqualStrings(expected, cand);

    // A differently-cased subsection is a different section: no span, so
    // the owned block appends instead of replacing.
    const paths = try testOwn(arena, &.{"remote.\"My Origin\""});
    var diag: Diag = .{};
    const loc = try locateSpans(arena, .gitconfig, live, paths, &diag);
    try testing.expect(loc.spans[0] == null);
}

test "gitconfig: key entry replace and multi-value append" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const replaced = try testApply(
        arena,
        .gitconfig,
        "[user]\n\temail = old@example.com\n\tname = Some One\n",
        &.{"user.email"},
        "[user]\nemail = new@example.com\n",
    );
    try testing.expectEqualStrings(
        "[user]\nemail = new@example.com\n\tname = Some One\n",
        replaced,
    );

    const appended = try testApply(
        arena,
        .gitconfig,
        "[core]\n\teditor = vim\n",
        &.{"my-tool.path"},
        "[my-tool]\npath = a\npath = b\n",
    );
    try testing.expectEqualStrings(
        "[core]\n\teditor = vim\n[my-tool]\npath = a\npath = b\n",
        appended,
    );
}

test "verifier: a corrupted remainder and a wrong owned value both fail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\[keep]
        \\x = 1
        \\
        \\[tui.keymap.global]
        \\a = 1
        \\
    ;
    const owned_text = "[tui.keymap.global]\na = 2\n";
    const paths = try testOwn(arena, &.{"tui.keymap.global"});
    const owned = try OwnedDoc.parse(arena, .toml, owned_text);
    const good = try replaceOwned(arena, .toml, live, paths, &owned, null);
    try verifyInvariant(arena, .toml, live, good, paths, &owned, null);

    const bad_rest = try std.mem.replaceOwned(u8, arena, good, "[keep]", "[kept]");
    var diag: Diag = .{};
    try testing.expectError(
        error.RemainderMismatch,
        verifyInvariant(arena, .toml, live, bad_rest, paths, &owned, &diag),
    );

    const bad_owned = try std.mem.replaceOwned(u8, arena, good, "a = 2", "a = 3");
    try testing.expectError(
        error.OwnedContentMismatch,
        verifyInvariant(arena, .toml, live, bad_owned, paths, &owned, &diag),
    );
}

test "verifier: every replaced format reparses cleanly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Each testApply above already verifies; this pins the reparse of a
    // mixed replace+remove+append in one file per format family.
    const cand = try testApply(
        arena,
        .toml,
        "[a]\nx = 1\n\n[gone]\ny = 2\n\n[keep]\nz = 3\n",
        &.{ "a", "gone", "fresh" },
        "[a]\nx = 9\n\n[fresh]\nn = 1\n",
    );
    const reparsed = try toml.parse(arena, cand, .{});
    try testing.expect(reparsed.get("keep.z") != null);
    try testing.expect(reparsed.get("gone") == null);
    try testing.expect(reparsed.get("fresh.n") != null);
}

test "yaml: a flow-style mapping on the path is refused, a flow value is replaceable" {
    try testLocateError(.yaml, "tui: {a: 1}\n", &.{"tui.a"}, error.OwnedPathUnaddressable);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cand = try testApply(arena, .yaml, "x: 1\ntui: {a: 1}\n", &.{"tui"}, "tui:\n  a: 2\n");
    try testing.expectEqualStrings("x: 1\ntui:\n  a: 2\n", cand);
}

test "ini: key entry appends into its existing section" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cand = try testApply(
        arena,
        .ini,
        "[colors]\nfg = red\n\n[keep]\nk = 1\n",
        &.{"colors.bg"},
        "[colors]\nbg = blue\n",
    );
    try testing.expectEqualStrings("[colors]\nfg = red\nbg = blue\n\n[keep]\nk = 1\n", cand);
}

test "gitconfig: an entry on a section header line is refused" {
    try testLocateError(.gitconfig, "[alias] st = status\n", &.{"alias.st"}, error.OwnedPathUnaddressable);
}

test "undeclaredLeaf: names a leaf outside the declaration, passes a covered doc" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try testOwn(arena, &.{"tui.keymap.global"});

    const covered = try OwnedDoc.parse(arena, .toml, "[tui.keymap.global]\na = 1\n");
    try testing.expect(try undeclaredLeaf(arena, &covered, paths) == null);

    // An intermediate table implied by the header is traversal; the stray
    // leaf beside the owned one is the violation.
    const stray = try OwnedDoc.parse(arena, .toml, "[tui.keymap.global]\na = 1\n\n[tui.other]\nb = 2\n");
    try testing.expectEqualStrings("tui.other.b", (try undeclaredLeaf(arena, &stray, paths)).?);

    // An empty composed document defines nothing.
    const empty = try OwnedDoc.parse(arena, .toml, "");
    try testing.expect(try undeclaredLeaf(arena, &empty, paths) == null);
}

test "undeclaredLeaf: ini declarations match with the dialect's case rules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Generic ini: sections and keys fold, so a differently-cased declared
    // section still covers the composed content.
    const doc = try OwnedDoc.parse(arena, .ini, "[colors]\nfg = blue\n");
    try testing.expect(try undeclaredLeaf(arena, &doc, try testOwn(arena, &.{"COLORS"})) == null);

    // gitconfig: keys fold, subsections are verbatim.
    const git = try OwnedDoc.parse(arena, .gitconfig, "[remote \"Origin\"]\nurl = x\n");
    try testing.expect(try undeclaredLeaf(arena, &git, try testOwn(arena, &.{"REMOTE.\"Origin\".URL"})) == null);
    const wrong_sub = try testOwn(arena, &.{"remote.\"origin\""});
    try testing.expectEqualStrings("remote.Origin.url", (try undeclaredLeaf(arena, &git, wrong_sub)).?);
}

test "maskSecretPaths: masks every leaf value under the path, keeps the rest byte-for-byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\# program comment
        \\keep = "visible"
        \\
        \\[api]
        \\token = "cleartext"
        \\
    ;
    const paths = try testOwn(arena, &.{"api"});
    const masked = try maskSecretPaths(arena, .toml, live, paths);
    try testing.expect(std.mem.indexOf(u8, masked, "cleartext") == null);
    try testing.expect(std.mem.indexOf(u8, masked, secret_mask) != null);
    try testing.expect(std.mem.indexOf(u8, masked, "# program comment") != null);
    try testing.expect(std.mem.indexOf(u8, masked, "keep = \"visible\"") != null);
}

fn testExtract(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    raws: []const []const u8,
) ![]u8 {
    const paths = try testOwn(arena, raws);
    var diag: Diag = .{};
    return extractOwnedSource(arena, format, live, paths, &diag) catch |e| {
        std.debug.print("extract failed: {s} ({t})\n", .{ diag.text(), e });
        return e;
    };
}

test "extract toml: block spans keep comments verbatim, root kv precedes blocks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live =
        \\model = "opus"
        \\
        \\[tui.keymap.global]
        \\# user note on submit
        \\submit = "enter"
        \\
        \\[program]
        \\state = 1
        \\
    ;
    // `model` is declared after the table; it still extracts before any
    // header so the result parses with `model` at the root.
    const got = try testExtract(arena, .toml, live, &.{ "tui.keymap.global", "model" });
    const expected =
        \\model = "opus"
        \\[tui.keymap.global]
        \\# user note on submit
        \\submit = "enter"
        \\
    ;
    try testing.expectEqualStrings(expected, got);
    const doc = try OwnedDoc.parse(arena, .toml, got);
    try testing.expect(try undeclaredLeaf(arena, &doc, try testOwn(arena, &.{ "tui.keymap.global", "model" })) == null);
}

test "extract toml: a nested kv leaf gains its parent header, siblings share it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live = "[tui]\ntheme = \"dark\"\nmodel = \"opus\" # keep\nfont = 12\n";
    const got = try testExtract(arena, .toml, live, &.{ "tui.model", "tui.font" });
    try testing.expectEqualStrings("[tui]\nmodel = \"opus\" # keep\nfont = 12\n", got);
}

test "extract toml: a declared path absent from live is an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try testOwn(arena, &.{"missing"});
    var diag: Diag = .{};
    try testing.expectError(
        error.OwnedPathMissing,
        extractOwnedSource(arena, .toml, "present = 1\n", paths, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.text(), "--own-absent") != null);
}

test "extract json: root and nested members reassemble into one parsing object" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live = "{\"model\": \"opus\", \"editor\": {\"fontSize\": 12, \"theme\": \"d\"}, \"x\": 0}";
    const got = try testExtract(arena, .json, live, &.{ "model", "editor.fontSize" });
    const doc = try OwnedDoc.parse(arena, .json, got);
    const paths = try testOwn(arena, &.{ "model", "editor.fontSize" });
    try testing.expect(try undeclaredLeaf(arena, &doc, paths) == null);
    const model = doc.subtreeAt(&.{"model"}).?;
    try testing.expectEqualStrings("opus", model.json.string);
    const size = doc.subtreeAt(&.{ "editor", "fontSize" }).?;
    try testing.expectEqual(@as(i64, 12), size.json.integer);
}

test "extract yaml: raw member lines reassemble under generated ancestors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live = "top: a\nsec:\n  keep: v # note\n  other: 1\n";
    const got = try testExtract(arena, .yaml, live, &.{ "sec.keep", "top" });
    const doc = try OwnedDoc.parse(arena, .yaml, got);
    const keep = doc.subtreeAt(&.{ "sec", "keep" }).?;
    try testing.expectEqualStrings("v", keep.yaml.string);
    const top = doc.subtreeAt(&.{"top"}).?;
    try testing.expectEqualStrings("a", top.yaml.string);
    try testing.expect(std.mem.indexOf(u8, got, "# note") != null);
}

test "extract ini: section block verbatim, key entry gains its section header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live = "[colors]\n; keep this\nfg = red\n\n[user]\nname = me\nmail = m@x\n";
    const got = try testExtract(arena, .ini, live, &.{ "colors", "user.name" });
    try testing.expectEqualStrings("[colors]\n; keep this\nfg = red\n\n[user]\nname = me\n", got);
}

test "unownedTopLevelCount: counts entries with no ownership relation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc = try OwnedDoc.parse(arena, .toml, "model = 1\n\n[tui.keymap]\nk = 1\n\n[hooks]\nh = 1\n");
    const paths = try testOwn(arena, &.{"tui.keymap.global"});
    // `tui` is an ancestor of the declared path; `model` and `hooks` are not.
    try testing.expectEqual(@as(usize, 2), unownedTopLevelCount(&doc, paths));
}

test "ownedHasSecretMask: sees the mask under a declared path only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const masked = try OwnedDoc.parse(
        arena,
        .toml,
        "outside = \"<mox:secret>\"\n\n[api]\ntoken = \"<mox:secret>\"\n",
    );
    const clean = try OwnedDoc.parse(arena, .toml, "[api]\ntoken = \"real\"\n");
    const paths = try testOwn(arena, &.{"api"});
    try testing.expect(ownedHasSecretMask(&masked, paths));
    try testing.expect(!ownedHasSecretMask(&clean, paths));
    const other = try testOwn(arena, &.{"ui"});
    try testing.expect(!ownedHasSecretMask(&masked, other));
}

test "secretPathFlags: a secret line inside one owned table flags exactly that path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const composed =
        \\[plain]
        \\x = "v"
        \\
        \\[api]
        \\token = "resolved-secret"
        \\
    ;
    const paths = try testOwn(arena, &.{ "plain", "api" });
    // Line 4 (0-based) is `token = ...`, marked secret by compose.
    const segments = [_]provmap.Segment{
        .{ .out_start = 0, .out_len = 4, .origin = .{ .base = .{ .line = 1 } } },
        .{ .out_start = 4, .out_len = 1, .origin = .secret },
    };
    const flags = try secretPathFlags(arena, .toml, composed, paths, &segments, null);
    try testing.expect(!flags[0]);
    try testing.expect(flags[1]);

    // No secret segment: nothing flagged, no locate work needed.
    const none = [_]provmap.Segment{
        .{ .out_start = 0, .out_len = 5, .origin = .{ .base = .{ .line = 1 } } },
    };
    const clean = try secretPathFlags(arena, .toml, composed, paths, &none, null);
    try testing.expect(!clean[0] and !clean[1]);
}

// Disown-mode tests

fn testDisown(
    arena: std.mem.Allocator,
    format: Format,
    live: []const u8,
    raws: []const []const u8,
    composed_text: []const u8,
) ![]u8 {
    const paths = try testOwn(arena, raws);
    const composed_doc = try OwnedDoc.parse(arena, format, composed_text);
    var diag: Diag = .{};
    const cand = replaceDisowned(arena, format, live, paths, composed_text, &diag) catch |e| {
        std.debug.print("disown replace failed: {s} ({t})\n", .{ diag.text(), e });
        return e;
    };
    verifyDisownInvariant(arena, format, live, cand, paths, composed_text, &composed_doc, &diag) catch |e| {
        std.debug.print("disown verify failed: {s} ({t})\ncandidate:\n{s}\n", .{ diag.text(), e, cand });
        return e;
    };
    return cand;
}

test "disown json: the program's member survives byte-for-byte around reasserted content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const composed = "{\n  \"theme\": \"dark\",\n  \"editor\": \"nvim\"\n}\n";
    const live = "{\n  \"theme\": \"old\",\n  \"model\": \"test-model-4.1\"\n}\n";
    const cand = try testDisown(arena, .json, live, &.{"model"}, composed);
    try testing.expectEqualStrings(
        "{\n  \"theme\": \"dark\",\n  \"editor\": \"nvim\",\n  \"model\": \"test-model-4.1\"\n}\n",
        cand,
    );
}

test "disown json: a missing live file yields exactly the composed text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const composed = "{\n  \"theme\": \"dark\"\n}\n";
    const cand = try testDisown(arena, .json, "", &.{"model"}, composed);
    try testing.expectEqualStrings(composed, cand);
}

test "disown toml: block and nested kv insertions, comments in the span preserved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const composed = "[user]\nname = \"me\"\n";
    const live = "[user]\nname = \"old\"\n\n[state]\n# program note\ncount = 42\n";
    // The blank separator line before [state] was live remainder, not span
    // content, so the appended block sits directly after the composed text.
    const cand = try testDisown(arena, .toml, live, &.{"state"}, composed);
    try testing.expectEqualStrings("[user]\nname = \"me\"\n[state]\n# program note\ncount = 42\n", cand);

    // A disowned kv whose parent section exists in the composed text joins it.
    const cand2 = try testDisown(arena, .toml, "[user]\nname = \"old\"\nseen = 9\n", &.{"user.seen"}, composed);
    try testing.expectEqualStrings("[user]\nname = \"me\"\nseen = 9\n", cand2);
}

test "disown ini: the program's section is appended and matched case-insensitively" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const composed = "[colors]\nfg = red\n";
    const live = "[colors]\nfg = blue\n[STATE]\ncount = 1\n";
    const cand = try testDisown(arena, .ini, live, &.{"state"}, composed);
    try testing.expectEqualStrings("[colors]\nfg = red\n[STATE]\ncount = 1\n", cand);
}

test "disown yaml: a top-level live member is appended after the composed mapping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const composed = "theme: dark\n";
    const live = "theme: old\nstate:\n  count: 1\n";
    const cand = try testDisown(arena, .yaml, live, &.{"state"}, composed);
    try testing.expectEqualStrings("theme: dark\nstate:\n  count: 1\n", cand);
}

test "disown verify: a smuggled owned byte and a mutated protected span both fail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try testOwn(arena, &.{"state"});
    const composed = "[user]\nname = \"me\"\n";
    const composed_doc = try OwnedDoc.parse(arena, .toml, composed);
    const live = "[user]\nname = \"me\"\n\n[state]\ncount = 42\n";
    var diag: Diag = .{};

    // Owned content beyond the composed document.
    try testing.expectError(error.OwnedContentMismatch, verifyDisownInvariant(
        arena,
        .toml,
        live,
        "[user]\nname = \"me\"\nextra = 1\n\n[state]\ncount = 42\n",
        paths,
        composed,
        &composed_doc,
        &diag,
    ));
    // A protected span that changed between live and candidate.
    try testing.expectError(error.RemainderMismatch, verifyDisownInvariant(
        arena,
        .toml,
        live,
        "[user]\nname = \"me\"\n\n[state]\ncount = 43\n",
        paths,
        composed,
        &composed_doc,
        &diag,
    ));
}

test "disown D2: a composed document populating a disowned path is named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try testOwn(arena, &.{"model"});
    const doc = try OwnedDoc.parse(arena, .json, "{\"model\": \"x\", \"theme\": \"dark\"}");
    try testing.expectEqualStrings("model", (try populatedDisownPath(arena, &doc, paths)).?);
    const clean = try OwnedDoc.parse(arena, .json, "{\"theme\": \"dark\"}");
    try testing.expect(try populatedDisownPath(arena, &clean, paths) == null);
}

test "withoutSubtrees: removes declared subtrees and prunes emptied framing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc = try OwnedDoc.parse(arena, .toml, "[a]\nb = 1\n\n[keep]\nk = 1\n\n[empty]\n");
    const pruned = try withoutSubtrees(arena, &doc, try testOwn(arena, &.{"a.b"}));
    // a lost its only entry to the removal: pure framing, pruned with it.
    try testing.expect(pruned.root.toml.table.get("a") == null);
    try testing.expect(pruned.root.toml.table.get("keep") != null);
    // A container that was ALREADY empty is content, not framing.
    try testing.expect(pruned.root.toml.table.get("empty") != null);
}
