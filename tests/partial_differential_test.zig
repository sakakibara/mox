//! Flagship differential for partial ownership: the codex keymap fixtures.
//!
//! The behavioral baseline is the hand-written patcher this feature replaces
//! (`codex-keybindings.sh` plus the keymap assertions of the dotfiles
//! sandbox test): a live `~/.codex/config.toml` holds program state (model,
//! projects, hooks) and three user-managed keymap tables. For identical
//! inputs, mox's owned tables must semantically match the script's keymap
//! block, the remainder must match byte-for-byte, and a second apply must
//! write nothing.
//!
//! The script refused any config containing a multiline string -- a
//! regex-parser artifact. mox parses real TOML, so that fixture is a
//! POSITIVE case here: patched, with the decoy string bytes preserved
//! verbatim. The mid-patch-change refusal (the script's post-fsync stat
//! recheck) is unit-covered by `writeAtomicPartial` in src/apply/write.zig
//! and is not duplicated here.

const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");
const mox = @import("mox");

const Io = std.Io;

const testutil = @import("testutil.zig");

/// The keymap block `codex-keybindings.sh` asserts into the live file,
/// verbatim. It doubles as the composed source: the script's output block
/// and the source parse to the same document.
const keymap_block =
    \\[tui.keymap.global]
    \\open_transcript = "ctrl-shift-t"
    \\open_external_editor = "ctrl-shift-g"
    \\copy = "ctrl-shift-o"
    \\clear_terminal = "ctrl-l"
    \\
    \\[tui.keymap.composer]
    \\submit = ["enter", "ctrl-j", "ctrl-m"]
    \\history_search_previous = "ctrl-r"
    \\history_search_next = "ctrl-s"
    \\
    \\[tui.keymap.editor]
    \\insert_newline = ["shift-enter", "alt-enter", "ctrl-shift-j"]
    \\move_left = "ctrl-b"
    \\move_right = "ctrl-f"
    \\move_up = "ctrl-p"
    \\move_down = "ctrl-n"
    \\move_word_left = "alt-b"
    \\move_word_right = "alt-f"
    \\move_line_start = "ctrl-a"
    \\move_line_end = "ctrl-e"
    \\delete_backward = ["backspace", "ctrl-h"]
    \\delete_forward = "ctrl-d"
    \\delete_backward_word = "ctrl-w"
    \\delete_forward_word = "alt-d"
    \\kill_line_start = "ctrl-u"
    \\kill_line_end = "ctrl-k"
    \\yank = "ctrl-y"
    \\
;

const own_attrs =
    \\[".codex/config.toml"]
    \\own = ["tui.keymap.global", "tui.keymap.composer", "tui.keymap.editor"]
    \\
;

/// The sandbox test's live fixture: program state around one stale keymap
/// table.
const live_fixture =
    \\model = "test-model"
    \\
    \\[projects."/tmp/example"]
    \\trust_level = "trusted"
    \\
    \\[tui.keymap.editor]
    \\move_left = "broken"
    \\
    \\[hooks.state.example]
    \\trusted_hash = "test-hash"
    \\
;

/// Everything in `live_fixture` outside the keymap tables, byte-for-byte:
/// what the patched file's remainder must still hold.
const live_remainder =
    \\model = "test-model"
    \\
    \\[projects."/tmp/example"]
    \\trust_level = "trusted"
    \\
    \\[hooks.state.example]
    \\trusted_hash = "test-hash"
    \\
;

const own_raws = [_][]const u8{ "tui.keymap.global", "tui.keymap.composer", "tui.keymap.editor" };

fn writeFixture(io: Io, tmp: *std.testing.TmpDir, live: []const u8, attrs: []const u8) !void {
    try tmp.dir.createDirPath(io, "repo/src/.codex");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.codex/config.toml", .data = keymap_block });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.mox/attributes.toml", .data = attrs });
    try tmp.dir.createDirPath(io, "home/.codex");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.codex/config.toml", .data = live });
}

fn read(io: Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
}

fn mtimeNs(io: Io, path: []const u8) !i96 {
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    return st.mtime.nanoseconds;
}

fn ownPaths(a: std.mem.Allocator) ![]mox.source.tree.OwnPath {
    const out = try a.alloc(mox.source.tree.OwnPath, own_raws.len);
    for (&own_raws, out) |raw, *o| {
        o.* = .{ .raw = raw, .segments = try mox.source.keypath.parse(a, raw) };
    }
    return out;
}

/// `text` minus every owned span and wrapper region -- the bytes that
/// belong to the program, cut with the same locator production uses.
fn remainderOf(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const loc = try mox.apply.partial.locateSpans(a, .toml, text, try ownPaths(a), null);
    var regions: std.ArrayList(mox.apply.partial.Span) = .empty;
    for (loc.spans) |s| {
        if (s) |sp| try regions.append(a, sp);
    }
    for (loc.wrappers) |w| try regions.append(a, w);
    std.mem.sort(mox.apply.partial.Span, regions.items, {}, spanLess);
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (regions.items) |r| {
        if (r.start > cursor) try out.appendSlice(a, text[cursor..r.start]);
        cursor = @max(cursor, r.end);
    }
    try out.appendSlice(a, text[cursor..]);
    return out.toOwnedSlice(a);
}

fn spanLess(_: void, x: mox.apply.partial.Span, y: mox.apply.partial.Span) bool {
    return x.start < y.start;
}

/// Semantic equality of the patched file's `tui` subtree against the
/// script's keymap block -- the cross-serializer comparison Oracle 1 pins.
fn expectKeymapMatchesScript(a: std.mem.Allocator, patched_text: []const u8) !void {
    const patched = try toml.parse(a, patched_text, .{});
    const expected = try toml.parse(a, keymap_block, .{});
    const got = patched.get("tui") orelse return error.TestExpectedTuiTable;
    const want = expected.get("tui").?;
    try std.testing.expect(want.eql(got));
}

test "codex differential: force reassertion matches the script's keymap and remainder byte-for-byte" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeFixture(io, &tmp, live_fixture, own_attrs);
    const c = try testutil.setup(a, io, &tmp, .{});
    const live = try c.homePath(".codex/config.toml");

    // First contact with differing owned content (the stale editor table,
    // the missing global/composer tables) is drift, never a silent write.
    const skip = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), skip.rc);
    try std.testing.expect(std.mem.indexOf(u8, skip.err, "DRIFT") != null);
    try std.testing.expectEqualStrings(live_fixture, try read(io, a, live));

    // The script's unconditional patch corresponds to consented reassertion.
    const forced = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expectEqual(@as(u8, 0), forced.rc);
    const patched = try read(io, a, live);

    // (1) Owned tables semantically equal the script's keymap block.
    try expectKeymapMatchesScript(a, patched);

    // The program values the sandbox test asserts all survive.
    const doc = try toml.parse(a, patched, .{});
    try std.testing.expectEqualStrings("test-model", doc.get("model").?.string);
    const projects = doc.table.get("projects").?.table;
    try std.testing.expectEqualStrings("trusted", projects.get("/tmp/example").?.table.get("trust_level").?.string);
    try std.testing.expectEqualStrings("test-hash", doc.get("hooks.state.example.trusted_hash").?.string);

    // (2) Remainder byte-for-byte identical to live's non-keymap bytes.
    try std.testing.expectEqualStrings(live_remainder, try remainderOf(a, patched));

    // (3) Idempotency: the second apply writes nothing.
    const before = try mtimeNs(io, live);
    const again = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), again.rc);
    try std.testing.expect(std.mem.indexOf(u8, again.out, "unchanged") != null);
    try std.testing.expectEqual(before, try mtimeNs(io, live));
}

test "codex differential: adoption path is clean when live owned content already matches" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The script's own output state: program remainder plus the exact
    // keymap block. mox adopts it without changing a byte.
    const adopted_live = live_remainder ++ "\n" ++ keymap_block;
    try writeFixture(io, &tmp, adopted_live, own_attrs);
    const c = try testutil.setup(a, io, &tmp, .{});
    const live = try c.homePath(".codex/config.toml");

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "adopted") != null);
    try std.testing.expectEqualStrings(adopted_live, try read(io, a, live));

    const before = try mtimeNs(io, live);
    const again = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), again.rc);
    try std.testing.expect(std.mem.indexOf(u8, again.out, "unchanged") != null);
    try std.testing.expectEqual(before, try mtimeNs(io, live));
}

test "codex differential: a multiline-string decoy is patched with its bytes preserved verbatim" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The script refused this file outright (its regex would have matched
    // the decoy header inside the string). It is valid TOML: a positive
    // fidelity case for a real parser.
    const decoy_live =
        \\model_instructions = """
        \\[tui.keymap.editor]
        \\This is data, not a TOML table.
        \\"""
        \\
    ;
    try writeFixture(io, &tmp, decoy_live, own_attrs);
    const c = try testutil.setup(a, io, &tmp, .{});
    const live = try c.homePath(".codex/config.toml");

    // No owned path exists live yet; populated composed content on first
    // contact is drift until consented.
    const skip = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), skip.rc);
    try std.testing.expectEqualStrings(decoy_live, try read(io, a, live));

    const forced = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expectEqual(@as(u8, 0), forced.rc);
    const patched = try read(io, a, live);

    // The decoy string's bytes survive verbatim and still parse as a string.
    try std.testing.expect(std.mem.indexOf(u8, patched, decoy_live) != null);
    const doc = try toml.parse(a, patched, .{});
    try std.testing.expectEqualStrings(
        "[tui.keymap.editor]\nThis is data, not a TOML table.\n",
        doc.get("model_instructions").?.string,
    );
    try expectKeymapMatchesScript(a, patched);
    try std.testing.expectEqualStrings(decoy_live, try remainderOf(a, patched));
}

const script_ext = if (builtin.os.tag == .windows) ".ps1" else ".sh";

fn writeExecScript(io: Io, tmp: *std.testing.TmpDir, sub: []const u8, content: []const u8, abs: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| try tmp.dir.createDirPath(io, parent);
    try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = content });
    if (builtin.os.tag == .windows) return;
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..abs.len], abs);
    zbuf[abs.len] = 0;
    _ = std.c.chmod(@ptrCast(&zbuf), 0o755);
}

test "codex differential: the check hook stub validates the candidate and the write proceeds" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Mimics the codex stub the dotfiles sandbox test uses: sanity-check the
    // candidate document and require every keymap table, then accept. (The
    // real repo script wraps `codex app-server` with its expected-exit-1
    // transport contract; the stub keeps the same accept/refuse shape.)
    const check_rel = "scripts/check/codex-config" ++ script_ext;
    const attrs = "[\".codex/config.toml\"]\n" ++
        "own = [\"tui.keymap.global\", \"tui.keymap.composer\", \"tui.keymap.editor\"]\n" ++
        "check = [\"" ++ check_rel ++ "\"]\n";
    const checker: []const u8 = if (builtin.os.tag == .windows)
        \\if (-not (Test-Path -LiteralPath $env:MOX_CHECK_FILE)) { exit 1 }
        \\foreach ($t in '[tui.keymap.global]', '[tui.keymap.composer]', '[tui.keymap.editor]') {
        \\    if (-not (Select-String -LiteralPath $env:MOX_CHECK_FILE -SimpleMatch $t -Quiet)) { exit 1 }
        \\}
        \\if (-not (Select-String -LiteralPath $env:MOX_CHECK_FILE -SimpleMatch 'open_transcript = "ctrl-shift-t"' -Quiet)) { exit 1 }
        \\New-Item -ItemType File -Force -Path (Join-Path (Split-Path $env:MOX_CHECK_DIR) 'check-ran') | Out-Null
        \\exit 0
        \\
    else
        \\#!/bin/sh
        \\[ -f "$MOX_CHECK_FILE" ] || exit 1
        \\grep -q '^\[tui\.keymap\.global\]$' "$MOX_CHECK_FILE" || exit 1
        \\grep -q '^\[tui\.keymap\.composer\]$' "$MOX_CHECK_FILE" || exit 1
        \\grep -q '^\[tui\.keymap\.editor\]$' "$MOX_CHECK_FILE" || exit 1
        \\grep -q '^open_transcript = "ctrl-shift-t"$' "$MOX_CHECK_FILE" || exit 1
        \\: > "$MOX_CHECK_DIR/../check-ran"
        \\exit 0
        \\
    ;

    try writeFixture(io, &tmp, live_fixture, attrs);
    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const abs = try std.fs.path.join(a, &.{ root, "repo", "scripts", "check", "codex-config" ++ script_ext });
    try writeExecScript(io, &tmp, "repo/" ++ check_rel, checker, abs);

    const c = try testutil.setup(a, io, &tmp, .{});
    const live = try c.homePath(".codex/config.toml");

    const forced = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expectEqual(@as(u8, 0), forced.rc);
    const patched = try read(io, a, live);
    try expectKeymapMatchesScript(a, patched);
    try std.testing.expectEqualStrings(live_remainder, try remainderOf(a, patched));
    // The hook really ran (its side-effect marker exists in state).
    try std.testing.expect(fileExists(io, try std.fs.path.join(a, &.{ c.state, "check-ran" })));
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
