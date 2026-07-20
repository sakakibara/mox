const std = @import("std");

pub const Event = union(enum) {
    /// A non-directive content line.
    content: struct {
        line_no: u32, // 1-indexed
        text: []const u8,
    },
    /// A `# mox: <args>` directive line.
    directive: struct {
        line_no: u32,
        /// The args portion (everything after `mox:`), trimmed.
        args: []const u8,
        /// The original full line (for error reporting).
        original_line: []const u8,
    },
};

pub const ScanError = error{
    DirectiveTooLong,
    OutOfMemory,
};

/// Maximum length (bytes) of a directive's args. Directives are short by
/// construction; a line far larger than this is either a mistake or a hostile
/// attempt to drive the expression parsers into deep recursion. Capping here
/// bounds the input the lexer/axis/row_expr parsers ever see.
pub const max_directive_len: usize = 8192;

/// Scan a source file given its line-comment marker (e.g., `#`, `--`, `;`).
/// Returns a slice of events; allocator-owned.
pub fn scan(allocator: std.mem.Allocator, src: []const u8, comment_marker: []const u8) ScanError![]Event {
    var list: std.ArrayList(Event) = .empty;
    errdefer list.deinit(allocator);

    var line_no: u32 = 0;
    var iter = std.mem.splitScalar(u8, src, '\n');
    while (iter.next()) |line| {
        line_no += 1;
        var start: usize = 0;
        while (start < line.len and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
        const trimmed = line[start..];

        if (matchDirective(trimmed, comment_marker)) |args| {
            if (args.len > max_directive_len) return error.DirectiveTooLong;
            try list.append(allocator, .{
                .directive = .{
                    .line_no = line_no,
                    .args = args,
                    .original_line = line,
                },
            });
        } else {
            try list.append(allocator, .{
                .content = .{ .line_no = line_no, .text = line },
            });
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Returns the args of a directive line, or null if `line` is not a directive.
/// Match rules:
///   - line must start with the comment marker (already trimmed of leading whitespace by caller)
///   - the char immediately after the marker must be a space or tab (so `##` and `#mox:` are not directives)
///   - after whitespace, the prefix must be `mox:`
///   - args is whatever follows `mox:`, trimmed of surrounding whitespace
fn matchDirective(line: []const u8, marker: []const u8) ?[]const u8 {
    if (line.len < marker.len) return null;
    if (!std.mem.startsWith(u8, line, marker)) return null;
    var rest = line[marker.len..];
    if (rest.len == 0) return null;
    if (rest[0] != ' ' and rest[0] != '\t') return null;

    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) {
        rest = rest[1..];
    }

    const prefix = "mox:";
    if (rest.len < prefix.len) return null;
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    var args = rest[prefix.len..];

    while (args.len > 0 and (args[0] == ' ' or args[0] == '\t')) {
        args = args[1..];
    }
    // Strip trailing spaces/tabs and a CRLF carriage return, so directive
    // lines parse identically whether the file uses LF or CRLF endings.
    while (args.len > 0 and (args[args.len - 1] == ' ' or args[args.len - 1] == '\t' or args[args.len - 1] == '\r')) {
        args = args[0 .. args.len - 1];
    }

    return args;
}

test "scan: over-long directive line rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "# mox: when ");
    try buf.appendNTimes(a, '(', max_directive_len);
    try std.testing.expectError(error.DirectiveTooLong, scan(a, buf.items, "#"));
}

test "matchDirective: typical case" {
    const r = matchDirective("# mox: include \"x\"", "#");
    try std.testing.expectEqualStrings("include \"x\"", r.?);
}

test "matchDirective: extra hash is not a directive" {
    try std.testing.expect(matchDirective("## mox: foo", "#") == null);
}

test "matchDirective: marker followed immediately by mox is not directive" {
    try std.testing.expect(matchDirective("#mox: foo", "#") == null);
}

test "matchDirective: regular comment" {
    try std.testing.expect(matchDirective("# this is a comment", "#") == null);
}

test "matchDirective: lua marker" {
    const r = matchDirective("-- mox: include \"x\"", "--");
    try std.testing.expectEqualStrings("include \"x\"", r.?);
}

test "matchDirective: trailing whitespace stripped" {
    const r = matchDirective("# mox: include \"x\"   ", "#");
    try std.testing.expectEqualStrings("include \"x\"", r.?);
}

test "matchDirective: trailing CRLF carriage return stripped" {
    const r = matchDirective("# mox: when os=darwin\r", "#");
    try std.testing.expectEqualStrings("when os=darwin", r.?);
    const e = matchDirective("# mox: end\r", "#");
    try std.testing.expectEqualStrings("end", e.?);
}
