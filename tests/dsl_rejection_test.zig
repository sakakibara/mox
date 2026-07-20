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
