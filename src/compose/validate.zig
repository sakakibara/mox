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
const dsl = @import("../dsl/root.zig");
const interp = @import("interp.zig");

const Format = source.format.Format;

pub const Error = error{ FormatViolation, OutOfMemory };

const comment_hint = "remove the comment, or set format = \"jsonc\" for this file in .mox/attributes.toml if the program reads comments";
const trailing_comma_hint = "remove the trailing comma";
const empty_hint = "an empty file is not JSON: write {}";
const data_capture_hint = "quote it: a quoted single data capture emits its typed value";
const capture_hint = "quote it";
const bom_hint = "strip the byte order mark at the start of the file";
/// One parse failure: 1-based line and column in the checked text, the
/// parser's message, and a hint by cause.
const Failure = struct {
    line: u32,
    col: u32,
    message: []const u8,
    hint: ?[]const u8 = null,
    /// The parser's error, which names its kind without quoting the text.
    err: anyerror = error.ParseError,
    /// For a duplicate key, the key as the text spells it.
    dup_key: ?[]const u8 = null,
    /// The hint quotes the text (a directive's arguments).
    hint_quotes: bool = false,
};

/// Check one layer as written. `display` names it; `removed` maps a line of
/// the checked text back to the line the source file has it on (the base's
/// stripped head lines). A layer holds no resolved secret.
pub fn checkLayer(
    arena: std.mem.Allocator,
    format: Format,
    text: []const u8,
    display: []const u8,
    key: []const u8,
    removed: []const u32,
    diag: ?*interp.Diag,
) Error!void {
    const f = (try firstFailure(arena, format, text, display, key)) orelse return;
    const line = source.head.sourceLine(removed, f.line);
    return report(arena, diag, try std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ display, line, f.col }), try reason(arena, format, f, false), f.hint);
}

/// `checkLayer` for a merge layer whose captures were expanded: `lines` maps
/// each line of `text` to the layer's own (empty when they are the same),
/// and when a secret resolved into it the report is fixed text.
pub fn checkExpandedLayer(
    arena: std.mem.Allocator,
    format: Format,
    text: []const u8,
    display: []const u8,
    lines: []const u32,
    removed: []const u32,
    has_secret: bool,
    diag: ?*interp.Diag,
) Error!void {
    const f = (try firstFailure(arena, format, text, display, "")) orelse return;
    const own = if (f.line >= 1 and f.line <= lines.len) lines[f.line - 1] else f.line;
    const line = source.head.sourceLine(removed, own);
    return report(arena, diag, try std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ display, line, f.col }), try reason(arena, format, f, has_secret), shownHint(f, has_secret));
}

/// Why a live file `display` names does not parse in `format`, as
/// `<display>:<line>:<col>: <reason>[; <hint>]`, or null when it parses. A
/// live file is the user's data and may hold secrets mox never wrote, so the
/// reason is fixed text: no byte of the file is printed.
pub fn liveFailure(arena: std.mem.Allocator, format: Format, text: []const u8, display: []const u8) !?[]const u8 {
    const f = (try firstFailure(arena, format, text, display, "")) orelse return null;
    const why = try reason(arena, format, f, true);
    const hint = shownHint(f, true);
    if (hint) |h| return try std.fmt.allocPrint(arena, "{s}:{d}:{d}: {s}; {s}", .{ display, f.line, f.col, why, h });
    return try std.fmt.allocPrint(arena, "{s}:{d}:{d}: {s}", .{ display, f.line, f.col, why });
}

/// Check a composed output. `layers` names the layers it came from;
/// `has_secret` says a secret was resolved into it, so the report carries
/// fixed text only.
pub fn checkOutput(
    arena: std.mem.Allocator,
    format: Format,
    bytes: []const u8,
    layers: []const []const u8,
    has_secret: bool,
    diag: ?*interp.Diag,
) Error!void {
    return checkOutputFor(arena, format, bytes, layers, has_secret, "", diag);
}

/// `checkOutput` for the target `key`, which a hint names.
pub fn checkOutputFor(
    arena: std.mem.Allocator,
    format: Format,
    bytes: []const u8,
    layers: []const []const u8,
    has_secret: bool,
    key: []const u8,
    diag: ?*interp.Diag,
) Error!void {
    const f = (try firstFailure(arena, format, bytes, "", key)) orelse return;
    const loc = try std.fmt.allocPrint(arena, "composed output line {d} from {s}", .{ f.line, try layerList(arena, layers) });
    return report(arena, diag, loc, try reason(arena, format, f, has_secret), shownHint(f, has_secret));
}

/// A duplicate object key in a JSON-family document, reported against
/// `display` (a layer, or the composed output when `layers` is non-empty).
pub fn checkDuplicateKeys(
    arena: std.mem.Allocator,
    format: Format,
    bytes: []const u8,
    display: []const u8,
    layers: []const []const u8,
    has_secret: bool,
    diag: ?*interp.Diag,
) Error!void {
    return checkDuplicateKeysAmong(arena, format, bytes, display, layers, has_secret, null, diag);
}

/// `checkDuplicateKeys`, reporting only a duplicate of a key in `only` when
/// set: the keys a key capture made.
pub fn checkDuplicateKeysAmong(
    arena: std.mem.Allocator,
    format: Format,
    bytes: []const u8,
    display: []const u8,
    layers: []const []const u8,
    has_secret: bool,
    only: ?*const std.StringHashMap(void),
    diag: ?*interp.Diag,
) Error!void {
    const hit = (try duplicateKeyAmong(arena, format.jsonDialect(), bytes, only)) orelse return;
    const lc = lineCol(bytes, hit.offset);
    const loc = if (layers.len > 0)
        try std.fmt.allocPrint(arena, "composed output line {d} from {s}", .{ lc.line, try layerList(arena, layers) })
    else
        try std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ display, lc.line, lc.col });
    return report(arena, diag, loc, try dupReason(arena, hit.key, has_secret), null);
}

/// The reason a report gives for `f`: the parser's message, a duplicate
/// key as a JSON string, or with `has_secret` fixed text alone.
fn reason(arena: std.mem.Allocator, format: Format, f: Failure, has_secret: bool) ![]const u8 {
    if (f.dup_key) |k| return dupReason(arena, k, has_secret);
    if (!has_secret) return f.message;
    if (std.mem.startsWith(u8, f.message, "duplicate")) return "duplicate key <redacted>";
    if (format == .ini or format == .gitconfig) return errorWords(arena, f.err);
    return std.fmt.allocPrint(arena, "does not parse as {s}", .{@tagName(format)});
}

fn dupReason(arena: std.mem.Allocator, key: []const u8, has_secret: bool) ![]const u8 {
    if (has_secret) return "duplicate key <redacted>";
    return std.fmt.allocPrint(arena, "duplicate key {s}", .{try quoteKey(arena, key)});
}

fn shownHint(f: Failure, has_secret: bool) ?[]const u8 {
    return if (has_secret and f.hint_quotes) null else f.hint;
}

/// A parser error's name as words: `ExpectedAssignment` -> "expected
/// assignment". The name is the parser's, never the text's.
fn errorWords(arena: std.mem.Allocator, err: anyerror) ![]const u8 {
    const name = @errorName(err);
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0) try out.append(arena, ' ');
            try out.append(arena, std.ascii.toLower(c));
        } else try out.append(arena, c);
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
fn firstFailure(arena: std.mem.Allocator, format: Format, text: []const u8, display: []const u8, key: []const u8) !?Failure {
    var f = (try parserFailure(arena, format, text, display, key)) orelse return null;
    if (f.hint == null and std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) f.hint = bom_hint;
    return f;
}

fn parserFailure(arena: std.mem.Allocator, format: Format, text: []const u8, display: []const u8, key: []const u8) !?Failure {
    return switch (format) {
        .json, .jsonc => jsonFailure(arena, format, text, display, key),
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
            var spans: yaml.Spans = .empty;
            const docs = yaml.parseStream(arena, text, .{ .errors = &errs, .spans = &spans }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blk try fromSpan(text, errs.items, e),
            };
            // YAML requires a mapping's keys to be unique; the parser keeps
            // a repeat, so it is found here.
            for (docs) |doc| {
                if (try yamlDuplicate(arena, doc, "")) |dup| {
                    const at: usize = if (spans.get(dup.path)) |sp| @min(@as(usize, @intCast(sp.start)), text.len) else 0;
                    const lc = lineCol(text, lineOffset(text, lineCol(text, at).line));
                    break :blk .{ .line = lc.line, .col = 1, .message = "duplicate key", .dup_key = dup.key };
                }
            }
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
    if (diags.len == 0) return .{ .line = 1, .col = 1, .message = @errorName(e), .err = e };
    const d = diags[0];
    const start: usize = @min(@as(usize, @intCast(d.span.start)), text.len);
    const end: usize = @min(@as(usize, @intCast(d.span.end)), text.len);
    const lc = lineCol(text, start);
    var f: Failure = .{ .line = lc.line, .col = lc.col, .message = d.message, .err = e };
    if (std.mem.startsWith(u8, d.message, "duplicate key") and end > start) f.dup_key = unquoteKey(text[start..end]);
    return f;
}

const YamlDup = struct { key: []const u8, path: []const u8 };

/// The first string key a YAML mapping repeats, with the dotted path of its
/// value, or null.
/// True when a YAML value repeats a key in one of its mappings.
pub fn yamlRepeatsKey(arena: std.mem.Allocator, v: yaml.Value) !bool {
    return (try yamlDuplicate(arena, v, "")) != null;
}

fn yamlDuplicate(arena: std.mem.Allocator, v: yaml.Value, path: []const u8) !?YamlDup {
    switch (v) {
        .map => |entries| {
            var seen = std.StringHashMap(void).init(arena);
            for (entries) |e| {
                if (e.key != .string) continue;
                const child = if (path.len == 0) e.key.string else try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, e.key.string });
                if ((try seen.getOrPut(e.key.string)).found_existing) return .{ .key = e.key.string, .path = child };
                if (try yamlDuplicate(arena, e.value, child)) |d| return d;
            }
        },
        .seq => |items| for (items, 0..) |item, i| {
            if (try yamlDuplicate(arena, item, try std.fmt.allocPrint(arena, "{s}[{d}]", .{ path, i }))) |d| return d;
        },
        else => {},
    }
    return null;
}

/// The offset of the last comma token before `end`, by the tokenizer, so a
/// comma inside a string or comment is not one.
fn lastCommaToken(text: []const u8, dialect: json.Dialect, end: usize) ?usize {
    var t = json.Tokenizer.init(text, dialect);
    var last: ?usize = null;
    while (t.next()) |tok| {
        const s: usize = @intCast(tok.span.start);
        if (s >= end) break;
        if (tok.kind == .comma) last = s;
    }
    return last;
}

/// A key token without its TOML/YAML/INI quotes.
fn unquoteKey(tok: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, tok, " \t");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'')) {
        if (std.mem.indexOfScalarPos(u8, t, 1, t[0])) |close| return t[1..close];
    }
    return t[0 .. std.mem.indexOfAny(u8, t, " \t=:") orelse t.len];
}

/// Byte offset where 1-based `line` starts.
fn lineOffset(text: []const u8, line: u32) usize {
    var n: u32 = 1;
    for (text, 0..) |c, i| {
        if (n == line) return i;
        if (c == '\n') n += 1;
    }
    return text.len;
}

fn jsonFailure(arena: std.mem.Allocator, format: Format, text: []const u8, display: []const u8, key: []const u8) !?Failure {
    if (format == .json) {
        if (try directiveRefusal(arena, text, display, key)) |f| return f;
    }
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        return .{ .line = 1, .col = 1, .message = "unexpected end of input", .hint = empty_hint };
    }
    var errs: std.ArrayList(json.Diagnostic) = .empty;
    _ = json.parse(arena, text, .{ .dialect = format.jsonDialect(), .errors = &errs }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (errs.items.len == 0) return .{ .line = 1, .col = 1, .message = @errorName(e), .err = e };
            const d = errs.items[0];
            var start: usize = @min(@as(usize, @intCast(d.span.start)), text.len);
            const at: u8 = if (start < text.len) text[start] else 0;
            const trailing = std.mem.indexOf(u8, d.message, "trailing comma") != null;
            // The parser stops at the closing bracket; the comma is the error.
            if (trailing) {
                if (lastCommaToken(text, format.jsonDialect(), start)) |comma| start = comma;
            }
            const lc = lineCol(text, start);
            var f: Failure = .{ .line = lc.line, .col = lc.col, .message = d.message, .err = e };
            if (at == '/' and format == .json) {
                f.hint = if (key.len > 0) try std.fmt.allocPrint(arena, "remove the comment, or set format = \"jsonc\" for [{s}] in .mox/attributes.toml if the program reads comments", .{try quoteKey(arena, key)}) else comment_hint;
            } else if (trailing) {
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
/// merely spells `// mox:` is content. When the first one is a head
/// directive, the hint is every head directive of the layer as one
/// attributes entry for `key`, ready to paste.
fn directiveRefusal(arena: std.mem.Allocator, text: []const u8, display: []const u8, key: []const u8) !?Failure {
    var t = json.Tokenizer.init(text, .jsonc);
    var seen_value = false;
    var first: ?struct { verb: []const u8, start: usize, leading: bool } = null;
    var has_end = false;
    var own: std.ArrayList([]const u8) = .empty;
    var disown: std.ArrayList([]const u8) = .empty;
    var check: ?[]const []const u8 = null;
    var gate: ?[]const u8 = null;
    var defaults: std.ArrayList(source.attributes.Default) = .empty;
    var generator = false;
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
        const rest = std.mem.trim(u8, args[verb_end..], " \t");
        if (std.mem.eql(u8, verb, "end")) has_end = true;
        if (std.mem.eql(u8, verb, "for") and std.mem.indexOf(u8, rest, " into \"") != null) generator = true;
        if (first == null) first = .{ .verb = verb, .start = start, .leading = !seen_value };
        if (std.mem.eql(u8, verb, "own")) {
            try own.append(arena, rest);
        } else if (std.mem.eql(u8, verb, "disown")) {
            try disown.append(arena, rest);
        } else if (std.mem.eql(u8, verb, "check")) {
            check = source.head.parseQuotedArgv(arena, rest) catch null;
        } else if (std.mem.eql(u8, verb, "default")) {
            const d = dsl.parser.parseLineDirective(arena, args, 0) catch continue;
            if (d.kind == .default) try defaults.append(arena, .{ .name = d.kind.default.name, .value = d.kind.default.value });
        } else if (std.mem.eql(u8, verb, "when") and !seen_value and gate == null) {
            gate = rest;
        }
    }
    const hit = first orelse return null;
    const lc = lineCol(text, hit.start);
    const v = hit.verb;
    const head_verb = eqAny(v, &.{ "own", "disown", "check", "default" }) or (std.mem.eql(u8, v, "when") and hit.leading and !has_end);
    // A generator with anything beside its loop is judged as the generator
    // it was meant to be, whatever line is first.
    const hint: []const u8 = if (generator)
        generator_hint
    else if (head_verb) blk: {
        const where = try attributesWhere(arena, display, key);
        var entry: std.ArrayList(u8) = .empty;
        try entry.print(arena, "declare it in {s} as below and remove the comments\n{s}", .{ where.file, where.table });
        if (own.items.len > 0) try entry.print(arena, "\nown = {s}", .{try tomlArray(arena, own.items)});
        if (disown.items.len > 0) try entry.print(arena, "\ndisown = {s}", .{try tomlArray(arena, disown.items)});
        if (check) |argv| try entry.print(arena, "\ncheck = {s}", .{try tomlArray(arena, argv)});
        if (!has_end) if (gate) |g| try entry.print(arena, "\nwhen = {s}", .{try tomlString(arena, g)});
        if (defaults.items.len > 0) try entry.print(arena, "\ndefaults = {s}", .{try tomlDefaults(arena, defaults.items)});
        break :blk try entry.toOwnedSlice(arena);
    } else if (std.mem.eql(u8, v, "secret"))
        "use a \"<secret:URI>\" capture inside a JSON string instead"
    else if (std.mem.eql(u8, v, "keep-empty"))
        "remove it: a structured file is never omitted when empty"
    else if (eqAny(v, &.{ "when", "include", "replace", "append", "prepend", "remove", "from", "for", "end" }))
        try std.fmt.allocPrint(arena, "vary the file with an overlay {s}.d/<axis>.json instead", .{std.fs.path.basenamePosix(if (key.len > 0) key else display)})
    else
        comment_hint;
    const message = try std.fmt.allocPrint(arena, "mox directive \"{s}\" in strict JSON, which has no comments", .{v});
    return .{ .line = lc.line, .col = lc.col, .message = message, .hint = hint, .hint_quotes = true };
}

/// A generator template that is not one because something stands outside
/// its loop: the loop's own clauses and its body are where it varies.
const generator_hint = "a generator source holds only its `for ... into` loop: move anything else into its body, and gate it with the loop's own `when` or a `when` nested in the body";

const Where = struct { file: []const u8, table: []const u8 };

/// The attributes file and table header the target `key` of a layer named
/// `display` (`src/` or `private/` first) is declared in.
fn attributesWhere(arena: std.mem.Allocator, display: []const u8, key: []const u8) !Where {
    const private = std.mem.startsWith(u8, display, "private/");
    return .{
        .file = if (private) "the private layer's .mox/attributes.toml" else ".mox/attributes.toml",
        .table = try std.fmt.allocPrint(arena, "[{s}]", .{try tomlString(arena, if (key.len > 0) key else "<target>")}),
    };
}

/// A TOML basic string holding `s`.
fn tomlString(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    return quoteKey(arena, s);
}

/// The TOML array of `items`, each a basic string.
fn tomlArray(arena: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (items) |item| try parts.append(arena, try tomlString(arena, item));
    return std.fmt.allocPrint(arena, "[{s}]", .{try std.mem.join(arena, ", ", parts.items)});
}

/// The TOML inline table of `default` directives, each read by the DSL's
/// own parser.
fn tomlDefaults(arena: std.mem.Allocator, items: []const source.attributes.Default) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (items) |d| try parts.append(arena, try std.fmt.allocPrint(arena, "{s} = {s}", .{ d.name, try tomlString(arena, d.value) }));
    return std.fmt.allocPrint(arena, "{{ {s} }}", .{try std.mem.join(arena, ", ", parts.items)});
}

/// A report as printed: its first line goes inside `ERROR <file> (...)`,
/// and any further lines (a pasteable attributes entry) follow it.
pub const Printed = struct { head: []const u8, more: []const u8 };

pub fn splitReport(text: []const u8) Printed {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return .{ .head = text, .more = "" };
    return .{ .head = text[0..nl], .more = text[nl + 1 ..] };
}

/// The lines after a report's first, indented under its ERROR row.
pub fn writeMore(w: *std.Io.Writer, more: []const u8) !void {
    if (more.len == 0) return;
    var lines = std.mem.splitScalar(u8, more, '\n');
    while (lines.next()) |line| try w.print("      {s}\n", .{line});
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
    return duplicateKeyAmong(arena, dialect, text, null);
}

fn duplicateKeyAmong(arena: std.mem.Allocator, dialect: json.Dialect, text: []const u8, only: ?*const std.StringHashMap(void)) !?DupHit {
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
                    if (gop.found_existing) {
                        const counts = if (only) |o| o.contains(decoded.string) else true;
                        if (counts) return .{ .key = decoded.string, .offset = @intCast(tok.span.start), .first_offset = gop.value_ptr.* };
                    }
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
    checkLayer(arena.allocator(), format, text, "src/s.json", "s.json", &.{}, &d) catch |e| switch (e) {
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
    try expectFailure(.json, "// mox: disown a\n{\"a\": 1}\n", &.{ "src/s.json:1:1:", "mox directive \"disown\"", "declare it in .mox/attributes.toml as below and remove the comments\n[\"s.json\"]\ndisown = [\"a\"]" });
}

test "strict JSON: anything beside a generator loop is advised toward the loop" {
    try expectFailure(.json, "// mox: when os=darwin\n// mox: for id in \"data/ids.toml\" into \"id-<id.slug>.json\"\n{}\n// mox: end\n", &.{ "s.json:1:1:", "a generator source holds only its `for ... into` loop" });
    try expectFailure(.json, "{}\n// mox: for id in \"data/ids.toml\" into \"id-<id.slug>.json\"\n{}\n// mox: end\n", &.{"a generator source holds only its `for ... into` loop"});
    try expectFailure(.json, "// a comment\n// mox: for id in \"data/ids.toml\" into \"id-<id.slug>.json\"\n{}\n// mox: end\n", &.{"a generator source holds only its `for ... into` loop"});
    try expectFailure(.json, "// mox: for id in \"data/ids.toml\" into \"id-<id.slug>.json\"\n{}\n// mox: end\n// mox: keep-empty\n", &.{"a generator source holds only its `for ... into` loop"});
}

test "strict JSON: each directive kind names its replacement" {
    try expectFailure(.json, "// mox: own a\n// mox: own b.c\n// mox: check \"x\" \"say \\\"hi\\\"\"\n// mox: when os=darwin\n// mox: default profile=\"work\"\n{}\n", &.{"[\"s.json\"]\nown = [\"a\", \"b.c\"]\ncheck = [\"x\", \"say \\\"hi\\\"\"]\nwhen = \"os=darwin\"\ndefaults = { profile = \"work\" }"});
    try expectFailure(.json, "// mox: when os=darwin\n{}\n", &.{"\n[\"s.json\"]\nwhen = \"os=darwin\""});
    try expectFailure(.json, "{\n// mox: when os=darwin\n\"a\": 1\n// mox: end\n}\n", &.{ "s.json:2:1:", "overlay s.json.d/<axis>.json" });
    try expectFailure(.json, "{\n// mox: include \"x.json\"\n}\n", &.{"overlay s.json.d/<axis>.json"});
    try expectFailure(.json, "{\n// mox: secret \"env:X\"\n}\n", &.{"\"<secret:URI>\" capture inside a JSON string"});
    try expectFailure(.json, "// mox: default profile=\"work\"\n{}\n", &.{"\n[\"s.json\"]\ndefaults = { profile = \"work\" }"});
    try expectFailure(.json, "// mox: default motto=\"a b\"\n{}\n", &.{"defaults = { motto = \"a b\" }"});
    // A line the DSL cannot read gives no entry, rather than a guessed one.
    const bad = (try failureText(.json, "// mox: default g=\"x\" junk\n{}\n")).?;
    defer testing.allocator.free(bad);
    try testing.expect(std.mem.indexOf(u8, bad, "defaults =") == null);
    try expectFailure(.json, "// mox: keep-empty\n{}\n", &.{"never omitted when empty"});
}

test "strict JSON: a string spelling // mox: is content" {
    try testing.expect((try failureText(.json, "{\"desc\": \"// mox: own x\"}\n")) == null);
}

test "strict JSON: each hint by cause" {
    try expectFailure(.json, "{\n  \"a\": 1 // note\n}\n", &.{ "s.json:2:10:", "comments not allowed", "set format = \"jsonc\"" });
    try expectFailure(.json, "{ \"b\": 1, }\n", &.{ "s.json:1:9:", "trailing comma", "remove the trailing comma" });
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
    try testing.expectError(error.FormatViolation, checkLayer(arena.allocator(), .toml, "[a]\nk = = 1\n", "src/x.toml", "x.toml", &.{ 1, 2 }, &d));
    try testing.expect(std.mem.startsWith(u8, d.capture().?, "src/x.toml:4:"));
}

test "checkOutput: names the output line and the layers, and never quotes a secret line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: interp.Diag = .{};
    try testing.expectError(error.FormatViolation, checkOutput(a, .toml, "a = 1\nb = hunter2\n", &.{ "src/x.toml", "src/x.toml.d/os=darwin.toml" }, false, &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "composed output line 2 from src/x.toml and src/x.toml.d/os=darwin.toml: ") != null);

    var s: interp.Diag = .{};
    try testing.expectError(error.FormatViolation, checkOutput(a, .json, "{\n\"t\": hunter2\n}\n", &.{"src/x.json"}, true, &s));
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
        try testing.expectError(error.FormatViolation, checkOutput(a, c.f, c.text, &.{"x"}, false, &d));
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

test "quoteKey, errorWords and a reason with a secret" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("\"a\\n\\\"b\\u0001\"", try quoteKey(a, "a\n\"b\x01"));
    try testing.expectEqualStrings("expected assignment", try errorWords(a, error.ExpectedAssignment));
    var d: interp.Diag = .{};
    try testing.expectError(error.FormatViolation, checkOutput(a, .toml, "[\"s3cr3t\"]\nx = {a=1}\nx.b = 2\n", &.{"src/t.toml"}, true, &d));
    try testing.expectEqualStrings("composed output line 3 from src/t.toml: does not parse as toml", d.capture().?);
}

test "a byte order mark gets its hint, and a layer's reason is the parser's own" {
    try expectFailure(.json, "\xEF\xBB\xBF{}\n", &.{ "s.json:1:1:", "strip the byte order mark" });
    try expectFailure(.toml, "a = 1\na = 2\n", &.{ "s.json:2:1:", "duplicate key \"a\"" });
}

test "a YAML mapping that repeats a key is refused naming it" {
    try expectFailure(.yaml, "a: 1\nb:\n  c: 1\n  c: 2\n", &.{ "s.json:4:1:", "duplicate key \"c\"" });
}
