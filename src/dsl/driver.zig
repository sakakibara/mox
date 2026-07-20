const std = @import("std");
const ast = @import("ast.zig");
const scanner = @import("scanner.zig");
const parser = @import("parser.zig");

pub const DriverError = error{
    UnmatchedEndMarker,
    UnclosedRegion,
} || parser.ParseError || scanner.ScanError;

/// Where a parse error occurred: the 1-based source line and the directive text
/// on it, so a caller can point the user at the malformed line by name.
pub const ParseLoc = struct { line: u32 = 0, directive: []const u8 = "" };

/// Parse a complete source file into a list of directives.
/// `comment_marker` should be obtained via `comment.markerForExtension`.
/// On a parse error, `loc` (if given) is set to the offending directive line.
pub fn parseFile(arena: std.mem.Allocator, src: []const u8, comment_marker: []const u8, loc: ?*ParseLoc) DriverError!ast.ParsedFile {
    return parseFileImpl(arena, src, comment_marker, loc, false);
}

/// Parse a region body captured verbatim inside a `for` loop. A standalone
/// `when` gate in `src` then parses its condition with the row-expr grammar
/// (evaluated against the innermost loop record at compose), not the axis one.
pub fn parseFileInLoop(arena: std.mem.Allocator, src: []const u8, comment_marker: []const u8, loc: ?*ParseLoc) DriverError!ast.ParsedFile {
    return parseFileImpl(arena, src, comment_marker, loc, true);
}

fn parseFileImpl(arena: std.mem.Allocator, src: []const u8, comment_marker: []const u8, loc: ?*ParseLoc, in_loop: bool) DriverError!ast.ParsedFile {
    const events = try scanner.scan(arena, src, comment_marker);

    var directives: std.ArrayList(ast.Directive) = .empty;
    errdefer directives.deinit(arena);

    var i: usize = 0;
    var line_count: u32 = 0;
    while (i < events.len) : (i += 1) {
        const ev = events[i];
        line_count = switch (ev) {
            .content => |c| c.line_no,
            .directive => |d| d.line_no,
        };
        if (ev != .directive) continue;

        const args = ev.directive.args;
        const start_line = ev.directive.line_no;
        // Any error raised while parsing this directive (or the region it opens)
        // points here; record it before unwinding.
        errdefer if (loc) |l| {
            l.* = .{ .line = start_line, .directive = args };
        };

        // Try line-level first.
        const line_dir = parser.parseLineDirective(arena, args, start_line) catch |err| switch (err) {
            error.NotALineDirective => null,
            else => return err,
        };
        if (line_dir) |d| {
            try directives.append(arena, d);
            continue;
        }

        if (isEndMarker(args)) {
            return error.UnmatchedEndMarker;
        }

        const opener = try parser.parseRegionOpener(arena, args, start_line, in_loop);
        var body_buf: std.ArrayList(u8) = .empty;
        // Capture the body VERBATIM (raw lines, nested directive lines included)
        // up to the matching `end` at depth 0; compose re-parses a for/when body
        // recursively, so nesting works. Tracked by a flag, not buffer length: an
        // empty first line must still take its '\n' separator.
        var body_started = false;
        var end_line = start_line;
        var found_end = false;
        var depth: u32 = 0;
        var j: usize = i + 1;
        while (j < events.len) : (j += 1) {
            var raw: []const u8 = undefined;
            switch (events[j]) {
                .content => |c| {
                    raw = c.text;
                    end_line = c.line_no;
                },
                .directive => |d| {
                    if (isEndMarker(d.args)) {
                        if (depth == 0) {
                            end_line = d.line_no;
                            found_end = true;
                            break;
                        }
                        depth -= 1;
                    } else if (isRegionOpener(d.args)) {
                        depth += 1;
                    }
                    raw = d.original_line;
                    end_line = d.line_no;
                },
            }
            if (body_started) try body_buf.append(arena, '\n');
            try body_buf.appendSlice(arena, raw);
            body_started = true;
        }
        if (!found_end and opener.kind_tag != .when_gate) {
            return error.UnclosedRegion;
        }
        i = if (found_end) j else events.len;
        if (end_line > line_count) line_count = end_line;

        const body = try body_buf.toOwnedSlice(arena);

        const kind: ast.Directive.Kind = switch (opener.kind_tag) {
            .replace => .{ .replace = .{
                .path = opener.path,
                .when = opener.when,
                .from = opener.from_dir,
                .body = body,
            } },
            .append => .{ .append = .{
                .path = opener.path.?,
                .when = opener.when,
                .body = body,
            } },
            .prepend => .{ .prepend = .{
                .path = opener.path.?,
                .when = opener.when,
                .body = body,
            } },
            .remove => .{ .remove = .{
                .when = opener.when.?,
                .body = body,
            } },
            .from => .{ .from = .{
                .dir = opener.from_dir.?,
                .body = body,
            } },
            .when_gate => .{ .when_gate = .{
                .when = opener.when,
                .row_when = opener.row_when,
                .body = body,
                .to_eof = !found_end,
            } },
            .for_loop => .{ .for_loop = .{
                .variable = opener.from_dir.?,
                .data_source = opener.path.?,
                .when = opener.when,
                .where = opener.where,
                .into = opener.into,
                .body_template = body,
            } },
        };
        try directives.append(arena, .{
            .kind = kind,
            .start_line = start_line,
            .end_line = end_line,
        });
    }

    return .{
        .directives = try directives.toOwnedSlice(arena),
        .line_count = line_count,
    };
}

fn isEndMarker(args: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, args, " \t"), "end");
}

/// True when a directive opens a region (has a body closed by `end`), so it must
/// be depth-counted while capturing an enclosing region's body. A line directive
/// (`include`/`secret`) or an `end` returns false.
fn isRegionOpener(args: []const u8) bool {
    var e: usize = 0;
    while (e < args.len and args[e] != ' ' and args[e] != '\t') : (e += 1) {}
    const verb = args[0..e];
    inline for (.{ "replace", "append", "prepend", "remove", "from", "when", "for" }) |o| {
        if (std.mem.eql(u8, verb, o)) return true;
    }
    return false;
}

/// Strip leading whitespace, then the comment marker, then one space, from a loop-body line.
/// Returns the line as-is if the prefix doesn't match (an uncommented body line
/// passes through unchanged). Applied by compose to a for-body's content lines.
pub fn stripLoopBodyPrefix(line: []const u8, marker: []const u8) []const u8 {
    var rest = line;
    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) {
        rest = rest[1..];
    }
    if (!std.mem.startsWith(u8, rest, marker)) return line;
    rest = rest[marker.len..];
    if (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) {
        rest = rest[1..];
    }
    return rest;
}

test "parseFile: replace region" {
    var allocator_buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\local M = {}
        \\-- mox: replace "kind/work.lua" when profile=work
        \\M.kind = "personal"
        \\-- mox: end
        \\return M
    ;
    const parsed = try parseFile(fba.allocator(), src, "--", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    const d = parsed.directives[0];
    try std.testing.expect(d.kind == .replace);
    try std.testing.expectEqualStrings("M.kind = \"personal\"", d.kind.replace.body);
}

test "parseFile: from shorthand stores from dir" {
    var allocator_buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\-- mox: replace from "profile"
        \\M.kind = "personal"
        \\-- mox: end
    ;
    const parsed = try parseFile(fba.allocator(), src, "--", null);
    try std.testing.expect(parsed.directives[0].kind.replace.from != null);
}

test "parseFile: when gate without end gates to EOF" {
    var allocator_buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\# mox: when os=darwin
        \\hide() { chflags hidden "$@"; }
    ;
    const parsed = try parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .when_gate);
}

test "parseFile: a parse error records the offending line and directive" {
    var allocator_buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    // An unknown verb on line 3; the caller needs the line, not just the error.
    const src =
        \\a
        \\b
        \\# mox: frobnicate x
    ;
    var loc: ParseLoc = .{};
    try std.testing.expectError(error.ExpectedKeyword, parseFile(fba.allocator(), src, "#", &loc));
    try std.testing.expectEqual(@as(u32, 3), loc.line);
    try std.testing.expectEqualStrings("frobnicate x", loc.directive);
}

test "parseFile: region body preserves a leading blank line" {
    var allocator_buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    // A conditional section preceded by a blank line is the common shape for
    // TOML/INI/gitconfig; the blank must survive into the region body.
    const src =
        \\# mox: when os=macos
        \\
        \\B
        \\# mox: end
    ;
    const parsed = try parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .when_gate);
    try std.testing.expectEqualStrings("\nB", parsed.directives[0].kind.when_gate.body);
}

test "parseFile: when_gate.to_eof distinguishes an EOF gate from a terminated region" {
    var allocator_buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);

    const eof_gate = try parseFile(fba.allocator(), "# mox: when os=macos\nB\nC", "#", null);
    try std.testing.expect(eof_gate.directives[0].kind == .when_gate);
    try std.testing.expect(eof_gate.directives[0].kind.when_gate.to_eof);

    // Terminated region whose `end` is the last line (no trailing newline): the
    // line-count heuristic could not tell this from an EOF gate; `to_eof` can.
    const scoped = try parseFile(fba.allocator(), "# mox: when os=macos\nB\n# mox: end", "#", null);
    try std.testing.expect(scoped.directives[0].kind == .when_gate);
    try std.testing.expect(!scoped.directives[0].kind.when_gate.to_eof);
}

test "parseFile: for loop captures body verbatim (compose strips the prefix)" {
    var allocator_buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\# mox: for entry in abbreviations.toml
        \\#   abbr <entry.key>=<entry.expansion>
        \\# mox: end
    ;
    const parsed = try parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .for_loop);
    try std.testing.expectEqualStrings("entry", parsed.directives[0].kind.for_loop.variable);
    try std.testing.expectEqualStrings("abbreviations.toml", parsed.directives[0].kind.for_loop.data_source);
    // Verbatim: the comment prefix survives into the body; compose strips it (so
    // nested `# mox:` directive lines inside the body remain parseable).
    try std.testing.expectEqualStrings("#   abbr <entry.key>=<entry.expansion>", parsed.directives[0].kind.for_loop.body_template);
}

test "stripLoopBodyPrefix removes leading whitespace and comment marker" {
    try std.testing.expectEqualStrings("abbr foo=bar", stripLoopBodyPrefix("# abbr foo=bar", "#"));
    try std.testing.expectEqualStrings("  abbr foo=bar", stripLoopBodyPrefix("#   abbr foo=bar", "#"));
    try std.testing.expectEqualStrings("M.x = 1", stripLoopBodyPrefix("-- M.x = 1", "--"));
    // No marker -> return as-is
    try std.testing.expectEqualStrings("plain text", stripLoopBodyPrefix("plain text", "#"));
}
