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

/// Every file under `dir`, by relative path, with its bytes.
fn treeOf(a: std.mem.Allocator, io: Io, dir: []const u8) !std.StringArrayHashMapUnmanaged([]const u8) {
    var out: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return out;
    defer d.close(io);
    var w = try d.walk(a);
    defer w.deinit();
    while (try w.next(io)) |e| {
        if (e.kind != .file) continue;
        try out.put(a, try a.dupe(u8, e.path), try d.readFileAlloc(io, e.path, a, .limited(1 << 22)));
    }
    return out;
}

test "state: an apply that fails after finding the private layer still records that this part expects one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "state/private/.p", "p\n");
    try writeRepo(io, &tmp, "repo/src/.a", "a\n");
    try tmp.dir.symLink(io, "/nonexistent", "repo/src/.link", .{});
    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(r.rc != 0);
    const d = try testutil.dumpOf(h);
    try std.testing.expect(d.expects_private[0]);
}

/// `h` with its state directory at `state`.
fn withState(h: Harness, state: []const u8) !Harness {
    const m = try h.a.create(std.process.Environ.Map);
    m.* = try h.env.createMap(h.a);
    try m.put("MOX_STATE_DIR", state);
    var out = h;
    out.env = .{ .map = m };
    out.state = state;
    return out;
}

var raced_state: []const u8 = "";

test "ids: a run that trashed but changed no state keeps its id from the next run" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_CLOCK", .value = "1783671300" }});
    try writeRepo(io, &tmp, "repo/src/.a", "a\n");
    try writeRepo(io, &tmp, "repo/src/.b", "b\n");
    // .a was never applied: removing it trashes its source and records
    // nothing.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "remove", ".a" })).rc);
    try std.testing.expect(exists(io, try statePath(h, &.{ "trash", "20260710T081500Z" })));
    try std.testing.expect(!exists(io, try statePath(h, &.{ "v2", "current" })));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(!std.mem.eql(u8, "20260710T081500Z", try currentId(h)));
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "state: an apply that wrote some files and failed others commits what it wrote" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.good", "g\n");
    // A FIFO at a managed live path fails that file.
    try writeRepo(io, &tmp, "repo/src/.bad", "b\n");
    const fifo = try a.dupeZ(u8, try h.liveOf(".bad"));
    _ = mkfifo(fifo.ptr, 0o644);
    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expectEqualStrings("g\n", try read(io, a, try h.liveOf(".good")));
    // Committed, not left to recovery: `current` names a generation that
    // records it, read without folding any journal, and none is pending.
    try std.testing.expect(exists(io, try statePath(h, &.{ "v2", "current" })));
    try std.testing.expect(try testutil.hasRecord(h, try h.liveOf(".good"), .file));
    var pending = try Io.Dir.cwd().openDir(io, try statePath(h, &.{ "v2", "pending" }), .{ .iterate = true });
    defer pending.close(io);
    var it = pending.iterate();
    try std.testing.expect((try it.next(io)) == null);
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

test "state: an apply whose commit finds the state changed exits 2, runs no post script and reports no success" {
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
    const marker = try std.fs.path.join(a, &.{ h.root, "post-ran" });
    const current = try statePath(h, &.{ "v2", "current" });
    try writeRepo(io, &tmp, "repo/scripts/pre/00-move.sh", try std.fmt.allocPrint(a, "#!/bin/sh\nprintf '20000101T000000Z\\n' > '{s}'\n", .{current}));
    try writeRepo(io, &tmp, "repo/scripts/post/00-mark.sh", try std.fmt.allocPrint(a, "#!/bin/sh\ntouch '{s}'\n", .{marker}));
    for ([_][]const u8{ "pre/00-move.sh", "post/00-mark.sh" }) |rel| {
        const z = try a.dupeZ(u8, try std.fs.path.join(a, &.{ h.repo, "scripts", rel }));
        _ = std.c.chmod(z.ptr, 0o755);
    }
    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expect(contains(r.err, "the state changed while this run held its lock"));
    try std.testing.expect(!contains(r.out, "Applied:"));
    try std.testing.expect(!exists(io, marker));
}

var moved_current: []const u8 = "";

test "state: an uninstall whose commit finds the state changed exits 2 and strips nothing" {
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
    const gen = try statePath(h, &.{ "v2", "gen", try std.fmt.allocPrint(a, "{s}.json", .{try currentId(h)}) });
    moved_current = try statePath(h, &.{ "v2", "current" });
    mox.state.recovery.before_commit_point = struct {
        fn move(io_: Io) void {
            mox.state.recovery.before_commit_point = null;
            Io.Dir.cwd().writeFile(io_, .{ .sub_path = moved_current, .data = "20000101T000000Z\n" }) catch unreachable;
        }
    }.move;
    defer mox.state.recovery.before_commit_point = null;
    const r = try h.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expect(contains(r.err, "the state changed while this run held its lock"));
    try std.testing.expect(contains(try read(io, a, gen), ".zshrc"));
}

/// An owned TOML target applied once, its owned record's canonical blob
/// then deleted, beside a plain file.
fn ownedWithoutCanonical(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, h: Harness) ![]const u8 {
    try writeRepo(io, tmp, "repo/src/app.toml", "# mox: own a\n[a]\nk = 1\n");
    try writeRepo(io, tmp, "repo/src/.plain", "p1\n");
    try writeRepo(io, tmp, "home/app.toml", "[a]\nk = 0\n\n[b]\nx = 1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    const store = try mox.state.Store.init(a, h.state);
    const g = (try mox.state.recovery.readGeneration(a, io, store, try currentId(h), null)).?;
    const hex = g.paths.get(try h.liveOf("app.toml")).?.owned.?.canonical_blob.?;
    const blob = try statePath(h, &.{ "v2", "blobs", &hex });
    try Io.Dir.cwd().deleteFile(io, blob);
    return blob;
}

test "state: an owned record whose canonical blob is gone is an error naming it, never a first contact" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    const blob = try ownedWithoutCanonical(a, io, &tmp, h);
    const remedy = "mox apply --overwrite ~/app.toml";

    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 1), s.rc);
    try std.testing.expect(contains(s.out, blob) or contains(s.err, blob));
    try std.testing.expect(contains(s.out, remedy) or contains(s.err, remedy));

    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expect(contains(d.out, blob) or contains(d.err, blob));

    const doc = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(contains(doc.out, blob));

    // apply fails that file only: the other still writes, and the owned
    // target is neither patched nor written whole.
    try writeRepo(io, &tmp, "repo/src/.plain", "p2\n");
    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own a\n[a]\nk = 2\n");
    const before = try read(io, a, try h.liveOf("app.toml"));
    const ap = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 2), ap.rc);
    try std.testing.expect(contains(ap.err, blob));
    try std.testing.expectEqualStrings("p2\n", try read(io, a, try h.liveOf(".plain")));
    try std.testing.expectEqualStrings(before, try read(io, a, try h.liveOf("app.toml")));

    try testutil.gitTracked(io, a, h.repo);
    const c = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(contains(c.out, blob) or contains(c.err, blob));

    // The remedy as printed writes the owned keys again and records them.
    const fixed = try h.run(&.{ "mox", "apply", "--overwrite", try h.liveOf("app.toml") });
    try std.testing.expectEqual(@as(u8, 0), fixed.rc);
    try std.testing.expect(contains(try read(io, a, try h.liveOf("app.toml")), "k = 2"));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "state: rollback re-patches an owned target whose record lost its canonical blob, never restoring it whole" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    _ = try ownedWithoutCanonical(a, io, &tmp, h);
    try writeRepo(io, &tmp, "home/app.toml", "[a]\nk = 1\n\n[b]\nx = 2\n");
    _ = try h.run(&.{ "mox", "rollback" });
    const live = try read(io, a, try h.liveOf("app.toml"));
    try std.testing.expect(contains(live, "x = 2"));
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

test "state: doctor shows a current generation that cannot be read, and --fix makes current name a readable one" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |missing| {
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
        const gen = try statePath(h, &.{ "v2", "gen", try std.fmt.allocPrint(a, "{s}.json", .{torn}) });
        if (missing) try Io.Dir.cwd().deleteFile(io, gen) else try Io.Dir.cwd().writeFile(io, .{ .sub_path = gen, .data = "{ torn" });
        try testutil.gitTracked(io, a, h.repo);

        const report = try h.run(&.{ "mox", "doctor" });
        try std.testing.expectEqual(@as(u8, 1), report.rc);
        try std.testing.expect(contains(report.out, torn));
        _ = try h.run(&.{ "mox", "doctor", "--fix" });
        try std.testing.expect(!std.mem.eql(u8, torn, try currentId(h)));
        const s = try h.run(&.{ "mox", "status" });
        try std.testing.expect(!contains(s.err, "cannot be read"));
        try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor" })).rc);
    }
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

test "snapshot: a refused link restore names the target the link held, not a copy" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try tmp.dir.symLink(io, "/tmp/mox-held-target", "home/.lnk", .{});
    try writeRepo(io, &tmp, "repo/src/.lnk", "/tmp/mox-new-target\n");
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "[\".lnk\"]\nsymlink = true\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    try Io.Dir.cwd().deleteFile(io, try h.liveOf(".lnk"));
    try Io.Dir.cwd().symLink(io, "/tmp/mox-user-target", try h.liveOf(".lnk"), .{});
    const rb = try h.run(&.{ "mox", "rollback" });
    try std.testing.expectEqual(@as(u8, 1), rb.rc);
    try std.testing.expect(contains(rb.err, "the link it held points to /tmp/mox-held-target"));
    try std.testing.expect(!contains(rb.err, "snapshot copy is at /tmp/mox-held-target"));
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
    try std.testing.expect(try testutil.snapshotHolds(h, ids[1], ".zshrc", "v2\n"));
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

const Reach = struct { line: usize, what: []const u8 };

/// Every reference in Zig source `text`, outside comments, to the store
/// type, a draft's `.store` field (spelled `.store`, `. store`, `.@"store"`
/// or `@field(x, "store")`), the store's id directories or its directory
/// name, and every string literal naming a path under `v2/`. `.store(` is
/// an atomic's method and `coupling.store`
/// another module.
fn storeReaches(a: std.mem.Allocator, text: []const u8) ![]const Reach {
    var out: std.ArrayList(Reach) = .empty;
    var i: usize = 0;
    var line: usize = 1;
    var prev_ident: []const u8 = "";
    while (i < text.len) {
        const c = text[i];
        if (c == '\n') {
            line += 1;
            i += 1;
        } else if (std.mem.startsWith(u8, text[i..], "//")) {
            while (i < text.len and text[i] != '\n') i += 1;
        } else if (std.mem.startsWith(u8, text[i..], "\\\\")) {
            const start = i + 2;
            while (i < text.len and text[i] != '\n') i += 1;
            if (namesStorePath(text[start..i])) try out.append(a, .{ .line = line, .what = "a path under the store" });
        } else if (c == '"' or c == '\'') {
            const start = i + 1;
            i += 1;
            while (i < text.len and text[i] != c and text[i] != '\n') : (i += 1) {
                if (text[i] == '\\') i += 1;
            }
            const body = text[start..@min(i, text.len)];
            i += 1;
            if (c == '"' and namesStorePath(body)) try out.append(a, .{ .line = line, .what = "a path under the store" });
            // `.@"store"`, a quoted identifier.
            if (c == '"' and start >= 2 and text[start - 2] == '@' and std.mem.eql(u8, body, "store") and dotBefore(text, start - 2) and !calledAt(text, i))
                try out.append(a, .{ .line = line, .what = ".store" });
        } else if (c == '@' and std.mem.startsWith(u8, text[i..], "@field")) {
            const close = std.mem.indexOfScalarPos(u8, text, i, ')') orelse text.len;
            const args = text[i..close];
            if (std.mem.indexOf(u8, args, "\"store\"") != null) try out.append(a, .{ .line = line, .what = ".store" });
            i += "@field".len;
        } else if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = i;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
            const ident = text[start..i];
            const what: ?[]const u8 = if (std.mem.eql(u8, ident, "Store") or std.mem.eql(u8, ident, "idDirs") or std.mem.eql(u8, ident, "store_dir_name"))
                ident
            else if (dotBefore(text, start) and std.mem.eql(u8, ident, "store") and !calledAt(text, i) and !std.mem.eql(u8, prev_ident, "coupling"))
                ".store"
            else
                null;
            if (what) |w| try out.append(a, .{ .line = line, .what = w });
            prev_ident = ident;
        } else i += 1;
    }
    return out.items;
}

/// A `.` before `at`, spaces between allowed.
fn dotBefore(text: []const u8, at: usize) bool {
    var j = at;
    while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t')) j -= 1;
    return j > 0 and text[j - 1] == '.' and !(j > 1 and text[j - 2] == '.');
}

/// A call's `(` at `at`, spaces before it allowed.
fn calledAt(text: []const u8, at: usize) bool {
    var j = at;
    while (j < text.len and text[j] == ' ') j += 1;
    return j < text.len and text[j] == '(';
}

/// The literal body names a path under `v2/`, either separator.
fn namesStorePath(body: []const u8) bool {
    for ([_][]const u8{ "v2/", "v2\\" }) |n| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, body, from, n)) |at| : (from = at + 1) {
            if (at == 0 or !(std.ascii.isAlphanumeric(body[at - 1]) or body[at - 1] == '_' or body[at - 1] == '-')) return true;
        }
    }
    return false;
}

test "storeReaches: names the store and a draft's store, never a literal, a comment, an atomic's store or the coupling store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\const s = try mox.state.Store.init(a, dir);
        \\x(st.store);
        \\_ = d.store.idDirs();
        \\// a Store in a comment, st.store too, and "v2/gen"
        \\const t = ".DS_Store st.store";
        \\flag.store(true, .release);
        \\try mox.coupling.store.saveGraph(a);
        \\
    ;
    const got = try storeReaches(a, src);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("Store", got[0].what);
    try std.testing.expectEqual(@as(usize, 2), got[1].line);
    try std.testing.expectEqualStrings("idDirs", got[3].what);
}

test "storeReaches: a path under v2/ in a literal, and every other spelling of a draft's store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const forms = [_][]const u8{
        "const p = \"v2/gen\";\n",
        "const p = \"state\\\\v2\\\\blobs\";\n",
        "const p =\n    \\\\v2/current\n;\n",
        "x(@field(st, \"store\"));\n",
        "x(st.@\"store\");\n",
        "x(st. store);\n",
    };
    for (forms) |f| {
        const got = try storeReaches(a, f);
        if (got.len != 1) {
            std.debug.print("not caught once: {s}", .{f});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "const p = \"nav2/x\";\n", "const p = \"v20/x\";\n", "for (xs) |x| x.store(1, .release);\n", "const r = a..store;\n" }) |f| {
        try std.testing.expectEqual(@as(usize, 0), (try storeReaches(a, f)).len);
    }
}

test "allowlist: no file outside src/state/ names a path of the state store or reaches into it" {
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
        // The store, its paths and its directory name are the state API's.
        const reaches = try storeReaches(a, text);
        if (reaches.len > 0) {
            for (reaches) |r| std.debug.print("\n{s}:{d}: reaches into the state store ({s})\n", .{ file, r.line, r.what });
            bad = true;
        }
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

test "uninstall: --purge-snapshots deletes the history of a state with no readable generation" {
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
    const kept = try h.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 2), kept.rc);
    try std.testing.expect(exists(io, try statePath(h, &.{"v2"})));
    const r = try h.run(&.{ "mox", "uninstall", "--purge-snapshots" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(!exists(io, try statePath(h, &.{"v2"})));
}

test "uninstall: a state directory that is a symlink is uninstalled through it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setup(a, io, &tmp);
    try Io.Dir.cwd().createDirPath(io, h.state);
    try tmp.dir.symLink(io, h.state, "statelink", .{ .is_directory = true });
    h = try withState(h, try std.fs.path.join(a, &.{ h.root, "statelink" }));
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect((try testutil.dumpOf(h)).path(try h.liveOf(".zshrc")) != null);
    const r = try h.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(exists(io, try statePath(h, &.{"v2"})));
    try std.testing.expect((try testutil.dumpOf(h)).path(try h.liveOf(".zshrc")) == null);
}

test "state: mv and export run the start checks, refusing a state a newer mox wrote" {
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
    const mv = try h.run(&.{ "mox", "mv", ".zshrc", ".zshrc2" });
    try std.testing.expectEqual(@as(u8, 2), mv.rc);
    try std.testing.expect(contains(mv.err, "state written by a newer mox (v3)"));
    try std.testing.expect(exists(io, try h.srcOf(".zshrc")));
    const out = try std.fs.path.join(a, &.{ h.root, "export-out" });
    const ex = try h.run(&.{ "mox", "export", out });
    try std.testing.expectEqual(@as(u8, 2), ex.rc);
    try std.testing.expect(contains(ex.err, "state written by a newer mox (v3)"));
}

fn generationIds(h: Harness) ![]const []const u8 {
    const inv = try mox.state.retention.inventory(h.a, h.io, try mox.state.Store.init(h.a, h.state));
    var out: std.ArrayList([]const u8) = .empty;
    for (inv.gens) |l| try out.append(h.a, l.id);
    return out.items;
}

fn hasId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |i| if (std.mem.eql(u8, i, id)) return true;
    return false;
}

test "readers: a reader holding its lock across commits keeps the generation and blobs it reads, silently; once it is gone, the next commit collects them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_SNAPSHOT_RETENTION", .value = "1" }});
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v2\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const read_id = try currentId(h);

    // Another mox reading: its readers lock, and the generation it loaded.
    const store = try mox.state.Store.init(a, h.state);
    const held = try mox.state.lock.foreignReader(io, store.readers);
    var released = false;
    defer if (!released) held.release();
    const reader = (try mox.state.open(a, io, .{ .state_dir = h.state, .repo_dir = h.repo, .home = h.home, .writes = false, .locked = false })).ready.draft;
    mox.state.releaseReaders();
    for ([_][]const u8{ "v3\n", "v4\n" }) |v| {
        try writeRepo(io, &tmp, "repo/src/.zshrc", v);
        const r = try h.run(&.{ "mox", "apply" });
        try std.testing.expectEqual(@as(u8, 0), r.rc);
        try std.testing.expect(!contains(r.err, "reader") and !contains(r.err, "warning"));
    }
    try std.testing.expect(hasId(try generationIds(h), read_id));
    try std.testing.expectEqualStrings("v2\n", (try reader.readContent(try h.liveOf(".zshrc"))).?);

    held.release();
    released = true;
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v5\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(!hasId(try generationIds(h), read_id));
    try std.testing.expect((try reader.readContent(try h.liveOf(".zshrc"))) == null);
}

fn chmodPath(a: std.mem.Allocator, path: []const u8, mode: u32) !void {
    const z = try a.dupeZ(u8, path);
    _ = std.c.chmod(z.ptr, @intCast(mode));
}

test "readers: a readers.lock that is only readable, and a state directory where it cannot be created, still let status read" {
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
    const readers = try statePath(h, &.{"readers.lock"});
    try std.testing.expect(exists(io, readers));

    try chmodPath(a, readers, 0o400);
    const ro = try h.run(&.{ "mox", "status" });
    try chmodPath(a, readers, 0o600);
    try std.testing.expectEqual(@as(u8, 0), ro.rc);
    try std.testing.expectEqualStrings("", ro.err);

    try Io.Dir.cwd().deleteFile(io, readers);
    try chmodPath(a, h.state, 0o500);
    const no_file = try h.run(&.{ "mox", "status" });
    try chmodPath(a, h.state, 0o700);
    try std.testing.expectEqual(@as(u8, 0), no_file.rc);
    try std.testing.expectEqualStrings("", no_file.err);
    try std.testing.expect(!exists(io, readers));
}

test "readers: a readers.lock that cannot be opened names its path and what to do, and a commit that cannot take it warns once" {
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
    const readers = try statePath(h, &.{"readers.lock"});

    try chmodPath(a, readers, 0o000);
    const st = try h.run(&.{ "mox", "status" });
    try chmodPath(a, readers, 0o600);
    try std.testing.expectEqual(@as(u8, 2), st.rc);
    try std.testing.expect(contains(st.err, readers));
    try std.testing.expect(contains(st.err, "chmod 600"));
    try std.testing.expect(!contains(st.err, "error: AccessDenied"));

    try Io.Dir.cwd().deleteFile(io, readers);
    try Io.Dir.cwd().createDirPath(io, readers);
    const dir = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 2), dir.rc);
    try std.testing.expect(contains(dir.err, readers));
    try std.testing.expect(contains(dir.err, "a file you own"));
    try Io.Dir.cwd().deleteTree(io, readers);

    mox.state.lock.forced_exclusive_failure = error.SystemResources;
    defer mox.state.lock.forced_exclusive_failure = null;
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v2\n");
    const ap = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), ap.rc);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ap.err, "warning:"));
    try std.testing.expect(contains(ap.err, readers));
    try std.testing.expect(!contains(ap.err, "SystemResources"));
    try std.testing.expect(contains(ap.err, "local filesystem"));
}

var raced_harness: ?Harness = null;
var unlocked_reads: usize = 0;
var locked_reads: usize = 0;

fn noteRead(io: Io, store: mox.state.Store) void {
    if (mox.state.lock.readersHeld(io, store.readers)) locked_reads += 1 else unlocked_reads += 1;
}

test "readers: a store created between a reader's start checks and its load is read only under its lock" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    raced_harness = h;
    defer raced_harness = null;
    defer mox.state.before_reader_load = null;
    defer mox.state.recovery.on_read_current = null;
    // status reads the private expectation first; snapshot opens the state
    // directly.
    for ([_][]const u8{ "status", "snapshot" }) |cmd| {
        Io.Dir.cwd().deleteTree(io, h.state) catch {};
        unlocked_reads = 0;
        locked_reads = 0;
        mox.state.recovery.on_read_current = null;
        mox.state.before_reader_load = struct {
            fn commitFirst(_: Io) void {
                mox.state.before_reader_load = null;
                const r = raced_harness.?.run(&.{ "mox", "apply" }) catch unreachable;
                std.testing.expectEqual(@as(u8, 0), r.rc) catch unreachable;
                mox.state.recovery.on_read_current = noteRead;
            }
        }.commitFirst;
        const r = try h.run(&.{ "mox", cmd });
        try std.testing.expectEqual(@as(u8, 0), r.rc);
        try std.testing.expect(mox.state.before_reader_load == null);
        try std.testing.expect(exists(io, try statePath(h, &.{ "v2", "current" })));
        try std.testing.expectEqual(@as(usize, 0), unlocked_reads);
    }
}

test "readers: every command that reads the state without writing it reads current under the readers lock" {
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
    try testutil.gitTracked(io, a, h.repo);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".zshrc"), .data = "v1\nedited\n" });
    const out = try std.fs.path.join(a, &.{ h.root, "export-out" });

    defer mox.state.recovery.on_read_current = null;
    const runs = [_][]const []const u8{
        &.{ "mox", "status" },
        &.{ "mox", "diff" },
        &.{ "mox", "snapshot" },
        &.{ "mox", "export", out },
        &.{ "mox", "doctor" },
        &.{ "mox", "apply", "--dry-run" },
        &.{ "mox", "commit", "--dry-run" },
        &.{ "mox", "private", "retire", "--dry-run" },
        &.{ "mox", "mv", ".zshrc", ".zshrc2" },
        &.{ "mox", "uninstall" },
    };
    var bad: usize = 0;
    for (runs) |argv| {
        unlocked_reads = 0;
        locked_reads = 0;
        mox.state.recovery.on_read_current = noteRead;
        _ = try h.run(argv);
        mox.state.recovery.on_read_current = null;
        if (unlocked_reads != 0 or locked_reads == 0) {
            std.debug.print("{s} {s}: {d} reads of current under the readers lock, {d} without\n", .{ argv[1], if (argv.len > 2) argv[2] else "", locked_reads, unlocked_reads });
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "readers: doctor says what a commit left for a reader, and stops once a commit deletes it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_SNAPSHOT_RETENTION", .value = "1" }});
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    const clean = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(!contains(clean.out, "left for a reader"));

    const held = try mox.state.lock.foreignReader(io, try statePath(h, &.{"readers.lock"}));
    for ([_][]const u8{ "v2\n", "v3\n", "v4\n" }) |v| {
        try writeRepo(io, &tmp, "repo/src/.zshrc", v);
        try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    }
    held.release();
    const left = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(contains(left.out, "left for a reader"));
    try std.testing.expect(contains(left.out, "(pruning to 1)"));
    const left_rc = left.rc;

    try writeRepo(io, &tmp, "repo/src/.zshrc", "v5\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const after = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(!contains(after.out, "left for a reader"));
    try std.testing.expectEqual(after.rc, left_rc);
}

var waiting_on: ?mox.state.lock.Readers = null;
var waits: usize = 0;

/// The reader the test holds lets go once a step says it waits for it.
fn releaseWaitedOn(_: Io, _: []const u8) void {
    waits += 1;
    if (waiting_on) |r| r.release();
    waiting_on = null;
}

fn blobCount(h: Harness) !usize {
    var d = Io.Dir.cwd().openDir(h.io, try statePath(h, &.{ "v2", "blobs" }), .{ .iterate = true }) catch return 0;
    defer d.close(h.io);
    var n: usize = 0;
    var it = d.iterate();
    while (try it.next(h.io)) |e| if (e.kind == .file and e.name.len == 64) {
        n += 1;
    };
    return n;
}

test "readers: uninstall waits for a running reader, saying so once, then collects the records' blobs" {
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
    try std.testing.expect(try blobCount(h) > 0);

    waits = 0;
    waiting_on = try mox.state.lock.foreignReader(io, try statePath(h, &.{"readers.lock"}));
    defer if (waiting_on) |r| r.release();
    mox.state.lock.before_readers_wait = releaseWaitedOn;
    defer mox.state.lock.before_readers_wait = null;
    const r = try h.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expectEqual(@as(usize, 1), waits);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.err, "waiting for a running mox command that reads the state"));
    try std.testing.expectEqual(@as(usize, 0), try blobCount(h));
}

test "readers: uninstall --purge-snapshots and doctor --fix wait for a running reader before they delete or move" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |purge| {
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
        const gen = try statePath(h, &.{ "v2", "gen", try std.fmt.allocPrint(a, "{s}.json", .{torn}) });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = gen, .data = "{ torn" });
        try testutil.gitTracked(io, a, h.repo);

        waits = 0;
        waiting_on = try mox.state.lock.foreignReader(io, try statePath(h, &.{"readers.lock"}));
        defer if (waiting_on) |r| r.release();
        mox.state.lock.before_readers_wait = releaseWaitedOn;
        defer mox.state.lock.before_readers_wait = null;
        const r = if (purge) try h.run(&.{ "mox", "uninstall", "--purge-snapshots" }) else try h.run(&.{ "mox", "doctor", "--fix" });
        try std.testing.expectEqual(@as(usize, 1), waits);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.err, "waiting for a running mox command that reads the state"));
        if (purge) {
            try std.testing.expectEqual(@as(u8, 0), r.rc);
            try std.testing.expect(!exists(io, try statePath(h, &.{"v2"})));
        } else try std.testing.expect(!exists(io, gen));
    }
}

test "readers: a step that waits for the readers and cannot take their lock names the file and what to do" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const Step = enum { uninstall, purge, doctor_fix, repair };
    for ([_]Step{ .uninstall, .purge, .doctor_fix, .repair }) |step| {
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
        try testutil.gitTracked(io, a, h.repo);
        switch (step) {
            .doctor_fix => try Io.Dir.cwd().writeFile(io, .{ .sub_path = try statePath(h, &.{ "v2", "gen", try std.fmt.allocPrint(a, "{s}.json", .{try currentId(h)}) }), .data = "{ torn" }),
            .repair => try writeRepo(io, &tmp, "state/v2/current", "not an id\n"),
            .uninstall, .purge => {},
        }
        mox.state.lock.forced_exclusive_failure = error.Unexpected;
        defer mox.state.lock.forced_exclusive_failure = null;
        const r = switch (step) {
            .uninstall => try h.run(&.{ "mox", "uninstall" }),
            .purge => try h.run(&.{ "mox", "uninstall", "--purge-snapshots" }),
            .doctor_fix, .repair => try h.run(&.{ "mox", "doctor", "--fix" }),
        };
        if (!contains(r.err, "it must be a file you own") or contains(r.err, "error: Unexpected") or r.rc != 2) {
            std.debug.print("{s}: rc {d}\n{s}\n", .{ @tagName(step), r.rc, r.err });
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(contains(r.err, try statePath(h, &.{"readers.lock"})));
    }
}

test "readers: the readers lock is in the state directory, next to mox.lock, outside v2/" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    const store = try mox.state.Store.init(a, h.state);
    try std.testing.expectEqualStrings(try statePath(h, &.{"readers.lock"}), store.readers);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, store.readers));
    try std.testing.expect(!exists(io, try statePath(h, &.{ "v2", "readers.lock" })));
}

/// A reader that opens the lock file while a step waits for the one before
/// it; it locks it once the step is done.
var latecomer: ?Io.File = null;
var latecomer_path: []const u8 = "";

fn releaseAndOpen(io: Io, _: []const u8) void {
    releaseWaitedOn(io, "");
    latecomer = Io.Dir.cwd().openFile(io, latecomer_path, .{}) catch null;
}

/// The latecomer's file is still the one at the lock's path, and its shared
/// lock, which it keeps, is seen there.
fn expectLatecomerHolds(h: Harness) !void {
    const f = latecomer orelse return error.NoLatecomer;
    try std.testing.expect(exists(h.io, latecomer_path));
    const at_path = try Io.Dir.cwd().statFile(h.io, latecomer_path, .{});
    try std.testing.expectEqual(at_path.inode, (try f.stat(h.io)).inode);
    try f.lock(h.io, .shared);
    try std.testing.expect(mox.state.lock.readersHeld(h.io, latecomer_path));
}

/// The latecomer lets go once a step says it waits for it.
fn releaseLatecomer(io: Io, _: []const u8) void {
    waits += 1;
    if (latecomer) |f| {
        f.unlock(io);
        f.close(io);
    }
    latecomer = null;
}

test "readers: after the purge, a reader that opened the lock while the step waited holds it, and the next step waits for it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const h = try setup(a, io, &tmp);
        try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
        try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
        latecomer_path = try statePath(h, &.{"readers.lock"});
        waits = 0;
        waiting_on = try mox.state.lock.foreignReader(io, latecomer_path);
        defer if (waiting_on) |r| r.release();
        mox.state.lock.before_readers_wait = releaseAndOpen;
        defer mox.state.lock.before_readers_wait = null;
        const r = try h.run(&.{ "mox", "uninstall", "--purge-snapshots" });
        try std.testing.expectEqual(@as(usize, 1), waits);
        try std.testing.expectEqual(@as(u8, 0), r.rc);
        try std.testing.expect(!exists(io, try statePath(h, &.{"v2"})));
        try expectLatecomerHolds(h);
        defer if (latecomer) |f| {
            f.unlock(io);
            f.close(io);
            latecomer = null;
        };
        // The purge took the store; an apply makes one again, its cleanup
        // skipped for the latecomer.
        try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
        waits = 0;
        mox.state.lock.before_readers_wait = releaseLatecomer;
        const next = try h.run(&.{ "mox", "uninstall", "--purge-snapshots" });
        try std.testing.expectEqual(@as(usize, 1), waits);
        try std.testing.expectEqual(@as(u8, 0), next.rc);
        try std.testing.expect(!exists(io, try statePath(h, &.{"v2"})));
    }
}

fn trashIds(h: Harness) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = Io.Dir.cwd().openDir(h.io, try statePath(h, &.{"trash"}), .{ .iterate = true }) catch return out.items;
    defer d.close(h.io);
    var it = d.iterate();
    while (try it.next(h.io)) |e| try out.append(h.a, try h.a.dupe(u8, e.name));
    return out.items;
}

fn withClock(h: *Harness, secs: []const u8) !void {
    const m = try h.a.create(std.process.Environ.Map);
    m.* = try h.env.createMap(h.a);
    try m.put("MOX_TEST_CLOCK", secs);
    h.env = .{ .map = m };
}

test "ids: under a clock that moved backwards, a run's generation and trash still sort after every id there is" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_CLOCK", .value = "1783671300" }});
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try writeRepo(io, &tmp, "repo/src/.other", "o\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const first = try currentId(h);
    try withClock(&h, "1700000000");
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v2\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const second = try currentId(h);
    try std.testing.expect(mox.state.id.older({}, first, second));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "remove", ".other" })).rc);
    const removed = try currentId(h);
    try std.testing.expect(mox.state.id.older({}, second, removed));
    for (try trashIds(h)) |t| try std.testing.expect(mox.state.id.older({}, second, t));
}

test "ids: mv's trash sorts after the id current names, though that generation's file is gone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_CLOCK", .value = "1783671300" }});
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try withClock(&h, "1783671400");
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v2\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const named = try currentId(h);
    try Io.Dir.cwd().deleteFile(io, try statePath(h, &.{ "v2", "gen", try std.fmt.allocPrint(a, "{s}.json", .{named}) }));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "mv", ".zshrc", ".zshrc2" })).rc);
    const trash = try trashIds(h);
    try std.testing.expectEqual(@as(usize, 1), trash.len);
    try std.testing.expect(mox.state.id.older({}, named, trash[0]));
}

const editCurrent = testutil.editCurrent;

test "state: an owned record naming no canonical blob says so, doctor lists it, and --overwrite says it wrote it again" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own a\n[a]\nk = 1\n");
    try writeRepo(io, &tmp, "home/app.toml", "[a]\nk = 0\n\n[b]\nx = 1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    const live = try h.liveOf("app.toml");
    try editCurrent(h, struct {
        fn unrecord(_: std.mem.Allocator, g: *mox.state.generation.Generation, p: []const u8) !void {
            g.paths.getPtr(p).?.owned.?.canonical_blob = null;
        }
    }.unrecord, live);

    const s = try h.run(&.{ "mox", "status" });
    const said = try std.mem.concat(a, u8, &.{ s.out, s.err });
    try std.testing.expect(contains(said, "no canonical blob recorded"));
    try std.testing.expect(!contains(said, try std.fmt.allocPrint(a, "{s},", .{try statePath(h, &.{ "v2", "blobs" })})));

    const doc = try h.run(&.{ "mox", "doctor" });
    try std.testing.expect(contains(doc.out, "missing-canonical ~/app.toml"));

    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own a\n[a]\nk = 2\n");
    const fixed = try h.run(&.{ "mox", "apply", "--overwrite" });
    try std.testing.expectEqual(@as(u8, 0), fixed.rc);
    try std.testing.expect(contains(fixed.out, "canonical text (no canonical blob recorded) was missing; writing the owned keys"));
    try std.testing.expect(contains(try read(io, a, live), "k = 2"));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "diff: a secret line the last apply wrote is masked wherever it moved, and the lines around it are shown" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "tok-4c1d" }});
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\ntoken=<secret:env:MOX_TEST_TOKEN>\nz\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\nz\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "n1\nn2\nn3\na\ntoken=tok-4c1d\nz\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "tok-4c1d"));
    try std.testing.expect(contains(d.out, "-n1\n-n2\n-n3\n"));
    try std.testing.expect(contains(d.out, mox.provenance.map.secret_redaction));

    if (builtin.os.tag != .windows) {
        const key = try statePath(h, &.{ "v2", "secret-lines.key" });
        const st = try Io.Dir.cwd().statFile(io, key, .{});
        try std.testing.expectEqual(@as(u64, 32), st.size);
        try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
}

test "diff: a live file whose secret mask is gone is not shown, and no resolved secret reaches stdout" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "tok-4c1d" }});
    const filler = "export A=1\n# 1\n# 2\n# 3\n# 4\n# 5\n# 6\n# 7\n# 8\n";
    try writeRepo(io, &tmp, "repo/src/.envrc", filler ++ "export T=<secret:env:MOX_TEST_TOKEN>\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    // The secret line moves to the top: the live side's copy of it is a
    // hunk of its own, far from the composed one.
    try writeRepo(io, &tmp, "repo/src/.envrc", "export T=<secret:env:MOX_TEST_TOKEN>\n" ++ filler);
    const masked = try h.run(&.{ "mox", "diff" });
    try std.testing.expect(!contains(masked.out, "tok-4c1d"));
    try std.testing.expect(contains(masked.out, "@@"));

    const live = try h.liveOf(".envrc");
    const store = try mox.state.Store.init(a, h.state);
    const g = (try mox.state.recovery.readGeneration(a, io, store, try currentId(h), null)).?;
    try Io.Dir.cwd().deleteFile(io, try statePath(h, &.{ "v2", "blobs", &g.paths.get(live).?.file.?.provenance_blob.? }));
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expect(!contains(d.out, "tok-4c1d"));
    try std.testing.expect(contains(d.err, "not shown"));
    // A source that no longer resolves it: the record says it was written
    // with one.
    try writeRepo(io, &tmp, "repo/src/.envrc", filler);
    const gone = try h.run(&.{ "mox", "diff" });
    try std.testing.expect(!contains(gone.out, "tok-4c1d"));
    try std.testing.expect(contains(gone.err, "not shown"));
}

test "diff: a live line holding a secret value is masked wherever it sits, edited or not" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "tok-4c1d-SECRET" }});
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\ntoken=<secret:env:MOX_TEST_TOKEN>\nz\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "export TOKEN=tok-4c1d-SECRET\nq1\nq2\nq3\nq4\nq5\nq6\nq7\nq8\na\ntoken=tok-4c1d-SECRET # rotate soon\nz\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "4c1d"));
    try std.testing.expect(contains(d.out, mox.provenance.map.secret_redaction));
}

test "diff: a secret value the source no longer resolves is masked by what the last apply recorded" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "tok-4c1d-SECRET" }});
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\ntoken=<secret:env:MOX_TEST_TOKEN>\nz\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\nz\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "a\ntoken=tok-4c1d-SECRET  # edited\nz\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "4c1d"));
    try std.testing.expect(contains(d.out, mox.provenance.map.secret_redaction));

    // A file whose source left the tree shows its pending removal masked.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "a\ntoken=tok-4c1d-SECRET\nz\n" });
    try Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ h.repo, "src", ".cfg" }));
    const stale = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), stale.rc);
    try std.testing.expect(!contains(stale.out, "4c1d"));
    try std.testing.expect(contains(stale.out, "@@ -1,3 +1,0 @@"));
}

test "diff: each line of a multi-line secret value is masked, an edited one included, and a value shorter than a window is matched whole" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{
        .{ .name = "MOX_TEST_MULTI", .value = "first-AAAA\nsecond-BBBB\nthird-CCCC" },
        .{ .name = "MOX_TEST_SHORT", .value = "qz7k1" },
    });
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\nkey=<secret:env:MOX_TEST_MULTI>\npin=<secret:env:MOX_TEST_SHORT>\nz\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\nz\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "a\nkey=first-AAAA\nsecond-BBBB-edited\nthird-CCCC\nm1\nm2\nm3\nm4\nm5\nm6\nm7\nm8\nold pin: qz7k1.\nz\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "AAAA"));
    try std.testing.expect(!contains(d.out, "BBBB"));
    try std.testing.expect(!contains(d.out, "CCCC"));
    try std.testing.expect(!contains(d.out, "qz7k1"));
    try std.testing.expect(contains(d.out, "@@"));
}

test "diff: a record whose provenance records no secret values is shown masked while its source still resolves the secret; once the source changes it is not shown, and the remedy it names works on an edited file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "tok-4c1d-SECRET" }});
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\ntoken=<secret:env:MOX_TEST_TOKEN>\nz\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    raced_state = h.state;
    // As a damaged store holds it: the provenance names the secret line but
    // records no values.
    try editCurrent(h, struct {
        fn unrecorded(arena_: std.mem.Allocator, g: *mox.state.generation.Generation, p: []const u8) !void {
            const segments = [_]mox.provenance.map.Segment{
                .{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } },
                .{ .out_start = 1, .out_len = 1, .origin = .secret },
                .{ .out_start = 2, .out_len = 1, .origin = .{ .base = .{ .line = 3 } } },
            };
            const bytes = try mox.provenance.map.serialize(arena_, p, &segments, null);
            const store = try mox.state.Store.init(arena_, raced_state);
            g.paths.getPtr(p).?.file.?.provenance_blob = try mox.state.blob.put(arena_, std.testing.io, store.blobs, bytes);
        }
    }.unrecorded, try h.liveOf(".cfg"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "export TOKEN=tok-4c1d-SECRET\nq1\nq2\nq3\nq4\nq5\nq6\nq7\nq8\na\ntoken=tok-4c1d-SECRET\nz\n" });
    const shown = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), shown.rc);
    try std.testing.expect(!contains(shown.err, "not shown"));
    try std.testing.expect(!contains(shown.out, "4c1d"));
    try std.testing.expect(contains(shown.out, "@@"));

    try writeRepo(io, &tmp, "repo/src/.cfg", "a\nz\n");
    const refused = try h.run(&.{ "mox", "diff" });
    try std.testing.expect(!contains(refused.out, "4c1d"));
    try std.testing.expect(contains(refused.err, "not shown"));
    try std.testing.expect(contains(refused.err, "mox apply --overwrite"));

    const fixed = try h.run(&.{ "mox", "apply", "--overwrite", try h.liveOf(".cfg") });
    try std.testing.expectEqual(@as(u8, 0), fixed.rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "a\nedited\nz\n" });
    const after = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), after.rc);
    try std.testing.expect(!contains(after.err, "not shown"));
    try std.testing.expect(contains(after.out, "-edited\n"));
}

test "diff: a secret-line key that cannot be read fails diff and apply naming it, leaves the commands that do not read it working, and no command makes a new one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "tok-4c1d-SECRET" }});
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\ntoken=<secret:env:MOX_TEST_TOKEN>\nz\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const key = try statePath(h, &.{ "v2", "secret-lines.key" });
    const before = try read(io, a, key);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "a\ntoken=tok-4c1d-SECRET # x\nz\n" });
    const status_before = try h.run(&.{ "mox", "status" });
    try chmodPath(a, key, 0);
    defer chmodPath(a, key, 0o600) catch {};
    const status = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(status_before.rc, status.rc);
    try std.testing.expectEqualStrings(status_before.out, status.out);
    try std.testing.expect(!contains(status.err, key));
    const snaps = try h.run(&.{ "mox", "snapshot" });
    try std.testing.expectEqual(@as(u8, 0), snaps.rc);
    try std.testing.expect(!contains(snaps.err, key));
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expect(d.rc != 0);
    try std.testing.expect(!contains(d.out, "4c1d"));
    try std.testing.expect(contains(d.err, key));
    const ap = try h.run(&.{ "mox", "apply", "--overwrite" });
    try std.testing.expect(ap.rc != 0);
    try std.testing.expect(contains(ap.err, key));
    try chmodPath(a, key, 0o600);
    try std.testing.expectEqualStrings(before, try read(io, a, key));
}

test "uninstall: a state directory holding nothing mox made is refused, and nothing in it is followed, created or removed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "homelike/Documents/thesis.txt", "precious\n");
    try writeRepo(io, &tmp, "homelike/.bashrc", "alias l=ls\n");
    const target = try std.fs.path.join(a, &.{ h.root, "homelike" });
    try tmp.dir.symLink(io, target, "statelink", .{ .is_directory = true });
    h = try withState(h, try std.fs.path.join(a, &.{ h.root, "statelink" }));
    const before = try treeOf(a, io, target);
    const r = try h.run(&.{ "mox", "uninstall", "--purge-snapshots", "--purge-trash", "--purge-private" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expect(contains(r.err, "nothing mox made"));
    const after = try treeOf(a, io, target);
    try std.testing.expectEqual(before.count(), after.count());
    for (before.keys(), before.values()) |k, v| try std.testing.expectEqualStrings(v, after.get(k).?);
}

test "uninstall: with MOX_STATE_DIR=. in a home directory, it removes only what mox made there" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setup(a, io, &tmp);
    h = try withState(h, ".");
    try writeRepo(io, &tmp, "home/Documents/thesis.txt", "precious\n");
    try writeRepo(io, &tmp, "home/.bashrc", "alias l=ls\n");
    const docs = try std.fs.path.join(a, &.{ h.home, "Documents", "thesis.txt" });
    const bashrc = try std.fs.path.join(a, &.{ h.home, ".bashrc" });
    const first = try h.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 2), first.rc);
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.home, "mox.lock" })));

    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ h.home, "v2" })));
    const r = try h.run(&.{ "mox", "uninstall", "--purge-snapshots" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expectEqualStrings("precious\n", try read(io, a, docs));
    try std.testing.expectEqualStrings("alias l=ls\n", try read(io, a, bashrc));
    try std.testing.expectEqualStrings("v1\n", try read(io, a, try h.liveOf(".zshrc")));
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.home, "v2" })));
    try std.testing.expect(contains(r.out, "kept ~/Documents (not made by mox)"));
    try std.testing.expect(contains(r.out, "kept ~/.bashrc (not made by mox)"));
}

test "uninstall: an entry of the state directory mox did not make is kept and listed, and a link in it is not followed" {
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
    try writeRepo(io, &tmp, "state/notes.txt", "mine\n");
    try writeRepo(io, &tmp, "outside/precious", "keep\n");
    try tmp.dir.symLink(io, try std.fs.path.join(a, &.{ h.root, "outside" }), "state/elsewhere", .{ .is_directory = true });
    try writeRepo(io, &tmp, "state/coupling/graph.json", "{}\n");
    const r = try h.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expectEqualStrings("mine\n", try read(io, a, try statePath(h, &.{"notes.txt"})));
    try std.testing.expectEqualStrings("keep\n", try read(io, a, try std.fs.path.join(a, &.{ h.root, "outside", "precious" })));
    try std.testing.expect(exists(io, try statePath(h, &.{"elsewhere"})));
    try std.testing.expect(contains(r.out, "notes.txt (not made by mox)"));
    try std.testing.expect(contains(r.out, "elsewhere (not made by mox)"));
    try std.testing.expect(!exists(io, try statePath(h, &.{"coupling"})));
}

test "uninstall: a bin/, tmp/ or trash/ holding what mox did not make is kept and listed, and mox's own are removed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setup(a, io, &tmp);

    // A home directory named as the state directory, with a lock file a
    // run left in it.
    try writeRepo(io, &tmp, "homelike/mox.lock", "");
    try writeRepo(io, &tmp, "homelike/bin/user-script", "#!/bin/sh\n");
    try writeRepo(io, &tmp, "homelike/tmp/notes", "mine\n");
    try writeRepo(io, &tmp, "homelike/trash/old-photos/a.jpg", "jpg\n");
    const home_like = try std.fs.path.join(a, &.{ h.root, "homelike" });
    const foreign = try withState(h, home_like);
    const r = try foreign.run(&.{ "mox", "uninstall", "--purge-trash" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expectEqualStrings("#!/bin/sh\n", try read(io, a, try statePath(foreign, &.{ "bin", "user-script" })));
    try std.testing.expectEqualStrings("mine\n", try read(io, a, try statePath(foreign, &.{ "tmp", "notes" })));
    try std.testing.expectEqualStrings("jpg\n", try read(io, a, try statePath(foreign, &.{ "trash", "old-photos", "a.jpg" })));
    try std.testing.expect(contains(r.out, try std.fmt.allocPrint(a, "kept {s} (holds user-script, which mox did not make)", .{try statePath(foreign, &.{"bin"})})));
    try std.testing.expect(contains(r.out, try std.fmt.allocPrint(a, "kept {s} (holds notes, which mox did not make)", .{try statePath(foreign, &.{"tmp"})})));
    try std.testing.expect(contains(r.out, try std.fmt.allocPrint(a, "kept {s} (holds old-photos, which mox did not make)", .{try statePath(foreign, &.{"trash"})})));

    // Without the lock file, a bin/ and tmp/ of the user's are not mox's.
    try Io.Dir.cwd().deleteFile(io, try statePath(foreign, &.{"mox.lock"}));
    for ([_][]const u8{ "readers.lock", "readers.gate" }) |n| Io.Dir.cwd().deleteFile(io, try statePath(foreign, &.{n})) catch {};
    const refused = try foreign.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 2), refused.rc);
    try std.testing.expect(contains(refused.err, "nothing mox made"));

    // A real state: the scripts' bin/ apply made, the package managers'
    // scratch files and a trash generation are mox's, and go.
    h = try withState(h, try std.fs.path.join(a, &.{ h.root, "state" }));
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    try writeRepo(io, &tmp, "repo/scripts/pre/00-noop.sh", "#!/bin/sh\nexit 0\n");
    try chmodPath(a, try std.fs.path.join(a, &.{ h.repo, "scripts", "pre", "00-noop.sh" }), 0o755);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try statePath(h, &.{ "bin", "mox" })));
    try writeRepo(io, &tmp, "state/tmp/stdin-99999.txt", "in\n");
    try writeRepo(io, &tmp, "state/tmp/brew-installer-99999.sh", "#!/bin/sh\n");
    try writeRepo(io, &tmp, "state/trash/20260101T000000Z-2/src/.old", "old\n");
    const ok = try h.run(&.{ "mox", "uninstall", "--purge-trash" });
    try std.testing.expectEqual(@as(u8, 0), ok.rc);
    for ([_][]const u8{ "bin", "tmp", "trash" }) |n| try std.testing.expect(!exists(io, try statePath(h, &.{n})));
}

/// Readers that overlap one another, each its own holder as a separate mox
/// would be: a new one every 100 ms holds the readers lock shared for
/// 400 ms, taking it through the gate as mox's readers do, until `stop`.
const Relay = struct {
    io: Io,
    readers: []const u8,
    gate: []const u8,
    stop: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(usize) = .init(0),

    fn openLock(io: Io, path: []const u8) !Io.File {
        return Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    }

    fn one(r: *Relay) void {
        const gate = openLock(r.io, r.gate) catch return;
        defer gate.close(r.io);
        gate.lock(r.io, .shared) catch return;
        const f = openLock(r.io, r.readers) catch return;
        defer f.close(r.io);
        f.lock(r.io, .shared) catch return;
        gate.unlock(r.io);
        _ = r.started.fetchAdd(1, .seq_cst);
        r.io.sleep(.fromMilliseconds(400), .awake) catch {};
        f.unlock(r.io);
    }

    fn run(r: *Relay) void {
        var threads: [400]?std.Thread = @splat(null);
        for (&threads) |*t| {
            if (r.stop.load(.seq_cst)) break;
            t.* = std.Thread.spawn(.{}, one, .{r}) catch null;
            r.io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
        for (threads) |t| if (t) |th| th.join();
    }
};

test "readers: a relay of overlapping readers does not keep uninstall waiting" {
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

    var relay: Relay = .{ .io = io, .readers = try statePath(h, &.{"readers.lock"}), .gate = try statePath(h, &.{"readers.gate"}) };
    const spawner = try std.Thread.spawn(.{}, Relay.run, .{&relay});
    defer spawner.join();
    defer relay.stop.store(true, .seq_cst);
    while (relay.started.load(.seq_cst) < 2) try io.sleep(.fromMilliseconds(20), .awake);

    const t0 = Io.Clock.awake.now(io);
    const r = try h.run(&.{ "mox", "uninstall" });
    const took = t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    relay.stop.store(true, .seq_cst);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(contains(r.err, "waiting for a running mox command that reads the state"));
    // The relay runs for 40 s; uninstall waits only for the readers that
    // held the lock when it asked.
    try std.testing.expect(took < 10_000);
}

test "readers: recovery that writes waits for a running reader before it folds, deletes or moves a journal" {
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
    const jid = try deadJournal(h, .apply, ".zshrc");

    waits = 0;
    waiting_on = try mox.state.lock.foreignReader(io, try statePath(h, &.{"readers.lock"}));
    defer if (waiting_on) |r| r.release();
    mox.state.lock.before_readers_wait = releaseWaitedOn;
    defer mox.state.lock.before_readers_wait = null;
    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expectEqual(@as(usize, 1), waits);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.err, "waiting for a running mox command that reads the state"));
    try std.testing.expect(!exists(io, try statePath(h, &.{ "v2", "pending", try std.fmt.allocPrint(a, "{s}.jsonl", .{jid}) })));
}

test "uninstall: a readers lock it cannot take exclusive stops it before it removes or forgets anything" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |purge| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const h = try setup(a, io, &tmp);
        try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
        try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
        try writeRepo(io, &tmp, "state/coupling/graph.json", "{}\n");
        mox.state.lock.forced_exclusive_failure = error.Unexpected;
        defer mox.state.lock.forced_exclusive_failure = null;
        const r = if (purge) try h.run(&.{ "mox", "uninstall", "--purge-snapshots" }) else try h.run(&.{ "mox", "uninstall" });
        try std.testing.expectEqual(@as(u8, 2), r.rc);
        try std.testing.expect(contains(r.err, try statePath(h, &.{"readers.lock"})));
        mox.state.lock.forced_exclusive_failure = null;
        try std.testing.expect(exists(io, try statePath(h, &.{ "coupling", "graph.json" })));
        try std.testing.expect(exists(io, try statePath(h, &.{"v2"})));
        try std.testing.expect((try testutil.dumpOf(h)).path(try h.liveOf(".zshrc")) != null);
    }
}

test "paths: a relative MOX_STATE_DIR resolves as the kernel does, through a symlink before `..`" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setup(a, io, &tmp);
    const real = try std.fs.path.join(a, &.{ h.root, "other", "st" });
    const cwd = try std.fs.path.join(a, &.{ h.root, "cwd" });
    try tmp.dir.createDirPath(io, "other/deep");
    try tmp.dir.createDirPath(io, "cwd");
    try tmp.dir.symLink(io, try std.fs.path.join(a, &.{ h.root, "other", "deep" }), "cwd/lnk", .{ .is_directory = true });
    h = try withState(h, real);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");

    const rel = try withState(h, "lnk/../st");
    try std.testing.expectEqual(@as(u8, 0), (try rel.runIn(cwd, &.{ "mox", "apply" })).rc);
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ real, "v2", "current" })));
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ cwd, "st" })));
}

test "readers: doctor shows nothing left for a reader when no reader kept a commit from cleaning up" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    for ([_][]const u8{ "v1\nx\n", "v2\nx\n", "v3\nx\n", "v4\nx\n", "v5\nx\n" }) |v| {
        try writeRepo(io, &tmp, "repo/src/.f", v);
        try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    }
    // Doctor run under a retention the commits did not prune to finds no
    // cleanup a reader kept from running.
    const m = try h.a.create(std.process.Environ.Map);
    m.* = try h.env.createMap(h.a);
    try m.put("MOX_SNAPSHOT_RETENTION", "1");
    var one = h;
    one.env = .{ .map = m };
    for ([_]Harness{ h, one }) |hh| {
        const d = try hh.run(&.{ "mox", "doctor" });
        try std.testing.expect(!contains(d.out, "left for a reader"));
    }
}
