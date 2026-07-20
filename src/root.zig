//! Public API root for the mox library; re-exports the dsl module.

const std = @import("std");
const Env = @import("env").Env;

pub const env = struct {
    pub const Env = @import("env").Env;
};
pub const dsl = @import("dsl/root.zig");
pub const source = @import("source/root.zig");
pub const compose = @import("compose/root.zig");
pub const apply = @import("apply/root.zig");
pub const data = @import("data/root.zig");
pub const machine = @import("machine/root.zig");
pub const coupling = @import("coupling/root.zig");
pub const classify = @import("classify/root.zig");
pub const private = @import("private/root.zig");
pub const secret = @import("secret/root.zig");
pub const trigger = @import("trigger/root.zig");
pub const diff = @import("diff/root.zig");
pub const provenance = @import("provenance/root.zig");
pub const cli = @import("cli/root.zig");

/// External: TOML 1.1 parser/encoder. Used by the Cat A composer.
pub const toml = @import("toml");

test "ast module reachable through re-export chain" {
    const Directive = dsl.ast.Directive;
    _ = Directive;
}

test "comment marker module reachable" {
    try std.testing.expect(dsl.comment.markerForExtension(".lua") != null);
}

test "lexer module reachable" {
    var allocator_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const toks = try dsl.lexer.lex(fba.allocator(), "include");
    try std.testing.expect(toks.len > 0);
}

test "axis module reachable (parser + evaluator)" {
    var allocator_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try dsl.axis.parseString(fba.allocator(), "os=darwin");
    var bindings = std.StringHashMap([]const u8).init(fba.allocator());
    try bindings.put("os", "darwin");
    try std.testing.expect(dsl.axis.evaluate(expr, &bindings));
}

test "scanner module reachable" {
    var allocator_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const events = try dsl.scanner.scan(fba.allocator(), "# mox: foo", "#");
    try std.testing.expect(events.len > 0);
}

test "parser module reachable" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const dir = try dsl.parser.parseLineDirective(fba.allocator(), "include \"x\"", 1);
    try std.testing.expect(dir.kind == .include);
}

test "driver module reachable" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const parsed = try dsl.driver.parseFile(fba.allocator(), "echo hi", "#", null);
    try std.testing.expectEqual(@as(usize, 0), parsed.directives.len);
}

test "ManagedTree types are constructible" {
    const f = source.tree.ManagedFile{
        .source_base_path = "src/.zshrc",
        .source_base_abs = "/abs/src/.zshrc",
        .live_path = "/home/me/.zshrc",
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
    };
    try std.testing.expectEqualStrings("src/.zshrc", f.source_base_path);
}

test "parse axis tuple from filename: single axis" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const t = try source.tuple.parseFilename(fba.allocator(), "os=darwin.lua");
    try std.testing.expectEqual(@as(usize, 1), t.pairs.len);
    try std.testing.expectEqualStrings("os", t.pairs[0].name);
    try std.testing.expectEqualStrings("darwin", t.pairs[0].value);
}

test "parse axis tuple from filename: combined axes sorted" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const t = try source.tuple.parseFilename(fba.allocator(), "profile=work+os=darwin.lua");
    try std.testing.expectEqual(@as(usize, 2), t.pairs.len);
    try std.testing.expectEqualStrings("os", t.pairs[0].name);
    try std.testing.expectEqualStrings("profile", t.pairs[1].name);
}

test "parse axis tuple: invalid axis name rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = source.tuple.parseFilename(fba.allocator(), "OS=darwin.lua");
    try std.testing.expectError(error.InvalidAxisName, result);
}

test "parse axis tuple: missing value rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = source.tuple.parseFilename(fba.allocator(), "os=.lua");
    try std.testing.expectError(error.InvalidAxisValue, result);
}

test "source path to live path" {
    const a = std.testing.allocator;
    const live = try source.path.toLivePath(a, "src/.zshrc", "/home/me");
    defer a.free(live);
    const want = try std.fs.path.join(a, &.{ "/home/me", ".zshrc" });
    defer a.free(want);
    try std.testing.expectEqualStrings(want, live);
}

test "source path nested" {
    const a = std.testing.allocator;
    const live = try source.path.toLivePath(a, "src/.config/nvim/init.lua", "/home/me");
    defer a.free(live);
    const want = try std.fs.path.join(a, &.{ "/home/me", ".config", "nvim", "init.lua" });
    defer a.free(want);
    try std.testing.expectEqualStrings(want, live);
}

test "junk filter: .DS_Store is junk" {
    try std.testing.expect(source.junk.isJunk(".DS_Store"));
}

test "junk filter: vim swap files are junk" {
    try std.testing.expect(source.junk.isJunk(".file.lua.swp"));
    try std.testing.expect(source.junk.isJunk("file.swo"));
}

test "junk filter: regular file is not junk" {
    try std.testing.expect(!source.junk.isJunk("config.toml"));
    try std.testing.expect(!source.junk.isJunk(".zshrc"));
}

test "match: empty tuple matches everything" {
    var bindings = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer bindings.deinit();
    try bindings.put("os", "darwin");

    const tuples = [_]source.tree.AxisTuple{
        .{ .pairs = &.{} },
    };
    const idx = compose.match.bestMatch(&tuples, &bindings);
    try std.testing.expectEqual(@as(?usize, 0), idx);
}

test "match: most specific tuple wins" {
    var bindings = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer bindings.deinit();
    try bindings.put("os", "darwin");
    try bindings.put("profile", "work");

    const universal = source.tree.AxisTuple{ .pairs = &.{} };
    const os_only = source.tree.AxisTuple{ .pairs = &.{
        .{ .name = "os", .value = "darwin" },
    } };
    const both = source.tree.AxisTuple{ .pairs = &.{
        .{ .name = "os", .value = "darwin" },
        .{ .name = "profile", .value = "work" },
    } };

    const tuples = [_]source.tree.AxisTuple{ universal, os_only, both };
    const idx = compose.match.bestMatch(&tuples, &bindings);
    try std.testing.expectEqual(@as(?usize, 2), idx);
}

test "match: no match returns null" {
    var bindings = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer bindings.deinit();
    try bindings.put("os", "linux");

    const darwin_only = source.tree.AxisTuple{ .pairs = &.{
        .{ .name = "os", .value = "darwin" },
    } };
    const tuples = [_]source.tree.AxisTuple{darwin_only};
    const idx = compose.match.bestMatch(&tuples, &bindings);
    try std.testing.expectEqual(@as(?usize, null), idx);
}

test "category: .toml is A" {
    try std.testing.expectEqual(compose.category.Category.a, compose.category.detect("config.toml", "[user]\n"));
}

test "category: .lua is B" {
    try std.testing.expectEqual(compose.category.Category.b, compose.category.detect("init.lua", "local M = {}\n"));
}

test "category: binary content is C" {
    var bin = [_]u8{ 0x89, 0x50, 0x4e, 0x47 };
    try std.testing.expectEqual(compose.category.Category.c, compose.category.detect("icon.png", &bin));
}

test "category: unknown extension defaults to B if text" {
    try std.testing.expectEqual(compose.category.Category.b, compose.category.detect("README", "Hello world\n"));
}

test "pacifier: strips lua diagnostic directive" {
    const stripped = compose.pacifier.strip("---@diagnostic disable: undefined-global\nM.kind = \"work\"\n", "lua");
    try std.testing.expectEqualStrings("M.kind = \"work\"\n", stripped.text);
}

test "pacifier: no pacifier present returns input unchanged" {
    const input = "M.kind = \"work\"\n";
    const stripped = compose.pacifier.strip(input, "lua");
    try std.testing.expectEqualStrings(input, stripped.text);
}

test "data Value type is constructible" {
    const v_str = data.value.Value{ .string = "hello" };
    try std.testing.expect(v_str == .string);
    const v_int = data.value.Value{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), v_int.int);
}

test "toml parser: simple array-of-tables" {
    var allocator_buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const arena = fba.allocator();

    const src =
        \\[[abbreviations]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbreviations]]
        \\key = "gs"
        \\expansion = "git status"
    ;
    const result = try data.toml.parse(arena, src);
    const arr = result.get("abbreviations").?;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("ll", arr[0].get("key").?.string);
    try std.testing.expectEqualStrings("git status", arr[1].get("expansion").?.string);
}

test "toml parser: int values" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = try data.toml.parse(fba.allocator(), "[[entries]]\nname = \"foo\"\npriority = 5\n");
    const arr = result.get("entries").?;
    try std.testing.expectEqual(@as(i64, 5), arr[0].get("priority").?.int);
}

test "toml parser: bool values" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = try data.toml.parse(fba.allocator(), "[[entries]]\nname = \"foo\"\nenabled = true\nblocked = false\n");
    const arr = result.get("entries").?;
    try std.testing.expectEqual(true, arr[0].get("enabled").?.bool);
    try std.testing.expectEqual(false, arr[0].get("blocked").?.bool);
}

test "toml parser: comments are skipped" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = try data.toml.parse(fba.allocator(), "# top comment\n[[entries]]\n# inside table\nkey = \"foo\"\n");
    try std.testing.expectEqual(@as(usize, 1), result.get("entries").?.len);
}

test "data source loader is reachable" {
    _ = data.source.loadFile;
}

test "interp: basic substitution" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);

    var record = std.StringHashMap(data.value.Value).init(fba.allocator());
    try record.put("key", .{ .string = "ll" });
    try record.put("expansion", .{ .string = "ls -l" });

    const out = try compose.interp.expand(fba.allocator(), "abbr <entry.key>=\"<entry.expansion>\"", &record, .{});
    try std.testing.expectEqualStrings("abbr ll=\"ls -l\"", out);
}

test "interp lint: adjacent captures rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = compose.interp.lint(arena.allocator(), "abbr <entry.a><entry.b>");
    try std.testing.expectError(error.AdjacentCaptures, result);
}

test "interp lint: duplicate capture rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = compose.interp.lint(arena.allocator(), "<entry.k>=<entry.k>");
    try std.testing.expectError(error.DuplicateCapture, result);
}

test "interp lint: clean template passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try compose.interp.lint(arena.allocator(), "abbr <entry.key>=\"<entry.expansion>\"");
}

test "MachineState type is constructible" {
    const m = machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "test-host",
        .username = "tester",
        .home = "/home/tester",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
    try std.testing.expectEqualStrings("linux", m.os);
}

test "path_lookup: detects the platform's shell on PATH" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `cmd` resolves via PATHEXT to cmd.exe, which is the lookup being tested.
    const shell = if (@import("builtin").os.tag == .windows) "cmd" else "sh";
    const candidates = [_][]const u8{ shell, "definitely-does-not-exist-9876" };
    const found = try machine.path_lookup.findOnPath(
        arena.allocator(),
        std.testing.io,
        Env{ .process = std.testing.environ },
        &candidates,
    );

    var has_shell = false;
    for (found) |n| {
        if (std.mem.eql(u8, n, shell)) has_shell = true;
    }
    try std.testing.expect(has_shell);
    for (found) |n| {
        try std.testing.expect(!std.mem.eql(u8, n, "definitely-does-not-exist-9876"));
    }
}

test "MachineState capture: returns plausible OS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try machine.state.capture(arena.allocator(), std.testing.io, Env{ .process = std.testing.environ });
    // macOS reports as "darwin" (uname/chezmoi convention), not Zig's "macos".
    const known_os = [_][]const u8{ "linux", "darwin", "windows", "freebsd", "openbsd" };
    var ok = false;
    for (known_os) |o| {
        if (std.mem.eql(u8, m.os, o)) ok = true;
    }
    try std.testing.expect(ok);
}

test "MachineState capture: sets home directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try machine.state.capture(arena.allocator(), std.testing.io, Env{ .process = std.testing.environ });
    try std.testing.expect(m.home.len > 0);
}

test "machine bindings: produces os and tool entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "test",
        .username = "tester",
        .home = "/home/tester",
        .tools_on_path = &.{ "fd", "rg" },
        .defined_envs = &.{"WSL_DISTRO_NAME"},
        .brew_prefix = "/opt/homebrew",
        .cargo_home = "/home/tester/.cargo",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "/home/tester/.config",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
    var b = try machine.bindings.fromMachineState(arena.allocator(), m);
    try std.testing.expectEqualStrings("linux", b.get("os").?);
    try std.testing.expectEqualStrings("aarch64", b.get("arch").?);
    try std.testing.expect(b.contains("tool=fd"));
    try std.testing.expect(b.contains("tool=rg"));
    try std.testing.expect(b.contains("env=WSL_DISTRO_NAME"));
    try std.testing.expect(b.contains("path=brew_prefix"));
}

test "tokens: extract from simple text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try coupling.tokens.extract(arena.allocator(), "hello user@example.com world");
    var found = false;
    for (result) |t| {
        if (std.mem.eql(u8, t, "user@example.com")) found = true;
    }
    try std.testing.expect(found);
}

test "tokens: short tokens excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try coupling.tokens.extract(arena.allocator(), "abc def short");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "tokens: numeric excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try coupling.tokens.extract(arena.allocator(), "12345678 12345.6789 -100000");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "tokens: high-entropy base64 excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try coupling.tokens.extract(arena.allocator(), "Xb7Kj9Pq3Lz8Mn4Vt6Rw2Yc5Eh1Sd0");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "coupling graph: add and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var g = coupling.graph.Graph.init(arena.allocator());
    try g.addOccurrence("hello-world-token", "src/a", 0, 17);
    try g.addOccurrence("hello-world-token", "src/b", 100, 17);

    const occs = g.lookup("hello-world-token").?;
    try std.testing.expectEqual(@as(usize, 2), occs.len);
}

test "coupling graph: file count for token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var g = coupling.graph.Graph.init(arena.allocator());
    try g.addOccurrence("token12345", "src/a", 0, 10);
    try g.addOccurrence("token12345", "src/a", 50, 10);
    try g.addOccurrence("token12345", "src/b", 0, 10);
    try std.testing.expectEqual(@as(usize, 2), g.fileCountForToken("token12345"));
}

test "coupling index: builds from files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const inputs = [_]coupling.index.FileInput{
        .{ .id = "src/.gitconfig", .content = "email = ada@example.com\n" },
        .{ .id = "src/allowed_signers", .content = "ada@example.com namespaces=git\n" },
    };
    var g = try coupling.index.build(arena.allocator(), &inputs);
    try std.testing.expect(g.lookup("ada@example.com") != null);
}

test "coupling index: singleton tokens excluded by co-occurrence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const inputs = [_]coupling.index.FileInput{
        .{ .id = "src/a", .content = "uniquetoken12345 in only one file" },
        .{ .id = "src/b", .content = "differentcontent here only" },
    };
    var g = try coupling.index.build(arena.allocator(), &inputs);
    try std.testing.expect(g.lookup("uniquetoken12345") == null);
}

test "coupling index: universal token excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const inputs = [_]coupling.index.FileInput{
        .{ .id = "src/a", .content = "boilerplate-token-everywhere" },
        .{ .id = "src/b", .content = "boilerplate-token-everywhere" },
        .{ .id = "src/c", .content = "boilerplate-token-everywhere" },
        .{ .id = "src/d", .content = "boilerplate-token-everywhere" },
    };
    var g = try coupling.index.build(arena.allocator(), &inputs);
    try std.testing.expect(g.lookup("boilerplate-token-everywhere") == null);
}

test "decline list: per-pair decline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var d = coupling.decline.DeclineList.init(arena.allocator());
    try d.declinePair("token12345", "src/a", "src/b");
    try std.testing.expect(d.isPairDeclined("token12345", "src/a", "src/b"));
    try std.testing.expect(d.isPairDeclined("token12345", "src/b", "src/a"));
    try std.testing.expect(!d.isPairDeclined("token12345", "src/a", "src/c"));
}

test "decline list: global decline applies to all pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var d = coupling.decline.DeclineList.init(arena.allocator());
    try d.declineGlobal("noisytoken");
    try std.testing.expect(d.isPairDeclined("noisytoken", "src/x", "src/y"));
    try std.testing.expect(d.isPairDeclined("noisytoken", "src/p", "src/q"));
}

test "divergence: detects email change in one file but not other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const before = [_]coupling.divergence.FileSnapshot{
        .{ .id = "src/.gitconfig", .content = "email = old@example.com" },
        .{ .id = "src/allowed_signers", .content = "old@example.com namespaces=git" },
    };
    const after = [_]coupling.divergence.FileSnapshot{
        .{ .id = "src/.gitconfig", .content = "email = new@example.com" },
        .{ .id = "src/allowed_signers", .content = "old@example.com namespaces=git" },
    };

    const decline_list: ?*const coupling.decline.DeclineList = null;
    const divs = try coupling.divergence.detect(arena.allocator(), &before, &after, decline_list);
    try std.testing.expectEqual(@as(usize, 1), divs.len);
    try std.testing.expectEqualStrings("old@example.com", divs[0].token);
}

test "divergence: coherent change does not flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const before = [_]coupling.divergence.FileSnapshot{
        .{ .id = "src/a", .content = "old@example.com here" },
        .{ .id = "src/b", .content = "old@example.com there" },
    };
    const after = [_]coupling.divergence.FileSnapshot{
        .{ .id = "src/a", .content = "new@example.com here" },
        .{ .id = "src/b", .content = "new@example.com there" },
    };

    const divs = try coupling.divergence.detect(arena.allocator(), &before, &after, null);
    try std.testing.expectEqual(@as(usize, 0), divs.len);
}

test "divergence: declined coupling silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const before = [_]coupling.divergence.FileSnapshot{
        .{ .id = "src/a", .content = "old@example.com here" },
        .{ .id = "src/b", .content = "old@example.com there" },
    };
    const after = [_]coupling.divergence.FileSnapshot{
        .{ .id = "src/a", .content = "new@example.com here" },
        .{ .id = "src/b", .content = "old@example.com there" },
    };

    var d = coupling.decline.DeclineList.init(arena.allocator());
    try d.declineGlobal("old@example.com");

    const divs = try coupling.divergence.detect(arena.allocator(), &before, &after, &d);
    try std.testing.expectEqual(@as(usize, 0), divs.len);
}

test "secret uri: parse op://" {
    const u = try secret.uri.parse("op://Personal/GitHub/email");
    try std.testing.expect(u.scheme == .op);
    try std.testing.expectEqualStrings("Personal/GitHub/email", u.payload);
}

test "secret uri: parse env:" {
    const u = try secret.uri.parse("env:GITHUB_TOKEN");
    try std.testing.expect(u.scheme == .env);
    try std.testing.expectEqualStrings("GITHUB_TOKEN", u.payload);
}

test "secret uri: parse pass://" {
    const u = try secret.uri.parse("pass://github/email");
    try std.testing.expect(u.scheme == .pass);
    try std.testing.expectEqualStrings("github/email", u.payload);
}

test "secret uri: parse file://" {
    const u = try secret.uri.parse("file:///etc/secret");
    try std.testing.expect(u.scheme == .file);
    try std.testing.expectEqualStrings("/etc/secret", u.payload);
}

test "secret uri: unknown scheme errors" {
    try std.testing.expectError(error.UnknownScheme, secret.uri.parse("ftp://foo"));
}

test "secret resolver: env scheme reads env var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Injected, not the process's own: HOME is a POSIX spelling, and a test
    // should not depend on which variables the host happens to define.
    var map = std.process.Environ.Map.init(a);
    try map.put("MOX_TEST_SECRET", "hunter2");

    const u = try secret.uri.parse("env:MOX_TEST_SECRET");
    const value = try secret.resolver.resolve(a, std.testing.io, Env{ .map = &map }, u);
    try std.testing.expectEqualStrings("hunter2", value);
}

test "secret resolver: file scheme reads file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "hunter2\n" });

    const cwd = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const path = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "secret.txt" });
    defer std.testing.allocator.free(path);

    const uri_str = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{path});
    defer std.testing.allocator.free(uri_str);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const u = try secret.uri.parse(uri_str);
    const value = try secret.resolver.resolve(arena.allocator(), io, Env{ .process = std.testing.environ }, u);
    try std.testing.expectEqualStrings("hunter2\n", value);
}

test "secret resolver: env missing var errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const u = try secret.uri.parse("env:DEFINITELY_NOT_SET_XYZ");
    const result = secret.resolver.resolve(arena.allocator(), std.testing.io, Env{ .process = std.testing.environ }, u);
    try std.testing.expectError(error.SecretNotFound, result);
}

test "secret cache: caches resolved values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var c = secret.cache.Cache.init(arena.allocator());
    try c.put("op://test/foo", "value1");
    const got = c.get("op://test/foo");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("value1", got.?);
}

test "secret cache: missing key returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var c = secret.cache.Cache.init(arena.allocator());
    try std.testing.expect(c.get("never-cached") == null);
}

test "trigger seen-version: first time true, second time false" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const state_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "triggers.txt" });
    defer std.testing.allocator.free(state_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var s = try trigger.state.State.loadOrEmpty(arena.allocator(), io, state_path);

    try std.testing.expect(try s.checkSeenVersion(arena.allocator(), "eza-0.18.0"));
    try std.testing.expect(!try s.checkSeenVersion(arena.allocator(), "eza-0.18.0"));
}

test "private layer: merges into existing managed file overlays" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "private/.gitconfig.d");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.gitconfig", .data = "[user]\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "private/.gitconfig.d/machine=laptop-1", .data = "[user]\n  email = secret@private.com\n" });

    const cwd = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const src_dir = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "src" });
    defer std.testing.allocator.free(src_dir);
    const priv_dir = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "private" });
    defer std.testing.allocator.free(priv_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const base_tree = try source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    const merged = try private.layer.merge(arena.allocator(), io, base_tree, priv_dir, "/home/me");

    try std.testing.expectEqual(@as(usize, 1), merged.files.len);
    try std.testing.expect(merged.files[0].overlays.len >= 1);
}

test "apply module tests are discovered" {
    _ = apply;
}

test "diff module tests are discovered" {
    _ = diff;
}

test "provenance module tests are discovered" {
    _ = provenance;
}

test "machine module tests are discovered" {
    _ = machine;
}

test "classify module tests are discovered" {
    _ = classify;
}

test "coupling module tests are discovered" {
    _ = coupling;
}

test "cli paths module is reachable" {
    _ = cli;
    _ = cli.paths.Paths;
}

test "toml dependency is reachable through re-export" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try toml.parse(arena.allocator(), "name = \"foo\"\n", .{});
    try std.testing.expectEqualStrings("foo", v.table.get("name").?.string);
}
