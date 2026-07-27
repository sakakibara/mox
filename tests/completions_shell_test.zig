//! Shell-level integration tests for the completions generator: the emitted
//! stubs are exercised inside REAL shells, not just compared to goldens. The
//! zsh cases run a compsys session in a zpty and demand completion on the
//! FIRST tab -- the failure mode a file-shape golden cannot see (a stub whose
//! generated script never self-dispatches under eval completes nothing once
//! per session). The harness gates every keystroke on a compinit-done marker:
//! a fixed-sleep harness races compinit and reports false first-tab failures
//! indistinguishable from the real bug.
//!
//! Each test skips (with zig's skip status) where its shell is unavailable;
//! CI exercises the zsh cases on the macOS runner, which ships zsh natively.

const std = @import("std");
const builtin = @import("builtin");
const mox = @import("mox");

const Io = std.Io;

const wall_timeout: std.Io.Timeout = .{
    .duration = .{ .raw = std.Io.Duration.fromMilliseconds(60_000), .clock = .awake },
};

fn writeFileAt(io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

/// Absolute path of `sub` inside the tmp dir.
fn absPath(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, sub: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, sub });
}

/// Compose the stub the completions generator emits for `shell` given a
/// one-row registry, via the real compose path.
fn composeStub(
    a: std.mem.Allocator,
    io: Io,
    tmp: *std.testing.TmpDir,
    shell: []const u8,
    gen_rel: []const u8,
    registry: []const u8,
    stub_suffix: []const u8,
) ![]const u8 {
    const gen_src = try std.fmt.allocPrint(a, "src/{s}", .{gen_rel});
    const directive = try std.fmt.allocPrint(a, "# mox: completions {s} \"data/completions.toml\"\n", .{shell});
    try writeFileAt(io, tmp.dir, gen_src, directive);
    try writeFileAt(io, tmp.dir, "data/completions.toml", registry);

    const src_dir = try absPath(a, io, tmp, "src");
    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    var bindings_r: mox.dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    const outputs = (try mox.compose.catB.composeGenerator(a, io, tree.files[0], &bindings_r, null, null, null)).?;
    for (outputs) |o| {
        if (std.mem.endsWith(u8, o.live_path, stub_suffix)) return o.content;
    }
    unreachable;
}

fn runShell(a: std.mem.Allocator, io: Io, argv: []const []const u8) !?[]const u8 {
    const result = std.process.run(a, io, .{
        .argv = argv,
        .timeout = wall_timeout,
        .stdout_limit = std.Io.Limit.limited(1 << 20),
    }) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    return result.stdout;
}

/// zpty harness: complete `cmdline` twice in a fresh interactive compsys
/// session, printing FIRST-TAB-COMPLETED / SECOND-TAB-COMPLETED when `word`
/// lands in the buffer. All keystrokes wait on the SETUP-DONE barrier.
fn zptyHarness(a: std.mem.Allocator, bin: []const u8, comp: []const u8, cmdline: []const u8, word: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\zmodload zsh/zpty || {{ print HARNESS-NO-ZPTY; exit 1 }}
        \\ACC=""
        \\drain() {{ local chunk; while zpty -rt z chunk 2>/dev/null; do ACC+=$chunk; done }}
        \\wait_word() {{ local i=0; while (( i < ${{2:-60}} )); do drain; [[ $ACC == *"$1"* ]] && return 0; sleep 0.1; (( i++ )); done; return 1 }}
        \\zpty z zsh -f -i
        \\zpty -w z "TERM=vt100; PATH='{s}':\$PATH; fpath=('{s}' \$fpath); autoload -Uz compinit; compinit -u -D && print SETUP-DONE-\$+functions[compdef]"
        \\wait_word "SETUP-DONE-1" 200 || {{ print HARNESS-SETUP-TIMEOUT; zpty -d z; exit 1 }}
        \\ACC=""
        \\zpty -w -n z "{s}"; zpty -w -n z $'\t'
        \\if wait_word "{s}"; then print FIRST-TAB-COMPLETED; else print FIRST-TAB-EMPTY; fi
        \\ACC=""
        \\zpty -w -n z $'\025'"{s}"; zpty -w -n z $'\t'
        \\if wait_word "{s}"; then print SECOND-TAB-COMPLETED; else print SECOND-TAB-EMPTY; fi
        \\zpty -d z
        \\
    , .{ bin, comp, cmdline, word, cmdline, word });
}

fn chmodExec(a: std.mem.Allocator, io: Io, path: []const u8) !void {
    _ = try std.process.run(a, io, .{
        .argv = &.{ "chmod", "+x", path },
        .timeout = wall_timeout,
        .stdout_limit = std.Io.Limit.limited(4096),
    });
}

fn runZshCase(fake_tool_script: []const u8, registry: []const u8, cmdline: []const u8, word: []const u8) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stub = try composeStub(a, io, &tmp, "zsh", ".zcomp/completions.gen", registry, "_mytool");
    try writeFileAt(io, tmp.dir, "comp/_mytool", stub);
    try writeFileAt(io, tmp.dir, "bin/mytool", fake_tool_script);
    const tool_path = try absPath(a, io, &tmp, "bin/mytool");
    try chmodExec(a, io, tool_path);

    const bin = try absPath(a, io, &tmp, "bin");
    const comp = try absPath(a, io, &tmp, "comp");
    const harness = try zptyHarness(a, bin, comp, cmdline, word);
    try writeFileAt(io, tmp.dir, "harness.zsh", harness);
    const harness_path = try absPath(a, io, &tmp, "harness.zsh");

    const out = (try runShell(a, io, &.{ "zsh", harness_path })) orelse return error.SkipZigTest;
    if (std.mem.indexOf(u8, out, "HARNESS-NO-ZPTY") != null) return error.SkipZigTest;
    std.testing.expect(std.mem.indexOf(u8, out, "FIRST-TAB-COMPLETED") != null) catch |e| {
        std.debug.print("zsh harness output:\n{s}\n", .{out});
        return e;
    };
    try std.testing.expect(std.mem.indexOf(u8, out, "SECOND-TAB-COMPLETED") != null);
}

test "zsh stub: clap-style script completes on the first tab of a session" {
    // The generated script self-dispatches only via a funcstack guard, which
    // never fires under eval -- the stub's explicit tail must carry it.
    try runZshCase(
        \\#!/bin/sh
        \\cat <<'ZEOF'
        \\#compdef mytool
        \\_mytool() {
        \\  compadd onlymatch
        \\}
        \\if [ "$funcstack[1]" = "_mytool" ]; then
        \\    _mytool "$@"
        \\else
        \\    compdef _mytool mytool
        \\fi
        \\ZEOF
        \\
    ,
        \\[[completions]]
        \\name = "mytool"
        \\command = "mytool completion"
        \\
    , "mytool on", "onlymatch");
}

test "zsh stub: compdef-registering script dispatches via zsh_dispatch" {
    // The script defines a differently-named function and only registers a
    // compdef; the stub's explicit tail must call the declared dispatcher.
    try runZshCase(
        \\#!/bin/sh
        \\cat <<'ZEOF'
        \\_my_complete() {
        \\  compadd dispatched
        \\}
        \\compdef _my_complete mytool
        \\ZEOF
        \\
    ,
        \\[[completions]]
        \\name = "mytool"
        \\command = "mytool completion"
        \\zsh_dispatch = "_my_complete"
        \\
    , "mytool di", "dispatched");
}

test "fish stub: sourced on demand, candidates come from the live tool" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stub = try composeStub(a, io, &tmp, "fish", ".config/fish/completions/completions.gen",
        \\[[completions]]
        \\name = "mytool"
        \\command = "mytool completion"
        \\
    , "mytool.fish");
    try writeFileAt(io, tmp.dir, "comp/mytool.fish", stub);
    try writeFileAt(io, tmp.dir, "bin/mytool",
        \\#!/bin/sh
        \\echo 'complete -c mytool -f -a onlymatch'
        \\
    );
    const tool_path = try absPath(a, io, &tmp, "bin/mytool");
    try chmodExec(a, io, tool_path);

    const bin = try absPath(a, io, &tmp, "bin");
    const comp = try absPath(a, io, &tmp, "comp");
    const script = try std.fmt.allocPrint(
        a,
        "set -p PATH '{s}'; set -p fish_complete_path '{s}'; complete -C'mytool '",
        .{ bin, comp },
    );
    const out = (try runShell(a, io, &.{ "fish", "-c", script })) orelse return error.SkipZigTest;
    std.testing.expect(std.mem.indexOf(u8, out, "onlymatch") != null) catch |e| {
        std.debug.print("fish output:\n{s}\n", .{out});
        return e;
    };
}

test "bash stub: sourcing registers the live tool completion" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stub = try composeStub(a, io, &tmp, "bash", ".local/share/bash-completion/completions/completions.gen",
        \\[[completions]]
        \\name = "mytool"
        \\command = "mytool completion"
        \\
    , "completions/mytool");
    try writeFileAt(io, tmp.dir, "comp/mytool", stub);
    try writeFileAt(io, tmp.dir, "bin/mytool",
        \\#!/bin/sh
        \\echo "_mytool(){ COMPREPLY=(onlymatch); }; complete -F _mytool mytool"
        \\
    );
    try chmodExec(a, io, try absPath(a, io, &tmp, "bin/mytool"));

    const bin = try absPath(a, io, &tmp, "bin");
    const comp = try absPath(a, io, &tmp, "comp");
    const script = try std.fmt.allocPrint(
        a,
        "PATH='{s}':$PATH; source '{s}/mytool' && complete -p mytool && _mytool && echo COMPREPLY=$COMPREPLY",
        .{ bin, comp },
    );
    const out = (try runShell(a, io, &.{ "bash", "-c", script })) orelse return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, out, "complete -F _mytool mytool") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "COMPREPLY=onlymatch") != null);
}

test "powershell stub: first completion request loads and answers" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stub = try composeStub(a, io, &tmp, "powershell", ".config/powershell/completions/completions.gen",
        \\[[completions]]
        \\name = "mytool"
        \\command = "mytool completion"
        \\
    , "completions/mytool.ps1");
    try writeFileAt(io, tmp.dir, "comp/mytool.ps1", stub);
    try writeFileAt(io, tmp.dir, "bin/mytool",
        \\#!/bin/sh
        \\cat <<PEOF
        \\Register-ArgumentCompleter -Native -CommandName mytool -ScriptBlock {
        \\    param(\$wordToComplete, \$commandAst, \$cursorPosition)
        \\    [System.Management.Automation.CompletionResult]::new("onlymatch", "onlymatch", "ParameterValue", "onlymatch")
        \\}
        \\PEOF
        \\
    );
    try chmodExec(a, io, try absPath(a, io, &tmp, "bin/mytool"));

    const bin = try absPath(a, io, &tmp, "bin");
    const comp = try absPath(a, io, &tmp, "comp");
    const script = try std.fmt.allocPrint(a,
        \\$env:PATH = '{s}:' + $env:PATH
        \\. '{s}/mytool.ps1'
        \\$r1 = (TabExpansion2 'mytool on' 9).CompletionMatches
        \\if ($r1.CompletionText -contains 'onlymatch') {{ Write-Output FIRST-CALL-COMPLETED }} else {{ Write-Output FIRST-CALL-EMPTY }}
        \\$r2 = (TabExpansion2 'mytool on' 9).CompletionMatches
        \\if ($r2.CompletionText -contains 'onlymatch') {{ Write-Output SECOND-CALL-COMPLETED }} else {{ Write-Output SECOND-CALL-EMPTY }}
        \\
    , .{ bin, comp });
    try writeFileAt(io, tmp.dir, "run.ps1", script);
    const run_path = try absPath(a, io, &tmp, "run.ps1");

    const out = (try runShell(a, io, &.{ "pwsh", "-NoProfile", "-File", run_path })) orelse return error.SkipZigTest;
    std.testing.expect(std.mem.indexOf(u8, out, "FIRST-CALL-COMPLETED") != null) catch |e| {
        std.debug.print("pwsh output:\n{s}\n", .{out});
        return e;
    };
    try std.testing.expect(std.mem.indexOf(u8, out, "SECOND-CALL-COMPLETED") != null);
}
