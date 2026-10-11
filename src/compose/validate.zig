//! Format validation of composed layers and outputs.
//!
//! Every structured layer is parsed in its target's format and dialect
//! before composition, and every composed output after capture expansion,
//! so a file its program cannot read never reaches the live tree. A failure
//! is `error.FormatViolation`, with the diag holding the report a command
//! prints inside `ERROR <file> (...)`: `<location>: <message>[; <hint>]`.

const std = @import("std");
const json = @import("json");
const toml = @import("toml");
const yaml = @import("yaml");
const ini = @import("ini");
const source = @import("../source/root.zig");
const interp = @import("interp.zig");

const Format = source.format.Format;

pub const Error = error{ FormatViolation, OutOfMemory };

const comment_hint = "JSON has no comments: remove it, or set format = \"jsonc\" for this file in .mox/attributes.toml if the program reads comments";
const trailing_comma_hint = "remove the trailing comma";
const empty_hint = "an empty file is not JSON: write {}";
const data_capture_hint = "quote it: a quoted single data capture emits its typed value";
const capture_hint = "quote it";

/// One parse failure: 1-based line and column in the checked text, the
/// parser's message, and a hint by cause.
const Failure = struct {
    line: u32,
    col: u32,
    message: []const u8,
    hint: ?[]const u8 = null,
};

/// Check one layer as written. `display` names it; `removed` maps a line of
/// the checked text back to the line the source file has it on (the base's
/// stripped head lines).
pub fn checkLayer(
    arena: std.mem.Allocator,
    format: Format,
    text: []const u8,
    display: []const u8,
    removed: []const u32,
    diag: ?*interp.Diag,
) Error!void {
    const f = (try firstFailure(arena, format, text, display)) orelse return;
    const line = source.head.sourceLine(removed, f.line);
    return report(arena, diag, try std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ display, line, f.col }), f.message, f.hint);
}

/// Check a composed output. `layers` names the layers it came from;
/// `secret_lines[i]` marks output line `i + 1` as carrying a resolved
/// secret, whose text is never quoted.
pub fn checkOutput(
    arena: std.mem.Allocator,
    format: Format,
    bytes: []const u8,
    layers: []const []const u8,
    secret_lines: []const bool,
    diag: ?*interp.Diag,
) Error!void {
    const f = (try firstFailure(arena, format, bytes, "")) orelse return;
    const secret = f.line >= 1 and f.line - 1 < secret_lines.len and secret_lines[f.line - 1];
    const loc = try std.fmt.allocPrint(arena, "composed output line {d} from {s}", .{ f.line, try layerList(arena, layers) });
    return report(arena, diag, loc, if (secret) "<redacted>" else f.message, if (secret) null else f.hint);
}

/// A duplicate object key in a JSON-family document, reported against
/// `display` (a layer, or the composed output when `layers` is non-empty).
pub fn checkDuplicateKeys(
    arena: std.mem.Allocator,
    format: Format,
    bytes: []const u8,
    display: []const u8,
    layers: []const []const u8,
    secret_lines: []const bool,
    diag: ?*interp.Diag,
) Error!void {
    const hit = (try duplicateKey(arena, format.jsonDialect(), bytes)) orelse return;
    const lc = lineCol(bytes, hit.offset);
    const secret = lc.line >= 1 and lc.line - 1 < secret_lines.len and secret_lines[lc.line - 1];
    const loc = if (layers.len > 0)
        try std.fmt.allocPrint(arena, "composed output line {d} from {s}", .{ lc.line, try layerList(arena, layers) })
    else
        try std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ display, lc.line, lc.col });
    const message = if (secret) "<redacted>" else try std.fmt.allocPrint(arena, "duplicate key \"{s}\"", .{hit.key});
    return report(arena, diag, loc, message, null);
}

fn report(arena: std.mem.Allocator, diag: ?*interp.Diag, loc: []const u8, message: []const u8, hint: ?[]const u8) Error {
    if (diag) |d| {
        const text = if (hint) |h|
            try std.fmt.allocPrint(arena, "{s}: {s}; {s}", .{ loc, message, h })
        else
            try std.fmt.allocPrint(arena, "{s}: {s}", .{ loc, message });
        d.set(text);
    }
    return error.FormatViolation;
}

fn layerList(arena: std.mem.Allocator, layers: []const []const u8) ![]const u8 {
    if (layers.len == 0) return "no layer";
    if (layers.len == 1) return layers[0];
    const head = try std.mem.join(arena, ", ", layers[0 .. layers.len - 1]);
    return std.fmt.allocPrint(arena, "{s} and {s}", .{ head, layers[layers.len - 1] });
}

const LineCol = struct { line: u32, col: u32 };

fn lineCol(text: []const u8, offset: usize) LineCol {
    var line: u32 = 1;
    var start: usize = 0;
    const end = @min(offset, text.len);
    for (text[0..end], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            start = i + 1;
        }
    }
    return .{ .line = line, .col = @intCast(end - start + 1) };
}

/// The first parse failure of `text` in `format`, or null when it parses.
/// `display` names the file in a directive refusal's overlay hint.
fn firstFailure(arena: std.mem.Allocator, format: Format, text: []const u8, display: []const u8) !?Failure {
    return switch (format) {
        .json, .jsonc => jsonFailure(arena, format, text, display),
        .toml => blk: {
            var errs: std.ArrayList(toml.Diagnostic) = .empty;
            _ = toml.parse(arena, text, .{ .errors = &errs }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blk try fromSpan(text, errs.items, e),
            };
            break :blk null;
        },
        .yaml => blk: {
            // A YAML file is a stream: zero documents, or several, are as
            // valid as one.
            var errs: std.ArrayList(yaml.Diagnostic) = .empty;
            _ = yaml.parseStream(arena, text, .{ .errors = &errs }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blk try fromSpan(text, errs.items, e),
            };
            break :blk null;
        },
        .ini, .gitconfig => blk: {
            var errs: std.ArrayList(ini.Diagnostic) = .empty;
            _ = ini.parse(arena, text, .{ .dialect = source.format.iniDialect(format), .errors = &errs }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blk try fromSpan(text, errs.items, e),
            };
            break :blk null;
        },
    };
}

fn fromSpan(text: []const u8, diags: anytype, e: anyerror) !Failure {
    if (diags.len == 0) return .{ .line = 1, .col = 1, .message = @errorName(e) };
    const d = diags[0];
    const lc = lineCol(text, @intCast(d.span.start));
    return .{ .line = lc.line, .col = lc.col, .message = d.message };
}

fn jsonFailure(arena: std.mem.Allocator, format: Format, text: []const u8, display: []const u8) !?Failure {
    if (format == .json) {
        if (try directiveRefusal(arena, text, display)) |f| return f;
    }
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        return .{ .line = 1, .col = 1, .message = "unexpected end of input", .hint = empty_hint };
    }
    var errs: std.ArrayList(json.Diagnostic) = .empty;
    _ = json.parse(arena, text, .{ .dialect = format.jsonDialect(), .errors = &errs }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (errs.items.len == 0) return .{ .line = 1, .col = 1, .message = @errorName(e) };
            const d = errs.items[0];
            const start: usize = @intCast(d.span.start);
            const lc = lineCol(text, start);
            var f: Failure = .{ .line = lc.line, .col = lc.col, .message = d.message };
            const at: u8 = if (start < text.len) text[start] else 0;
            if (at == '/' and format == .json) {
                f.hint = comment_hint;
            } else if (std.mem.indexOf(u8, d.message, "trailing comma") != null) {
                f.hint = trailing_comma_hint;
            } else if (at == '<') {
                f.hint = if (std.mem.startsWith(u8, std.mem.trimStart(u8, text[start + 1 ..], " \t"), "data.")) data_capture_hint else capture_hint;
            }
            return f;
        },
    };
    return null;
}

/// A strict-JSON layer's first `mox:` comment, refused with the place its
/// directive lives instead. Found with the JSONC tokenizer, so a string that
/// merely spells `// mox:` is content.
fn directiveRefusal(arena: std.mem.Allocator, text: []const u8, display: []const u8) !?Failure {
    var t = json.Tokenizer.init(text, .jsonc);
    var seen_value = false;
    var first: ?struct { verb: []const u8, start: usize, leading: bool } = null;
    var has_end = false;
    while (t.next()) |tok| {
        if (tok.kind != .comment) {
            seen_value = true;
            continue;
        }
        const start: usize = @intCast(tok.span.start);
        const body = commentBody(text[start..@intCast(tok.span.end)]);
        if (!std.mem.startsWith(u8, body, "mox:")) continue;
        const args = std.mem.trimStart(u8, body["mox:".len..], " \t");
        const verb_end = std.mem.indexOfAny(u8, args, " \t(\"") orelse args.len;
        const verb = args[0..verb_end];
        if (std.mem.eql(u8, verb, "end")) has_end = true;
        if (first == null) first = .{ .verb = verb, .start = start, .leading = !seen_value };
    }
    const hit = first orelse return null;
    const lc = lineCol(text, hit.start);
    const v = hit.verb;
    const hint: []const u8 = if (eqAny(v, &.{ "own", "disown", "check" }))
        try std.fmt.allocPrint(arena, "declare it in .mox/attributes.toml as {s} = [\"...\"] for this file", .{v})
    else if (std.mem.eql(u8, v, "when") and hit.leading and !has_end)
        "declare the whole-file gate in .mox/attributes.toml as when = \"<axis-expr>\" for this file"
    else if (std.mem.eql(u8, v, "secret"))
        "use a \"<secret:URI>\" capture inside a JSON string instead"
    else if (std.mem.eql(u8, v, "default"))
        "declare it in .mox/attributes.toml as defaults = { <name> = \"<value>\" } for this file"
    else if (std.mem.eql(u8, v, "keep-empty"))
        "remove it: a structured file is never omitted when empty"
    else if (eqAny(v, &.{ "when", "include", "replace", "append", "prepend", "remove", "from", "for", "end" }))
        try std.fmt.allocPrint(arena, "vary the file with an overlay {s}.d/<axis>.json instead", .{std.fs.path.basenamePosix(display)})
    else
        comment_hint;
    const message = try std.fmt.allocPrint(arena, "mox directive \"{s}\" in strict JSON, which has no comments", .{v});
    return .{ .line = lc.line, .col = lc.col, .message = message, .hint = hint };
}

fn eqAny(s: []const u8, set: []const []const u8) bool {
    for (set) |c| if (std.mem.eql(u8, s, c)) return true;
    return false;
}

/// A comment token's text without its delimiters, trimmed.
fn commentBody(tok: []const u8) []const u8 {
    var b = tok;
    if (std.mem.startsWith(u8, b, "//")) {
        b = b[2..];
    } else if (std.mem.startsWith(u8, b, "/*")) {
        b = b[2..];
        if (std.mem.endsWith(u8, b, "*/")) b = b[0 .. b.len - 2];
    }
    return std.mem.trim(u8, b, " \t\r\n");
}

pub const DupHit = struct { key: []const u8, offset: usize };

/// The first object key that repeats within its object, or null. Keys are
/// compared decoded, so `"a"` and `"\u0061"` are one key.
pub fn duplicateKey(arena: std.mem.Allocator, dialect: json.Dialect, text: []const u8) !?DupHit {
    const Frame = struct { object: bool, want_key: bool, keys: std.StringHashMap(void) };
    var stack: std.ArrayList(Frame) = .empty;
    var t = json.Tokenizer.init(text, dialect);
    while (t.next()) |tok| {
        switch (tok.kind) {
            .object_begin => try stack.append(arena, .{ .object = true, .want_key = true, .keys = .init(arena) }),
            .array_begin => try stack.append(arena, .{ .object = false, .want_key = false, .keys = .init(arena) }),
            .object_end, .array_end => _ = stack.pop(),
            .comma => if (stack.items.len > 0) {
                const top = &stack.items[stack.items.len - 1];
                if (top.object) top.want_key = true;
            },
            .string => if (stack.items.len > 0) {
                const top = &stack.items[stack.items.len - 1];
                if (top.object and top.want_key) {
                    top.want_key = false;
                    const slice = text[@intCast(tok.span.start)..@intCast(tok.span.end)];
                    const decoded = json.parse(arena, slice, .{}) catch continue;
                    if (decoded != .string) continue;
                    const gop = try top.keys.getOrPut(decoded.string);
                    if (gop.found_existing) return .{ .key = decoded.string, .offset = @intCast(tok.span.start) };
                }
            },
            else => {},
        }
    }
    return null;
}

const testing = std.testing;

fn failureText(format: Format, text: []const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    var d: interp.Diag = .{};
    checkLayer(arena.allocator(), format, text, "src/s.json", &.{}, &d) catch |e| switch (e) {
        error.FormatViolation => {
            const out = try testing.allocator.dupe(u8, d.capture().?);
            arena.deinit();
            return out;
        },
        else => return e,
    };
    arena.deinit();
    return null;
}

fn expectFailure(format: Format, text: []const u8, want: []const []const u8) !void {
    const got = (try failureText(format, text)) orelse return error.TestExpectedFailure;
    defer testing.allocator.free(got);
    for (want) |w| {
        if (std.mem.indexOf(u8, got, w) == null) {
            std.debug.print("missing \"{s}\" in \"{s}\"\n", .{ w, got });
            return error.TestExpectedSubstring;
        }
    }
}

test "strict JSON: a directive head is refused naming its attributes key" {
    try expectFailure(.json, "// mox: disown a\n{\"a\": 1}\n", &.{ "src/s.json:1:1:", "mox directive \"disown\"", "disown = [\"...\"]", ".mox/attributes.toml" });
}

test "strict JSON: each directive kind names its replacement" {
    try expectFailure(.json, "// mox: own a\n{}\n", &.{"own = [\"...\"]"});
    try expectFailure(.json, "// mox: check \"x\"\n{}\n", &.{"check = [\"...\"]"});
    try expectFailure(.json, "// mox: when os=darwin\n{}\n", &.{"when = \"<axis-expr>\""});
    try expectFailure(.json, "{\n// mox: when os=darwin\n\"a\": 1\n// mox: end\n}\n", &.{ "s.json:2:1:", "overlay s.json.d/<axis>.json" });
    try expectFailure(.json, "{\n// mox: include \"x.json\"\n}\n", &.{"overlay s.json.d/<axis>.json"});
    try expectFailure(.json, "{\n// mox: secret \"env:X\"\n}\n", &.{"\"<secret:URI>\" capture inside a JSON string"});
    try expectFailure(.json, "// mox: default profile=\"work\"\n{}\n", &.{"defaults = {"});
    try expectFailure(.json, "// mox: keep-empty\n{}\n", &.{"never omitted when empty"});
}

test "strict JSON: a string spelling // mox: is content" {
    try testing.expect((try failureText(.json, "{\"desc\": \"// mox: own x\"}\n")) == null);
}

test "strict JSON: each hint by cause" {
    try expectFailure(.json, "{\n  \"a\": 1 // note\n}\n", &.{ "s.json:2:10:", "comments not allowed", "set format = \"jsonc\"" });
    try expectFailure(.json, "{ \"b\": 1, }\n", &.{ "s.json:1:11:", "trailing comma", "remove the trailing comma" });
    try expectFailure(.json, "", &.{ "s.json:1:1:", "write {}" });
    try expectFailure(.jsonc, "  \n", &.{"write {}"});
    try expectFailure(.json, "{\"port\": <data.u.port>}\n", &.{"quote it: a quoted single data capture emits its typed value"});
    try expectFailure(.json, "{\"h\": <machine.home>}\n", &.{"; quote it"});
}

test "jsonc: comments and a trailing comma parse; head directives are comments" {
    try testing.expect((try failureText(.jsonc, "// mox: own a\n{\n  \"a\": 1, // x\n}\n")) == null);
}

test "checkLayer: a line of the stripped text names the line the source has it on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: interp.Diag = .{};
    // Lines 1 and 2 of the source were stripped; the error on stripped line
    // 2 is source line 4.
    try testing.expectError(error.FormatViolation, checkLayer(arena.allocator(), .toml, "[a]\nk = = 1\n", "src/x.toml", &.{ 1, 2 }, &d));
    try testing.expect(std.mem.startsWith(u8, d.capture().?, "src/x.toml:4:"));
}

test "checkOutput: names the output line and the layers, and never quotes a secret line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: interp.Diag = .{};
    try testing.expectError(error.FormatViolation, checkOutput(a, .toml, "a = 1\nb = hunter2\n", &.{ "src/x.toml", "src/x.toml.d/os=darwin.toml" }, &.{}, &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "composed output line 2 from src/x.toml and src/x.toml.d/os=darwin.toml: ") != null);

    var s: interp.Diag = .{};
    try testing.expectError(error.FormatViolation, checkOutput(a, .json, "{\n\"t\": hunter2\n}\n", &.{"src/x.json"}, &.{ false, true, false }, &s));
    try testing.expectEqualStrings("composed output line 2 from src/x.json: <redacted>", s.capture().?);
}

test "duplicateKey: finds a repeat within one object only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a", (try duplicateKey(a, .json, "{\"a\": 1, \"b\": {\"a\": 2}, \"\\u0061\": 3}")).?.key);
    try testing.expect((try duplicateKey(a, .json, "{\"a\": 1, \"b\": {\"a\": 2}}")) == null);
    try testing.expect((try duplicateKey(a, .json, "[{\"a\": 1}, {\"a\": 2}]")) == null);
}

test "every format reports a layer with a line" {
    try expectFailure(.yaml, "a: [\n", &.{"src/s.json:"});
    try expectFailure(.ini, "[a\n", &.{"src/s.json:1:"});
    try expectFailure(.gitconfig, "x = 1\n[a]\n", &.{"src/s.json:1:"});
    try testing.expect((try failureText(.yaml, "")) == null);
    try testing.expect((try failureText(.yaml, "a: 1\n---\nb: 2\n")) == null);
    try testing.expect((try failureText(.ini, "[mysqld]\nskip-networking\n")) == null);
    try testing.expect((try failureText(.toml, "")) == null);
}
