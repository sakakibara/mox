//! Fuzz targets for the parsing-heavy surfaces that take arbitrary bytes:
//! the DSL parse pipeline (scanner -> driver -> axis/row_expr), the INI
//! section-merge, the head-directive and key-path parsers, and the
//! partial-ownership span operations. All accept untrusted file content, so
//! the invariant under test is total: any input either parses or returns an
//! error, never crashes, hangs, or corrupts memory. The head, keypath, and
//! partial targets also check semantic properties: spans stay within the
//! input, strip removes exactly the spanned bytes, parsed key-paths respell
//! and reparse to the same segments, and a successful replaceOwned always
//! passes its own invariant check.
//!
//! Each property has two vehicles sharing one checker: a deterministic
//! seeded sweep that runs on every `zig build test`, and a Smith target that
//! runs once as a smoke test there and explores continuously under
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
    var bindings_r: mox.dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    var it = std.mem.tokenizeAny(u8, input, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            bindings.put(tok, "1") catch {};
            bindings.put(tok[0..eq], tok[eq + 1 ..]) catch {};
        } else {
            bindings.put(tok, "1") catch {};
        }
    }
    _ = mox.dsl.axis.evaluate(expr, &bindings_r);
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

/// Head-directive properties over arbitrary bytes: a parse error is an
/// expected outcome (and strips nothing); a successful parse yields spans
/// that lie within the input in file order, one span per directive line, and
/// a strip that removes exactly the spanned bytes.
fn checkHead(a: std.mem.Allocator, input: []const u8, marker: []const u8) anyerror!void {
    const head = mox.source.head;
    const parsed = head.parse(a, input, marker) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try std.testing.expectEqualStrings(input, try head.strip(a, input, marker));
            return;
        },
    };
    try std.testing.expect(parsed.block_end <= input.len);
    var covered: usize = 0;
    var prev: usize = 0;
    for (parsed.spans) |s| {
        try std.testing.expect(s.start <= s.end);
        try std.testing.expect(s.end <= input.len);
        try std.testing.expect(s.start >= prev);
        prev = s.end;
        covered += s.end - s.start;
    }
    if (parsed.gate) |g| {
        try std.testing.expect(g.span.start <= g.span.end);
        try std.testing.expect(g.span.end <= input.len);
    }
    if (parsed.ownership == .none) {
        try std.testing.expectEqual(@as(usize, 0), parsed.paths.len);
        try std.testing.expectEqual(@as(usize, 0), parsed.spans.len);
    } else {
        try std.testing.expect(parsed.paths.len > 0);
        try std.testing.expectEqual(parsed.paths.len + @intFromBool(parsed.check.len != 0), parsed.spans.len);
    }
    const stripped = try head.stripSpans(a, input, parsed.spans);
    try std.testing.expectEqual(input.len - covered, stripped.len);
    try std.testing.expect(isSubsequence(stripped, input));
}

fn isSubsequence(needle: []const u8, haystack: []const u8) bool {
    var i: usize = 0;
    for (haystack) |c| {
        if (i < needle.len and needle[i] == c) i += 1;
    }
    return i == needle.len;
}

/// Key-path properties over arbitrary bytes: a parse error is an expected
/// outcome; a successful parse yields at least one segment, and respelling
/// every decoded segment basic-quoted reparses to the same segments.
fn checkKeypath(a: std.mem.Allocator, input: []const u8) anyerror!void {
    const keypath = mox.source.keypath;
    const segs = keypath.parse(a, input) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    try std.testing.expect(segs.len >= 1);
    var spelled: std.ArrayList(u8) = .empty;
    for (segs, 0..) |seg, i| {
        if (i > 0) try spelled.append(a, '.');
        try appendBasicQuoted(a, &spelled, seg);
    }
    const again = try keypath.parse(a, spelled.items);
    try std.testing.expectEqual(segs.len, again.len);
    for (segs, again) |x, y| try std.testing.expectEqualStrings(x, y);
}

/// Spell one decoded segment as a TOML basic-quoted key.
fn appendBasicQuoted(a: std.mem.Allocator, out: *std.ArrayList(u8), seg: []const u8) !void {
    try out.append(a, '"');
    for (seg) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        0x08 => try out.appendSlice(a, "\\b"),
        '\t' => try out.appendSlice(a, "\\t"),
        '\n' => try out.appendSlice(a, "\\n"),
        0x0c => try out.appendSlice(a, "\\f"),
        '\r' => try out.appendSlice(a, "\\r"),
        else => if (c < 0x20 or c == 0x7f) {
            var ubuf: [8]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&ubuf, "\\u{X:0>4}", .{c}) catch unreachable);
        } else try out.append(a, c),
    };
    try out.append(a, '"');
}

/// One partial-ownership scenario: a format, a small fixed declaration, a
/// composed owned document populating it, and live-text fragments for the
/// deterministic sweep's input builder.
const PartialCase = struct {
    format: mox.apply.partial.Format,
    raws: []const []const u8,
    owned_text: []const u8,
    fragments: []const []const u8,
};

const ini_fragments = [_][]const u8{
    "[alpha]\n", "[omega]\n",  "[alpha \"sub\"]\n", "[other]\n",
    "k = v\n",   "beta = 1\n", "k=v\n",             "=\n",
    "; c\n",     "# c\n",      "\n",                "\tindent = deep\n",
};

const partial_cases = [_]PartialCase{
    .{
        .format = .toml,
        .raws = &.{ "alpha.beta", "gamma" },
        .owned_text = "gamma = \"g\"\n\n[alpha.beta]\nk = 1\n",
        .fragments = &.{
            "[alpha]\n",          "[alpha.beta]\n",           "[alpha.beta.sub]\n", "[gamma]\n",
            "[[rows]]\n",         "gamma = 1\n",              "alpha.beta = 2\n",   "k = \"v\"\n",
            "beta = { a = 1 }\n", "# c\n",                    "\n",                 "[other]\nx = 1\n",
            "gamma = [1, 2]\n",   "m = \"\"\"\nml\n\"\"\"\n",
        },
    },
    .{
        .format = .json,
        .raws = &.{ "alpha.beta", "gamma" },
        .owned_text = "{\"alpha\": {\"beta\": {\"k\": 1}}, \"gamma\": \"g\"}\n",
        .fragments = &.{
            "{",      "}",  "\"alpha\"",                           "\"beta\"",          "\"gamma\"", ":",
            ",",      "1",  "\"s\"",                               "[",                 "]",         "true",
            "// c\n", "\n", "{\"alpha\": {\"beta\": {\"k\": 1}}}", "{\"gamma\": null}",
        },
    },
    .{
        .format = .yaml,
        .raws = &.{ "alpha.beta", "gamma" },
        .owned_text = "alpha:\n  beta:\n    k: 1\ngamma: g\n",
        .fragments = &.{
            "alpha:\n",           "  beta:\n",       "    k: 1\n", "gamma: g\n",
            "other: 1\n",         "- item\n",        "# c\n",      "\n",
            "alpha: {beta: 1}\n", "gamma: [1, 2]\n", "  ",         "\t",
        },
    },
    .{
        .format = .ini,
        .raws = &.{ "alpha", "omega" },
        .owned_text = "[alpha]\nk = v\n\n[omega]\nj = w\n",
        .fragments = &ini_fragments,
    },
    .{
        .format = .gitconfig,
        .raws = &.{ "alpha", "omega" },
        .owned_text = "[alpha]\nk = v\n\n[omega]\nj = w\n",
        .fragments = &ini_fragments,
    },
};

/// Partial-ownership properties for one scenario under hostile live bytes:
/// locate and replace errors are expected outcomes; located spans lie within
/// the live text; and a candidate replaceOwned builds must pass
/// verifyInvariant against the same inputs (the self-consistency the apply
/// pipeline relies on before writing).
fn checkPartialCase(a: std.mem.Allocator, case: PartialCase, live: []const u8) anyerror!void {
    const partial = mox.apply.partial;
    const paths = try a.alloc(partial.OwnPath, case.raws.len);
    for (case.raws, paths) |raw, *p| {
        p.* = .{ .raw = raw, .segments = try mox.source.keypath.parse(a, raw) };
    }

    var diag: partial.Diag = .{};
    if (partial.locateSpans(a, case.format, live, paths, &diag)) |loc| {
        for (loc.spans) |span_opt| if (span_opt) |s| {
            try std.testing.expect(s.start <= s.end);
            try std.testing.expect(s.end <= live.len);
        };
        for (loc.wrappers) |w| {
            try std.testing.expect(w.start <= w.end);
            try std.testing.expect(w.end <= live.len);
        }
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }

    const owned = try partial.OwnedDoc.parse(a, case.format, case.owned_text);
    const candidate = partial.replaceOwned(a, case.format, live, paths, &owned, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    partial.verifyInvariant(a, case.format, live, candidate, paths, &owned, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.debug.print(
                "partial self-consistency failed: format={s} err={s} diag={s}\n--- live ---\n{s}\n--- candidate ---\n{s}\n---\n",
                .{ @tagName(case.format), @errorName(e), diag.text(), live, candidate },
            );
            return e;
        },
    };
}

fn checkPartial(a: std.mem.Allocator, live: []const u8) anyerror!void {
    for (partial_cases) |case| try checkPartialCase(a, case, live);
}

/// Concatenate randomly chosen fragments (with occasional raw bytes) into
/// `buf` -- the deterministic sweeps' input builder. Bounded by `buf.len`
/// and a geometric stop, so it always terminates.
fn buildFromFragments(rng: std.Random, buf: []u8, fragments: []const []const u8) []const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        if (rng.uintLessThan(u8, 12) == 0) break;
        if (rng.uintLessThan(u8, 5) == 0) {
            buf[len] = rng.int(u8);
            len += 1;
            continue;
        }
        const frag = fragments[rng.uintLessThan(usize, fragments.len)];
        const take = @min(frag.len, buf.len - len);
        @memcpy(buf[len..][0..take], frag[0..take]);
        len += take;
    }
    return buf[0..len];
}

const head_fragments = [_][]const u8{
    "# mox: own a.b\n",      "# mox: disown x\n", "# mox: check \"c\" \"--flag\"\n",
    "# mox: when os=mac\n",  "// mox: own m\n",   "; mox: own s\n",
    "#!/usr/bin/env tool\n", "# note\n",          "#",
    "//",                    ";",                 " mox: ",
    "own",                   "disown",            "check",
    "when",                  "\"",                "'",
    "\\",                    ".",                 " ",
    "\t",                    "\n",                "\r\n",
    "\xEF\xBB\xBF",          "[t]\nk = 1\n",      "body\n",
};

const keypath_fragments = [_][]const u8{
    "a",     "b2",   "seg-ment", "_",    "-",       ".",
    " . ",   "\"",   "'",        " ",    "\t",      "\"a.b\"",
    "'x y'", "\"\"", "\\\"",     "\\\\", "\\u0041", "\\U0001F600",
    "\\u00", "\\n",  "\"q w\"",
};

test "property: head parse spans and strip stay within the input" {
    const iterations = 400;
    var prng = std.Random.DefaultPrng.init(0x68656164);
    const rng = prng.random();
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const input = buildFromFragments(rng, &buf, &head_fragments);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        for ([_][]const u8{ "#", "//", ";" }) |marker| {
            checkHead(a, input, marker) catch |e| {
                std.debug.print("head sweep iteration {d} marker {s} failed on input:\n{s}\n", .{ i, marker, input });
                return e;
            };
        }
    }
}

test "property: keypath segments respell and reparse consistently" {
    const iterations = 800;
    var prng = std.Random.DefaultPrng.init(0x6b657970);
    const rng = prng.random();
    var buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const input = buildFromFragments(rng, &buf, &keypath_fragments);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        checkKeypath(arena.allocator(), input) catch |e| {
            std.debug.print("keypath sweep iteration {d} failed on input:\n{s}\n", .{ i, input });
            return e;
        };
    }
}

test "property: partial replaceOwned output passes its own invariant check" {
    const iterations = 150;
    var buf: [768]u8 = undefined;
    for (partial_cases) |case| {
        var prng = std.Random.DefaultPrng.init(0x706172 ^ @as(u64, @intFromEnum(case.format)));
        const rng = prng.random();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const live = buildFromFragments(rng, &buf, case.fragments);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            checkPartialCase(arena.allocator(), case, live) catch |e| {
                std.debug.print("partial sweep format {s} iteration {d} failed on live:\n{s}\n", .{ @tagName(case.format), i, live });
                return e;
            };
        }
    }
}

/// Drive the head-directive parser over arbitrary bytes for each comment
/// marker the walk hands it. Errors are expected; a crash, hang, or span
/// outside the input is the bug the fuzzer hunts.
fn fuzzHead(_: void, smith: *Smith) anyerror!void {
    var buf: [8192]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try checkHead(a, input, "#");
    try checkHead(a, input, "//");
    try checkHead(a, input, ";");
}

/// Drive the key-path parser over arbitrary bytes and round-trip whatever
/// parses.
fn fuzzKeypath(_: void, smith: *Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const n = smith.slice(&buf);
    const input = buf[0..n];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try checkKeypath(arena.allocator(), input);
}

/// Feed arbitrary live bytes through locateSpans, replaceOwned, and
/// verifyInvariant for every format's fixed declaration.
fn fuzzPartial(_: void, smith: *Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const live = buf[0..n];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try checkPartial(arena.allocator(), live);
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

test "fuzz: head directive parse + strip" {
    try std.testing.fuzz({}, fuzzHead, .{});
}

test "fuzz: keypath parse + respell round-trip" {
    try std.testing.fuzz({}, fuzzKeypath, .{});
}

test "fuzz: partial locate + replace + verify" {
    try std.testing.fuzz({}, fuzzPartial, .{});
}
