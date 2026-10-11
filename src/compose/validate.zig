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

const comment_hint = "remove it, or set format = \"jsonc\" for this file in .mox/attributes.toml if the program reads comments";
const trailing_comma_hint = "remove the trailing comma";
const empty_hint = "an empty file is not JSON: write {}";
const data_capture_hint = "quote it: a quoted single data capture emits its typed value";
const capture_hint = "quote it";
const merged_capture_hint = "layers merge before captures expand, so a capture in a merged layer must sit inside a string";

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

/// Why a live file `display` names does not parse in `format`, as
/// `<display>:<line>:<col>: <message>[; <hint>]`, or null when it parses.
/// A live file may hold secrets mox wrote, so quoted text is redacted.
pub fn liveFailure(arena: std.mem.Allocator, format: Format, text: []const u8, display: []const u8) !?[]const u8 {
    const f = (try firstFailure(arena, format, text, display)) orelse return null;
    const message = try redactQuoted(arena, f.message);
    if (f.hint) |h| return try std.fmt.allocPrint(arena, "{s}:{d}:{d}: {s}; {s}", .{ display, f.line, f.col, message, h });
    return try std.fmt.allocPrint(arena, "{s}:{d}:{d}: {s}", .{ display, f.line, f.col, message });
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
    const loc = try std.fmt.allocPrint(arena, "composed output line {d} from {s}", .{ f.line, try layerList(arena, layers) });
    const message = if (isSecretLine(secret_lines, f.line)) try redactQuoted(arena, f.message) else f.message;
    return report(arena, diag, loc, message, f.hint);
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
    // Either spelling of the key may be a resolved secret.
    const secret = isSecretLine(secret_lines, lc.line) or isSecretLine(secret_lines, lineCol(bytes, hit.first_offset).line);
    const loc = if (layers.len > 0)
        try std.fmt.allocPrint(arena, "composed output line {d} from {s}", .{ lc.line, try layerList(arena, layers) })
    else
        try std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ display, lc.line, lc.col });
    const message = if (secret) "duplicate key <redacted>" else try std.fmt.allocPrint(arena, "duplicate key {s}", .{try quoteKey(arena, hit.key)});
    return report(arena, diag, loc, message, null);
}

fn isSecretLine(secret_lines: []const bool, line: u32) bool {
    return line >= 1 and line - 1 < secret_lines.len and secret_lines[line - 1];
}

/// `message` with every quoted span replaced by `<redacted>`: a parser
/// quotes the text it stopped at, which on a secret-bearing line may be the
/// secret itself.
fn redactQuoted(arena: std.mem.Allocator, message: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < message.len) {
        const c = message[i];
        if (c == '"' or c == '\'' or c == '`') {
            if (std.mem.indexOfScalarPos(u8, message, i + 1, c)) |end| {
                try out.appendSlice(arena, "<redacted>");
                i = end + 1;
                continue;
            }
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// `key` as a JSON string literal, so a quote or control character in it
/// cannot break the report line.
fn quoteKey(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (key) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try out.print(arena, "\\u{x:0>4}", .{c}),
        else => try out.append(arena, c),
    };
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
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
    const start: usize = @intCast(d.span.start);
    const lc = lineCol(text, start);
    var f: Failure = .{ .line = lc.line, .col = lc.col, .message = d.message };
    if (std.mem.indexOfScalar(u8, lineAt(text, start), '<') != null and interp.containsCapture(lineAt(text, start)))
        f.hint = merged_capture_hint;
    return f;
}

/// The line of `text` holding byte `offset`.
fn lineAt(text: []const u8, offset: usize) []const u8 {
    const at = @min(offset, text.len);
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |i| i + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    return text[start..end];
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
    // The arguments of every directive spelled with the first one's verb,
    // for a hint that can be pasted into the attributes file.
    var args_seen: std.ArrayList([]const u8) = .empty;
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
        if (std.mem.eql(u8, verb, first.?.verb)) try args_seen.append(arena, std.mem.trim(u8, args[verb_end..], " \t"));
    }
    const hit = first orelse return null;
    const lc = lineCol(text, hit.start);
    const v = hit.verb;
    const where = try attributesWhere(arena, display);
    const hint: []const u8 = if (std.mem.eql(u8, v, "own") or std.mem.eql(u8, v, "disown"))
        try std.fmt.allocPrint(arena, "declare it in {s}: {s} {s} = {s}", .{ where.file, where.table, v, try tomlList(arena, args_seen.items, false) })
    else if (std.mem.eql(u8, v, "check"))
        try std.fmt.allocPrint(arena, "declare it in {s}: {s} check = {s}", .{ where.file, where.table, try tomlList(arena, args_seen.items[0..1], true) })
    else if (std.mem.eql(u8, v, "when") and hit.leading and !has_end)
        try std.fmt.allocPrint(arena, "declare the whole-file gate in {s}: {s} when = {s}", .{ where.file, where.table, try tomlString(arena, args_seen.items[0]) })
    else if (std.mem.eql(u8, v, "secret"))
        "use a \"<secret:URI>\" capture inside a JSON string instead"
    else if (std.mem.eql(u8, v, "default"))
        try std.fmt.allocPrint(arena, "declare it in {s}: {s} defaults = {s}", .{ where.file, where.table, try tomlDefaults(arena, args_seen.items) })
    else if (std.mem.eql(u8, v, "keep-empty"))
        "remove it: a structured file is never omitted when empty"
    else if (eqAny(v, &.{ "when", "include", "replace", "append", "prepend", "remove", "from", "for", "end" }))
        try std.fmt.allocPrint(arena, "vary the file with an overlay {s}.d/<axis>.json instead", .{std.fs.path.basenamePosix(display)})
    else
        comment_hint;
    const message = try std.fmt.allocPrint(arena, "mox directive \"{s}\" in strict JSON, which has no comments", .{v});
    return .{ .line = lc.line, .col = lc.col, .message = message, .hint = hint };
}

const Where = struct { file: []const u8, table: []const u8 };

/// The attributes file and table header a layer named `display` (repo- or
/// private-relative, `src/` or `private/` first) declares its target in.
fn attributesWhere(arena: std.mem.Allocator, display: []const u8) !Where {
    const slash = std.mem.indexOfScalar(u8, display, '/') orelse return .{ .file = ".mox/attributes.toml", .table = "[\"<target>\"]" };
    var key = display[slash + 1 ..];
    if (std.mem.indexOf(u8, key, ".d/")) |d| key = key[0..d];
    const private = std.mem.startsWith(u8, display, "private/");
    return .{
        .file = if (private) "the private layer's .mox/attributes.toml" else ".mox/attributes.toml",
        .table = try std.fmt.allocPrint(arena, "[{s}]", .{try tomlString(arena, key)}),
    };
}

/// A TOML basic string holding `s`.
fn tomlString(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    return quoteKey(arena, s);
}

/// The TOML array of `items`: each a directive argument, or with `argv`
/// the double-quoted argv items of one `check` line.
fn tomlList(arena: std.mem.Allocator, items: []const []const u8, argv: bool) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (!argv) {
            try parts.append(arena, try tomlString(arena, item));
            continue;
        }
        var rest = item;
        while (std.mem.indexOfScalar(u8, rest, '"')) |open| {
            const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse break;
            try parts.append(arena, rest[open .. close + 1]);
            rest = rest[close + 1 ..];
        }
    }
    return std.fmt.allocPrint(arena, "[{s}]", .{try std.mem.join(arena, ", ", parts.items)});
}

/// The TOML inline table of `default name="value"` arguments.
fn tomlDefaults(arena: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        const name = std.mem.trim(u8, item[0..eq], " \t");
        const value = std.mem.trim(u8, std.mem.trim(u8, item[eq + 1 ..], " \t"), "\"");
        try parts.append(arena, try std.fmt.allocPrint(arena, "{s} = {s}", .{ name, try tomlString(arena, value) }));
    }
    return std.fmt.allocPrint(arena, "{{ {s} }}", .{try std.mem.join(arena, ", ", parts.items)});
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

pub const DupHit = struct { key: []const u8, offset: usize, first_offset: usize };

/// The first object key that repeats within its object, or null. Keys are
/// compared decoded, so `"a"` and `"\u0061"` are one key.
pub fn duplicateKey(arena: std.mem.Allocator, dialect: json.Dialect, text: []const u8) !?DupHit {
    const Frame = struct { object: bool, want_key: bool, keys: std.StringHashMap(usize) };
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
                    if (gop.found_existing) return .{ .key = decoded.string, .offset = @intCast(tok.span.start), .first_offset = gop.value_ptr.* };
                    gop.value_ptr.* = @intCast(tok.span.start);
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
    try expectFailure(.json, "// mox: disown a\n{\"a\": 1}\n", &.{ "src/s.json:1:1:", "mox directive \"disown\"", "declare it in .mox/attributes.toml: [\"s.json\"] disown = [\"a\"]" });
}

test "strict JSON: each directive kind names its replacement" {
    try expectFailure(.json, "// mox: own a\n// mox: own b.c\n{}\n", &.{"[\"s.json\"] own = [\"a\", \"b.c\"]"});
    try expectFailure(.json, "// mox: check \"x\" \"--y\"\n{}\n", &.{"[\"s.json\"] check = [\"x\", \"--y\"]"});
    try expectFailure(.json, "// mox: when os=darwin\n{}\n", &.{"[\"s.json\"] when = \"os=darwin\""});
    try expectFailure(.json, "{\n// mox: when os=darwin\n\"a\": 1\n// mox: end\n}\n", &.{ "s.json:2:1:", "overlay s.json.d/<axis>.json" });
    try expectFailure(.json, "{\n// mox: include \"x.json\"\n}\n", &.{"overlay s.json.d/<axis>.json"});
    try expectFailure(.json, "{\n// mox: secret \"env:X\"\n}\n", &.{"\"<secret:URI>\" capture inside a JSON string"});
    try expectFailure(.json, "// mox: default profile=\"work\"\n{}\n", &.{"[\"s.json\"] defaults = { profile = \"work\" }"});
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
    try testing.expect(std.mem.startsWith(u8, s.capture().?, "composed output line 2 from src/x.json: "));
    try testing.expect(std.mem.indexOf(u8, s.capture().?, "hunter2") == null);
}

test "checkOutput: every format names the output line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { f: Format, text: []const u8, line: []const u8 }{
        .{ .f = .yaml, .text = "a: 1\nb: c: d\n", .line = "composed output line 2 from x: " },
        .{ .f = .ini, .text = "[s]\nk = 1\n[t\n", .line = "composed output line 3 from x: " },
        .{ .f = .gitconfig, .text = "[user]\n\tname = me\n\tbad key = 1\n", .line = "composed output line 3 from x: " },
        .{ .f = .jsonc, .text = "{\n  \"a\": 1,\n  oops\n}\n", .line = "composed output line 3 from x: " },
    };
    for (cases) |c| {
        var d: interp.Diag = .{};
        try testing.expectError(error.FormatViolation, checkOutput(a, c.f, c.text, &.{"x"}, &.{}, &d));
        try testing.expect(std.mem.startsWith(u8, d.capture().?, c.line));
    }
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

test "redactQuoted and quoteKey" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("unexpected <redacted> after <redacted>", try redactQuoted(a, "unexpected 'x1' after \"y\""));
    try testing.expectEqualStrings("expected value", try redactQuoted(a, "expected value"));
    try testing.expectEqualStrings("\"a\\n\\\"b\\u0001\"", try quoteKey(a, "a\n\"b\x01"));
}
