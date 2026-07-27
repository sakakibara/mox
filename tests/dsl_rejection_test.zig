//! Locks the bounded DSL's explicit non-features: each construct below must
//! ERROR at parse or compose time rather than be silently accepted. A feature
//! request that would expand the DSL has to first delete one of these.

const std = @import("std");
const mox = @import("mox");

const Value = mox.data.value.Value;

// Recursive directives (a region body is itself a template) are now a
// FEATURE: `when`-in-`for`, `for`-in-`for`, etc. parse into an outer directive
// whose body is captured verbatim and re-parsed at compose. The former
// `NestedDirectiveNotAllowed` non-feature was deleted to deliver it. What
// remains a hard error is an UNBALANCED structure: a region that opens a nested
// region and never closes its own.
test "reject: an unclosed outer region (inner region opened, outer never closed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\# mox: replace "a.sh" when os=darwin
        \\body
        \\# mox: append "b.sh"
        \\# mox: end
    ;
    // `append` nests inside `replace` (depth 1); the single `end` closes it, so
    // `replace` runs to EOF with no `end` -> unclosed.
    try std.testing.expectError(
        error.UnclosedRegion,
        mox.dsl.driver.parseFile(arena.allocator(), src, "#", null),
    );
}

test "reject: an unmatched end marker with no open region" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\plain
        \\# mox: end
    ;
    try std.testing.expectError(
        error.UnmatchedEndMarker,
        mox.dsl.driver.parseFile(arena.allocator(), src, "#", null),
    );
}

test "reject: adjacent captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.AdjacentCaptures,
        mox.compose.interp.lint(arena.allocator(), "<entry.a><entry.b>"),
    );
}

test "reject: repeated capture name in one template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.DuplicateCapture,
        mox.compose.interp.lint(arena.allocator(), "<entry.k>=<entry.k>"),
    );
}

test "reject: regex metachar in a loop template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record = std.StringHashMap(Value).init(arena.allocator());
    try record.put("key", .{ .string = "ll" });
    // `*` is not a wildcard: `<entry.key*>` is a literal field name that does
    // not exist, so expansion fails rather than pattern-matching `key`.
    try std.testing.expectError(
        error.UnknownField,
        mox.compose.interp.expand(arena.allocator(), "abbr <entry.key*>", &record, .{}),
    );
}

test "reject: glob in an axis value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `os=lin*` - the `*` is not a valid value token, so the directive does
    // not even lex; axis values are exact tokens, never patterns.
    try std.testing.expectError(
        error.UnexpectedCharacter,
        mox.dsl.parser.parseRegionOpener(arena.allocator(), "when os=lin*", 1, false),
    );
}

test "reject: an unquoted non-ASCII axis value does not lex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A bare token lexes ASCII-alphanumeric only; a non-ASCII fact value
    // (e.g. a Kanji profile name) needs the quoted-string escape hatch.
    try std.testing.expectError(
        error.UnexpectedCharacter,
        mox.dsl.parser.parseRegionOpener(arena.allocator(), "when profile=\xe6\x97\xa5", 1, false),
    );
}

test "reject: a when gate naming path= is refused as a reserved axis name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `path` is a reserved axis name: its closed axis was deleted (D8), so
    // any `path=` source now errors loudly rather than composing to a
    // silent false forever.
    const src = "# mox: when path=brew\nbody\n# mox: end\n";
    try std.testing.expectError(
        error.ReservedAxisName,
        mox.dsl.driver.parseFile(arena.allocator(), src, "#", null),
    );
}

test "reject: completions with an unsupported shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "# mox: completions tcsh \"data/completions.toml\"";
    try std.testing.expectError(
        error.UnknownShell,
        mox.dsl.driver.parseFile(arena.allocator(), src, "#", null),
    );
}

test "reject: completions without a shell token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "# mox: completions \"data/completions.toml\"";
    try std.testing.expectError(
        error.ExpectedShell,
        mox.dsl.driver.parseFile(arena.allocator(), src, "#", null),
    );
}

test "reject: completions without a registry path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "# mox: completions fish";
    try std.testing.expectError(
        error.ExpectedString,
        mox.dsl.driver.parseFile(arena.allocator(), src, "#", null),
    );
}

test "reject: completions with trailing tokens after the when clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "# mox: completions zsh \"data/completions.toml\" when os=darwin extra";
    try std.testing.expectError(
        error.UnexpectedTrailingTokens,
        mox.dsl.driver.parseFile(arena.allocator(), src, "#", null),
    );
}

test "reject: completions shell given as a key=value argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The rejected design: `shell=fish` is surface-identical to an axis atom
    // and collides with a custom fact named `shell`; the shell is a typed
    // positional token instead.
    const src = "# mox: completions shell=fish \"data/completions.toml\"";
    try std.testing.expectError(
        error.ExpectedShell,
        mox.dsl.driver.parseFile(arena.allocator(), src, "#", null),
    );
}
