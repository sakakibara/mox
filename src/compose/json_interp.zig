//! Capture expansion for the JSON family, per string token.
//!
//! A capture in a JSON source lives inside a string token. Each string token
//! that holds one is decoded, expanded, and re-encoded as a JSON string, so a
//! `"` or `\` in a resolved value can never break the document. A value
//! token that is exactly one `<data.FILE.KEY>` capture emits the scalar in
//! its own JSON type. Every byte outside such a token -- structure,
//! whitespace, comments, a token with no capture -- is left as written, and
//! no expansion adds a newline.

const std = @import("std");
const json = @import("json");
const interp = @import("interp.zig");
const data = @import("../data/root.zig");

/// Scanner state carried between chunks of one document expanded piecewise
/// (Cat B emits a JSONC file line by line and body by body): whether the
/// previous chunk ended inside a `/* ... */` comment, which json-zig's
/// tokenizer cannot resume in. A string never spans a newline, so nothing
/// else needs carrying.
pub const ScanState = struct {
    in_block_comment: bool = false,
    dialect: json.Dialect = .jsonc,
};

pub const Result = struct {
    bytes: []u8,
    /// One flag per line of `bytes`: the line resolved a secret.
    line_secret: []bool,
    secret: bool = false,
    placeholder: bool = false,
    /// A capture expanded inside an object key.
    key_capture: bool = false,
};

/// Expand every capture-bearing string token of `text`. `ctx.json` is
/// ignored: a decoded string's own captures expand as plain text.
pub fn expand(
    arena: std.mem.Allocator,
    text: []const u8,
    dialect: json.Dialect,
    record: ?*const std.StringHashMap(data.value.Value),
    ctx: interp.Ctx,
    state: *ScanState,
) interp.InterpError!Result {
    var inner_ctx = ctx;
    inner_ctx.json = null;

    const line_count = std.mem.count(u8, text, "\n") + 1;
    const line_secret = try arena.alloc(bool, line_count);
    @memset(line_secret, false);
    var res: Result = .{ .bytes = &.{}, .line_secret = line_secret };

    var start: usize = 0;
    if (state.in_block_comment) {
        const close = std.mem.indexOf(u8, text, "*/") orelse {
            res.bytes = try arena.dupe(u8, text);
            return res;
        };
        start = close + 2;
        state.in_block_comment = false;
    }

    var tokens: std.ArrayList(json.Token) = .empty;
    var t = json.Tokenizer.init(text, dialect);
    t.pos = start;
    while (t.next()) |tok| {
        const s: usize = @intCast(tok.span.start);
        if (tok.kind == .invalid and std.mem.startsWith(u8, text[s..], "/*")) {
            state.in_block_comment = true;
            break;
        }
        try tokens.append(arena, tok);
    }

    var out: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    var line: usize = 0;
    var line_pos: usize = 0;
    for (tokens.items, 0..) |tok, i| {
        if (tok.kind != .string) continue;
        const s: usize = @intCast(tok.span.start);
        const e: usize = @intCast(tok.span.end);
        const slice = text[s..e];
        if (std.mem.indexOfScalar(u8, slice, '<') == null) continue;
        const decoded = json.parse(arena, slice, .{ .dialect = dialect }) catch continue;
        if (decoded != .string) continue;
        const content = decoded.string;
        // Inside a loop a bare `<var.field>` is a capture too.
        const in_loop = record != null or ctx.scope.len > 0;
        if (!in_loop and !interp.containsCapture(content)) continue;

        line += std.mem.count(u8, text[line_pos..s], "\n");
        line_pos = s;
        const is_key = nextIsColon(tokens.items[i + 1 ..]);

        try out.appendSlice(arena, text[copied..s]);
        copied = e;
        if (!is_key) {
            if (try interp.soleDataCapture(arena, content, inner_ctx)) |sc| {
                switch (sc.kind) {
                    .integer, .boolean => try out.appendSlice(arena, sc.text),
                    .float => if (finiteNumber(sc.text))
                        try out.appendSlice(arena, sc.text)
                    else
                        try appendJsonString(arena, &out, sc.text),
                    .string, .datetime => try appendJsonString(arena, &out, sc.text),
                }
                continue;
            }
        }
        const exp = try interp.expandTracked(arena, content, record, inner_ctx);
        try appendJsonString(arena, &out, exp.bytes);
        if (exp.secret) res.secret = true;
        if (exp.placeholder) res.placeholder = true;
        if (exp.secret) line_secret[line] = true;
        if (is_key) {
            res.key_capture = true;
            if (ctx.diag) |d| d.json_key_capture = true;
        }
    }
    try out.appendSlice(arena, text[copied..]);
    res.bytes = try out.toOwnedSlice(arena);
    return res;
}

fn nextIsColon(rest: []const json.Token) bool {
    for (rest) |tok| {
        if (tok.kind == .comment) continue;
        return tok.kind == .colon;
    }
    return false;
}

/// True when a TOML float's rendering is a JSON number (not nan or inf).
fn finiteNumber(text: []const u8) bool {
    for (text) |c| {
        if (std.ascii.isAlphabetic(c) and c != 'e' and c != 'E') return false;
    }
    return true;
}

/// Append `s` as a JSON string literal: quotes, backslashes and control
/// bytes escaped, everything else (non-ASCII included) as written.
pub fn appendJsonString(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(arena, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        0x08 => try out.appendSlice(arena, "\\b"),
        0x0c => try out.appendSlice(arena, "\\f"),
        else => if (c < 0x20) {
            var buf: [6]u8 = undefined;
            try out.appendSlice(arena, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable);
        } else try out.append(arena, c),
    };
    try out.append(arena, '"');
}

const testing = std.testing;

fn expandText(a: std.mem.Allocator, text: []const u8, ctx: interp.Ctx) !Result {
    var st: ScanState = .{};
    return expand(a, text, .jsonc, null, ctx, &st);
}

test "expand: a capture-free document is byte-identical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "{\n  \"a\": \"\\/x\\u00e9\", // <machine.os>\n  \"b\": \"<not a capture>\"\n}\n";
    const r = try expandText(arena.allocator(), text, .{});
    try testing.expectEqualStrings(text, r.bytes);
}

test "appendJsonString: quotes, backslashes and control bytes are escaped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try appendJsonString(a, &out, "C:\\Users\\\"me\"\n\x01");
    try testing.expectEqualStrings("\"C:\\\\Users\\\\\\\"me\\\"\\n\\u0001\"", out.items);
}

test "expand: an unterminated block comment carries into the next chunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: ScanState = .{};
    const one = try expand(a, "\"a\": 1, /* start", .jsonc, null, .{}, &st);
    try testing.expectEqualStrings("\"a\": 1, /* start", one.bytes);
    try testing.expect(st.in_block_comment);
    const two = try expand(a, "  \"<env.X>\" still comment */ \"b\": 2", .jsonc, null, .{}, &st);
    try testing.expectEqualStrings("  \"<env.X>\" still comment */ \"b\": 2", two.bytes);
    try testing.expect(!st.in_block_comment);
}
