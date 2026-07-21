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
