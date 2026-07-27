//! Config-space interview: walk over `dimensions.discover`'s output instead
//! of a hand-maintained schema file.
//!
//! A dimension is asked when it is unbound (an existing binding, even the
//! empty string, is a persisted decline and is never re-asked) and its
//! `asking_condition` -- the OR of its capture occurrences' enclosing gates,
//! null for a value-compared or presence-only dimension, whose comparison
//! IS the demand -- evaluates true against the bindings accumulated so far
//! this run (axes, existing facts, and earlier answers in the same walk).
//! Dimensions are asked in FIXPOINT waves: everything eligible right now is
//! asked, then the walk re-evaluates every remaining dimension's condition
//! against the freshly widened bindings and asks whatever that newly
//! exposed, repeating until nothing more becomes eligible. This is how a
//! personal/icloud machine's answers never expose `gdrive_account` or a
//! work-profile-gated fact, while a work answer exposes them in the same
//! run. Within one wave, dimensions are asked in name order.
//!
//! Each prompt shows an advisory choice list (`observed_values`, `
//! capture_defaults`, and `declared_defaults`, unioned and sorted -- free
//! text is always still accepted), a default when every declared/capture
//! default for the name agrees on one value, and one provenance line (the
//! source count, plus any scripts that consume it). A non-empty answer to a
//! value-compared dimension that matches none of its observed values is
//! confirmed once before it binds; declining the confirmation re-asks.
//! Pressing enter takes the default when there is one, and binds the empty
//! string (a decline) when there is not -- declined and legitimately-empty
//! are the same state, never re-asked.

const std = @import("std");
const dsl = @import("../dsl/root.zig");
const state_mod = @import("state.zig");
const dimensions = @import("dimensions.zig");

const Io = std.Io;

const max_facts_bytes: usize = 256 * 1024;

/// One interview run's mode: which of the three answer sources (interactive
/// prompting, silent reporting, or declared-default auto-binding) resolves
/// each eligible dimension.
pub const Mode = union(enum) {
    /// TTY (or scripted-stdin test) run: `askDimension` prompts through
    /// `input`/`out` for every eligible dimension.
    interactive: Interactive,
    /// Non-interactive, or `--dry-run`: nothing is asked or persisted; every
    /// eligible dimension's name is reported in `Outcome.unbound` instead.
    report_only,
    /// `mox apply --defaults`: never prompts; every eligible dimension binds
    /// its agreed default, or the empty string (a decline) when it has none.
    defaults,

    pub const Interactive = struct {
        input: *Io.Reader,
        out: *Io.Writer,
    };
};

pub const Outcome = struct {
    /// Facts resolved this run (interactive answers, or `--defaults`
    /// bindings), in ask order. Includes empty-string declines.
    answers: []const state_mod.Fact = &.{},
    /// Names of dimensions eligible to be asked but left unresolved
    /// (`report_only` mode only), sorted.
    unbound: []const []const u8 = &.{},
};

/// Walk `dims` (typically `dimensions.discover(...).dimensions`) against
/// `base_bindings`, resolving each eligible dimension through `mode`. See
/// the module doc comment for the fixpoint-wave and prompt-content contract.
pub fn walkDimensions(
    arena: std.mem.Allocator,
    dims: []const dimensions.Dimension,
    base_bindings: *const dsl.resolver.Resolver,
    mode: Mode,
) !Outcome {
    if (mode == .report_only) return walkReportOnly(arena, dims, base_bindings);

    var working = std.StringHashMap([]const u8).init(arena);
    var override: dsl.resolver.Resolver.Override = .{ .map = &working, .inner = base_bindings };
    var resolver: dsl.resolver.Resolver = .{ .override = &override };

    var answers: std.ArrayList(state_mod.Fact) = .empty;

    while (true) {
        var wave: std.ArrayList(dimensions.Dimension) = .empty;
        for (dims) |d| {
            if (resolver.lookup(d.name) != null) continue;
            if (d.asking_condition) |cond| {
                if (!dsl.axis.evaluate(cond, &resolver)) continue;
            }
            try wave.append(arena, d);
        }
        if (wave.items.len == 0) break;
        std.mem.sort(dimensions.Dimension, wave.items, {}, dimNameLess);

        for (wave.items) |d| {
            const value = switch (mode) {
                .interactive => |io_pair| try askDimension(arena, d, io_pair.input, io_pair.out),
                .defaults => agreedDefault(d) orelse "",
                .report_only => unreachable,
            };
            try answers.append(arena, .{ .name = d.name, .value = value });
            try working.put(d.name, value);
        }
    }

    return .{ .answers = try answers.toOwnedSlice(arena) };
}

/// The non-interactive/`--dry-run` path: a single pass (nothing is bound, so
/// there is nothing to fixpoint over) naming every dimension eligible to be
/// asked right now against `base_bindings` as-is.
fn walkReportOnly(arena: std.mem.Allocator, dims: []const dimensions.Dimension, base_bindings: *const dsl.resolver.Resolver) !Outcome {
    var names: std.ArrayList([]const u8) = .empty;
    for (dims) |d| {
        if (base_bindings.lookup(d.name) != null) continue;
        if (d.asking_condition) |cond| {
            if (!dsl.axis.evaluate(cond, base_bindings)) continue;
        }
        try names.append(arena, d.name);
    }
    std.mem.sort([]const u8, names.items, {}, lessThanStr);
    return .{ .unbound = try names.toOwnedSlice(arena) };
}

/// Prompt for one dimension: provenance line, then the question line
/// (choices, default), then read and validate an answer. Loops only on a
/// declined keep-anyway confirmation; a blank line (including one produced
/// by a closed/EOF input) always resolves immediately (to the default, or
/// the empty-string decline), so this never hangs or spins on dead input.
fn askDimension(arena: std.mem.Allocator, dim: dimensions.Dimension, input: *Io.Reader, out: *Io.Writer) ![]const u8 {
    const choices = try choiceList(arena, dim);
    const default = agreedDefault(dim);

    try printProvenance(out, dim);
    try printPrompt(arena, out, dim.name, choices, default);
    try out.flush();

    while (true) {
        const line = try input.takeDelimiter('\n');
        const trimmed = std.mem.trim(u8, line orelse "", " \t\r");
        if (trimmed.len == 0) return default orelse "";

        if (dim.roles.value_compared and dim.observed_values.len > 0 and !containsStr(dim.observed_values, trimmed)) {
            const answer = try arena.dupe(u8, trimmed);
            if (try confirmKeepAnyway(arena, dim.name, answer, dim.observed_values, input, out)) return answer;
            try printPrompt(arena, out, dim.name, choices, default);
            try out.flush();
            continue;
        }
        return try arena.dupe(u8, trimmed);
    }
}

/// One keep-anyway confirmation for a value-compared answer outside its
/// observed set. Any answer not starting with `y`/`Y` (including a blank or
/// closed-input line) declines.
fn confirmKeepAnyway(
    arena: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    observed: []const []const u8,
    input: *Io.Reader,
    out: *Io.Writer,
) !bool {
    const joined = try std.mem.join(arena, ", ", observed);
    try out.print("\"{s}\" is not among {s}'s observed values ({s}) -- keep anyway? [y/N]: ", .{ value, name, joined });
    try out.flush();
    const line = try input.takeDelimiter('\n');
    const trimmed = std.mem.trim(u8, line orelse "", " \t\r");
    return trimmed.len > 0 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
}

fn printProvenance(out: *Io.Writer, dim: dimensions.Dimension) !void {
    try out.print("  ({d} source{s}", .{
        dim.provenance.source_count,
        if (dim.provenance.source_count == 1) "" else "s",
    });
    if (dim.provenance.needing_scripts.len > 0) {
        try out.writeAll(", needs:");
        for (dim.provenance.needing_scripts) |s| try out.print(" {s}", .{s});
    }
    try out.writeAll(")\n");
}

fn printPrompt(arena: std.mem.Allocator, out: *Io.Writer, name: []const u8, choices: []const []const u8, default: ?[]const u8) !void {
    try out.print("{s}", .{name});
    if (choices.len > 0) {
        const joined = try std.mem.join(arena, ", ", choices);
        try out.print(" ({s})", .{joined});
    }
    if (default) |d| try out.print(" [{s}]", .{d});
    try out.writeAll(": ");
}

/// `observed_values` UNION `capture_defaults` UNION `declared_defaults`,
/// sorted and deduped: the advisory choice list a prompt shows.
fn choiceList(arena: std.mem.Allocator, dim: dimensions.Dimension) ![]const []const u8 {
    var set = std.StringHashMap(void).init(arena);
    for (dim.observed_values) |v| try set.put(v, {});
    for (dim.capture_defaults) |v| try set.put(v, {});
    for (dim.declared_defaults) |v| try set.put(v, {});
    var out: std.ArrayList([]const u8) = .empty;
    var it = set.keyIterator();
    while (it.next()) |k| try out.append(arena, k.*);
    const slice = try out.toOwnedSlice(arena);
    std.mem.sort([]const u8, slice, {}, lessThanStr);
    return slice;
}

/// The interview default: the single value every `capture_defaults` and
/// `declared_defaults` entry agrees on, or null when there is none (no
/// defaults at all, or more than one distinct value among them).
fn agreedDefault(dim: dimensions.Dimension) ?[]const u8 {
    var first: ?[]const u8 = null;
    for (dim.capture_defaults) |v| {
        if (first) |f| {
            if (!std.mem.eql(u8, f, v)) return null;
        } else first = v;
    }
    for (dim.declared_defaults) |v| {
        if (first) |f| {
            if (!std.mem.eql(u8, f, v)) return null;
        } else first = v;
    }
    return first;
}

/// One stderr notice for `Outcome.unbound`: shared text between `mox apply`
/// (`prefix = "mox apply: "`) and bare `mox facts` (`prefix = ""`, matching
/// its own unprefixed messages) so the two callers stay worded identically.
pub fn writeUnboundNotice(out: *Io.Writer, prefix: []const u8, names: []const []const u8) !void {
    if (names.len == 0) return;
    try out.print("{s}unbound facts:", .{prefix});
    for (names) |n| try out.print(" {s}", .{n});
    try out.print("\n{s}Answer interactively (mox apply / mox facts) or set directly (mox facts set <name> <value>).\n", .{prefix});
}

fn dimNameLess(_: void, a: dimensions.Dimension, b: dimensions.Dimension) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, s)) return true;
    }
    return false;
}

/// True when `s` holds a C0 control byte (newline, CR, tab, ...) or DEL. Such
/// a byte in a fact value would inject a line into / break the parse of
/// facts.toml, so it is rejected rather than written raw.
fn hasControlChar(s: []const u8) bool {
    for (s) |ch| {
        if (ch < 0x20 or ch == 0x7f) return true;
    }
    return false;
}

/// True when `name` is a valid fact name: a non-empty TOML bare key
/// (`[A-Za-z0-9_-]`). A name is written UNQUOTED as `name = "..."` and also
/// becomes an axis and a `MOX_FACT_<NAME>` env var, so a space, `=`, `"`, `#`,
/// `[`, or `.` would produce invalid TOML that breaks every later facts load.
fn isValidFactName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return false;
    }
    return true;
}

/// True when `name`/`value` could be written by `persist` without either
/// being refused: see `isValidFactName` and `hasControlChar`. Lets a caller
/// that is ABOUT to route an edit to a fact check first, rather than
/// discover the refusal only once other writes may already be applied.
pub fn canPersist(name: []const u8, value: []const u8) bool {
    return isValidFactName(name) and !hasControlChar(value);
}

/// Persist `answers` into the machine-local facts file, replacing any
/// existing assignments of the same names and preserving everything else
/// (comments included). A name or value carrying a control character is
/// refused (`error.InvalidFactName` / `error.InvalidFactValue`) before any
/// write, so a single bad value cannot corrupt the whole file.
pub fn persist(arena: std.mem.Allocator, io: Io, facts_path: []const u8, answers: []const state_mod.Fact) !void {
    if (answers.len == 0) return;

    for (answers) |ans| {
        if (!isValidFactName(ans.name)) return error.InvalidFactName;
        if (hasControlChar(ans.value)) return error.InvalidFactValue;
    }

    const existing = Io.Dir.cwd().readFileAlloc(io, facts_path, arena, .limited(max_facts_bytes)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };

    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) break;
        if (assignedName(line)) |name| {
            if (findAnswer(answers, name) != null) continue;
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    for (answers) |a| {
        try out.appendSlice(arena, a.name);
        try out.appendSlice(arena, " = \"");
        for (a.value) |c| switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            else => try out.append(arena, c),
        };
        try out.appendSlice(arena, "\"\n");
    }

    if (std.fs.path.dirname(facts_path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = facts_path, .data = out.items });
}

/// Remove `name`'s assignment from the machine-local facts file, leaving
/// everything else (including comments) intact. A missing file, or a name
/// with no assignment, is a no-op. Used to roll a fact write back to "never
/// set" when the name did not exist before it was written.
pub fn remove(arena: std.mem.Allocator, io: Io, facts_path: []const u8, name: []const u8) !void {
    const existing = Io.Dir.cwd().readFileAlloc(io, facts_path, arena, .limited(max_facts_bytes)) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };

    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null and line.len == 0) break;
        if (assignedName(line)) |n| {
            if (std.mem.eql(u8, n, name)) continue;
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = facts_path, .data = out.items });
}

fn assignedName(line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const name = std.mem.trim(u8, line[0..eq], " \t");
    if (name.len == 0 or name[0] == '#') return null;
    return name;
}

fn findAnswer(answers: []const state_mod.Fact, name: []const u8) ?[]const u8 {
    for (answers) |a| {
        if (std.mem.eql(u8, a.name, name)) return a.value;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testDim(name: []const u8, opts: struct {
    value_compared: bool = false,
    presence: bool = false,
    captured: bool = false,
    observed_values: []const []const u8 = &.{},
    capture_defaults: []const []const u8 = &.{},
    declared_defaults: []const []const u8 = &.{},
    asking_condition: ?*const dsl.ast.AxisExpr = null,
    source_count: usize = 1,
    needing_scripts: []const []const u8 = &.{},
}) dimensions.Dimension {
    return .{
        .name = name,
        .roles = .{ .value_compared = opts.value_compared, .presence = opts.presence, .captured = opts.captured },
        .observed_values = opts.observed_values,
        .capture_defaults = opts.capture_defaults,
        .declared_defaults = opts.declared_defaults,
        .asking_condition = opts.asking_condition,
        .provenance = .{ .source_count = opts.source_count, .needing_scripts = opts.needing_scripts },
    };
}

fn eqExpr(arena: std.mem.Allocator, axis: []const u8, value: []const u8) !*const dsl.ast.AxisExpr {
    const e = try arena.create(dsl.ast.AxisExpr);
    e.* = .{ .eq = .{ .axis = axis, .value = value } };
    return e;
}

test "walkDimensions: fixpoint exposure -- a work answer asks the gated dimension in the same run, personal never does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gate = try eqExpr(a, "profile", "work");
    const dims = [_]dimensions.Dimension{
        testDim("onepassword_account", .{ .captured = true, .capture_defaults = &.{}, .asking_condition = gate }),
        testDim("profile", .{ .value_compared = true, .observed_values = &.{"work"}, .capture_defaults = &.{"personal"} }),
    };

    {
        var bindings = std.StringHashMap([]const u8).init(a);
        var live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings };
        var r: dsl.resolver.Resolver = .{ .live = &live };
        var input = Io.Reader.fixed("\n"); // Enter -> takes the "personal" default
        var discard: [4096]u8 = undefined;
        var out: Io.Writer = .fixed(&discard);
        const outcome = try walkDimensions(a, &dims, &r, .{ .interactive = .{ .input = &input, .out = &out } });
        try std.testing.expectEqual(@as(usize, 1), outcome.answers.len);
        try std.testing.expectEqualStrings("profile", outcome.answers[0].name);
        try std.testing.expectEqualStrings("personal", outcome.answers[0].value);
    }
    {
        var bindings = std.StringHashMap([]const u8).init(a);
        var live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings };
        var r: dsl.resolver.Resolver = .{ .live = &live };
        var input = Io.Reader.fixed("work\nteam@example.com\n");
        var out_buf: [4096]u8 = undefined;
        var out: Io.Writer = .fixed(&out_buf);
        const outcome = try walkDimensions(a, &dims, &r, .{ .interactive = .{ .input = &input, .out = &out } });
        try std.testing.expectEqual(@as(usize, 2), outcome.answers.len);
        try std.testing.expectEqualStrings("profile", outcome.answers[0].name);
        try std.testing.expectEqualStrings("work", outcome.answers[0].value);
        try std.testing.expectEqualStrings("onepassword_account", outcome.answers[1].name);
        try std.testing.expectEqualStrings("team@example.com", outcome.answers[1].value);
    }
}

test "walkDimensions: a bound dimension (including bound-empty) is skipped, never asked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dims = [_]dimensions.Dimension{
        testDim("profile", .{ .value_compared = true }),
        testDim("signing_key", .{ .presence = true }),
    };
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("profile", "work");
    try bindings.put("signing_key", ""); // declined
    var live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings };
    var r: dsl.resolver.Resolver = .{ .live = &live };

    const outcome = try walkDimensions(a, &dims, &r, .report_only);
    try std.testing.expectEqual(@as(usize, 0), outcome.unbound.len);
}

test "walkDimensions: report-only lists eligible unbound dimensions, sorted, persists nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gate = try eqExpr(a, "profile", "work");
    const dims = [_]dimensions.Dimension{
        testDim("zzz_fact", .{ .presence = true }),
        testDim("gated_fact", .{ .captured = true, .asking_condition = gate }),
        testDim("aaa_fact", .{ .presence = true }),
    };
    var bindings = std.StringHashMap([]const u8).init(a);
    var live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings };
    var r: dsl.resolver.Resolver = .{ .live = &live };

    const outcome = try walkDimensions(a, &dims, &r, .report_only);
    try std.testing.expectEqual(@as(usize, 2), outcome.unbound.len);
    try std.testing.expectEqualStrings("aaa_fact", outcome.unbound[0]);
    try std.testing.expectEqualStrings("zzz_fact", outcome.unbound[1]);
    try std.testing.expectEqual(@as(usize, 0), outcome.answers.len);
}

test "walkDimensions: --defaults binds the agreed default and declines the rest, never prompts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dims = [_]dimensions.Dimension{
        testDim("holt_backend", .{ .value_compared = true, .observed_values = &.{"gdrive"}, .declared_defaults = &.{"icloud"} }),
        testDim("signing_key", .{ .presence = true }),
    };
    var bindings = std.StringHashMap([]const u8).init(a);
    var live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings };
    var r: dsl.resolver.Resolver = .{ .live = &live };

    const outcome = try walkDimensions(a, &dims, &r, .defaults);
    try std.testing.expectEqual(@as(usize, 2), outcome.answers.len);
    try std.testing.expectEqualStrings("holt_backend", outcome.answers[0].name);
    try std.testing.expectEqualStrings("icloud", outcome.answers[0].value);
    try std.testing.expectEqualStrings("signing_key", outcome.answers[1].name);
    try std.testing.expectEqualStrings("", outcome.answers[1].value);
}

test "askDimension (via walkDimensions): an answer outside the observed set is confirmed once, accepted on 'y'" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dims = [_]dimensions.Dimension{
        testDim("profile", .{ .value_compared = true, .observed_values = &.{ "personal", "work" } }),
    };
    var bindings = std.StringHashMap([]const u8).init(a);
    var live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings };
    var r: dsl.resolver.Resolver = .{ .live = &live };

    var input = Io.Reader.fixed("side-project\ny\n");
    var out_buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    const outcome = try walkDimensions(a, &dims, &r, .{ .interactive = .{ .input = &input, .out = &out } });
    try std.testing.expectEqual(@as(usize, 1), outcome.answers.len);
    try std.testing.expectEqualStrings("side-project", outcome.answers[0].value);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "not among") != null);
}

test "askDimension (via walkDimensions): declining the keep-anyway confirmation re-asks the same dimension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dims = [_]dimensions.Dimension{
        testDim("profile", .{ .value_compared = true, .observed_values = &.{ "personal", "work" } }),
    };
    var bindings = std.StringHashMap([]const u8).init(a);
    var live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings };
    var r: dsl.resolver.Resolver = .{ .live = &live };

    // "typo" is declined at the confirmation, so it re-asks; "work" is then
    // accepted outright (an observed value needs no confirmation).
    var input = Io.Reader.fixed("typo\nn\nwork\n");
    var out_buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    const outcome = try walkDimensions(a, &dims, &r, .{ .interactive = .{ .input = &input, .out = &out } });
    try std.testing.expectEqual(@as(usize, 1), outcome.answers.len);
    try std.testing.expectEqualStrings("work", outcome.answers[0].value);
}

test "askDimension (via walkDimensions): a UTF-8 answer is bound byte-for-byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dims = [_]dimensions.Dimension{
        testDim("display_name", .{ .presence = true }),
    };
    var bindings = std.StringHashMap([]const u8).init(a);
    var live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings };
    var r: dsl.resolver.Resolver = .{ .live = &live };

    var input = Io.Reader.fixed("\u{69d1}\u{6749}\n");
    var out_buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    const outcome = try walkDimensions(a, &dims, &r, .{ .interactive = .{ .input = &input, .out = &out } });
    try std.testing.expectEqual(@as(usize, 1), outcome.answers.len);
    try std.testing.expectEqualStrings("\u{69d1}\u{6749}", outcome.answers[0].value);
}

test "askDimension (via walkDimensions): enter with a default takes it, enter without one declines (binds empty)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dims = [_]dimensions.Dimension{
        testDim("holt_backend", .{ .captured = true, .capture_defaults = &.{"icloud"} }),
        testDim("email", .{ .presence = true }),
    };
    var bindings = std.StringHashMap([]const u8).init(a);
    var live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings };
    var r: dsl.resolver.Resolver = .{ .live = &live };

    var input = Io.Reader.fixed("\n\n");
    var out_buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    const outcome = try walkDimensions(a, &dims, &r, .{ .interactive = .{ .input = &input, .out = &out } });
    try std.testing.expectEqual(@as(usize, 2), outcome.answers.len);
    // Name order within the wave: "email" sorts before "holt_backend".
    try std.testing.expectEqualStrings("email", outcome.answers[0].name);
    try std.testing.expectEqualStrings("", outcome.answers[0].value);
    try std.testing.expectEqualStrings("holt_backend", outcome.answers[1].name);
    try std.testing.expectEqualStrings("icloud", outcome.answers[1].value);
}

test "printPrompt: choices and default rendered, provenance line names source count and needing scripts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const d = testDim("profile", .{
        .value_compared = true,
        .observed_values = &.{"work"},
        .capture_defaults = &.{"personal"},
        .source_count = 2,
        .needing_scripts = &.{"scripts/pre/10-op.sh"},
    });
    var out_buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    try printProvenance(&out, d);
    try printPrompt(a, &out, d.name, try choiceList(a, d), agreedDefault(d));

    const got = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "2 sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "scripts/pre/10-op.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "personal, work") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "[personal]") != null);
}

test "agreedDefault: disagreeing capture and declared defaults yield no default" {
    const d = testDim("holt_backend", .{ .capture_defaults = &.{"personal"}, .declared_defaults = &.{"icloud"} });
    try std.testing.expect(agreedDefault(d) == null);
}

test "persist: replaces existing assignment, keeps comments, escapes quotes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "facts.toml",
        .data = "# my facts\nprofile = \"personal\"\nlocale = \"en_US.UTF-8\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cwd_path = try std.process.currentPathAlloc(io, arena.allocator());
    const facts_path = try std.fs.path.join(arena.allocator(), &.{
        cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "facts.toml",
    });

    const answers = [_]state_mod.Fact{
        .{ .name = "profile", .value = "work" },
        .{ .name = "note", .value = "say \"hi\"" },
    };
    try persist(arena.allocator(), io, facts_path, &answers);

    const written = try Io.Dir.cwd().readFileAlloc(io, facts_path, arena.allocator(), .limited(4096));
    try std.testing.expectEqualStrings(
        "# my facts\nlocale = \"en_US.UTF-8\"\nprofile = \"work\"\nnote = \"say \\\"hi\\\"\"\n",
        written,
    );
}

test "persist: a control character in a value or name is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    const facts_path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", "no-such-facts-xyz.toml" });

    const bad_value = [_]state_mod.Fact{.{ .name = "note", .value = "a\nadmin = 1" }};
    try std.testing.expectError(error.InvalidFactValue, persist(a, std.testing.io, facts_path, &bad_value));

    const bad_name = [_]state_mod.Fact{.{ .name = "a\nb", .value = "ok" }};
    try std.testing.expectError(error.InvalidFactName, persist(a, std.testing.io, facts_path, &bad_name));

    // Nothing was written.
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(std.testing.io, facts_path, .{}));
}

test "remove: drops only the named assignment, keeps comments and other facts" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "facts.toml",
        .data = "# my facts\nprofile = \"personal\"\nemail = \"a@b.com\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cwd_path = try std.process.currentPathAlloc(io, arena.allocator());
    const facts_path = try std.fs.path.join(arena.allocator(), &.{
        cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "facts.toml",
    });

    try remove(arena.allocator(), io, facts_path, "email");

    const written = try Io.Dir.cwd().readFileAlloc(io, facts_path, arena.allocator(), .limited(4096));
    try std.testing.expectEqualStrings("# my facts\nprofile = \"personal\"\n", written);
}

test "remove: a missing file or an absent name is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    const facts_path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", "no-such-facts-remove.toml" });

    try remove(a, std.testing.io, facts_path, "email");
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(std.testing.io, facts_path, .{}));
}

test "isValidFactName: bare-key charset only, so a name cannot break the TOML" {
    try std.testing.expect(isValidFactName("cloud_backend"));
    try std.testing.expect(isValidFactName("signing-work-key"));
    try std.testing.expect(isValidFactName("os2"));
    try std.testing.expect(!isValidFactName("")); // empty
    try std.testing.expect(!isValidFactName("a b")); // space -> `a b = ..` invalid
    try std.testing.expect(!isValidFactName("a=b")); // `=` breaks the assignment
    try std.testing.expect(!isValidFactName("a\"b")); // quote
    try std.testing.expect(!isValidFactName("a.b")); // dotted key is a table path
    try std.testing.expect(!isValidFactName("[x]")); // section header
}

test "canPersist: rejects exactly what persist itself would refuse" {
    try std.testing.expect(canPersist("email", "team@work.com"));
    try std.testing.expect(!canPersist("email", "a\tb"));
    try std.testing.expect(!canPersist("email", "a\nadmin = 1"));
    try std.testing.expect(!canPersist("a.b", "ok"));
    try std.testing.expect(!canPersist("", "ok"));
}

test "writeUnboundNotice: empty list writes nothing; a non-empty list names every dimension with the prefix" {
    var buf: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    try writeUnboundNotice(&out, "mox apply: ", &.{});
    try std.testing.expectEqualStrings("", out.buffered());

    try writeUnboundNotice(&out, "mox apply: ", &.{ "gdrive_account", "profile" });
    const got = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "mox apply: unbound facts: gdrive_account profile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "mox facts set") != null);
}
