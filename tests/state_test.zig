//! What mox persists about what it applied, through the CLI: the lock,
//! recovery, rollback over generations, retention and uninstall.

const std = @import("std");
const builtin = @import("builtin");
const mox = @import("mox");

const Io = std.Io;
const testutil = @import("testutil.zig");
const Harness = testutil.Harness;
const tilde = testutil.tilde;

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
        try testutil.markState(h);
        const path = try statePath(h, &.{"mox.lock"});
        const f = try Io.Dir.cwd().createFile(h.io, path, .{ .read = true, .truncate = false });
        if (!try mox.state.lock.lockAsHolder(h.io, f)) return error.LockTaken;
        const line = try std.fmt.allocPrint(h.a, "{d} - 00000000-0000-0000-0000-000000000000 {s}\n", .{ pid(), command });
        try f.writePositionalAll(h.io, line, 0);
        try f.setLength(h.io, line.len);
        return .{ .file = f, .io = h.io };
    }

    fn drop(l: HeldLock) void {
        mox.state.lock.unlockAsHolder(l.io, l.file);
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

test "state directory: one spelled ending in `.` or `..` is the directory it names" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    for ([_][]const u8{ "/.", "/private/.." }) |suffix| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const real = try setup(a, io, &tmp);
        try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=2\n");
        try Io.Dir.cwd().createDirPath(io, try statePath(real, &.{"private"}));
        const h = try withState(real, try std.mem.concat(a, u8, &.{ real.state, suffix }));
        try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
        try std.testing.expect(exists(io, try statePath(real, &.{ "v2", "current" })));
        try std.testing.expect(exists(io, try statePath(real, &.{".mox-state"})));
    }
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
    try testutil.markState(h);
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
    const remedy = try tilde(a, "mox apply --overwrite ~/app.toml");

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
    try std.testing.expect(contains(rb.err, try tilde(a, "~/.zshrc")));
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
    try testutil.markState(h);
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
    const reader = (try mox.state.open(a, io, .{ .state_dir = h.state, .origin = .explicit, .repo_dir = h.repo, .home = h.home, .writes = false, .locked = false })).ready.draft;
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
    try std.testing.expect(contains(doc.out, try std.fmt.allocPrint(a, "missing-canonical {s}", .{try tilde(a, "~/app.toml")})));

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
    try std.testing.expect(contains(d.out, "-token=" ++ mox.provenance.map.secret_redaction ++ "\n"));
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

/// True when a file under the state directory, or the name of one, holds
/// `needle`.
fn stateHolds(h: Harness, needle: []const u8) !bool {
    var dir = try Io.Dir.cwd().openDir(h.io, h.state, .{ .iterate = true });
    defer dir.close(h.io);
    var walker = try dir.walk(h.a);
    defer walker.deinit();
    while (try walker.next(h.io)) |entry| {
        if (contains(entry.path, needle)) return true;
        if (entry.kind != .file) continue;
        const content = try dir.readFileAlloc(h.io, entry.path, h.a, .limited(256 << 20));
        if (contains(content, needle)) return true;
    }
    return false;
}

const redacted_secret = mox.provenance.map.secret_redaction;
const redacted_line = mox.provenance.map.line_redaction;

test "diff: a three-byte secret the source no longer resolves is masked by the shape of its line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_PIN", .value = "k9z" }});
    try writeRepo(io, &tmp, "repo/src/rc.txt", "a=1\npin=<secret:env:MOX_TEST_PIN>\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try writeRepo(io, &tmp, "repo/src/rc.txt", "a=1\npin=none\n");
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "k9z"));
    try std.testing.expect(contains(d.out, "-pin=" ++ redacted_secret ++ "\n"));
    try std.testing.expect(contains(d.out, "+pin=none\n"));
}

test "diff: a secret written JSON-escaped, quote and all, is masked once the source stops resolving it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_PW", .value = "ab\"cdefg" }});
    try writeRepo(io, &tmp, "repo/src/cfg.json", "{\"pw\": \"<secret:env:MOX_TEST_PW>\"}\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("{\"pw\": \"ab\\\"cdefg\"}\n", try read(io, a, try h.liveOf("cfg.json")));
    try writeRepo(io, &tmp, "repo/src/cfg.json", "{\"pw\": \"literal\"}\n");
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "cdefg"));
    try std.testing.expect(contains(d.out, "-{\"pw\": \"" ++ redacted_secret ++ "\"}\n"));
}

test "state: nothing derived from a secret value is stored, by apply, an overwrite, diff or commit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = "SuperSecretValue12345";
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = value }});
    try writeRepo(io, &tmp, "repo/src/rc.txt", "a=1\ntok=<secret:env:MOX_TEST_TOKEN>\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("rc.txt"), .data = "a=2\ntok=" ++ value ++ "\n" });
    _ = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    _ = try h.run(&.{ "mox", "doctor", "--rebuild-provenance" });

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expect(!try stateHolds(h, value));
    try std.testing.expect(!try stateHolds(h, &hex));
    try std.testing.expect(!try stateHolds(h, "secret_windows"));
    try std.testing.expect(!try stateHolds(h, "digests"));
    try std.testing.expect(!exists(io, try statePath(h, &.{ "v2", "secret-lines.key" })));
}

/// A PEM-like text of about `size` bytes, its body drawn from `seed`.
fn pemOf(a: std.mem.Allocator, seed: u64, size: usize) ![]const u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "-----BEGIN TEST KEY-----\n");
    while (out.items.len + 64 < size) {
        for (0..63) |_| try out.append(a, alphabet[prng.random().uintLessThan(usize, alphabet.len)]);
        try out.append(a, '\n');
    }
    try out.appendSlice(a, "-----END TEST KEY-----");
    return out.items;
}

test "apply: a secret of a megabyte, rotated and overwritten, leaves no byte of either value in the state, and its provenance stays under twice the file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    const pem_path = try std.fs.path.join(a, &.{ h.root, "key.pem" });
    const old = try pemOf(a, 1, 1_000_000);
    const new = try pemOf(a, 2, 1_000_000);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pem_path, .data = old });
    try writeRepo(io, &tmp, "repo/src/big.txt", try std.fmt.allocPrint(a, "name=big\nkey: <secret:file://{s}>\nend=1\n", .{pem_path}));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("big.txt");
    const live_size = (try Io.Dir.cwd().statFile(io, live, .{})).size;

    const store = try mox.state.Store.init(a, h.state);
    const g = (try mox.state.recovery.readGeneration(a, io, store, try currentId(h), null)).?;
    const prov = try statePath(h, &.{ "v2", "blobs", &g.paths.get(live).?.file.?.provenance_blob.? });
    try std.testing.expect((try Io.Dir.cwd().statFile(io, prov, .{})).size < 2 * live_size);

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pem_path, .data = new });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = try std.mem.concat(a, u8, &.{ "name=big\nkey: ", old, "\nend=2\n" }) });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    for ([_][]const u8{ old, new }) |value| {
        for ([_]usize{ 100, 400_000, 900_000 }) |at| {
            try std.testing.expect(!try stateHolds(h, value[at .. at + 40]));
        }
    }
}

test "apply --overwrite: a secret line the user moved is masked in the snapshot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "tok-4c1d-SECRET" }});
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\ntoken=<secret:env:MOX_TEST_TOKEN>\nz\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "token=tok-4c1d-SECRET\na\nz\nkept\n" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    try std.testing.expect(!try stateHolds(h, "4c1d"));
    try std.testing.expect(try stateHolds(h, "token=" ++ redacted_secret ++ "\na\nz\nkept\n"));
}

test "diff: an edited secret line, a trailing comment added, is masked from its value on, and a copy in another hunk is masked by the value" {
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
    try std.testing.expect(contains(d.out, "-token=" ++ redacted_secret ++ "\n"));
    try std.testing.expect(contains(d.out, "+token=" ++ redacted_secret ++ "\n"));
    try std.testing.expect(contains(d.out, "-export TOKEN=" ++ redacted_secret ++ "\n"));
    try std.testing.expect(contains(d.out, "-q1\n"));
}

test "diff: a value rotated behind the same reference prints neither value, and a stale file shows its removal masked" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    const tok = try std.fs.path.join(a, &.{ h.root, "token" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tok, .data = "old-7f3a-VALUE" });
    try writeRepo(io, &tmp, "repo/src/.cfg", try std.fmt.allocPrint(a, "a\ntoken=<secret:file://{s}>\nz\n", .{tok}));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tok, .data = "new-9b2e-VALUE" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "7f3a"));
    try std.testing.expect(!contains(d.out, "9b2e"));
    try std.testing.expect(contains(d.out, "-token=" ++ redacted_secret ++ "\n+token=" ++ redacted_secret ++ "\n"));

    try Io.Dir.cwd().deleteFile(io, try h.srcOf(".cfg"));
    const stale = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), stale.rc);
    try std.testing.expect(!contains(stale.out, "7f3a"));
    try std.testing.expect(contains(stale.out, "-a\n-token=" ++ redacted_secret ++ "\n-z\n"));
}

test "diff: every live line of a file holding a multi-line secret is masked, an edited one included" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_MULTI", .value = "-----BEGIN-----\nAAAA1111\nBBBB2222\n-----END-----" }});
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\nkey=<secret:env:MOX_TEST_MULTI>\nz\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\nz\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "a\nkey=-----BEGIN-----\nAAAA1111\nBBBB2222-edited\n-----END-----\nadded\nz\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    for ([_][]const u8{ "BEGIN", "AAAA", "BBBB", "END", "added" }) |s| try std.testing.expect(!contains(d.out, s));
    try std.testing.expect(contains(d.out, "-" ++ redacted_secret ++ "\n"));
}

test "diff: a file that is one secret line shows none of its live lines" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "tok-4c1d-SECRET" }});
    try writeRepo(io, &tmp, "repo/src/.tok", "<secret:env:MOX_TEST_TOKEN>\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try writeRepo(io, &tmp, "repo/src/.tok", "plain\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".tok"), .data = "tok-4c1d-SECRET-and-more\nnote\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "4c1d"));
    try std.testing.expect(!contains(d.out, "note"));
    try std.testing.expect(contains(d.out, "-" ++ redacted_secret ++ "\n-" ++ redacted_secret ++ "\n+plain\n"));
}

test "diff: a secret line edited beyond its shape leaves no unrecognized live line in clear" {
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
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "a\ntok3n: tok-4c1d-SECRET\nz\nadded\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "4c1d"));
    try std.testing.expect(!contains(d.out, "added"));
    try std.testing.expect(contains(d.out, "-" ++ redacted_line ++ "\n"));
}

test "diff and apply: a secret of several lines in a TOML file is masked on every line it fills, once rotated" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    const pem = try std.fs.path.join(a, &.{ h.root, "pem" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pem, .data = "AAAA1111\nBBBB2222\nCCCC3333" });
    try writeRepo(io, &tmp, "repo/src/c.toml", try std.fmt.allocPrint(a, "name = \"x\"\nkey = \"\"\"<secret:file://{s}>\"\"\"\nend = 1\n", .{pem}));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pem, .data = "DDDD4444\nEEEE5555" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    for ([_][]const u8{ "AAAA", "BBBB", "CCCC", "DDDD", "EEEE" }) |s| try std.testing.expect(!contains(d.out, s));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    for ([_][]const u8{ "AAAA1111", "BBBB2222", "CCCC3333", "DDDD4444", "EEEE5555" }) |s| try std.testing.expect(!try stateHolds(h, s));
}

test "diff and apply: a rotated value that holds the text after its slot is masked whole" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    const pw = try std.fs.path.join(a, &.{ h.root, "pw" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pw, .data = "ab\"cdLEAKME" });
    try writeRepo(io, &tmp, "repo/src/.cfg", try std.fmt.allocPrint(a, "a=1\npw=\"<secret:file://{s}>\"\nz=1\n", .{pw}));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pw, .data = "newvalue1" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "LEAKME"));
    try std.testing.expect(!contains(d.out, "newvalue1"));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    try std.testing.expect(!try stateHolds(h, "LEAKME"));
}

test "apply: a snapshot of a file whose provenance has no shapes, or none at all, keeps no rotated value" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_USER", .value = "admin" }});
    const pw = try std.fs.path.join(a, &.{ h.root, "pw" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pw, .data = "OLDPASSWORD" });
    try writeRepo(io, &tmp, "repo/src/.cfg", try std.fmt.allocPrint(a, "a\nurl=<secret:env:MOX_TEST_USER>:<secret:file://{s}>@host\nz\n", .{pw}));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    raced_state = h.state;
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
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pw, .data = "NEWPASSWORD" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(!try stateHolds(h, "OLDPASSWORD"));

    const live = try h.liveOf(".cfg");
    const store = try mox.state.Store.init(a, h.state);
    const g = (try mox.state.recovery.readGeneration(a, io, store, try currentId(h), null)).?;
    try Io.Dir.cwd().deleteFile(io, try statePath(h, &.{ "v2", "blobs", &g.paths.get(live).?.file.?.provenance_blob.? }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pw, .data = "THIRDPASSWORD" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(!try stateHolds(h, "NEWPASSWORD"));
}

test "remove --purge: the snapshot of a file mox wrote a secret into keeps no value" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "PURGEDSECRET" }});
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\ntok=<secret:env:MOX_TEST_TOKEN>\nz\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const r = try h.runIn(h.home, &.{ "mox", "remove", "--purge", ".cfg" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(!exists(io, try h.liveOf(".cfg")));
    try std.testing.expect(!try stateHolds(h, "PURGEDSECRET"));
    try std.testing.expect(try stateHolds(h, "a\ntok=" ++ redacted_secret ++ "\nz\n"));
}

test "apply --overwrite: a value one file resolves masks nothing in the snapshot of another" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    const key = try std.fs.path.join(a, &.{ h.root, "sa.json" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = key, .data = "{\n  \"k\": \"v4lue\"\n}" });
    try writeRepo(io, &tmp, "repo/src/a.cfg", try std.fmt.allocPrint(a, "creds=<secret:file://{s}>\n", .{key}));
    try writeRepo(io, &tmp, "repo/src/b.sh", "f() {\n  echo hi\n}\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("b.sh"), .data = "f() {\n  echo edited\n}\n" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    try std.testing.expect(try stateHolds(h, "f() {\n  echo edited\n}\n"));
}

test "apply and diff: a secret of 200000 lines is recorded and masked within a bounded time" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    const many = try std.fs.path.join(a, &.{ h.root, "many" });
    var value: std.ArrayList(u8) = .empty;
    for (0..200_000) |i| try value.appendSlice(a, if (i % 2 == 0) "x\n" else "y\n");
    try value.appendSlice(a, "zzUNIQUEzz");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = many, .data = value.items });
    try writeRepo(io, &tmp, "repo/src/many.txt", try std.fmt.allocPrint(a, "k: <secret:file://{s}>\n", .{many}));
    var watch = try Watchdog.start(io, 60);
    defer watch.stop();
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("many.txt"), .data = "edited\nzzUNIQUEzz\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "zzUNIQUEzz"));
    try std.testing.expect(!contains(d.out, "edited"));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    try std.testing.expect(!try stateHolds(h, "zzUNIQUEzz"));
}

test "diff: a value another file resolves is masked in every file, a file composing nothing included" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "SHAREDSECRET1" }});
    try writeRepo(io, &tmp, "repo/src/z.cfg", "a=1\nz=1\n");
    try writeRepo(io, &tmp, "repo/src/a.cfg", "tok=<secret:env:MOX_TEST_TOKEN>\n");
    try writeRepo(io, &tmp, "repo/src/y.cfg", "y=1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("z.cfg"), .data = "a=1\nexport TOKEN=SHAREDSECRET1\nz=1\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("y.cfg"), .data = "y=1\ncopy=SHAREDSECRET1\n" });
    try Io.Dir.cwd().deleteFile(io, try h.srcOf("y.cfg"));
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "SHAREDSECRET1"));
    try std.testing.expect(contains(d.out, "-export TOKEN=" ++ redacted_secret ++ "\n"));
}

test "remove --purge: a FIFO at the live path is removed without being read, and the run does not wait on it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf(".cfg");
    try Io.Dir.cwd().deleteFile(io, live);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(try a.dupeZ(u8, live), 0o644));
    var watch = try Watchdog.start(io, 120);
    defer watch.stop();
    const r = try h.runIn(h.home, &.{ "mox", "remove", "--purge", ".cfg" });
    try std.testing.expect(r.rc <= 1);
}

/// A harness whose source resolves `<secret:file://{root}/sec>`, the file
/// holding `value`; `rotate` rewrites it.
fn withSecretFile(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, value: []const u8) !struct { h: Harness, ref: []const u8, path: []const u8 } {
    const h = try setup(a, io, tmp);
    const path = try std.fs.path.join(a, &.{ h.root, "sec" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = value });
    return .{ .h = h, .ref = try std.fmt.allocPrint(a, "<secret:file://{s}>", .{path}), .path = path };
}

fn rotate(io: Io, path: []const u8, value: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = value });
}

test "diff: a secret line edited beyond its shape fails closed although another line holds its prefix, and neither value is printed" {
    const io = std.testing.io;
    for ([_][]const u8{ "db_token=public", "other=public" }) |first| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const s = try withSecretFile(a, io, &tmp, "OLDSECRET1");
        const h = s.h;
        try writeRepo(io, &tmp, "repo/src/.app.conf", try std.fmt.allocPrint(a, "{s}\ntoken={s}\n", .{ first, s.ref }));
        try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
        try rotate(io, s.path, "NEWSECRET2");
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".app.conf"), .data = try std.fmt.allocPrint(a, "{s}\ntoken = OLDSECRET1\n", .{first}) });
        const d = try h.run(&.{ "mox", "diff" });
        try std.testing.expectEqual(@as(u8, 0), d.rc);
        try std.testing.expect(!contains(d.out, "OLDSECRET1"));
        try std.testing.expect(!contains(d.out, "NEWSECRET2"));
        try std.testing.expect(contains(d.out, "-" ++ redacted_line ++ "\n"));
        try std.testing.expect(contains(d.out, "+token=" ++ redacted_secret ++ "\n"));
    }
}

test "apply --overwrite and remove --purge: a secret line edited beyond its shape, its value rotated, is not kept in the snapshot" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |purge| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const s = try withSecretFile(a, io, &tmp, "OLDSECRET1");
        const h = s.h;
        try writeRepo(io, &tmp, "repo/src/.app.conf", try std.fmt.allocPrint(a, "other=public\ntoken={s}\n", .{s.ref}));
        try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
        try rotate(io, s.path, "NEWSECRET2");
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".app.conf"), .data = "other=public\ntoken = OLDSECRET1\n" });
        if (purge) {
            try std.testing.expectEqual(@as(u8, 0), (try h.runIn(h.home, &.{ "mox", "remove", "--purge", ".app.conf" })).rc);
        } else {
            try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
        }
        try std.testing.expect(!try stateHolds(h, "OLDSECRET1"));
        try std.testing.expect(!try stateHolds(h, "NEWSECRET2"));
        try std.testing.expect(try stateHolds(h, "other=public\n" ++ redacted_line ++ "\n"));
    }
}

test "remove --purge: a secret line whose CRLF the user changed to LF is not kept in the snapshot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "CRLFSECRET" }});
    try writeRepo(io, &tmp, "repo/src/.app.conf", "other=public\r\ntoken=<secret:env:MOX_TEST_TOKEN>\r\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect(contains(try read(io, a, try h.liveOf(".app.conf")), "token=CRLFSECRET\r\n"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".app.conf"), .data = "other=public\ntoken=CRLFSECRET\n" });
    try std.testing.expectEqual(@as(u8, 0), (try h.runIn(h.home, &.{ "mox", "remove", "--purge", ".app.conf" })).rc);
    try std.testing.expect(!try stateHolds(h, "CRLFSECRET"));
}

test "diff and apply --overwrite: a secret line edited beyond its shape is not stood in for by a line mox wrote that matches the shape" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try withSecretFile(a, io, &tmp, "OLDSECRET1");
    const h = s.h;
    try writeRepo(io, &tmp, "repo/src/list.txt", try std.fmt.allocPrint(a, "- token: \"{s}\"\n- token: \"public\"\n", .{s.ref}));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try rotate(io, s.path, "NEWSECRET2");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("list.txt"), .data = "- token: \"OLDSECRET1\" # rotated\n- token: \"public\"\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "OLDSECRET1"));
    try std.testing.expect(!contains(d.out, "NEWSECRET2"));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    try std.testing.expect(!try stateHolds(h, "OLDSECRET1"));
}

test "diff: two secret lines of one shape under two INI sections, one edited beyond it, fail closed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try withSecretFile(a, io, &tmp, "AAAOLDVALUE");
    const h = s.h;
    const b_path = try std.fs.path.join(a, &.{ h.root, "sec-b" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = b_path, .data = "BBBVALUE" });
    try writeRepo(io, &tmp, "repo/src/app.ini", try std.fmt.allocPrint(a, "[a]\ntoken = {s}\n[b]\ntoken = <secret:file://{s}>\n", .{ s.ref, b_path }));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try rotate(io, s.path, "AAANEWVALUE");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("app.ini"), .data = "[a]\ntoken: AAAOLDVALUE\n[b]\ntoken = BBBVALUE\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "AAA"));
    try std.testing.expect(!contains(d.out, "BBB"));
    try std.testing.expect(contains(d.out, "-" ++ redacted_line ++ "\n"));
}

test "diff: a YAML list of secrets with one item gone and its value moved elsewhere fails closed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try withSecretFile(a, io, &tmp, "KEYONEOLD");
    const h = s.h;
    const two = try std.fs.path.join(a, &.{ h.root, "sec-2" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = two, .data = "KEYTWO" });
    try writeRepo(io, &tmp, "repo/src/keys.yaml", try std.fmt.allocPrint(a, "keys:\n  - {s}\n  - <secret:file://{s}>\nname: x\n", .{ s.ref, two }));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try rotate(io, s.path, "KEYONENEW");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("keys.yaml"), .data = "keys:\n  - KEYTWO\nname: x\nbackup: KEYONEOLD\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "KEYONE"));
    try std.testing.expect(!contains(d.out, "KEYTWO"));
    try std.testing.expect(contains(d.out, "-" ++ redacted_line ++ "\n"));
}

test "diff and apply --overwrite: a secret line moved below the lines around it is still recognized, and the other lines are shown and kept" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try withSecretFile(a, io, &tmp, "MOVEDOLD");
    const h = s.h;
    try writeRepo(io, &tmp, "repo/src/.cfg", try std.fmt.allocPrint(a, "a\ntoken={s}\nz\n", .{s.ref}));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try rotate(io, s.path, "MOVEDNEW");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "a\nz\nadded\ntoken=MOVEDOLD\n" });
    const d = try h.run(&.{ "mox", "diff" });
    try std.testing.expectEqual(@as(u8, 0), d.rc);
    try std.testing.expect(!contains(d.out, "MOVED"));
    try std.testing.expect(!contains(d.out, redacted_line));
    try std.testing.expect(contains(d.out, "-added\n"));
    try std.testing.expect(contains(d.out, "-token=" ++ redacted_secret ++ "\n"));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    try std.testing.expect(!try stateHolds(h, "MOVED"));
    try std.testing.expect(try stateHolds(h, "a\nz\nadded\ntoken=" ++ redacted_secret ++ "\n"));
}

test "rollback: a snapshot whose lines were not kept because a secret line had changed says how many" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try withSecretFile(a, io, &tmp, "OLDSECRET1");
    const h = s.h;
    try writeRepo(io, &tmp, "repo/src/.app.conf", try std.fmt.allocPrint(a, "other=public\ntoken={s}\n", .{s.ref}));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try rotate(io, s.path, "NEWSECRET2");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".app.conf"), .data = "other=public\ntoken = OLDSECRET1\nnote = mine\n" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    const rb = try h.run(&.{ "mox", "rollback" });
    try std.testing.expectEqual(@as(u8, 0), rb.rc);
    try std.testing.expect(contains(rb.out, "2 line(s) were not kept"));
    try std.testing.expectEqualStrings("other=public\n" ++ redacted_line ++ "\n" ++ redacted_line ++ "\n", try read(io, a, try h.liveOf(".app.conf")));
}

test "apply --overwrite: a record whose provenance holds no outline masks the lines at the secret's recorded positions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try withSecretFile(a, io, &tmp, "UNOUTLINEDOLD");
    const h = s.h;
    try writeRepo(io, &tmp, "repo/src/.cfg", try std.fmt.allocPrint(a, "a\ntoken={s}\nz\n", .{s.ref}));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    raced_state = h.state;
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
    try rotate(io, s.path, "UNOUTLINEDNEW");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".cfg"), .data = "a\ntoken = UNOUTLINEDOLD\nz\n" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply", "--overwrite" })).rc);
    try std.testing.expect(!try stateHolds(h, "UNOUTLINED"));
    try std.testing.expect(try stateHolds(h, "a\n" ++ redacted_secret ++ "\nz\n"));
}

/// Fails the test run, rather than letting it hang, when the test does not
/// stop it within `seconds`.
const Watchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn start(io: Io, seconds: u64) !*Watchdog {
        const w = try std.heap.page_allocator.create(Watchdog);
        w.* = .{};
        w.thread = try std.Thread.spawn(.{}, run, .{ w, io, seconds });
        return w;
    }

    fn run(w: *Watchdog, io: Io, seconds: u64) void {
        const started = Io.Clock.awake.now(io);
        while (!w.done.load(.acquire)) {
            if (started.durationTo(Io.Clock.awake.now(io)).toSeconds() >= seconds) {
                std.debug.print("watchdog: the test did not finish within {d} s\n", .{seconds});
                std.process.abort();
            }
            io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
    }

    fn stop(w: *Watchdog) void {
        w.done.store(true, .release);
        w.thread.join();
        std.heap.page_allocator.destroy(w);
    }
};

test "apply: a file mox wrote a secret into, replaced by a symlink, is kept masked in the snapshot" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_TEST_TOKEN", .value = "LINKEDSECRET" }});
    try writeRepo(io, &tmp, "repo/src/.cfg", "a\ntok=<secret:env:MOX_TEST_TOKEN>\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().deleteFile(io, try h.srcOf(".cfg"));
    try tmp.dir.symLink(io, "/nonexistent-target", "repo/src/.cfg", .{});
    _ = try h.run(&.{ "mox", "apply", "--overwrite" });
    try std.testing.expect(!try stateHolds(h, "LINKEDSECRET"));
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
    try std.testing.expect(contains(r.err, "is not a mox state directory"));
    const after = try treeOf(a, io, target);
    try std.testing.expectEqual(before.count(), after.count());
    for (before.keys(), before.values()) |k, v| try std.testing.expectEqualStrings(v, after.get(k).?);
}

test "state directory: MOX_STATE_DIR=. in a home directory is refused, and nothing is created or removed there" {
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
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    const names = try namesIn(a, io, h.home);
    for ([_][]const []const u8{ &.{ "mox", "uninstall" }, &.{ "mox", "apply" }, &.{ "mox", "uninstall", "--purge-snapshots" } }) |argv| {
        const r = try h.run(argv);
        try std.testing.expectEqual(@as(u8, 2), r.rc);
        try std.testing.expect(contains(r.err, "is not a mox state directory"));
        const now = try namesIn(a, io, h.home);
        try std.testing.expectEqual(names.len, now.len);
    }
    try std.testing.expectEqualStrings("precious\n", try read(io, a, try std.fs.path.join(a, &.{ h.home, "Documents", "thesis.txt" })));
    try std.testing.expectEqualStrings("alias l=ls\n", try read(io, a, try std.fs.path.join(a, &.{ h.home, ".bashrc" })));
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

test "uninstall: a bin/ or trash/ holding what mox did not make, and any tmp/, is kept and listed, and mox's own are removed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setup(a, io, &tmp);

    // A home directory named as the state directory, marked as mox's.
    try writeRepo(io, &tmp, "homelike/.mox-state", "mox state 1\n");
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
    try std.testing.expect(contains(r.out, try std.fmt.allocPrint(a, "kept {s} (not made by mox)", .{try statePath(foreign, &.{"tmp"})})));
    try std.testing.expect(contains(r.out, try std.fmt.allocPrint(a, "kept {s} (holds old-photos, which mox did not make)", .{try statePath(foreign, &.{"trash"})})));

    // Without the marker, a bin/ of the user's is not mox's.
    for ([_][]const u8{ ".mox-state", "mox.lock", "readers.lock", "readers.gate" }) |n| Io.Dir.cwd().deleteFile(io, try statePath(foreign, &.{n})) catch {};
    const refused = try foreign.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 2), refused.rc);
    try std.testing.expect(contains(refused.err, "is not a mox state directory"));

    // A real state: the scripts' bin/ apply made and a trash generation
    // are mox's, and go; mox stages nothing in a tmp/, so one is kept.
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
    for ([_][]const u8{ "bin", "trash" }) |n| try std.testing.expect(!exists(io, try statePath(h, &.{n})));
    try std.testing.expectEqualStrings("in\n", try read(io, a, try statePath(h, &.{ "tmp", "stdin-99999.txt" })));
    try std.testing.expect(contains(ok.out, try std.fmt.allocPrint(a, "kept {s} (not made by mox)", .{try statePath(h, &.{"tmp"})})));
}

/// The top-level entry names of `dir`, sorted; none when it is absent.
fn namesIn(a: std.mem.Allocator, io: Io, dir: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| try out.append(a, try a.dupe(u8, e.name));
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

/// A home directory named as the state directory: a script of the user's
/// in `bin/`, notes in `v2/`, a photo in `snapshots/`.
fn homeLike(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, h: Harness) !Harness {
    try writeRepo(io, tmp, "homelike/bin/user-script", "#!/bin/sh\n");
    try writeRepo(io, tmp, "homelike/v2/notes", "notes\n");
    try writeRepo(io, tmp, "homelike/trash/photo", "jpg\n");
    try writeRepo(io, tmp, "homelike/.bashrc", "alias l=ls\n");
    return withState(h, try std.fs.path.join(a, &.{ h.root, "homelike" }));
}

fn expectHomeLikeKept(io: Io, a: std.mem.Allocator, h: Harness) !void {
    try std.testing.expectEqualStrings("#!/bin/sh\n", try read(io, a, try statePath(h, &.{ "bin", "user-script" })));
    try std.testing.expectEqualStrings("notes\n", try read(io, a, try statePath(h, &.{ "v2", "notes" })));
    try std.testing.expectEqualStrings("jpg\n", try read(io, a, try statePath(h, &.{ "trash", "photo" })));
    try std.testing.expectEqualStrings("alias l=ls\n", try read(io, a, try statePath(h, &.{".bashrc"})));
}

/// The setup a run that reaches the script runner needs: a managed file and
/// a pre script.
fn withScript(io: Io, a: std.mem.Allocator, tmp: *std.testing.TmpDir, h: Harness) !void {
    try writeRepo(io, tmp, "repo/src/.zshrc", "v1\n");
    try writeRepo(io, tmp, "repo/scripts/pre/00-noop.sh", "#!/bin/sh\nexit 0\n");
    try chmodPath(a, try std.fs.path.join(a, &.{ h.repo, "scripts", "pre", "00-noop.sh" }), 0o755);
}

test "state directory: one that holds no marker is refused by every command, and nothing in it is read, created or removed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setup(a, io, &tmp);
    try withScript(io, a, &tmp, h);
    h = try homeLike(a, io, &tmp, h);
    const names = try namesIn(a, io, h.state);
    const before = try treeOf(a, io, h.state);
    const commands = [_][]const []const u8{
        &.{ "mox", "apply" },
        &.{ "mox", "apply", "--dry-run" },
        &.{ "mox", "status" },
        &.{ "mox", "diff" },
        &.{ "mox", "snapshot" },
        &.{ "mox", "export", try std.fs.path.join(a, &.{ h.root, "out" }) },
        &.{ "mox", "mv", try h.liveOf(".zshrc"), try h.liveOf(".zshrc2") },
        &.{ "mox", "add", try h.liveOf(".zshrc") },
        &.{ "mox", "facts", "set", "x", "y" },
        &.{ "mox", "trigger", "every", "k", "1" },
        &.{ "mox", "uninstall", "--purge-snapshots", "--purge-trash", "--purge-private" },
    };
    for (commands) |argv| {
        const r = try h.run(argv);
        if (r.rc != 2 or !contains(r.err, "is not a mox state directory")) std.debug.print("{s}: rc {d}\n{s}\n", .{ argv[1], r.rc, r.err });
        try std.testing.expectEqual(@as(u8, 2), r.rc);
        try std.testing.expect(contains(r.err, try std.fmt.allocPrint(a, "{s} is not a mox state directory", .{h.state})));
        try std.testing.expect(contains(r.err, "point MOX_STATE_DIR at a dedicated directory"));
        try std.testing.expect(contains(r.err, try std.fmt.allocPrint(a, "  sh:         (umask 077 && printf 'mox state 1\\n' > '{s}/.mox-state')\n", .{h.state})));
        try std.testing.expect(contains(r.err, try std.fmt.allocPrint(a, "  PowerShell: [IO.File]::WriteAllText('{s}/.mox-state', \"mox state 1`n\")\n", .{h.state})));
        const now = try namesIn(a, io, h.state);
        try std.testing.expectEqual(names.len, now.len);
        for (names, now) |x, y| try std.testing.expectEqualStrings(x, y);
        const after = try treeOf(a, io, h.state);
        try std.testing.expectEqual(before.count(), after.count());
        for (before.keys(), before.values()) |k, v| try std.testing.expectEqualStrings(v, after.get(k).?);
    }
    try std.testing.expect(!exists(io, try h.liveOf(".zshrc")));
}

test "state directory: a stray empty mox.lock is no evidence, and one the marker makes mox's keeps every entry mox did not make, through every command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = try setup(a, io, &tmp);
    try withScript(io, a, &tmp, h);
    h = try homeLike(a, io, &tmp, h);
    try writeRepo(io, &tmp, "homelike/mox.lock", "");
    const refused = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 2), refused.rc);
    try std.testing.expect(contains(refused.err, "is not a mox state directory"));
    try writeRepo(io, &tmp, "homelike/.mox-state", "mox state 1\n");
    for ([_][]const []const u8{
        &.{ "mox", "status" },
        &.{ "mox", "apply" },
        &.{ "mox", "status" },
        &.{ "mox", "uninstall", "--purge-snapshots", "--purge-trash" },
    }) |argv| {
        const r = try h.run(argv);
        if (std.mem.eql(u8, argv[1], "uninstall")) {
            try std.testing.expectEqual(@as(u8, 0), r.rc);
            try std.testing.expect(contains(r.out, try std.fmt.allocPrint(a, "kept {s} (holds user-script, which mox did not make)", .{try statePath(h, &.{"bin"})})));
            try std.testing.expect(contains(r.out, try std.fmt.allocPrint(a, "kept {s} (holds photo, which mox did not make)", .{try statePath(h, &.{"trash"})})));
            try std.testing.expect(contains(r.out, try std.fmt.allocPrint(a, "kept {s} (holds notes, which mox did not make)", .{try statePath(h, &.{"v2"})})));
        }
        try expectHomeLikeKept(io, a, h);
    }
    try std.testing.expectEqualStrings("v1\n", try read(io, a, try h.liveOf(".zshrc")));
}

test "state directory: a fresh state, an absent or empty one, gets the marker on its first write, and a reader creates nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    _ = try h.run(&.{ "mox", "status" });
    try std.testing.expect(!exists(io, h.state));
    try Io.Dir.cwd().createDirPath(io, h.state);
    _ = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(usize, 0), (try namesIn(a, io, h.state)).len);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const marker = try statePath(h, &.{".mox-state"});
    try std.testing.expectEqualStrings("mox state 1\n", try read(io, a, marker));
    if (builtin.os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(io, marker, .{});
        try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);

    // A state directory that holds only the private layer is one the user
    // set up before the first run.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    const p = try setup(a, io, &tmp2);
    try writeRepo(io, &tmp2, "repo/src/.zshrc", "v1\n");
    try writeRepo(io, &tmp2, "state/private/.p", "private\n");
    try std.testing.expectEqual(@as(u8, 0), (try p.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("private\n", try read(io, a, try p.liveOf(".p")));
    try std.testing.expect(exists(io, try statePath(p, &.{".mox-state"})));
}

/// `h` with no `MOX_STATE_DIR`: the state directory is mox's default,
/// `$XDG_STATE_HOME/mox`, with `XDG_STATE_HOME` under the test's root.
fn withDefaultState(h: Harness) !Harness {
    const m = try h.a.create(std.process.Environ.Map);
    m.* = try h.env.createMap(h.a);
    _ = m.swapRemove("MOX_STATE_DIR");
    const xdg = try std.fs.path.join(h.a, &.{ h.root, "xdg-state" });
    try m.put("XDG_STATE_HOME", xdg);
    var out = h;
    out.env = .{ .map = m };
    out.state = try std.fs.path.join(h.a, &.{ xdg, "mox" });
    return out;
}

test "state directory: one holding only lock files and OS files is fresh under MOX_STATE_DIR, and the default path is mox's whatever it holds" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try setup(a, io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
    for ([_][]const u8{ "mox.lock", "readers.lock", "readers.gate", ".DS_Store" }) |n| try writeRepo(io, &tmp, try std.fs.path.join(a, &.{ "state", n }), "");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("v1\n", try read(io, a, try h.liveOf(".zshrc")));
    try std.testing.expect(exists(io, try statePath(h, &.{".mox-state"})));

    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    const d = try withDefaultState(try setup(a, io, &tmp2));
    try writeRepo(io, &tmp2, "repo/src/.zshrc", "v1\n");
    try writeRepo(io, &tmp2, "xdg-state/mox/notes.txt", "mine\n");
    try writeRepo(io, &tmp2, "xdg-state/mox/bin/user-script", "#!/bin/sh\n");
    const st = try d.run(&.{ "mox", "status" });
    try std.testing.expect(st.rc != 2);
    try std.testing.expect(!contains(st.err, "is not a mox state directory"));
    try std.testing.expect(!exists(io, try statePath(d, &.{".mox-state"})));
    try std.testing.expectEqual(@as(u8, 0), (try d.run(&.{ "mox", "apply" })).rc);
    try std.testing.expectEqualStrings("v1\n", try read(io, a, try d.liveOf(".zshrc")));
    try std.testing.expectEqualStrings("mox state 1\n", try read(io, a, try statePath(d, &.{".mox-state"})));
    try std.testing.expectEqualStrings("mine\n", try read(io, a, try statePath(d, &.{"notes.txt"})));
}

test "state directory: a marker a newer mox wrote is refused, at the default path too" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |default| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var h = try setup(a, io, &tmp);
        if (default) h = try withDefaultState(h);
        try writeRepo(io, &tmp, "repo/src/.zshrc", "v1\n");
        try Io.Dir.cwd().createDirPath(io, h.state);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try statePath(h, &.{".mox-state"}), .data = "mox state 2\n" });
        for ([_][]const []const u8{ &.{ "mox", "status" }, &.{ "mox", "apply" } }) |argv| {
            const r = try h.run(argv);
            try std.testing.expectEqual(@as(u8, 2), r.rc);
            try std.testing.expect(contains(r.err, "newer mox"));
        }
        try std.testing.expect(!exists(io, try h.liveOf(".zshrc")));
        try std.testing.expectEqualStrings("mox state 2\n", try read(io, a, try statePath(h, &.{".mox-state"})));
    }
}

test "state directory: a full uninstall removes the marker last, and one that keeps mox's entries keeps it" {
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
    const marker = try statePath(h, &.{".mox-state"});
    const kept = try h.run(&.{ "mox", "uninstall" });
    try std.testing.expectEqual(@as(u8, 0), kept.rc);
    try std.testing.expect(exists(io, marker));
    try std.testing.expect(contains(kept.out, try std.fmt.allocPrint(a, "kept {s}", .{marker})));
    const r = try h.run(&.{ "mox", "uninstall", "--purge-snapshots" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(!exists(io, marker));
    const line = try std.fmt.allocPrint(a, "  removed {s}\n", .{marker});
    const at = std.mem.indexOf(u8, r.out, line) orelse return error.MarkerNotRemoved;
    try std.testing.expect(std.mem.indexOf(u8, r.out[at + line.len ..], "  removed ") == null);
    for (try namesIn(a, io, h.state)) |n| {
        const lockish = std.mem.eql(u8, n, "mox.lock") or std.mem.eql(u8, n, "readers.lock") or std.mem.eql(u8, n, "readers.gate");
        if (!lockish) std.debug.print("left: {s}\n", .{n});
        try std.testing.expect(lockish);
    }
}

test "uninstall: a directory named as an OS file inside v2/ or a store is the user's, and keeps it whole" {
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
    try writeRepo(io, &tmp, "state/v2/.DS_Store/photo", "jpg\n");
    try writeRepo(io, &tmp, "state/v2/Thumbs.db", "x");
    const r = try h.run(&.{ "mox", "uninstall", "--purge-snapshots" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expectEqualStrings("jpg\n", try read(io, a, try statePath(h, &.{ "v2", ".DS_Store", "photo" })));
    try std.testing.expect(contains(r.out, try std.fmt.allocPrint(a, "kept {s} (holds .DS_Store, which mox did not make)", .{try statePath(h, &.{"v2"})})));
}

test "state directory: uninstall keeps the marker while it keeps any entry, mox's or not, and removes it when only lock files and OS files are left" {
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
    const marker = try statePath(h, &.{".mox-state"});
    for ([_][]const u8{ "notes.txt", "bin/user-script", "v2/.DS_Store/photo" }) |stray| {
        try writeRepo(io, &tmp, try std.fs.path.join(a, &.{ "state", stray }), "mine\n");
        const r = try h.run(&.{ "mox", "uninstall", "--purge-snapshots", "--purge-trash" });
        try std.testing.expectEqual(@as(u8, 0), r.rc);
        try std.testing.expect(exists(io, marker));
        try std.testing.expect(contains(r.out, try std.fmt.allocPrint(a, "kept {s}", .{marker})));
        try std.testing.expectEqualStrings("mine\n", try read(io, a, try statePath(h, &.{stray})));
        try std.testing.expect(!contains((try h.run(&.{ "mox", "status" })).err, "is not a mox state directory"));
        try Io.Dir.cwd().deleteTree(io, try statePath(h, &.{std.mem.sliceTo(stray, '/')}));
    }
    try writeRepo(io, &tmp, "state/.DS_Store", "x");
    const r = try h.run(&.{ "mox", "uninstall", "--purge-snapshots", "--purge-trash" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(!exists(io, marker));
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
