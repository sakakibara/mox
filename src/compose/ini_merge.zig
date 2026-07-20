//! Section-merge for gitconfig and INI files.
//!
//! The merge is a raw-line rewrite of the base: overlay entries are spliced
//! into the output as the exact bytes the user wrote in the overlay file, and
//! base lines that are not replaced pass through verbatim. No value is ever
//! unescaped and re-escaped, so comments, quoting, spacing, and bare-key
//! semantics survive on both sides.
//!
//! Semantics (spec: "append-and-override-by-key"):
//! - Sections are identified by case-folded name plus verbatim subsection.
//! - An overlay key replaces ALL base instances of that key in the section,
//!   at the position of the first instance. A multi-valued overlay key
//!   contributes all of its lines there.
//! - Overlay keys absent from the base are appended at the end of the base's
//!   section body (before the blank lines separating the next section).
//! - Overlay sections absent from the base are appended at end of file.
//!
//! ini-zig's tokenizer does the line classification (continuation-, quote-,
//! and comment-aware), so logical lines are moved whole.

const std = @import("std");
const ini = @import("ini");

const Tokenizer = ini.Tokenizer;

pub const Dialect = enum {
    gitconfig,
    generic,

    fn toIni(self: Dialect) ini.Dialect {
        return switch (self) {
            .gitconfig => .gitconfig,
            .generic => .generic,
        };
    }
};

/// Merge `overlay_src` onto `base_src`. Returned bytes are arena-owned.
pub fn merge(arena: std.mem.Allocator, base_src: []const u8, overlay_src: []const u8, dialect: Dialect) ![]u8 {
    const d = dialect.toIni();
    var overlay = try scan(arena, overlay_src, d);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    // Blank lines are held back so section-end insertions land before the
    // whitespace that separates the next section.
    var held_blanks: std.ArrayList(u8) = .empty;
    defer held_blanks.deinit(arena);

    var current: ?*OverlaySection = overlay.find(root_ident);
    if (current) |s| s.seen_in_base = true;

    var toks = Tokenizer.init(base_src, d);
    var skipping_continuation = false;
    while (toks.next()) |tok| {
        const line = lineWithEol(base_src, tok);
        switch (tok.kind) {
            .continuation => {
                if (!skipping_continuation) try out.appendSlice(arena, line);
                continue;
            },
            .blank => {
                skipping_continuation = false;
                try held_blanks.appendSlice(arena, line);
                continue;
            },
            .comment => {
                skipping_continuation = false;
                try flushBlanks(arena, &out, &held_blanks);
                try out.appendSlice(arena, line);
                continue;
            },
            .section_header => {
                skipping_continuation = false;
                if (current) |s| try emitUnconsumed(arena, &out, s);
                try flushBlanks(arena, &out, &held_blanks);
                const ident = sectionIdent(arena, line) catch |e| switch (e) {
                    error.MalformedHeader => {
                        // Not something we can match against; pass through and
                        // stop attributing keys to any overlay section.
                        try out.appendSlice(arena, line);
                        current = null;
                        continue;
                    },
                    else => return e,
                };
                current = overlay.find(ident);
                if (current) |s| s.seen_in_base = true;
                try out.appendSlice(arena, line);
                continue;
            },
            .key_value => {
                skipping_continuation = false;
                const key = try keyOf(arena, line, d);
                if (current) |s| {
                    if (s.findEntry(key)) |entry| {
                        skipping_continuation = true;
                        if (!entry.consumed) {
                            entry.consumed = true;
                            try flushBlanks(arena, &out, &held_blanks);
                            try appendEntryLines(arena, &out, entry.raw.items);
                        }
                        continue;
                    }
                }
                try flushBlanks(arena, &out, &held_blanks);
                try out.appendSlice(arena, line);
                continue;
            },
        }
    }
    if (current) |s| try emitUnconsumed(arena, &out, s);
    try flushBlanks(arena, &out, &held_blanks);

    // Whole sections the base never opened, in overlay order. A section with no
    // entries adds nothing (an empty `[gpg]` is not emitted), and the blank-line
    // separator is added only when the output does not already end in one.
    for (overlay.sections.items) |*s| {
        if (s.seen_in_base) continue;
        if (s.entries.items.len == 0) continue;
        try ensureTrailingNewline(arena, &out);
        const ends_blank = out.items.len >= 2 and
            out.items[out.items.len - 1] == '\n' and out.items[out.items.len - 2] == '\n';
        if (out.items.len > 0 and !ends_blank) try out.append(arena, '\n');
        try out.appendSlice(arena, s.header);
        try ensureTrailingNewline(arena, &out);
        try emitUnconsumed(arena, &out, s);
    }

    return out.toOwnedSlice(arena);
}

const root_ident: []const u8 = "";

const OverlayEntry = struct {
    key: []const u8,
    raw: std.ArrayList(u8),
    consumed: bool = false,
};

const OverlaySection = struct {
    ident: []const u8,
    /// Header line exactly as written in the overlay (empty for root).
    header: []const u8,
    entries: std.ArrayList(OverlayEntry),
    seen_in_base: bool = false,

    fn findEntry(self: *OverlaySection, key: []const u8) ?*OverlayEntry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }
};

const Overlay = struct {
    sections: std.ArrayList(OverlaySection),

    fn find(self: *Overlay, ident: []const u8) ?*OverlaySection {
        for (self.sections.items) |*s| {
            if (std.mem.eql(u8, s.ident, ident)) return s;
        }
        return null;
    }

    fn findOrAdd(self: *Overlay, arena: std.mem.Allocator, ident: []const u8, header: []const u8) !*OverlaySection {
        if (self.find(ident)) |s| return s;
        try self.sections.append(arena, .{
            .ident = ident,
            .header = header,
            .entries = .empty,
        });
        return &self.sections.items[self.sections.items.len - 1];
    }
};

/// Collect an overlay's sections and entries with their raw logical lines.
/// Comments and blank lines in the overlay are attached to nothing: an
/// overlay is a set of settings, not a document being preserved (the base
/// carries the document).
fn scan(arena: std.mem.Allocator, src: []const u8, d: ini.Dialect) !Overlay {
    var overlay: Overlay = .{ .sections = .empty };
    var current: *OverlaySection = try overlay.findOrAdd(arena, root_ident, "");

    var toks = Tokenizer.init(src, d);
    var open_entry: ?*OverlayEntry = null;
    while (toks.next()) |tok| {
        const line = lineWithEol(src, tok);
        switch (tok.kind) {
            .blank, .comment => open_entry = null,
            .section_header => {
                open_entry = null;
                const ident = sectionIdent(arena, line) catch |e| switch (e) {
                    error.MalformedHeader => return error.MalformedOverlayHeader,
                    else => return e,
                };
                current = try overlay.findOrAdd(arena, ident, line);
            },
            .key_value => {
                const key = try keyOf(arena, line, d);
                var entry = current.findEntry(key) orelse blk: {
                    try current.entries.append(arena, .{
                        .key = key,
                        .raw = .empty,
                    });
                    break :blk &current.entries.items[current.entries.items.len - 1];
                };
                try entry.raw.appendSlice(arena, line);
                open_entry = entry;
            },
            .continuation => {
                const entry = open_entry orelse return error.DanglingContinuation;
                try entry.raw.appendSlice(arena, line);
            },
        }
    }
    return overlay;
}

/// Section identity: case-folded name, `\x00`, verbatim subsection (when the
/// header has a quoted subsection). Both sides of a merge run through this,
/// so any consistent normalization matches. `[a.b]`-style dotted headers keep
/// the dots in the folded name, which matches git's case-insensitive reading
/// of the legacy form.
fn sectionIdent(arena: std.mem.Allocator, header_line: []const u8) ![]const u8 {
    const line = std.mem.trim(u8, trimEol(header_line), " \t");
    if (line.len < 2 or line[0] != '[') return error.MalformedHeader;
    const close = std.mem.lastIndexOfScalar(u8, line, ']') orelse return error.MalformedHeader;
    const inner = line[1..close];

    var ident: std.ArrayList(u8) = .empty;
    errdefer ident.deinit(arena);

    if (std.mem.indexOfScalar(u8, inner, '"')) |q| {
        const name = std.mem.trim(u8, inner[0..q], " \t");
        const rest = inner[q..];
        for (name) |c| try ident.append(arena, std.ascii.toLower(c));
        try ident.append(arena, 0);
        try ident.appendSlice(arena, std.mem.trim(u8, rest, " \t"));
    } else {
        for (std.mem.trim(u8, inner, " \t")) |c| try ident.append(arena, std.ascii.toLower(c));
    }
    return ident.toOwnedSlice(arena);
}

/// Case-folded key token of a key_value line (bare keys included). Both
/// sides of a merge run through this, so matching is case-insensitive as
/// git and most INI dialects read keys.
fn keyOf(arena: std.mem.Allocator, line: []const u8, d: ini.Dialect) ![]const u8 {
    const content = std.mem.trim(u8, trimEol(line), " \t");
    const end = std.mem.indexOfAny(u8, content, d.assign_chars) orelse content.len;
    const key = std.mem.trimEnd(u8, content[0..end], " \t");
    return std.ascii.allocLowerString(arena, key);
}

fn trimEol(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r\n");
}

/// Token spans cover line content without the terminator; extend to include
/// it so moved lines keep their original endings.
fn lineWithEol(src: []const u8, tok: ini.Token) []const u8 {
    const start: usize = @intCast(tok.span.start);
    var end: usize = @intCast(tok.span.end);
    if (end < src.len and src[end] == '\r') end += 1;
    if (end < src.len and src[end] == '\n') end += 1;
    return src[start..end];
}

fn flushBlanks(arena: std.mem.Allocator, out: *std.ArrayList(u8), held: *std.ArrayList(u8)) !void {
    if (held.items.len == 0) return;
    try out.appendSlice(arena, held.items);
    held.clearRetainingCapacity();
}

fn emitUnconsumed(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: *OverlaySection) !void {
    for (s.entries.items) |*e| {
        if (e.consumed) continue;
        e.consumed = true;
        try ensureTrailingNewline(arena, out);
        try appendEntryLines(arena, out, e.raw.items);
    }
}

fn appendEntryLines(arena: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    try out.appendSlice(arena, raw);
    try ensureTrailingNewline(arena, out);
}

fn ensureTrailingNewline(arena: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(arena, '\n');
    }
}

test "merge: overlay replaces a key in place, comments and order preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base = "# identity\n[user]\n\tname = Ada Lovelace\n\temail = personal@example.com\n\n[push]\n\tdefault = simple\n";
    const overlay = "[user]\n\temail = work@example.com\n";
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings(
        "# identity\n[user]\n\tname = Ada Lovelace\n\temail = work@example.com\n\n[push]\n\tdefault = simple\n",
        merged,
    );
}

test "merge: new key appends at end of the section body, before separator blanks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base = "[user]\n\tname = Ada\n\n[push]\n\tdefault = simple\n";
    const overlay = "[user]\n\tsigningkey = ssh-ed25519 AAAA\n";
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings(
        "[user]\n\tname = Ada\n\tsigningkey = ssh-ed25519 AAAA\n\n[push]\n\tdefault = simple\n",
        merged,
    );
}

test "merge: new section appends at end of file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base = "[user]\n\tname = Ada\n";
    const overlay = "[gpg]\n\tformat = ssh\n";
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings(
        "[user]\n\tname = Ada\n\n[gpg]\n\tformat = ssh\n",
        merged,
    );
}

test "merge: an empty overlay section is not emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base = "[user]\n\tname = Ada\n";
    const overlay = "[gpg]\n"; // header only, no keys -> nothing to add
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings("[user]\n\tname = Ada\n", merged);
}

test "merge: appending a section when the base ends in a blank line adds one separator, not two" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base = "[user]\n\tname = Ada\n\n"; // already ends in a blank line
    const overlay = "[gpg]\n\tformat = ssh\n";
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings(
        "[user]\n\tname = Ada\n\n[gpg]\n\tformat = ssh\n",
        merged,
    );
}

test "merge: overlay key replaces ALL base instances (multi-value collapse)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base = "[credential \"https://github.com\"]\n\thelper =\n\thelper = !gh auth git-credential\n";
    const overlay = "[credential \"https://github.com\"]\n\thelper = osxkeychain\n";
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings(
        "[credential \"https://github.com\"]\n\thelper = osxkeychain\n",
        merged,
    );
}

test "merge: multi-valued overlay key contributes all its lines in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base = "[credential \"https://github.com\"]\n\thelper = osxkeychain\n\tuseHttpPath = true\n";
    const overlay = "[credential \"https://github.com\"]\n\thelper =\n\thelper = !gh auth git-credential\n";
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings(
        "[credential \"https://github.com\"]\n\thelper =\n\thelper = !gh auth git-credential\n\tuseHttpPath = true\n",
        merged,
    );
}

test "merge: subsections with dots and slashes are distinct sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base = "[url \"https://github.com/\"]\n\tinsteadOf = git@github.com:\n[includeIf \"hasconfig:remote.*.url:https://github.com/octocat/**\"]\n\tpath = ~/.config/git/personal.inc\n";
    const overlay = "[url \"https://github.com/\"]\n\tinsteadOf = ssh://git@github.com/\n";
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings(
        "[url \"https://github.com/\"]\n\tinsteadOf = ssh://git@github.com/\n[includeIf \"hasconfig:remote.*.url:https://github.com/octocat/**\"]\n\tpath = ~/.config/git/personal.inc\n",
        merged,
    );
}

test "merge: section and key matching is case-insensitive, subsection case-sensitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base = "[User]\n\tEmail = a@example.com\n[branch \"Feature\"]\n\trebase = true\n";
    const overlay = "[user]\n\temail = b@example.com\n[branch \"feature\"]\n\trebase = false\n";
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings(
        "[User]\n\temail = b@example.com\n[branch \"Feature\"]\n\trebase = true\n\n[branch \"feature\"]\n\trebase = false\n",
        merged,
    );
}

test "merge: untouched base bytes survive verbatim including odd spacing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base = "; generic ini comment\n[a]\nx=1\n\n   \n[b]\ny  =   2\n";
    const overlay = "[a]\nx=9\n";
    const merged = try merge(arena.allocator(), base, overlay, .generic);
    try std.testing.expectEqualStrings("; generic ini comment\n[a]\nx=9\n\n   \n[b]\ny  =   2\n", merged);
}

test "merge: generic ini root keys before any section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base = "top=1\n[s]\nk=v\n";
    const overlay = "top=2\n";
    const merged = try merge(arena.allocator(), base, overlay, .generic);
    try std.testing.expectEqualStrings("top=2\n[s]\nk=v\n", merged);
}

test "merge: overlay trailing comment on a replaced line is kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base = "[core]\n\tautocrlf = input\n";
    const overlay = "[core]\n\tautocrlf = true  # windows checkout\n";
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings("[core]\n\tautocrlf = true  # windows checkout\n", merged);
}

test "merge: CRLF base round-trips as CRLF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A CRLF base with a CRLF overlay must emit CRLF throughout: untouched
    // base lines keep their carriage returns and the replaced line adopts the
    // overlay's CRLF ending.
    const base = "[user]\r\n\tname = Ada\r\n\temail = old@example.com\r\n";
    const overlay = "[user]\r\n\temail = work@example.com\r\n";
    const merged = try merge(arena.allocator(), base, overlay, .gitconfig);
    try std.testing.expectEqualStrings(
        "[user]\r\n\tname = Ada\r\n\temail = work@example.com\r\n",
        merged,
    );
}
