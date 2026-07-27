const std = @import("std");
const builtin = @import("builtin");
const mox = @import("mox");

const Io = std.Io;

const testutil = @import("testutil.zig");
const Harness = testutil.Harness;
const containsAnywhere = testutil.containsAnywhere;

fn setup(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, editor: ?[]const u8) !Harness {
    return testutil.setup(a, io, tmp, .{ .create_repo_src = true, .editor = editor });
}

fn writeRepo(io: Io, tmp: *std.testing.TmpDir, sub: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| try tmp.dir.createDirPath(io, parent);
    try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = content });
}

fn read(io: Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn chmodPath(a: std.mem.Allocator, path: []const u8, mode: u32) !void {
    const z = try a.dupeZ(u8, path);
    _ = std.c.chmod(z.ptr, @intCast(mode));
}

/// Write an executable script at `sub` (relative to tmp) with mode 0o755.
/// `abs` is its absolute path, needed because std.c.chmod takes an absolute
/// NUL-terminated path.
fn writeExecScript(io: Io, tmp: *std.testing.TmpDir, sub: []const u8, content: []const u8, abs: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| try tmp.dir.createDirPath(io, parent);
    try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = content });
    if (builtin.os.tag == .windows) return; // no exec bit to set
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..abs.len], abs);
    zbuf[abs.len] = 0;
    _ = std.c.chmod(@ptrCast(&zbuf), 0o755);
}

/// What the stand-in editor recorded. `echo` ends the line; `printf` does not.
fn editedPath(recorded: []const u8) []const u8 {
    return std.mem.trimEnd(u8, recorded, "\r\n");
}

/// A stand-in $EDITOR that records the path it was handed, written in the
/// platform's own script dialect. Windows has no shebang, and a batch file is
/// not itself spawnable, so it goes through cmd -- which mox reaches because
/// $EDITOR may carry arguments (`code -w`), split on whitespace.
const FakeEditor = struct {
    /// What $EDITOR is set to.
    command: []const u8,

    fn install(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, root: []const u8, marker: []const u8) !FakeEditor {
        if (builtin.os.tag == .windows) {
            // PowerShell, not a batch file: cmd splits a batch parameter on '='
            // as well as on spaces, and an overlay is named `os=darwin`, so %1
            // would arrive cut at `os`.
            const abs = try std.fs.path.join(a, &.{ root, "fake-editor.ps1" });
            const body = try std.fmt.allocPrint(
                a,
                "Set-Content -LiteralPath '{s}' -NoNewline -Value $args[0]\r\n",
                .{marker},
            );
            try writeExecScript(io, tmp, "fake-editor.ps1", body, abs);
            return .{ .command = try std.fmt.allocPrint(a, "powershell -NoProfile -File {s}", .{abs}) };
        }
        const abs = try std.fs.path.join(a, &.{ root, "fake-editor.sh" });
        const body = try std.fmt.allocPrint(a, "#!/bin/sh\nprintf '%s' \"$1\" > \"{s}\"\n", .{marker});
        try writeExecScript(io, tmp, "fake-editor.sh", body, abs);
        return .{ .command = abs };
    }
};

test "diff: a drifted file shows its hunk, a clean file shows nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\nb\nc\n");

    // Apply writes the live file from the current source.
    _ = try h.run(&.{ "mox", "apply" });

    // No source change yet: diff is clean.
    const clean = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), clean.rc);
    try std.testing.expectEqualStrings("", clean.out);

    // Change the source so composed now differs from the live file.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\nB\nc\n");
    const drifted = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), drifted.rc);
    try std.testing.expect(std.mem.indexOf(u8, drifted.out, "-b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, drifted.out, "+B\n") != null);

    // --stat summarizes instead of printing hunks.
    const stat = try h.run(&.{ "mox", "diff", "--stat" });
    try std.testing.expectEqual(@as(u8, 0), stat.rc);
    try std.testing.expect(std.mem.indexOf(u8, stat.out, "+1 -1") != null);
}

test "diff --color=always colors +/- lines; --color=never and the non-TTY default do not" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\nb\nc\n");
    _ = try h.run(&.{ "mox", "apply" });
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\nB\nc\n");

    const colored = try h.run(&.{ "mox", "diff", "--color=always" });
    try std.testing.expectEqual(@as(u8, 0), colored.rc);
    try std.testing.expect(std.mem.indexOf(u8, colored.out, "\x1b[31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored.out, "\x1b[32m") != null);

    const never = try h.run(&.{ "mox", "diff", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), never.rc);
    try std.testing.expect(std.mem.indexOf(u8, never.out, "\x1b[") == null);

    // The harness's captured stdout is not a real TTY, so the default `auto`
    // flag stays off with no `--color` given at all.
    const default = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), default.rc);
    try std.testing.expect(std.mem.indexOf(u8, default.out, "\x1b[") == null);
}

test "status: an ignored tracked file is not reported" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.config/oldtool/conf", "x\n");
    try writeRepo(io, &tmp, "repo/.moxignore", ".config/oldtool/\n");

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "oldtool") == null);
}

test "status: a path argument limits output to that file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\n");
    try writeRepo(io, &tmp, "repo/src/.bashrc", "b\n");

    const live = try h.liveOf(".zshrc");
    const r = try h.run(&.{ "mox", "status", live });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, ".zshrc") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, ".bashrc") == null);

    // No-arg behavior is unchanged: both files are reported.
    const all = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, all.out, ".zshrc") != null);
    try std.testing.expect(std.mem.indexOf(u8, all.out, ".bashrc") != null);
}

test "status: an unmanaged path argument exits non-zero reporting not managed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\n");

    const nope = try h.liveOf(".nope");
    const r = try h.run(&.{ "mox", "status", nope });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not managed") != null);
}

test "status: no probe-log section when the run probed no tool= or env= name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\n");

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "probed:") == null);
}

test "status: the tool probe log names every tool= name this run asked, misses highlighted" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const bin_dir = try std.fs.path.join(a, &.{ root, "bin" });
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/fd", .data = "" });

    const h = try testutil.setup(a, io, &tmp, .{
        .create_repo_src = true,
        .extra_env = &.{.{ .name = "PATH", .value = bin_dir }},
    });
    try writeRepo(io, &tmp, "repo/src/.has-fd", "# mox: when tool=fd\nyes\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.has-hedrr", "# mox: when tool=hedrr\nyes\n# mox: end\n");

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "tool probed: fd present, hedrr ABSENT\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "env probed:") == null);
}

test "status: the env probe log names every env= name this run asked, misses highlighted" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{
        .create_repo_src = true,
        .extra_env = &.{.{ .name = "MOX_STATUS_PROBE_VAR", .value = "1" }},
    });
    try writeRepo(io, &tmp, "repo/src/.has-var", "# mox: when env=MOX_STATUS_PROBE_VAR\nyes\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.no-var", "# mox: when env=MOX_STATUS_PROBE_TYPO\nyes\n# mox: end\n");

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(
        u8,
        r.out,
        "env probed: MOX_STATUS_PROBE_TYPO ABSENT, MOX_STATUS_PROBE_VAR present\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "tool probed:") == null);
}

test "diff: a path argument limits the stat summary to that file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\nb\nc\n");
    try writeRepo(io, &tmp, "repo/src/.bashrc", "x\ny\nz\n");
    _ = try h.run(&.{ "mox", "apply" });

    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\nB\nc\n");
    try writeRepo(io, &tmp, "repo/src/.bashrc", "x\nY\nz\n");

    const live = try h.liveOf(".zshrc");
    const r = try h.run(&.{ "mox", "diff", "--stat", live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, ".zshrc") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, ".bashrc") == null);
}

test "diff: an unmanaged path argument exits non-zero reporting not managed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\n");

    const nope = try h.liveOf(".nope");
    const r = try h.run(&.{ "mox", "diff", nope });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not managed") != null);
}

test "__complete: the managed-file dynamic resolver offers every managed live path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\n");
    try writeRepo(io, &tmp, "repo/src/.bashrc", "b\n");

    const r = try h.run(&.{ "mox", "__complete", "status", "" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    const zshrc = try h.liveOf(".zshrc");
    const bashrc = try h.liveOf(".bashrc");
    try std.testing.expect(std.mem.indexOf(u8, r.out, zshrc) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, bashrc) != null);
}

test "edit: base name launches $EDITOR on the source; unmanaged errors with a candidate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const marker = try std.fs.path.join(a, &.{ root, "edited-path" });
    const editor = try FakeEditor.install(a, io, &tmp, root, marker);

    const h = try setup(a, io, &tmp, editor.command);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "hello\n");

    const r = try h.run(&.{ "mox", "edit", ".zshrc" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    // The editor was invoked with the absolute source path.
    const edited = editedPath(try read(io, a, marker));
    const src_abs = try h.srcOf(".zshrc");
    try std.testing.expectEqualStrings(src_abs, edited);

    // An unmanaged name errors and reports the candidate source path.
    const miss = try h.run(&.{ "mox", "edit", ".nope" });
    try std.testing.expectEqual(@as(u8, 1), miss.rc);
    try std.testing.expect(std.mem.indexOf(u8, miss.err, "not managed") != null);
}

test "edit: --axis resolves the matching overlay file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const marker = try std.fs.path.join(a, &.{ root, "edited-path" });
    const editor = try FakeEditor.install(a, io, &tmp, root, marker);

    const h = try setup(a, io, &tmp, editor.command);
    try writeRepo(io, &tmp, "repo/src/.gitconfig", "[user]\n");
    try writeRepo(io, &tmp, "repo/src/.gitconfig.d/os=darwin", "[user]\n  name = mac\n");

    const r = try h.run(&.{ "mox", "edit", ".gitconfig", "--axis", "os=darwin" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    const edited = editedPath(try read(io, a, marker));
    const overlay_abs = try h.srcOf(".gitconfig.d/os=darwin");
    try std.testing.expectEqualStrings(overlay_abs, edited);
}

test "export --resolved bakes the same bytes apply writes to live" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\n");
    try writeRepo(io, &tmp, "repo/src/.config/app/conf", "k = v\n");

    _ = try h.run(&.{ "mox", "apply" });

    const out_dir = try std.fs.path.join(a, &.{ h.root, "baked" });
    const r = try h.run(&.{ "mox", "export", "--resolved", out_dir });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    // Every exported file byte-matches the live file apply produced.
    const files = [_][]const u8{ ".zshrc", ".config/app/conf" };
    for (files) |rel| {
        const live = try read(io, a, try h.liveOf(rel));
        const baked = try read(io, a, try std.fs.path.join(a, &.{ out_dir, rel }));
        try std.testing.expectEqualStrings(live, baked);
    }
}

/// Absolute path of the sole child inside a directory (used to find the one
/// timestamped trash generation). Errors if the dir is missing or empty.
fn soleChild(io: Io, a: std.mem.Allocator, dir_abs: []const u8) ![]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    if (try it.next(io)) |e| return std.fs.path.join(a, &.{ dir_abs, e.name });
    return error.EmptyDir;
}

test "mv: renames base and its overlay dir, trashing the old source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "base\n");
    try writeRepo(io, &tmp, "repo/src/.zshrc.d/os=darwin", "mac\n");

    const r = try h.run(&.{ "mox", "mv", ".zshrc", ".bashrc" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    try std.testing.expect(!exists(io, try h.srcOf(".zshrc")));
    try std.testing.expect(exists(io, try h.srcOf(".bashrc")));
    // Overlay dir moved with the base (overlay preserved).
    try std.testing.expect(exists(io, try h.srcOf(".bashrc.d/os=darwin")));

    // The old source is recoverable in the trash.
    const trash_gen = try soleChild(io, a, try std.fs.path.join(a, &.{ h.state, "trash" }));
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ trash_gen, "src/.zshrc" })));
}

test "mv: refuses upfront when the destination overlay dir exists (no half-move)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "base\n");
    try writeRepo(io, &tmp, "repo/src/.zshrc.d/os=darwin", "mac\n");
    // A base-less orphan overlay dir already sits at the destination.
    try writeRepo(io, &tmp, "repo/src/.bashrc.d/os=linux", "other\n");

    const r = try h.run(&.{ "mox", "mv", ".zshrc", ".bashrc" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);

    // Nothing moved: the source base and its overlay are untouched, and the
    // destination base was never created.
    try std.testing.expect(exists(io, try h.srcOf(".zshrc")));
    try std.testing.expect(exists(io, try h.srcOf(".zshrc.d/os=darwin")));
    try std.testing.expect(!exists(io, try h.srcOf(".bashrc")));
}

test "remove: trashes source recoverably and leaves the live file orphaned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "content\n");
    _ = try h.run(&.{ "mox", "apply" });

    const r = try h.run(&.{ "mox", "remove", ".zshrc" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    // Source gone, live file still present (orphaned).
    try std.testing.expect(!exists(io, try h.srcOf(".zshrc")));
    try std.testing.expect(exists(io, try h.liveOf(".zshrc")));

    // Recoverable in the trash.
    const trash_gen = try soleChild(io, a, try std.fs.path.join(a, &.{ h.state, "trash" }));
    const recovered = try read(io, a, try std.fs.path.join(a, &.{ trash_gen, "src/.zshrc" }));
    try std.testing.expectEqualStrings("content\n", recovered);
}

test "remove --purge deletes the live file after snapshotting it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "content\n");
    _ = try h.run(&.{ "mox", "apply" });

    const r = try h.run(&.{ "mox", "remove", ".zshrc", "--purge" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(!exists(io, try h.liveOf(".zshrc")));

    // A snapshot of the purged live file exists (recoverable via rollback).
    const snap_gen = try soleChild(io, a, try std.fs.path.join(a, &.{ h.state, "snapshots" }));
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ snap_gen, ".zshrc" })));
}

test "remove: an unknown attributes.toml key refuses with the friendly schema message, not a raw error name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "content\n");
    // A typo'd key (`seed_one` for `seed_once`): the raw zig error name
    // (`UnknownAttributeKey`) must never reach the user.
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "[\".zshrc\"]\nseed_one = true\n");

    const r = try h.run(&.{ "mox", "remove", ".zshrc" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "attributes.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "seed_one") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "UnknownAttributeKey") == null);
}

test "mv: an unknown attributes.toml key refuses with the friendly schema message, not a raw error name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "content\n");
    // A typo'd key (`seed_one` for `seed_once`): the raw zig error name
    // (`UnknownAttributeKey`) must never reach the user.
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "[\".zshrc\"]\nseed_one = true\n");

    const r = try h.run(&.{ "mox", "mv", ".zshrc", ".bashrc" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "attributes.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "seed_one") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "UnknownAttributeKey") == null);
}

test "add-tree: a coupling-graph persistence failure warns as add-tree, not add" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try tmp.dir.createDirPath(io, "home/.config/app");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/app/a.conf", .data = "a\n" });

    try Io.Dir.cwd().createDirPath(io, h.state);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ h.state, "coupling" }), .data = "" });

    const r = try h.run(&.{ "mox", "add-tree", ".config/app" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox add-tree: coupling graph not updated") != null);
}

test "add-tree: adds every non-junk file under a live dir, skipping junk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try tmp.dir.createDirPath(io, "home/.config/app/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/app/a.conf", .data = "a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/app/sub/b.conf", .data = "b\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/app/.DS_Store", .data = "junk" });

    const r = try h.run(&.{ "mox", "add-tree", ".config/app" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Added 2 file(s)") != null);

    try std.testing.expect(exists(io, try h.srcOf(".config/app/a.conf")));
    try std.testing.expect(exists(io, try h.srcOf(".config/app/sub/b.conf")));
    // Junk was not added.
    try std.testing.expect(!exists(io, try h.srcOf(".config/app/.DS_Store")));
}

test "add-tree: ignore file refuses sensitive paths, adds the rest" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);

    // A live ~/.claude-like tree under the harness home.
    try writeRepo(io, &tmp, "home/.claude/CLAUDE.md", "rules\n");
    try writeRepo(io, &tmp, "home/.claude/.credentials.json", "SECRET\n");
    try writeRepo(io, &tmp, "home/.claude/projects/p.jsonl", "{}\n");
    // Repo ignore file.
    try writeRepo(io, &tmp, "repo/.moxignore", ".claude/.credentials.json\n.claude/projects/\n");

    // A shell would have expanded `~/.claude` to this absolute path already.
    const dir = try h.homePath(".claude");
    const r = try h.run(&.{ "mox", "add-tree", dir });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    // The good file is now a source; the secret and the ignored dir are not.
    try std.testing.expect(exists(io, try h.srcOf(".claude/CLAUDE.md")));
    try std.testing.expect(!exists(io, try h.srcOf(".claude/.credentials.json")));
    try std.testing.expect(!exists(io, try h.srcOf(".claude/projects/p.jsonl")));
}

test "add-tree: a missing directory fails with not found instead of adding nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    const r = try h.run(&.{ "mox", "add-tree", ".config/no-such-dir" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not found") != null);
}

test "add-tree: a file argument is refused as not a directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/notes.txt", "n\n");

    const r = try h.run(&.{ "mox", "add-tree", "notes.txt" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not a directory (use 'mox add' for a single file)") != null);
    try std.testing.expect(!exists(io, try h.srcOf("notes.txt")));
}

test "add-tree: rebuilds the coupling graph after a bulk add" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    // `sharedalias` clears the tokenizer's length/entropy filters and occurs
    // in both files, so it must survive the co-occurrence filter.
    try tmp.dir.createDirPath(io, "home/.config/app");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/app/a.conf", .data = "name = sharedalias\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/app/b.conf", .data = "name = sharedalias\n" });

    const r = try h.run(&.{ "mox", "add-tree", ".config/app" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    // The graph was rebuilt once over the bulk add, so both new sources'
    // tokens are indexed for the next commit's coupling pass.
    const graph_path = try std.fs.path.join(a, &.{ h.state, "coupling", "graph.json" });
    try std.testing.expect(exists(io, graph_path));
    const graph = try read(io, a, graph_path);
    try std.testing.expect(std.mem.indexOf(u8, graph, "sharedalias") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph, "a.conf") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph, "b.conf") != null);
}

test "add: a relative path resolves against HOME" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/notes.txt", "n\n");

    const r = try h.run(&.{ "mox", "add", "notes.txt" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(exists(io, try h.srcOf("notes.txt")));
}

test "add: an unknown attributes.toml key refuses with the friendly schema message, not a raw error name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    // A symlink capture unconditionally records into attributes.toml
    // (`symlink = true`), so it always reaches the load this exercises.
    const link = try h.homePath("link.conf");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/real.conf", .data = "x\n" });
    try Io.Dir.cwd().symLink(io, "real.conf", link, .{});
    // A typo'd key (`seed_one` for `seed_once`): the raw zig error name
    // (`UnknownAttributeKey`) must never reach the user.
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "[\"link.conf\"]\nseed_one = true\n");

    const r = try h.run(&.{ "mox", "add", "link.conf" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "attributes.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "seed_one") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "UnknownAttributeKey") == null);
}

test "add: a coupling-graph persistence failure warns, but the add itself still succeeds" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/notes.txt", "n\n");

    // A plain FILE where the coupling dir belongs: saveGraph's createDirPath
    // fails, so the rebuild this add triggers cannot persist.
    try Io.Dir.cwd().createDirPath(io, h.state);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ h.state, "coupling" }), .data = "" });

    const r = try h.run(&.{ "mox", "add", "notes.txt" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(exists(io, try h.srcOf("notes.txt")));
    try std.testing.expect(std.mem.indexOf(u8, r.err, "coupling graph not updated") != null);
}

test "add --own: a relative path resolves against HOME" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/app.toml", "keep = 1\n\n[mine]\nx = 2\n");

    const r = try h.run(&.{ "mox", "add", "--own", "mine", "app.toml" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    const src = try read(io, a, try h.srcOf("app.toml"));
    try std.testing.expect(std.mem.indexOf(u8, src, "# mox: own mine") != null);
}

test "add: a ./-spelled path records the canonical attribute key; apply restores its mode" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/priv.txt", "secret\n");
    const live = try h.homePath("priv.txt");
    try chmodPath(a, live, 0o600);

    const r = try h.run(&.{ "mox", "add", "./priv.txt" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(exists(io, try h.srcOf("priv.txt")));

    // The mode is keyed by the canonical spelling the source walk derives,
    // not by the `./`-spelled add argument.
    var attrs = try mox.source.attributes.load(a, io, h.repo, null);
    try std.testing.expectEqual(@as(u32, 0o600), attrs.mode("priv.txt").?);
    try std.testing.expect(attrs.mode("./priv.txt") == null);

    // Losing the live file and re-applying restores the recorded 0600.
    try Io.Dir.cwd().deleteFile(io, live);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const st = try Io.Dir.cwd().statFile(io, live, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}

test "edit/remove: a ./-spelled name resolves to the managed file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const marker = try std.fs.path.join(a, &.{ root, "edited-path" });
    const editor = try FakeEditor.install(a, io, &tmp, root, marker);

    const h = try setup(a, io, &tmp, editor.command);
    try writeRepo(io, &tmp, "home/notes.txt", "n\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "add", "notes.txt" })).rc);

    const re = try h.run(&.{ "mox", "edit", "./notes.txt" });
    try std.testing.expectEqual(@as(u8, 0), re.rc);
    try std.testing.expectEqualStrings(try h.srcOf("notes.txt"), editedPath(try read(io, a, marker)));

    const rr = try h.run(&.{ "mox", "remove", "./notes.txt" });
    try std.testing.expectEqual(@as(u8, 0), rr.rc);
    try std.testing.expect(!exists(io, try h.srcOf("notes.txt")));
}

test "add: notes a secret-looking file that is not ignored" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/.ssh/deploy.pem", "KEY\n");
    const live = try h.homePath(".ssh/deploy.pem");

    const r = try h.run(&.{ "mox", "add", live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "looks like a secret") != null);
    // It is still added (non-blocking).
    try std.testing.expect(exists(io, try h.srcOf(".ssh/deploy.pem")));
}

test "add: refuses an ignored path with a hint; --force overrides" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/.ssh/id_rsa", "PRIVATE\n");
    try writeRepo(io, &tmp, "repo/.moxignore", ".ssh/id_rsa\n");
    const live = try h.homePath(".ssh/id_rsa");

    const refused = try h.run(&.{ "mox", "add", live });
    try std.testing.expectEqual(@as(u8, 1), refused.rc);
    try std.testing.expect(std.mem.indexOf(u8, refused.err, "matches an ignore rule") != null);
    try std.testing.expect(!exists(io, try h.srcOf(".ssh/id_rsa")));

    const forced = try h.run(&.{ "mox", "add", live, "--force" });
    try std.testing.expectEqual(@as(u8, 0), forced.rc);
    try std.testing.expect(exists(io, try h.srcOf(".ssh/id_rsa")));
}

test "add: refuses a path under a dir-only ignored ancestor; --force overrides" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/.claude/projects/session.jsonl", "{}\n");
    // A dir-only rule: isIgnored alone would miss a leaf checked in isolation
    // (dir_only is skipped when is_dir is false), so this only refuses via the
    // ancestor-aware isPathIgnored.
    try writeRepo(io, &tmp, "repo/.moxignore", ".claude/projects/\n");
    const live = try h.homePath(".claude/projects/session.jsonl");

    const refused = try h.run(&.{ "mox", "add", live });
    try std.testing.expectEqual(@as(u8, 1), refused.rc);
    try std.testing.expect(std.mem.indexOf(u8, refused.err, "matches an ignore rule") != null);
    try std.testing.expect(!exists(io, try h.srcOf(".claude/projects/session.jsonl")));

    const forced = try h.run(&.{ "mox", "add", live, "--force" });
    try std.testing.expectEqual(@as(u8, 0), forced.rc);
    try std.testing.expect(exists(io, try h.srcOf(".claude/projects/session.jsonl")));
}

/// Overwrite every regular file in `dir_abs` with `garbage`.
fn corruptAll(io: Io, a: std.mem.Allocator, dir_abs: []const u8, garbage: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        const p = try std.fs.path.join(a, &.{ dir_abs, e.name });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = garbage });
    }
}

test "doctor: detects a malformed state file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "ok\n");
    // Malformed provenance record.
    try writeRepo(io, &tmp, "state/provenance/deadbeef", "{ not json");

    const r = try h.run(&.{ "mox", "doctor" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bad-provenance") != null);
}

test "doctor: a malformed attributes.toml skips the checks that read it, and the report is not healthy" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "ok\n");
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "not valid toml [[[\n");

    const r = try h.run(&.{ "mox", "doctor" });
    // A read failure is not a rebuildable problem, so the rc stays soft.
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "check(s) skipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "healthy") == null);
}

test "doctor: a conventional `.d` config dir is healthy, not an orphan" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    // `conf.d/` has no base file `conf` and no axis overlays, so it is a plain
    // config directory whose files are managed in their own right -- the shape
    // every real dotfiles repo has (fish conf.d, profile.d, sources.list.d).
    try writeRepo(io, &tmp, "repo/src/.config/fish/conf.d/abbreviations.fish", "abbr -a -- e nvim\n");

    const r = try h.run(&.{ "mox", "doctor" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "conf.d") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "healthy") != null);
}

test "doctor: a gate that can never hold is a never-materializes advisory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true, .os = "linux" });
    // `os` holds one value per configuration, so this gate is off everywhere.
    try writeRepo(io, &tmp, "repo/src/.config/broken.toml", "# mox: when os=macos and os=linux\nkey = 1\n");
    // Gated for a different OS: still materializes under that OS's config, so
    // it is not a finding on this machine.
    try writeRepo(io, &tmp, "repo/src/.config/mac-only.toml", "# mox: when os=macos\nkey = 1\n");

    const r = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "never-materializes src/.config/broken.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "mac-only") == null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "doctor: a presence-fact gate is not a never-materializes false positive" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true, .os = "linux" });
    // Gated on a presence fact this machine lacks: it materializes on a machine
    // that has the fact, so it must not be flagged as never-materializing.
    try writeRepo(io, &tmp, "repo/src/.config/gpg.toml", "# mox: when signing_key\nkey = 1\n");

    const r = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "never-materializes") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "healthy") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

/// `git init` in `repo`, so doctor's git-backed untracked-source check has a
/// working tree to query. Skips the test when git is unavailable.
fn gitInit(io: Io, a: std.mem.Allocator, repo: []const u8) !void {
    const r = std.process.run(a, io, .{ .argv = &.{ "git", "init", repo } }) catch return error.SkipZigTest;
    switch (r.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

test "doctor: an untracked source is an advisory -- reported, and the rc stays 0" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "ok\n");
    try gitInit(io, a, h.repo);

    const r = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "untracked src/.zshrc") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "1 advisory item(s)") != null);
    // An advisory is something mox reports for a human to act on, never
    // something it remediates -- so it must not gate the exit code.
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "apply: an unknown attributes.toml key refuses loudly instead of silently dropping it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.config/app.local", "x\n");
    // A typo'd key (`seed_one` for `seed_once`): silently dropping it would
    // apply and overwrite what the user meant to protect.
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "[\".config/app.local\"]\nseed_one = true\n");

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "attributes.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "seed_one") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "schema") != null);
}

test "doctor --fix rebuilds malformed provenance for tracked files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "a\nb\n");
    _ = try h.run(&.{ "mox", "apply" });

    // Corrupt the provenance record apply just wrote.
    try corruptAll(io, a, try std.fs.path.join(a, &.{ h.state, "provenance" }), "{ broken");

    const fixed = try h.run(&.{ "mox", "doctor", "--fix" });
    try std.testing.expect(std.mem.indexOf(u8, fixed.out, "rebuilt provenance") != null);

    // A follow-up plain report is healthy: the record parses again.
    const after = try h.run(&.{ "mox", "doctor" });
    try std.testing.expectEqual(@as(u8, 0), after.rc);
    try std.testing.expect(std.mem.indexOf(u8, after.out, "bad-provenance") == null);
}

test "doctor: flags a tracked source that matches an ignore rule" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.config/oldtool/conf", "x\n");
    try writeRepo(io, &tmp, "repo/.moxignore", ".config/oldtool/\n");

    const r = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "oldtool") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "ignore") != null);
    // An advisory is never a rebuild-gating problem, so the rc stays 0.
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "doctor: a file ignored only under a `when`-gate for another machine is not flagged" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true, .os = "linux" });
    try writeRepo(io, &tmp, "repo/src/.config/gh.ps1", "x\n");
    // Ignored only on darwin -- this machine is pinned to linux, so the rule
    // does not apply here and gh.ps1 is intentionally per-machine gated, not
    // a real tracked-vs-ignored contradiction.
    try writeRepo(io, &tmp, "repo/.moxignore", "# mox: when os=darwin\n.config/gh.ps1\n# mox: end\n");

    const r = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "tracked-and-ignored") == null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

/// Seed a throwaway git repo at `repo` with a committed working tree so
/// `mox init --clone` has something to clone. Skips the test if git is
/// unavailable. The identity is throwaway test scaffolding, not a real repo.
fn gitSeed(io: Io, a: std.mem.Allocator, repo: []const u8) !void {
    const step = struct {
        fn run(io_: Io, a_: std.mem.Allocator, argv: []const []const u8) !void {
            const r = std.process.run(a_, io_, .{ .argv = argv }) catch return error.SkipZigTest;
            switch (r.term) {
                .exited => |c| if (c != 0) return error.SkipZigTest,
                else => return error.SkipZigTest,
            }
        }
    }.run;
    try step(io, a, &.{ "git", "init", "-q", repo });
    try step(io, a, &.{ "git", "-C", repo, "add", "src" });
    try step(io, a, &.{ "git", "-C", repo, "-c", "user.email=test@example.com", "-c", "user.name=test", "commit", "-q", "-m", "seed" });
}

test "init --clone --apply: clones the repo and applies it in one command" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A source repo with a committed src/ tree to clone from.
    try writeRepo(io, &tmp, "source/src/.zshrc", "hello from clone\n");
    const cwd = try std.process.currentPathAlloc(io, a);
    const source = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "source" });
    try gitSeed(io, a, source);

    // Empty repo dir (no create_repo_src) so init --clone is allowed.
    const h = try testutil.setup(a, io, &tmp, .{});

    const r = try h.run(&.{ "mox", "init", "--clone", source, "--apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    // Cloned AND applied in one step: the live file is written.
    try std.testing.expectEqualStrings("hello from clone\n", try read(io, a, try h.homePath(".zshrc")));
    // With --apply, the "review then apply" prompt is suppressed.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Review the repository") == null);
}

test "init: scaffolds a starter .moxignore" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Empty repo dir (no create_repo_src) so init builds it fresh.
    const h = try testutil.setup(a, io, &tmp, .{});

    const r = try h.run(&.{ "mox", "init" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    const moxignore_path = try std.fs.path.join(a, &.{ h.repo, ".moxignore" });
    const body = try read(io, a, moxignore_path);
    try std.testing.expect(std.mem.indexOf(u8, body, ".credentials.json") != null);
}

test "uninstall: removes state, preserves private and trash and the source repo" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "content\n");
    _ = try h.run(&.{ "mox", "apply" });
    // Seed a private-layer file and a trash generation.
    try writeRepo(io, &tmp, "state/private/.gitconfig.d/machine=x", "secret\n");
    try writeRepo(io, &tmp, "state/trash/gen1/src/.old", "recoverable\n");

    const r = try h.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    // Tracked state removed.
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.state, "applied" })));
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.state, "provenance" })));
    // Private and trash preserved (trash needs confirmation; test is non-interactive).
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ h.state, "private" })));
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ h.state, "trash" })));
    // The source repo is never touched.
    try std.testing.expect(exists(io, try h.srcOf(".zshrc")));
}

test "uninstall --purge-private --purge-trash removes both" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "content\n");
    _ = try h.run(&.{ "mox", "apply" });
    try writeRepo(io, &tmp, "state/private/keep", "secret\n");
    try writeRepo(io, &tmp, "state/trash/gen1/x", "old\n");

    const r = try h.run(&.{ "mox", "uninstall", "--purge-private", "--purge-trash" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.state, "private" })));
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.state, "trash" })));
    try std.testing.expect(exists(io, try h.srcOf(".zshrc")));
}

/// Every entry under `root` as sorted `kind relpath\ncontent` records: a
/// manifest of the whole tree, so comparing it across an operation catches any
/// entry that operation created, modified, or removed.
///
/// Every kind is recorded, not just regular files: a directory named for the
/// machine is a leak even when empty, and git stores a symlink as a blob whose
/// content is its raw target string, so a target commits a value exactly as a
/// file body does. A symlink is recorded by that raw target, never followed,
/// and its record is tagged so it can never collide with a file of the same
/// content.
fn treeManifest(a: std.mem.Allocator, io: Io, root: []const u8) ![]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();

    var records: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        const record = switch (entry.kind) {
            .file => blk: {
                const content = try dir.readFileAlloc(io, entry.path, a, .limited(1 << 20));
                break :blk try std.fmt.allocPrint(a, "file {s}\n{s}\n", .{ entry.path, content });
            },
            .directory => try std.fmt.allocPrint(a, "dir {s}\n", .{entry.path}),
            .sym_link => blk: {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = try dir.readLink(io, entry.path, &buf);
                break :blk try std.fmt.allocPrint(a, "symlink {s}\n{s}\n", .{ entry.path, buf[0..n] });
            },
            else => |k| try std.fmt.allocPrint(a, "{t} {s}\n", .{ k, entry.path }),
        };
        try records.append(a, record);
    }
    std.mem.sort([]const u8, records.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    return std.mem.concat(a, u8, records.items);
}

test "apply: nothing about this machine is written outside it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true });

    // A file that gates on one fact and interpolates another: the two shapes
    // that published a value before.
    try writeRepo(io, &tmp, "repo/data/facts-schema.toml", "[[fact]]\nname = \"signing_key\"\nprompt = \"k\"\n" ++
        "[[fact]]\nname = \"email\"\nprompt = \"e\"\n");
    try writeRepo(io, &tmp, "repo/src/.gitconfig", "[user]\n" ++
        "# mox: when signing_key\n" ++
        "\tsigningkey = <machine.signing_key>\n" ++
        "# mox: end\n" ++
        "\temail = <machine.email>\n");

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "facts", "set", "signing_key", "ssh-ed25519 CANARYKEY" })).rc);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "facts", "set", "email", "canary@example.invalid" })).rc);

    const before = try treeManifest(a, io, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The repo is the shared, committed thing. Nothing of the machine is in it:
    // neither fact's value, and -- since apply left the tree exactly as the user
    // wrote it -- no record naming the facts this machine binds either.
    try std.testing.expect(!containsAnywhere(a, io, h.repo, "CANARYKEY"));
    try std.testing.expect(!containsAnywhere(a, io, h.repo, "canary@example.invalid"));
    try std.testing.expectEqualStrings(before, try treeManifest(a, io, h.repo));

    const machines = try std.fs.path.join(a, &.{ h.repo, "machines" });
    try std.testing.expect(!exists(io, machines));

    // The composed live file did receive both facts: the assertions above hold
    // because nothing about the machine reaches the repo, not because the facts
    // went unused.
    const live = try read(io, a, try h.liveOf(".gitconfig"));
    try std.testing.expect(std.mem.indexOf(u8, live, "CANARYKEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "canary@example.invalid") != null);
}

test "facts probe: a present tool prints its path, exits 0" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const bin_dir = try std.fs.path.join(a, &.{ root, "bin" });
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/fd", .data = "" });

    const h = try testutil.setup(a, io, &tmp, .{
        .create_repo_src = true,
        .extra_env = &.{.{ .name = "PATH", .value = bin_dir }},
    });

    const r = try h.run(&.{ "mox", "facts", "probe", "tool=fd" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.startsWith(u8, r.out, "present "));
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, r.out, "\n"), "fd"));
}

test "facts probe: an absent tool prints absent, exits 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true });
    const r = try h.run(&.{ "mox", "facts", "probe", "tool=definitely-not-installed-xyz" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqualStrings("absent\n", r.out);
}

test "facts probe: a present env var prints its value, exits 0" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{
        .create_repo_src = true,
        .extra_env = &.{.{ .name = "MOX_FACTS_PROBE_VAR", .value = "hello" }},
    });
    const r = try h.run(&.{ "mox", "facts", "probe", "env=MOX_FACTS_PROBE_VAR" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expectEqualStrings("present hello\n", r.out);
}

test "facts probe: an unset env var prints absent, exits 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true });
    const r = try h.run(&.{ "mox", "facts", "probe", "env=MOX_FACTS_PROBE_MISSING" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqualStrings("absent\n", r.out);
}

test "facts probe: a set-but-empty env var reads as unset, same as env= axis evaluation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{
        .create_repo_src = true,
        .extra_env = &.{.{ .name = "MOX_FACTS_PROBE_EMPTY", .value = "" }},
    });
    const r = try h.run(&.{ "mox", "facts", "probe", "env=MOX_FACTS_PROBE_EMPTY" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqualStrings("absent\n", r.out);
}

test "facts probe: a malformed argument (no '=') is a usage error naming the syntax" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true });
    const r = try h.run(&.{ "mox", "facts", "probe", "fd" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "tool=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "env=") != null);
}

test "facts probe: an unknown axis is a usage error naming tool and env" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true });
    const r = try h.run(&.{ "mox", "facts", "probe", "path=brew_prefix" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "path") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "env") != null);
}

test "apply: an unset USER/USERNAME warns instead of silently interpolating \"unknown\"" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "repo/src");
    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const home = try std.fs.path.join(a, &.{ root, "home" });
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    const state = try std.fs.path.join(a, &.{ root, "state" });

    // No USER/USERNAME entry at all -- unlike testutil.setup, which always
    // defines USER, so this is the only way to reach the fallback.
    var map = std.process.Environ.Map.init(a);
    try map.put("HOME", home);
    try map.put("MOX_REPO", repo);
    try map.put("MOX_STATE_DIR", state);
    const map_ptr = try a.create(std.process.Environ.Map);
    map_ptr.* = map;
    const h: Harness = .{ .a = a, .io = io, .env = .{ .map = map_ptr }, .root = root, .home = home, .repo = repo, .state = state };

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "username could not be determined") != null);
}

test "apply and facts: a non-string facts.toml value is dropped loudly, not silently" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true });
    const facts_path = try h.homePath(".config/mox/facts.toml");
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(facts_path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = facts_path, .data = "profile = 1\n" });

    const applied = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), applied.rc);
    try std.testing.expect(std.mem.indexOf(u8, applied.err, "facts.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, applied.err, "profile") != null);

    const facts_out = try h.run(&.{ "mox", "facts" });
    try std.testing.expect(std.mem.indexOf(u8, facts_out.err, "profile") != null);
}

test "apply and facts: a facts.toml key named for a multi-value axis errors loudly, naming the reserved set" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true });
    const facts_path = try h.homePath(".config/mox/facts.toml");
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(facts_path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = facts_path, .data = "tool = \"x\"\n" });

    const applied = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(applied.rc != 0);
    // The remediation message -- which key collided and the reserved set --
    // reaches apply's own diagnostic, not just the bare error name main
    // would otherwise print with no remediation at all.
    try std.testing.expect(std.mem.indexOf(u8, applied.err, "tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, applied.err, "reserved axis names (tool, env, path)") != null);

    const facts_out = try h.run(&.{ "mox", "facts" });
    try std.testing.expectEqual(@as(u8, 1), facts_out.rc);
    try std.testing.expect(std.mem.indexOf(u8, facts_out.err, "tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts_out.err, "tool, env, path") != null);
}

test "apply and doctor: a legacy extras.toml prints one notice; its tools still resolve lazily" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const bin_dir = try std.fs.path.join(a, &.{ root, "bin" });
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/zk", .data = "" });

    const h = try testutil.setup(a, io, &tmp, .{
        .create_repo_src = true,
        .extra_env = &.{.{ .name = "PATH", .value = bin_dir }},
    });
    try writeRepo(io, &tmp, "repo/src/.testrc", "export BASE=1\n" ++
        "# mox: when tool=zk\n" ++
        "export HAS_ZK=1\n" ++
        "# mox: end\n");

    const extras_path = try h.homePath(".config/mox/extras.toml");
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(extras_path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = extras_path, .data = "tools = [\"zk\"]\n" });

    const applied = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), applied.rc);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, applied.err, "extras.toml"));
    try std.testing.expect(std.mem.indexOf(u8, applied.err, "no longer read") != null);

    // "zk" resolves purely because it is on PATH: extras.toml being present
    // (and unread) neither seeds it nor is required for it to resolve.
    const live = try read(io, a, try h.liveOf(".testrc"));
    try std.testing.expect(std.mem.indexOf(u8, live, "export HAS_ZK=1") != null);

    const doctored = try h.run(&.{ "mox", "doctor" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, doctored.err, "extras.toml"));
}

test "apply: no extras.toml present prints no notice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true });
    const applied = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), applied.rc);
    try std.testing.expect(std.mem.indexOf(u8, applied.err, "extras.toml") == null);

    const doctored = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(std.mem.indexOf(u8, doctored.err, "extras.toml") == null);
}

test "apply: a pre-script's axis-relevant change is visible to compose in the same apply" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Gated on path=cargo_home, which binds only once ~/.cargo exists.
    try writeRepo(io, &tmp, "repo/src/.testrc", "export BASE=1\n" ++
        "# mox: when path=cargo_home\n" ++
        "export HAS_CARGO=1\n" ++
        "# mox: end\n");

    // A pre-script that creates ~/.cargo. Without re-capturing machine state
    // after the pre-stage, this apply composes with the gate still off.
    const ext = if (builtin.os.tag == .windows) ".ps1" else ".sh";
    const body = if (builtin.os.tag == .windows)
        "New-Item -ItemType Directory -Force -Path \"$env:MOX_HOME\\.cargo\" | Out-Null\n"
    else
        "#!/bin/sh\nmkdir -p \"$MOX_HOME/.cargo\"\n";
    const sub = try std.fmt.allocPrint(a, "repo/scripts/pre/00-cargo{s}", .{ext});
    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const abs = try std.fs.path.join(a, &.{ root, sub });
    try writeExecScript(io, &tmp, sub, body, abs);

    const h = try setup(a, io, &tmp, null);
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.home, ".cargo" })));

    _ = try h.run(&.{ "mox", "apply" });

    // The gate flipped within the same apply, and the dir really was created.
    const live = try read(io, a, try h.liveOf(".testrc"));
    try std.testing.expect(std.mem.indexOf(u8, live, "export HAS_CARGO=1") != null);
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ h.home, ".cargo" })));
}

test "apply: a pre-script that installs an unwatched tool is gated on in the same apply" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // This file only materializes once the lazy probe sees "herdr" on PATH,
    // and only after the pre-script installs it.
    try writeRepo(io, &tmp, "repo/src/.testrc", "export BASE=1\n" ++
        "# mox: when tool=herdr\n" ++
        "export HAS_HERDR=1\n" ++
        "# mox: end\n");

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const bin_dir = try std.fs.path.join(a, &.{ root, "toolbin" });

    // A pre-script that drops a plain file named "herdr" into a directory
    // already on $PATH -- the real system PATH is preserved alongside it so
    // the script's own `mkdir`/`New-Item` still resolve.
    const real_path = (mox.env.Env{ .process = std.testing.environ }).getAlloc(a, "PATH") catch "";
    const test_path = if (real_path.len > 0)
        try std.fmt.allocPrint(a, "{s}{c}{s}", .{ bin_dir, std.fs.path.delimiter, real_path })
    else
        bin_dir;

    const ext = if (builtin.os.tag == .windows) ".ps1" else ".sh";
    const body = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(
            a,
            "New-Item -ItemType Directory -Force -Path \"{s}\" | Out-Null\nSet-Content -LiteralPath \"{s}\\herdr\" -NoNewline -Value ''\n",
            .{ bin_dir, bin_dir },
        )
    else
        try std.fmt.allocPrint(a, "#!/bin/sh\nmkdir -p \"{s}\"\ntouch \"{s}/herdr\"\n", .{ bin_dir, bin_dir });
    const sub = try std.fmt.allocPrint(a, "repo/scripts/pre/00-herdr{s}", .{ext});
    const abs = try std.fs.path.join(a, &.{ root, sub });
    try writeExecScript(io, &tmp, sub, body, abs);

    const h = try testutil.setup(a, io, &tmp, .{
        .create_repo_src = true,
        .extra_env = &.{.{ .name = "PATH", .value = test_path }},
    });
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ bin_dir, "herdr" })));

    const applied = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), applied.rc);

    // The gate flipped within the same apply, and the file really was created.
    const live = try read(io, a, try h.liveOf(".testrc"));
    try std.testing.expect(std.mem.indexOf(u8, live, "export HAS_HERDR=1") != null);
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ bin_dir, "herdr" })));
}

test "apply: a pre-script that installs into cargo_home/bin (never on PATH) is gated on in the same apply" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "cargotool" never touches $PATH: the only way this row materializes
    // is the tool-home search-space layer finding it under
    // `$CARGO_HOME/bin`.
    try writeRepo(io, &tmp, "repo/src/.testrc", "export BASE=1\n" ++
        "# mox: when tool=cargotool\n" ++
        "export HAS_CARGOTOOL=1\n" ++
        "# mox: end\n");

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const cargo_home = try std.fs.path.join(a, &.{ root, "fakecargo" });
    const cargo_bin = try std.fs.path.join(a, &.{ cargo_home, "bin" });

    // CARGO_HOME must already exist for `resolveToolHome` to accept it (it
    // access-checks the root); the pre-script is what creates `bin/` and
    // drops the "installed" binary into it, mid-apply.
    try tmp.dir.createDirPath(io, "fakecargo");

    const ext = if (builtin.os.tag == .windows) ".ps1" else ".sh";
    const body = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(
            a,
            "New-Item -ItemType Directory -Force -Path \"{s}\" | Out-Null\nSet-Content -LiteralPath \"{s}\\cargotool\" -NoNewline -Value ''\n",
            .{ cargo_bin, cargo_bin },
        )
    else
        try std.fmt.allocPrint(a, "#!/bin/sh\nmkdir -p \"{s}\"\ntouch \"{s}/cargotool\"\n", .{ cargo_bin, cargo_bin });
    const sub = try std.fmt.allocPrint(a, "repo/scripts/pre/00-cargotool{s}", .{ext});
    const abs = try std.fs.path.join(a, &.{ root, sub });
    try writeExecScript(io, &tmp, sub, body, abs);

    // Real system PATH is preserved (so the script's own mkdir/touch still
    // resolve) but never carries the cargo bin dir: the row can only
    // materialize through the tool-home layer, not a widened PATH.
    const real_path = (mox.env.Env{ .process = std.testing.environ }).getAlloc(a, "PATH") catch "";
    const h = try testutil.setup(a, io, &tmp, .{
        .create_repo_src = true,
        .extra_env = &.{
            .{ .name = "CARGO_HOME", .value = cargo_home },
            .{ .name = "PATH", .value = real_path },
        },
    });
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ cargo_bin, "cargotool" })));

    const applied = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), applied.rc);

    // The gate flipped within the same apply, and the binary really was
    // dropped into cargo_home/bin -- never onto $PATH.
    const live = try read(io, a, try h.liveOf(".testrc"));
    try std.testing.expect(std.mem.indexOf(u8, live, "export HAS_CARGOTOOL=1") != null);
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ cargo_bin, "cargotool" })));
    try std.testing.expect(std.mem.indexOf(u8, real_path, "fakecargo") == null);
}

test "apply: a pre-script names an arbitrary dir via $MOX_PATH; gates true same apply, post script sees it on PATH" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "mypathtool" lives in a directory that is neither on $PATH nor any
    // detected tool home: only the explicit $MOX_PATH channel can
    // make it visible.
    try writeRepo(io, &tmp, "repo/src/.testrc", "export BASE=1\n" ++
        "# mox: when tool=mypathtool\n" ++
        "export HAS_MYPATHTOOL=1\n" ++
        "# mox: end\n");

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const target_dir = try std.fs.path.join(a, &.{ root, "arbitrary-install-dir" });
    const marker = try std.fs.path.join(a, &.{ root, "post-saw-path.txt" });

    const ext = if (builtin.os.tag == .windows) ".ps1" else ".sh";
    const pre_body = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(
            a,
            "New-Item -ItemType Directory -Force -Path \"{s}\" | Out-Null\n" ++
                "Set-Content -LiteralPath \"{s}\\mypathtool\" -NoNewline -Value ''\n" ++
                "Add-Content -LiteralPath $env:MOX_PATH -Value \"{s}\"\n",
            .{ target_dir, target_dir, target_dir },
        )
    else
        try std.fmt.allocPrint(
            a,
            "#!/bin/sh\nmkdir -p \"{s}\"\ntouch \"{s}/mypathtool\"\necho \"{s}\" >> \"$MOX_PATH\"\n",
            .{ target_dir, target_dir, target_dir },
        );
    const pre_sub = try std.fmt.allocPrint(a, "repo/scripts/pre/00-moxpath{s}", .{ext});
    const pre_abs = try std.fs.path.join(a, &.{ root, pre_sub });
    try writeExecScript(io, &tmp, pre_sub, pre_body, pre_abs);

    // A post script writes "yes"/"no" to a marker depending on whether the
    // pre stage's $MOX_PATH addition shows up on ITS OWN PATH -- the
    // "subsequent scripts" half of the $MOX_PATH channel's contract.
    const post_body = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(
            a,
            "if ($env:PATH -split ';' -contains \"{s}\") {{ Set-Content -LiteralPath \"{s}\" -NoNewline -Value 'yes' }} else {{ Set-Content -LiteralPath \"{s}\" -NoNewline -Value 'no' }}\n",
            .{ target_dir, marker, marker },
        )
    else
        try std.fmt.allocPrint(
            a,
            "#!/bin/sh\ncase \":$PATH:\" in\n  *\":{s}:\"*) echo yes > \"{s}\" ;;\n  *) echo no > \"{s}\" ;;\nesac\n",
            .{ target_dir, marker, marker },
        );
    const post_sub = try std.fmt.allocPrint(a, "repo/scripts/post/00-checkpath{s}", .{ext});
    const post_abs = try std.fs.path.join(a, &.{ root, post_sub });
    try writeExecScript(io, &tmp, post_sub, post_body, post_abs);

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true });
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ target_dir, "mypathtool" })));

    const applied = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), applied.rc);

    // The gate flipped within the same apply...
    const live = try read(io, a, try h.liveOf(".testrc"));
    try std.testing.expect(std.mem.indexOf(u8, live, "export HAS_MYPATHTOOL=1") != null);
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ target_dir, "mypathtool" })));
    // ...and the post script's own PATH carried the addition.
    const saw = try read(io, a, marker);
    try std.testing.expectEqualStrings("yes", std.mem.trimEnd(u8, saw, "\r\n"));
}

test "apply: a relative $MOX_PATH line is a loud per-line warning, not a silent skip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.testrc", "export BASE=1\n");

    const ext = if (builtin.os.tag == .windows) ".ps1" else ".sh";
    const body = if (builtin.os.tag == .windows)
        "Add-Content -LiteralPath $env:MOX_PATH -Value 'not/absolute'\n"
    else
        "#!/bin/sh\necho 'not/absolute' >> \"$MOX_PATH\"\n";
    const sub = try std.fmt.allocPrint(a, "repo/scripts/pre/00-badpath{s}", .{ext});
    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const abs = try std.fs.path.join(a, &.{ root, sub });
    try writeExecScript(io, &tmp, sub, body, abs);

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true });
    const applied = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), applied.rc);

    try std.testing.expect(std.mem.indexOf(u8, applied.err, "MOX_PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, applied.err, "not/absolute") != null);
    try std.testing.expect(std.mem.indexOf(u8, applied.err, ":1:") != null);
}

// Partial-ownership lifecycle: onboarding via `add --own` and the partial
// semantics of add-tree, remove, mv, export, and doctor.

test "add --own: extracts raw spans with comments, preserves attribute comments, apply adopts cleanly" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    const live_content =
        \\model = "gpt"
        \\
        \\[tui.keymap.global]
        \\# prefer plain enter
        \\submit = "enter"
        \\
        \\[state]
        \\count = 1
        \\
    ;
    try writeRepo(io, &tmp, "home/app.toml", live_content);
    // The attributes file is user-authored and carries no ownership; the
    // declaration lands in the new source's head instead.
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "# hand-maintained attributes\n[\".ssh/config\"]\nmode = \"0600\"\n");

    const live = try h.liveOf("app.toml");
    const r = try h.run(&.{ "mox", "add", "--own", "tui.keymap.global", live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "own: 1 key-path") != null);
    // model and state stay the program's; tui is an owned ancestor.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "2 top-level live entries remain unowned") != null);

    // The source is the head declaration plus the RAW span: the user's
    // comment survives verbatim. The span ends at the table's last content
    // line, so the blank line that trailed it stays with the live remainder.
    const src = try read(io, a, try h.srcOf("app.toml"));
    try std.testing.expectEqualStrings("# mox: own tui.keymap.global\n[tui.keymap.global]\n# prefer plain enter\nsubmit = \"enter\"\n", src);

    const attrs = try read(io, a, try std.fs.path.join(a, &.{ h.repo, ".mox", "attributes.toml" }));
    try std.testing.expect(std.mem.indexOf(u8, attrs, "# hand-maintained attributes") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs, "mode = \"0600\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs, "own") == null);

    // Extracted == live owned content, so the first apply adopts cleanly and
    // changes no live byte.
    const apply = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), apply.rc);
    try std.testing.expect(std.mem.indexOf(u8, apply.out, "adopted") != null);
    try std.testing.expectEqualStrings(live_content, try read(io, a, live));
}

test "add --own: a symlinked live path captures through the link; apply patches the target" {
    // Creating a symlink needs a POSIX-class filesystem.
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    const live_content =
        \\model = "gpt"
        \\
        \\[tui.keymap.global]
        \\submit = "enter"
        \\
    ;
    try writeRepo(io, &tmp, "home/real-app.toml", live_content);
    const live = try h.liveOf("app.toml");
    const target = try h.liveOf("real-app.toml");
    try Io.Dir.cwd().symLink(io, "real-app.toml", live, .{});

    // Onboards through the link: the target's bytes are captured, the live
    // path stays the link.
    const r = try h.run(&.{ "mox", "add", "--own", "tui.keymap.global", live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    const src = try read(io, a, try h.srcOf("app.toml"));
    try std.testing.expectEqualStrings("# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"enter\"\n", src);

    // First apply adopts; a source change then patches the TARGET while the
    // link survives.
    const r1 = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r1.rc);
    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"ctrl-enter\"\n");
    const r2 = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r2.rc);
    const link_st = try Io.Dir.cwd().statFile(io, live, .{ .follow_symlinks = false });
    try std.testing.expect(link_st.kind == .sym_link);
    try std.testing.expectEqualStrings(
        "model = \"gpt\"\n\n[tui.keymap.global]\nsubmit = \"ctrl-enter\"\n",
        try read(io, a, target),
    );

    // A dangling link still refuses, with nothing captured.
    const dangling = try h.liveOf("dangling.toml");
    try Io.Dir.cwd().symLink(io, "no-such.toml", dangling, .{});
    const bad = try h.run(&.{ "mox", "add", "--own", "x", dangling });
    try std.testing.expectEqual(@as(u8, 1), bad.rc);
    try std.testing.expect(std.mem.indexOf(u8, bad.err, "dangling symlink") != null);
    try std.testing.expect(!exists(io, try h.srcOf("dangling.toml")));
}

test "add --own: a declared path absent from the live file is an error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/app.toml", "present = 1\n");
    const live = try h.liveOf("app.toml");

    const r = try h.run(&.{ "mox", "add", "--own", "missing.table", live });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "missing.table") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "--own-absent") != null);
    // Nothing was captured or recorded.
    try std.testing.expect(!exists(io, try h.srcOf("app.toml")));
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.repo, ".mox", "attributes.toml" })));
}

test "add --own-absent: the declared path flows to enforced absence" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/app.toml", "[keep]\nk = 1\n\n[gone]\ng = 1\n");
    const live = try h.liveOf("app.toml");

    const r = try h.run(&.{ "mox", "add", "--own", "keep", "--own-absent", "gone", live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    const src = try read(io, a, try h.srcOf("app.toml"));
    try std.testing.expect(std.mem.indexOf(u8, src, "# mox: own keep\n# mox: own gone\n") != null);
    // The absent path contributed no content to the source body.
    try std.testing.expect(std.mem.indexOf(u8, src, "[gone]") == null);

    // Live still holds [gone] and no record exists: first contact for the
    // enforced absence, so removal is drift until forced.
    const drift = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), drift.rc);
    try std.testing.expect(std.mem.indexOf(u8, drift.err, "DRIFT") != null);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "[gone]") != null);

    const forced = try h.run(&.{ "mox", "apply", "--force" });
    try std.testing.expectEqual(@as(u8, 0), forced.rc);
    const after = try read(io, a, live);
    try std.testing.expect(std.mem.indexOf(u8, after, "[gone]") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "k = 1") != null);
}

test "add --own --gate: the gate line follows the directives and a matching machine patches" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true, .os = "darwin" });
    const live_content = "[tui]\nsubmit = \"enter\"\n\n[state]\ncount = 1\n";
    try writeRepo(io, &tmp, "home/app.toml", live_content);
    const live = try h.liveOf("app.toml");

    const r = try h.run(&.{ "mox", "add", "--own", "tui", "--gate", "os=darwin", live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    // The gate holds on this machine: no warning.
    try std.testing.expect(std.mem.indexOf(u8, r.err, "does not hold") == null);
    // The head is the ownership directives, then the whole-file gate.
    const src = try read(io, a, try h.srcOf("app.toml"));
    try std.testing.expect(std.mem.startsWith(u8, src, "# mox: own tui\n# mox: when os=darwin\n[tui]\n"));

    // The gate holds here: first apply adopts, and a source change patches
    // the owned span while the program's remainder survives byte-for-byte.
    const adopt = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), adopt.rc);
    try std.testing.expect(std.mem.indexOf(u8, adopt.out, "adopted") != null);

    const changed = try std.mem.replaceOwned(u8, a, src, "\"enter\"", "\"tab\"");
    try writeRepo(io, &tmp, "repo/src/app.toml", changed);
    const apply = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), apply.rc);
    const after = try read(io, a, live);
    try std.testing.expect(std.mem.indexOf(u8, after, "submit = \"tab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "[state]\ncount = 1\n") != null);
    // No directive line reaches the live file.
    try std.testing.expect(std.mem.indexOf(u8, after, "mox:") == null);
}

test "add --own --gate: a machine where the gate fails leaves the live file untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try testutil.setup(a, io, &tmp, .{ .create_repo_src = true, .os = "linux" });
    const live_content = "[tui]\nsubmit = \"enter\"\n";
    try writeRepo(io, &tmp, "home/app.toml", live_content);
    const live = try h.liveOf("app.toml");

    const r = try h.run(&.{ "mox", "add", "--own", "tui", "--gate", "os=darwin", live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    // The add succeeds, but the user is told this machine will skip the file.
    try std.testing.expect(std.mem.indexOf(u8, r.err, "gate `os=darwin` does not hold on this machine; the file will not apply here until the axis is bound") != null);

    const apply = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), apply.rc);
    try std.testing.expect(std.mem.indexOf(u8, apply.out, "skipped") != null);
    try std.testing.expectEqualStrings(live_content, try read(io, a, live));
    // No owned record exists for the gated-off target.
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.state, "applied-owned" })));

    // status reports the gated partial with its inventory annotation.
    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 0), s.rc);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "GATED") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "app.toml  (own 1)") != null);
}

test "add --disown --gate: the jsonc gate line follows the disown directives" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/settings.json", "{\n  \"theme\": \"dark\",\n  \"model\": \"m\"\n}\n");
    const live = try h.liveOf("settings.json");

    const r = try h.run(&.{ "mox", "add", "--disown", "model", "--gate", "tool=codex", live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    const src = try read(io, a, try h.srcOf("settings.json"));
    try std.testing.expect(std.mem.startsWith(u8, src, "// mox: disown model\n// mox: when tool=codex\n"));
}

test "add --gate: a malformed expression or a gate without ownership is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/app.toml", "[tui]\nk = 1\n");
    const live = try h.liveOf("app.toml");

    // A dropped `or`: refused with the parser's diagnostic, nothing written.
    const bad = try h.run(&.{ "mox", "add", "--own", "tui", "--gate", "os=darwin os=linux", live });
    try std.testing.expectEqual(@as(u8, 1), bad.rc);
    try std.testing.expect(std.mem.indexOf(u8, bad.err, "os=darwin os=linux") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad.err, "UnexpectedTrailingTokens") != null);
    try std.testing.expect(!exists(io, try h.srcOf("app.toml")));

    // --gate gates the created partial source; a whole-file add has none.
    const alone = try h.run(&.{ "mox", "add", "--gate", "os=darwin", live });
    try std.testing.expectEqual(@as(u8, 1), alone.rc);
    try std.testing.expect(std.mem.indexOf(u8, alone.err, "--gate requires --own or --disown") != null);
    try std.testing.expect(!exists(io, try h.srcOf("app.toml")));
}

test "add: a whole-file add of a partially owned target is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/app.toml", "[tui]\nk = 1\n");
    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own tui\n[tui]\nk = 1\n");

    const r = try h.run(&.{ "mox", "add", try h.liveOf("app.toml") });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "partially owned") != null);
    try std.testing.expectEqualStrings("# mox: own tui\n[tui]\nk = 1\n", try read(io, a, try h.srcOf("app.toml")));
}

test "add-tree: a partially owned target is skipped with an explicit reason" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/cfg/app.toml", "[tui]\nk = 1\n");
    try writeRepo(io, &tmp, "home/cfg/plain.txt", "text\n");
    try writeRepo(io, &tmp, "repo/src/cfg/app.toml", "# mox: own tui\n[tui]\nk = 1\n");

    const dir = try std.fs.path.join(a, &.{ h.home, "cfg" });
    const r = try h.run(&.{ "mox", "add-tree", dir });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "partially owned") != null);
    try std.testing.expect(exists(io, try h.srcOf("cfg/plain.txt")));
    // The partial source keeps its declaration; nothing overwrote it.
    try std.testing.expectEqualStrings("# mox: own tui\n[tui]\nk = 1\n", try read(io, a, try h.srcOf("cfg/app.toml")));
}

test "remove: --purge is refused on a partial target; plain remove forgets the owned record" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own tui\n[tui]\nk = 1\n");
    _ = try h.run(&.{ "mox", "apply" });

    const live = try h.liveOf("app.toml");
    const rec_name = mox.apply.applied.contentHashHex(live);
    const rec_path = try std.fs.path.join(a, &.{ h.state, "applied-owned", &rec_name });
    try std.testing.expect(exists(io, rec_path));

    const purge = try h.run(&.{ "mox", "remove", "app.toml", "--purge" });
    try std.testing.expectEqual(@as(u8, 1), purge.rc);
    try std.testing.expect(std.mem.indexOf(u8, purge.err, "--purge is refused") != null);
    // Nothing was touched by the refusal.
    try std.testing.expect(exists(io, live));
    try std.testing.expect(exists(io, try h.srcOf("app.toml")));

    const r = try h.run(&.{ "mox", "remove", "app.toml" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    // Live file untouched (both regions), source trashed, and the owned
    // record forgotten so a later re-add is first contact again.
    try std.testing.expect(exists(io, live));
    try std.testing.expect(!exists(io, try h.srcOf("app.toml")));
    try std.testing.expect(!exists(io, rec_path));
}

test "mv: re-keys the owned record for a partial target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own tui\n[tui]\nk = 1\n");
    _ = try h.run(&.{ "mox", "apply" });

    const old_live = try h.liveOf("app.toml");
    const new_live = try h.liveOf("app2.toml");
    const old_rec = try std.fs.path.join(a, &.{ h.state, "applied-owned", &mox.apply.applied.contentHashHex(old_live) });
    const new_rec = try std.fs.path.join(a, &.{ h.state, "applied-owned", &mox.apply.applied.contentHashHex(new_live) });

    const r = try h.run(&.{ "mox", "mv", "app.toml", "app2.toml" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "old live file keeps its owned content") != null);

    // The declaration travels inside the renamed source file.
    const moved = try read(io, a, try h.srcOf("app2.toml"));
    try std.testing.expect(std.mem.indexOf(u8, moved, "# mox: own tui") != null);
    try std.testing.expect(!exists(io, old_rec));
    try std.testing.expect(exists(io, new_rec));

    // The re-keyed record is the one apply compares against: a live file at
    // the new path holding the recorded content is unchanged, not adopted.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = new_live, .data = try read(io, a, old_live) });
    const apply = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), apply.rc);
    try std.testing.expect(std.mem.indexOf(u8, apply.out, "unchanged") != null);
    try std.testing.expect(std.mem.indexOf(u8, apply.out, "adopted") == null);
}

test "export --resolved: a partial target bakes its canonical owned serialization" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    const source = "[tui]\nk = 1\n";
    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own tui\n" ++ source);

    const out_dir = try std.fs.path.join(a, &.{ h.root, "baked" });
    const r = try h.run(&.{ "mox", "export", "--resolved", out_dir });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    // The export is the owned contract in canonical form, not a whole file.
    const doc = try mox.apply.partial.OwnedDoc.parse(a, .toml, source);
    const paths = [_]mox.source.tree.OwnPath{
        .{ .raw = "tui", .segments = try mox.source.keypath.parse(a, "tui") },
    };
    const want = try mox.apply.canonical.canonicalOwned(a, &doc, &paths);
    const baked = try read(io, a, try std.fs.path.join(a, &.{ out_dir, "app.toml" }));
    try std.testing.expectEqualStrings(want, baked);
}

test "add --disown: the live file minus the program's spans becomes the source, comments kept" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    const live_content =
        \\{
        \\  // the user's theme
        \\  "theme": "dark",
        \\  "model": "test-model-4.1",
        \\  "editor": "nvim"
        \\}
        \\
    ;
    try writeRepo(io, &tmp, "home/settings.json", live_content);
    const live = try h.liveOf("settings.json");

    const bad = try h.run(&.{ "mox", "add", "--disown", "model", "--own", "theme", live });
    try std.testing.expectEqual(@as(u8, 1), bad.rc);
    try std.testing.expect(std.mem.indexOf(u8, bad.err, "exclusive") != null);

    const r = try h.run(&.{ "mox", "add", "--disown", "model", live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "disown: 1 key-path") != null);

    // The source is the raw complement under the declaration: the user's
    // comment survives, the program's key is gone.
    const src = try read(io, a, try h.srcOf("settings.json"));
    try std.testing.expect(std.mem.indexOf(u8, src, "// mox: disown model") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "// the user's theme") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "model") != null); // the directive names it
    try std.testing.expect(std.mem.indexOf(u8, src, "test-model-4.1") == null);

    // First apply adopts cleanly and changes no live byte.
    const apply = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), apply.rc);
    try std.testing.expect(std.mem.indexOf(u8, apply.out, "adopted") != null);
    try std.testing.expectEqualStrings(live_content, try read(io, a, live));
}

test "add --disown: an extraction that cannot re-apply is refused with nothing written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    // The whole live file is the disowned subtree: the complement is empty,
    // and an indented block span cannot be re-applied into an empty
    // document. The add-time round-trip gate must refuse UP FRONT instead
    // of writing a source that fails on every later apply.
    try writeRepo(io, &tmp, "home/data.yaml", "survey:\n  state: 1\n");
    const live = try h.liveOf("data.yaml");

    const r = try h.run(&.{ "mox", "add", "--disown", "survey.state", live });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "does not re-apply cleanly") != null);
    try std.testing.expect(!exists(io, try h.srcOf("data.yaml")));
    // The live file is untouched.
    try std.testing.expectEqualStrings("survey:\n  state: 1\n", try read(io, a, live));
}

test "add --disown: a declared path absent from the live file is an error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/settings.json", "{\n  \"theme\": \"dark\"\n}\n");
    const live = try h.liveOf("settings.json");

    const r = try h.run(&.{ "mox", "add", "--disown", "model", live });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "model") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not present") != null);
    try std.testing.expect(!exists(io, try h.srcOf("settings.json")));
}

const json_mod = @import("json");

test "add --disown: a suffix run of members with a quoted key extracts and applies cleanly" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    const live_content = "{\n  \"theme\": \"dark\",\n  \"editor\": \"nvim\",\n  \"the model\": \"m1\"\n}\n";
    try writeRepo(io, &tmp, "home/settings.json", live_content);
    const live = try h.liveOf("settings.json");

    // Disowning the object's LAST TWO members must not leave the preceding
    // member's separator dangling in the extracted source.
    const r = try h.run(&.{ "mox", "add", "--disown", "editor", "--disown", "\"the model\"", live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    const src = try read(io, a, try h.srcOf("settings.json"));
    try std.testing.expectEqualStrings(
        "// mox: disown editor\n// mox: disown \"the model\"\n{\n  \"theme\": \"dark\"\n}\n",
        src,
    );

    // With the program keys present, the first apply adopts byte-for-byte.
    const adopt = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), adopt.rc);
    try std.testing.expect(std.mem.indexOf(u8, adopt.out, "adopted") != null);
    try std.testing.expectEqualStrings(live_content, try read(io, a, live));

    // A reassert splices the live spans back in and the result is STRICT
    // JSON -- no dangling separator ever reaches the live file.
    try writeRepo(io, &tmp, "repo/src/settings.json", "// mox: disown editor\n// mox: disown \"the model\"\n{\n  \"theme\": \"light\"\n}\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const patched = try read(io, a, live);
    try std.testing.expect(std.mem.indexOf(u8, patched, "\"theme\": \"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, patched, "\"the model\": \"m1\"") != null);
    _ = try json_mod.parse(a, patched, .{});

    // With the program keys ABSENT the spans contribute nothing: the live
    // file is exactly the composed text, still strict JSON.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "{\n  \"theme\": \"light\"\n}\n" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const absent = try read(io, a, live);
    try std.testing.expectEqualStrings("{\n  \"theme\": \"light\"\n}\n", absent);
    _ = try json_mod.parse(a, absent, .{});
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

/// Bounds every FIFO-guard e2e below. With the kind guard intact no command
/// ever opens the FIFO, and this loop just polls `done`. If a regression made
/// a command open the FIFO for reading, that open blocks waiting for a
/// writer -- the loop connects one and closes it, so the blocked open
/// returns, the read sees immediate EOF, and the test FAILS on its
/// assertions instead of hanging CI. A hard wall-clock cap aborts the test
/// process if the command still has not returned.
fn fifoRelief(io: Io, path_z: [*:0]const u8, done: *std.atomic.Value(bool)) void {
    var waited_ms: u64 = 0;
    while (!done.load(.acquire)) {
        const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .NONBLOCK = true });
        if (fd >= 0) _ = std.c.close(fd);
        io.sleep(.fromMilliseconds(10), .awake) catch {};
        waited_ms += 10;
        if (waited_ms > 60_000) {
            std.debug.print("fifoRelief: command still running after 60s; aborting\n", .{});
            std.process.exit(1);
        }
    }
}

const FifoGuard = struct {
    done: *std.atomic.Value(bool),
    fut: Io.Future(void),

    fn start(a: std.mem.Allocator, io: Io, fifo_abs: []const u8) !FifoGuard {
        const done = try a.create(std.atomic.Value(bool));
        done.* = .init(false);
        const path_z = try a.dupeZ(u8, fifo_abs);
        return .{ .done = done, .fut = io.async(fifoRelief, .{ io, path_z.ptr, done }) };
    }

    fn stop(self: *FifoGuard, io: Io) void {
        self.done.store(true, .release);
        self.fut.await(io);
    }
};

test "add: a FIFO is refused as not a regular file, never opened" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no FIFOs
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    const fifo = try h.homePath("pipe.toml");
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(try a.dupeZ(u8, fifo), 0o644));
    var guard = try FifoGuard.start(a, io, fifo);
    defer guard.stop(io);

    const r = try h.run(&.{ "mox", "add", fifo });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not a regular file") != null);
    try std.testing.expect(!exists(io, try h.srcOf("pipe.toml")));

    // The partial route refuses the same way, before any extraction read.
    const own = try h.run(&.{ "mox", "add", "--own", "tui", fifo });
    try std.testing.expectEqual(@as(u8, 1), own.rc);
    try std.testing.expect(std.mem.indexOf(u8, own.err, "not a regular file") != null);
}

test "add: refuses while another live process holds the lock" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/notes.txt", "n\n");

    // A live process (this test) already holds the lock.
    try Io.Dir.cwd().createDirPath(io, h.state);
    const boot = mox.cli.lock.bootId(a, io);
    const stamp = if (boot.len > 0) boot else "-";
    const line = try std.fmt.allocPrint(a, "{d} {s} apply\n", .{ mox.cli.lock.selfPid(), stamp });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ h.state, "mox.lock" }), .data = line });

    const r = try h.run(&.{ "mox", "add", "notes.txt" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "lock held") != null);
    try std.testing.expect(!exists(io, try h.srcOf("notes.txt")));
}

test "add-tree: a directory outside HOME is refused at the top level" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "elsewhere/x.conf", "x\n");
    const outside = try std.fs.path.join(a, &.{ h.root, "elsewhere" });

    const r = try h.run(&.{ "mox", "add-tree", outside });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "outside HOME") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Added") == null);
}

test "add-tree: captures a symlink, reports a FIFO as skipped with a reason" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no FIFOs
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "home/.config/app/a.conf", "a\n");
    const link = try h.homePath(".config/app/link.conf");
    try Io.Dir.cwd().symLink(io, "a.conf", link, .{});
    const fifo = try h.homePath(".config/app/pipe");
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(try a.dupeZ(u8, fifo), 0o644));
    var guard = try FifoGuard.start(a, io, fifo);
    defer guard.stop(io);

    const r = try h.run(&.{ "mox", "add-tree", ".config/app" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Added 2 file(s); 1 skipped, 0 failed") != null);
    const skip_line = try std.fmt.allocPrint(a, "skipping {s} (not a regular file)", .{fifo});
    try std.testing.expect(std.mem.indexOf(u8, r.out, skip_line) != null);

    // The symlink was captured like single add captures it: a regular source
    // file holding the target string, flagged in attributes.
    try std.testing.expectEqualStrings("a.conf", try read(io, a, try h.srcOf(".config/app/link.conf")));
    var attrs = try mox.source.attributes.load(a, io, h.repo, null);
    try std.testing.expect(attrs.symlink(".config/app/link.conf"));
    try std.testing.expect(!exists(io, try h.srcOf(".config/app/pipe")));
}

test "apply: a FIFO at a live path is reported, never opened, and the run continues" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no FIFOs
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    // A whole-file target whose live path is a FIFO, a partial target whose
    // live path is a FIFO, and a healthy sibling that must still be written.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "ok\n");
    try writeRepo(io, &tmp, "repo/src/.config/app.toml", "# mox: own tui\n[tui]\nx = 1\n");
    try writeRepo(io, &tmp, "repo/src/healthy.conf", "fine\n");
    const fifo_whole = try h.homePath(".zshrc");
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(try a.dupeZ(u8, fifo_whole), 0o644));
    try tmp.dir.createDirPath(io, "home/.config");
    const fifo_partial = try h.homePath(".config/app.toml");
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(try a.dupeZ(u8, fifo_partial), 0o644));
    var g1 = try FifoGuard.start(a, io, fifo_whole);
    defer g1.stop(io);
    var g2 = try FifoGuard.start(a, io, fifo_partial);
    defer g2.stop(io);

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not a regular file") != null);
    // Both FIFO targets are reported individually, and neither was replaced.
    try std.testing.expect(std.mem.indexOf(u8, r.err, ".zshrc") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "app.toml") != null);
    const st = try Io.Dir.cwd().statFile(io, fifo_whole, .{ .follow_symlinks = false });
    try std.testing.expect(st.kind == .named_pipe);
    // The stray FIFOs did not brick the run: the sibling still landed.
    try std.testing.expectEqualStrings("fine\n", try read(io, a, try h.liveOf("healthy.conf")));
}

test "status and diff: a FIFO at a live path is an ERROR line, never opened" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no FIFOs
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "ok\n");
    try writeRepo(io, &tmp, "repo/src/healthy.conf", "fine\n");
    const fifo = try h.homePath(".zshrc");
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(try a.dupeZ(u8, fifo), 0o644));
    var guard = try FifoGuard.start(a, io, fifo);
    defer guard.stop(io);

    const st = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 1), st.rc);
    const err_line = try std.fmt.allocPrint(a, "ERROR    {s}", .{fifo});
    try std.testing.expect(std.mem.indexOf(u8, st.out, err_line) != null);
    // The healthy sibling still reports (MISSING: not applied yet).
    try std.testing.expect(std.mem.indexOf(u8, st.out, "healthy.conf") != null);

    const df = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), df.rc);
    try std.testing.expect(std.mem.indexOf(u8, df.err, "not a regular file") != null);
    // The sibling still diffs (absent live vs composed).
    try std.testing.expect(std.mem.indexOf(u8, df.out, "healthy.conf") != null);
}

test "commit: a FIFO at a recorded live path is skipped, never opened" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no FIFOs
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "ok\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The applied regular file was replaced by a FIFO out from under mox.
    const live = try h.liveOf(".zshrc");
    try Io.Dir.cwd().deleteFile(io, live);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(try a.dupeZ(u8, live), 0o644));
    var guard = try FifoGuard.start(a, io, live);
    defer guard.stop(io);

    const r = try h.run(&.{ "mox", "commit" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "skipped (not a regular file)") != null);
    // The source is untouched.
    try std.testing.expectEqualStrings("ok\n", try read(io, a, try h.srcOf(".zshrc")));
}

test "doctor: an attributes entry no managed target derives is an advisory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, null);
    try writeRepo(io, &tmp, "repo/src/.ssh/config", "Host x\n");
    // One entry a managed target derives, one orphan (a `./`-era remnant).
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml",
        \\["./old.conf"]
        \\mode = "0600"
        \\
        \\[".ssh/config"]
        \\mode = "0600"
        \\
    );

    const r = try h.run(&.{ "mox", "doctor" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "orphaned-attribute ./old.conf") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "orphaned-attribute .ssh/config") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "advisory item(s)") != null);
}
