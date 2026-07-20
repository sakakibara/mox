const std = @import("std");
const mox = @import("mox");

test "integration: realistic shell file with multiple directives" {
    var allocator_buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\export EDITOR=nvim
        \\# mox: include "extras/wsl.sh" when env=WSL_DISTRO_NAME
        \\export PATH=$PATH:~/bin
        \\# mox: replace from "shell-prompt"
        \\PS1='$ '
        \\# mox: end
        \\export LANG=en_US.UTF-8
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 2), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .include);
    try std.testing.expect(parsed.directives[1].kind == .replace);
    try std.testing.expect(parsed.directives[1].kind.replace.from != null);
}

test "integration: lua file with replace + return statement" {
    var allocator_buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\local M = {}
        \\-- mox: replace "kind/work.lua" when profile=work
        \\M.kind = "personal"
        \\-- mox: end
        \\-- mox: replace "kind/personal.lua" when profile=personal
        \\M.kind = "personal"
        \\-- mox: end
        \\return M
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "--", null);
    try std.testing.expectEqual(@as(usize, 2), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .replace);
    try std.testing.expect(parsed.directives[1].kind == .replace);
}

test "integration: shell file with for-loop generating abbreviations" {
    var allocator_buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\# zsh-abbr abbreviations
        \\# mox: for entry in abbreviations.toml
        \\#   abbr <entry.key>=<entry.expansion>
        \\# mox: end
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .for_loop);
    try std.testing.expectEqualStrings("entry", parsed.directives[0].kind.for_loop.variable);
    try std.testing.expectEqualStrings("abbreviations.toml", parsed.directives[0].kind.for_loop.data_source);
}

test "integration: file with whole-file when gate" {
    var allocator_buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\# mox: when os=darwin
        \\alias hide='chflags hidden'
        \\alias show='chflags nohidden'
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .when_gate);
}

test "integration: file with no directives is parsed cleanly" {
    var allocator_buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\export EDITOR=nvim
        \\export LANG=en_US.UTF-8
        \\alias ll='ls -la'
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 0), parsed.directives.len);
    try std.testing.expectEqual(@as(u32, 3), parsed.line_count);
}

test "integration: trailing comment after code is NOT a directive" {
    var allocator_buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\[github]
        \\token = # mox: secret "op://Personal/GitHub/token"
        \\enabled = true
    ;
    // The directive is mid-line, after the value. Per spec, directives must be
    // start-of-line (with optional leading whitespace). So the 2nd line is not
    // a directive; it's content.
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 0), parsed.directives.len);
}

test "integration: secret directive on its own line" {
    var allocator_buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\[github]
        \\# mox: secret "op://Personal/GitHub/token"
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .secret);
    try std.testing.expectEqualStrings("op://Personal/GitHub/token", parsed.directives[0].kind.secret.uri);
}

test "integration: comment marker lookup" {
    try std.testing.expectEqualStrings("#", mox.dsl.comment.markerForExtension(".sh").?);
    try std.testing.expectEqualStrings("--", mox.dsl.comment.markerForExtension(".lua").?);
    try std.testing.expect(mox.dsl.comment.markerForExtension(".xyz") == null);
}

test "integration: axis evaluator works through full re-export chain" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try mox.dsl.axis.parseString(fba.allocator(), "os=darwin and profile=work");

    var bindings = std.StringHashMap([]const u8).init(fba.allocator());
    try bindings.put("os", "darwin");
    try bindings.put("profile", "work");

    try std.testing.expect(mox.dsl.axis.evaluate(expr, &bindings));
}

test "integration: line_count counts last line when file ends with mox: end" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\local M = {}
        \\-- mox: replace "x.lua" when profile=work
        \\M.kind = "personal"
        \\-- mox: end
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "--", null);
    try std.testing.expectEqual(@as(u32, 4), parsed.line_count);
}

test "integration: append directive" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\universal content
        \\# mox: append "extras/darwin.sh" when os=darwin
        \\# mox: end
        \\more universal
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .append);
}

test "integration: prepend directive" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\# mox: prepend "header.sh" when profile=work
        \\# mox: end
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .prepend);
}

test "integration: remove directive" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\# mox: remove when os=windows
        \\unwanted content
        \\# mox: end
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .remove);
}

test "integration: standalone from directive" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\# mox: from "regions"
        \\default body
        \\# mox: end
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "#", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expect(parsed.directives[0].kind == .from);
    try std.testing.expectEqualStrings("regions", parsed.directives[0].kind.from.dir);
}

test "integration: unclosed region errors" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\-- mox: replace "x.lua" when profile=work
        \\body without end marker
    ;
    const result = mox.dsl.driver.parseFile(fba.allocator(), src, "--", null);
    try std.testing.expectError(error.UnclosedRegion, result);
}

test "integration: empty body in region" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const src =
        \\-- mox: replace from "regions"
        \\-- mox: end
    ;
    const parsed = try mox.dsl.driver.parseFile(fba.allocator(), src, "--", null);
    try std.testing.expectEqual(@as(usize, 1), parsed.directives.len);
    try std.testing.expectEqualStrings("", parsed.directives[0].kind.replace.body);
}
