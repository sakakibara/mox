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
const capture = @import("capture.zig");

/// Scanner state carried between chunks of one document expanded piecewise
/// (Cat B emits a JSONC file line by line and body by body): whether the
/// previous chunk ended inside a `/* ... */` comment, which json-zig's
/// tokenizer cannot resume in. A string never spans a newline, so nothing
/// else needs carrying.
pub const ScanState = struct {
    in_block_comment: bool = false,
    dialect: json.Dialect = .jsonc,
    /// A generator template, not a parsed layer: a capture outside a string
    /// emits its value as typed JSON, and a string token that is one loop-row
    /// capture is typed as a data capture is.
    generator: bool = false,
    /// When set, collects every key a key capture made.
    captured_keys: ?*std.StringHashMap(void) = null,
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

/// `text` with every raw `"` inside a capture that sits in a JSON string
/// escaped, so `"<a | default "x">"` reads as the one string it means, as
/// `"<a | default \"x\">"` does. A capture is recognized as a unit before
/// the string is tokenized; nothing else changes.
pub fn escapeCaptureQuotes(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '<') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_string = false;
    var changed = false;
    while (i < text.len) {
        const c = text[i];
        if (!in_string) {
            if (std.mem.startsWith(u8, text[i..], "//")) {
                const end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
                try out.appendSlice(arena, text[i..end]);
                i = end;
                continue;
            }
            if (std.mem.startsWith(u8, text[i..], "/*")) {
                const end = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 2 else text.len;
                try out.appendSlice(arena, text[i..end]);
                i = end;
                continue;
            }
            if (c == '"') in_string = true;
            try out.append(arena, c);
            i += 1;
            continue;
        }
        switch (c) {
            '\\' => {
                try out.appendSlice(arena, text[i..@min(i + 2, text.len)]);
                i += 2;
            },
            '"', '\n' => {
                in_string = false;
                try out.append(arena, c);
                i += 1;
            },
            '<' => {
                const rest = text[i + 1 ..];
                const opens = rest.len > 0 and (std.ascii.isAlphabetic(rest[0]) or rest[0] == '_');
                const close = if (opens) capture.closeIndex(text, i) else null;
                const within = if (close) |e| std.mem.indexOfScalar(u8, text[i..e], '\n') == null else false;
                if (close != null and within) {
                    var k = i;
                    while (k <= close.?) : (k += 1) {
                        if (text[k] == '\\' and k + 1 <= close.?) {
                            try out.appendSlice(arena, text[k .. k + 2]);
                            k += 1;
                        } else if (text[k] == '"') {
                            try out.appendSlice(arena, "\\\"");
                            changed = true;
                        } else try out.append(arena, text[k]);
                    }
                    i = close.? + 1;
                } else {
                    try out.append(arena, c);
                    i += 1;
                }
            },
            else => {
                try out.append(arena, c);
                i += 1;
            },
        }
    }
    return if (changed) out.items else text;
}

test "escapeCaptureQuotes: a raw-quoted default is escaped, an escaped one is left" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectEqualStrings("{\"o\": \"<a | default \\\"z\\\">\"}", try escapeCaptureQuotes(arena.allocator(), "{\"o\": \"<a | default \"z\">\"}"));
    const esc = "{\"o\": \"<a | default \\\"z\\\">\"}";
    try std.testing.expectEqualStrings(esc, try escapeCaptureQuotes(arena.allocator(), esc));
    try std.testing.expectEqualStrings("{\"a\": \"x < y\"}", try escapeCaptureQuotes(arena.allocator(), "{\"a\": \"x < y\"}"));
}

/// True when `text` holds a capture outside any string with a `| default`.
pub fn hasBareDefault(text: []const u8) bool {
    var i: usize = 0;
    var in_string = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"' or c == '\n') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c != '<') continue;
        const close = capture.closeIndex(text, i) orelse continue;
        if (std.mem.indexOf(u8, text[i..close], "| default") != null) return true;
        i = close;
    }
    return false;
}

/// Expand every capture-bearing string token of `text`. `ctx.json` is
/// ignored: a decoded string's own captures expand as plain text.
pub fn expand(
    arena: std.mem.Allocator,
    text_in: []const u8,
    dialect: json.Dialect,
    record: ?*const std.StringHashMap(data.value.Value),
    ctx: interp.Ctx,
    state: *ScanState,
) interp.InterpError!Result {
    var inner_ctx = ctx;
    inner_ctx.json = null;
    var text = if (state.in_block_comment) text_in else try escapeCaptureQuotes(arena, text_in);

    const line_count = std.mem.count(u8, text, "\n") + 1;
    const line_secret = try arena.alloc(bool, line_count);
    @memset(line_secret, false);
    var res: Result = .{ .bytes = &.{}, .line_secret = line_secret };

    if (state.generator) text = try typeBareCaptures(arena, text, record, inner_ctx, state.in_block_comment, &res);

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
            const sole = (try interp.soleDataCapture(arena, content, inner_ctx)) orelse
                if (state.generator) try interp.soleRowCapture(arena, content, inner_ctx) else null;
            if (sole) |sc| {
                switch (sc.kind) {
                    .integer, .boolean => try out.appendSlice(arena, sc.text),
                    .float => if (finiteNumber(sc.text))
                        try out.appendSlice(arena, try jsNumber(arena, std.fmt.parseFloat(f64, sc.text) catch unreachable))
                    else {
                        if (ctx.diag) |d| d.set(try std.fmt.allocPrint(arena, "{s} is {s}, not representable in JSON", .{ content[1 .. content.len - 1], sc.text }));
                        return error.NotRepresentableInJson;
                    },
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
            if (state.captured_keys) |ck| try ck.put(exp.bytes, {});
        }
    }
    try out.appendSlice(arena, text[copied..]);
    res.bytes = try out.toOwnedSlice(arena);
    return res;
}

/// `text` with every capture outside a string and a comment replaced by its
/// value as JSON: a scalar in its own type, anything else a JSON string.
fn typeBareCaptures(
    arena: std.mem.Allocator,
    text: []const u8,
    record: ?*const std.StringHashMap(data.value.Value),
    ctx: interp.Ctx,
    in_block_comment: bool,
    res: *Result,
) interp.InterpError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var block = in_block_comment;
    while (i < text.len) {
        const c = text[i];
        if (block) {
            if (std.mem.startsWith(u8, text[i..], "*/")) {
                block = false;
                try out.appendSlice(arena, "*/");
                i += 2;
            } else {
                try out.append(arena, c);
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "//")) {
            const end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            try out.appendSlice(arena, text[i..end]);
            i = end;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "/*")) {
            block = true;
            try out.appendSlice(arena, "/*");
            i += 2;
            continue;
        }
        if (c == '"') {
            var j = i + 1;
            while (j < text.len and text[j] != '"' and text[j] != '\n') : (j += 1) {
                if (text[j] == '\\') j += 1;
            }
            const end = @min(j + 1, text.len);
            try out.appendSlice(arena, text[i..end]);
            i = end;
            continue;
        }
        if (c == '<' and captureAt(text, i, ctx)) if (capture_close(text, i)) |close| {
            const cap = text[i .. close + 1];
            const sole = (try interp.soleDataCapture(arena, cap, ctx)) orelse try interp.soleRowCapture(arena, cap, ctx);
            if (sole) |sc| {
                switch (sc.kind) {
                    .integer, .boolean => try out.appendSlice(arena, sc.text),
                    .float => if (finiteNumber(sc.text))
                        try out.appendSlice(arena, try jsNumber(arena, std.fmt.parseFloat(f64, sc.text) catch unreachable))
                    else {
                        if (ctx.diag) |d| d.set(try std.fmt.allocPrint(arena, "{s} is {s}, not representable in JSON", .{ cap[1 .. cap.len - 1], sc.text }));
                        return error.NotRepresentableInJson;
                    },
                    .string, .datetime => try appendJsonString(arena, &out, sc.text),
                }
            } else {
                const exp = try interp.expandTracked(arena, cap, record, ctx);
                try appendJsonString(arena, &out, exp.bytes);
                if (exp.secret) {
                    res.secret = true;
                    res.line_secret[std.mem.count(u8, text[0..i], "\n")] = true;
                }
                if (exp.placeholder) res.placeholder = true;
            }
            i = close + 1;
            continue;
        };
        try out.append(arena, c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// True when the `<` at `open` opens a capture: a secret, a namespace, or a
/// loop variable in scope.
fn captureAt(text: []const u8, open: usize, ctx: interp.Ctx) bool {
    const rest = text[open + 1 ..];
    if (std.mem.startsWith(u8, rest, "secret:") or capture.hasNamespace(rest)) return true;
    var n: usize = 0;
    while (n < rest.len and (std.ascii.isAlphanumeric(rest[n]) or rest[n] == '_')) n += 1;
    if (n == 0) return false;
    for (ctx.scope) |f| if (std.mem.eql(u8, f.name, rest[0..n])) return true;
    return false;
}

fn capture_close(text: []const u8, open: usize) ?usize {
    const close = capture.closeIndex(text, open) orelse return null;
    if (std.mem.indexOfScalar(u8, text[open..close], '\n') != null) return null;
    return close;
}

fn nextIsColon(rest: []const json.Token) bool {
    for (rest) |tok| {
        if (tok.kind == .comment) continue;
        return tok.kind == .colon;
    }
    return false;
}

/// A finite float as JavaScript's Number-to-string writes it: the shortest
/// digits that read back as the same value, in decimal notation for
/// 1e-7 <= |x| < 1e21 and in exponent notation otherwise.
pub fn jsNumber(arena: std.mem.Allocator, x: f64) ![]const u8 {
    if (x == 0) return "0";
    const sci = try std.fmt.allocPrint(arena, "{e}", .{@abs(x)});
    const e_at = std.mem.indexOfScalar(u8, sci, 'e').?;
    var digits: std.ArrayList(u8) = .empty;
    for (sci[0..e_at]) |c| if (c != '.') try digits.append(arena, c);
    const k: i64 = @intCast(digits.items.len);
    const n: i64 = (std.fmt.parseInt(i64, sci[e_at + 1 ..], 10) catch unreachable) + 1;
    var out: std.ArrayList(u8) = .empty;
    if (x < 0) try out.append(arena, '-');
    const d = digits.items;
    if (k <= n and n <= 21) {
        try out.appendSlice(arena, d);
        try out.appendNTimes(arena, '0', @intCast(n - k));
    } else if (0 < n and n <= 21) {
        try out.appendSlice(arena, d[0..@intCast(n)]);
        try out.append(arena, '.');
        try out.appendSlice(arena, d[@intCast(n)..]);
    } else if (-6 < n and n <= 0) {
        try out.appendSlice(arena, "0.");
        try out.appendNTimes(arena, '0', @intCast(-n));
        try out.appendSlice(arena, d);
    } else {
        try out.append(arena, d[0]);
        if (k > 1) {
            try out.append(arena, '.');
            try out.appendSlice(arena, d[1..]);
        }
        try out.print(arena, "e{c}{d}", .{ @as(u8, if (n - 1 < 0) '-' else '+'), @abs(n - 1) });
    }
    return out.toOwnedSlice(arena);
}

test "jsNumber follows JavaScript's Number-to-string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { x: f64, want: []const u8 }{
        .{ .x = 0.0001, .want = "0.0001" },              .{ .x = 100000.0, .want = "100000" },
        .{ .x = 1e300, .want = "1e+300" },               .{ .x = -0.0, .want = "0" },
        .{ .x = 1.5, .want = "1.5" },                    .{ .x = 3.0, .want = "3" },
        .{ .x = 1e-7, .want = "1e-7" },                  .{ .x = 1.5e-7, .want = "1.5e-7" },
        .{ .x = 0.000001, .want = "0.000001" },          .{ .x = 1e21, .want = "1e+21" },
        .{ .x = 1e20, .want = "100000000000000000000" }, .{ .x = -123.25, .want = "-123.25" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c.want, try jsNumber(a, c.x));
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
