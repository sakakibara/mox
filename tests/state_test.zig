//! What mox persists about what it applied, through the CLI: the lock,
//! recovery, rollback over generations, retention and uninstall.

const std = @import("std");
const builtin = @import("builtin");
const mox = @import("mox");

const Io = std.Io;
const testutil = @import("testutil.zig");
const Harness = testutil.Harness;

fn setup(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !Harness {
    return testutil.setup(a, io, tmp, .{ .create_repo_src = true });
}

fn setupEnv(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, env: []const testutil.EnvPair) !Harness {
    return testutil.setup(a, io, tmp, .{ .create_repo_src = true, .extra_env = env });
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

fn statePath(h: Harness, parts: []const []const u8) ![]const u8 {
    var all: std.ArrayList([]const u8) = .empty;
    try all.append(h.a, h.state);
    try all.appendSlice(h.a, parts);
    return std.fs.path.join(h.a, all.items);
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// A kernel lock on the state's lock file, as another mox would hold it,
/// with a holder line in this version's form.
const HeldLock = struct {
    file: Io.File,
    io: Io,

    fn take(h: Harness, command: []const u8) !HeldLock {
        try Io.Dir.cwd().createDirPath(h.io, h.state);
        const path = try statePath(h, &.{"mox.lock"});
        const f = try Io.Dir.cwd().createFile(h.io, path, .{ .read = true, .truncate = false });
        if (!try f.tryLock(h.io, .exclusive)) return error.LockTaken;
        const line = try std.fmt.allocPrint(h.a, "{d} - 00000000-0000-0000-0000-000000000000 {s}\n", .{ pid(), command });
        try f.writePositionalAll(h.io, line, 0);
        try f.setLength(h.io, line.len);
        return .{ .file = f, .io = h.io };
    }

    fn drop(l: HeldLock) void {
        l.file.unlock(l.io);
        l.file.close(l.io);
    }
};

fn pid() u32 {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

test "lock: another mox's lock refuses a run with its pid and command, and removing the file is not offered" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "x\n");

    const held = try HeldLock.take(h, "holder-test");
    defer held.drop();
    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "lock held by {d} (holder-test); wait\n", .{pid()}), r.err);
    try std.testing.expect(!exists(io, try h.liveOf(".zshrc")));
}

test "lock: the lock file stays after a run, empty" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "x\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("", try read(io, a, try statePath(h, &.{"mox.lock"})));
}

test "lock: private retire takes the lock, its dry run reads without it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "x\n");
    try writeRepo(io, &tmp, "state/private/.p", "p\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const held = try HeldLock.take(h, "holder-test");
    defer held.drop();
    const dry = try h.run(&.{ "mox", "private", "retire", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 0), dry.rc);
    const real = try h.run(&.{ "mox", "private", "retire" });
    try std.testing.expect(real.rc != 0);
    try std.testing.expect(contains(real.err, "lock held by"));
}

test "lock: a daemon a setup script leaves running does not keep the lock" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "x\n");
    try writeRepo(io, &tmp, "repo/scripts/pre/00-daemon.sh", "#!/bin/sh\nsleep 5 >/dev/null 2>&1 &\n");
    const script = try std.fs.path.join(a, &.{ h.repo, "scripts", "pre", "00-daemon.sh" });
    const z = try a.dupeZ(u8, script);
    _ = std.c.chmod(z.ptr, 0o755);
    _ = try h.run(&.{ "mox", "apply" });
    const after = try HeldLock.take(h, "after");
    after.drop();
}

test "state: a generation a newer mox wrote is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "x\n");
    try writeRepo(io, &tmp, "state/v2/current", "20260101T000000Z\n");
    try writeRepo(io, &tmp, "state/v2/gen/20260101T000000Z.json", "{\"v\":3}");
    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expect(contains(r.err, "state written by a newer mox (v3)"));
    try std.testing.expect(!exists(io, try h.liveOf(".zshrc")));
}

/// The id `current` names.
const currentId = testutil.currentId;

test "state: a torn current generation falls back to its parent with a warning, and writes go on; doctor --fix moves it aside" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_CLOCK", .value = "1783671300" }});
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v2\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const torn = try currentId(h);
    try writeRepo(io, &tmp, try std.fmt.allocPrint(a, "state/v2/gen/{s}.json", .{torn}), "{ torn");

    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expect(contains(s.err, try std.fmt.allocPrint(a, "generation {s} cannot be read", .{torn})));
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v3\n");
    const r = try h.run(&.{ "mox", "apply", "--overwrite" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expectEqualStrings("v3\n", try read(io, a, try h.liveOf(".zshrc")));

    try testutil.gitTracked(io, a, h.repo);
    const fix = try h.run(&.{ "mox", "doctor", "--fix" });
    try std.testing.expect(contains(fix.out, "quarantine"));
    try std.testing.expect(!exists(io, try statePath(h, &.{ "v2", "gen", try std.fmt.allocPrint(a, "{s}.json", .{torn}) })));
}

test "state: an exhausted chain reads as empty with a warning, refuses writes, and doctor --fix starts over" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try writeRepo(io, &tmp, "state/v2/current", "not an id\n");

    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expect(contains(s.err, "mox doctor --fix"));
    const w = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 2), w.rc);
    try std.testing.expect(contains(w.err, "mox doctor --fix"));
    try testutil.gitTracked(io, a, h.repo);
    _ = try h.run(&.{ "mox", "doctor", "--fix" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
}

/// A journal a run of `kind` left when it died, made against the current
/// generation, displacing `rel`.
fn deadJournal(h: Harness, kind: mox.state.generation.Kind, rel: []const u8) ![]const u8 {
    const d = try mox.state.draft.testDraft(h.a, h.io, h.state);
    d.base = try read(h.io, h.a, try statePath(h, &.{ "v2", "current" }));
    d.loaded = mox.state.recovery.parseCurrent(d.base).?.id;
    d.run_kind = kind;
    try d.saveWithMode(h.home, try h.liveOf(rel), "displaced\n", 0o644);
    const id = d.run_id.?;
    d.jnl.?.close(h.io);
    return id;
}

test "state: a recovered rollback is not picked as the newest snapshot" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.zshrc", .data = "mine\n" });
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    const ids = try testutil.snapshotIds(h);
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    _ = try deadJournal(h, .rollback, ".zshrc");
    const r = try h.run(&.{ "mox", "rollback" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(contains(r.err, try std.fmt.allocPrint(a, "rolling back the newest snapshot, {s}", .{ids[0]})));
    try std.testing.expectEqualStrings("mine\n", try read(io, a, try h.liveOf(".zshrc")));
}

test "state: doctor --fix on an exhausted chain quarantines a dead journal and reports it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const jid = try deadJournal(h, .apply, ".other");
    const cur = mox.state.recovery.parseCurrent(try read(io, a, try statePath(h, &.{ "v2", "current" }))).?;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try statePath(h, &.{ "v2", "gen", try std.fmt.allocPrint(a, "{s}.json", .{cur.id}) }), .data = "{ torn" });
    const fix = try h.run(&.{ "mox", "doctor", "--fix" });
    const jname = try std.fmt.allocPrint(a, "{s}.jsonl", .{jid});
    try std.testing.expect(contains(fix.out, jname) or contains(fix.err, jname));
    try std.testing.expect(!exists(io, try statePath(h, &.{ "v2", "pending", jname })));
    try std.testing.expect(exists(io, try statePath(h, &.{ "v2", "quarantine", jname })));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
}

test "state: v2/ with generations but no current refuses as an exhausted chain" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().deleteFile(io, try statePath(h, &.{ "v2", "current" }));
    const w = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 2), w.rc);
    try std.testing.expect(contains(w.err, "mox doctor --fix"));
}

test "snapshot: mox snapshot <id> lists every entry, and a refused restore names where its content is" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v2\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const ids = try testutil.snapshotIds(h);
    const listed = try h.run(&.{ "mox", "snapshot", ids[0] });
    try std.testing.expectEqual(@as(u8, 0), listed.rc);
    const blob_path = try statePath(h, &.{ "v2", "blobs", &mox.apply.applied.contentHashHex("v1\n") });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, ".zshrc file {s}\n", .{blob_path}), listed.out);

    // A symlink the user made where the snapshot has a file.
    try Io.Dir.cwd().deleteFile(io, try h.liveOf(".zshrc"));
    try Io.Dir.cwd().symLink(io, "/tmp/elsewhere", try h.liveOf(".zshrc"), .{});
    const rb = try h.run(&.{ "mox", "rollback", ids[0] });
    try std.testing.expectEqual(@as(u8, 1), rb.rc);
    try std.testing.expect(contains(rb.err, try std.fmt.allocPrint(a, "the snapshot copy is at {s}", .{blob_path})));
}

test "snapshot: a missing displaced blob refuses that restore, naming the path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    _ = try h.run(&.{ "mox", "apply" });
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v2\n");
    _ = try h.run(&.{ "mox", "apply" });
    try Io.Dir.cwd().deleteFile(io, try statePath(h, &.{ "v2", "blobs", &mox.apply.applied.contentHashHex("v1\n") }));
    const rb = try h.run(&.{ "mox", "rollback" });
    try std.testing.expectEqual(@as(u8, 1), rb.rc);
    try std.testing.expect(contains(rb.err, "~/.zshrc"));
    try std.testing.expectEqualStrings("v2\n", try read(io, a, try h.liveOf(".zshrc")));
}

test "snapshot: a run that displaced only an empty directory is listed, counted and rolled back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try tmp.dir.createDirPath(io, "home/.config/app");
    try writeRepo(io, &tmp, "repo/src/.config/app", "/tmp/somewhere\n");
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "[\".config/app\"]\nsymlink = true\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    const ids = try testutil.snapshotIds(h);
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    try Io.Dir.cwd().deleteFile(io, try h.liveOf(".config/app"));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "rollback" })).rc);
    const st = try Io.Dir.cwd().statFile(io, try h.liveOf(".config/app"), .{ .follow_symlinks = false });
    try std.testing.expect(st.kind == .directory);
}

test "ids: two removes in one second keep both backups" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_CLOCK", .value = "1783671300" }});
    try writeRepo(io, &tmp, "repo/src/.a", "a\n");
    try writeRepo(io, &tmp, "repo/src/.b", "b\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "remove", ".a" })).rc);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "remove", ".b" })).rc);
    var trash = try Io.Dir.cwd().openDir(io, try statePath(h, &.{"trash"}), .{ .iterate = true });
    defer trash.close(io);
    var n: usize = 0;
    var it = trash.iterate();
    while (try it.next(io)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "retention: under a clock that moved backwards, the new generation is kept" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setupEnv(a, io, &tmp, &.{ .{ .name = "MOX_TEST_CLOCK", .value = "1783671300" }, .{ .name = "MOX_SNAPSHOT_RETENTION", .value = "1" } });
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    _ = try h.run(&.{ "mox", "apply" });
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v2\n");
    _ = try h.run(&.{ "mox", "apply" });
    const later = try a.create(std.process.Environ.Map);
    later.* = try h.env.createMap(a);
    try later.put("MOX_TEST_CLOCK", "1700000000");
    h.env = .{ .map = later };
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v3\n");
    _ = try h.run(&.{ "mox", "apply" });
    const ids = try testutil.snapshotIds(h);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expect(try testutil.snapshotHolds(h, ids[0], ".zshrc", "v2\n"));
}

test "uninstall: records and flags are forgotten, the history is kept, and the records' blobs go" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    try writeRepo(io, &tmp, "home/.zshrc", "old\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    try std.testing.expect(exists(io, try statePath(h, &.{ "v2", "blobs", &mox.apply.applied.contentHashHex("export A=1\n") })));
    const r = try h.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(contains(r.out, "(preserved; delete manually or re-run with --purge-snapshots)"));
    const d = try testutil.dumpOf(h);
    try std.testing.expectEqual(@as(usize, 0), d.paths.len);
    try std.testing.expectEqual(@as(usize, 1), d.generations.len);
    // The cache and provenance blobs of the records went with them.
    try std.testing.expect(!exists(io, try statePath(h, &.{ "v2", "blobs", &mox.apply.applied.contentHashHex("export A=1\n") })));
}

test "doctor: a provenance rebuild of a secret-bearing composition nulls the content cache" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "tok" }});
    try writeRepo(io, &tmp, "repo/src/.envrc", "export A=1\n");
    _ = try h.run(&.{ "mox", "apply" });
    try writeRepo(io, &tmp, "repo/src/.envrc", "export A=1\nexport T=<secret:env:MOX_TEST_TOKEN>\n");
    _ = try h.run(&.{ "mox", "apply" });
    try testutil.gitTracked(io, a, h.repo);
    _ = try h.run(&.{ "mox", "doctor", "--fix", "--rebuild-provenance" });
    try std.testing.expect((try testutil.dumpOf(h)).path(try h.liveOf(".envrc")).?.file.?.cache == null);
}

test "allowlist: no file outside src/state/ names a path of the state store" {
    // A string literal equal to a store name is a path into the store, unless
    // listed here as a use that is not one.
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{ "v2", "gen", "blobs", "pending", "quarantine", "current", "mox.lock" };
    const allowed = [_]struct { []const u8, []const u8, usize }{};
    var src = Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return error.SkipZigTest,
        else => return e,
    };
    defer src.close(io);
    var bad = false;
    var walker = try src.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const rel = try std.mem.replaceOwned(u8, a, entry.path, "\\", "/");
        if (std.mem.startsWith(u8, rel, "state/")) continue;
        const file = try std.fmt.allocPrint(a, "src/{s}", .{rel});
        const text = try entry.dir.readFileAlloc(io, entry.basename, a, .limited(16 * 1024 * 1024));
        for (names) |n| {
            const quoted = try std.fmt.allocPrint(a, "\"{s}\"", .{n});
            const count = std.mem.count(u8, text, quoted);
            var want: usize = 0;
            for (allowed) |al| if (std.mem.eql(u8, al[0], file) and std.mem.eql(u8, al[1], n)) {
                want = al[2];
            };
            if (count != want) {
                std.debug.print("\n{s}: {s} named {d} times, {d} listed\n", .{ file, quoted, count, want });
                bad = true;
            }
        }
    }
    try std.testing.expect(!bad);
}
