const std = @import("std");
const Env = @import("mox").env.Env;
const mox = @import("mox");

const Io = std.Io;

const builtin = @import("builtin");

/// Setup scripts are shell scripts with an exec bit on POSIX, and PowerShell
/// on Windows -- which has neither a shebang nor an exec bit, and is the
/// dialect mox dispatches there.
const script_ext = if (builtin.os.tag == .windows) ".ps1" else ".sh";

/// A script appending `word` to `log`, spelled for the platform's dialect.
fn appendingScript(a: std.mem.Allocator, log: []const u8, word: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return std.fmt.allocPrint(a, "Add-Content -LiteralPath '{s}' -Value '{s}'\n", .{ log, word });
    }
    return std.fmt.allocPrint(a, "#!/bin/sh\nprintf '{s}\\n' >> \"{s}\"\n", .{ word, log });
}

/// Like `appendingScript`, but with a `# mox: when <expr>` gate header placed
/// where the dialect allows it (after the shebang on POSIX, at the top on ps1).
fn gatedScript(a: std.mem.Allocator, log: []const u8, word: []const u8, when_expr: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return std.fmt.allocPrint(a, "# mox: when {s}\nAdd-Content -LiteralPath '{s}' -Value '{s}'\n", .{ when_expr, log, word });
    }
    return std.fmt.allocPrint(a, "#!/bin/sh\n# mox: when {s}\nprintf '{s}\\n' >> \"{s}\"\n", .{ when_expr, word, log });
}

fn writeExecScript(io: Io, dir: Io.Dir, sub: []const u8, content: []const u8, abs_path: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub, .data = content });
    if (builtin.os.tag == .windows) return; // no exec bit to set
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..abs_path.len], abs_path);
    zbuf[abs_path.len] = 0;
    _ = std.c.chmod(@ptrCast(&zbuf), 0o755);
}

/// PowerShell's Add-Content writes CRLF; compare on content, not line endings.
fn expectLoggedLines(expected: []const u8, logged: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (logged) |c| {
        if (c != '\r') try buf.append(std.testing.allocator, c);
    }
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "run_scripts: top-level runs, matching gated dir runs, non-matching skipped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const log = try std.fs.path.join(a, &.{ root, "log" });

    const top = try appendingScript(a, log, "top");
    const on = try appendingScript(a, log, "on");
    const off = try appendingScript(a, log, "off");

    const top_rel = try std.fmt.allocPrint(a, "scripts/00-top{s}", .{script_ext});
    const on_rel = try std.fmt.allocPrint(a, "scripts/gate=on/10-run{s}", .{script_ext});
    const off_rel = try std.fmt.allocPrint(a, "scripts/gate=off/20-skip{s}", .{script_ext});

    try writeExecScript(io, tmp.dir, top_rel, top, try std.fs.path.join(a, &.{ root, top_rel }));
    try writeExecScript(io, tmp.dir, on_rel, on, try std.fs.path.join(a, &.{ root, on_rel }));
    try writeExecScript(io, tmp.dir, off_rel, off, try std.fs.path.join(a, &.{ root, off_rel }));

    const scripts_dir = try std.fs.path.join(a, &.{ root, "scripts" });

    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("gate", "on");

    var out_aw: std.Io.Writer.Allocating = .init(a);
    var err_aw: std.Io.Writer.Allocating = .init(a);
    const result = try mox.apply.run_scripts.runStage(a, io, scripts_dir, &bindings, null, &out_aw.writer, &err_aw.writer);

    try std.testing.expectEqual(@as(usize, 2), result.ran);
    try std.testing.expectEqual(@as(usize, 0), result.failed);

    const logged = try Io.Dir.cwd().readFileAlloc(io, log, a, .limited(4096));
    // Top-level script ran before the gated one; the non-matching dir was skipped.
    try expectLoggedLines("top\non\n", logged);
}

test "run_scripts: a true `# mox: when` header runs, a false one is skipped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const log = try std.fs.path.join(a, &.{ root, "log" });

    const yes_rel = try std.fmt.allocPrint(a, "scripts/00-yes{s}", .{script_ext});
    const no_rel = try std.fmt.allocPrint(a, "scripts/10-no{s}", .{script_ext});
    try writeExecScript(io, tmp.dir, yes_rel, try gatedScript(a, log, "yes", "os=darwin"), try std.fs.path.join(a, &.{ root, yes_rel }));
    try writeExecScript(io, tmp.dir, no_rel, try gatedScript(a, log, "no", "os=linux"), try std.fs.path.join(a, &.{ root, no_rel }));

    const scripts_dir = try std.fs.path.join(a, &.{ root, "scripts" });
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");

    var out_aw: std.Io.Writer.Allocating = .init(a);
    var err_aw: std.Io.Writer.Allocating = .init(a);
    const result = try mox.apply.run_scripts.runStage(a, io, scripts_dir, &bindings, null, &out_aw.writer, &err_aw.writer);

    try std.testing.expectEqual(@as(usize, 1), result.ran);
    try std.testing.expectEqual(@as(usize, 1), result.skipped);
    try std.testing.expectEqual(@as(usize, 0), result.failed);

    // The false-header script's side effect never happened.
    const logged = try Io.Dir.cwd().readFileAlloc(io, log, a, .limited(4096));
    try expectLoggedLines("yes\n", logged);
}

test "run_scripts: a header `or` expression runs on the second alternative" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const log = try std.fs.path.join(a, &.{ root, "log" });

    const rel = try std.fmt.allocPrint(a, "scripts/00-alt{s}", .{script_ext});
    try writeExecScript(io, tmp.dir, rel, try gatedScript(a, log, "hit", "os=darwin or os=linux"), try std.fs.path.join(a, &.{ root, rel }));

    const scripts_dir = try std.fs.path.join(a, &.{ root, "scripts" });
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "linux");

    var out_aw: std.Io.Writer.Allocating = .init(a);
    var err_aw: std.Io.Writer.Allocating = .init(a);
    const result = try mox.apply.run_scripts.runStage(a, io, scripts_dir, &bindings, null, &out_aw.writer, &err_aw.writer);

    try std.testing.expectEqual(@as(usize, 1), result.ran);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
    try expectLoggedLines("hit\n", try Io.Dir.cwd().readFileAlloc(io, log, a, .limited(4096)));
}

test "run_scripts: a malformed `# mox: when` header fails that script, others still run" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const log = try std.fs.path.join(a, &.{ root, "log" });

    // `os=` is a truncated equality: it must fail to parse, not run or skip.
    const bad_rel = try std.fmt.allocPrint(a, "scripts/00-bad{s}", .{script_ext});
    const good_rel = try std.fmt.allocPrint(a, "scripts/10-good{s}", .{script_ext});
    try writeExecScript(io, tmp.dir, bad_rel, try gatedScript(a, log, "bad", "os="), try std.fs.path.join(a, &.{ root, bad_rel }));
    try writeExecScript(io, tmp.dir, good_rel, try gatedScript(a, log, "good", "os=darwin"), try std.fs.path.join(a, &.{ root, good_rel }));

    const scripts_dir = try std.fs.path.join(a, &.{ root, "scripts" });
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");

    var out_aw: std.Io.Writer.Allocating = .init(a);
    var err_aw: std.Io.Writer.Allocating = .init(a);
    const result = try mox.apply.run_scripts.runStage(a, io, scripts_dir, &bindings, null, &out_aw.writer, &err_aw.writer);

    // Malformed -> failed; the stage continued and ran the well-formed script.
    try std.testing.expectEqual(@as(usize, 1), result.failed);
    try std.testing.expectEqual(@as(usize, 1), result.ran);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
    try expectLoggedLines("good\n", try Io.Dir.cwd().readFileAlloc(io, log, a, .limited(4096)));
}

test "run_scripts: a header does not bypass a non-matching axis dir" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const log = try std.fs.path.join(a, &.{ root, "log" });

    // The dir tuple (os=linux) does not match; the header (os=darwin) WOULD be
    // true if evaluated -- proving the dir gate still filters before the header.
    const rel = try std.fmt.allocPrint(a, "scripts/os=linux/00-nope{s}", .{script_ext});
    try writeExecScript(io, tmp.dir, rel, try gatedScript(a, log, "nope", "os=darwin"), try std.fs.path.join(a, &.{ root, rel }));

    const scripts_dir = try std.fs.path.join(a, &.{ root, "scripts" });
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");

    var out_aw: std.Io.Writer.Allocating = .init(a);
    var err_aw: std.Io.Writer.Allocating = .init(a);
    const result = try mox.apply.run_scripts.runStage(a, io, scripts_dir, &bindings, null, &out_aw.writer, &err_aw.writer);

    try std.testing.expectEqual(@as(usize, 0), result.ran);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    // The script never ran: its log was never created.
    try std.testing.expect(!exists(io, log));
}

test "apply: writes file with parent directory creation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const live_path = try std.fs.path.join(std.testing.allocator, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "deep", "nested", "file.txt",
    });
    defer std.testing.allocator.free(live_path);

    try mox.apply.write.writeAtomic(io, live_path, "hello world\n", 0o644);

    // Verify file exists with right content.
    const content = try Io.Dir.cwd().readFileAlloc(io, live_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello world\n", content);
}

test "apply: overwrites existing file atomically" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const live_path = try std.fs.path.join(std.testing.allocator, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "file.txt",
    });
    defer std.testing.allocator.free(live_path);

    try mox.apply.write.writeAtomic(io, live_path, "first\n", 0o644);
    try mox.apply.write.writeAtomic(io, live_path, "second\n", 0o644);

    const content = try Io.Dir.cwd().readFileAlloc(io, live_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("second\n", content);
}

test "apply: writeAtomic enforces the exact restrictive mode past umask" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const live_path = try std.fs.path.join(std.testing.allocator, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "id_ed25519",
    });
    defer std.testing.allocator.free(live_path);

    // A 0600 file materializes at 0600; a discarded chmod would leave it at
    // the umask default (typically 0644) and expose the secret. A filesystem
    // with no mode bits cannot express that, and skips rather than asserting a
    // guarantee it does not make.
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    try mox.apply.write.writeAtomic(io, live_path, "PRIVATE KEY\n", 0o600);
    const st = try Io.Dir.cwd().statFile(io, live_path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}

test "apply: tmp file does not linger after success" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const live_path = try std.fs.path.join(std.testing.allocator, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "file.txt",
    });
    defer std.testing.allocator.free(live_path);

    try mox.apply.write.writeAtomic(io, live_path, "hello\n", 0o644);

    // .mox-tmp shouldn't exist after success.
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.mox-tmp", .{live_path});
    defer std.testing.allocator.free(tmp_path);
    const result = Io.Dir.cwd().openFile(io, tmp_path, .{});
    if (result) |f| {
        var fmut = f;
        fmut.close(io);
        try std.testing.expect(false); // tmp file should not exist
    } else |_| {
        // Expected: file not found
    }
}

test "applied: record then read roundtrip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cwd = try std.process.currentPathAlloc(io, arena.allocator());
    const state_dir = try std.fs.path.join(arena.allocator(), &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "state",
    });

    try mox.apply.applied.record(arena.allocator(), io, state_dir, "/home/me/.zshrc", "export EDITOR=nvim\n");

    const got = try mox.apply.applied.read(arena.allocator(), io, state_dir, "/home/me/.zshrc");
    try std.testing.expect(got != null);
    const expected = mox.apply.applied.contentHashHex("export EDITOR=nvim\n");
    try std.testing.expectEqualStrings(&expected, &got.?);
}

test "applied: read without a record returns null" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cwd = try std.process.currentPathAlloc(io, arena.allocator());
    const state_dir = try std.fs.path.join(arena.allocator(), &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path, "state",
    });

    const got = try mox.apply.applied.read(arena.allocator(), io, state_dir, "/home/me/.zshrc");
    try std.testing.expect(got == null);
}

fn read(io: Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
}

const testutil = @import("testutil.zig");
const Cli = testutil.Harness;

fn cliSetup(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !Cli {
    return testutil.setup(a, io, tmp, .{});
}

test "apply: a seed-once file seeds when absent, leaves an existing one untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/config.local", .data = "seed = default\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.mox/attributes.toml",
        .data =
        \\["config.local"]
        \\seed_once = true
        \\
        ,
    });

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("config.local");

    // Absent -> seeded with the composed content.
    const r1 = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r1.rc);
    try std.testing.expectEqualStrings("seed = default\n", try read(io, a, live));

    // User edits the seed; the source composes to something different now.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "seed = user-changed\n" });

    // Present -> left exactly as-is, no drift, exit 0.
    const r2 = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r2.rc);
    try std.testing.expectEqualStrings("seed = user-changed\n", try read(io, a, live));
}

test "apply+commit: an edited seed-once file is not offered by commit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/notes.txt", .data = "line one\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.mox/attributes.toml",
        .data =
        \\["notes.txt"]
        \\seed_once = true
        \\
        ,
    });

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("notes.txt");

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "line one\nline two\n" });

    const res = try c.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "notes.txt") == null);
    // The user's live edit is preserved; nothing routed back to source.
    try std.testing.expectEqualStrings("line one\nline two\n", try read(io, a, live));
    try std.testing.expectEqualStrings("line one\n", try read(io, a, try std.fs.path.join(a, &.{ c.repo, "src", "notes.txt" })));
}

fn modeOf(io: Io, path: []const u8) !u32 {
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    return @intCast(st.permissions.toMode() & 0o777);
}

test "apply: an executable source file materializes at 0755 (native, no prefix)" {
    // 0755 rides on the source's native exec bit, which a filesystem without
    // one cannot express.
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.local/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.local/bin/weather", .data = "#!/bin/sh\necho sunny\n" });

    const c = try cliSetup(a, io, &tmp);
    const src_bin = try std.fs.path.join(a, &.{ c.repo, "src", ".local", "bin", "weather" });
    try chmod(io, a, src_bin, 0o755);

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    const live = try c.homePath(".local/bin/weather");
    try std.testing.expectEqual(@as(u32, 0o755), try modeOf(io, live));
}

test "add: an executable live file leaves the source executable so git carries it" {
    // The exec bit rides on the source's native mode; a filesystem without one
    // cannot express it.
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath(".local/bin/tool");
    if (std.fs.path.dirname(live)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "#!/bin/sh\necho hi\n" });
    try chmod(io, a, live, 0o755);

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "add", live })).rc);

    // Source must be 0755 -- git stores 100755 and restores it on clone, so no
    // attributes record is needed for it (0755 is not recorded).
    const src = try std.fs.path.join(a, &.{ c.repo, "src", ".local", "bin", "tool" });
    try std.testing.expectEqual(@as(u32, 0o755), try modeOf(io, src));
}

test "remove then re-add at the same path drops the stale attributes entry" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath(".secret");
    if (std.fs.path.dirname(live)) |d| try Io.Dir.cwd().createDirPath(io, d);

    // Add a 0600 live file -> records mode 0600 in .mox/attributes.toml.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "a\n" });
    try chmod(io, a, live, 0o600);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "add", live })).rc);

    // Remove it: the attributes entry must be dropped, not orphaned.
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "remove", ".secret" })).rc);

    // Re-add a PLAIN 0644 file at the same path.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "b\n" });
    try chmod(io, a, live, 0o644);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "add", live })).rc);

    // Delete the live file so apply writes it fresh with the resolved mode.
    // With a stale 0600 entry this would apply 0600; the re-add is 0644.
    try Io.Dir.cwd().deleteFile(io, live);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqual(@as(u32, 0o644), try modeOf(io, live));
}

test "apply: a mode recorded in attributes survives a git-collapsed source stat" {
    // Git collapses 0600 -> 100644 on clone, so the source stats 0644 here;
    // the applied file must still be 0600, read from .mox/attributes.toml.
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.ssh");
    // Source on disk is 0644 (what a clone leaves), not 0600.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.ssh/config", .data = "Host x\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.mox/attributes.toml",
        .data =
        \\[".ssh/config"]
        \\mode = "0600"
        \\
        \\[".local/share/ro"]
        \\mode = "0444"
        \\
        ,
    });
    try tmp.dir.createDirPath(io, "repo/src/.local/share");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.local/share/ro", .data = "readonly\n" });

    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    try std.testing.expectEqual(@as(u32, 0o600), try modeOf(io, try c.homePath(".ssh/config")));
    try std.testing.expectEqual(@as(u32, 0o444), try modeOf(io, try c.homePath(".local/share/ro")));
}

test "apply: an explicit 0600 mode is re-enforced when the live file drifts to 0644" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.ssh");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.ssh/config", .data = "Host x\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.mox/attributes.toml", .data =
        \\[".ssh/config"]
        \\mode = "0600"
        \\
    });

    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    const live = try c.homePath(".ssh/config");
    try std.testing.expectEqual(@as(u32, 0o600), try modeOf(io, live));

    // Mode drifts (content unchanged); a re-apply heals the EXPLICIT mode.
    try chmod(io, a, live, 0o644);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqual(@as(u32, 0o600), try modeOf(io, live));
}

test "apply: a hand-hardened default-mode file is not re-loosened on unchanged apply" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No attributes.toml: the mode is the stat default (0644), not explicit.
    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.netrc", .data = "machine x\n" });

    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    const live = try c.homePath(".netrc");
    try std.testing.expectEqual(@as(u32, 0o644), try modeOf(io, live));

    // The user hardens the live file to 0600. A re-apply (content unchanged)
    // must NOT reset it to 0644: the mode was never explicitly declared, so
    // apply leaves a hand-hardened file alone.
    try chmod(io, a, live, 0o600);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqual(@as(u32, 0o600), try modeOf(io, live));
}

fn snapshotHas(io: Io, a: std.mem.Allocator, state_dir: []const u8, rel: []const u8, want: []const u8) !bool {
    const snaps = try std.fs.path.join(a, &.{ state_dir, "snapshots" });
    const ids = try mox.apply.snapshot.list(a, io, snaps);
    for (ids) |id| {
        const p = try std.fs.path.join(a, &.{ snaps, id, rel });
        const c = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1 << 20)) catch continue;
        if (std.mem.eql(u8, c, want)) return true;
    }
    return false;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn isSymlink(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

/// True if any file anywhere under `dir` contains `needle`.
fn treeContainsBytes(io: Io, a: std.mem.Allocator, dir: []const u8, needle: []const u8) !bool {
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true, .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(a, &.{ dir, entry.name });
        switch (entry.kind) {
            .directory => if (try treeContainsBytes(io, a, child, needle)) return true,
            .file => {
                const content = Io.Dir.cwd().readFileAlloc(io, child, a, .limited(1 << 20)) catch continue;
                if (std.mem.indexOf(u8, content, needle) != null) return true;
            },
            else => {},
        }
    }
    return false;
}

fn chmod(io: Io, a: std.mem.Allocator, path: []const u8, mode: u32) !void {
    _ = io;
    const z = try a.dupeZ(u8, path);
    _ = std.c.chmod(z.ptr, @intCast(mode));
}

test "apply: exact-dir sweep refuses to delete a subtree with an unsnapshottable entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The unsnapshottable entry is made so by chmod, which a filesystem with no
    // mode bits does not honour -- the file stays readable and there is nothing
    // for the sweep to refuse. The refusal itself is platform-independent and
    // covered where permissions mean something.
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    try tmp.dir.createDirPath(io, "repo/src/.config/app");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/keep.txt", .data = "keep\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/.mox-exact", .data = "" });

    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // A foreign directory with an unreadable file: it cannot be snapshotted.
    const foreign_dir = try c.homePath(".config/app/oldtool");
    try Io.Dir.cwd().createDirPath(io, foreign_dir);
    const readable = try c.homePath(".config/app/oldtool/readable.txt");
    const locked = try c.homePath(".config/app/oldtool/locked.txt");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = readable, .data = "r\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = locked, .data = "cannot snapshot\n" });
    try chmod(io, a, locked, 0o000);
    defer chmod(io, a, locked, 0o644) catch {};

    // --force would remove a foreign dir, but the unsnapshottable entry must
    // block the delete entirely: the subtree survives, and apply reports it.
    const r = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(exists(io, foreign_dir));
    try std.testing.expect(exists(io, locked));
    try std.testing.expect(exists(io, readable));
}

test "apply: a tracked-but-ignored source is skipped, not written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config/oldtool");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/oldtool/conf", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.moxignore", .data = ".config/oldtool/\n" });

    const c = try cliSetup(a, io, &tmp);
    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(!exists(io, try c.homePath(".config/oldtool/conf")));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "skipping") != null);
}

test "apply: exact prune leaves an ignored live file alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.claude");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.claude/.mox-exact", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.claude/CLAUDE.md", .data = "rules\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.moxignore", .data = ".claude/.credentials.json\n" });

    const c = try cliSetup(a, io, &tmp);
    // A live secret sitting in the exact dir, never applied by mox.
    const secret = try c.homePath(".claude/.credentials.json");
    if (std.fs.path.dirname(secret)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = secret, .data = "SECRET\n" });

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(exists(io, secret));
    try std.testing.expectEqualStrings("SECRET\n", try read(io, a, secret));
}

test "apply: --force exact sweep leaves an ignored direct-child file alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.claude");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.claude/.mox-exact", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.claude/CLAUDE.md", .data = "rules\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.moxignore", .data = ".claude/.credentials.json\n" });

    const c = try cliSetup(a, io, &tmp);
    // A live secret sitting in the exact dir, never applied by mox.
    const secret = try c.homePath(".claude/.credentials.json");
    if (std.fs.path.dirname(secret)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = secret, .data = "SECRET\n" });

    // --force would remove any other unmanaged file in this exact dir; the
    // ignored one must survive the actual deletion path, not just be refused.
    const r = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(exists(io, secret));
    try std.testing.expectEqualStrings("SECRET\n", try read(io, a, secret));
}

test "apply: exact prune leaves an entry ignored only via a dir-only ancestor rule alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The exact dir is nested under `.claude`, which is dir-only ignored. A
    // dir-only rule never matches a leaf checked in isolation (is_dir=false),
    // so this only survives via the ancestor walk in isPathIgnored.
    try tmp.dir.createDirPath(io, "repo/src/.claude/plugins");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.claude/plugins/.mox-exact", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.claude/plugins/marketplace.json", .data = "{}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.moxignore", .data = ".claude/\n" });

    const c = try cliSetup(a, io, &tmp);
    // An untracked, never-applied file directly inside the exact dir.
    const token = try c.homePath(".claude/plugins/token");
    if (std.fs.path.dirname(token)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = token, .data = "TOKEN\n" });

    const r = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(exists(io, token));
    try std.testing.expectEqualStrings("TOKEN\n", try read(io, a, token));
}

test "apply: --force exact sweep refuses a foreign subdir harboring a nested ignored file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.claude");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.claude/.mox-exact", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.claude/CLAUDE.md", .data = "rules\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.moxignore", .data = "secret.txt\n" });

    const c = try cliSetup(a, io, &tmp);
    // A foreign, non-ignored subdir with an innocuous file and a nested
    // ignored file two levels down -- neither the subdir itself nor its
    // direct children match the rule; only the deep descendant does.
    const oldtool_dir = try c.homePath(".claude/oldtool");
    const nested_dir = try c.homePath(".claude/oldtool/sub");
    try Io.Dir.cwd().createDirPath(io, nested_dir);
    const readme = try c.homePath(".claude/oldtool/readme.txt");
    const secret = try c.homePath(".claude/oldtool/sub/secret.txt");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = readme, .data = "notes\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = secret, .data = "SECRET\n" });

    // --force would otherwise remove the whole foreign subtree; the buried
    // ignored file must block the removal of the ENTIRE directory.
    const r = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(exists(io, oldtool_dir));
    try std.testing.expect(exists(io, readme));
    try std.testing.expect(exists(io, secret));
    try std.testing.expectEqualStrings("SECRET\n", try read(io, a, secret));
    try std.testing.expect(std.mem.indexOf(u8, r.err, "UNMANAGED") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "ignored") != null);
}

test "facts set: a value with a control character is refused, facts file uncorrupted" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    const c = try cliSetup(a, io, &tmp);

    // A newline in the value would inject a second TOML line / break parsing.
    const r = try c.run(&.{ "mox", "facts", "set", "note", "a\nadmin = 1" });
    try std.testing.expect(r.rc != 0);

    // facts.toml must not have been written with the injected content.
    const facts_path = try c.homePath(".config/mox/facts.toml");
    const facts = Io.Dir.cwd().readFileAlloc(io, facts_path, a, .limited(4096)) catch "";
    try std.testing.expect(std.mem.indexOf(u8, facts, "admin = 1") == null);
}

test "facts interview: persist is guarded by the command lock" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/facts-schema.toml",
        .data = "[[fact]]\nname = \"profile\"\nprompt = \"Profile\"\n",
    });

    const c = try cliSetup(a, io, &tmp);

    // A live process (this test) already holds the lock.
    const state = try std.fs.path.join(a, &.{ std.fs.path.dirname(c.repo).?, "state" });
    try Io.Dir.cwd().createDirPath(io, state);
    const boot = mox.cli.lock.bootId(a, io);
    const stamp = if (boot.len > 0) boot else "-";
    const lock_line = try std.fmt.allocPrint(a, "{d} {s} apply\n", .{ mox.cli.lock.selfPid(), stamp });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ state, "mox.lock" }), .data = lock_line });

    // The interview flow (which would persist the unbound fact) must refuse
    // rather than race the held lock.
    const r = try c.run(&.{ "mox", "facts" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "lock held") != null);
}

test "apply: a resolved secret value is never persisted anywhere in the state dir" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const secret_value = "s3cr3t-value-DO-NOT-LEAK-9f8a7b6c";
    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = secret_value ++ "\n" });

    const cwd = try std.process.currentPathAlloc(io, a);
    const secret_abs = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "secret.txt" });
    const src = try std.fmt.allocPrint(
        a,
        "export FOO=bar\n# mox: secret \"file://{s}\"\nexport BAZ=qux\n",
        .{secret_abs},
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc", .data = src });

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath(".zshrc");

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    // The secret is inlined into the live file (intended).
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), secret_value) != null);

    // It must appear nowhere in mox's own state tree (applied-content, snapshots, ...).
    const state = try std.fs.path.join(a, &.{ std.fs.path.dirname(c.repo).?, "state" });
    try std.testing.expect(!try treeContainsBytes(io, a, state, secret_value));
}

test "apply: an inline <secret:URI> value is inlined mid-line but never persisted in state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const secret_value = "inline-s3cr3t-DO-NOT-LEAK-1a2b3c4d";
    try tmp.dir.createDirPath(io, "repo/src");
    // No trailing newline: a file secret is spliced verbatim, so a mid-line
    // capture must not carry a stray newline into the middle of the line.
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = secret_value });

    const cwd = try std.process.currentPathAlloc(io, a);
    const secret_abs = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "secret.txt" });
    // Mid-line capture surrounded by literal text: the whole line is `.secret`.
    const src = try std.fmt.allocPrint(
        a,
        "export FOO=bar\nexport TOKEN=<secret:file://{s}>-suffix\nexport BAZ=qux\n",
        .{secret_abs},
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc", .data = src });

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath(".zshrc");

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    // The secret is spliced mid-line into the live file (intended).
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "TOKEN=" ++ secret_value ++ "-suffix") != null);

    // And appears nowhere in mox's own state tree (applied-content cache, snapshots).
    const state = try std.fs.path.join(a, &.{ std.fs.path.dirname(c.repo).?, "state" });
    try std.testing.expect(!try treeContainsBytes(io, a, state, secret_value));
}

test "apply: a secret in a Cat A gitconfig directive region is inlined live but never cached" {
    // A single-layer `.gitconfig` is Cat A, but a `# mox:` directive routes it
    // through Cat B. The resolved secret must inherit `.secret` provenance so
    // its cleartext is kept out of the applied-content cache and snapshots --
    // the Cat A route must not discard the fact that a secret was resolved.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const secret_value = "catA-directive-s3cr3t-DO-NOT-LEAK-7e6d5c4b";
    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = secret_value });

    const cwd = try std.process.currentPathAlloc(io, a);
    const secret_abs = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "secret.txt" });
    const src = try std.fmt.allocPrint(
        a,
        "[user]\n\tname = me\n# mox: when os=darwin\n\ttoken = <secret:file://{s}>\n# mox: end\n",
        .{secret_abs},
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.gitconfig", .data = src });

    const c = try testutil.setup(a, io, &tmp, .{ .os = "darwin" });
    const live = try c.homePath(".gitconfig");

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    // The secret is inlined into the live gitconfig (intended).
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), secret_value) != null);
    // It must appear nowhere in mox's own state tree.
    try std.testing.expect(!try treeContainsBytes(io, a, c.state, secret_value));
}

test "apply: a secret picked by a Cat B `from` region is inlined live but never cached" {
    // The standalone `from` directive arm must honour the picked fragment's
    // secret flag: a fragment carrying an inline `<secret:URI>` makes the file
    // secret-bearing, so its cleartext stays out of the cache.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const secret_value = "from-region-s3cr3t-DO-NOT-LEAK-2f3e4d5c";
    try tmp.dir.createDirPath(io, "repo/src/.zshrc.d/os");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = secret_value });

    const cwd = try std.process.currentPathAlloc(io, a);
    const secret_abs = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "secret.txt" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.zshrc",
        .data = "export A=1\n# mox: from \"os\"\nexport TOKEN=none\n# mox: end\n",
    });
    const frag = try std.fmt.allocPrint(a, "export TOKEN=<secret:file://{s}>\n", .{secret_abs});
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc.d/os/darwin", .data = frag });

    const c = try testutil.setup(a, io, &tmp, .{ .os = "darwin" });
    const live = try c.homePath(".zshrc");

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "TOKEN=" ++ secret_value) != null);
    try std.testing.expect(!try treeContainsBytes(io, a, c.state, secret_value));
}

test "apply: a directiveless Cat A file resolves an inline secret and keeps it out of the cache" {
    // A pure structural `.toml` (no `# mox:` directive) must still resolve an
    // inline `<secret:URI>` AND mark itself secret-bearing so the resolved value
    // is excluded from the applied-content cache.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const secret_value = "catA-inline-s3cr3t-DO-NOT-LEAK-9a8b7c6d";
    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = secret_value });

    const cwd = try std.process.currentPathAlloc(io, a);
    const secret_abs = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "secret.txt" });
    const src = try std.fmt.allocPrint(a, "[github]\ntoken = \"<secret:file://{s}>\"\n", .{secret_abs});
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/config.toml", .data = src });

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("config.toml");

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    // The inline secret resolved (no `<SECRET:...>` placeholder left behind).
    const live_bytes = try read(io, a, live);
    try std.testing.expect(std.mem.indexOf(u8, live_bytes, secret_value) != null);
    try std.testing.expect(std.mem.indexOf(u8, live_bytes, "<SECRET:") == null);
    try std.testing.expect(!try treeContainsBytes(io, a, c.state, secret_value));
}

test "diff: a rotated secret is redacted on both sides, never printing a resolved value" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old_secret = "OLD-diff-s3cr3t-DO-NOT-LEAK-1111aaaa";
    const new_secret = "NEW-diff-s3cr3t-DO-NOT-LEAK-2222bbbb";
    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = old_secret });

    const cwd = try std.process.currentPathAlloc(io, a);
    const secret_abs = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "secret.txt" });
    const src = try std.fmt.allocPrint(
        a,
        "export FOO=bar\nexport TOKEN=<secret:file://{s}>\nexport BAZ=qux\n",
        .{secret_abs},
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc", .data = src });

    const c = try cliSetup(a, io, &tmp);

    // Apply resolves and writes the old secret, recording secret provenance.
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    // Rotate the secret: the composed side now resolves a different value, so
    // the token line drifts and shows up as a diff hunk.
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = new_secret });

    const r = try c.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    // Neither the old (live) nor the new (composed) resolved value may reach stdout.
    try std.testing.expect(std.mem.indexOf(u8, r.out, old_secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, new_secret) == null);
    // The secret line is present as a redaction marker.
    try std.testing.expect(std.mem.indexOf(u8, r.out, mox.provenance.map.secret_redaction) != null);
}

fn linkTarget(io: Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.cwd().readLink(io, path, &buf);
    return a.dupe(u8, buf[0..n]);
}

/// Assert a symlink at `path` points at `expected`, tolerating the `/`->`\`
/// separator rewrite Windows applies to a stored link target (same rule mox's
/// drift check uses). Falls back to a readable string diff on a real mismatch.
fn expectLinkTarget(io: Io, a: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const actual = try linkTarget(io, a, path);
    if (mox.apply.applied.sameSymlinkTarget(expected, actual)) return;
    try std.testing.expectEqualStrings(expected, actual);
}

test "apply: a symlink-flagged source refuses a live regular file as drift, replaces with --force after snapshot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A regular source file whose content is the symlink target, marked
    // `symlink = true` in `.mox/attributes.toml` (no actual symlink in src/).
    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/mylink", .data = "/tmp/mox-symlink-target\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.mox/attributes.toml",
        .data =
        \\["mylink"]
        \\symlink = true
        \\
        ,
    });

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("mylink");

    // A real, hand-written regular file already lives at the target path.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "hand written user data\n" });

    // First apply: this is unrecorded live content mox never wrote. It must be
    // refused as drift, NOT silently unlinked.
    const r1 = try c.run(&.{ "mox", "apply" });
    try std.testing.expect(r1.rc != 0);
    try std.testing.expect(std.mem.indexOf(u8, r1.err, "mylink") != null);
    try std.testing.expect(!isSymlink(io, live));
    try std.testing.expectEqualStrings("hand written user data\n", try read(io, a, live));

    // With --force: the original is snapshotted, then replaced by the symlink.
    const r2 = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expectEqual(@as(u8, 0), r2.rc);
    try std.testing.expect(isSymlink(io, live));
    try expectLinkTarget(io, a, live, "/tmp/mox-symlink-target");
    const state = try std.fs.path.join(a, &.{ std.fs.path.dirname(c.repo).?, "state" });
    try std.testing.expect(try snapshotHas(io, a, state, "mylink", "hand written user data\n"));
}

test "apply: a symlink target interpolates machine captures before the link is created" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The target is composable: `<machine.home>` must expand before the symlink
    // is planted, so the link points at a concrete, machine-resolved path.
    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/nvimlink", .data = "<machine.home>/real-nvim\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.mox/attributes.toml",
        .data =
        \\["nvimlink"]
        \\symlink = true
        \\
        ,
    });

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("nvimlink");

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(isSymlink(io, live));
    const want = try std.fmt.allocPrint(a, "{s}/real-nvim", .{c.home});
    try expectLinkTarget(io, a, live, want);
}

test "add: a live symlink is captured as a regular source file plus a symlink flag" {
    // Creating a symlink needs a POSIX-class filesystem; where mode bits are
    // absent there is no symlink to capture.
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath(".config/nvim");
    if (std.fs.path.dirname(live)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().symLink(io, "/opt/dotfiles/nvim", live, .{});

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "add", live })).rc);

    // The source is a regular file whose content is the link target -- no
    // symlink enters the repo.
    const src = try std.fs.path.join(a, &.{ c.repo, "src", ".config", "nvim" });
    try std.testing.expect(!isSymlink(io, src));
    try std.testing.expectEqualStrings("/opt/dotfiles/nvim", try read(io, a, src));

    // ... flagged `symlink = true`, keyed by the portable home-relative key.
    var attrs = try mox.source.attributes.load(a, io, c.repo);
    try std.testing.expect(attrs.symlink(".config/nvim"));
}

test "apply: .mox-exact removes a clean managed leftover and snapshots it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config/app");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/keep.txt", .data = "keep\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/old.txt", .data = "old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/.mox-exact", .data = "" });

    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    const keep_live = try c.homePath(".config/app/keep.txt");
    const old_live = try c.homePath(".config/app/old.txt");
    try std.testing.expect(exists(io, old_live));

    // Remove the source for old.txt; it is now a clean managed leftover.
    try Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ c.repo, "src/.config/app/old.txt" }));

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(!exists(io, old_live));
    try std.testing.expect(exists(io, keep_live));

    const state = try std.fs.path.join(a, &.{ std.fs.path.dirname(c.repo).?, "state" });
    try std.testing.expect(try snapshotHas(io, a, state, ".config/app/old.txt", "old\n"));
}

test "apply: .mox-exact refuses a foreign file without --force, removes with it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config/app");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/keep.txt", .data = "keep\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/.mox-exact", .data = "" });

    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // A foreign file mox never wrote.
    const foreign = try c.homePath(".config/app/foreign.txt");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = foreign, .data = "mine\n" });

    // Refused without --force: nonzero rc, file remains.
    const r1 = try c.run(&.{ "mox", "apply" });
    try std.testing.expect(r1.rc != 0);
    try std.testing.expect(exists(io, foreign));
    try std.testing.expect(std.mem.indexOf(u8, r1.err, "foreign.txt") != null);

    // Removed with --force, and snapshotted.
    const r2 = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expectEqual(@as(u8, 0), r2.rc);
    try std.testing.expect(!exists(io, foreign));
    const state = try std.fs.path.join(a, &.{ std.fs.path.dirname(c.repo).?, "state" });
    try std.testing.expect(try snapshotHas(io, a, state, ".config/app/foreign.txt", "mine\n"));
}

test "apply: .mox-exact keeps managed files including a nested managed dir" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config/app/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/keep.txt", .data = "keep\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/sub/deep.txt", .data = "deep\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/.mox-exact", .data = "" });

    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    const foreign = try c.homePath(".config/app/bar.txt");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = foreign, .data = "x\n" });

    const r = try c.run(&.{ "mox", "apply", "--force" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(!exists(io, foreign));
    try std.testing.expect(exists(io, try c.homePath(".config/app/keep.txt")));
    try std.testing.expect(exists(io, try c.homePath(".config/app/sub/deep.txt")));
}

test "apply: a path argument writes only that file, leaving another managed file untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc", .data = "a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.bashrc", .data = "b\n" });

    const c = try cliSetup(a, io, &tmp);
    const zshrc_live = try c.homePath(".zshrc");
    const r = try c.run(&.{ "mox", "apply", zshrc_live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(exists(io, zshrc_live));
    try std.testing.expect(!exists(io, try c.homePath(".bashrc")));
}

test "apply: an unmanaged path argument exits non-zero reporting not managed, writes nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.zshrc", .data = "a\n" });

    const c = try cliSetup(a, io, &tmp);
    const nope = try c.homePath(".nope");
    const r = try c.run(&.{ "mox", "apply", nope });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not managed") != null);
    try std.testing.expect(!exists(io, try c.homePath(".zshrc")));
}

test "apply: a scoped run skips the .mox-exact prune sweep entirely" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config/app");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/keep.txt", .data = "keep\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/app/.mox-exact", .data = "" });

    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // A foreign file mox never wrote, inside the exact-marked directory. An
    // unscoped apply would refuse (nonzero rc) without --force; a scoped
    // apply naming only keep.txt must not even look at it.
    const foreign = try c.homePath(".config/app/foreign.txt");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = foreign, .data = "mine\n" });

    const keep_live = try c.homePath(".config/app/keep.txt");
    const r = try c.run(&.{ "mox", "apply", keep_live });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(exists(io, foreign));
}

test "run_scripts: a hung script is killed within the configured timeout" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    // Sleeps far past the timeout; bounded by the sleep so a regression fails
    // (script exits 0) rather than hanging.
    try writeExecScript(io, tmp.dir, "scripts/00-hang.sh", "#!/bin/sh\nsleep 5\n", try std.fs.path.join(a, &.{ root, "scripts/00-hang.sh" }));
    const scripts_dir = try std.fs.path.join(a, &.{ root, "scripts" });

    var bindings = std.StringHashMap([]const u8).init(a);
    var script_env = try mox.apply.run_scripts.buildScriptEnv(a, Env{ .process = std.testing.environ }, "/repo", "/state", "/home", &.{});
    try script_env.put("MOX_SCRIPT_TIMEOUT_MS", "200");

    var out_aw: std.Io.Writer.Allocating = .init(a);
    var err_aw: std.Io.Writer.Allocating = .init(a);
    const result = try mox.apply.run_scripts.runStage(a, io, scripts_dir, &bindings, &script_env, &out_aw.writer, &err_aw.writer);

    try std.testing.expectEqual(@as(usize, 0), result.ran);
    try std.testing.expectEqual(@as(usize, 1), result.failed);
}

test "run_scripts: a script sees MOX_HOME and MOX_FACT_* from the built env" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const out_file = try std.fs.path.join(a, &.{ root, "seen" });
    const script = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(
            a,
            "Set-Content -LiteralPath '{s}' -Value \"$env:MOX_HOME|$env:MOX_FACT_PROFILE\"\n",
            .{out_file},
        )
    else
        try std.fmt.allocPrint(
            a,
            "#!/bin/sh\nprintf '%s|%s\\n' \"$MOX_HOME\" \"$MOX_FACT_PROFILE\" > \"{s}\"\n",
            .{out_file},
        );
    const env_rel = try std.fmt.allocPrint(a, "scripts/00-env{s}", .{script_ext});
    try writeExecScript(io, tmp.dir, env_rel, script, try std.fs.path.join(a, &.{ root, env_rel }));
    const scripts_dir = try std.fs.path.join(a, &.{ root, "scripts" });

    var bindings = std.StringHashMap([]const u8).init(a);
    const facts = [_]mox.apply.run_scripts.Fact{.{ .name = "profile", .value = "work" }};
    var script_env = try mox.apply.run_scripts.buildScriptEnv(a, Env{ .process = std.testing.environ }, "/repo", "/state", "/home/tester", &facts);

    var out_aw: std.Io.Writer.Allocating = .init(a);
    var err_aw: std.Io.Writer.Allocating = .init(a);
    const result = try mox.apply.run_scripts.runStage(a, io, scripts_dir, &bindings, &script_env, &out_aw.writer, &err_aw.writer);
    try std.testing.expectEqual(@as(usize, 1), result.ran);

    try expectLoggedLines("/home/tester|work\n", try read(io, a, out_file));
}

test "run_scripts: a hung script is terminated at the timeout, not left to block apply" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    // Sleeps far longer than the timeout below; bounded (30s, not forever) so a
    // broken kill fails the assertion instead of hanging CI.
    const script = if (builtin.os.tag == .windows)
        "Start-Sleep -Seconds 30\n"
    else
        "#!/bin/sh\nsleep 30\n";
    const rel = try std.fmt.allocPrint(a, "scripts/00-hang{s}", .{script_ext});
    try writeExecScript(io, tmp.dir, rel, script, try std.fs.path.join(a, &.{ root, rel }));
    const scripts_dir = try std.fs.path.join(a, &.{ root, "scripts" });

    var bindings = std.StringHashMap([]const u8).init(a);
    const facts = [_]mox.apply.run_scripts.Fact{};
    var script_env = try mox.apply.run_scripts.buildScriptEnv(a, Env{ .process = std.testing.environ }, "/repo", "/state", "/home/tester", &facts);
    try script_env.put("MOX_SCRIPT_TIMEOUT_MS", "500");

    var out_aw: std.Io.Writer.Allocating = .init(a);
    var err_aw: std.Io.Writer.Allocating = .init(a);
    const result = try mox.apply.run_scripts.runStage(a, io, scripts_dir, &bindings, &script_env, &out_aw.writer, &err_aw.writer);

    // The script was terminated at ~500ms, counted failed, and runStage
    // RETURNED rather than blocking for the full 30s sleep.
    try std.testing.expectEqual(@as(usize, 1), result.failed);
    try std.testing.expectEqual(@as(usize, 0), result.ran);
}

test "init --clone: refuses a non-empty repo dir before touching git" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Pre-populate the repo dir so the clone must refuse.
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/existing.txt", .data = "keep me\n" });

    const c = try cliSetup(a, io, &tmp);
    const r = try c.run(&.{ "mox", "init", "--clone", "https://example.invalid/does-not-matter.git" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "non-empty") != null);
    // The existing content is untouched.
    try std.testing.expectEqualStrings("keep me\n", try read(io, a, try std.fs.path.join(a, &.{ c.repo, "existing.txt" })));
}

test "status: a symlink target is classified without following the link" {
    // Real symlinks are planted and inspected; needs symlink support.
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/mylink", .data = "/tmp/mox-status-target\n" });
    try tmp.dir.createDirPath(io, "repo/.mox");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.mox/attributes.toml",
        .data =
        \\["mylink"]
        \\symlink = true
        \\
        ,
    });

    const c = try cliSetup(a, io, &tmp);
    const live = try c.homePath("mylink");

    // Apply plants the link; status then reports it clean, exit 0.
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    const s1 = try c.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 0), s1.rc);
    try std.testing.expect(std.mem.indexOf(u8, s1.out, "clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1.out, "DRIFT") == null);

    // Repoint the link by hand: status flags a problem and exits 1. Reading
    // through the link (the bug) would perpetually mis-classify a valid link.
    std.Io.Dir.cwd().deleteFile(io, live) catch {};
    try Io.Dir.cwd().symLink(io, "/somewhere/else", live, .{});
    const s2 = try c.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 1), s2.rc);
    try std.testing.expect(std.mem.indexOf(u8, s2.out, "DRIFT") != null);

    // A live DIRECTORY where a symlink is expected must NOT abort status
    // (reading through a dir-link returns error.IsDir); it reports DRIFT.
    std.Io.Dir.cwd().deleteFile(io, live) catch {};
    try Io.Dir.cwd().createDirPath(io, live);
    const s3 = try c.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 1), s3.rc);
    try std.testing.expect(std.mem.indexOf(u8, s3.out, "DRIFT") != null);
}

// -- generator (`for ... into`) fan-out + prune (data-safety critical) --

/// A generator source at `src/.config/gen.inc` whose body is a single
/// `key=<id.slug>` line, driven by `data/ids.toml`. Rows are the given slugs.
fn writeGenFixture(io: Io, tmp: *std.testing.TmpDir, slugs: []const []const u8) !void {
    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen.inc",
        .data = "# mox: for id in \"data/ids.toml\" into \"id-<id.slug>.inc\"\nkey=<id.slug>\n# mox: end\n",
    });
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    for (slugs) |s| {
        try body.appendSlice(std.testing.allocator, "[[ids]]\nslug = \"");
        try body.appendSlice(std.testing.allocator, s);
        try body.appendSlice(std.testing.allocator, "\"\n\n");
    }
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = body.items });
}

test "diff generator: diffs what it produces, not the generator itself" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // Freshly applied: the produced files match, so there is nothing to show
    // -- and, critically, no attempt to compose the generator as an ordinary
    // file (which rejects its own `into` clause as IntoOnNonGenerator).
    const clean = try c.run(&.{ "mox", "diff" });
    try std.testing.expect(std.mem.indexOf(u8, clean.err, "compose failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean.err, "IntoOnNonGenerator") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean.out, "gen.inc") == null);

    // Edit one produced file: diff must report THAT path, since the generator
    // has no live file of its own to compare.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try c.homePath(".config/id-a.inc"), .data = "key=EDITED\n" });
    const res = try c.run(&.{ "mox", "diff" });
    try std.testing.expect(std.mem.indexOf(u8, res.err, "compose failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "id-a.inc") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "key=EDITED") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "key=a") != null);
    // The untouched sibling row is not reported.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "id-b.inc") == null);
}

test "apply generator: writes one file per row; the generator's own path is not written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("key=a\n", try read(io, a, try c.homePath(".config/id-a.inc")));
    try std.testing.expectEqualStrings("key=b\n", try read(io, a, try c.homePath(".config/id-b.inc")));
    // The generator source never materializes at its own live path.
    try std.testing.expect(!exists(io, try c.homePath(".config/gen.inc")));
}

test "apply generator: a rendered output matching an ignore rule is skipped, not written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two rows: "a" renders to id-a.inc (kept), "b" renders to id-b.inc, which
    // an ignore rule targets directly -- the generator must honor it same as
    // any other tracked source, not shield it from pruning via the keep-set.
    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.moxignore", .data = "id-b.inc\n" });
    const c = try cliSetup(a, io, &tmp);

    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expectEqualStrings("key=a\n", try read(io, a, try c.homePath(".config/id-a.inc")));
    try std.testing.expect(!exists(io, try c.homePath(".config/id-b.inc")));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "skipping") != null);
}

test "apply generator prune: dropping a row removes its file (snapshotted), others intact, unrelated file untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b", "c" });
    const c = try cliSetup(a, io, &tmp);

    // An unrelated, unmanaged file in the same directory must never be touched.
    const keep = try c.homePath(".config/keep.txt");
    if (std.fs.path.dirname(keep)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = keep, .data = "precious\n" });

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try c.homePath(".config/id-b.inc")));

    // Drop row b, re-apply.
    try writeGenFixture(io, &tmp, &.{ "a", "c" });
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // b's file is gone; a and c survive; the snapshot holds b's content.
    try std.testing.expect(!exists(io, try c.homePath(".config/id-b.inc")));
    try std.testing.expectEqualStrings("key=a\n", try read(io, a, try c.homePath(".config/id-a.inc")));
    try std.testing.expectEqualStrings("key=c\n", try read(io, a, try c.homePath(".config/id-c.inc")));
    try std.testing.expect(try snapshotHas(io, a, c.state, ".config/id-b.inc", "key=b\n"));

    // The unrelated file is exactly as it was.
    try std.testing.expectEqualStrings("precious\n", try read(io, a, keep));
}

test "apply generator prune: emptying the data source removes every generated file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try c.homePath(".config/id-a.inc")));

    // Empty the data (present file, zero rows) -> every leaf pruned.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "ids = []\n" });
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    try std.testing.expect(!exists(io, try c.homePath(".config/id-a.inc")));
    try std.testing.expect(!exists(io, try c.homePath(".config/id-b.inc")));
    // The pruned leaves are recoverable.
    try std.testing.expect(try snapshotHas(io, a, c.state, ".config/id-a.inc", "key=a\n"));
}

test "apply generator: truncating the data source to zero bytes fails and keeps existing leaves" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try c.homePath(".config/id-a.inc")));
    try std.testing.expect(exists(io, try c.homePath(".config/id-b.inc")));

    // Truncate the data to 0 bytes: the array is now ABSENT (a corrupt/truncated
    // source), not a present-empty `ids = []`. It must fail loudly rather than
    // silently prune every leaf, unlike the emptying-via-`[]` case above.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "" });
    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expect(r.rc != 0);

    // The existing leaves survive untouched -- the failure protected them.
    try std.testing.expectEqualStrings("key=a\n", try read(io, a, try c.homePath(".config/id-a.inc")));
    try std.testing.expectEqualStrings("key=b\n", try read(io, a, try c.homePath(".config/id-b.inc")));
    // Nothing was removed, so nothing was snapshotted.
    try std.testing.expect(!(try snapshotHas(io, a, c.state, ".config/id-a.inc", "key=a\n")));
}

test "apply generator: a for-into mixed with stray top-level content is rejected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config");
    // A stray top-level line precedes the for-into block, so the block is not the
    // whole file. The fan-out would silently drop that content; instead it must
    // fail loudly (IntoOnNonGenerator) and produce nothing.
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen.inc",
        .data = "[header]\n# mox: for id in \"data/ids.toml\" into \"id-<id.slug>.inc\"\nkey=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "[[ids]]\nslug = \"a\"\n" });

    const c = try cliSetup(a, io, &tmp);
    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "IntoOnNonGenerator") != null);
    // Nothing fanned out from the rejected generator.
    try std.testing.expect(!exists(io, try c.homePath(".config/id-a.inc")));
}

test "apply generator: mox remove deletes all produced files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try c.homePath(".config/id-a.inc")));

    const r = try c.run(&.{ "mox", "remove", ".config/gen.inc" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(!exists(io, try c.homePath(".config/id-a.inc")));
    try std.testing.expect(!exists(io, try c.homePath(".config/id-b.inc")));
    // The source is trashed (no longer under src).
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ c.repo, "src", ".config", "gen.inc" })));
    // Removal is recoverable.
    try std.testing.expect(try snapshotHas(io, a, c.state, ".config/id-a.inc", "key=a\n"));
}

test "apply generator: a rendered path colliding with a managed file is rejected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen.inc",
        .data = "# mox: for id in \"data/ids.toml\" into \"collide.inc\"\nkey=<id.slug>\n# mox: end\n",
    });
    // A regular managed file at the exact path the generator renders.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/collide.inc", .data = "managed\n" });
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "[[ids]]\nslug = \"only\"\n" });

    const c = try cliSetup(a, io, &tmp);
    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "collides") != null);
    // The regular managed file keeps its own content (the collision aborts only
    // the generator, which produced nothing).
    try std.testing.expectEqualStrings("managed\n", try read(io, a, try c.homePath(".config/collide.inc")));
}

test "apply generator: into on a nested for inside the body is rejected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen.inc",
        .data = "# mox: for id in \"data/ids.toml\" into \"<id.slug>.inc\"\n" ++
            "# mox: for u in id.urls into \"nested.inc\"\n" ++
            "x=<u>\n" ++
            "# mox: end\n" ++
            "# mox: end\n",
    });
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "[[ids]]\nslug = \"a\"\nurls = [\"u\"]\n" });

    const c = try cliSetup(a, io, &tmp);
    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "IntoOnNestedFor") != null);
}

test "apply generator: private-layer data shadows the committed source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen.inc",
        .data = "# mox: for id in \"data/ids.toml\" into \"id-<id.slug>.inc\"\nkey=<id.slug>\n# mox: end\n",
    });
    // Committed data is empty; the private layer supplies the real rows.
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "" });
    try tmp.dir.createDirPath(io, "state/private/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/private/data/ids.toml", .data = "[[ids]]\nslug = \"secret\"\n" });

    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("key=secret\n", try read(io, a, try c.homePath(".config/id-secret.inc")));
}

test "apply generator: a transient compose failure keeps the prior leaves, deletes nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try c.homePath(".config/id-a.inc")));
    try std.testing.expect(exists(io, try c.homePath(".config/id-b.inc")));

    // Delete the data source: composeGenerator errors (a transient failure, as
    // if the source were momentarily unreadable). The existing leaves survive.
    try Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ c.repo, "data", "ids.toml" }));
    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expect(r.rc != 0); // the failure is counted, not swallowed

    try std.testing.expectEqualStrings("key=a\n", try read(io, a, try c.homePath(".config/id-a.inc")));
    try std.testing.expectEqualStrings("key=b\n", try read(io, a, try c.homePath(".config/id-b.inc")));
    // Nothing was removed, so nothing was snapshotted.
    try std.testing.expect(!(try snapshotHas(io, a, c.state, ".config/id-a.inc", "key=a\n")));
}

test "apply generator: a failed generator's leaves survive the exact-dir sweep" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    // Mark the generator's target dir exact: a leaf not in the managed set would
    // be swept as unmanaged.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/.mox-exact", .data = "" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try c.homePath(".config/id-a.inc")));

    // Data source gone -> compose fails; the leaves must NOT be swept away.
    try Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ c.repo, "data", "ids.toml" }));
    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expect(r.rc != 0);
    try std.testing.expectEqualStrings("key=a\n", try read(io, a, try c.homePath(".config/id-a.inc")));
    try std.testing.expectEqualStrings("key=b\n", try read(io, a, try c.homePath(".config/id-b.inc")));
}

test "apply generator: a leaf moving between generators is never deleted+recreated" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config");
    // Two generators rendering the SAME path with identical bodies, from two
    // data sources. Whichever produces the row owns the leaf that apply.
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/g1.inc",
        .data = "# mox: for id in \"data/d1.toml\" into \"shared-<id.slug>.inc\"\nval=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/g2.inc",
        .data = "# mox: for id in \"data/d2.toml\" into \"shared-<id.slug>.inc\"\nval=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/d1.toml", .data = "[[d1]]\nslug = \"x\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/d2.toml", .data = "d2 = []\n" });

    const c = try cliSetup(a, io, &tmp);
    const shared = try c.homePath(".config/shared-x.inc");

    // Run 1: g1 owns shared-x.
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("val=x\n", try read(io, a, shared));

    // Run 2: move x to g2 in one apply. Run 3: move it back. Across the two
    // moves, the dropper is the earlier generator in AT LEAST one of them under
    // any fixed walk order -- the case that used to prune-then-recreate.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/d1.toml", .data = "d1 = []\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/d2.toml", .data = "[[d2]]\nslug = \"x\"\n" });
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("val=x\n", try read(io, a, shared));

    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/d1.toml", .data = "[[d1]]\nslug = \"x\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/d2.toml", .data = "d2 = []\n" });
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("val=x\n", try read(io, a, shared));

    // The file was untouched throughout: no delete+recreate, so no snapshot of
    // it was ever taken.
    try std.testing.expect(!(try snapshotHas(io, a, c.state, ".config/shared-x.inc", "val=x\n")));
}

test "apply generator: mox remove does not delete a leaf another generator owns" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // genB produces shared.inc through a normal apply; its manifest records it.
    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/genB.inc",
        .data = "# mox: for id in \"data/db.toml\" into \"shared.inc\"\nval=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/db.toml", .data = "[[db]]\nslug = \"b\"\n" });

    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    const shared = try c.homePath(".config/shared.inc");
    try std.testing.expectEqualStrings("val=b\n", try read(io, a, shared));

    // A second generator genA is present, and (an inconsistent state) its stale
    // manifest lists shared.inc. Removing genA must not delete shared.inc, which
    // genB legitimately owns.
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/genA.inc",
        .data = "# mox: for id in \"data/da.toml\" into \"a-<id.slug>.inc\"\nk=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/da.toml", .data = "" });
    const gen_a_live = try c.homePath(".config/genA.inc");
    try mox.apply.generated.writeManifest(a, io, c.state, gen_a_live, &.{shared});

    const r = try c.run(&.{ "mox", "remove", ".config/genA.inc" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    // genB's leaf survives, with its content intact.
    try std.testing.expectEqualStrings("val=b\n", try read(io, a, shared));
}

test "apply generator: a leaf drifted into a symlink is pruned without dereferencing it" {
    if (!Io.File.Permissions.has_executable_bit) return; // symlink create is privileged on Windows
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // An external file holding private data; the b leaf drifts into a symlink
    // pointing at it.
    const secret = try c.homePath("external.txt");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = secret, .data = "PRIVATE-DATA\n" });
    const leaf_b = try c.homePath(".config/id-b.inc");
    try Io.Dir.cwd().deleteFile(io, leaf_b);
    try Io.Dir.cwd().symLink(io, secret, leaf_b, .{});

    // Drop row b and re-apply with --force so the prune acts on the drifted leaf.
    try writeGenFixture(io, &tmp, &.{"a"});
    _ = try c.run(&.{ "mox", "apply", "--force" });

    // The link's TARGET file is untouched, and its private content never reached
    // a snapshot (the link was snapshotted AS a link, never dereferenced).
    try std.testing.expectEqualStrings("PRIVATE-DATA\n", try read(io, a, secret));
    try std.testing.expect(!(try treeContainsBytes(io, a, c.state, "PRIVATE-DATA")));
}

test "apply generator: mox remove retains the manifest when a leaf is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // Replace leaf b with a directory: pruneStale refuses it (never deletes a
    // directory), so the manifest must be retained, not dropped -- else the
    // refused leaf becomes a permanent un-prunable orphan.
    const leaf_b = try c.homePath(".config/id-b.inc");
    try Io.Dir.cwd().deleteFile(io, leaf_b);
    try Io.Dir.cwd().createDirPath(io, leaf_b);

    const r = try c.run(&.{ "mox", "remove", ".config/gen.inc" });
    try std.testing.expect(r.rc != 0); // a refused leaf -> nonzero exit

    const gen_live = try c.homePath(".config/gen.inc");
    const m = try mox.apply.generated.readManifest(a, io, c.state, gen_live);
    try std.testing.expect(m.len > 0);
}

/// True when some line of `out` contains both `needle_a` and `needle_b` -- used
/// to tie a status label to the path on its own row.
fn lineHasBoth(out: []const u8, needle_a: []const u8, needle_b: []const u8) bool {
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle_a) != null and std.mem.indexOf(u8, line, needle_b) != null) return true;
    }
    return false;
}

test "apply generator: an inline secret in a produced leaf is inlined live but never cached, and a dropped row's snapshot omits the cleartext" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const secret_value = "gen-leaf-s3cr3t-DO-NOT-LEAK-4d3c2b1a";
    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = secret_value });

    const cwd = try std.process.currentPathAlloc(io, a);
    const secret_abs = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "secret.txt" });
    const gen_src = try std.fmt.allocPrint(
        a,
        "# mox: for id in \"data/ids.toml\" into \"id-<id.slug>.inc\"\nemail=<id.slug>\ntoken=<secret:file://{s}>\n# mox: end\n",
        .{secret_abs},
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/.config/gen.inc", .data = gen_src });
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "[[ids]]\nslug = \"a\"\n\n[[ids]]\nslug = \"b\"\n" });

    const c = try cliSetup(a, io, &tmp);

    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    // The secret is inlined into each produced leaf (intended).
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try c.homePath(".config/id-a.inc")), secret_value) != null);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try c.homePath(".config/id-b.inc")), secret_value) != null);
    // But nowhere in mox's own state tree (applied-content cache, provenance).
    try std.testing.expect(!try treeContainsBytes(io, a, c.state, secret_value));

    // Drop row b and re-apply: b's leaf is pruned (snapshot-first). The pre-delete
    // snapshot must redact the token line, so the cleartext never lands in state.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "[[ids]]\nslug = \"a\"\n" });
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(!exists(io, try c.homePath(".config/id-b.inc")));
    // The dropped leaf IS recoverable (its non-secret line reached a snapshot)...
    try std.testing.expect(try treeContainsBytes(io, a, c.state, "email=b"));
    // ...but the secret's cleartext appears nowhere in state, snapshot included.
    try std.testing.expect(!try treeContainsBytes(io, a, c.state, secret_value));
}

test "status generator: reports clean, DRIFT, and MISSING per produced output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // Both produced outputs are clean right after apply, and status reports each
    // one on its own line (rc 0, nothing needs attention).
    const clean = try c.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 0), clean.rc);
    try std.testing.expect(lineHasBoth(clean.out, "clean", "id-a.inc"));
    try std.testing.expect(lineHasBoth(clean.out, "clean", "id-b.inc"));

    // Edit a's leaf (drift) and delete b's leaf (missing); status flags both and
    // exits nonzero.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try c.homePath(".config/id-a.inc"), .data = "hand-edited\n" });
    try Io.Dir.cwd().deleteFile(io, try c.homePath(".config/id-b.inc"));

    const dirty = try c.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 1), dirty.rc);
    try std.testing.expect(lineHasBoth(dirty.out, "DRIFT", "id-a.inc"));
    try std.testing.expect(lineHasBoth(dirty.out, "MISSING", "id-b.inc"));
}

test "export generator: renders every row into the export tree statelessly" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);

    const out_dir = try std.fs.path.join(a, &.{ c.root, "export" });
    // Export WITHOUT a prior apply: it must render both rows from the current
    // data alone -- no manifest, no applied records, no deletion.
    const r = try c.run(&.{ "mox", "export", "--resolved", out_dir });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    try std.testing.expectEqualStrings("key=a\n", try read(io, a, try std.fs.path.join(a, &.{ out_dir, ".config", "id-a.inc" })));
    try std.testing.expectEqualStrings("key=b\n", try read(io, a, try std.fs.path.join(a, &.{ out_dir, ".config", "id-b.inc" })));
    // The generator's own path never lands in the export tree.
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ out_dir, ".config", "gen.inc" })));

    // Stateless: export recorded no manifest and wrote nothing into HOME.
    const gen_live = try c.homePath(".config/gen.inc");
    try std.testing.expectEqual(@as(usize, 0), (try mox.apply.generated.readManifest(a, io, c.state, gen_live)).len);
    try std.testing.expect(!exists(io, try c.homePath(".config/id-a.inc")));
}

test "doctor generator: flags a missing data source and a colliding pair, stays silent on a healthy one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.createDirPath(io, "repo/data");
    // Healthy: present data, distinct rendered paths.
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen_ok.inc",
        .data = "# mox: for id in \"data/ok.toml\" into \"ok-<id.slug>.inc\"\nk=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ok.toml", .data = "[[ok]]\nslug = \"a\"\n\n[[ok]]\nslug = \"b\"\n" });
    // Missing data source.
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen_missing.inc",
        .data = "# mox: for id in \"data/nope.toml\" into \"m-<id.slug>.inc\"\nk=<id.slug>\n# mox: end\n",
    });
    // Two rows collide on one rendered path.
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen_collide.inc",
        .data = "# mox: for id in \"data/coll.toml\" into \"same.inc\"\nk=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/coll.toml", .data = "[[coll]]\nslug = \"a\"\n\n[[coll]]\nslug = \"b\"\n" });

    const c = try cliSetup(a, io, &tmp);
    const r = try c.run(&.{ "mox", "doctor" });
    // Generator findings are advisories, not rc-gating problems.
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    try std.testing.expect(lineHasBoth(r.out, "gen_missing.inc", "data source missing"));
    try std.testing.expect(lineHasBoth(r.out, "gen_collide.inc", "two rows render the same path"));
    // The healthy generator is never mentioned (and, with no git tree, no
    // untracked advisory names it either).
    try std.testing.expect(std.mem.indexOf(u8, r.out, "gen_ok.inc") == null);
}

test "apply generator: a torn manifest line neither crashes apply nor over-deletes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // Corrupt the manifest: keep the two real leaves, then append a blank line
    // and a torn (leading-space, no-newline, bogus) line. readManifest must skip
    // the empties and treat the bogus one as an absent leaf -- not crash, not
    // delete the real ones.
    const gen_live = try c.homePath(".config/gen.inc");
    const leaf_a = try c.homePath(".config/id-a.inc");
    const leaf_b = try c.homePath(".config/id-b.inc");
    const man_hash = mox.apply.applied.contentHashHex(gen_live);
    const man_path = try std.fs.path.join(a, &.{ c.state, "generated", &man_hash });
    const torn = try std.fmt.allocPrint(a, "{s}\n{s}\n\n   /tmp/mox-torn-no-such-\x01\x02", .{ leaf_a, leaf_b });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = man_path, .data = torn });

    // Re-apply the same set: nothing to prune, and the bogus prior line is a
    // no-op, so both real leaves survive and apply exits clean.
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("key=a\n", try read(io, a, leaf_a));
    try std.testing.expectEqualStrings("key=b\n", try read(io, a, leaf_b));
}

test "apply generator: a loop-level when gate off produces nothing and prunes the prior set" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A generator gated by a loop-level `when os=darwin`, plus an unrelated
    // regular managed file that must be untouched throughout.
    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen.inc",
        .data = "# mox: for id in \"data/ids.toml\" when os=darwin into \"id-<id.slug>.inc\"\nkey=<id.slug>\n# mox: end\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/keep.txt", .data = "unrelated\n" });
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "[[ids]]\nslug = \"a\"\n\n[[ids]]\nslug = \"b\"\n" });

    // Run 1 on darwin: the gate passes, both leaves are produced.
    const c_on = try testutil.setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try c_on.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try c_on.homePath(".config/id-a.inc")));
    try std.testing.expect(exists(io, try c_on.homePath(".config/id-b.inc")));

    // Run 2 on linux (same tmp/state): the gate is false -> zero files, and the
    // prior set is pruned (snapshot-first), exactly like an empty source.
    const c_off = try testutil.setup(a, io, &tmp, .{ .os = "linux" });
    try std.testing.expectEqual(@as(u8, 0), (try c_off.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(!exists(io, try c_off.homePath(".config/id-a.inc")));
    try std.testing.expect(!exists(io, try c_off.homePath(".config/id-b.inc")));
    // The pruned leaves are recoverable, and the unrelated file was never swept.
    try std.testing.expect(try snapshotHas(io, a, c_off.state, ".config/id-a.inc", "key=a\n"));
    try std.testing.expectEqualStrings("unrelated\n", try read(io, a, try c_off.homePath("keep.txt")));
}

test "apply generator: a top-level for..into sharing the file with another directive is a loud error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two top-level directives: composeGenerator declines (not a sole for..into),
    // so the normal composer runs and hits the generator loop with `into` set --
    // the IntoOnNonGenerator guard, surfaced loudly rather than silently emitting.
    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen.inc",
        .data = "# mox: for id in \"data/ids.toml\" into \"id-<id.slug>.inc\"\nkey=<id.slug>\n# mox: end\n" ++
            "# mox: when os=linux\nextra\n# mox: end\n",
    });
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/ids.toml", .data = "[[ids]]\nslug = \"a\"\n" });

    const c = try cliSetup(a, io, &tmp);
    const r = try c.run(&.{ "mox", "apply" });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "IntoOnNonGenerator") != null);
    // Nothing was fanned out: the generator's rows never materialized.
    try std.testing.expect(!exists(io, try c.homePath(".config/id-a.inc")));
}

test "apply generator: mox mv re-keys the manifest so the old leaves are pruned, not orphaned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp, &.{ "a", "b" });
    const c = try cliSetup(a, io, &tmp);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try c.homePath(".config/id-a.inc")));

    // Move the generator source into a subdirectory: its leaves now render under
    // the new dir. The old leaves must be pruned (snapshot-first) on the next
    // apply, not left orphaned under the old location.
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "mv", ".config/gen.inc", ".config/sub/gen.inc" })).rc);
    try std.testing.expectEqual(@as(u8, 0), (try c.run(&.{ "mox", "apply" })).rc);

    // New leaves at the moved location.
    try std.testing.expectEqualStrings("key=a\n", try read(io, a, try c.homePath(".config/sub/id-a.inc")));
    try std.testing.expectEqualStrings("key=b\n", try read(io, a, try c.homePath(".config/sub/id-b.inc")));
    // Old leaves pruned, not orphaned, and recoverable.
    try std.testing.expect(!exists(io, try c.homePath(".config/id-a.inc")));
    try std.testing.expect(!exists(io, try c.homePath(".config/id-b.inc")));
    try std.testing.expect(try snapshotHas(io, a, c.state, ".config/id-a.inc", "key=a\n"));
}
