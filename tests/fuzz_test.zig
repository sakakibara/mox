//! Fuzz targets for the parsing-heavy surfaces that take arbitrary bytes:
//! the DSL parse pipeline (scanner -> driver -> axis/row_expr) and the INI
//! section-merge. Both accept untrusted file content, so the invariant under
//! test is total: any input either parses or returns an error, never crashes,
//! hangs, or corrupts memory.
//!
//! Run once as smoke tests via `zig build test`; fuzz continuously with
//! `zig build fuzz --fuzz`.

const std = @import("std");
const mox = @import("mox");

const Smith = std.testing.Smith;

/// Drive the DSL parser over arbitrary bytes as if they were a source file.
/// Errors are expected; a crash or hang is the bug the fuzzer hunts.
fn fuzzDsl(_: void, smith: *Smith) anyerror!void {
    // >= 16KB so an input can reach the script-header (16KB) parse regime.
    var buf: [16384]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `#` covers the common shell/toml/gitconfig dialect; the driver walks the
    // scanner, line/region parsers, and the axis/row-expr sub-parsers.
    _ = mox.dsl.driver.parseFile(arena.allocator(), input, "#", null) catch {};
}

/// Drive the DSL parser with multi-character comment markers (`--`, `;`), which
/// exercise the marker-length handling in the scanner that a single `#` never
/// reaches. Errors are expected; a crash or hang is the bug.
fn fuzzDslMarkers(_: void, smith: *Smith) anyerror!void {
    var buf: [16384]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = mox.dsl.driver.parseFile(arena.allocator(), input, "--", null) catch {};
    _ = mox.dsl.driver.parseFile(arena.allocator(), input, ";", null) catch {};
}

/// Parse an axis expression from arbitrary bytes and, when it parses, evaluate
/// it against a bindings map built from the same bytes -- so the evaluators
/// (eqMatch, presentMatch, and/or/not) get coverage, not just the parser.
fn fuzzAxis(_: void, smith: *Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = mox.dsl.axis.parseString(a, input) catch return;

    // Bindings from the same bytes: whitespace-split tokens become `k=v`
    // (compound axis) or bare-`k` presence entries.
    var bindings = std.StringHashMap([]const u8).init(a);
    var it = std.mem.tokenizeAny(u8, input, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            bindings.put(tok, "1") catch {};
            bindings.put(tok[0..eq], tok[eq + 1 ..]) catch {};
        } else {
            bindings.put(tok, "1") catch {};
        }
    }
    _ = mox.dsl.axis.evaluate(expr, &bindings);
}

/// Drive the template capture engine over arbitrary bytes: lint, then (when it
/// lints) expand. Covers the `<...>` close-index scan (including the escaped
/// `<secret:...\>...>` form), default/chain splitting, and data-spec parsing.
/// No secrets or machine context, so expand never shells out -- the invariant
/// is purely that the parser never crashes, hangs, or corrupts memory.
fn fuzzInterp(_: void, smith: *Smith) anyerror!void {
    var buf: [8192]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A template that fails lint must not be expanded (expand's contract
    // assumes a linted template); a lint-clean one must expand without a crash.
    mox.compose.interp.lint(arena.allocator(), input) catch return;
    _ = mox.compose.interp.expand(arena.allocator(), input, null, .{}) catch {};
}

/// Merge two arbitrary byte blobs as INI base + overlay.
fn fuzzIniMerge(_: void, smith: *Smith) anyerror!void {
    var base_buf: [4096]u8 = undefined;
    var overlay_buf: [4096]u8 = undefined;
    const bn = smith.slice(&base_buf);
    const on = smith.slice(&overlay_buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = mox.compose.ini_merge.merge(arena.allocator(), base_buf[0..bn], overlay_buf[0..on], .generic) catch {};
}

test "fuzz: dsl parse pipeline" {
    try std.testing.fuzz({}, fuzzDsl, .{});
}

test "fuzz: dsl parse pipeline with multi-char markers" {
    try std.testing.fuzz({}, fuzzDslMarkers, .{});
}

test "fuzz: axis parse then evaluate" {
    try std.testing.fuzz({}, fuzzAxis, .{});
}

test "fuzz: template capture engine (lint + expand)" {
    try std.testing.fuzz({}, fuzzInterp, .{});
}

test "fuzz: ini_merge base + overlay" {
    try std.testing.fuzz({}, fuzzIniMerge, .{});
}
