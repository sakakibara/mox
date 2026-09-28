const std = @import("std");
const mox = @import("mox");

const Io = std.Io;

const testutil = @import("testutil.zig");
const Harness = testutil.Harness;

fn setup(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, opts: testutil.SetupOpts) !Harness {
    // These fixtures reason about os-gated configurations relative to "this
    // machine", so the machine's os must not depend on which runner builds
    // them. darwin is the value the fixtures are written against.
    var pinned = opts;
    if (pinned.os == null) pinned.os = "darwin";
    return testutil.setup(a, io, tmp, pinned);
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn writeRepo(io: Io, tmp: *std.testing.TmpDir, sub: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}", .{sub});
    defer std.testing.allocator.free(path);
    if (std.fs.path.dirname(sub)) |parent| try tmp.dir.createDirPath(io, parent);
    try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = content });
}

fn read(io: Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
}

fn editLive(io: Io, a: std.mem.Allocator, path: []const u8, from: []const u8, to: []const u8) !void {
    const c = try read(io, a, path);
    const nc = try std.mem.replaceOwned(u8, a, c, from, to);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = nc });
}

/// Order-independent hash of every regular file under `dir_abs`, keyed by
/// relative path, so a before/after comparison proves the tree is byte-equal.
fn hashTree(io: Io, a: std.mem.Allocator, dir_abs: []const u8, rel: []const u8, hasher: *std.crypto.hash.sha2.Sha256) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close(io);

    const Entry = struct { name: []const u8, is_dir: bool };
    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        try entries.append(a, .{ .name = try a.dupe(u8, e.name), .is_dir = e.kind == .directory });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);

    for (entries.items) |e| {
        const child_abs = try std.fs.path.join(a, &.{ dir_abs, e.name });
        const child_rel = try std.fs.path.join(a, &.{ rel, e.name });
        if (e.is_dir) {
            try hashTree(io, a, child_abs, child_rel, hasher);
        } else {
            const content = try read(io, a, child_abs);
            hasher.update(child_rel);
            hasher.update(&[_]u8{0});
            hasher.update(content);
            hasher.update(&[_]u8{0});
        }
    }
}

fn treeDigest(io: Io, a: std.mem.Allocator, dir_abs: []const u8) ![32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try hashTree(io, a, dir_abs, "", &hasher);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

test "commit: base-origin edit routes to src base and recompose is byte-identical" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\nexport C=3\n");
    const h = try setup(a, io, &tmp, .{});

    const apply_res = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), apply_res.rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export B=2", "export B=22");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The edit landed in the base source, byte-identical recompose.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expectEqualStrings("export A=1\nexport B=22\nexport C=3\n", src);

    // Status is now clean (rc 0): recompose == live, applied record advanced.
    const st = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 0), st.rc);
}

test "commit: a drifted file is scoped by the bare name its own directory gives it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.config/nvim/init.lua", "vim.o.number = true\n");
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".config/nvim/init.lua");
    try editLive(io, a, live, "number = true", "number = false");

    // What tab-completion in that directory produces, which named HOME's
    // `init.lua` -- nothing -- before a relative path meant the cwd's.
    const nvim_dir = try std.fs.path.join(a, &.{ h.home, ".config", "nvim" });
    const res = try h.runIn(nvim_dir, &.{ "mox", "commit", "--yes", "init.lua" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    try std.testing.expectEqualStrings(
        "vim.o.number = false\n",
        try read(io, a, try h.srcOf(".config/nvim/init.lua")),
    );
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: a stored-baseline edit still refuses when the source changed since apply, not just when it is unmodified" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\nexport C=3\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The source moves on independently of any live edit -- e.g. another
    // machine's `mox commit` landed first. The stored baseline (what mox last
    // applied here) still says "export B=2", so a naive recompose-as-baseline
    // would trivially match the CURRENT source against itself and mis-route
    // the live edit below into a source that has already changed underneath
    // it. `sourceLinesMatch` must still see the mismatch and refuse.
    const src_path = try h.srcOf(".zshrc");
    try editLive(io, a, src_path, "export B=2", "export B=99");

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export B=2", "export B=22");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "source no longer matches recorded provenance") != null);

    // Nothing was routed: the independently-changed source and the live edit
    // both stand exactly as they were before this commit ran.
    try std.testing.expectEqualStrings("export A=1\nexport B=99\nexport C=3\n", try read(io, a, src_path));
    try std.testing.expectEqualStrings("export A=1\nexport B=22\nexport C=3\n", try read(io, a, live));
}

test "commit: an insertion refuses when the source line it follows moved since apply" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\nexport C=3\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_path = try h.srcOf(".zshrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src_path, .data = "export Z=0\nexport A=1\nexport B=2\nexport C=3\n" });

    const live = try h.liveOf(".zshrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "export A=1\nexport B=2\nexport N=1\nexport C=3\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "source no longer matches recorded provenance") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqualStrings("export Z=0\nexport A=1\nexport B=2\nexport C=3\n", try read(io, a, src_path));
    try std.testing.expectEqualStrings("export A=1\nexport B=2\nexport N=1\nexport C=3\n", try read(io, a, live));
}

test "commit: an insertion at the top refuses when the source line it precedes moved since apply" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_path = try h.srcOf(".zshrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src_path, .data = "export Z=0\nexport A=1\nexport B=2\n" });

    const live = try h.liveOf(".zshrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "export N=1\nexport A=1\nexport B=2\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "source no longer matches recorded provenance") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqualStrings("export Z=0\nexport A=1\nexport B=2\n", try read(io, a, src_path));
    try std.testing.expectEqualStrings("export N=1\nexport A=1\nexport B=2\n", try read(io, a, live));
}

test "commit: an insertion refuses when only the line it follows still matches a moved source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "a=1\n\nb=2\n\nc=3\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_path = try h.srcOf(".zshrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src_path, .data = "z=0\n\na=1\n\nb=2\n\nc=3\n" });

    const live = try h.liveOf(".zshrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "a=1\n\nb=2\n\nn=1\nc=3\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "source no longer matches recorded provenance") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqualStrings("z=0\n\na=1\n\nb=2\n\nc=3\n", try read(io, a, src_path));
}

test "commit: an insertion between lines of literal tags routes, both neighbours unchanged" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.pagerc", "<a><b>\nfoo\n</b></a>\nnnoremap <C-h><C-w>h\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".pagerc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "<a><b>\nbar\nfoo\n</b></a>\nbaz\nnnoremap <C-h><C-w>h\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("<a><b>\nbar\nfoo\n</b></a>\nbaz\nnnoremap <C-h><C-w>h\n", try read(io, a, try h.srcOf(".pagerc")));
}

test "commit: an insertion after a line whose capture default holds a > routes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myrc", "# top\n# mox: include \"extra.sh\"\n");
    try writeRepo(io, &tmp, "repo/src/.myrc.d/extra.sh", "alias x=1\nexport P=\"<machine.nosuchfield | default \"a>b\">\"\nalias y=2\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".myrc");
    try editLive(io, a, live, "alias y=2", "export NEW=1\nalias y=2");

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "commit", "--yes" })).rc);
    try std.testing.expectEqualStrings(
        "alias x=1\nexport P=\"<machine.nosuchfield | default \"a>b\">\"\nexport NEW=1\nalias y=2\n",
        try read(io, a, try h.srcOf(".myrc.d/extra.sh")),
    );
}

test "commit: an insertion after an interpolated fragment line routes into the fragment" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myrc", "# top\n# mox: include \"extra.sh\"\n# bottom\n");
    try writeRepo(io, &tmp, "repo/src/.myrc.d/extra.sh", "alias x=1\nexport P=<machine.profile | default \"work\">\nalias y=2\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".myrc");
    try editLive(io, a, live, "alias y=2", "export NEW=1\nalias y=2");

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "commit", "--yes" })).rc);
    try std.testing.expectEqualStrings(
        "alias x=1\nexport P=<machine.profile | default \"work\">\nexport NEW=1\nalias y=2\n",
        try read(io, a, try h.srcOf(".myrc.d/extra.sh")),
    );
}

test "commit: an insertion after an interpolated line of a structured base routes into it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/settings.toml", "a = 1\nprofile = \"<machine.profile | default \"work\">\"\nb = 2\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("settings.toml");
    try editLive(io, a, live, "b = 2", "c = 3\nb = 2");

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "commit", "--yes" })).rc);
    try std.testing.expectEqualStrings(
        "a = 1\nprofile = \"<machine.profile | default \"work\">\"\nc = 3\nb = 2\n",
        try read(io, a, try h.srcOf("settings.toml")),
    );
}

test "commit: an insertion at the top of an unchanged source lands first" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "export N=1\nexport A=1\nexport B=2\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("export N=1\nexport A=1\nexport B=2\n", try read(io, a, try h.srcOf(".zshrc")));
}

test "commit: a first-contact file's real edit routes into source preserving an adjacent capture, and a spurious hunk is skippable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.bashrc", "export A=1\n" ++
        "export PROFILE=<machine.profile | default \"work\">\n" ++
        "export C=3\n");
    const h = try setup(a, io, &tmp, .{});

    // No `mox apply` here: the repo has a source, but mox never wrote this
    // live path -- as if another tool (or a prior manual placement) put it
    // there. This is first contact: no applied record exists for it at all.
    const live = try h.liveOf(".bashrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "export A=11\n" ++
        "export PROFILE=work\n" ++
        "export C=3 \n" });

    // Two hunks: a real edit (A) and a spurious rendering difference (a
    // trailing space on C, the kind another tool's writer might leave). The
    // capture line is untouched, so it produces no hunk at all -- proving the
    // recompose preserved it rather than baking the resolved default in.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ns\n");
    _ = res;

    const src = try read(io, a, try h.srcOf(".bashrc"));
    try std.testing.expectEqualStrings("export A=11\n" ++
        "export PROFILE=<machine.profile | default \"work\">\n" ++
        "export C=3\n", src);

    // The declined (spurious) hunk stays as drift in the live file; the
    // routed edit did not touch it.
    try std.testing.expectEqualStrings("export A=11\n" ++
        "export PROFILE=work\n" ++
        "export C=3 \n", try read(io, a, live));
}

test "commit --yes on a first-contact file never silently routes a spurious hunk; it stays unresolved" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.bashrc", "export C=3\n");
    const h = try setup(a, io, &tmp, .{});

    // No `mox apply`: the repo has a source, but mox never wrote this live
    // path -- first contact. The only difference from the source is a
    // trailing space, the kind of rendering quirk another tool's writer
    // (e.g. a chezmoi-rendered live file during a migration) might leave.
    const live = try h.liveOf(".bashrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "export C=3 \n" });

    // `--yes` reads no input at all -- if this silently auto-accepted, the
    // process would need none, and the spurious hunk would land in source.
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // The hunk is a first-contact one, never a silent keep-all: nothing is
    // written to source, and the live file is untouched too.
    try std.testing.expectEqualStrings("export C=3\n", try read(io, a, try h.srcOf(".bashrc")));
    try std.testing.expectEqualStrings("export C=3 \n", try read(io, a, live));
}

test "commit --yes: a run whose every hunk is manual exits 1, the same code the identical state gets under --dry-run" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An interpolated line: manual by design, and nothing else in the file to
    // route -- so the run commits nothing and leaves the drift standing.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export HOST=<machine.hostname>\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export HOST=", "export HOSTNAME=");

    try std.testing.expectEqual(@as(u8, 1), (try h.run(&.{ "mox", "commit", "--dry-run" })).rc);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "came from a capture") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // What the exit code has to agree with: the drift the commit left behind.
    try std.testing.expectEqual(@as(u8, 1), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit --dry-run: a first-contact hunk is counted manual, the same way the --yes run counts it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.bashrc", "export C=3\n");
    const h = try setup(a, io, &tmp, .{});

    // No `mox apply`: a live path mox never wrote, holding a real edit that
    // would route on any other file.
    const live = try h.liveOf(".bashrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "export C=4\n" });

    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "first contact, needs confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "0 routable, 0 coupled, 1 manual") != null);
    try std.testing.expectEqual(@as(u8, 1), dry.rc);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    try std.testing.expectEqualStrings("export C=3\n", try read(io, a, try h.srcOf(".bashrc")));
}

test "commit --yes: a first-contact hunk in a multi-configuration file is manual, never routed into the shared source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The gated region gives the file a configuration space with more than one
    // member, so the base-line edit takes the "where does this belong?" route
    // -- the one path whose default `--yes` would otherwise take unasked.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export EDITOR=nvim\n" ++
        "# mox: when os=linux\n" ++
        "export L=1\n" ++
        "# mox: end\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    const live = try h.liveOf(".zshrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "export EDITOR=vim\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "first contact, needs confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    try std.testing.expectEqualStrings("export EDITOR=nvim\n" ++
        "# mox: when os=linux\n" ++
        "export L=1\n" ++
        "# mox: end\n", try read(io, a, try h.srcOf(".zshrc")));
}

test "commit: a first-contact structured file with no matching layer creates one, scoped to this machine, and routes the key into it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Only a linux overlay exists; this machine is darwin (pinned by
    // `setup`), so NO layer -- not even a base -- matches it: there is no
    // existing target to route a key change to at all.
    try writeRepo(io, &tmp, "repo/src/settings.toml.d/os=linux.toml", "theme = \"light\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    const live = try h.liveOf("settings.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "theme = \"dark\"\n" });

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") != null);

    const overlay = try h.srcOf("settings.toml.d/os=darwin");
    const overlay_src = try read(io, a, overlay);
    try std.testing.expect(std.mem.indexOf(u8, overlay_src, "theme") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay_src, "dark") != null);

    // The linux overlay is untouched by a darwin-scoped key placement.
    const linux_overlay = try h.srcOf("settings.toml.d/os=linux.toml");
    try std.testing.expectEqualStrings("theme = \"light\"\n", try read(io, a, linux_overlay));

    // Converges: the newly-created overlay now composes on this machine,
    // matching live.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit --yes: a first-contact structured file with no matching layer creates nothing, and --dry-run predicts that" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/settings.toml.d/os=linux.toml", "theme = \"light\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    const live = try h.liveOf("settings.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "theme = \"dark\"\n" });

    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "first contact, needs confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "0 routable, 0 coupled, 1 manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would create") == null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "first contact, needs confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expect(!exists(io, try h.srcOf("settings.toml.d/os=darwin")));
    try std.testing.expect(!exists(io, try h.srcOf("settings.toml.d/os=darwin.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.err, "no longer compose") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "1 hunk(s) could not be routed and remain only in the live file; not committed") != null);
}

test "commit --yes: a first-contact structured file with layers routes no key, and --dry-run predicts that" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/settings.toml", "theme = \"light\"\nsize = 1\n");
    try writeRepo(io, &tmp, "repo/src/settings.toml.d/os=darwin.toml", "size = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    const live = try h.liveOf("settings.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "theme = \"dark\"\nsize = 2\n" });

    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "first contact, needs confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "0 routable, 0 coupled, 1 manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would write") == null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "first contact, needs confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqualStrings("theme = \"light\"\nsize = 1\n", try read(io, a, try h.srcOf("settings.toml")));
    try std.testing.expectEqualStrings("size = 2\n", try read(io, a, try h.srcOf("settings.toml.d/os=darwin.toml")));
}

test "commit: a first-contact structured file with layers routes a key into source once confirmed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/settings.toml", "theme = \"light\"\nsize = 1\n");
    try writeRepo(io, &tmp, "repo/src/settings.toml.d/os=darwin.toml", "size = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    const live = try h.liveOf("settings.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "theme = \"dark\"\nsize = 2\n" });

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") != null);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("settings.toml")), "dark") != null);
}

test "commit: a layered key whose value holds a capture inside a literal <...> is not routed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "name = \"Me <<machine.os>>\"\nsize = 1\n";
    try writeRepo(io, &tmp, "repo/src/settings.toml", base);
    try writeRepo(io, &tmp, "repo/src/settings.toml.d/os=darwin.toml", "size = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("settings.toml");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "Me <darwin>") != null);
    try editLive(io, a, live, "Me <darwin>", "Me <home>");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf("settings.toml")));
}

test "commit: a layered value whose serialized form expands a capture past a literal chain is not routed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "name = \"<a | b | default \\\"1> <machine.os>\\\">\"\nsize = 1\n";
    try writeRepo(io, &tmp, "repo/src/settings.toml", base);
    try writeRepo(io, &tmp, "repo/src/settings.toml.d/os=darwin.toml", "size = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("settings.toml");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "1> darwin") != null);
    try editLive(io, a, live, "1> darwin", "9> darwin");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf("settings.toml")));
}

test "commit: a layered gitconfig value holding a defaulted capture is not routed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "[user]\n\temail = <machine.os | default \"x\">\n\tname = a\n";
    try writeRepo(io, &tmp, "repo/src/.gitconfig", base);
    try writeRepo(io, &tmp, "repo/src/.gitconfig.d/os=darwin", "[user]\n\tname = b\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".gitconfig");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "email = darwin") != null);
    try editLive(io, a, live, "email = darwin", "email = linux");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf(".gitconfig")));
}

test "commit: a layered toml key named by a capture is never written under its resolved name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "\"<machine.os>\" = \"a\"\nm = \"<machine.os>\"\nsize = 1\n";
    try writeRepo(io, &tmp, "repo/src/s.toml", base);
    try writeRepo(io, &tmp, "repo/src/s.toml.d/os=darwin.toml", "size = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("s.toml");
    try editLive(io, a, live, "\"darwin\" = \"a\"", "\"darwin\" = \"b\"");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "\"darwin\" = \"b\"") != null);
    try editLive(io, a, live, "m = \"darwin\"", "m = \"linux\"");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "m = \"linux\"") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") == null);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf("s.toml")));
}

test "commit: a layered toml table named by a capture is never written under its resolved name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "size = 1\n";
    try writeRepo(io, &tmp, "repo/src/s.toml", base);
    try writeRepo(io, &tmp, "repo/src/s.toml.d/os=darwin.toml", "m = \"<machine.os>\"\n\n[\"<machine.os>\"]\nk = \"a\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("s.toml");
    try editLive(io, a, live, "k = \"a\"", "k = \"b\"");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "k = \"b\"") != null);
    try editLive(io, a, live, "m = \"darwin\"", "m = \"linux\"");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "m = \"linux\"") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") == null);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf("s.toml")));
}

test "commit: a layered gitconfig subsection named by a capture is never written under its resolved name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "[url \"<machine.os>\"]\n\tinsteadOf = x\n[user]\n\temail = <machine.os>\n\tname = a\n";
    try writeRepo(io, &tmp, "repo/src/.gitconfig", base);
    try writeRepo(io, &tmp, "repo/src/.gitconfig.d/os=darwin", "[user]\n\tname = b\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".gitconfig");
    try editLive(io, a, live, "insteadOf = x", "insteadOf = y");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "insteadOf = y") != null);
    try editLive(io, a, live, "email = darwin", "email = linux");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "email = linux") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") == null);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf(".gitconfig")));
}

test "commit: a layered ini key is checked in the layer the merge took it from" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "[s]\nk = plain\nm = <machine.os>\n";
    try writeRepo(io, &tmp, "repo/src/s.ini", base);
    try writeRepo(io, &tmp, "repo/src/s.ini.d/os=darwin.ini", "[ s ]\nk = pre-<machine.os>\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("s.ini");
    try editLive(io, a, live, "k = pre-darwin", "k = post-darwin");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "k = post-darwin") != null);
    try editLive(io, a, live, "m = darwin", "m = linux");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "m = linux") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") == null);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf("s.ini")));
}

test "commit: an edit under a toml key named by a capture is refused as interpolation-derived" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "\"<machine.os>\" = \"a\"\nsize = 1\n";
    try writeRepo(io, &tmp, "repo/src/s.toml", base);
    try writeRepo(io, &tmp, "repo/src/s.toml.d/os=darwin.toml", "size = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("s.toml");
    try editLive(io, a, live, "\"darwin\" = \"a\"", "\"darwin\" = \"b\"");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "\"darwin\" = \"b\"") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "key is named by an interpolation capture") != null);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf("s.toml")));
}

test "commit: an edit under a json key named by a capture is refused as interpolation-derived" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "{\n  \"<machine.os>\": \"a\",\n  \"size\": 1\n}\n";
    try writeRepo(io, &tmp, "repo/src/s.json", base);
    try writeRepo(io, &tmp, "repo/src/s.json.d/os=darwin.json", "{\n  \"size\": 2\n}\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("s.json");
    try editLive(io, a, live, "\"darwin\": \"a\"", "\"darwin\": \"b\"");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "\"darwin\": \"b\"") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "key is named by an interpolation capture") != null);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf("s.json")));
}

test "commit: an edit under a yaml key named by a capture is refused as interpolation-derived" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "<machine.os>: a\nsize: 1\n";
    try writeRepo(io, &tmp, "repo/src/s.yaml", base);
    try writeRepo(io, &tmp, "repo/src/s.yaml.d/os=darwin.yaml", "size: 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("s.yaml");
    try editLive(io, a, live, "darwin: a", "darwin: b");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "darwin: b") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "key is named by an interpolation capture") != null);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf("s.yaml")));
}

test "commit: an edit under a gitconfig subsection named by a capture is refused as interpolation-derived" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "[url \"<machine.os>\"]\n\tinsteadOf = x\n[user]\n\tname = a\n";
    try writeRepo(io, &tmp, "repo/src/.gitconfig", base);
    try writeRepo(io, &tmp, "repo/src/.gitconfig.d/os=darwin", "[user]\n\tname = b\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".gitconfig");
    try editLive(io, a, live, "insteadOf = x", "insteadOf = y");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "insteadOf = y") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "key is named by an interpolation capture") != null);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf(".gitconfig")));
}

test "commit: a literal key beside one named by a capture still routes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "[t]\n\"<machine.os>\" = \"a\"\nplain = 1\n";
    try writeRepo(io, &tmp, "repo/src/s.toml", base);
    try writeRepo(io, &tmp, "repo/src/s.toml.d/os=darwin.toml", "size = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("s.toml");
    try editLive(io, a, live, "plain = 1", "plain = 5");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "plain = 5") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(!std.mem.eql(u8, base, try read(io, a, try h.srcOf("s.toml"))));
}

test "commit: an ini key under a padded section name is checked in the layer the merge took it from" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "[s]\nk = plain\n";
    try writeRepo(io, &tmp, "repo/src/s.ini", base);
    try writeRepo(io, &tmp, "repo/src/s.ini.d/os=darwin.ini", "[ s ]\nk = pre-<machine.os>\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("s.ini");
    try editLive(io, a, live, "k = pre-darwin", "k = post-darwin");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "k = post-darwin") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "value is interpolation- or secret-derived") != null);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf("s.ini")));
}

test "commit: an ini key under a padded section name routes to the layer the merge took it from" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/s.ini", "[s]\nk = plain\n");
    try writeRepo(io, &tmp, "repo/src/s.ini.d/os=darwin.ini", "[ s ]\nk = over\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("s.ini");
    try editLive(io, a, live, "k = over", "k = changed");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "k = changed") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[s]\nk = plain\n", try read(io, a, try h.srcOf("s.ini")));
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("s.ini.d/os=darwin.ini")), "k = changed") != null);
}

test "commit: a new toml key beside one named by a capture routes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/s.toml", "\"<machine.os>\" = \"a\"\nsize = 1\n");
    try writeRepo(io, &tmp, "repo/src/s.toml.d/os=darwin.toml", "size = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("s.toml");
    try editLive(io, a, live, "size = 2", "size = 2\nfresh = 7");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "fresh = 7") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("s.toml")), "fresh = 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("s.toml")), "<machine.os>") != null);
}

test "commit: a new gitconfig subsection beside one named by a capture is not refused as capture-named" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.gitconfig", "[includeIf \"gitdir:<machine.os>/work/\"]\n\tpath = w\n[user]\n\tname = a\n");
    try writeRepo(io, &tmp, "repo/src/.gitconfig.d/os=darwin", "[user]\n\tname = b\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".gitconfig");
    const before = try read(io, a, live);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = try std.mem.concat(a, u8, &.{ before, "[includeIf \"gitdir:~/oss/\"]\n\tpath = o\n" }) });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "named by an interpolation capture") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "write .gitconfig includeif.gitdir:~/oss/") != null);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf(".gitconfig")), "gitdir:<machine.os>/work/") != null);
}

test "commit: a key another layer defines literally routes beside a capture-named key" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.gitconfig", "[includeIf \"gitdir:<machine.os>/work/\"]\n\tpath = w\n");
    try writeRepo(io, &tmp, "repo/src/.gitconfig.d/os=darwin", "[includeIf \"gitdir:~/oss/\"]\n\tpath = o\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".gitconfig");
    try editLive(io, a, live, "path = o", "path = o2");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "path = o2") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf(".gitconfig.d/os=darwin")), "path = o2") != null);
}

test "commit: a first-contact structured file whose live copy cannot be parsed is a manual outcome at exit 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeRepo(io, &tmp, "repo/src/settings.toml.d/os=linux.toml", "theme = \"light\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    const live = try h.liveOf("settings.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "[[[not toml\n" });
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "could not be parsed as toml") != null);
    try std.testing.expect(!exists(io, try h.srcOf("settings.toml.d/os=darwin")));
}

test "commit: a first-contact structured file whose live copy holds no keys is nothing to commit, not a crash" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try writeRepo(io, &tmp, "repo/src/settings.toml.d/os=linux.toml", "theme = \"light\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    const live = try h.liveOf("settings.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "\n" });
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(!exists(io, try h.srcOf("settings.toml.d/os=darwin")));
}

test "commit: a narrowing whose fact value cannot name a fragment file is left uncommitted, and writes nowhere" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The shared line composes into several configurations (the profile
    // gate makes two), so commit asks where it belongs; `site` is bound to a
    // value that could only name a fragment by leaving the tree.
    try writeExistingRegionFixture(io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export EDITOR=vim\n# mox: when profile=work\nexport WORK=1\n# mox: end\n# mox: when site=\"../../escaped\"\nexport SITE=1\n# mox: end\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "profile = \"personal\"\nsite = \"../../escaped\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    const listing = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "?\nq\n");
    const mark = std.mem.indexOf(u8, listing.out, "] site=") orelse {
        std.debug.print("commit listed no site candidate:\n{s}\n{s}\n", .{ listing.out, listing.err });
        return error.NoSiteCandidate;
    };
    const answer = try std.fmt.allocPrint(a, "{c}\n", .{listing.out[mark - 1]});
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, answer);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "cannot name a fragment file") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "left uncommitted") != null);
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.root, "escaped" })));
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.repo, "escaped" })));
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf(".zshrc")), "export EDITOR=vim\n") != null);
}

test "commit: a hunk contained in one secret segment is shown without its old resolved value, and never routed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "token = \"<secret:env:MOX_TEST_TOKEN>\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    var h = try setup(a, io, &tmp, .{ .os = "darwin" });
    var map = std.process.Environ.Map.init(a);
    try map.put("HOME", h.home);
    try map.put("USER", "tester");
    try map.put("MOX_REPO", h.repo);
    try map.put("MOX_STATE_DIR", h.state);
    try map.put("MOX_OS", "darwin");
    try map.put("MOX_TEST_TOKEN", "s3cr3t");
    const map_ptr = try a.create(std.process.Environ.Map);
    map_ptr.* = map;
    h.env = .{ .map = map_ptr };

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "s3cr3t", "changed");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "s\n");

    // The new (live) value and the secret's store URI are shown -- but the
    // OLD resolved secret value never appears anywhere in the output, on
    // either stream.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "env:MOX_TEST_TOKEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "s3cr3t") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "s3cr3t") == null);

    // Nothing secret is written anywhere: the source keeps its directive
    // verbatim, never the resolved value in any form.
    const src = try read(io, a, try h.srcOf("config.toml"));
    try std.testing.expect(std.mem.indexOf(u8, src, "s3cr3t") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "changed") == null);
    try std.testing.expectEqualStrings("token = \"<secret:env:MOX_TEST_TOKEN>\"\n", src);
}

fn chmodPath(path: []const u8, mode: u32) void {
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    _ = std.c.chmod(@ptrCast(&zbuf), @intCast(mode));
}

test "commit: a coupling-graph persistence failure warns, but the commit itself still succeeds" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\nexport C=3\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".zshrc"), "export B=2", "export B=22");

    // An empty, read-only coupling dir: the pre-write loads see "nothing
    // recorded yet" (FileNotFound, tolerated), but the post-commit rebuild's
    // write into it is refused -- isolating the failure to the site under test.
    const coupling_dir = try std.fs.path.join(a, &.{ h.state, "coupling" });
    try Io.Dir.cwd().createDirPath(io, coupling_dir);
    chmodPath(coupling_dir, 0o500);
    defer chmodPath(coupling_dir, 0o700);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "mox commit: coupling graph not updated") != null);

    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expectEqualStrings("export A=1\nexport B=22\nexport C=3\n", src);
}

test "commit: fragment edit routes to the fragment file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myrc", "# top\n# mox: include \"extra.sh\"\n# bottom\n");
    try writeRepo(io, &tmp, "repo/src/.myrc.d/extra.sh", "alias x=1\nalias y=2\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".myrc");
    try editLive(io, a, live, "alias x=1", "alias x=111");

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "commit", "--yes" })).rc);

    // Fragment file changed; base file untouched.
    const frag = try read(io, a, try h.srcOf(".myrc.d/extra.sh"));
    try std.testing.expectEqualStrings("alias x=111\nalias y=2\n", frag);
    const base = try read(io, a, try h.srcOf(".myrc"));
    try std.testing.expectEqualStrings("# top\n# mox: include \"extra.sh\"\n# bottom\n", base);
}

test "commit: a fragment included twice and edited identically in both places lands once and commits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myrc", "# top\n# mox: include \"extra.sh\"\n# mid\n# mox: include \"extra.sh\"\n# bottom\n");
    try writeRepo(io, &tmp, "repo/src/.myrc.d/extra.sh", "alias x=1\nalias y=2\nalias z=3\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".myrc");
    try editLive(io, a, live, "alias x=1\n", "");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    const frag = try read(io, a, try h.srcOf(".myrc.d/extra.sh"));
    try std.testing.expectEqualStrings("alias y=2\nalias z=3\n", frag);
    const base = try read(io, a, try h.srcOf(".myrc"));
    try std.testing.expectEqualStrings("# top\n# mox: include \"extra.sh\"\n# mid\n# mox: include \"extra.sh\"\n# bottom\n", base);

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: edit to a line after a stripped pacifier routes to the right fragment line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The fragment leads with a shellcheck pacifier line that compose strips,
    // so emitted fragment lines are shifted by one relative to the source file.
    try writeRepo(io, &tmp, "repo/src/.myrc", "# top\n# mox: include \"extra.sh\"\n");
    try writeRepo(io, &tmp, "repo/src/.myrc.d/extra.sh", "# shellcheck disable=SC2034\nalias x=1\nalias y=2\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // Composed live is `# top\nalias x=1\nalias y=2\n` (pacifier stripped).
    const live = try h.liveOf(".myrc");
    try editLive(io, a, live, "alias y=2", "alias y=2-EDITED");

    const res = try h.run(&.{ "mox", "commit", "--yes" });

    // The edit must land on `alias y=2`, not clobber `alias x=1`, and the
    // untouched pacifier line must survive.
    const frag = try read(io, a, try h.srcOf(".myrc.d/extra.sh"));
    try std.testing.expectEqualStrings(
        "# shellcheck disable=SC2034\nalias x=1\nalias y=2-EDITED\n",
        frag,
    );
    // Recompose matches live, so commit reports success.
    try std.testing.expectEqual(@as(u8, 0), res.rc);
}

test "commit: a private-only file's edit lands in the private layer and leaves repo src byte-identical" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A repo-side base file (part of the src tree we must not touch) plus a
    // private-only base whose include pulls a fragment from the private layer.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    try writeRepo(io, &tmp, "state/private/.zsecret", "# mox: include \"frag.sh\"\n");
    try writeRepo(io, &tmp, "state/private/.zsecret.d/frag.sh", "secret_one\nsecret_two\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const live = try h.liveOf(".zsecret");
    try editLive(io, a, live, "secret_two", "secret_two_edited");

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "commit", "--yes" })).rc);

    // The ENTIRE repo src tree is byte-identical: no private content leaked.
    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);

    // The private fragment DID receive the edit.
    const frag = try read(io, a, try std.fs.path.join(a, &.{ h.state, "private", ".zsecret.d", "frag.sh" }));
    try std.testing.expectEqualStrings("secret_one\nsecret_two_edited\n", frag);
}

test "commit: loop-row edit updates only the changed field of one row" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".abbrs");
    try editLive(io, a, live, "git status", "git status -sb");

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "commit", "--yes" })).rc);

    const data = try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" }));
    // Only row 1's expansion changed; row 0 and the keys are byte-identical.
    try std.testing.expectEqualStrings(
        "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status -sb\"\n",
        data,
    );
}

test "commit: loop-row deletion routes to manual and leaves the data file untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    const data_orig = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n";
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", data_orig);
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".abbrs");
    // Delete the whole second row line.
    try editLive(io, a, live, "abbr gs=\"git status\"\n", "");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "manual") != null);

    // The data source is byte-identical: a deletion never wrote.
    const data = try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" }));
    try std.testing.expectEqualStrings(data_orig, data);
}

test "commit: loop-row insertion routes to manual and leaves the data file untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    const data_orig = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n";
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", data_orig);
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".abbrs");
    // Insert a new line that partially matches the template frame.
    try editLive(io, a, live, "abbr gs=\"git status\"\n", "abbr gs=\"git status\"\nabbr zz=\"echo hi\"\n");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "manual") != null);

    const data = try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" }));
    try std.testing.expectEqualStrings(data_orig, data);
}

test "commit: multi-line loop template edit routes to manual and leaves the data file untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A two-line loop body: the recorded template contains a newline, so no
    // single-line reverse-parse is possible.
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key>\n# note <entry.expansion>\n# mox: end\n");
    const data_orig = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n";
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", data_orig);
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".abbrs");
    try editLive(io, a, live, "abbr ll", "abbr LL");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "manual") != null);

    const data = try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" }));
    try std.testing.expectEqualStrings(data_orig, data);
}

test "commit: secret-line edit is reported manual and leaves sources untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.secretrc", "# mox: secret \"env:MOX_TEST_SECRET\"\n");
    var h = try setup(a, io, &tmp, .{});
    // Re-build env with the secret variable present for resolution.
    var map = std.process.Environ.Map.init(a);
    try map.put("HOME", h.home);
    try map.put("USER", "tester");
    try map.put("MOX_REPO", h.repo);
    try map.put("MOX_STATE_DIR", h.state);
    try map.put("MOX_TEST_SECRET", "hunter2");
    const map_ptr = try a.create(std.process.Environ.Map);
    map_ptr.* = map;
    h.env = .{ .map = map_ptr };

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_path = try h.srcOf(".secretrc");
    const src_before = try read(io, a, src_path);

    const live = try h.liveOf(".secretrc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "leaked-edit\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    // A secret-origin hunk routes nowhere: reported manual, source unchanged.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "manual") != null);
    const src_after = try read(io, a, src_path);
    try std.testing.expectEqualStrings(src_before, src_after);
}

test "commit: an inline <secret:URI> line edit is reported manual and leaves sources untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.inlinerc", "export TOKEN=<secret:env:MOX_TEST_SECRET>\n");
    var h = try setup(a, io, &tmp, .{});
    var map = std.process.Environ.Map.init(a);
    try map.put("HOME", h.home);
    try map.put("USER", "tester");
    try map.put("MOX_REPO", h.repo);
    try map.put("MOX_STATE_DIR", h.state);
    try map.put("MOX_TEST_SECRET", "hunter2");
    const map_ptr = try a.create(std.process.Environ.Map);
    map_ptr.* = map;
    h.env = .{ .map = map_ptr };

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_path = try h.srcOf(".inlinerc");
    const src_before = try read(io, a, src_path);

    const live = try h.liveOf(".inlinerc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "export TOKEN=leaked-edit\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    // The inline-secret line is `.secret` provenance: routes nowhere, reported
    // manual, and the source is left exactly as written.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "manual") != null);
    try std.testing.expectEqualStrings(src_before, try read(io, a, src_path));
}

/// A fragment conditionally included for profile=personal (this machine's own
/// value), crossed against a second axis (os) so the FILE's own configuration
/// space includes an os=linux+profile=personal sibling the edit also reaches,
/// alongside os=*+profile=work siblings it does not -- a genuine subset,
/// entirely derived from the source, no census involved.
fn writeSubsetImpactFixture(io: Io, tmp: *std.testing.TmpDir, frag_content: []const u8) !void {
    try writeRepo(io, tmp, "repo/src/.zshrc", "export SHARED=1\n" ++
        "# mox: when os=linux\n" ++
        "export PLATFORM=linux\n" ++
        "# mox: end\n" ++
        "# mox: include \"p.sh\" when profile=personal\n" ++
        "# mox: include \"w.sh\" when profile=work\n");
    try writeRepo(io, tmp, "repo/src/.zshrc.d/p.sh", frag_content);
    try writeRepo(io, tmp, "repo/src/.zshrc.d/w.sh", "alias other=x\n");
    // Deterministic profile fact so the test behaves identically on any host.
    try writeRepo(io, tmp, "home/.config/mox/facts.toml", "profile = \"personal\"\n");
}

test "commit: subset-impact shared edit reports the candidate set and writes nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSubsetImpactFixture(io, &tmp, "alias foo=bar\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "alias foo=bar", "alias foo=baz");

    // Non-TTY, no --yes: report mode prints the analysis and writes nothing.
    const res = try h.run(&.{ "mox", "commit" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "universal") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "profile=personal") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "private") != null);

    // The transient impact simulation restored the fragment: nothing written.
    try std.testing.expectEqualStrings("alias foo=bar\n", try read(io, a, try h.srcOf(".zshrc.d/p.sh")));
}

test "commit: impact simulation leaves the whole source tree byte-identical" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSubsetImpactFixture(io, &tmp, "alias foo=bar\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "alias foo=bar", "alias foo=baz");

    // Report mode still runs the transient impact simulation (classifyLine
    // simulates before it checks report_mode), so this exercises the write and
    // restore around a real edit on a real source file.
    const res = try h.run(&.{ "mox", "commit" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // Every byte of the source tree -- base AND both fragments -- is restored.
    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "commit: a coupled token change updates the other consumer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two managed sources share the same email token.
    try writeRepo(io, &tmp, "repo/src/.myenv", "email = old@example.com\n");
    try writeRepo(io, &tmp, "repo/src/.mysigners", "old@example.com signing\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    // Seed the coupling graph over both sources.
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    const live = try h.liveOf(".myenv");
    try editLive(io, a, live, "old@example.com", "new@example.com");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "update") != null);

    // Both the edited source and the coupled source now hold the new token.
    try std.testing.expectEqualStrings("email = new@example.com\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expectEqualStrings("new@example.com signing\n", try read(io, a, try h.srcOf(".mysigners")));
}

test "commit: a declined coupled token is left unchanged" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "email = old@example.com\n");
    try writeRepo(io, &tmp, "repo/src/.mysigners", "old@example.com signing\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    // A global decline for the token suppresses the coupling prompt entirely.
    const coupling_dir = try std.fs.path.join(a, &.{ h.state, "coupling" });
    var d = mox.coupling.decline.DeclineList.init(a);
    try d.declineGlobal("old@example.com");
    try mox.coupling.store.saveDeclines(a, io, coupling_dir, &d);

    const live = try h.liveOf(".myenv");
    try editLive(io, a, live, "old@example.com", "new@example.com");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The primary edit landed; the coupled source was left untouched.
    try std.testing.expectEqualStrings("email = new@example.com\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expectEqualStrings("old@example.com signing\n", try read(io, a, try h.srcOf(".mysigners")));
}

test "commit: a coupled update that would diverge an unaffected configuration is undone and its target restored, and its origin commits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // File A: a plain shared base holding the coupled token (universal).
    try writeRepo(io, &tmp, "repo/src/.zshrc", "email = shared@old.example\n");
    // File B: the SAME token, but inside an os=linux-gated block, with an
    // os=windows block that never holds it. This machine's own os (darwin)
    // matches neither, so its own compose of B never shows the token -- but
    // B's own configuration space (built from its own two `when os=...`
    // blocks) includes an os=linux sibling that DOES, and an os=windows
    // sibling that does not: a genuine subset, not "every configuration".
    try writeRepo(io, &tmp, "repo/src/.gitconfig", "signingkey = personal-key\n" ++
        "# mox: when os=linux\n" ++
        "backup_signingkey = shared@old.example\n" ++
        "# mox: end\n" ++
        "# mox: when os=windows\n" ++
        "backup_signingkey = none\n" ++
        "# mox: end\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    const gitconfig_src = try h.srcOf(".gitconfig");
    const b_before = try read(io, a, gitconfig_src);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "shared@old.example", "shared@new.example");

    // --yes accepts the coupling propagation into B. Verification must catch
    // that renaming the os=linux case changes a configuration the user never
    // chose to affect (the os=windows case is a sibling too, and does NOT
    // change, so this is a genuine subset): the coupled update is undone,
    // naming the configuration, never a machine id, and B restored.
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("mox commit: coupled update to ~/.gitconfig undone: ~/.gitconfig could not take it (configuration os=linux would change)\n", res.err);

    // B's source is byte-identical: the unsafe coupling edit was rolled back.
    try std.testing.expectEqualStrings(b_before, try read(io, a, gitconfig_src));
    // The origin's own edit does not depend on the coupled update: it stays
    // committed.
    try std.testing.expectEqualStrings("email = shared@new.example\n", try read(io, a, try h.srcOf(".zshrc")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.zshrc") != null);
}

test "commit: dry-run writes neither the routed nor the coupled edit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "email = old@example.com\n");
    try writeRepo(io, &tmp, "repo/src/.mysigners", "old@example.com signing\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    const live = try h.liveOf(".myenv");
    try editLive(io, a, live, "old@example.com", "new@example.com");

    _ = try h.run(&.{ "mox", "commit", "--dry-run" });
    // Single write pass, gated behind every prompt: dry-run writes nothing.
    try std.testing.expectEqualStrings("email = old@example.com\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expectEqualStrings("old@example.com signing\n", try read(io, a, try h.srcOf(".mysigners")));
}

test "commit: capstone - candidate set, then verified subset commit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSubsetImpactFixture(io, &tmp, "alias longfoo=longbar\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "alias longfoo=longbar", "alias longfoo=longbaz");

    // Report mode lists the computed candidate set for the subset-impact edit.
    const report = try h.run(&.{ "mox", "commit" });
    try std.testing.expectEqual(@as(u8, 1), report.rc);
    try std.testing.expect(std.mem.indexOf(u8, report.out, "universal") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.out, "profile=personal") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.out, "private") != null);

    // --yes takes the universal default. The edit changes only the
    // os=linux+profile=personal sibling; verification confirms every other
    // configuration composes unchanged, so the commit succeeds and the
    // fragment is written.
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("alias longfoo=longbaz\n", try read(io, a, try h.srcOf(".zshrc.d/p.sh")));
}

test "commit: non-TTY report mode reports a pending coupling update and exits 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "email = old@example.com\n");
    try writeRepo(io, &tmp, "repo/src/.mysigners", "old@example.com signing\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    const live = try h.liveOf(".myenv");
    try editLive(io, a, live, "old@example.com", "new@example.com");

    // Non-TTY, no --yes: pure report mode. The routed rename has a coupled
    // consumer; report mode must surface it and exit 1, writing nothing.
    const res = try h.run(&.{ "mox", "commit" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, ".mysigners") != null);

    // Neither source was written.
    try std.testing.expectEqualStrings("email = old@example.com\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expectEqualStrings("old@example.com signing\n", try read(io, a, try h.srcOf(".mysigners")));
}

test "commit: non-TTY report mode exits 1 and writes nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_path = try h.srcOf(".zshrc");
    const src_before = try read(io, a, src_path);
    const applied_before = (try mox.apply.applied.readContent(a, io, h.state, try h.liveOf(".zshrc"))).?;

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export B=2", "export B=22");

    // No --yes and a non-TTY stdin: pure report mode.
    const res = try h.run(&.{ "mox", "commit" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // Source bytes unchanged and the applied record was not advanced.
    try std.testing.expectEqualStrings(src_before, try read(io, a, src_path));
    const applied_after = (try mox.apply.applied.readContent(a, io, h.state, try h.liveOf(".zshrc"))).?;
    try std.testing.expectEqualStrings(applied_before, applied_after);
}

/// A shared base line (`export EDITOR=vim`, top-level, so it composes into
/// every configuration) in a file whose own directives gate on `os`, giving it
/// a configuration space of {os=darwin, os=linux}. The shared line sits BELOW
/// line 1, so narrowing it is a legal region synthesis.
fn writeSharedBaseFixture(io: Io, tmp: *std.testing.TmpDir) !void {
    try writeRepo(io, tmp, "repo/src/.zshrc", "export SHELL_OK=1\n" ++
        "export EDITOR=vim\n" ++
        "# mox: when os=darwin\n" ++
        "export BREW=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "export APT=1\n" ++
        "# mox: end\n");
}

/// Compose the fixture's `.zshrc` under a single axis binding, so a test can
/// prove a configuration OTHER than this machine's recomposes byte-identically.
fn composeZshrcUnder(a: std.mem.Allocator, io: Io, h: Harness, axis: []const u8, value: []const u8) !?[]const u8 {
    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const tree = try mox.source.tree.walk(a, io, src_dir, h.home);
    var bindings = std.StringHashMap([]const u8).init(a);
    var bindings_r: mox.dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put(axis, value);
    for (tree.files) |f| {
        if (!std.mem.endsWith(u8, f.live_path, ".zshrc")) continue;
        return try mox.compose.composeFile(a, io, f, &bindings_r, null, null);
    }
    return error.FixtureFileMissing;
}

test "commit: a shared base-line edit asks where it belongs instead of committing universally on its own" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    // Scripted terminal, answering with the default (universal). The edit
    // changes every configuration this file has, which is exactly the case the
    // command used to decide by itself: it must ASK, because whether the line
    // is universal or belongs to one axis is an intent only the user holds.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "1\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The candidate list really was rendered: universal first, then the axis
    // the source compares by value, then machine-local, then private.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[1] universal") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[2] os=") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "only here") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[4] private") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "choose>") != null);
    // The impact is reported, but as information, not as the decision.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "changes every configuration") != null);

    // Choice 1 keeps the edit at its origin: the base line.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "export EDITOR=nvim") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "mox: replace from") == null);
}

test "commit: --yes commits a shared base-line edit universally; --abort-on-prompt exits 2 and writes nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    // Strict CI on a terminal: the intent question is a prompt, so it aborts
    // with rc 2 and writes nothing at all.
    const strict = try h.runWithInput(&.{ "mox", "commit", "--abort-on-prompt" }, "1\n");
    try std.testing.expectEqual(@as(u8, 2), strict.rc);
    const after_strict = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after_strict);

    // --yes takes the default, which is universal: the edit lands on the base
    // line, unnarrowed.
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("export SHELL_OK=1\n" ++
        "export EDITOR=nvim\n" ++
        "# mox: when os=darwin\n" ++
        "export BREW=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "export APT=1\n" ++
        "# mox: end\n", try read(io, a, try h.srcOf(".zshrc")));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: a region-fragment edit in a multi-configuration file commits and writes the fragment" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The design's flagship construct: a Cat B `replace from` region whose
    // fragment is picked by profile, in a file that ALSO gates on os -- so the
    // file's own configuration space is the {os} x {profile} cross product and
    // the edited fragment feeds a sibling configuration (the other os, same
    // profile) as well as this machine's own.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export SHARED=1\n" ++
        "# mox: replace from \"profile\"\n" ++
        "export KEY=fallback\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "export PLATFORM=linux\n" ++
        "# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.zshrc.d/profile/personal.zshrc", "export KEY=personal\n");
    try writeRepo(io, &tmp, "repo/src/.zshrc.d/profile/work.zshrc", "export KEY=work\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "profile = \"personal\"\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // Guard the fixture: the composed live file really did come from the
    // personal fragment, so the edit below routes to a region fragment.
    const live = try h.liveOf(".zshrc");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "export KEY=personal") != null);

    try editLive(io, a, live, "export KEY=personal", "export KEY=personal-edited");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    // An axis-gated fragment edit makes no classification choice, so no
    // configuration was "not chosen": the verification guard must not fire.
    try std.testing.expect(std.mem.indexOf(u8, res.err, "did not choose to affect") == null);
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The edit landed in the personal fragment; the work fragment and the base
    // are untouched.
    try std.testing.expectEqualStrings("export KEY=personal-edited\n", try read(io, a, try h.srcOf(".zshrc.d/profile/personal.zshrc")));
    try std.testing.expectEqualStrings("export KEY=work\n", try read(io, a, try h.srcOf(".zshrc.d/profile/work.zshrc")));

    // The applied record and provenance advanced: nothing is left drifting.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: a loop-row edit in a multi-configuration file updates the data source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The loop body is universal, but the file also carries an os-gated block,
    // so its configuration space has a sibling configuration whose compose the
    // row edit legitimately changes too.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "# mox: for entry in \"data/abbrs.toml\"\n" ++
        "abbr <entry.key>=\"<entry.expansion>\"\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "alias apt=\"sudo apt\"\n" ++
        "# mox: end\n");
    const data_before = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n";
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", data_before);
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "git status", "git status -sb");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    // A loop-row edit makes no classification choice either.
    try std.testing.expect(std.mem.indexOf(u8, res.err, "did not choose to affect") == null);
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    const data = try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" }));
    try std.testing.expectEqualStrings(
        "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status -sb\"\n",
        data,
    );

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: the candidate prompt drives a non-default choice, and a non-base narrowing writes nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The subset-impact fixture: editing the profile=personal fragment reaches
    // only the profile=personal half of the {os} x {profile} space, so
    // classification cannot decide alone and prompts with the candidate list.
    try writeSubsetImpactFixture(io, &tmp, "alias foo=bar\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "alias foo=bar", "alias foo=baz");

    // Scripted terminal, non-default answer: "3" is the profile axis candidate
    // (the list is universal, os=<this os>, profile=personal, machine, private).
    // Without the scripted stdin this run would be report-only and never reach
    // a choice at all. The hunk stays only in live, so the run exits 1.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "3\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // The prompt really was rendered and really did take choice 3: the axis it
    // names is the one that candidate stands for, and the hunk was left
    // uncommitted rather than routed to its origin.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[3] profile=personal") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "no automatic route to profile=personal") != null);
    // Choice 1 (universal, the --yes default) would have routed the hunk to its
    // origin and reported one committed file; choice 3 commits nothing.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed") != null);

    // A narrowing with no automatic route writes nothing at all: the whole
    // source tree -- base, both fragments, the data-free `.d/` -- is byte-equal.
    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "commit: does not read or write the machines directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try setup(a, io, &tmp, .{ .create_repo_src = true });
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const machines = try std.fs.path.join(a, &.{ h.repo, "machines" });
    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export A=1", "export A=2");

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "commit", "--yes" })).rc);

    // Neither apply nor commit ever creates it.
    try std.testing.expect(!exists(io, machines));
}

test "commit: narrowing a shared base line to an axis materializes the region and leaves every other configuration byte-identical" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The one configuration the user will NOT choose to affect, composed from
    // the pre-commit source.
    const other_before = (try composeZshrcUnder(a, io, h, "os", "linux")).?;

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    // Choice 2 is the axis candidate for this machine's own os.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "synthesize os=") != null);

    // The base now wraps the ORIGINAL line in an os region; the edit lives in
    // the axis fragment.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "# mox: replace from \"os\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "export EDITOR=vim\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "export EDITOR=nvim") == null);

    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const frag = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/os/{s}", .{m_state.os}));
    try std.testing.expectEqualStrings("export EDITOR=nvim\n", try read(io, a, frag));

    // This machine's live edit is reflected in the source: recompose == live,
    // so the applied record advanced and nothing is left drifting.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);

    // The configuration the user did not choose composes exactly as before.
    const other_after = (try composeZshrcUnder(a, io, h, "os", "linux")).?;
    try std.testing.expectEqualStrings(other_before, other_after);
}

test "commit: a narrowing that would change an unchosen configuration is rejected and fully rolled back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The fixture, plus a leftover fragment in the `os` region directory that
    // no directive references yet. Narrowing a base line to `os` synthesizes a
    // `replace from "os"` region, and THAT region resolves the leftover for the
    // os=linux configuration -- a configuration the user never chose to affect.
    try writeSharedBaseFixture(io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc.d/os/linux", "export EDITOR=vim-linux\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "os=linux") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "did not choose to affect") != null);

    // "Not committed" left nothing behind: the base is byte-identical and the
    // synthesized fragment is gone, so the whole source tree hashes as before.
    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const frag = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/os/{s}", .{m_state.os}));
    try std.testing.expect(!exists(io, frag));
    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

/// A file that ALREADY owns an `os` region (with its `.d/os/` fragments) and a
/// `profile` gate, plus a shared base line above both. Fragments for BOTH os
/// values exist, so whichever os this machine runs, the region resolves.
fn writeExistingRegionFixture(io: Io, tmp: *std.testing.TmpDir) !void {
    try writeRepo(io, tmp, "repo/src/.zshrc", "export SHELL_OK=1\n" ++
        "export EDITOR=vim\n" ++
        "# mox: replace from \"os\"\n" ++
        "export PAGER=less\n" ++
        "# mox: end\n" ++
        "# mox: when profile=work\n" ++
        "export WORK=1\n" ++
        "# mox: end\n");
    try writeRepo(io, tmp, "repo/src/.zshrc.d/os/darwin", "export PAGER=darwin-pager\n");
    try writeRepo(io, tmp, "repo/src/.zshrc.d/os/linux", "export PAGER=linux-pager\n");
    try writeRepo(io, tmp, "home/.config/mox/facts.toml", "profile = \"personal\"\n");
}

test "commit: narrowing to an axis the file already has a region for is refused, leaving that region's fragments intact" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Region fragments are keyed by region NAME, so a SECOND `os` region would
    // share `.d/os/` with the one already here: the fragment synthesized for the
    // shared base line would be picked up by the existing region too, replacing
    // its body on every machine matching that os.
    try writeExistingRegionFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);
    const base_before = try read(io, a, try h.srcOf(".zshrc"));

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    // Choice 2 is the os axis candidate -- the axis this file already has a
    // region for.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[2] os=") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "already has a region named \"os\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "left uncommitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed") != null);

    // The base is byte-identical: no second region was wrapped around the line.
    try std.testing.expectEqualStrings(base_before, try read(io, a, try h.srcOf(".zshrc")));

    // The existing region's fragments are untouched -- above all the one named
    // for THIS machine's os, which is exactly the path the synthesized fragment
    // would have overwritten.
    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const mine = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/os/{s}", .{m_state.os}));
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, mine), "PAGER=") != null);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, mine), "EDITOR") == null);

    // And nothing else was written anywhere in the source tree.
    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "commit: narrowing to an axis the file has no region for still synthesizes one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Same file, same shared base line -- but narrowed to `profile`, a region
    // the file does not have. The collision guard must not fire: refusing every
    // narrowing in a file that happens to hold SOME region would destroy the
    // feature.
    try writeExistingRegionFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    // Choice 3 is the profile axis candidate (universal, os, profile, machine,
    // private).
    const res = try h.runWithInput(&.{ "mox", "commit" }, "3\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[3] profile=personal") != null);
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The profile region was synthesized around the original line, and the edit
    // lives in its fragment.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "# mox: replace from \"profile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "export EDITOR=vim\n") != null);
    try std.testing.expectEqualStrings("export EDITOR=nvim\n", try read(io, a, try h.srcOf(".zshrc.d/profile/personal")));

    // The pre-existing os region is untouched, and this machine's compose now
    // matches its source: nothing is left drifting.
    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const mine = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/os/{s}", .{m_state.os}));
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, mine), "PAGER=") != null);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: a leftover fragment at the exact synthesis path is refused, its content and the base left untouched" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});

    // A leftover fragment already sits at the exact path this machine's os
    // narrowing would write -- no directive claims the "os" region yet, so
    // nothing composes it and nothing warns it is there.
    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const leftover_sub = try std.fmt.allocPrint(a, "repo/src/.zshrc.d/os/{s}", .{m_state.os});
    try writeRepo(io, &tmp, leftover_sub, "leftover, unclaimed by any directive\n");
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);
    const base_before = try read(io, a, try h.srcOf(".zshrc"));
    const leftover_abs = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/os/{s}", .{m_state.os}));
    const leftover_before = try read(io, a, leftover_abs);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    // Choice 2 is the os axis candidate for this machine's own os -- exactly
    // the path the leftover fragment already occupies.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "already exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "left uncommitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed") != null);

    // Neither the base nor the leftover fragment's content was touched: no
    // silent data loss.
    try std.testing.expectEqualStrings(base_before, try read(io, a, try h.srcOf(".zshrc")));
    try std.testing.expectEqualStrings(leftover_before, try read(io, a, leftover_abs));
    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "commit: narrowing succeeds end-to-end when no fragment sits at the write path yet" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const frag = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/os/{s}", .{m_state.os}));
    try std.testing.expect(!exists(io, frag));

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    // A blanket refusal (an over-eager hazard) must not fire here: the write
    // path is free, so the narrowing commits normally.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "already exists") == null);
    try std.testing.expectEqualStrings("export EDITOR=nvim\n", try read(io, a, frag));
}

test "commit: narrowing a shebang line is refused, leaving the script and its whole-file gate intact" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A whole-file gate on line 2, so line 1 can stay the shebang. The gate
    // owns every line below it, so the shebang is the file's ONLY routable base
    // line -- and wrapping it in a region would push it off line 1 and displace
    // the gate from the top of the file, silently disabling it.
    try writeRepo(io, &tmp, "repo/src/.myscript.sh", "#!/bin/sh\n" ++
        "# mox: when not os=windows and (profile=personal or profile=work)\n" ++
        "echo hello\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "profile = \"personal\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const live = try h.liveOf(".myscript.sh");
    try editLive(io, a, live, "#!/bin/sh", "#!/bin/bash");

    // Choice 2 is the os axis candidate: the narrowing that would corrupt it.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "cannot wrap the first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "left uncommitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed") != null);

    // The source is untouched: no region wraps the shebang, and no fragment was
    // written anywhere under the source tree.
    const src = try read(io, a, try h.srcOf(".myscript.sh"));
    try std.testing.expect(std.mem.startsWith(u8, src, "#!/bin/sh\n"));
    try std.testing.expect(std.mem.indexOf(u8, src, "mox: replace from") == null);
    const frag_dir = try h.srcOf(".myscript.sh.d");
    try std.testing.expect(!exists(io, frag_dir));
    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "commit: narrowing a shared base line synthesizes a region on a shebang-bearing, extensionless base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No dot anywhere in the basename, so `markerForExtension` has no entry --
    // only the shebang signals the comment marker. Mirrors
    // `writeSharedBaseFixture` (a shared line above two `os`-gated branches),
    // which proves the "os" axis and its values come from the directive scan
    // itself, not a pre-existing `.d/` overlay.
    try writeRepo(io, &tmp, "repo/src/myscript", "#!/bin/sh\n" ++
        "echo SHELL_OK=1\n" ++
        "echo EDITOR=vim\n" ++
        "# mox: when os=darwin\n" ++
        "echo BREW=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "echo APT=1\n" ++
        "# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("myscript");
    try editLive(io, a, live, "echo EDITOR=vim", "echo EDITOR=nvim");

    // Choice 2 is the os axis candidate for this machine's own os (darwin).
    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[2] os=darwin") != null);
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    const src = try read(io, a, try h.srcOf("myscript"));
    try std.testing.expect(std.mem.indexOf(u8, src, "# mox: replace from \"os\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "echo EDITOR=vim\n") != null);
    try std.testing.expectEqualStrings("echo EDITOR=nvim\n", try read(io, a, try h.srcOf("myscript.d/os/darwin")));
}

test "commit: a narrowing on a base with no extension, shebang, or apparent directive is still refused for an unknown marker" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No extension, no shebang, and no apparent `# mox:` line anywhere in the
    // base -- every resolution path `markerForFile` tries comes up empty, so
    // the refusal must still fire. The "os" axis is established the same way
    // as the success case above, via a sibling region fragment.
    try writeRepo(io, &tmp, "repo/src/plainconfig", "greeting: hello\n" ++
        "farewell: bye\n");
    try writeRepo(io, &tmp, "repo/src/plainconfig.d/os/windows", "greeting: hi\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const live = try h.liveOf("plainconfig");
    try editLive(io, a, live, "greeting: hello", "greeting: hi there");

    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[2] os=darwin") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "unknown comment marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "left uncommitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed") != null);

    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

/// Two non-adjacent shared base lines (`export EDITOR`, `export PAGER`) in a
/// file whose own directives gate on `os`: editing both live lines yields TWO
/// hunks routed to the SAME base file, each independently classifiable.
fn writeTwoSharedBaseFixture(io: Io, tmp: *std.testing.TmpDir) !void {
    try writeRepo(io, tmp, "repo/src/.zshrc", "export SHELL_OK=1\n" ++
        "export EDITOR=vim\n" ++
        "export MIDDLE=1\n" ++
        "export PAGER=less\n" ++
        "# mox: when os=darwin\n" ++
        "export BREW=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "export APT=1\n" ++
        "# mox: end\n");
}

test "commit: a universal hunk and a narrowed hunk in the same file both land" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeTwoSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");
    try editLive(io, a, live, "export PAGER=less", "export PAGER=more");

    // Hunk 1 stays universal, hunk 2 is narrowed to this machine's os. The
    // narrowing rewrites the base, so it must compose ONTO the base the
    // universal edit just landed in -- not over a snapshot taken before it.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "1\n2\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    const src = try read(io, a, try h.srcOf(".zshrc"));
    // The universal edit survived the synthesis.
    try std.testing.expect(std.mem.indexOf(u8, src, "export EDITOR=nvim") != null);
    // The narrowed line was wrapped: its ORIGINAL text is the region's fallback
    // body, and the region directive is there.
    try std.testing.expect(std.mem.indexOf(u8, src, "# mox: replace from \"os\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "export PAGER=less") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "export PAGER=more") == null);

    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const frag = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/os/{s}", .{m_state.os}));
    try std.testing.expectEqualStrings("export PAGER=more\n", try read(io, a, frag));

    // Both edits are reflected in what this machine composes: nothing drifts.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);

    // The configuration the user did not narrow to keeps the universal edit and
    // the region's fallback body.
    const other = (try composeZshrcUnder(a, io, h, "os", "linux")).?;
    try std.testing.expect(std.mem.indexOf(u8, other, "export EDITOR=nvim") != null);
    try std.testing.expect(std.mem.indexOf(u8, other, "export PAGER=less") != null);
}

test "commit: a second narrowing to an axis this same run already claimed is refused, leaving nothing behind" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeTwoSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");
    try editLive(io, a, live, "export PAGER=less", "export PAGER=more");

    // Two narrowings to the SAME axis are unrepresentable: both regions would be
    // named "os" and share `.d/os/`, so the second fragment would overwrite the
    // first. The second must be refused, exactly as if the region were already on
    // disk -- and refusing it leaves the file unroutable, so nothing is written.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n2\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "left uncommitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed") != null);
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // Nothing corrupt on disk: no region wraps either line, no fragment was
    // written, and the whole source tree is byte-identical.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "mox: replace from") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "export EDITOR=vim") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "export PAGER=less") != null);
    try std.testing.expect(!exists(io, try h.srcOf(".zshrc.d")));
    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "commit: a routed file whose recompose still differs from live is restored, fragment and region dir and all" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two shared base lines. The first is narrowed to this machine's os -- a
    // region and a fragment are written. The second is sent to the private
    // layer, which has no automatic route: it stays uncommitted, so the file
    // cannot recompose to live. Nothing about that difference is EXPECTED (no
    // hunk of this file went manual), so the routing is rejected after the
    // write and everything it wrote must come back off the disk.
    try writeTwoSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);
    const base_before = try read(io, a, try h.srcOf(".zshrc"));

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");
    try editLive(io, a, live, "export PAGER=less", "export PAGER=more");

    // Choice 2 narrows the first hunk to this machine's os; choice 4 sends the
    // second to the private layer, which cannot be routed to.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n4\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "left uncommitted") != null);
    // The diagnostic names the cause: a hunk that never reached a source, not a
    // bare "output differs".
    try std.testing.expect(std.mem.indexOf(u8, res.err, "1 hunk(s) were left uncommitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "not committed") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed") != null);

    // "Not committed" left nothing behind: the base is byte-identical, and the
    // fragment and the region directory the synthesis created are gone.
    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const frag = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/os/{s}", .{m_state.os}));
    try std.testing.expect(!exists(io, frag));
    try std.testing.expect(!exists(io, try h.srcOf(".zshrc.d/os")));
    try std.testing.expect(!exists(io, try h.srcOf(".zshrc.d")));
    try std.testing.expectEqualStrings(base_before, try read(io, a, try h.srcOf(".zshrc")));
    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "commit: --abort-on-prompt exits 2 off a terminal too, and writes nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    // No scripted stdin: a real CI run, where the command is NOT on a terminal.
    // A prompt is still what this hunk needs, so strict CI must exit 2 -- the
    // exit code is about the prompt, not about the terminal.
    const res = try h.run(&.{ "mox", "commit", "--abort-on-prompt" });
    try std.testing.expectEqual(@as(u8, 2), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "a prompt was required") != null);

    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "commit: narrowing to this machine uses the machine axis's first-label value, even when the raw hostname carries a dot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The raw hostname on macOS always ends in `.local`, but the `machine`
    // axis binds only its first label (network-volatile suffixes never
    // matter), so a fragment named for it carries no dot even on such a
    // host: the machine-local candidate mox offers in every prompt must
    // still resolve, using the same first-label value everywhere.
    try writeSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The configuration the narrowing must NOT reach: another machine's.
    const other_before = (try composeZshrcUnder(a, io, h, "os", "linux")).?;

    const live = try h.liveOf(".zshrc");
    const live_before = try read(io, a, live);
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    // Choice 3 is the machine-local candidate ("only here").
    const res = try h.runWithInput(&.{ "mox", "commit" }, "3\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "still differs from live") == null);

    // The base wraps the ORIGINAL line in a `machine` region; the edit lives in
    // a fragment named for this machine's first-label value.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "# mox: replace from \"machine\"") != null);
    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const machine_value = mox.machine.bindings.firstLabel(m_state.hostname);
    const frag = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/machine/{s}", .{machine_value}));
    try std.testing.expectEqualStrings("export EDITOR=nvim\n", try read(io, a, frag));

    // The region resolves for THIS machine: recompose == live, so the applied
    // record advanced and nothing drifts.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
    try std.testing.expectEqualStrings(
        try std.mem.replaceOwned(u8, a, live_before, "export EDITOR=vim", "export EDITOR=nvim"),
        try read(io, a, live),
    );

    // "Only here" means only here: another machine's configuration is byte-identical.
    const other_after = (try composeZshrcUnder(a, io, h, "os", "linux")).?;
    try std.testing.expectEqualStrings(other_before, other_after);
}

test "commit: narrowing to an axis whose value contains a dot commits and resolves" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The dotted-value case with no dependence on what this host is called: a
    // custom fact whose value has a dot in it, compared by the source, so it is
    // offered as an axis candidate.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export SHELL_OK=1\n" ++
        "export EDITOR=vim\n" ++
        "# mox: when site=tokyo.example\n" ++
        "export SITE=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=darwin\n" ++
        "export BREW=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "export APT=1\n" ++
        "# mox: end\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "site = \"tokyo.example\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    // [1] universal [2] os=<mine> [3] site=tokyo.example [4] machine [5] private
    const res = try h.runWithInput(&.{ "mox", "commit" }, "3\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "synthesize site=tokyo.example") != null);
    try std.testing.expectEqualStrings(
        "export EDITOR=nvim\n",
        try read(io, a, try h.srcOf(".zshrc.d/site/tokyo.example")),
    );
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: an extension-bearing fragment still resolves by its stem" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Preferring an exact filename match must not stop a fragment named
    // `<value>.<ext>` from standing for `<value>`: the axis value is `darwin`,
    // the file on disk is `darwin.sh`, and it still has to resolve.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export SHARED=1\n" ++
        "# mox: replace from \"os\"\n" ++
        "export PLATFORM=other\n" ++
        "# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.zshrc.d/os/darwin.sh", "export PLATFORM=darwin\n");
    try writeRepo(io, &tmp, "repo/src/.zshrc.d/os/linux.sh", "export PLATFORM=linux\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const live = try h.liveOf(".zshrc");
    const want = try std.fmt.allocPrint(a, "export SHARED=1\nexport PLATFORM={s}\n", .{m_state.os});
    try std.testing.expectEqualStrings(want, try read(io, a, live));

    // And an edit to that composed line still routes back into the fragment it
    // came from, extension and all.
    const from = try std.fmt.allocPrint(a, "export PLATFORM={s}", .{m_state.os});
    const to = try std.fmt.allocPrint(a, "export PLATFORM={s}-edited", .{m_state.os});
    try editLive(io, a, live, from, to);
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    const frag = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/os/{s}.sh", .{m_state.os}));
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "export PLATFORM={s}-edited\n", .{m_state.os}),
        try read(io, a, frag),
    );
}

test "commit: a data-interpolated line is reported manual and left in source verbatim" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `<data.FILE.KEY>` capture expands from a committed data file. The
    // resulting live line is manual BY DESIGN (like `<machine.X>`): an edit to
    // it has no route back into source, and the capture must survive verbatim.
    try writeRepo(io, &tmp, "repo/data/signing.toml", "pub = \"AAAApub\"\n");
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export PLAIN=1\n" ++
        "export KEY=<data.signing.pub>\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    // The capture expanded on apply.
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "export KEY=AAAApub") != null);

    try editLive(io, a, live, "export KEY=AAAApub", "export KEY=EDITED");
    const res = try h.run(&.{ "mox", "commit", "--yes" });

    // The edit over an interpolated line has no route back into source: it is
    // reported manual, and nothing is committed.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    // The source keeps the literal capture, not the expanded/edited value.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "export KEY=<data.signing.pub>") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "EDITED") == null);
}

test "commit: an interpolated machine-fact edit routes to facts.toml, never to src, when the user picks [f]" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `.gitconfig` composes structurally (Cat A, whole-file merge) and never
    // attributes `.interpolated` provenance per line; `.zshrc` is Cat B
    // (line/directive-based), matching every other interpolation test here.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n" ++
        "export EMAIL=<machine.email | default \"nobody@example.com\">\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "email = \"old@home.com\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "export EMAIL=old@home.com") != null);
    try editLive(io, a, live, "export EMAIL=old@home.com", "export EMAIL=new@work.com");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "f\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "This value comes from machine.email.") != null);

    // The fact carries the new value...
    const facts = try read(io, a, try h.homePath(".config/mox/facts.toml"));
    try std.testing.expect(std.mem.indexOf(u8, facts, "email = \"new@work.com\"") != null);
    // ...and the source template is untouched, byte for byte: [f] never
    // writes to repo src.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expectEqualStrings(
        "export A=1\nexport EMAIL=<machine.email | default \"nobody@example.com\">\n",
        src,
    );

    // Recompose (with the newly-written fact) matches live: status is clean.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: an interpolated machine-fact edit rewrites the source default when the user picks [d]" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n" ++
        "export EMAIL=<machine.email | default \"nobody@example.com\">\n");
    // No facts.toml: the default is what is actually in effect.
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "export EMAIL=nobody@example.com") != null);
    try editLive(io, a, live, "export EMAIL=nobody@example.com", "export EMAIL=team@work.com");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "d\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The source default carries the new value...
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expectEqualStrings(
        "export A=1\nexport EMAIL=<machine.email | default \"team@work.com\">\n",
        src,
    );
    // ...and no fact was ever written.
    try std.testing.expect(!exists(io, try h.homePath(".config/mox/facts.toml")));

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: a multi-capture interpolated line with an ambiguous change falls back to manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two captures on one line; the hand-edit changes BOTH values, so which
    // one the edit is "about" cannot be told apart. Never guess: manual.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n" ++
        "export WHO=<machine.email> and <machine.profile>\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "email = \"a@x.com\"\nprofile = \"alice\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "export WHO=a@x.com and alice") != null);
    try editLive(io, a, live, "export WHO=a@x.com and alice", "export WHO=b@y.com and bob");

    // No hunk was routed at all (nothing to verify a recompose against), so
    // this matches the sibling "data-interpolated" manual test: only the
    // output and the untouched sources are asserted, not the exit code.
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);

    // Nothing written: the source keeps both literal captures, and neither
    // fact changed.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expectEqualStrings(
        "export A=1\nexport WHO=<machine.email> and <machine.profile>\n",
        src,
    );
    const facts = try read(io, a, try h.homePath(".config/mox/facts.toml"));
    try std.testing.expectEqualStrings("email = \"a@x.com\"\nprofile = \"alice\"\n", facts);
}

test "commit: a shared fact survives when a file that also routed it is independently rejected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two managed files both interpolate the same machine.email fact. .bashrc
    // is a plain single-configuration file: its [f] choice has nothing else
    // to fail on. .zshrc additionally has a shared EDITOR line that the user
    // routes to the private layer -- no automatic route, so THAT file's
    // routing is rejected for a reason that has nothing to do with the fact.
    try writeRepo(io, &tmp, "repo/src/.bashrc", "export A=1\n" ++
        "export EMAIL=<machine.email | default \"nobody@example.com\">\n");
    // EDITOR and EMAIL are kept non-adjacent (a spacer line between them) so
    // their edits form two independent hunks rather than one straddling hunk.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export SHELL_OK=1\n" ++
        "export EDITOR=vim\n" ++
        "export SPACER=1\n" ++
        "export EMAIL=<machine.email | default \"nobody@example.com\">\n" ++
        "# mox: when os=darwin\n" ++
        "export BREW=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "export APT=1\n" ++
        "# mox: end\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "email = \"old@home.com\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const bashrc_live = try h.liveOf(".bashrc");
    const zshrc_live = try h.liveOf(".zshrc");
    try editLive(io, a, bashrc_live, "export EMAIL=old@home.com", "export EMAIL=shared@new.com");
    try editLive(io, a, zshrc_live, "export EDITOR=vim", "export EDITOR=nvim");
    try editLive(io, a, zshrc_live, "export EMAIL=old@home.com", "export EMAIL=shared@new.com");

    // .bashrc: [f]. .zshrc: EDITOR to the private layer (candidate 4: universal,
    // axis(os), machine-local, private), then EMAIL's [f].
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "f\n4\nf\n");

    // .zshrc's routing was rejected (the EDITOR hunk never reached a source),
    // so the overall run reports a failure.
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, ".zshrc") != null);

    // .bashrc committed the shared fact...
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") != null);
    // ...and .zshrc's rejection must not pull that fact out from under it: the
    // new value survives, not the pre-run one.
    const facts = try read(io, a, try h.homePath(".config/mox/facts.toml"));
    try std.testing.expectEqualStrings("email = \"shared@new.com\"\n", facts);

    // .bashrc's own recompose (using the surviving fact) still matches live.
    const bashrc_src = try read(io, a, try h.srcOf(".bashrc"));
    try std.testing.expectEqualStrings(
        "export A=1\nexport EMAIL=<machine.email | default \"nobody@example.com\">\n",
        bashrc_src,
    );
    // .zshrc's own sources are untouched: [f] never writes src, and the
    // private-routed EDITOR hunk never had anywhere to go.
    const zshrc_src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, zshrc_src, "export EDITOR=vim\n") != null);
}

test "commit: an interpolated fact edit whose new value has a control character is classified manual outright" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n" ++
        "export EMAIL=<machine.email | default \"nobody@example.com\">\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "email = \"old@home.com\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "export EMAIL=old@home.com") != null);
    // A raw tab in the new value could never be persisted as a fact: it would
    // break facts.toml's own line-oriented format. This is what a fixed
    // classifier must catch BEFORE offering [f], not what `persist` catches
    // after the fact (literally) once other sources may already be written.
    try editLive(io, a, live, "export EMAIL=old@home.com", "export EMAIL=new\tvalue");

    // "f" is fed as if the user tried to route it to the fact anyway. If the
    // hunk is still classified `.fact`, this selects [f] and (pre-fix) the
    // write phase crashes on `persist`. If it is classified `.manual` (only
    // [m]/[s] on offer), "f" matches neither and the prompt loop runs out of
    // input, aborting cleanly -- proving [f] was never reachable.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "f\n");

    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: aborted; no changes written") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "This value comes from machine.email.") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "InvalidFactValue") == null);

    // Nothing was written anywhere: not the fact, not the source.
    const facts = try read(io, a, try h.homePath(".config/mox/facts.toml"));
    try std.testing.expectEqualStrings("email = \"old@home.com\"\n", facts);
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expectEqualStrings(
        "export A=1\nexport EMAIL=<machine.email | default \"nobody@example.com\">\n",
        src,
    );
}

test "commit: a fact interpolated in a multi-configuration file allowlists the sibling it actually affects and commits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `.interpolated` provenance is only ever emitted for an UNGATED base
    // line (a `# mox: when` body composes structurally instead), so EMAIL
    // here is universal: os=linux (the file's only other configuration)
    // recomposes differently once the fact changes. The single-config
    // sibling test above never exercises `simulateFactImpact` at all (its
    // file has no other configuration to allowlist); this one does, and the
    // file must still commit -- not be rejected for "changing a
    // configuration you did not choose to affect".
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export SHELL_OK=1\n" ++
        "export EMAIL=<machine.email | default \"nobody@example.com\">\n" ++
        "# mox: when os=darwin\n" ++
        "export BREW=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "export APT=1\n" ++
        "# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "export EMAIL=nobody@example.com") != null);
    try editLive(io, a, live, "export EMAIL=nobody@example.com", "export EMAIL=team@work.com");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "f\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    const facts = try read(io, a, try h.homePath(".config/mox/facts.toml"));
    try std.testing.expect(std.mem.indexOf(u8, facts, "email = \"team@work.com\"") != null);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: firstViolation still aborts an unintended configuration change in one file alongside a legitimate multi-configuration fact commit in another" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // .bashrc: the same multi-configuration fact edit as the sibling test
    // above -- its own os=linux sibling is legitimately allowlisted and it
    // commits. .zshrc: the leftover-fragment narrowing hazard, unrelated to
    // any fact, that must still be caught. Two different files' allowed
    // sets must never bleed into each other: the fact correctly widening
    // .bashrc's own allowlist must not excuse .zshrc's unintended change.
    try writeRepo(io, &tmp, "repo/src/.bashrc", "export SHELL_OK=1\n" ++
        "export EMAIL=<machine.email | default \"nobody@example.com\">\n" ++
        "# mox: when os=darwin\n" ++
        "export BREW=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "export APT=1\n" ++
        "# mox: end\n");
    try writeSharedBaseFixture(io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc.d/os/linux", "export EDITOR=vim-linux\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const zshrc_before = try read(io, a, try h.srcOf(".zshrc"));

    const bashrc_live = try h.liveOf(".bashrc");
    try editLive(io, a, bashrc_live, "export EMAIL=nobody@example.com", "export EMAIL=team@work.com");
    const zshrc_live = try h.liveOf(".zshrc");
    try editLive(io, a, zshrc_live, "export EDITOR=vim", "export EDITOR=nvim");

    // .bashrc: [f]. .zshrc: candidate 2 (narrow to os), which the leftover
    // fragment turns into an unintended os=linux change.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "f\n2\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "os=linux") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "did not choose to affect") != null);

    // .bashrc's fact commit stands...
    const facts = try read(io, a, try h.homePath(".config/mox/facts.toml"));
    try std.testing.expect(std.mem.indexOf(u8, facts, "email = \"team@work.com\"") != null);
    // ...and .zshrc's rejected narrowing left its source untouched.
    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const frag = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/os/{s}", .{m_state.os}));
    try std.testing.expect(!exists(io, frag));
    try std.testing.expectEqualStrings(zshrc_before, try read(io, a, try h.srcOf(".zshrc")));
}

test "commit: a routable hunk still commits when the same file has a manual hunk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The most ordinary mixed edit there is: one plain base line and one line
    // that came from `<machine.X>` interpolation, which is manual BY DESIGN. A
    // manual hunk means the recompose is EXPECTED to still differ from live, so
    // it must not take the routed edit down with it.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n" ++
        "export MIDDLE=1\n" ++
        "export HOST=<machine.hostname>\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export A=1", "export A=2");
    try editLive(io, a, live, "export HOST=", "export HOSTNAME=");

    const res = try h.run(&.{ "mox", "commit", "--yes" });

    // The routable edit is IN the source, not announced and then reverted.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "export A=2") != null);
    // The base's interpolated line is untouched: it never had a route.
    try std.testing.expect(std.mem.indexOf(u8, src, "export HOST=<machine.hostname>") != null);

    // The report is coherent: the manual hunk is named, the commit is counted,
    // and the message says what is left to do instead of "output differs".
    try std.testing.expect(std.mem.indexOf(u8, res.out, "came from a capture") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 1 routed, 0 coupled, 1 manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "1 hunk(s) could not be routed") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "run 'mox apply'") != null);
    // Edits remain, so the exit code says so.
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // The applied record did NOT advance: the unroutable hunk is still real
    // drift, and `mox status` keeps reporting it.
    try std.testing.expectEqual(@as(u8, 1), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: a routable hunk still commits when the same file has a declined hunk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Declining a hunk (`s`) is an ordinary, designed action, just like a
    // manual hunk: the recompose is EXPECTED to still differ from live, so it
    // must not take the ACCEPTED hunk down with it. Two plain base lines, no
    // axis anywhere, so both hit the [y/s/x] prompt directly.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n" ++
        "export MIDDLE=1\n" ++
        "export B=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export A=1", "export A=2");
    try editLive(io, a, live, "export B=1", "export B=2");

    // First hunk accepted (y), second declined (s, skip).
    const res = try h.runWithInput(&.{ "mox", "commit" }, "y\ns\n");

    // The accepted edit is IN the source, not announced and then reverted.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "export A=2") != null);
    // The declined edit never reached the source.
    try std.testing.expect(std.mem.indexOf(u8, src, "export B=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "export B=2") == null);

    // The report is coherent: the decline is named, the commit is counted,
    // and the message says how to discard it instead of "output differs".
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 1 routed, 0 coupled, 0 manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "1 hunk(s) were declined") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "run 'mox apply'") != null);
    // Edits remain, so the exit code says so.
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // The applied record did NOT advance: the declined hunk is still real
    // drift, and `mox status` keeps reporting it.
    try std.testing.expectEqual(@as(u8, 1), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: a routed hunk's interactive prompt shows a self-explaining header and legend" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export A=1", "export A=2");

    // --color=never for deterministic bytes: the header, diff, and legend
    // must all read without ANSI escapes getting in the way of the check.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The header names the hunk's position and where it routes -- no need to
    // cross-reference the diff to know what "y" commits to.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "hunk 1/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "src/.zshrc (base)") != null);
    // Not a doubled "src/src/..." prefix.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "src/src/") == null);
    // The legend is self-explaining: every key names its own action.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[Y]es") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[s]kip") != null);
    // No split: this hunk lies inside one segment, so there is nothing to
    // split at, and the legend only offers what the hunk can actually do.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[x] split") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[?]help") != null);
    // The end summary reports the routed/coupled/manual counts.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 1 routed, 0 coupled, 0 manual") != null);
}

test "commit: ? at the per-hunk prompt prints help for every choice, then re-asks" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export A=1", "export A=2");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "?\ny\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The help block explains each key; the edit still commits ("y" after).
    try std.testing.expect(std.mem.indexOf(u8, res.out, "route this edit into its source") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "skip -- leave the drift") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "split -- break this hunk into per-source pieces") == null);
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "export A=2") != null);
}

test "commit: a hunk straddling two provenance segments splits and routes each piece to its own source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Composed live is exactly two lines: "# top" (base) then "alias x=1"
    // (the included fragment's content, replacing the directive line). With
    // no context line between them, editing both forms ONE diff hunk that
    // spans a base segment and a fragment segment -- a straddle `routeHunk`
    // alone cannot route.
    try writeRepo(io, &tmp, "repo/src/.myrc", "# top\n# mox: include \"extra.sh\"\n");
    try writeRepo(io, &tmp, "repo/src/.myrc.d/extra.sh", "alias x=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".myrc");
    try editLive(io, a, live, "# top", "# TOP");
    try editLive(io, a, live, "alias x=1", "alias x=111");

    // Without splitting this whole hunk would be reported manual (see the
    // sibling non-interactive assertion below). Interactively: "x" splits it,
    // then "y" accepts each of the two resulting per-source pieces.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "x\ny\ny\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // Both pieces landed in their own source.
    const base = try read(io, a, try h.srcOf(".myrc"));
    try std.testing.expectEqualStrings("# TOP\n# mox: include \"extra.sh\"\n", base);
    const frag = try read(io, a, try h.srcOf(".myrc.d/extra.sh"));
    try std.testing.expectEqualStrings("alias x=111\n", frag);

    // The file routed (both pieces landed); the straddle did not fall back to
    // manual (contrast the non-interactive sibling test below: "1 manual").
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 1 routed, 0 coupled, 0 manual") != null);

    // Recompose now matches live exactly: status is clean.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: a straddling hunk left unsplit is reported manual, non-interactively" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myrc", "# top\n# mox: include \"extra.sh\"\n");
    try writeRepo(io, &tmp, "repo/src/.myrc.d/extra.sh", "alias x=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".myrc");
    try editLive(io, a, live, "# top", "# TOP");
    try editLive(io, a, live, "alias x=1", "alias x=111");

    const res = try h.run(&.{ "mox", "commit", "--yes" });

    try std.testing.expect(std.mem.indexOf(u8, res.out, "hunk straddles origins or is uncovered") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    const base = try read(io, a, try h.srcOf(".myrc"));
    try std.testing.expectEqualStrings("# top\n# mox: include \"extra.sh\"\n", base);
    const frag = try read(io, a, try h.srcOf(".myrc.d/extra.sh"));
    try std.testing.expectEqualStrings("alias x=1\n", frag);
}

test "commit: a routed hunk is not offered a split it could never perform" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export A=1", "export A=2");

    // A hunk only reaches a routed prompt when it lies inside ONE provenance
    // segment, so there is nothing to split at. Offering `x` there advertised
    // an operation that silently just routed the hunk instead.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "split") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 1 routed, 0 coupled, 0 manual") != null);
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "export A=2") != null);
}

test "commit: --color=always colors the per-hunk mini-diff and header" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export A=1", "export A=2");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=always" }, "y\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\x1b[31m") != null); // removed line, red
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\x1b[32m") != null); // added line, green
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\x1b[1m") != null); // bold path/keys
}

test "commit: the summary counts nothing as committed when the routing was rejected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The rejected-narrowing fixture: the synthesized `os` region resolves a
    // leftover fragment for os=linux, a configuration the user never chose, so
    // verification rejects the routing and rolls it back.
    try writeSharedBaseFixture(io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc.d/os/linux", "export EDITOR=vim-linux\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EDITOR=vim", "export EDITOR=nvim");

    const res = try h.runWithInput(&.{ "mox", "commit" }, "2\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "not committed") != null);
    // The summary must not claim a commit the command refused to make.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") == null);
}

test "commit: a coupled edit to a file that is not committed is rolled back with it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note os=darwin\n");
    try writeRepo(io, &tmp, "repo/src/.config/x.toml", "# mox: when os=darwin\nkey = \"v\"\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".myenv"), "os=darwin", "os=linux");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".config/x.toml"), .data = "[[[not toml\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("# mox: when os=darwin\nkey = \"v\"\n# mox: end\n", try read(io, a, try h.srcOf(".config/x.toml")));
}

test "commit: a manual-only file that took a coupled edit is not reported committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkatoken\n");
    try writeRepo(io, &tmp, "repo/src/.config/x.toml", "# mox: when os=darwin\n# quokkatoken\nkey = \"v\"\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".myenv"), "quokkatoken", "wombattoken");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".config/x.toml"), .data = "[[[not toml\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.config/x.toml") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 1 coupled, 1 manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "x.toml: 1 hunk(s) could not be routed and remain only in the live file; not committed") != null);
}

test "commit: a coupled token update reaches a source gated off this machine" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkatoken\n");
    try writeRepo(io, &tmp, "repo/src/.config/x.toml", "# mox: when os=linux\n# quokkatoken\nkey = \"v\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".myenv"), "quokkatoken", "wombattoken");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "uncomposable") == null);
    try std.testing.expectEqualStrings("# mox: when os=linux\n# wombattoken\nkey = \"v\"\n", try read(io, a, try h.srcOf(".config/x.toml")));
}

test "commit: a coupled token update that changes only some configurations a file exists in is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkatoken\n");
    const gated = "always\n# mox: when os=linux\n# quokkatoken\n# mox: end\n";
    try writeRepo(io, &tmp, "repo/src/.config/x.conf", gated);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".myenv"), "quokkatoken", "wombattoken");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqualStrings("mox commit: coupled update to ~/.config/x.conf undone: ~/.config/x.conf could not take it (configuration os=linux would change)\n", res.err);
    try std.testing.expectEqualStrings(gated, try read(io, a, try h.srcOf(".config/x.conf")));
}

test "commit: a coupled token update that breaks a source where it exists is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkatoken\n");
    const gated = "# mox: when os=linux\nquokkatoken = 1\nwombattoken = 2\n";
    try writeRepo(io, &tmp, "repo/src/.config/x.toml", gated);
    try writeRepo(io, &tmp, "repo/src/.config/x.toml.d/os=linux.toml", "z = 1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".myenv"), "quokkatoken", "wombattoken");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("mox commit: coupled update to ~/.config/x.toml undone: ~/.config/x.toml could not take it (configuration os=linux would be unable to compose)\n", res.err);
    try std.testing.expectEqualStrings(gated, try read(io, a, try h.srcOf(".config/x.toml")));
}

test "commit: a coupled token in a symlink target or seed-once body is not rewritten" {
    // The symlink source is materialized live during apply; needs symlink support.
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A plain edited source and two soon-to-be-protected sources all carry one
    // token. The `mylink`/`seed.local` sources start as PLAIN files so the
    // coupling graph indexes them; they only become a symlink target and a
    // seed-once body afterward, leaving the on-disk graph stale. The commit-time
    // protection (from the live tree) must still refuse to sync the token into
    // them -- exercising the reader-skip against a stale graph, not just the
    // builder-skip.
    try writeRepo(io, &tmp, "repo/src/.myenv", "email = old@example.com\n");
    // The whole symlink target is the shared token (a path separator is itself a
    // token char, so an embedded token would not be isolated).
    try writeRepo(io, &tmp, "repo/src/mylink", "old@example.com\n");
    try writeRepo(io, &tmp, "repo/src/seed.local", "email = old@example.com\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    // Build the coupling graph while all three are plain: it genuinely indexes
    // the mylink and seed.local bodies (an occurrence of the token in each).
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    // Now mark the two as protected. The stored graph is stale: it still holds
    // occurrences in what is now a symlink target and a seed body.
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml",
        \\["mylink"]
        \\symlink = true
        \\
        \\["seed.local"]
        \\seed_once = true
        \\
    );

    const link_src = try h.srcOf("mylink");
    const seed_src = try h.srcOf("seed.local");
    const link_before = try read(io, a, link_src);
    const seed_before = try read(io, a, seed_src);

    const live = try h.liveOf(".myenv");
    try editLive(io, a, live, "old@example.com", "new@example.com");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The edit landed in the plain source; neither now-protected source was
    // touched, even though the stale graph still couples the token across them.
    try std.testing.expectEqualStrings("email = new@example.com\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expectEqualStrings(link_before, try read(io, a, link_src));
    try std.testing.expectEqualStrings(seed_before, try read(io, a, seed_src));
    // The reader-skip means they are never even offered/announced -- without it
    // `--yes` would print "update <...mylink>" before the write-filter dropped it.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mylink") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "seed.local") == null);
}

test "commit: a path argument limits routing to that file, leaving another drifted file alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    try writeRepo(io, &tmp, "repo/src/.bashrc", "export B=1\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const zshrc_live = try h.liveOf(".zshrc");
    const bashrc_live = try h.liveOf(".bashrc");
    try editLive(io, a, zshrc_live, "export A=1", "export A=11");
    try editLive(io, a, bashrc_live, "export B=1", "export B=11");

    const res = try h.run(&.{ "mox", "commit", "--yes", zshrc_live });
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The scoped file's edit landed in its source.
    try std.testing.expectEqualStrings("export A=11\n", try read(io, a, try h.srcOf(".zshrc")));
    // The out-of-scope file was never routed: its source is untouched, and its
    // live edit still shows as drift.
    try std.testing.expectEqualStrings("export B=1\n", try read(io, a, try h.srcOf(".bashrc")));
    const st = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, st.out, "DRIFT") != null);
    try std.testing.expect(std.mem.indexOf(u8, st.out, ".bashrc") != null);
}

test "commit: a path-scoped commit skips cross-file coupling" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two managed sources share the same email token.
    try writeRepo(io, &tmp, "repo/src/.myenv", "email = old@example.com\n");
    try writeRepo(io, &tmp, "repo/src/.mysigners", "old@example.com signing\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    // Seed the coupling graph over both sources.
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    const live = try h.liveOf(".myenv");
    try editLive(io, a, live, "old@example.com", "new@example.com");

    // Scoped to the edited file only: the routed edit lands, but the coupling
    // pass that would offer to update .mysigners never runs.
    const res = try h.run(&.{ "mox", "commit", "--yes", live });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, ".mysigners") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 coupled") != null);

    // The scoped edit landed; the coupled source was never touched.
    try std.testing.expectEqualStrings("email = new@example.com\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expectEqualStrings("old@example.com signing\n", try read(io, a, try h.srcOf(".mysigners")));
}

test "commit: an unmanaged path argument exits non-zero reporting not managed, commits nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export A=1", "export A=11");

    const nope = try h.liveOf(".nope");
    const res = try h.run(&.{ "mox", "commit", "--yes", nope });
    try std.testing.expect(res.rc != 0);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "not managed") != null);
    // Untouched: the edit is still only in the live file.
    try std.testing.expectEqualStrings("export A=1\n", try read(io, a, try h.srcOf(".zshrc")));
}

test "commit: structured overlay-won key routes [y] to the winning overlay layer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nfont = \"mono\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    const apply_res = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), apply_res.rc);

    // Composed live: theme won by the darwin overlay (dark), font from base.
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The edit landed in the winning overlay, not the base.
    try std.testing.expectEqualStrings("theme = \"solarized\"\n", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
    try std.testing.expectEqualStrings("theme = \"light\"\nfont = \"mono\"\n", try read(io, a, try h.srcOf("config.toml")));

    const st = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 0), st.rc);
}

test "commit: a structured key prompt shows the old and new values" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nfont = \"mono\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    // The prompt itself must show what accepting trades: the last-applied
    // value out, the live value in, in canonical rendering.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "s\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "- \"dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "+ \"solarized\"") != null);
}

test "commit partial: the per-key prompt shows the record and live values" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writePartialRepo(io, &tmp, "# mox: own tui\n[tui]\nsubmit = \"enter\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("app.toml");
    try editLive(io, a, live, "submit = \"enter\"", "submit = \"ctrl-enter\"");

    // Old side from the owned record's canonical blob, new from live.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "s\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "- \"enter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "+ \"ctrl-enter\"") != null);
}

test "commit: structured key [s] skip leaves the source untouched and the file uncommitted" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nfont = \"mono\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    const res = try h.runWithInput(&.{ "mox", "commit" }, "s\n");
    // A skipped key stays only in live: the file is not committed (rc 1).
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("theme = \"dark\"\n", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));

    // `processStructFile` marks the file affected the instant a key changes,
    // even a skipped one, so it still reaches the recompose-verify guard --
    // but nothing was actually routed, so the guard must not report this file
    // as committed: no "committed" line, no phantom "routed" count, and no
    // instruction to run 'mox apply' to discard edits that were never written.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 0 manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "1 hunk(s) were declined") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "not committed") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "run 'mox apply'") == null);
}

test "commit: a routed structured key still commits when the same file has a skipped key" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nfont = \"mono\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    // Two independently routable keys: the overlay-won `theme` and the
    // base-only `font`. One is accepted, the other skipped.
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");
    try editLive(io, a, live, "\"mono\"", "\"sans\"");

    const res = try h.runWithInput(&.{ "mox", "commit" }, "y\ns\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // Keys are prompted in document order, so `y` took `theme` and `s` left
    // `font`. Pinning WHICH key landed is the point: an inversion routing the
    // skipped key and skipping the accepted one is the bug this guards.
    try std.testing.expectEqualStrings("theme = \"solarized\"\n", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
    try std.testing.expectEqualStrings("theme = \"light\"\nfont = \"mono\"\n", try read(io, a, try h.srcOf("config.toml")));

    // A real routed edit exists for this file, so the guard's mixed-file
    // reporting -- "committed", the routed count, and the "run 'mox apply' to
    // discard them" wording -- still applies exactly as it does for a
    // partially-declined line-hunk file.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  committed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled, 0 manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "1 hunk(s) were declined") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "run 'mox apply' to discard them") != null);
}

test "commit: structured new key [y] routes to the base layer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    // Append a brand-new key that no layer defines.
    const cur = try read(io, a, live);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = try std.fmt.allocPrint(a, "{s}font = \"mono\"\n", .{cur}) });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    // The new key lands in the base, not the overlay.
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("config.toml")), "font = \"mono\"") != null);
    try std.testing.expectEqualStrings("theme = \"dark\"\n", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
}

test "commit: structured [p] to base promotes the key and drops the overriding entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nfont = \"mono\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    // [p] then candidate 1 (base), then confirm: the base is what a machine
    // running an os this repo never names composes, so the promote reaches it.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n1\ny\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "os=(other): light -> solarized") != null);

    // Base now holds the promoted value; the overriding overlay entry is gone.
    try std.testing.expectEqualStrings("theme = \"solarized\"\nfont = \"mono\"\n", try read(io, a, try h.srcOf("config.toml")));
    try std.testing.expectEqualStrings("", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));

    const st = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 0), st.rc);
}

test "commit: structured [p] to a middle layer places there and deletes the more specific override" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin+profile=work.toml", "theme = \"work\"\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "profile = \"work\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"work\"", "\"solarized\"");

    // Layers listed least-specific-first: [1]=base, [2]=os=darwin, [3]=os=darwin+profile=work.
    // Pick [2] (the os=darwin overlay, a middle layer). Placing there also
    // changes a darwin machine with no profile fact, which reads the os=darwin
    // overlay, so the pick prompts a cross-configuration confirm; answer y.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n2\ny\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    try std.testing.expectEqualStrings("theme = \"solarized\"\n", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
    // The more specific override was deleted so the middle placement surfaces.
    try std.testing.expectEqualStrings("", try read(io, a, try h.srcOf("config.toml.d/os=darwin+profile=work.toml")));
    try std.testing.expectEqualStrings("theme = \"light\"\n", try read(io, a, try h.srcOf("config.toml")));
}

test "commit: structured [p] to base confirms and changes only the fall-through sibling, not one with its own override" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nfont = \"mono\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    // Sibling WITH its own override: must recompose identically regardless of
    // what happens to base or darwin's entry, so it must never appear in extra.
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=linux.toml", "theme = \"linux-theme\"\n");
    // A second file whose overlay reveals os=windows repo-wide, but config.toml
    // itself has no os=windows overlay, so that sibling falls through to base
    // and MUST appear in extra when base's theme value changes.
    try writeRepo(io, &tmp, "repo/src/other.toml", "x = 1\n");
    try writeRepo(io, &tmp, "repo/src/other.toml.d/os=windows.toml", "x = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    // [p] then base (candidate 1), then confirm y.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n1\ny\n");

    try std.testing.expectEqualStrings("theme = \"solarized\"\nfont = \"mono\"\n", try read(io, a, try h.srcOf("config.toml")));
    try std.testing.expectEqualStrings("", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
    // The sibling with its own override must be byte-identical: untouched.
    try std.testing.expectEqualStrings("theme = \"linux-theme\"\n", try read(io, a, try h.srcOf("config.toml.d/os=linux.toml")));

    try std.testing.expect(std.mem.indexOf(u8, res.out, "os=windows") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "os=linux") == null);
}

test "commit: declining the [p] to base confirm places nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nfont = \"mono\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    // A second file whose overlay reveals os=windows repo-wide, but config.toml
    // itself has no os=windows overlay, so that fall-through machine makes the
    // pick's cross-configuration confirm fire.
    try writeRepo(io, &tmp, "repo/src/other.toml", "x = 1\n");
    try writeRepo(io, &tmp, "repo/src/other.toml.d/os=windows.toml", "x = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    // [p] then base (candidate 1), then decline the confirm with n.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n1\nn\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // Nothing was placed anywhere: base, the winning overlay, and the
    // fall-through sibling's file all stay byte-identical to their originals.
    try std.testing.expectEqualStrings("theme = \"light\"\nfont = \"mono\"\n", try read(io, a, try h.srcOf("config.toml")));
    try std.testing.expectEqualStrings("theme = \"dark\"\n", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
    try std.testing.expectEqualStrings("x = 2\n", try read(io, a, try h.srcOf("other.toml.d/os=windows.toml")));
}

test "commit: structured promote detects a sibling revealed only by another file (repo-wide)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // config.toml only ever names os=darwin; os=linux exists ONLY via other.toml.
    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    try writeRepo(io, &tmp, "repo/src/other.toml", "x = 1\n");
    try writeRepo(io, &tmp, "repo/src/other.toml.d/os=linux.toml", "x = 2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    // [p] -> base, then decline: we assert only that os=linux was DETECTED and
    // listed at the confirm -- the soundness property. Declining leaves sources
    // untouched (rc 1), so the assertion does not depend on commit behavior.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n1\nn\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    // The repo-wide sibling was surfaced: the OLD per-file space would omit it.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "os=linux") != null);
    // Declined -> nothing placed.
    try std.testing.expectEqualStrings("theme = \"light\"\n", try read(io, a, try h.srcOf("config.toml")));
    try std.testing.expectEqualStrings("theme = \"dark\"\n", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
}

test "commit: structured [p] to base confirms a fall-through sibling that leaves an optional fact unset" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Base names no theme at all; both profile overlays define it, and this
    // machine's own profile=work wins. A sibling that leaves `profile` UNSET
    // (never named by any fact) falls through straight to base -- so
    // promoting theme to base changes what that sibling reads, from absent to
    // the promoted value. `profile` is an optional custom fact, not one of
    // os/arch/machine, so its unbound representative must be enumerated even
    // though this machine itself binds it.
    try writeRepo(io, &tmp, "repo/src/config.toml", "");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/profile=work.toml", "theme = \"work\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/profile=personal.toml", "theme = \"personal\"\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "profile = \"work\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"work\"", "\"solarized\"");

    // Layers least-specific-first: [1]=base, [2]=profile=work.toml (the
    // winner). Pick [1] (promote to base), then decline the confirm.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n1\nn\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // The fall-through sibling (profile left unset) was surfaced at the
    // confirm -- the OLD config space, which enumerated `null` only when THIS
    // machine itself left the axis unbound, would have missed it entirely and
    // silently promoted.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "profile=(unset)") != null);

    // Declined -> nothing placed anywhere.
    try std.testing.expectEqualStrings("", try read(io, a, try h.srcOf("config.toml")));
    try std.testing.expectEqualStrings("theme = \"work\"\n", try read(io, a, try h.srcOf("config.toml.d/profile=work.toml")));
    try std.testing.expectEqualStrings("theme = \"personal\"\n", try read(io, a, try h.srcOf("config.toml.d/profile=personal.toml")));
}

test "commit: structured [p] to base over a real os sibling never confirms a spurious unbound-os fall-through" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // os=linux has its OWN override, so it recomposes identically regardless
    // of the promote and never appears in the confirm. This pins the shape of
    // the derived-axis representative: os is bound on every real machine, so
    // an "os unset" configuration is a phantom that must never be enumerated,
    // while "an os no source names" is a real machine the promote does reach
    // and must be listed.
    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=linux.toml", "theme = \"blue\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n1\ny\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    // The unnamed-os machine is listed; os=linux, which overrides the key
    // itself, is not; and no phantom "unset" configuration appears at all.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "os=(other): light -> solarized") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "os=linux") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "unset") == null);

    try std.testing.expectEqualStrings("theme = \"solarized\"\n", try read(io, a, try h.srcOf("config.toml")));
    try std.testing.expectEqualStrings("", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
    // os=linux keeps its own override, untouched.
    try std.testing.expectEqualStrings("theme = \"blue\"\n", try read(io, a, try h.srcOf("config.toml.d/os=linux.toml")));
}

test "commit: structured secret-derived key is never routed, non-interactively too" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "token = \"<secret:env:MOX_TEST_TOKEN>\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    var h = try setup(a, io, &tmp, .{ .os = "darwin" });
    // Re-build env with the secret variable present, so apply composes a
    // cleartext token into live.
    var map = std.process.Environ.Map.init(a);
    try map.put("HOME", h.home);
    try map.put("USER", "tester");
    try map.put("MOX_REPO", h.repo);
    try map.put("MOX_STATE_DIR", h.state);
    try map.put("MOX_OS", "darwin");
    try map.put("MOX_TEST_TOKEN", "s3cr3t");
    const map_ptr = try a.create(std.process.Environ.Map);
    map_ptr.* = map;
    h.env = .{ .map = map_ptr };

    _ = try h.run(&.{ "mox", "apply" });
    // A file whose composition resolved a secret has no cached cleartext:
    // `--yes` (non-interactive) never shows a diff for any hunk, so a
    // changed secret hunk is reported manual with no display at all here --
    // still safe, just via the ordinary non-interactive manual path rather
    // than the dedicated notice a terminal gets. Assert the observable
    // outcome (nothing routed, nothing leaked) rather than the exact wording.
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "s3cr3t", "changed");
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "s3cr3t") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "s3cr3t") == null);
    const src = try read(io, a, try h.srcOf("config.toml"));
    try std.testing.expect(std.mem.indexOf(u8, src, "s3cr3t") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "changed") == null);
    try std.testing.expectEqualStrings("token = \"<secret:env:MOX_TEST_TOKEN>\"\n", src);
}

test "commit: skipping at the fact prompt is a decline, not an un-routable hunk" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export EMAIL=<machine.email | default \"nobody@example.com\">\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "email = \"old@home.com\"\n");
    const h = try setup(a, io, &tmp, .{});

    _ = try h.run(&.{ "mox", "apply" });
    try editLive(io, a, try h.liveOf(".zshrc"), "export EMAIL=old@home.com", "export EMAIL=new@work.com");

    // The only hunk is the fact one, so this `s` answers the FACT prompt.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "s\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "This value comes from machine.email.") != null);
    // A hunk the user chose to leave is declined, never reported as one the
    // tool could not route.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "manual: ") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "came from a capture") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 0 manual") != null);
    // Nothing was written either way.
    const facts = try read(io, a, try h.homePath(".config/mox/facts.toml"));
    try std.testing.expect(std.mem.indexOf(u8, facts, "old@home.com") != null);
}

test "commit: a fact route alongside a skip is reported committed, and the skip is not manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `export A=1` stays put so the two edits are separate hunks.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export EMAIL=<machine.email | default \"nobody@example.com\">\n" ++
        "export A=1\nexport B=2\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "email = \"old@home.com\"\n");
    const h = try setup(a, io, &tmp, .{});

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EMAIL=old@home.com", "export EMAIL=new@work.com");
    try editLive(io, a, live, "export B=2", "export B=22");

    // [f] routes the interpolated line to the fact; [s] leaves the plain one.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "f\ns\n");

    // The fact was written and is kept, so the run must not claim nothing was
    // committed -- and a deliberate [s] is a decline, never "could not be routed".
    const facts = try read(io, a, try h.homePath(".config/mox/facts.toml"));
    try std.testing.expect(std.mem.indexOf(u8, facts, "new@work.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "not committed") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "could not be routed") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "1 hunk(s) were declined") != null);
}

test "commit: structured drift with no key change is reported, never silently dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nfont = \"mono\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    const cur = try read(io, a, live);
    const noted = try std.fmt.allocPrint(a, "# my note\n{s}", .{cur});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = noted });

    // A merged file's comment has no key path. Reporting it as manual is what
    // keeps `commit` from claiming a clean run while `status` still sees drift.
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "has no key path") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    // Reported AND non-zero, the same as any other un-routable structured key:
    // a `mox commit` gate must not pass on drift that was not committed.
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqual(@as(u8, 1), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: an unparseable sibling layer is named, and does not stop the commit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    // Broken AFTER apply, and only for a configuration this machine never
    // composes: os=linux is enumerated for the guard, so its parse error used
    // to escape as a bare error naming neither the file nor the layer.
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=linux.toml", "theme = \"broken\n");
    try editLive(io, a, try h.liveOf("config.toml"), "\"dark\"", "\"solarized\"");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "configuration os=linux does not compose") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "TomlParseError") != null);
    // A configuration already broken before the edit is the repo's problem,
    // not a reason to refuse an edit that has nothing to do with it.
    try std.testing.expectEqualStrings("theme = \"solarized\"\n", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
}

test "commit: an unparseable live structured file fails only itself" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nfont = \"mono\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export B=2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    try editLive(io, a, try h.liveOf("config.toml"), "\"mono\"", "mono\"");
    try editLive(io, a, try h.liveOf(".zshrc"), "export B=2", "export B=22");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "could not be parsed") != null);
    // The broken file does not abandon an unrelated file's routing: without
    // the per-file catch, the parse error unwound the whole run.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled, 1 manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf(".zshrc")), "export B=22") != null);
}

test "commit: a stale pre-fix overlay stamp is refreshed from source, not obeyed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Composes verbatim from the base on darwin; the current rule stamps it
    // `.base`. An older mox stamped it `.overlay` because the file DECLARES an
    // overlay -- simulate that persisted state, as an upgrade would find it.
    try writeRepo(io, &tmp, "repo/src/config.toml", "# banner\ntheme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=linux.toml", "theme = \"blue\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    const stale = [_]mox.provenance.map.Segment{.{
        .out_start = 0,
        .out_len = 2,
        .origin = .{ .overlay = .{ .path = try h.srcOf("config.toml") } },
    }};
    try mox.provenance.map.persist(a, io, h.state, live, &stale);

    // A comment edit has no key path; obeying the stale stamp would strand it
    // as manual until the drift is discarded. The refresh recomposes the
    // current source, proves it reproduces the last-applied bytes, and routes
    // by the fresh per-line stamp instead.
    try editLive(io, a, live, "# banner", "# banner edited");
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("# banner edited\ntheme = \"light\"\n", try read(io, a, try h.srcOf("config.toml")));
}

test "commit: a base whose only overlay does not match this machine routes by line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The os=linux overlay never folds on darwin, so live is the base passed
    // through verbatim -- comments and all -- and a comment edit is an ordinary
    // base line hunk, not a key path.
    try writeRepo(io, &tmp, "repo/src/config.toml", "# banner\ntheme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=linux.toml", "theme = \"blue\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "# banner", "# banner edited");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("# banner edited\ntheme = \"light\"\n", try read(io, a, try h.srcOf("config.toml")));
    try std.testing.expectEqualStrings("theme = \"blue\"\n", try read(io, a, try h.srcOf("config.toml.d/os=linux.toml")));
}

test "commit: the pick menu refuses a removal at a layer that does not define the key" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nextra = \"gone\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "extra = \"gone\"\n", "");

    // Only the base defines `extra`, so it is the sole candidate: the overlay
    // is reported unavailable instead of offered, and [1] is the base.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n1\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "unavailable: os=darwin.toml -- does not define it") != null);
    // No second numbered candidate exists to pick: offering the overlay is
    // what used to make a removal there abort the run on a raw PathNotFound.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[2]") == null);
    try std.testing.expectEqualStrings("theme = \"light\"\n", try read(io, a, try h.srcOf("config.toml")));
}

test "commit: the pick menu refuses a layer whose entry is interpolated" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "email = \"<machine.email>\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "email = \"over@x\"\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "email = \"old@home.com\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"over@x\"", "\"new@x\"");

    // The overlay's literal wins, so the edit is routable -- but promoting it
    // to the base would overwrite the template with this machine's value. The
    // trailing `y` is what makes this drive the hazard rather than the message:
    // if the base were still offered as [1], that input would confirm the
    // promote and destroy the template.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n1\ny\n");
    try std.testing.expect(std.mem.indexOf(u8, res.out, "unavailable: base src/config.toml -- its entry is interpolated") != null);
    try std.testing.expectEqualStrings("email = \"<machine.email>\"\n", try read(io, a, try h.srcOf("config.toml")));
}

test "commit: a key the target layer cannot hold is reported, and writes nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `foo` is a string in the base and a table in the winning overlay, so a
    // new `foo.baz` routes to the base and hits a non-container intermediate.
    try writeRepo(io, &tmp, "repo/src/config.toml", "z = 1\nfoo = \"scalar\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "[foo]\nbar = 1\n");
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export B=2\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "z = 1", "z = 2");
    try editLive(io, a, live, "bar = 1", "bar = 1\nbaz = 2");
    try editLive(io, a, try h.liveOf(".zshrc"), "export B=2", "export B=22");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    // The impact simulation applies the edit for real and restores it, so the
    // bad key is caught before the write phase: it is reported un-routable and
    // the sibling key on the same file is unaffected by it.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "cannot hold this key") != null);
    try std.testing.expectEqualStrings("z = 2\nfoo = \"scalar\"\n", try read(io, a, try h.srcOf("config.toml")));
    // The failure is scoped to its own file: an unrelated one still commits.
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf(".zshrc")), "export B=22") != null);
}

test "commit: an angle-bracket literal in a value is data, not a capture" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `Name <addr>` is ordinary package metadata. Refusing to route it -- and
    // calling it secret-derived -- would strand the key permanently.
    try writeRepo(io, &tmp, "repo/src/config.toml", "authors = [\"Sho <me@example.com>\"]\ntheme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"Sho <me@example.com>\"", "\"Sho <me@example.com>\", \"Co\"");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "interpolation- or secret-derived") == null);
    const base = try read(io, a, try h.srcOf("config.toml"));
    try std.testing.expect(std.mem.indexOf(u8, base, "\"Co\"") != null);
}

test "commit: structured capture nested in an array is skipped, never routed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "hosts = [\"<machine.email>\", \"backup\"]\ntheme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "email = \"old@home.com\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "\"backup\"", "\"backup\", \"extra\"");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    // The capture sits in an array ELEMENT, not at the leaf the path names, so
    // a leaf-only guard would route it and bake the resolved fact into the
    // shared base. The whole subtree must be scanned.
    const base = try read(io, a, try h.srcOf("config.toml"));
    try std.testing.expect(std.mem.indexOf(u8, base, "old@home.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, base, "extra") == null);
    try std.testing.expect(std.mem.indexOf(u8, base, "<machine.email>") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "interpolation- or secret-derived") != null);
}

test "commit: structured [y] routes to the winning overlay (json)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/settings.json", "{\"theme\":\"light\",\"font\":\"mono\"}");
    try writeRepo(io, &tmp, "repo/src/settings.json.d/os=darwin.json", "{\"theme\":\"dark\"}");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("settings.json");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    const ov = try read(io, a, try h.srcOf("settings.json.d/os=darwin.json"));
    try std.testing.expect(std.mem.indexOf(u8, ov, "solarized") != null);
    // The base is never touched by a [y] to the overlay: byte-identical.
    try std.testing.expectEqualStrings("{\"theme\":\"light\",\"font\":\"mono\"}", try read(io, a, try h.srcOf("settings.json")));
}

test "commit: structured [y] routes to the winning overlay (yaml)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.yaml", "theme: light\nfont: mono\n");
    try writeRepo(io, &tmp, "repo/src/config.yaml.d/os=darwin.yaml", "theme: dark\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("config.yaml");
    try editLive(io, a, live, "dark", "solarized");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("config.yaml.d/os=darwin.yaml")), "solarized") != null);
}

test "commit: structured [y] routes to the winning overlay (ini)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/app.ini", "[ui]\ntheme=light\nfont=mono\n");
    try writeRepo(io, &tmp, "repo/src/app.ini.d/os=darwin.ini", "[ui]\ntheme=dark\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf("app.ini");
    try editLive(io, a, live, "theme=dark", "theme=solarized");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("app.ini.d/os=darwin.ini")), "solarized") != null);
}

test "commit: structured [y] routes to the winning overlay (gitconfig)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.gitconfig", "[user]\n\tname = base\n");
    try writeRepo(io, &tmp, "repo/src/.gitconfig.d/os=darwin.gitconfig", "[user]\n\tname = darwin\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    _ = try h.run(&.{ "mox", "apply" });
    const live = try h.liveOf(".gitconfig");
    try editLive(io, a, live, "name = darwin", "name = picked");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf(".gitconfig.d/os=darwin.gitconfig")), "picked") != null);
    // The base user.name is untouched.
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf(".gitconfig")), "base") != null);
}

// Partial ownership: a file with an `own` declaration commits per key over
// its owned subtree, against the owned record.

fn writePartialRepo(io: Io, tmp: *std.testing.TmpDir, source: []const u8) !void {
    try writeRepo(io, tmp, "repo/src/app.toml", source);
}

test "commit partial: an owned key under a padded ini section header routes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/p.ini", "# mox: disown other\n[ s ]\nk = a\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("p.ini");
    try editLive(io, a, live, "k = a", "k = b");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "k = b") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("# mox: disown other\n[ s ]\nk = b\n", try read(io, a, try h.srcOf("p.ini")));
}

test "commit partial: a key named by a capture whose value changed since apply is never written under its old name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "# mox: disown other\n[t]\n\"<machine.profile>\" = \"a\"\nv = \"<machine.profile>-x\"\n";
    try writeRepo(io, &tmp, "repo/src/p.toml", src);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "facts", "set", "profile", "alpha" })).rc);
    _ = try h.run(&.{ "mox", "apply", "--defaults" });

    const live = try h.liveOf("p.toml");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "\"alpha\" = \"a\"") != null);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "facts", "set", "profile", "beta" })).rc);
    try editLive(io, a, live, "\"alpha\" = \"a\"", "\"alpha\" = \"b\"");
    try editLive(io, a, live, "v = \"alpha-x\"", "v = \"alpha-y\"");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "\"alpha\" = \"b\"") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") == null);
    try std.testing.expectEqualStrings(src, try read(io, a, try h.srcOf("p.toml")));
}

test "commit partial: a new owned key beside one named by a capture routes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own tui\n[tui]\n\"<machine.os>\" = 1\ntheme = \"light\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("app.toml");
    try editLive(io, a, live, "theme = \"light\"", "theme = \"light\"\nfont = 2");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "font = 2") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    const src = try read(io, a, try h.srcOf("app.toml"));
    try std.testing.expect(std.mem.indexOf(u8, src, "font = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "<machine.os>") != null);
}

test "commit partial: an owned ini section declared with its padding routes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/p.ini", "# mox: own \" s \"\n[ s ]\nk = a\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("p.ini");
    try editLive(io, a, live, "k = a", "k = b");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "k = b") != null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("# mox: own \" s \"\n[ s ]\nk = b\n", try read(io, a, try h.srcOf("p.ini")));
}

test "commit partial: [y] routes an owned-key edit to the base and advances the owned record" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writePartialRepo(io, &tmp, "# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"enter\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The program rewrites the file around the owned span.
    const live = try h.liveOf("app.toml");
    const program_live =
        \\# program header
        \\model = "gpt"
        \\
        \\[tui.keymap.global]
        \\submit = "enter"
        \\
        \\[state]
        \\count = 42
        \\
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = program_live });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // User edits the owned key in place.
    try editLive(io, a, live, "submit = \"enter\"", "submit = \"ctrl-enter\"");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  committed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled, 0 manual") != null);
    // Program noise outside the owned paths never surfaces in commit.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "count = 42") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[state]") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "count = 42") == null);

    // The edit landed in the base source; the live file kept its remainder.
    try std.testing.expectEqualStrings("# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"ctrl-enter\"\n", try read(io, a, try h.srcOf("app.toml")));
    const live_after = try read(io, a, live);
    try std.testing.expect(std.mem.indexOf(u8, live_after, "count = 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, live_after, "submit = \"ctrl-enter\"") != null);

    // The owned record advanced: status is clean and a re-apply writes nothing.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
    const re = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), re.rc);
    try std.testing.expect(std.mem.indexOf(u8, re.out, "unchanged") != null);
}

test "commit partial: [y] routes an overlay-won owned key to the overlay layer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writePartialRepo(io, &tmp, "# mox: own tui\n[tui]\ntheme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/app.toml.d/os=darwin.toml", "[tui]\ntheme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("app.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("app.toml.d/os=darwin.toml")), "solarized") != null);
    try std.testing.expectEqualStrings("# mox: own tui\n[tui]\ntheme = \"light\"\n", try read(io, a, try h.srcOf("app.toml")));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit partial: [p] promotes an owned key to base behind the repo-wide blast-radius confirm" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writePartialRepo(io, &tmp, "# mox: own tui\n[tui]\ntheme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/app.toml.d/os=darwin.toml", "[tui]\ntheme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("app.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    // [p], base (candidate 1), confirm y: promoting reaches the fall-through
    // sibling, which the confirm names with the key's before/after value.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n1\ny\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "os=(other)") != null);

    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("app.toml")), "theme = \"solarized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("app.toml.d/os=darwin.toml")), "dark") == null);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit partial: [s] leaves the key in the live file and the file uncommitted" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writePartialRepo(io, &tmp, "# mox: own tui\n[tui]\ntheme = \"light\"\n");
    try writeRepo(io, &tmp, "repo/src/app.toml.d/os=darwin.toml", "[tui]\ntheme = \"dark\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("app.toml");
    try editLive(io, a, live, "\"dark\"", "\"solarized\"");

    const res = try h.runWithInput(&.{ "mox", "commit" }, "s\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("[tui]\ntheme = \"dark\"\n", try read(io, a, try h.srcOf("app.toml.d/os=darwin.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.err, "1 hunk(s) were declined") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "not committed") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
}

test "commit partial: the guard rolls back a routed key when another edit changes an unallowed configuration's owned content" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // .bashrc routes a fact edit ([f]) that legitimately commits. The partial
    // file's os=linux overlay interpolates the SAME fact into OWNED content,
    // so the fact write changes os=linux's canonical owned bytes -- a change
    // the [y] on the darwin overlay never allowlisted. The guard must roll
    // the partial file back by exactly that configuration.
    try writeRepo(io, &tmp, "repo/src/.bashrc", "export SHELL_OK=1\n" ++
        "export EMAIL=<machine.email | default \"nobody@example.com\">\n");
    try writePartialRepo(io, &tmp, "# mox: own tui\n[tui]\nkeys = \"a\"\n");
    try writeRepo(io, &tmp, "repo/src/app.toml.d/os=darwin.toml", "[tui]\nkeys = \"b\"\n");
    try writeRepo(io, &tmp, "repo/src/app.toml.d/os=linux.toml", "[tui]\ngreet = \"<machine.email>\"\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "email = \"nobody@example.com\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".bashrc"), "export EMAIL=nobody@example.com", "export EMAIL=team@work.com");
    try editLive(io, a, try h.liveOf("app.toml"), "keys = \"b\"", "keys = \"c\"");

    // .bashrc: [f]. app.toml: [y] to the winning darwin overlay.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "f\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "os=linux") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "did not choose to affect") != null);

    // The fact commit stands; the partial file's overlay edit was rolled back.
    const facts = try read(io, a, try h.homePath(".config/mox/facts.toml"));
    try std.testing.expect(std.mem.indexOf(u8, facts, "email = \"team@work.com\"") != null);
    try std.testing.expectEqualStrings("[tui]\nkeys = \"b\"\n", try read(io, a, try h.srcOf("app.toml.d/os=darwin.toml")));
}

test "commit partial: a sibling configuration's own-declaration violation rolls the file back naming the configuration and leaf" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writePartialRepo(io, &tmp, "# mox: own tui\n[tui]\nk = \"a\"\n");
    // The linux overlay defines a leaf outside the declaration: broken for
    // os=linux, invisible to a darwin apply -- commit's per-configuration
    // own-declaration pass is what catches it.
    try writeRepo(io, &tmp, "repo/src/app.toml.d/os=linux.toml", "[stray]\ns = 1\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf("app.toml"), "k = \"a\"", "k = \"b\"");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "configuration os=linux") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "stray.s is outside the declared own paths") != null);
    // Rolled back: the base still holds the original value.
    try std.testing.expectEqualStrings("# mox: own tui\n[tui]\nk = \"a\"\n", try read(io, a, try h.srcOf("app.toml")));
}

test "commit partial: a secret-bearing record is skipped with the secret contract" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const secret_value = "commit-partial-s3cr3t-11aa22bb";
    try writePartialRepo(io, &tmp, "# mox: own api\n[api]\ntoken = \"<secret:env:MY_PARTIAL_SECRET>\"\n");
    const h = try setup(a, io, &tmp, .{
        .extra_env = &.{.{ .name = "MY_PARTIAL_SECRET", .value = secret_value }},
    });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("app.toml");
    try editLive(io, a, live, secret_value, "edited-by-hand");

    const res = try h.run(&.{ "mox", "commit" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "skipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "contains a secret; edit its source directly") != null);
    // Nothing was routed and the edit never reached the source.
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("app.toml")), "edited-by-hand") == null);
}

test "commit partial: first-contact drift is reported, never routed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writePartialRepo(io, &tmp, "# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"enter\"\n");
    const h = try setup(a, io, &tmp, .{});
    // No apply: the live file exists with differing owned content and no
    // owned record. Taking ownership is apply's job, with consent.
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try h.homePath("app.toml"),
        .data = "[tui.keymap.global]\nsubmit = \"escape\"\n",
    });

    const res = try h.run(&.{ "mox", "commit" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "first contact") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox apply") != null);
    try std.testing.expectEqualStrings("# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"enter\"\n", try read(io, a, try h.srcOf("app.toml")));
}

test "commit partial: a first-contact-only file exits nonzero outside report mode" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writePartialRepo(io, &tmp, "# mox: own tui\n[tui]\nk = 1\n");
    const h = try setup(a, io, &tmp, .{});
    // No apply: differing live owned content with no owned record is first
    // contact, a manual outcome. It must reach the guard and report like any
    // other unrouted edit -- exit 1, never a silent 0.
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try h.homePath("app.toml"),
        .data = "[tui]\nk = 9\n",
    });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "first contact") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "not committed") != null);
    try std.testing.expectEqualStrings("# mox: own tui\n[tui]\nk = 1\n", try read(io, a, try h.srcOf("app.toml")));
}

test "apply drift partial: --overwrite reasserts the owned span and keeps the remainder" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writePartialRepo(io, &tmp, "# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"enter\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("app.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "# program header\nmodel = \"gpt\"\n\n[tui.keymap.global]\nsubmit = \"escape\"\n\n[state]\ncount = 42\n" });

    // apply no longer prompts: drift is skipped and reported first.
    const skip = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), skip.rc);
    try std.testing.expectEqualStrings("# program header\nmodel = \"gpt\"\n\n[tui.keymap.global]\nsubmit = \"escape\"\n\n[state]\ncount = 42\n", try read(io, a, live));

    const res = try h.run(&.{ "mox", "apply", "--overwrite", live });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    const after = try read(io, a, live);
    try std.testing.expect(std.mem.indexOf(u8, after, "submit = \"enter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "# program header") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "count = 42") != null);
}

test "apply drift partial: reported by apply, then routed to source by a separate mox commit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writePartialRepo(io, &tmp, "# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"enter\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("app.toml");
    try editLive(io, a, live, "submit = \"enter\"", "submit = \"ctrl-enter\"");

    // apply reports the drift and touches nothing; resolving it is a
    // separate, explicit `mox commit` run (its own per-key prompt: [y]).
    const skip = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 1), skip.rc);
    try std.testing.expect(std.mem.indexOf(u8, skip.out, "drifted, left untouched") != null);

    const res = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The live edit reached the base source and the record advanced.
    try std.testing.expectEqualStrings("# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"ctrl-enter\"\n", try read(io, a, try h.srcOf("app.toml")));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
    const re = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), re.rc);
    try std.testing.expect(std.mem.indexOf(u8, re.out, "unchanged") != null);
}

test "apply drift partial: a secret-bearing record refuses commit, --overwrite still resolves it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const secret_value = "drift-partial-s3cr3t-33cc44dd";
    try writePartialRepo(io, &tmp, "# mox: own api\n[api]\ntoken = \"<secret:env:MY_PARTIAL_SECRET>\"\n");
    const h = try setup(a, io, &tmp, .{
        .extra_env = &.{.{ .name = "MY_PARTIAL_SECRET", .value = secret_value }},
    });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("app.toml");
    try editLive(io, a, live, secret_value, "edited-by-hand");

    try std.testing.expectEqual(@as(u8, 1), (try h.run(&.{ "mox", "apply" })).rc);

    // mox commit's own standalone secret guard refuses it (unrelated to
    // apply's now-removed drift prompt).
    const committed = try h.run(&.{ "mox", "commit" });
    try std.testing.expectEqual(@as(u8, 1), committed.rc);
    try std.testing.expect(std.mem.indexOf(u8, committed.out, "contains a secret; edit its source directly") != null);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "edited-by-hand") != null);

    const res = try h.run(&.{ "mox", "apply", "--overwrite", live });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), secret_value) != null);
}

test "commit: an own declaration the walk rejects reports the target by name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own \"unterminated\n[t]\n");
    const h = try setup(a, io, &tmp, .{});

    const res = try h.run(&.{ "mox", "commit" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "app.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "dotted key path") != null);
}

test "commit: a directive-looking line in an unstructured head skips only that file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/notes.md", "# mox: own x\nprose body\n");
    const h = try setup(a, io, &tmp, .{});

    const res = try h.run(&.{ "mox", "commit" });
    try std.testing.expect(std.mem.indexOf(u8, res.err, "notes.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "skipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "structured") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "nothing to commit") != null);
}

test "commit disown: routes a user-key edit to the base; the program's key never surfaces" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/settings.json",
        \\// mox: disown model
        \\{
        \\  "theme": "dark",
        \\  "editor": "nvim"
        \\}
        \\
    );
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The program writes its key, then the user edits an owned key live.
    const live = try h.liveOf("settings.json");
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = live,
        .data = "{\n  \"theme\": \"dark\",\n  \"editor\": \"nvim\",\n  \"model\": \"test-model-4.1\"\n}\n",
    });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, live, "\"theme\": \"dark\"", "\"theme\": \"light\"");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  committed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled, 0 manual") != null);
    // The disowned key never surfaces in commit output.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "test-model-4.1") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "test-model-4.1") == null);

    // The edit landed in the base source, head declaration intact, and the
    // disowned key stayed out of the source.
    const src = try read(io, a, try h.srcOf("settings.json"));
    try std.testing.expect(std.mem.indexOf(u8, src, "// mox: disown model") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "\"theme\": \"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "test-model-4.1") == null);
    // The live file kept the program's key.
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, live), "test-model-4.1") != null);

    // The owned record advanced: status clean, re-apply writes nothing.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
    const re = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), re.rc);
    try std.testing.expect(std.mem.indexOf(u8, re.out, "unchanged") != null);
}

// -- symlink-target keep --

fn isSymlink(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

fn linkTarget(io: Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.cwd().readLink(io, path, &buf);
    return a.dupe(u8, buf[0..n]);
}

fn writeSymlinkFixture(io: Io, tmp: *std.testing.TmpDir, target: []const u8) !void {
    try writeRepo(io, tmp, "repo/src/mylink", target);
    try writeRepo(io, tmp, "repo/.mox/attributes.toml", "[\"mylink\"]\nsymlink = true\n");
}

test "commit: symlink-target keep syncs a plain-literal source to the new live target, converging" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSymlinkFixture(io, &tmp, "/tmp/mox-old-target\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("mylink");
    try std.testing.expect(isSymlink(io, live));
    try Io.Dir.cwd().deleteFile(io, live);
    try Io.Dir.cwd().symLink(io, "/tmp/mox-new-target", live, .{});

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") != null);

    // The source now holds the new target, literal.
    try std.testing.expectEqualStrings("/tmp/mox-new-target\n", try read(io, a, try h.srcOf("mylink")));

    // Converges: a fresh apply sees no drift and touches nothing.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
    const re = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), re.rc);
    try std.testing.expect(std.mem.indexOf(u8, re.out, "unchanged") != null);
}

test "commit --yes: a symlink mox never wrote keeps no target, and --dry-run predicts that" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSymlinkFixture(io, &tmp, "/tmp/mox-old-target\n");
    const h = try setup(a, io, &tmp, .{});

    const live = try h.liveOf("mylink");
    try Io.Dir.cwd().symLink(io, "/tmp/mox-foreign-target", live, .{});

    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "first contact, needs confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "0 routable, 0 coupled, 1 manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would keep") == null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "first contact, needs confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqualStrings("/tmp/mox-old-target\n", try read(io, a, try h.srcOf("mylink")));
}

test "commit: symlink-target keep does not clobber a capture-bearing source" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSymlinkFixture(io, &tmp, "<machine.home>/real-nvim\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("mylink");
    try Io.Dir.cwd().deleteFile(io, live);
    try Io.Dir.cwd().symLink(io, "/somewhere/else", live, .{});

    const src_path = try h.srcOf("mylink");
    const before = try read(io, a, src_path);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    // The capture is never clobbered with the resolved literal: the source is
    // byte-identical, and the live edit is reported, not silently discarded.
    try std.testing.expectEqualStrings(before, try read(io, a, src_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mylink") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "capture") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") == null);
}

test "commit: symlink-target keep never writes a resolved secret into the source" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSymlinkFixture(io, &tmp, "<secret:env:MOX_TEST_LINK_SECRET>\n");
    var h = try setup(a, io, &tmp, .{});
    var map = std.process.Environ.Map.init(a);
    try map.put("HOME", h.home);
    try map.put("USER", "tester");
    try map.put("MOX_REPO", h.repo);
    try map.put("MOX_STATE_DIR", h.state);
    try map.put("MOX_TEST_LINK_SECRET", "/secret/resolved/target");
    const map_ptr = try a.create(std.process.Environ.Map);
    map_ptr.* = map;
    h.env = .{ .map = map_ptr };

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("mylink");
    try std.testing.expect(isSymlink(io, live));
    try expectSymlinkTargetContains(io, a, live, "/secret/resolved/target");
    try Io.Dir.cwd().deleteFile(io, live);
    try Io.Dir.cwd().symLink(io, "/somewhere/else", live, .{});

    const src_path = try h.srcOf("mylink");
    const before = try read(io, a, src_path);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    // Never written into the source, and the old resolved value never
    // reaches stdout -- only the manual notice.
    try std.testing.expectEqualStrings(before, try read(io, a, src_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "/secret/resolved/target") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "secret") != null);
}

fn expectSymlinkTargetContains(io: Io, a: std.mem.Allocator, path: []const u8, needle: []const u8) !void {
    const target = try linkTarget(io, a, path);
    try std.testing.expect(std.mem.indexOf(u8, target, needle) != null);
}

/// Compose `mylink`'s target under a single axis binding, so a test can prove
/// a configuration OTHER than this machine's still resolves correctly.
fn composeSymlinkTargetUnder(a: std.mem.Allocator, io: Io, h: Harness, axis: []const u8, value: []const u8) !?[]const u8 {
    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const tree = try mox.source.tree.walk(a, io, src_dir, h.home);
    var bindings = std.StringHashMap([]const u8).init(a);
    var bindings_r: mox.dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    try bindings.put(axis, value);
    for (tree.files) |f| {
        if (!std.mem.endsWith(u8, f.live_path, "mylink")) continue;
        return try mox.compose.composeFile(a, io, f, &bindings_r, null, null);
    }
    return error.FixtureFileMissing;
}

test "commit: symlink-target keep refuses a region-gated source instead of collapsing it" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/mylink", "# mox: when os=darwin\n" ++
        "/tmp/darwin-target\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "/tmp/linux-target\n" ++
        "# mox: end\n");
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "[\"mylink\"]\nsymlink = true\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf("mylink");
    try std.testing.expect(isSymlink(io, live));
    try expectSymlinkTargetContains(io, a, live, "/tmp/darwin-target");
    try Io.Dir.cwd().deleteFile(io, live);
    try Io.Dir.cwd().symLink(io, "/tmp/mox-new-target", live, .{});

    const src_path = try h.srcOf("mylink");
    const before = try read(io, a, src_path);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    // The region-gated source is never collapsed to one literal target: the
    // source stays byte-identical, both regions survive, and the drift is
    // reported as manual rather than silently destroying the linux region.
    try std.testing.expectEqualStrings(before, try read(io, a, src_path));
    try std.testing.expect(std.mem.indexOf(u8, before, "/tmp/darwin-target") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, "/tmp/linux-target") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mylink") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 manual") != null);

    // A linux machine composing this same source still gets its own target --
    // proof the region structure truly survived, not just the raw bytes.
    const linux_target = try composeSymlinkTargetUnder(a, io, h, "os", "linux");
    try std.testing.expect(linux_target != null);
    try std.testing.expectEqualStrings("/tmp/linux-target", std.mem.trim(u8, linux_target.?, " \t\r\n"));

    // Unresolved: a fresh status still reports drift.
    try std.testing.expectEqual(@as(u8, 1), (try h.run(&.{ "mox", "status" })).rc);
}

// -- generated-leaf keep --

/// A generator source at `src/.config/gen.inc` producing one file per row,
/// `id-<entry.slug>.inc`, whose body is `key=<entry.value>` -- the row's
/// `slug` names the leaf, `value` is what a leaf edit reverse-routes into,
/// so editing a leaf's body never renames its own file.
fn writeGenValueFixture(io: Io, tmp: *std.testing.TmpDir, rows: []const [2][]const u8) !void {
    try tmp.dir.createDirPath(io, "repo/src/.config");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/src/.config/gen.inc",
        .data = "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value>\n# mox: end\n",
    });
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    for (rows) |r| {
        try body.appendSlice(std.testing.allocator, "[[entries]]\nslug = \"");
        try body.appendSlice(std.testing.allocator, r[0]);
        try body.appendSlice(std.testing.allocator, "\"\nvalue = \"");
        try body.appendSlice(std.testing.allocator, r[1]);
        try body.appendSlice(std.testing.allocator, "\"\n\n");
    }
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/entries.toml", .data = body.items });
}

test "commit: a generator leaf edit that reverse-parses cleanly routes to its data-source row, converging" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenValueFixture(io, &tmp, &.{ .{ "a", "1" }, .{ "b", "2" } });
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const leaf_a = try h.liveOf(".config/id-a.inc");
    try editLive(io, a, leaf_a, "key=1", "key=99");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "id-a.inc") != null);

    const data = try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" }));
    try std.testing.expectEqualStrings(
        "[[entries]]\nslug = \"a\"\nvalue = \"99\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\n\n",
        data,
    );
    // The untouched sibling leaf is unaffected.
    try std.testing.expectEqualStrings("key=2\n", try read(io, a, try h.liveOf(".config/id-b.inc")));

    // Converges: a fresh apply regenerates the set identically to live.
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
    const re = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), re.rc);
}

test "commit --yes: a generator leaf mox never wrote routes no row, and --dry-run predicts that" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenValueFixture(io, &tmp, &.{ .{ "a", "1" }, .{ "b", "2" } });
    const h = try setup(a, io, &tmp, .{});

    const leaf_a = try h.liveOf(".config/id-a.inc");
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(leaf_a).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = leaf_a, .data = "key=99\n" });

    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "first contact, needs confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "0 routable, 0 coupled, 1 manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would update") == null);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "first contact, needs confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqualStrings(
        "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\n\n",
        try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" })),
    );
}

test "commit: a generator leaf edit that does not match the row template surfaces as the shared template, not a silent route" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenValueFixture(io, &tmp, &.{.{ "a", "1" }});
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // Replace the leaf's whole line with text the row template's literal
    // prefix ("key=") cannot match at all -- indistinguishable, without the
    // template, from a change to the shared template text itself.
    const leaf_a = try h.liveOf(".config/id-a.inc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = leaf_a, .data = "totally different line\n" });

    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" });
    const data_before = try read(io, a, data_path);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    // Never silently routed as a row edit: the data source is untouched, and
    // the report names the generator's own source, not a row.
    try std.testing.expectEqualStrings(data_before, try read(io, a, data_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "shared template") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "gen.inc") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ") == null);
}

test "commit: a leaf path argument routes only that leaf, addressing its generator" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenValueFixture(io, &tmp, &.{ .{ "a", "1" }, .{ "b", "2" } });
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const leaf_a = try h.liveOf(".config/id-a.inc");
    const leaf_b = try h.liveOf(".config/id-b.inc");
    try editLive(io, a, leaf_a, "key=1", "key=91");
    try editLive(io, a, leaf_b, "key=2", "key=92");

    // Scoped to leaf a's own live path -- not the generator's.
    const res = try h.run(&.{ "mox", "commit", "--yes", leaf_a });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "id-a.inc") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "id-b.inc") == null);

    const data = try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" }));
    try std.testing.expectEqualStrings(
        "[[entries]]\nslug = \"a\"\nvalue = \"91\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\n\n",
        data,
    );
    // The out-of-scope leaf's edit is untouched and still shows as drift.
    try std.testing.expectEqualStrings("key=92\n", try read(io, a, leaf_b));
    const st = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, st.out, "DRIFT") != null or std.mem.indexOf(u8, st.err, "DRIFT") != null);
}

test "commit: a fact value that cannot name an overlay routes to manual, not out of the repo" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Overlay-only, so a live edit has no base to route into and commit tries
    // to synthesize a first-contact overlay named from this machine's binding.
    try writeRepo(io, &tmp, "repo/src/.config/foo.toml.d/profile=other", "other = 1\n");
    const h = try setup(a, io, &tmp, .{});

    // `mox facts set` takes arbitrary text; this value is about to be asked to
    // name a file: unchecked, the path lands outside the repo entirely.
    const fs_res = try h.run(&.{ "mox", "facts", "set", "profile", "../../../../ESCAPED" });
    try std.testing.expectEqual(@as(u8, 0), fs_res.rc);
    _ = try h.run(&.{ "mox", "apply", "--defaults" });

    const live = try std.fs.path.join(a, &.{ h.home, ".config", "foo.toml" });
    if (std.fs.path.dirname(live)) |d| Io.Dir.cwd().createDirPath(io, d) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "edited = 2\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "cannot name an overlay") != null);
    // Nothing escaped the repo, and nothing crashed on the way.
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.root, "ESCAPED" })));

    // A Windows device name is a file no machine can hold.
    _ = try h.run(&.{ "mox", "facts", "set", "profile", "aux" });
    _ = try h.run(&.{ "mox", "apply", "--defaults" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "edited = 4\n" });
    const device = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, device.out, "cannot name an overlay") != null);
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.root, "repo", "src", ".config", "foo.toml.d", "profile=aux" })));
    // A value holding the pair separator would name a tuple no filename can
    // carry: the overlay would be written and every later command would
    // refuse the repo over it.
    _ = try h.run(&.{ "mox", "facts", "set", "profile", "a+b" });
    _ = try h.run(&.{ "mox", "apply", "--defaults" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "edited = 3\n" });
    const plus = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, plus.out, "cannot name an overlay") != null);
    // A manual outcome is an uncommitted edit, and the exit code says so.
    try std.testing.expectEqual(@as(u8, 1), plus.rc);
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ h.root, "repo", "src", ".config", "foo.toml.d", "profile=a+b" })));
    const after = try h.run(&.{ "mox", "status" });
    try std.testing.expect(after.rc != 1 or std.mem.indexOf(u8, after.err, "malformed axis tuple") == null);
}

test "commit: a first-contact structured file with no axis to name an overlay by is manual, not a crash" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The only layer is gated on a tool this machine lacks: no layer matches,
    // and the file compares no single-value axis an overlay could be named by.
    try writeRepo(io, &tmp, "repo/src/.config/foo.toml.d/tool=ghosttool.toml", "other = 1\n");
    const h = try setup(a, io, &tmp, .{});
    _ = try h.run(&.{ "mox", "apply", "--defaults" });
    const live = try std.fs.path.join(a, &.{ h.home, ".config", "foo.toml" });
    if (std.fs.path.dirname(live)) |d| Io.Dir.cwd().createDirPath(io, d) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "edited = 2\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "no source matches this machine") != null);
}

test "commit: a hunk straddling a secret line and a plain one withholds the old resolved value" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resolved = "STRADDLE-s3cr3t-DO-NOT-LEAK-7777dddd";
    try writeRepo(io, &tmp, "repo/src/.straddlerc", "export A=one\n" ++
        "export TOKEN=<secret:env:MOX_TEST_STRADDLE>\n" ++
        "export B=two\n");
    var h = try setup(a, io, &tmp, .{});
    var map = std.process.Environ.Map.init(a);
    try map.put("HOME", h.home);
    try map.put("USER", "tester");
    try map.put("MOX_REPO", h.repo);
    try map.put("MOX_STATE_DIR", h.state);
    try map.put("MOX_TEST_STRADDLE", resolved);
    const map_ptr = try a.create(std.process.Environ.Map);
    map_ptr.* = map;
    h.env = .{ .map = map_ptr };

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // One contiguous edit over the secret line AND the plain line after it, so
    // the hunk overlaps a `.secret` segment without being contained in one.
    const live = try h.liveOf(".straddlerc");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "export A=one\n" ++
        "export TOKEN=changed\n" ++
        "export B=TWO\n" });

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "s\n");
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ res.out, res.err });

    try std.testing.expect(std.mem.indexOf(u8, res.out, resolved) == null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, resolved) == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "old value withheld") != null);

    try std.testing.expectEqualStrings("export A=one\n" ++
        "export TOKEN=<secret:env:MOX_TEST_STRADDLE>\n" ++
        "export B=two\n", try read(io, a, try h.srcOf(".straddlerc")));
}

test "commit: a private universal fragment's edit is confirmed as private, never offered the shared candidates" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A private-only base whose `include` pulls a UNIVERSAL fragment (not
    // axis-gated, so nothing but the private origin keeps it off the shared
    // route), in a file that names an axis of its own -- which is what gives
    // it a configuration space wide enough for commit to ask where a SHARED
    // edit belongs.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    try writeRepo(io, &tmp, "state/private/.zsecret", "# mox: include \"frag.sh\"\n# mox: include \"darwin.sh\" when os=darwin\n");
    try writeRepo(io, &tmp, "state/private/.zsecret.d/frag.sh", "secret_one\nsecret_two\n");
    try writeRepo(io, &tmp, "state/private/.zsecret.d/darwin.sh", "mac_line\n");
    const h = try setup(a, io, &tmp, .{});

    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const live = try h.liveOf(".zsecret");
    try editLive(io, a, live, "secret_two", "secret_two_edited");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    // The plain private confirm, not the classifier: no candidate list, no
    // repo axis to narrow into, no "choose>" question.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[Y]es") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "choose>") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "os=darwin") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "universal") == null);

    // The edit landed in the private fragment, and repo src is byte-identical.
    const frag = try read(io, a, try std.fs.path.join(a, &.{ h.state, "private", ".zsecret.d", "frag.sh" }));
    try std.testing.expectEqualStrings("secret_one\nsecret_two_edited\n", frag);
    const after = try treeDigest(io, a, src_dir);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "commit: an insertion into a whole-file-gated target lands after the source line it follows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The gate line is consumed before composing, so live line 1 is source
    // line 2. An insertion carries no old text for the router to check, so a
    // provenance number that is short by the gate line writes the new line
    // one line too early.
    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: when os=darwin\n[a]\nx = 1\n");
    const h = try setup(a, io, &tmp, .{});

    const apply_res = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), apply_res.rc);

    const live = try h.liveOf("app.toml");
    try std.testing.expectEqualStrings("[a]\nx = 1\n", try read(io, a, live));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "[a]\nx = 1\ny = 2\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    const src = try read(io, a, try h.srcOf("app.toml"));
    try std.testing.expectEqualStrings("# mox: when os=darwin\n[a]\nx = 1\ny = 2\n", src);
}

const os_blocks = "# mox: when os=darwin\nexport BREW=1\n# mox: end\n# mox: when os=linux\nexport APT=1\n# mox: end\n";

fn appliedContent(h: Harness, name: []const u8) !?[]const u8 {
    return mox.apply.applied.readContent(h.a, h.io, h.state, try h.liveOf(name));
}

test "commit: a file whose data source is restored for another file's failure is not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n";
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nkey: <entry.key>\n# mox: end\n");
    // The second loop file also carries a shared line the user sends to the
    // private layer, which has no automatic route: that file fails.
    try writeRepo(io, &tmp, "repo/src/.zaliases", "# mox: for entry in \"data/abbrs.toml\"\nexpansion: <entry.expansion>\n# mox: end\nexport SPACER=1\nexport EDITOR=vim\n" ++ os_blocks);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const abbrs_before = (try appliedContent(h, ".abbrs")).?;

    try editLive(io, a, try h.liveOf(".abbrs"), "key: ll\n", "key: lll\n");
    try editLive(io, a, try h.liveOf(".zaliases"), "git status\n", "git status -sb\n");
    try editLive(io, a, try h.liveOf(".zaliases"), "EDITOR=vim", "EDITOR=nvim");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ny\n4\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // The data source holds its pre-run bytes, so the file whose row edit it
    // held is not committed, says why, and keeps its applied record.
    try std.testing.expectEqualStrings(data, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") == null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/.abbrs: not committed: {s} was restored because ~/.zaliases was not committed; commit it on its own with 'mox commit ~/.abbrs'\n", .{
        try h.liveOf(".zaliases"),
        try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" }),
    }), res.err);
    try std.testing.expectEqualStrings(abbrs_before, (try appliedContent(h, ".abbrs")).?);
}

test "commit: a file with a held hunk whose routed row lands in a restored data source is not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n";
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nkey: <entry.key>\n# mox: end\nset -g spacer 1\nset -g greeting hello\n");
    try writeRepo(io, &tmp, "repo/src/.zaliases", "# mox: for entry in \"data/abbrs.toml\"\nexpansion: <entry.expansion>\n# mox: end\nexport SPACER=1\nexport EDITOR=vim\n" ++ os_blocks);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "key: ll\n", "key: lll\n");
    try editLive(io, a, try h.liveOf(".abbrs"), "greeting hello", "greeting howdy");
    try editLive(io, a, try h.liveOf(".zaliases"), "git status\n", "git status -sb\n");
    try editLive(io, a, try h.liveOf(".zaliases"), "EDITOR=vim", "EDITOR=nvim");

    // .abbrs: route the row, decline the plain line. .zaliases: route the
    // row, send the shared line to the private layer.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ns\ny\n4\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    try std.testing.expectEqualStrings(data, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") == null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/.abbrs: not committed: {s} was restored because ~/.zaliases was not committed; commit it on its own with 'mox commit ~/.abbrs'\n", .{
        try h.liveOf(".zaliases"),
        try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" }),
    }), res.err);
}

/// A multi-configuration file whose first line carries `token`, and whose
/// EDITOR line the tests send to the private layer, so the file fails.
fn failingRenameSource(a: std.mem.Allocator, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "note {s}\nexport SPACER=1\nexport EDITOR=vim\n" ++ os_blocks, .{token});
}

test "commit: a coupled update from a file that is not committed is undone and not counted" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.bshrc", try failingRenameSource(a, "quokkatoken"));
    try writeRepo(io, &tmp, "repo/src/.tsigners", "quokkatoken signing\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".bshrc"), "quokkatoken", "wombattoken");
    try editLive(io, a, try h.liveOf(".bshrc"), "EDITOR=vim", "EDITOR=nvim");

    // The rename stays universal, the EDITOR line goes to the private layer
    // (no automatic route), and the coupled update is accepted.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "1\n4\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    try std.testing.expectEqualStrings("quokkatoken signing\n", try read(io, a, try h.srcOf(".tsigners")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: coupled update to ~/.tsigners undone: ~/.bshrc was not committed\n", .{try h.liveOf(".bshrc")}), res.err);
}

test "commit: two origins coupling one target, one not committed, undo both updates and keep the other origin" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.aenv", "note alphatoken1\n");
    try writeRepo(io, &tmp, "repo/src/.bshrc", try failingRenameSource(a, "quokkatoken"));
    try writeRepo(io, &tmp, "repo/src/.tsigners", "alphatoken1 quokkatoken\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "alphatoken1", "alphatoken2");
    try editLive(io, a, try h.liveOf(".bshrc"), "quokkatoken", "wombattoken");
    try editLive(io, a, try h.liveOf(".bshrc"), "EDITOR=vim", "EDITOR=nvim");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n1\n4\ny\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // The target is back to its pre-run bytes: neither update stands, and
    // neither is counted. The origin that passed is still committed.
    try std.testing.expectEqualStrings("alphatoken1 quokkatoken\n", try read(io, a, try h.srcOf(".tsigners")));
    try std.testing.expectEqualStrings("note alphatoken2\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: coupled update to ~/.tsigners undone: {s} was restored because ~/.bshrc was not committed\n" ++
        "mox commit: coupled update to ~/.tsigners undone: ~/.bshrc was not committed\n", .{ try h.liveOf(".bshrc"), try h.srcOf(".tsigners") }), res.err);
}

test "commit: a symlink whose sync fails restores only its own source" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/alink", "/tmp/mox-a-old\n");
    try writeRepo(io, &tmp, "repo/src/blink", "/tmp/mox-b-old\n");
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "[\"alink\"]\nsymlink = true\n\n[\"blink\"]\nsymlink = true\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    for ([_][2][]const u8{ .{ "alink", "/tmp/mox-a-new" }, .{ "blink", "/tmp/<machine.os>" } }) |l| {
        const live = try h.liveOf(l[0]);
        try Io.Dir.cwd().deleteFile(io, live);
        try Io.Dir.cwd().symLink(io, l[1], live, .{});
    }

    // blink's new target holds capture syntax, so its source recomposes to a
    // different target and that sync fails; alink's stands on its own.
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("/tmp/mox-a-new\n", try read(io, a, try h.srcOf("alink")));
    try std.testing.expectEqualStrings("/tmp/mox-b-old\n", try read(io, a, try h.srcOf("blink")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/alink") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/blink") == null);
    try std.testing.expectEqualStrings("mox commit: ~/blink: recomposed symlink target does not match; not committed\n", res.err);
}

test "commit: a generator leaf whose data source is restored for a file's failure is not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenValueFixture(io, &tmp, &.{ .{ "a", "1" }, .{ "b", "2" } });
    try writeRepo(io, &tmp, "repo/src/.zloop", "# mox: for entry in \"data/entries.toml\"\nval <entry.slug> <entry.value>\n# mox: end\nexport SPACER=1\nexport EDITOR=vim\n" ++ os_blocks);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" });
    const data_before = try read(io, a, data_path);

    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=99");
    try editLive(io, a, try h.liveOf(".zloop"), "val b 2", "val b 7");
    try editLive(io, a, try h.liveOf(".zloop"), "EDITOR=vim", "EDITOR=nvim");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ny\n4\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    try std.testing.expectEqualStrings(data_before, try read(io, a, data_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.config/id-a.inc") == null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/.config/id-a.inc: not committed: {s} was restored because ~/.zloop was not committed; commit it on its own with 'mox commit ~/.config/id-a.inc'\n", .{ try h.liveOf(".zloop"), data_path }), res.err);
}

test "commit: a coupling graph entry that names no managed source is not written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "email = old@example.com\n");
    try writeRepo(io, &tmp, "repo/notes.txt", "old@example.com\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // A stale graph: it still names a path that is no managed file's source.
    const notes = try std.fs.path.join(a, &.{ h.repo, "notes.txt" });
    var g = mox.coupling.graph.Graph.init(a);
    try g.addOccurrence("old@example.com", try h.srcOf(".myenv"), 8, 15);
    try g.addOccurrence("old@example.com", notes, 0, 15);
    try mox.coupling.store.saveGraph(a, io, try std.fs.path.join(a, &.{ h.state, "coupling" }), &g);

    try editLive(io, a, try h.liveOf(".myenv"), "old@example.com", "new@example.com");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    try std.testing.expectEqualStrings("old@example.com\n", try read(io, a, notes));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "notes.txt") == null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: {s} is no managed file's source; not updating it\n", .{notes}), res.err);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.myenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
}

test "commit: a file verified under a fact that is then reverted is re-verified and not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const email_line = "export EMAIL=<machine.email | default \"nobody@example.com\">\n";
    try writeRepo(io, &tmp, "repo/src/.pfile", "export SHELL_OK=1\nexport EDITOR=vim\nexport SPACER=1\n" ++ email_line ++ os_blocks);
    try writeRepo(io, &tmp, "repo/src/.rfile", email_line);
    const facts_before = "email = \"old@home.com\"\n";
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", facts_before);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    try editLive(io, a, try h.liveOf(".pfile"), "EDITOR=vim", "EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".pfile"), "EMAIL=old@home.com", "EMAIL=new@home.com");
    try editLive(io, a, try h.liveOf(".rfile"), "EMAIL=old@home.com", "EMAIL=new@home.com");

    // .pfile: EDITOR to the private layer (fails), EMAIL to the fact.
    // .rfile: EMAIL to the source default, which recomposes to live only
    // while the fact .pfile routed holds the new value.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "4\nf\nd\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    try std.testing.expectEqualStrings(facts_before, try read(io, a, try h.homePath(".config/mox/facts.toml")));
    try std.testing.expectEqualStrings(email_line, try read(io, a, try h.srcOf(".rfile")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.rfile") == null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/.rfile: not committed: fact email was reverted because ~/.pfile was not committed; commit it on its own with 'mox commit ~/.rfile'\n", .{try h.liveOf(".pfile")}), res.err);
}

test "commit: a coupling target failed by a fact revert prints the fact line, and its update as not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const email_line = "export EMAIL=<machine.email | default \"nobody@example.com\">\n";
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    try writeRepo(io, &tmp, "repo/src/.pfile", "export SHELL_OK=1\nexport EDITOR=vim\nexport SPACER=1\n" ++ email_line ++ os_blocks);
    try writeRepo(io, &tmp, "repo/src/.rfile", "note wombatnote\n" ++ email_line);
    const facts_before = "email = \"old@home.com\"\n";
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", facts_before);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    // Since the apply, the source went back to the token live still shows
    // renamed: only .aenv's coupled update makes .rfile match live again.
    const rfile = "note quokkanote\n" ++ email_line;
    try writeRepo(io, &tmp, "repo/src/.rfile", rfile);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");
    try editLive(io, a, try h.liveOf(".pfile"), "EDITOR=vim", "EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".pfile"), "EMAIL=old@home.com", "EMAIL=new@home.com");
    try editLive(io, a, try h.liveOf(".rfile"), "EMAIL=old@home.com", "EMAIL=new@home.com");

    // .aenv: the rename, coupled into .rfile. .pfile: EDITOR to the private
    // layer (fails), EMAIL to the fact. .rfile: EMAIL to the source default,
    // which holds only while the fact .pfile routed does.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n4\nf\nd\ny\nn\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    try std.testing.expectEqualStrings(facts_before, try read(io, a, try h.homePath(".config/mox/facts.toml")));
    try std.testing.expectEqualStrings(rfile, try read(io, a, try h.srcOf(".rfile")));
    try std.testing.expectEqualStrings("note wombatnote\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/.rfile: not committed: fact email was reverted because ~/.pfile was not committed; commit it on its own with 'mox commit ~/.rfile'\n" ++
        "mox commit: coupled update to ~/.rfile undone: ~/.rfile was not committed\n", .{try h.liveOf(".pfile")}), res.err);
}

var restore_fail_target: []const u8 = "";
var restore_fail_calls: usize = 0;
var restore_fail_from: usize = 0;
var restore_fail_to: usize = std.math.maxInt(usize);
var restore_fail_real: *const fn (?*anyopaque, Io.Dir, []const u8, Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File = undefined;
var restore_fail_real_open: *const fn (?*anyopaque, Io.Dir, []const u8, Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File = undefined;
/// A second file, by real path, every create of which fails too.
var create_fail_also: []const u8 = "";

/// Whether this call on `sub_path` is one of the calls on the target that
/// fail.
fn failsNow(sub_path: []const u8) bool {
    if (restore_fail_target.len == 0 or !namesFailTarget(sub_path)) return false;
    restore_fail_calls += 1;
    return restore_fail_calls >= restore_fail_from and restore_fail_calls <= restore_fail_to;
}

fn restoreFailingCreateFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, opts: Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File {
    if (failsNow(sub_path)) return error.AccessDenied;
    if (create_fail_also.len > 0 and namesPath(sub_path, create_fail_also)) return error.AccessDenied;
    return restore_fail_real(userdata, dir, sub_path, opts);
}

fn failingOpenFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, opts: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
    if (failsNow(sub_path)) return error.AccessDenied;
    return restore_fail_real_open(userdata, dir, sub_path, opts);
}

/// Whether `path` names the file whose calls fail, however it is spelled:
/// commit reaches a source by its real path.
fn namesFailTarget(path: []const u8) bool {
    return namesPath(path, restore_fail_target);
}

/// Whether `path` names the file whose real path is `real`.
fn namesPath(path: []const u8, real: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(std.testing.io, path, &buf) catch return std.mem.eql(u8, path, real);
    return std.mem.eql(u8, buf[0..n], real);
}

/// The recovery directory a failed restore created: the only entry under
/// `<state>/commit-recovery`.
fn recoveryDir(h: Harness) ![]const u8 {
    const root = try std.fs.path.join(h.a, &.{ h.state, "commit-recovery" });
    var dir = try Io.Dir.cwd().openDir(h.io, root, .{ .iterate = true });
    defer dir.close(h.io);
    var it = dir.iterate();
    const entry = (try it.next(h.io)).?;
    try std.testing.expect((try it.next(h.io)) == null);
    return std.fs.path.join(h.a, &.{ root, entry.name });
}

/// `h` with every create of the existing file `target` from its `from`-th on
/// failing.
fn failingCreates(h: Harness, vtable: *Io.VTable, target: []const u8, from: usize) !Harness {
    return failingCreatesThrough(h, vtable, target, from, std.math.maxInt(usize));
}

/// `h` with the `from`-th through `to`-th creates of the existing file
/// `target` failing.
fn failingCreatesThrough(h: Harness, vtable: *Io.VTable, target: []const u8, from: usize, to: usize) !Harness {
    return failingCallsThrough(h, vtable, .create, target, from, to);
}

/// `h` with the `from`-th through `to`-th creates, or opens, of the existing
/// file `target` failing.
fn failingCallsThrough(h: Harness, vtable: *Io.VTable, call: enum { create, open }, target: []const u8, from: usize, to: usize) !Harness {
    restore_fail_target = try Io.Dir.cwd().realPathFileAlloc(h.io, target, h.a);
    restore_fail_calls = 0;
    restore_fail_from = from;
    restore_fail_to = to;
    vtable.* = h.io.vtable.*;
    switch (call) {
        .create => {
            restore_fail_real = h.io.vtable.dirCreateFile;
            vtable.dirCreateFile = restoreFailingCreateFile;
        },
        .open => {
            restore_fail_real_open = h.io.vtable.dirOpenFile;
            vtable.dirOpenFile = failingOpenFile;
        },
    }
    var faulty = h;
    faulty.io = .{ .userdata = h.io.userdata, .vtable = vtable };
    return faulty;
}

test "commit: a restore that fails saves the pre-run bytes, records nothing, and exits 2" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkatoken\n");
    const gated = "always\n# mox: when os=linux\n# quokkatoken\n# mox: end\n";
    try writeRepo(io, &tmp, "repo/src/.config/x.conf", gated);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    const myenv_before = (try appliedContent(h, ".myenv")).?;

    try editLive(io, a, try h.liveOf(".myenv"), "quokkatoken", "wombattoken");

    // The coupled update into x.conf changes only some of its configurations,
    // so it is refused and x.conf restored. Writes of x.conf: the impact
    // simulation's edit and its scoped journal's restore, the write phase,
    // then the settling restore, which fails.
    const target = try h.srcOf(".config/x.conf");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, target, 4);
    const res = try faulty.run(&.{ "mox", "commit", "--yes", "--color=never" });
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    // Nothing is recorded.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expectEqualStrings(myenv_before, (try appliedContent(h, ".myenv")).?);

    // The pre-run bytes of the path that could not be restored are saved in a
    // fresh recovery directory, named by root, and the path is named with its
    // copy.
    const copy = try std.fs.path.join(a, &.{ try recoveryDir(h), "repo", "src", ".config", "x.conf" });
    try std.testing.expectEqualStrings(gated, try read(io, a, copy));
    const myenv = try h.srcOf(".myenv");
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not restore {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{
        target,
        target,
        copy,
        myenv,
        try std.fs.path.join(a, &.{ try recoveryDir(h), "repo", "src", ".myenv" }),
    }), res.err);
}

test "commit: a restore that fails with no room for a recovery copy prints the pre-run bytes in full" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkatoken\n");
    const gated = "always\n# mox: when os=linux\n# quokkatoken\n# mox: end\n";
    try writeRepo(io, &tmp, "repo/src/.config/x.conf", gated);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    // A file where the recovery directory would go: no copy can be written.
    const recovery = try std.fs.path.join(a, &.{ h.state, "commit-recovery" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = recovery, .data = "" });

    try editLive(io, a, try h.liveOf(".myenv"), "quokkatoken", "wombattoken");

    // As above: the fourth write of x.conf is its restore, which fails.
    const target = try h.srcOf(".config/x.conf");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, target, 4);
    const res = try faulty.run(&.{ "mox", "commit", "--yes", "--color=never" });
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);

    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not restore {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: {s}: its pre-run bytes could not be saved; they follow in full:\n{s}" ++
        "mox commit: {s}: its pre-run bytes could not be saved; they follow in full:\nnote quokkatoken\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ target, target, gated, try h.srcOf(".myenv") }), res.err);
    try std.testing.expectEqualStrings("", try read(io, a, recovery));
}

/// Two plain files, each with a live edit routed to its source, applied and
/// recorded: `.aenv` and `.benv`.
fn twoRoutedEdits(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !Harness {
    try writeRepo(io, tmp, "repo/src/.aenv", "note alphanote\n");
    try writeRepo(io, tmp, "repo/src/.benv", "note betanote\n");
    const h = try setup(a, io, tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".aenv"), "alphanote", "gammanote");
    try editLive(io, a, try h.liveOf(".benv"), "betanote", "deltanote");
    return h;
}

test "commit: a write that fails after earlier writes restores every path, records nothing, and exits 2" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try twoRoutedEdits(a, io, &tmp);
    const aenv_before = (try appliedContent(h, ".aenv")).?;
    const benv_before = (try appliedContent(h, ".benv")).?;

    // .aenv is written first; the write of .benv fails.
    const benv = try h.srcOf(".benv");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, benv, 1);
    const res = try faulty.run(&.{ "mox", "commit", "--yes", "--color=never" });
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expectEqualStrings("note alphanote\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expectEqualStrings("note betanote\n", try read(io, a, benv));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expectEqualStrings(aenv_before, (try appliedContent(h, ".aenv")).?);
    try std.testing.expectEqualStrings(benv_before, (try appliedContent(h, ".benv")).?);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not write {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below was restored to its pre-run bytes\n" ++
        "mox commit: {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ benv, try h.srcOf(".aenv") }), res.err);
}

test "commit: a write that fails and a restore that fails save the pre-run bytes, record nothing, and exit 2" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try twoRoutedEdits(a, io, &tmp);
    const aenv_before = (try appliedContent(h, ".aenv")).?;

    // .aenv's write lands and its restore fails; .benv's write fails.
    const aenv = try h.srcOf(".aenv");
    const benv = try h.srcOf(".benv");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, aenv, 2);
    create_fail_also = try Io.Dir.cwd().realPathFileAlloc(io, benv, a);
    const res = try faulty.run(&.{ "mox", "commit", "--yes", "--color=never" });
    restore_fail_target = "";
    create_fail_also = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expectEqualStrings("note gammanote\n", try read(io, a, aenv));
    try std.testing.expectEqualStrings("note betanote\n", try read(io, a, benv));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expectEqualStrings(aenv_before, (try appliedContent(h, ".aenv")).?);
    const copy = try std.fs.path.join(a, &.{ try recoveryDir(h), "repo", "src", ".aenv" });
    try std.testing.expectEqualStrings("note alphanote\n", try read(io, a, copy));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not write {s} (AccessDenied)\n" ++
        "mox commit: could not restore {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ benv, aenv, aenv, copy }), res.err);
}

test "commit: a write that fails reports the package rows already recorded, which stay" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try twoRoutedEdits(a, io, &tmp);
    const manifest = try std.fs.path.join(a, &.{ h.repo, "data", "packages", "darwin.toml" });
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(manifest).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "backend = \"brew\"\n" });

    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    const brew = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew list ";
    try entries.appendSlice(a, &.{
        .{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" },
        .{ .argv = brew ++ "--full-name --installed-on-request", .stdout = "htop\n" },
        .{ .argv = brew ++ "--cask --full-name" },
        .{ .argv = brew ++ "--formula --full-name", .stdout = "htop\n" },
    });
    for ([_][]const u8{ "apt-get", "dnf", "pacman", "scoop", "winget", "zypper" }) |m| {
        try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} --version", .{m}), .fail = error.FileNotFound });
    }
    var fake: mox.packages.exec.Fake = .{ .arena = a, .entries = entries.items };
    mox.cli.app.package_runner_override = fake.runner();
    defer mox.cli.app.package_runner_override = null;

    const benv = try h.srcOf(".benv");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, benv, 1);
    const res = try faulty.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ny\ny\n");
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"htop\"\n", try read(io, a, manifest));
    try std.testing.expectEqualStrings("note alphanote\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not write {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below was restored to its pre-run bytes\n" ++
        "mox commit: {s}\n" ++
        "mox commit: 1 package row(s) already recorded\n", .{ benv, try h.srcOf(".aenv") }), res.err);
}

test "commit: a narrowing whose fragment write fails restores the base, removes the region directory, and exits 2" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);
    const applied_before = (try appliedContent(h, ".zshrc")).?;

    try editLive(io, a, try h.liveOf(".zshrc"), "export EDITOR=vim", "export EDITOR=nvim");

    // Only the fragment's creates fail; it does not exist yet, so it is
    // matched by the canonical path commit writes it through.
    const fragment = try std.fs.path.join(a, &.{ try Io.Dir.cwd().realPathFileAlloc(io, src_dir, a), ".zshrc.d", "os", "darwin" });
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, try h.srcOf(".zshrc"), std.math.maxInt(usize));
    create_fail_also = fragment;
    const res = try faulty.runWithInput(&.{ "mox", "commit", "--color=never" }, "2\n");
    restore_fail_target = "";
    create_fail_also = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expectEqual(before, try treeDigest(io, a, src_dir));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, try h.srcOf(".zshrc.d"), .{}));
    try std.testing.expectEqualStrings(applied_before, (try appliedContent(h, ".zshrc")).?);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not write {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below was restored to its pre-run bytes\n" ++
        "mox commit: {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ fragment, try h.srcOf(".zshrc") }), res.err);
}

test "commit: a first write that fails and changes nothing says only that nothing was recorded" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try twoRoutedEdits(a, io, &tmp);
    const aenv_before = (try appliedContent(h, ".aenv")).?;

    const aenv = try h.srcOf(".aenv");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, aenv, 1);
    const res = try faulty.run(&.{ "mox", "commit", "--yes", "--color=never" });
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expectEqualStrings("note alphanote\n", try read(io, a, aenv));
    try std.testing.expectEqualStrings("note betanote\n", try read(io, a, try h.srcOf(".benv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expectEqualStrings(aenv_before, (try appliedContent(h, ".aenv")).?);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not write {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{aenv}), res.err);
}

test "commit: a facts write that fails restores the routed source, leaves the facts, records nothing, and exits 2" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zshrc = "export EMAIL=<machine.email | default \"nobody@example.com\">\n" ++
        "export A=1\nexport B=2\n";
    try writeRepo(io, &tmp, "repo/src/.zshrc", zshrc);
    const facts_before = "email = \"old@home.com\"\n";
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", facts_before);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const applied_before = (try appliedContent(h, ".zshrc")).?;
    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export EMAIL=old@home.com", "export EMAIL=new@work.com");
    try editLive(io, a, live, "export B=2", "export B=22");

    const facts = try h.homePath(".config/mox/facts.toml");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, facts, 1);
    const res = try faulty.runWithInput(&.{ "mox", "commit", "--color=never" }, "f\ny\n");
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expectEqualStrings(zshrc, try read(io, a, try h.srcOf(".zshrc")));
    try std.testing.expectEqualStrings(facts_before, try read(io, a, facts));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expectEqualStrings(applied_before, (try appliedContent(h, ".zshrc")).?);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not write ~/.config/mox/facts.toml (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below was restored to its pre-run bytes\n" ++
        "mox commit: {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{try h.srcOf(".zshrc")}), res.err);
}

test "commit: a path the journal cannot read stops the run before any write" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A regular file where the region directory would go: the fragment path
    // under it cannot be read.
    try writeSharedBaseFixture(io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc.d", "not a directory\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);
    const applied_before = (try appliedContent(h, ".zshrc")).?;

    try editLive(io, a, try h.liveOf(".zshrc"), "export EDITOR=vim", "export EDITOR=nvim");
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "2\n");
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expectEqual(before, try treeDigest(io, a, src_dir));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expectEqualStrings(applied_before, (try appliedContent(h, ".zshrc")).?);
    const fragment = try std.fs.path.join(a, &.{ try Io.Dir.cwd().realPathFileAlloc(io, src_dir, a), ".zshrc.d", "os", "darwin" });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not read {s} (NotDir)\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{fragment}), res.err);
}

/// `name` as commit shows a live path under the home: `~`-relative.
fn shownLive(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "~{s}{s}", .{ std.fs.path.sep_str, name });
}

test "commit: an edited file whose source yields no file is not committed and exits 1 in both modes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.ids", "# mox: for e in \"data/ids.toml\"\nid <e.k>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/ids.toml", "[[ids]]\nk = \"one\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".ids"), .data = "id one\nhand edit\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ h.repo, "data", "ids.toml" }), .data = "ids = []\n" });

    const want_err = try std.fmt.allocPrint(a, "mox commit: {s}: source yields no file; remove the live copy or add the data that filled it; not committed\n", .{try shownLive(a, ".ids")});
    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(want_err, dry.err);
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(want_err, res.err);
    try std.testing.expectEqualStrings("\nmox commit: 0 routed, 0 coupled, 0 manual\n", res.out);
}

test "commit --dry-run: a key its target layer cannot hold is manual, as --yes reports it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `foo` is a string in the base and a table in the winning overlay, so a
    // new `foo.baz` routes to the base, which cannot hold it.
    try writeRepo(io, &tmp, "repo/src/config.toml", "foo = \"scalar\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "[foo]\nbar = 1\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "bar = 1", "bar = 1\nbaz = 2");

    const manual = try std.fmt.allocPrint(a, "  manual: {s} foo.baz: src/config.toml cannot hold this key\n", .{live});
    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\nmox commit: 0 routable, 0 coupled, 1 manual (report only; run without --dry-run on a terminal to apply)\n", .{manual}), dry.out);
    const held = try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) could not be routed and remain only in the live file; not committed\n", .{live});
    try std.testing.expectEqualStrings(held, dry.err);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\nmox commit: 0 routed, 0 coupled, 1 manual\n", .{manual}), res.out);
    try std.testing.expectEqualStrings(held, res.err);
}

test "commit: a key a single-configuration layer cannot hold is manual in the preview and at --yes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A partial file with only a base has one configuration; a key through
    // an array of tables is one no TOML layer edit can write.
    const src = "# mox: own srv\n[[srv]]\nname = \"a\"\n";
    try writeRepo(io, &tmp, "repo/src/app.toml", src);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("app.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "[[srv]]\nname = \"a\"\nport = 1\n" });

    const manual = try std.fmt.allocPrint(a, "  manual: {s} srv: src/app.toml cannot hold this key\n", .{live});
    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\nmox commit: 0 routable, 0 coupled, 1 manual (report only; run without --dry-run on a terminal to apply)\n", .{manual}), dry.out);
    const held = try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) could not be routed and remain only in the live file; not committed\n", .{live});
    try std.testing.expectEqualStrings(held, dry.err);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\nmox commit: 0 routed, 0 coupled, 1 manual\n", .{manual}), res.out);
    try std.testing.expectEqualStrings(held, res.err);
    try std.testing.expectEqualStrings(src, try read(io, a, try h.srcOf("app.toml")));
}

test "commit: a generator that fails to re-expand exits 1 in both modes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/entries.toml", "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=99");
    try writeRepo(io, &tmp, "repo/data/entries.toml", "[[entries]\n");

    const want_err = try std.fmt.allocPrint(a, "mox commit: {s}: generator failed to re-expand: TomlParseError\n", .{try shownLive(a, ".config" ++ std.fs.path.sep_str ++ "gen.inc")});
    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(want_err, dry.err);
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(want_err, res.err);
}

test "commit: a head error on a recorded path exits 1 when its live content differs, 0 when it does not" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    // An ownership declaration on an unstructured target is a head error.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "# mox: own foo\nexport A=1\n");
    const want_err = try std.fmt.allocPrint(a, "mox commit: {s}: skipped (head directives require a structured target (toml/json/yaml/ini/gitconfig))\n", .{try shownLive(a, ".zshrc")});

    const clean = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), clean.rc);
    try std.testing.expectEqualStrings(want_err, clean.err);

    try editLive(io, a, try h.liveOf(".zshrc"), "A=1", "A=2");
    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(want_err, dry.err);
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(want_err, res.err);
}

test "commit: a secret-recorded file whose source yields no file is not committed and exits 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.tokenrc", "# mox: when profile=work\nexport TOKEN=<secret:env:MOX_TEST_TOKEN>\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "profile = \"work\"\n");
    const h = try setup(a, io, &tmp, .{ .extra_env = &.{.{ .name = "MOX_TEST_TOKEN", .value = "s3cr3t" }} });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    // Only the hash is recorded for a secret-bearing file.
    try std.testing.expect((try appliedContent(h, ".tokenrc")) == null);
    try editLive(io, a, try h.liveOf(".tokenrc"), "s3cr3t", "rotated");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "profile = \"home\"\n");

    const want_err = try std.fmt.allocPrint(a, "mox commit: {s}: source yields no file; remove the live copy or add the data that filled it; not committed\n", .{try shownLive(a, ".tokenrc")});
    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(want_err, dry.err);
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(want_err, res.err);
}

test "commit --dry-run: a simulation write whose restore fails saves the pre-run bytes and exits 2" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSubsetImpactFixture(io, &tmp, "alias foo=bar\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".zshrc"), "alias foo=bar", "alias foo=baz");

    // The impact simulation writes the fragment and then puts it back; the
    // second create, that restore, fails.
    const frag = try h.srcOf(".zshrc.d/p.sh");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, frag, 2);
    const res = try faulty.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expectEqualStrings("alias foo=baz\n", try read(io, a, frag));
    const copy = try std.fs.path.join(a, &.{ try recoveryDir(h), "repo", "src", ".zshrc.d", "p.sh" });
    try std.testing.expectEqualStrings("alias foo=bar\n", try read(io, a, copy));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not restore {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ frag, frag, copy }), res.err);
}

test "commit: a simulated placement into a new overlay leaves no empty directory behind" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The only layer is a private-layer overlay for another os, so the first
    // key's placement is simulated in a repo overlay directory that does not
    // exist yet; the run then quits at the second key and writes nothing.
    try writeRepo(io, &tmp, "repo/src/.keep", "x\n");
    try writeRepo(io, &tmp, "state/private/settings.toml.d/os=linux.toml", "theme = \"light\"\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("settings.toml"), .data = "theme = \"dark\"\nsize = 2\n" });

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\nq\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "mox commit: aborted; no changes written\n"));
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expect(!exists(io, try h.srcOf("settings.toml.d")));
    try std.testing.expectEqual(before, try treeDigest(io, a, src_dir));
}

test "commit: a coupled update whose simulation cannot be reverted saves the pre-run bytes and exits 2" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkatoken\n");
    try writeRepo(io, &tmp, "repo/src/.tsigners", "quokkatoken signing\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    const myenv_before = (try appliedContent(h, ".myenv")).?;
    try editLive(io, a, try h.liveOf(".myenv"), "quokkatoken", "wombattoken");

    // The first create of .tsigners is the simulation's transient edit; the
    // second, its revert, fails.
    const target = try h.srcOf(".tsigners");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreatesThrough(h, &vtable, target, 2, 2);
    const res = try faulty.run(&.{ "mox", "commit", "--yes", "--color=never" });
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expectEqualStrings("note quokkatoken\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expectEqualStrings(myenv_before, (try appliedContent(h, ".myenv")).?);
    const copy = try std.fs.path.join(a, &.{ try recoveryDir(h), "repo", "src", ".tsigners" });
    try std.testing.expectEqualStrings("quokkatoken signing\n", try read(io, a, copy));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not restore {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ target, target, copy }), res.err);
}

test "commit: a file differing from its record only in the final newline is manual and exits 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".zshrc"), .data = "export A=1" });

    const manual = try std.fmt.allocPrint(a, "  manual: {s}: final newline differs\n", .{try shownLive(a, ".zshrc")});
    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\nmox commit: 0 routable, 0 coupled, 1 manual (report only; run without --dry-run on a terminal to apply)\n", .{manual}), dry.out);
    try std.testing.expectEqualStrings("", dry.err);
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\nmox commit: 0 routed, 0 coupled, 1 manual\n", .{manual}), res.out);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqualStrings("export A=1\n", try read(io, a, try h.srcOf(".zshrc")));
}

test "commit: a file whose every hunk was declined exits 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".zshrc"), "A=1", "A=2");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "s\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "\nmox commit: 0 routed, 0 coupled, 0 manual\n"));
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqualStrings("export A=1\n", try read(io, a, try h.srcOf(".zshrc")));
}

test "commit: a generator leaf whose every hunk was declined exits 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/entries.toml", "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=99");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "s\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "\nmox commit: 0 routed, 0 coupled, 0 manual\n"));
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a regular file at a recorded symlink path is manual and exits 1 in both modes" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSymlinkFixture(io, &tmp, "/tmp/mox-old-target\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("mylink");
    try Io.Dir.cwd().deleteFile(io, live);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "not a link\n" });

    const manual = try std.fmt.allocPrint(a, "  manual: {s} (not a symlink)\n", .{try shownLive(a, "mylink")});
    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\nmox commit: 0 routable, 0 coupled, 1 manual (report only; run without --dry-run on a terminal to apply)\n", .{manual}), dry.out);
    try std.testing.expectEqualStrings("", dry.err);
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\nmox commit: 0 routed, 0 coupled, 1 manual\n", .{manual}), res.out);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqualStrings("/tmp/mox-old-target\n", try read(io, a, try h.srcOf("mylink")));
}

test "commit: a head error on a partial file exits 1 when an owned key was edited, 0 when not" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: disown tui\n[core]\nname = \"a\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("app.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "[core]\nname = \"a\"\n\n[tui]\nx = 1\n" });
    // A declaration in another comment marker than TOML's is a head error.
    try writeRepo(io, &tmp, "repo/src/app.toml", "// mox: own core\n# mox: disown tui\n[core]\nname = \"a\"\n");
    const want_err = try std.fmt.allocPrint(a, "mox commit: {s}: skipped (a head directive or whole-file gate is spelled with a comment marker other than this file's own; it has no effect)\n", .{try shownLive(a, "app.toml")});

    // Only a disowned key differs: nothing owned was edited.
    const clean = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), clean.rc);
    try std.testing.expectEqualStrings(want_err, clean.err);

    try editLive(io, a, live, "name = \"a\"", "name = \"b\"");
    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(want_err, dry.err);
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(want_err, res.err);
}

test "commit: a key a layer holds only after an earlier key's placement routes, and both commit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `srv.b` cannot be added beside the dotted `srv.a`, but once `srv.a`
    // is removed the layer takes it.
    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own srv\nsrv.a = 1\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("app.toml"), .data = "[srv]\nb = { c = 2 }\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "  committed ~" ++ std.fs.path.sep_str ++ "app.toml\n\nmox commit: 1 routed, 0 coupled, 0 manual\n"));
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: one key removal made through two hard-linked files is one edit and commits both" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/a.toml", "# mox: own srv\n[srv]\nx = 1\ny = 2\n");
    try Io.Dir.hardLink(tmp.dir, "repo/src/a.toml", tmp.dir, "repo/src/b.toml", io, .{});
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf("a.toml"), "x = 1\n", "");
    try editLive(io, a, try h.liveOf("b.toml"), "x = 1\n", "");

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "\nmox commit: 2 routed, 0 coupled, 0 manual\n"));
    try std.testing.expectEqualStrings("# mox: own srv\n[srv]\ny = 2\n", try read(io, a, try h.srcOf("a.toml")));
}

test "commit: a first-contact file differing only in its final newline is manual and exits 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.bashrc", "export A=1\n");
    try writeRepo(io, &tmp, "home/.bashrc", "export A=1");
    const h = try setup(a, io, &tmp, .{});

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "  manual: {s}: final newline differs\n\nmox commit: 0 routed, 0 coupled, 1 manual\n", .{try shownLive(a, ".bashrc")}), res.out);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a secret-recorded file differing only in its final newline is manual and exits 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.tokenrc", "export TOKEN=<secret:env:MOX_TEST_TOKEN>\n");
    const h = try setup(a, io, &tmp, .{ .extra_env = &.{.{ .name = "MOX_TEST_TOKEN", .value = "s3cr3t" }} });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try std.testing.expect((try appliedContent(h, ".tokenrc")) == null);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".tokenrc"), .data = "export TOKEN=s3cr3t" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "  manual: {s}: final newline differs\n\nmox commit: 0 routed, 0 coupled, 1 manual\n", .{try shownLive(a, ".tokenrc")}), res.out);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a generator leaf differing only in its final newline is manual and exits 1" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/entries.toml", "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".config/id-a.inc"), .data = "key=1" });

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "  manual: {s}: final newline differs\n\nmox commit: 0 routed, 0 coupled, 1 manual\n", .{try shownLive(a, ".config" ++ std.fs.path.sep_str ++ "id-a.inc")}), res.out);
    try std.testing.expectEqualStrings("", res.err);
}

var delete_dir_fail: []const u8 = "";
var delete_dir_real: *const fn (?*anyopaque, Io.Dir, []const u8) Io.Dir.DeleteDirError!void = undefined;

fn failingDeleteDir(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteDirError!void {
    if (std.mem.eql(u8, sub_path, delete_dir_fail)) return error.AccessDenied;
    return delete_dir_real(userdata, dir, sub_path);
}

test "commit: a created directory a restore cannot remove is a restore failure, and exits 2" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSharedBaseFixture(io, &tmp);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const applied_before = (try appliedContent(h, ".zshrc")).?;
    try editLive(io, a, try h.liveOf(".zshrc"), "export EDITOR=vim", "export EDITOR=nvim");

    // The fragment's write fails; its restore removes the fragment, then the
    // directories its write made, and the innermost of those cannot be.
    const src_dir = try Io.Dir.cwd().realPathFileAlloc(io, try std.fs.path.join(a, &.{ h.repo, "src" }), a);
    const fragment = try std.fs.path.join(a, &.{ src_dir, ".zshrc.d", "os", "darwin" });
    var vtable: Io.VTable = undefined;
    var faulty = try failingCreates(h, &vtable, try h.srcOf(".zshrc"), std.math.maxInt(usize));
    create_fail_also = fragment;
    delete_dir_fail = try std.fs.path.join(a, &.{ src_dir, ".zshrc.d", "os" });
    delete_dir_real = h.io.vtable.dirDeleteDir;
    vtable.dirDeleteDir = failingDeleteDir;
    faulty.io = .{ .userdata = h.io.userdata, .vtable = &vtable };
    const res = try faulty.runWithInput(&.{ "mox", "commit", "--color=never" }, "2\n");
    restore_fail_target = "";
    create_fail_also = "";
    delete_dir_fail = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expectEqualStrings(applied_before, (try appliedContent(h, ".zshrc")).?);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not write {s} (AccessDenied)\n" ++
        "mox commit: could not restore {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ fragment, fragment }), res.err);
}

/// `rc_name` includes `<rc_name>.d/extra.toml`, a hard link to the partial
/// `app.toml`; applied, then `[srv]\na = 1` is rewritten as `srv.a = 1`
/// through `rc_name` and `b = { c = 2 }` added through `app.toml`, which the
/// layer can hold only while `[srv]` is a table header.
fn hardLinkedLayerEdits(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, rc_name: []const u8) !Harness {
    try writeRepo(io, tmp, try std.fmt.allocPrint(a, "repo/src/{s}", .{rc_name}), "export X=1\n# mox: include \"extra.toml\"\n");
    try writeRepo(io, tmp, "repo/src/app.toml", "# mox: own srv\n[srv]\na = 1\n");
    try tmp.dir.createDirPath(io, try std.fmt.allocPrint(a, "repo/src/{s}.d", .{rc_name}));
    try Io.Dir.hardLink(tmp.dir, "repo/src/app.toml", tmp.dir, try std.fmt.allocPrint(a, "repo/src/{s}.d/extra.toml", .{rc_name}), io, .{});
    const h = try setup(a, io, tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(rc_name), "[srv]\na = 1", "srv.a = 1");
    try editLive(io, a, try h.liveOf("app.toml"), "a = 1\n", "a = 1\nb = { c = 2 }\n");
    return h;
}

test "commit --dry-run: a line edit into a layer another file's key was routed to is refused at routing as --yes refuses it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `app.toml` sorts before `zrc`, so its key is routed first and the line
    // edit into the same file through `zrc` conflicts with it.
    const h = try hardLinkedLayerEdits(a, io, &tmp, "zrc");
    const manual = try std.fmt.allocPrint(a, "  manual: {s}:3 conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, "zrc"), try shownLive(a, "app.toml"), try h.srcOf("app.toml") });

    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings("", dry.err);
    try std.testing.expect(std.mem.endsWith(u8, dry.out, try std.fmt.allocPrint(a, "{s}\nmox commit: 1 routable, 0 coupled, 1 manual (report only; run without --dry-run on a terminal to apply)\n", .{manual})));

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expect(std.mem.endsWith(u8, res.out, try std.fmt.allocPrint(a, "{s}  committed {s}\n\nmox commit: 1 routed, 0 coupled, 1 manual\n", .{ manual, try shownLive(a, "app.toml") })));
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("app.toml")), "[srv]\na = 1\n") != null);
}

test "commit: a key routed into a layer a line edit was routed to under another name is refused at routing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `.myrc` sorts before `app.toml`: its line edit is routed first, and the
    // key into the same file conflicts with it.
    const h = try hardLinkedLayerEdits(a, io, &tmp, ".myrc");
    const manual = try std.fmt.allocPrint(a, "  manual: {s} srv.b: conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, "app.toml"), try shownLive(a, ".myrc"), try h.srcOf(".myrc.d/extra.toml") });

    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expect(std.mem.endsWith(u8, dry.out, try std.fmt.allocPrint(a, "{s}\nmox commit: 1 routable, 0 coupled, 1 manual (report only; run without --dry-run on a terminal to apply)\n", .{manual})));
    const held = try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) could not be routed and remain only in the live file; not committed\n", .{try h.liveOf("app.toml")});
    try std.testing.expectEqualStrings(held, dry.err);

    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.endsWith(u8, res.out, try std.fmt.allocPrint(a, "{s}  committed {s}\n\nmox commit: 1 routed, 0 coupled, 1 manual\n", .{ manual, try shownLive(a, ".myrc") })));
    try std.testing.expectEqualStrings(held, res.err);
    try std.testing.expectEqualStrings("# mox: own srv\nsrv.a = 1\n", try read(io, a, try h.srcOf("app.toml")));
}

/// Two keys of a layered file edited, both routed to the base, with the
/// `from`-th through `to`-th creates of the base failing.
fn twoBaseKeysFailingCreates(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, vtable: *Io.VTable, from: usize, to: usize) !struct { h: Harness, res: testutil.RunResult, base: []const u8 } {
    try writeRepo(io, tmp, "repo/src/config.toml", "y = 1\nz = 1\n");
    try writeRepo(io, tmp, "repo/src/config.toml.d/os=darwin.toml", "w = 1\n");
    const h = try setup(a, io, tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "y = 1", "y = 2");
    try editLive(io, a, live, "z = 1", "z = 2");
    const base = try h.srcOf("config.toml");
    const faulty = try failingCreatesThrough(h, vtable, base, from, to);
    const res = try faulty.run(&.{ "mox", "commit", "--yes", "--color=never" });
    restore_fail_target = "";
    return .{ .h = h, .res = res, .base = base };
}

test "commit: a simulation write that fails before its placement stops the run, restored, and exits 2" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The first key's simulation writes the base and puts it back; the
    // second's writes it as the plan holds it before that key, which fails.
    var vtable: Io.VTable = undefined;
    const r = try twoBaseKeysFailingCreates(a, io, &tmp, &vtable, 3, 3);
    try std.testing.expectEqual(@as(u8, 2), r.res.rc);
    try std.testing.expectEqualStrings("y = 1\nz = 1\n", try read(io, a, r.base));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not write {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{r.base}), r.res.err);
}

test "commit: a simulation write that fails with its placement stops the run, restored, and exits 2" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var vtable: Io.VTable = undefined;
    const r = try twoBaseKeysFailingCreates(a, io, &tmp, &vtable, 4, 4);
    try std.testing.expectEqual(@as(u8, 2), r.res.rc);
    try std.testing.expectEqualStrings("y = 1\nz = 1\n", try read(io, a, r.base));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: could not write {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below was restored to its pre-run bytes\n" ++
        "mox commit: {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ r.base, r.base }), r.res.err);
}

test "commit --dry-run: a coupled update undone because its origin fails at plan time is reported as --yes reports it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `.abbrs` writes a row of its own managed data file, whose copy renames
    // the row's key: the planned row no longer renders the loop's line, so
    // the plan fails both. `.abbrs` also renames a token `.cenv` holds, and
    // that coupled update is undone with it.
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "note alphatoken\n# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.cenv", "alphatoken signing\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    try editLive(io, a, try h.liveOf(".abbrs"), "note alphatoken", "note betatokens");
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");
    try editLive(io, a, try h.liveOf("abbrs.toml"), "key = \"gs\"", "key = \"gss\"");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    const data = try h.srcOf("abbrs.toml");
    const want_err = try std.fmt.allocPrint(a, "mox commit: {s}: the planned edit to {s} does not render the edited line; not committed\n" ++
        "mox commit: {s}: the planned edit to {s} does not render the edited line; not committed\n" ++
        "mox commit: coupled update to {s} undone: {s} was not committed\n", .{
        try h.liveOf(".abbrs"),
        data,
        try h.liveOf("abbrs.toml"),
        data,
        try shownLive(a, ".cenv"),
        try shownLive(a, ".abbrs"),
    });
    try std.testing.expectEqualStrings(want_err, res.err);
    try std.testing.expectEqualStrings(want_err, dry.err);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "\nmox commit: 0 routed, 0 coupled, 0 manual\n"));
    try std.testing.expect(std.mem.endsWith(u8, dry.out, "\nmox commit: 0 routable, 0 coupled, 0 manual (report only; run without --dry-run on a terminal to apply)\n"));
    try std.testing.expectEqualStrings(three_abbrs, try read(io, a, data));
    try std.testing.expectEqualStrings("alphatoken signing\n", try read(io, a, try h.srcOf(".cenv")));
}

test "commit --dry-run: a coupled update its target cannot compose is dropped as --yes drops it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zshrc = "export Q=<machine.quokkanote>\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.zshrc", zshrc);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note machine.quokkanote\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "quokkanote = \"somevalue\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    try editLive(io, a, try h.liveOf(".aenv"), "machine.quokkanote", "machine.wombatnote");
    const src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const before = try treeDigest(io, a, src_dir);

    const want_err = "mox commit: coupled update to ~" ++ std.fs.path.sep_str ++ ".zshrc undone: ~" ++ std.fs.path.sep_str ++ ".zshrc could not take it (recompose failed: UnknownMachineField)\n";
    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(want_err, dry.err);
    try std.testing.expect(std.mem.endsWith(u8, dry.out, "\nmox commit: 1 routable, 0 coupled, 0 manual (report only; run without --dry-run on a terminal to apply)\n"));
    try std.testing.expectEqual(before, try treeDigest(io, a, src_dir));

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(want_err, res.err);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "\nmox commit: 1 routed, 0 coupled, 0 manual\n"));
}

test "commit --dry-run: a configuration that cannot be verified is named as --yes names it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The linux configuration reads a fact no machine has, so it never
    // composes; this darwin machine's does.
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\n# mox: when os=linux\nexport B=<machine.nosuchfield>\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".zshrc"), "A=1", "A=2");

    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want_err = try std.fmt.allocPrint(a, "mox commit: {s}: configuration os=linux does not compose (UnknownMachineField); it cannot be verified -- fix that layer, then re-run\n", .{try h.liveOf(".zshrc")});
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(want_err, dry.err);
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings(want_err, res.err);
}

test "commit --dry-run: a file whose routed key commits beside a manual one is named as --yes names it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `z` routes to the base; `foo.baz` routes to the base too, which cannot
    // hold it beside the scalar `foo`.
    try writeRepo(io, &tmp, "repo/src/config.toml", "z = 1\nfoo = \"scalar\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "[foo]\nbar = 1\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "z = 1", "z = 2");
    try editLive(io, a, live, "bar = 1", "bar = 1\nbaz = 2");

    const want_err = try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) could not be routed and remain only in the live file; " ++
        "the routed edits were committed to the sources -- edit the rest in by hand, then run 'mox apply'\n", .{live});
    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings(want_err, dry.err);
    try std.testing.expect(std.mem.endsWith(u8, dry.out, "\nmox commit: 1 routable, 0 coupled, 1 manual (report only; run without --dry-run on a terminal to apply)\n"));
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(want_err, res.err);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "\nmox commit: 1 routed, 0 coupled, 1 manual\n"));
}

test "commit --dry-run: two keys routed from one layered file count as the one unit --yes commits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "y = 1\nz = 1\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "w = 1\n");
    const h = try setup(a, io, &tmp, .{ .os = "darwin" });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf("config.toml");
    try editLive(io, a, live, "y = 1", "y = 2");
    try editLive(io, a, live, "z = 1", "z = 2");

    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings("", dry.err);
    try std.testing.expect(std.mem.endsWith(u8, dry.out, "\nmox commit: 1 routable, 0 coupled, 0 manual (report only; run without --dry-run on a terminal to apply)\n"));
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "\nmox commit: 1 routed, 0 coupled, 0 manual\n"));
}

test "commit --dry-run: two line hunks routed from one plain file count as the one unit --yes commits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\nexport C=3\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "A=1", "A=11");
    try editLive(io, a, live, "C=3", "C=33");

    const dry = try h.run(&.{ "mox", "commit", "--dry-run" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings("", dry.err);
    try std.testing.expect(std.mem.endsWith(u8, dry.out, "\nmox commit: 1 routable, 0 coupled, 0 manual (report only; run without --dry-run on a terminal to apply)\n"));
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "\nmox commit: 1 routed, 0 coupled, 0 manual\n"));
}

test "commit: chained coupling renames apply in one pass over a target's tokens" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.aenv", "note alphatoken\n");
    try writeRepo(io, &tmp, "repo/src/.benv", "note betatokens\n");
    try writeRepo(io, &tmp, "repo/src/.cenv", "alphatoken betatokens\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "alphatoken", "betatokens");
    try editLive(io, a, try h.liveOf(".benv"), "betatokens", "gammatoken");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqualStrings("betatokens gammatoken\n", try read(io, a, try h.srcOf(".cenv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 2 coupled") != null);
}

test "commit: one token renamed two different ways couples neither rename" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.aenv", "note alphatoken\n");
    try writeRepo(io, &tmp, "repo/src/.benv", "note alphatoken\n");
    try writeRepo(io, &tmp, "repo/src/.cenv", "alphatoken signing\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "alphatoken", "betatokens");
    try editLive(io, a, try h.liveOf(".benv"), "alphatoken", "gammatoken");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("alphatoken signing\n", try read(io, a, try h.srcOf(".cenv")));
    try std.testing.expectEqualStrings("note betatokens\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expectEqualStrings("note gammatoken\n", try read(io, a, try h.srcOf(".benv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings("mox commit: coupling: \"alphatoken\" is renamed to different names in this commit; not updating it anywhere else\n", res.err);
}

test "commit: a file with an unrouted hunk beside a manual one is not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "export ONE=1\nexport SPACER1=1\nexport TWO=2\nexport SPACER2=1\nexport THREE=3\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.zshrc", src);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "ONE=1", "ONE=11");
    try editLive(io, a, live, "TWO=2", "TWO=22");
    try editLive(io, a, live, "THREE=3", "THREE=33");

    // ONE universal, TWO to the private layer (no automatic route), THREE
    // held as manual.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "1\n4\nm\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(src, try read(io, a, try h.srcOf(".zshrc")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.zshrc") == null);
    const left = try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n", .{live});
    try std.testing.expectEqualStrings(left, res.err);
}

test "commit: a coupling rename is not applied over a line another file routed with the old token" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "email = old@example.com\n");
    try writeRepo(io, &tmp, "repo/src/.mysigners", "old@example.com signing\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".myenv"), "old@example.com", "new@example.com");
    try editLive(io, a, try h.liveOf(".mysigners"), "old@example.com signing", "old@example.com signing extra");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("old@example.com signing extra\n", try read(io, a, try h.srcOf(".mysigners")));
    try std.testing.expectEqualStrings("email = new@example.com\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.mysigners") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: an edit routed into {s} keeps \"old@example.com\"; not renaming it there\n", .{try h.srcOf(".mysigners")}), res.err);
}

test "commit: a coupling target whose only hunk was left unrouted is not committed and its coupled update is undone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkatoken\n");
    const target_src = "note quokkatoken\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.tsigners", target_src);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkatoken", "wombattoken");
    try editLive(io, a, try h.liveOf(".tsigners"), "quokkatoken", "wombattoken");

    // .aenv routes the rename; .tsigners sends the same rename to the
    // private layer (no automatic route); the coupled update into
    // .tsigners is accepted.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n4\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    try std.testing.expectEqualStrings(target_src, try read(io, a, try h.srcOf(".tsigners")));
    try std.testing.expectEqualStrings("note wombattoken\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    // The target's own line names its unrouted hunk, so the undone line
    // only says it was not committed.
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted; not committed\n" ++
        "mox commit: coupled update to ~/.tsigners undone: ~/.tsigners was not committed\n", .{try h.liveOf(".tsigners")}), res.err);
}

const shared_abbrs = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n";

test "commit: a restore that fails saves every path the run still has edited, not only the paths due this round" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", shared_abbrs);
    const x_src = "# mox: for entry in \"data/abbrs.toml\"\nkey: <entry.key>\n# mox: end\nset -g spacer 1\nset -g greeting hello\n";
    try writeRepo(io, &tmp, "repo/src/.abbrs", x_src);
    const y_src = "# mox: for entry in \"data/abbrs.toml\"\nexpansion: <entry.expansion>\n# mox: end\nexport KEEP=1\nexport SPACER=1\nexport MIDDLE=1\nexport EDITOR=vim\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.zaliases", y_src);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const abbrs_before = (try appliedContent(h, ".abbrs")).?;

    try editLive(io, a, try h.liveOf(".abbrs"), "key: ll\n", "key: lll\n");
    try editLive(io, a, try h.liveOf(".abbrs"), "greeting hello", "greeting howdy");
    try editLive(io, a, try h.liveOf(".zaliases"), "git status\n", "git status -sb\n");
    try editLive(io, a, try h.liveOf(".zaliases"), "SPACER=1", "SPACER=2");
    try editLive(io, a, try h.liveOf(".zaliases"), "EDITOR=vim", "EDITOR=nvim");

    // .zaliases fails (its EDITOR line goes to the private layer), so the
    // first round restores its base and the shared data file; the restore
    // of its base fails. .abbrs would fail only in the next round, for the
    // restored data file, and its base would be restored then. Writes of
    // .zaliases: an impact simulation's edit and its scoped journal's
    // restore for each of its two shared hunks, the write phase, then the
    // settling restore.
    const y_path = try h.srcOf(".zaliases");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, y_path, 6);
    const res = try faulty.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ny\ny\n1\n4\n");
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    try std.testing.expect(std.mem.indexOf(u8, res.out, "  committed ") == null);
    try std.testing.expectEqualStrings(abbrs_before, (try appliedContent(h, ".abbrs")).?);

    // .abbrs's base still holds this run's edit, so its pre-run bytes are
    // saved beside those of the base that could not be restored; the data
    // file was restored and needs no copy.
    const dir = try recoveryDir(h);
    const x_path = try h.srcOf(".abbrs");
    try std.testing.expect(!std.mem.eql(u8, x_src, try read(io, a, x_path)));
    const x_copy = try std.fs.path.join(a, &.{ dir, "repo", "src", ".abbrs" });
    try std.testing.expectEqualStrings(x_src, try read(io, a, x_copy));
    try std.testing.expectEqualStrings(y_src, try read(io, a, try std.fs.path.join(a, &.{ dir, "repo", "src", ".zaliases" })));
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ dir, "repo", "data", "abbrs.toml" })));
    try std.testing.expectEqualStrings(shared_abbrs, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" })));
    const y_copy = try std.fs.path.join(a, &.{ dir, "repo", "src", ".zaliases" });
    const want = try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: could not restore {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ try h.liveOf(".zaliases"), y_path, x_path, x_copy, y_path, y_copy });
    try std.testing.expectEqualStrings(want, res.err);
}

test "commit: a restore that fails names a path the run created and still restores the facts file due that round" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", shared_abbrs);
    const x_src = "# mox: for entry in \"data/abbrs.toml\"\nkey: <entry.key>\n# mox: end\nexport KEEP=1\nexport PAGER=less\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.abbrs", x_src);
    const email_line = "export EMAIL=<machine.email | default \"nobody@example.com\">\n";
    const y_src = "# mox: for entry in \"data/abbrs.toml\"\nexpansion: <entry.expansion>\n# mox: end\nexport KEEP=1\nexport SPACER=1\nexport MIDDLE=1\nexport EDITOR=vim\nexport MIDDLE2=1\n" ++ email_line ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.zaliases", y_src);
    const facts_before = "email = \"old@home.com\"\n";
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", facts_before);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "key: ll\n", "key: lll\n");
    try editLive(io, a, try h.liveOf(".abbrs"), "PAGER=less", "PAGER=more");
    try editLive(io, a, try h.liveOf(".zaliases"), "git status\n", "git status -sb\n");
    try editLive(io, a, try h.liveOf(".zaliases"), "SPACER=1", "SPACER=2");
    try editLive(io, a, try h.liveOf(".zaliases"), "EDITOR=vim", "EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".zaliases"), "EMAIL=old@home.com", "EMAIL=new@home.com");

    // .abbrs narrows its PAGER line to this machine's os, creating a
    // fragment. .zaliases routes its email to the fact and fails for its
    // EDITOR line; the restore of its base fails, and the facts file due in
    // the same round is still put back. Its sixth write is that restore, as
    // above.
    const y_path = try h.srcOf(".zaliases");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, y_path, 6);
    const res = try faulty.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n2\ny\n1\n4\nf\n");
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  committed ") == null);

    const dir = try recoveryDir(h);
    try std.testing.expectEqualStrings(x_src, try read(io, a, try std.fs.path.join(a, &.{ dir, "repo", "src", ".abbrs" })));
    try std.testing.expectEqualStrings(y_src, try read(io, a, try std.fs.path.join(a, &.{ dir, "repo", "src", ".zaliases" })));
    try std.testing.expect(!exists(io, try std.fs.path.join(a, &.{ dir, "facts" })));
    try std.testing.expectEqualStrings(facts_before, try read(io, a, try h.homePath(".config/mox/facts.toml")));

    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    const frag = try h.srcOf(try std.fmt.allocPrint(a, ".abbrs.d/os/{s}", .{m_state.os}));
    try std.testing.expect(exists(io, frag));
    const want = try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: could not restore {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: {s} did not exist before this commit; delete it to restore it\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{
        try h.liveOf(".zaliases"),
        y_path,
        try h.srcOf(".abbrs"),
        try std.fs.path.join(a, &.{ dir, "repo", "src", ".abbrs" }),
        frag,
        y_path,
        try std.fs.path.join(a, &.{ dir, "repo", "src", ".zaliases" }),
    });
    try std.testing.expectEqualStrings(want, res.err);
}

test "commit: a restore that fails still reverts by name the facts due that round" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.afile", "export PAGER=<machine.pager | default \"less\">\n");
    const p_src = "export SHELL_OK=1\nexport SPACER=1\nexport MIDDLE=1\nexport EDITOR=vim\nexport MIDDLE2=1\nexport EMAIL=<machine.email | default \"nobody@example.com\">\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.pfile", p_src);
    const facts_before = "email = \"old@home.com\"\npager = \"less\"\n";
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", facts_before);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    try editLive(io, a, try h.liveOf(".afile"), "PAGER=less", "PAGER=more");
    try editLive(io, a, try h.liveOf(".pfile"), "SPACER=1", "SPACER=2");
    try editLive(io, a, try h.liveOf(".pfile"), "EDITOR=vim", "EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".pfile"), "EMAIL=old@home.com", "EMAIL=new@home.com");

    // .afile routes its pager to the fact and passes. .pfile routes SPACER
    // universally, EDITOR to the private layer (fails) and its email to the
    // fact; the restore of its base, its sixth write, fails, and its email
    // is still reverted by name.
    const p_path = try h.srcOf(".pfile");
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, p_path, 6);
    const res = try faulty.runWithInput(&.{ "mox", "commit", "--color=never" }, "f\n1\n4\nf\n");
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  committed ") == null);

    const facts_now = try read(io, a, try h.homePath(".config/mox/facts.toml"));
    try std.testing.expect(std.mem.indexOf(u8, facts_now, "old@home.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts_now, "new@home.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, facts_now, "pager = \"more\"") != null);
    const dir = try recoveryDir(h);
    const facts_copy = try std.fs.path.join(a, &.{ dir, "facts" });
    const p_copy = try std.fs.path.join(a, &.{ dir, "repo", "src", ".pfile" });
    try std.testing.expectEqualStrings(facts_before, try read(io, a, facts_copy));
    try std.testing.expectEqualStrings(p_src, try read(io, a, p_copy));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: could not restore {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: ~/.config/mox/facts.toml: its pre-run bytes are saved in {s}\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ try h.liveOf(".pfile"), p_path, facts_copy, p_path, p_copy }), res.err);
}

test "commit: a coupling rename into a data row field a loop template reads through a default is dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\nkey = \"ll\"\nquokkanote = \"listing\"\n";
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key> <entry.quokkanote | default \"none\">\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll listing", "abbr lll listing");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\nkey = \"lll\"\nquokkanote = \"listing\"\n", try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: an edit routed into {s} keeps \"quokkanote\"; not renaming it there\n", .{try h.srcOf("abbrs.toml")}), res.err);
}

/// A generator over data/entries.toml and a loop file with `loop_body` over
/// the same source.
fn writeLeafAndLoopFixture(io: Io, a: std.mem.Allocator, tmp: *std.testing.TmpDir, loop_body: []const u8) !void {
    try writeRepo(io, tmp, "repo/data/entries.toml", "[[entries]]\nslug = \"a\"\nvalue = \"1\"\nlabel = \"x\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\nlabel = \"y\"\n");
    try writeRepo(io, tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value>\n# mox: end\n");
    try writeRepo(io, tmp, "repo/src/.zloop", try std.fmt.allocPrint(a, "# mox: for entry in \"data/entries.toml\"\n{s}\n# mox: end\n", .{loop_body}));
}

/// Commit with the edited leaf's live copy unreadable from its second open
/// on: routing reads it, verification cannot, so the leaf fails.
fn commitFailingLeaf(h: Harness) !testutil.RunResult {
    var vtable: Io.VTable = undefined;
    const faulty = try failingCallsThrough(h, &vtable, .open, try h.liveOf(".config/id-a.inc"), 2, std.math.maxInt(usize));
    defer restore_fail_target = "";
    return faulty.run(&.{ "mox", "commit", "--yes", "--color=never" });
}

test "commit: a row write a loop file and a failing leaf both made stays under the loop file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeLeafAndLoopFixture(io, a, &tmp, "val <entry.value>");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" });

    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=99");
    try editLive(io, a, try h.liveOf(".zloop"), "val 1", "val 99");

    const res = try commitFailingLeaf(h);
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    // The leaf fails, but the row write is also the loop file's, which
    // passes: the data file keeps it.
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, data_path), "value = \"99\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.zloop") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.config/id-a.inc") == null);
    try std.testing.expectEqualStrings("mox commit: ~/.config/id-a.inc: recomposed generator output does not match; not committed\n", res.err);
}

test "commit: a failing leaf restores a loop file's data source and the loop file is not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The loop file renders a field the leaf's row write leaves alone.
    try writeLeafAndLoopFixture(io, a, &tmp, "tag <entry.label>");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" });
    const data_before = try read(io, a, data_path);

    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=99");
    try editLive(io, a, try h.liveOf(".zloop"), "tag y", "tag w");

    const res = try commitFailingLeaf(h);
    try std.testing.expectEqual(@as(u8, 1), res.rc);

    try std.testing.expectEqualStrings(data_before, try read(io, a, data_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.zloop") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.config/id-a.inc") == null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: ~/.config/id-a.inc: recomposed generator output does not match; not committed\n" ++
        "mox commit: ~/.zloop: not committed: {s} was restored because ~/.config/id-a.inc was not committed; commit it on its own with 'mox commit ~/.zloop'\n", .{data_path}), res.err);
}

test "commit: a coupling rename into a data row field read through another field's stored value is dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\na = \"<b>/bin\"\nb = \"quokkanote\"\nc = \"listing\"\n";
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.a | default \"none\"> <entry.c>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr quokkanote/bin listing", "abbr quokkanote/bin detail");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\na = \"<b>/bin\"\nb = \"quokkanote\"\nc = \"detail\"\n", try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: an edit routed into {s} keeps \"quokkanote\"; not renaming it there\n", .{try h.srcOf("abbrs.toml")}), res.err);
}

test "commit: a coupling rename into a data row field only a bare capture's stored value names is applied" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\na = \"<b>/bin\"\nb = \"quokkanote\"\nc = \"listing\"\n";
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <a | default \"none\"> <entry.c>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr <b>/bin listing", "abbr <b>/bin detail");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\na = \"<b>/bin\"\nb = \"wombatnote\"\nc = \"detail\"\n", try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 1 coupled") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a coupling rename that only touches comments in a routed data row is applied" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]  # quokkanote\nkey = \"ll\"\na = \"x\"  # quokkanote\n";
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key> <entry.a | default \"none\">\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll x", "abbr lll x");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]  # wombatnote\nkey = \"lll\"\na = \"x\"  # wombatnote\n", try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 1 coupled") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a coupled update into a generator source is verified through its leaves" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/entries.toml", "[[entries]]\nslug = \"a\"\n\n[[entries]]\nslug = \"b\"\n");
    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.slug> quokkanote\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqualStrings("# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.slug> wombatnote\n# mox: end\n", try read(io, a, try h.srcOf(".config/gen.inc")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 1 coupled") != null);
}

test "commit: a coupling rename into a generator source whose routed template holds the token is dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gen_src = "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value> quokkanote\n# mox: end\n";
    const data = "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\n";
    try writeRepo(io, &tmp, "repo/data/entries.toml", data);
    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", gen_src);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1 quokkanote", "key=99 quokkanote");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    // The leaf's row write was checked against the template the rename
    // would rewrite, so the rename is not offered there.
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings(gen_src, try read(io, a, try h.srcOf(".config/gen.inc")));
    try std.testing.expectEqualStrings("[[entries]]\nslug = \"a\"\nvalue = \"99\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\n", try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data/entries.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.config/id-a.inc") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled, 0 manual") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: {s} holds \"quokkanote\" in a loop a row write was routed through; not renaming it there\n", .{try h.srcOf(".config/gen.inc")}), res.err);
}

test "commit: a coupled update that changes nothing in a generator source leaves a failing leaf's line the only one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The generator holds the old token only inside a longer one, so the
    // rename into it changes nothing. It renders under os=linux too, which
    // the routed rows change: were it verified as a coupling target, that
    // configuration changing would fail it with a line of its own.
    const gen_src = "# mox: for entry in \"data/entries.toml\" when os=darwin or os=linux into \"id-<entry.slug>.inc\"\nkey=<entry.value> quokkanotes\n# mox: end\n";
    const data = "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\n";
    try writeRepo(io, &tmp, "repo/data/entries.toml", data);
    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", gen_src);
    try writeRepo(io, &tmp, "repo/src/.zloop", "# mox: for entry in \"data/entries.toml\"\nval <entry.slug> <entry.value>\n# mox: end\nexport SPACER=1\nexport EDITOR=vim\n" ++ os_blocks);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    var g = mox.coupling.graph.Graph.init(a);
    try g.addOccurrence("quokkanote", try h.srcOf(".aenv"), 5, 15);
    try g.addOccurrence("quokkanote", try h.srcOf(".config/gen.inc"), 0, 10);
    try mox.coupling.store.saveGraph(a, io, try std.fs.path.join(a, &.{ h.state, "coupling" }), &g);

    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1 ", "key=99 ");
    try editLive(io, a, try h.liveOf(".zloop"), "val b 2", "val b 7");
    try editLive(io, a, try h.liveOf(".zloop"), "EDITOR=vim", "EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    // .zloop sends its EDITOR line to the private layer and fails, so the
    // data source is restored and the leaf, which routed a row into it, is
    // not committed.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ny\ny\n4\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(gen_src, try read(io, a, try h.srcOf(".config/gen.inc")));
    try std.testing.expectEqualStrings(data, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/.config/id-a.inc: not committed: {s} was restored because ~/.zloop was not committed; commit it on its own with 'mox commit ~/.config/id-a.inc'\n", .{
        try h.liveOf(".zloop"),
        try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" }),
    }), res.err);
}

test "commit: --dry-run predicts a coupling rename into a generator source whose routed template holds the token is dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gen_src = "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value> quokkanote\n# mox: end\n";
    const data = "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\n";
    try writeRepo(io, &tmp, "repo/data/entries.toml", data);
    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", gen_src);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1 quokkanote", "key=99 quokkanote");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(gen_src, try read(io, a, try h.srcOf(".config/gen.inc")));
    try std.testing.expectEqualStrings(data, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data/entries.toml" })));
    try std.testing.expectEqualStrings("note quokkanote\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routable, 0 coupled, 0 manual") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: {s} holds \"quokkanote\" in a loop a row write was routed through; not renaming it there\n", .{try h.srcOf(".config/gen.inc")}), res.err);
}

test "commit: a coupling rename into a generator source with a routed leaf is dropped, and the leaf settles with its data source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The token is only in a default no row renders, but the template holds
    // it, and every token of a generator source is in its directive lines or
    // its template.
    const gen_src = "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value> <entry.note | default \"quokkanote\">\n# mox: end\n";
    const data = "[[entries]]\nslug = \"a\"\nvalue = \"1\"\nnote = \"x\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\nnote = \"y\"\n";
    try writeRepo(io, &tmp, "repo/data/entries.toml", data);
    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", gen_src);
    try writeRepo(io, &tmp, "repo/src/.zloop", "# mox: for entry in \"data/entries.toml\"\nval <entry.slug> <entry.value>\n# mox: end\nexport SPACER=1\nexport EDITOR=vim\n" ++ os_blocks);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1 ", "key=99 ");
    try editLive(io, a, try h.liveOf(".zloop"), "val b 2", "val b 7");
    try editLive(io, a, try h.liveOf(".zloop"), "EDITOR=vim", "EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    // .zloop fails, the data source is restored, and the leaf fails with it.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ny\ny\n4\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(gen_src, try read(io, a, try h.srcOf(".config/gen.inc")));
    try std.testing.expectEqualStrings(data, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: {s} holds \"quokkanote\" in a loop a row write was routed through; not renaming it there\n" ++
        "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/.config/id-a.inc: not committed: {s} was restored because ~/.zloop was not committed; commit it on its own with 'mox commit ~/.config/id-a.inc'\n", .{
        try h.srcOf(".config/gen.inc"),
        try h.liveOf(".zloop"),
        try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" }),
    }), res.err);
}

test "commit: a coupled update that changes nothing leaves its file out of verification" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // .tloop holds the old token only inside a longer one, so the rename
    // into it changes nothing; the row .abbrs routes changes .tloop's linux
    // configuration, which a coupling target could not take.
    const data = "[[abbrs]]\nkey = \"ll\"\n";
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nkey: <entry.key>\n# mox: end\n");
    const tloop = "note quokkanotes\n# mox: when os=linux\n# mox: for entry in \"data/abbrs.toml\"\nkey <entry.key>\n# mox: end\n# mox: end\n";
    try writeRepo(io, &tmp, "repo/src/.tloop", tloop);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    var g = mox.coupling.graph.Graph.init(a);
    try g.addOccurrence("quokkanote", try h.srcOf(".aenv"), 5, 15);
    try g.addOccurrence("quokkanote", try h.srcOf(".tloop"), 5, 15);
    try mox.coupling.store.saveGraph(a, io, try std.fs.path.join(a, &.{ h.state, "coupling" }), &g);

    try editLive(io, a, try h.liveOf(".abbrs"), "key: ll", "key: lll");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqualStrings(tloop, try read(io, a, try h.srcOf(".tloop")));
    try std.testing.expectEqualStrings("[[abbrs]]\nkey = \"lll\"\n", try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 1 coupled, 0 manual") != null);
}

test "commit: a coupled update into a generator source with several configurations is simulated as a generator" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gen_src = "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.slug> quokkanote\n# mox: when os=linux\nlinux only\n# mox: end\n# mox: end\n";
    try writeRepo(io, &tmp, "repo/data/entries.toml", "[[entries]]\nslug = \"a\"\n");
    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", gen_src);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf(".config/gen.inc")), "wombatnote") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 1 coupled") != null);
}

test "commit: a coupled update that leaves its target uncomposable in simulation is undone, not an abort" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zshrc = "export Q=<machine.quokkanote>\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.zshrc", zshrc);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note machine.quokkanote\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "quokkanote = \"somevalue\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "machine.quokkanote", "machine.wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(zshrc, try read(io, a, try h.srcOf(".zshrc")));
    try std.testing.expectEqualStrings("note machine.wombatnote\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings("mox commit: coupled update to ~/.zshrc undone: ~/.zshrc could not take it (recompose failed: UnknownMachineField)\n", res.err);
}

test "commit: a coupled update that leaves a generator target uncomposable in simulation is undone, not an abort" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gen_src = "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<machine.quokkanote>\n# mox: when os=linux\nlinux only\n# mox: end\n# mox: end\n";
    try writeRepo(io, &tmp, "repo/data/entries.toml", "[[entries]]\nslug = \"a\"\n");
    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", gen_src);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note machine.quokkanote\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "quokkanote = \"somevalue\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "machine.quokkanote", "machine.wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(gen_src, try read(io, a, try h.srcOf(".config/gen.inc")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings("mox commit: coupled update to ~/.config/gen.inc undone: ~/.config/gen.inc could not take it (recompose failed: UnknownMachineField)\n", res.err);
}

/// A loop file reading the managed data file src/abbrs.toml through
/// `data_spec`, a symlink when `through_link`; the loop file ends in `tail`.
/// The loop's first row and abbrs.toml's own live copy are both edited.
fn writeSpelledDataFixture(io: Io, a: std.mem.Allocator, tmp: *std.testing.TmpDir, data_spec: []const u8, through_link: bool, tail: []const u8) !Harness {
    try writeRepo(io, tmp, "repo/src/abbrs.toml", shared_abbrs);
    try writeRepo(io, tmp, "repo/src/.abbrs", try std.fmt.allocPrint(a, "# mox: for entry in \"{s}\"\nkey: <entry.key>\n# mox: end\n{s}", .{ data_spec, tail }));
    if (through_link) {
        try tmp.dir.createDirPath(io, "repo/data");
        try tmp.dir.symLink(io, "../src/abbrs.toml", "repo/data/abbrs.toml", .{});
    }
    const h = try setup(a, io, tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".abbrs"), "key: ll\n", "key: lll\n");
    try editLive(io, a, try h.liveOf("abbrs.toml"), "key = \"ll\"", "key = \"lll\"");
    try editLive(io, a, try h.liveOf("abbrs.toml"), "\"git status\"", "\"git status -sb\"");
    return h;
}

/// Both files commit: the row write and abbrs.toml's own line edits land in
/// one planned write of the one file.
fn expectSpelledDataCommits(io: Io, a: std.mem.Allocator, h: Harness) !void {
    try editLive(io, a, try h.liveOf(".abbrs"), "greeting hello", "greeting howdy");
    // .abbrs: route the row, decline the literal line. abbrs.toml: both lines.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ns\ny\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(
        "[[abbrs]]\nkey = \"lll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status -sb\"\n",
        try read(io, a, try h.srcOf("abbrs.toml")),
    );
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/abbrs.toml") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were declined and remain only in the live file; the routed edits were committed to the sources -- run 'mox apply' to discard them\n", .{try h.liveOf(".abbrs")}), res.err);
}

/// The loop file fails for its EDITOR line, sent to the private layer, so
/// its row write is dead and abbrs.toml, owning edits to the same file under
/// another spelling, is not committed either.
fn expectSpelledDataFailsTogether(io: Io, a: std.mem.Allocator, h: Harness) !void {
    try editLive(io, a, try h.liveOf(".abbrs"), "EDITOR=vim", "EDITOR=nvim");
    // abbrs.toml declines its key line, which the row write also makes, and
    // routes the other: the row write stays .abbrs's alone.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n4\ns\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(shared_abbrs, try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/abbrs.toml") == null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/abbrs.toml: not committed: {s} was restored because ~/.abbrs was not committed; commit it on its own with 'mox commit ~/abbrs.toml'\n", .{ try h.liveOf(".abbrs"), try h.srcOf("abbrs.toml") }), res.err);
}

const spelled_fail_tail = "export SPACER=1\nexport EDITOR=vim\n" ++ os_blocks;

test "commit: a data source reached through a symlink and the file's own line edits are one write" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try writeSpelledDataFixture(io, a, &tmp, "data/abbrs.toml", true, "set -g greeting hello\n");
    try expectSpelledDataCommits(io, a, h);
}

test "commit: a data source spelled with ./ and the file's own line edits are one write" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try writeSpelledDataFixture(io, a, &tmp, "src/./abbrs.toml", false, "set -g greeting hello\n");
    try expectSpelledDataCommits(io, a, h);
}

test "commit: a failing loop file restores a data source reached through a symlink under the file's own line edits" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try writeSpelledDataFixture(io, a, &tmp, "data/abbrs.toml", true, spelled_fail_tail);
    try expectSpelledDataFailsTogether(io, a, h);
}

test "commit: a failing loop file restores a data source spelled with ./ under the file's own line edits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try writeSpelledDataFixture(io, a, &tmp, "src/./abbrs.toml", false, spelled_fail_tail);
    try expectSpelledDataFailsTogether(io, a, h);
}

test "commit: a coupled update that leaves a single-configuration target uncomposable is undone before planning, reported once" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zshrc = "export Q=<machine.quokkanote>\n";
    try writeRepo(io, &tmp, "repo/src/.zshrc", zshrc);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note machine.quokkanote\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "quokkanote = \"somevalue\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "machine.quokkanote", "machine.wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(zshrc, try read(io, a, try h.srcOf(".zshrc")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(
        "mox commit: coupled update to ~/.zshrc undone: ~/.zshrc could not take it (recompose failed: UnknownMachineField)\n",
        res.err,
    );
}

test "commit: a coupled update that leaves a routed target uncomposable is undone and the target's own edit commits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=alpha\nexport Q=<machine.quokkanote>\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note machine.quokkanote\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "quokkanote = \"somevalue\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "machine.quokkanote", "machine.wombatnote");
    try editLive(io, a, try h.liveOf(".zshrc"), "A=alpha", "A=alpha gamma");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("export A=alpha gamma\nexport Q=<machine.quokkanote>\n", try read(io, a, try h.srcOf(".zshrc")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.zshrc") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(
        "mox commit: coupled update to ~/.zshrc undone: ~/.zshrc could not take it (recompose failed: UnknownMachineField)\n",
        res.err,
    );
}

test "commit: a coupling rename into a routed row field after a multi-line string holding a header line is dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\nkey = \"ll\"\ndesc = \"\"\"\n[x]\n\"\"\"\na = \"quokkanote\"\n";
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key> <entry.a>\n# mox: end\nset -g spacer 1\nset -g greeting hello\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll quokkanote", "abbr lll quokkanote");
    try editLive(io, a, try h.liveOf(".abbrs"), "greeting hello", "greeting howdy");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    // .abbrs: route the row, decline the literal line; .aenv: route the
    // rename; accept any coupled update offered.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ns\ny\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\nkey = \"lll\"\ndesc = \"\"\"\n[x]\n\"\"\"\na = \"quokkanote\"\n", try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: an edit routed into {s} keeps \"quokkanote\"; not renaming it there\n" ++
        "mox commit: {s}: 1 hunk(s) were declined and remain only in the live file; the routed edits were committed to the sources -- run 'mox apply' to discard them\n", .{ try h.srcOf("abbrs.toml"), try h.liveOf(".abbrs") }), res.err);
}

test "commit: a coupling rename into a data row field a loop's where reads is dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/abbrs.toml", "[[abbrs]]\nkey = \"ll\"\nquokkanote = \"yes\"\n");
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\" where entry.quokkanote\nabbr <entry.key>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll", "abbr lll");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\nkey = \"lll\"\nquokkanote = \"yes\"\n", try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: an edit routed into {s} keeps \"quokkanote\"; not renaming it there\n", .{try h.srcOf("abbrs.toml")}), res.err);
}

test "commit: a coupling rename into a data row field a generator's into path reads is dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/entries.toml", "[[entries]]\nquokkanote = \"a\"\nvalue = \"1\"\n");
    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"src/entries.toml\" into \"id-<entry.quokkanote>.inc\"\nkey=<entry.value>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=99");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[entries]]\nquokkanote = \"a\"\nvalue = \"99\"\n", try read(io, a, try h.srcOf("entries.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.config/id-a.inc") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: an edit routed into {s} keeps \"quokkanote\"; not renaming it there\n", .{try h.srcOf("entries.toml")}), res.err);
}

test "commit: a data source hard-linked to a managed file is one path with that file's own edits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/abbrs.toml", shared_abbrs);
    try tmp.dir.createDirPath(io, "repo/data");
    try Io.Dir.hardLink(tmp.dir, "repo/src/abbrs.toml", tmp.dir, "repo/data/abbrs.toml", io, .{});
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nkey: <entry.key>\n# mox: end\n" ++ spelled_fail_tail);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".abbrs"), "key: ll\n", "key: lll\n");
    try editLive(io, a, try h.liveOf(".abbrs"), "EDITOR=vim", "EDITOR=nvim");
    try editLive(io, a, try h.liveOf("abbrs.toml"), "key = \"ll\"", "key = \"lll\"");
    try editLive(io, a, try h.liveOf("abbrs.toml"), "\"git status\"", "\"git status -sb\"");

    // .abbrs: route the row, send EDITOR to the private layer, which leaves
    // it unrouted. abbrs.toml: decline its first line, which the row write
    // also makes, and route the second.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n4\ns\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(shared_abbrs, try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expectEqualStrings(shared_abbrs, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/abbrs.toml") == null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/abbrs.toml: not committed: {s} was restored because ~/.abbrs was not committed; commit it on its own with 'mox commit ~/abbrs.toml'\n", .{ try h.liveOf(".abbrs"), try h.srcOf("abbrs.toml") }), res.err);
}

test "commit: every managed file hard-linked to a coupled update's path is verified as its target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const linked = "note quokkanote\nexport A=1\n";
    try writeRepo(io, &tmp, "repo/src/.ha", linked);
    try Io.Dir.hardLink(tmp.dir, "repo/src/.ha", tmp.dir, "repo/src/.hb", io, .{});
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");
    try editLive(io, a, try h.liveOf(".hb"), "A=1", "A=2");

    // .hb's live copy keeps the old token, so .hb cannot take the update
    // into the file it shares with .ha, and .ha loses it too.
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(linked, try read(io, a, try h.srcOf(".ha")));
    try std.testing.expectEqualStrings("note wombatnote\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings("mox commit: coupled update to ~/.ha undone: ~/.hb was not committed\n" ++
        "mox commit: coupled update to ~/.hb undone: ~/.hb could not take it (its recomposed output differs from live); ~/.hb not committed\n", res.err);
}

test "commit: a coupled update whose simulation fails for one hard-linked target is undone for every target before planning" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const linked = "note quokkanote\nexport A=1\n";
    try writeRepo(io, &tmp, "repo/src/.ha", linked);
    try Io.Dir.hardLink(tmp.dir, "repo/src/.ha", tmp.dir, "repo/src/.hb", io, .{});
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    // .ha's simulation writes the file through its own name and passes;
    // .hb's, through .hb, fails at its first write.
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreatesThrough(h, &vtable, try h.srcOf(".hb"), 1, 1);
    const res = try faulty.run(&.{ "mox", "commit", "--yes", "--color=never" });
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(linked, try read(io, a, try h.srcOf(".ha")));
    try std.testing.expectEqualStrings("note wombatnote\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings("mox commit: coupled update to ~/.ha undone: ~/.hb could not take it (AccessDenied)\n" ++
        "mox commit: coupled update to ~/.hb undone: ~/.hb could not take it (AccessDenied)\n", res.err);
}

test "commit: a restore that fails for a data source outside the repo copies it under other/" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "ext/abbrs.toml", shared_abbrs);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/../../ext/abbrs.toml\"\nkey: <entry.key>\n# mox: end\n" ++ spelled_fail_tail);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".abbrs"), "key: ll\n", "key: lll\n");
    try editLive(io, a, try h.liveOf(".abbrs"), "EDITOR=vim", "EDITOR=nvim");

    // The row write lands, the unrouted EDITOR line fails the file, and the
    // restore of the data source fails.
    const data = try std.fs.path.join(a, &.{ h.root, "ext", "abbrs.toml" });
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, data, 4);
    const res = try faulty.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n4\n");
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    // The copy is other/1, the only entry of the recovery directory, and the
    // path is named in full.
    const recovery = try recoveryDir(h);
    var names: std.ArrayList([]const u8) = .empty;
    var walker = try (try Io.Dir.cwd().openDir(io, recovery, .{ .iterate = true })).walk(a);
    while (try walker.next(io)) |entry| try names.append(a, try a.dupe(u8, entry.path));
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    const copy = try std.fs.path.join(a, &.{ recovery, "other", "1" });
    try std.testing.expectEqualStrings(shared_abbrs, try read(io, a, copy));
    const real = try Io.Dir.cwd().realPathFileAlloc(io, data, a);
    // The failed restore names the path as the loop header spells it.
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: could not restore {s} (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: {s}: its pre-run bytes are saved in {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{
        try h.liveOf(".abbrs"),
        try std.fs.path.join(a, &.{ h.repo, "src", "../../ext/abbrs.toml" }),
        real,
        copy,
    }), res.err);
}

test "commit: a file failed by reverted facts names only the reverted facts it reads" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const email_line = "export EMAIL=<machine.email | default \"nobody@example.com\">\n";
    const nick_line = "export NICK=<machine.nick | default \"nobody\">\n";
    try writeRepo(io, &tmp, "repo/src/.pfile", "export SHELL_OK=1\nexport EDITOR=vim\nexport SPACER=1\n" ++ email_line ++ "export SPACER2=1\n" ++ nick_line ++ os_blocks);
    try writeRepo(io, &tmp, "repo/src/.rfile", email_line);
    const facts_before = "email = \"old@home.com\"\nnick = \"oldnick\"\n";
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", facts_before);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    try editLive(io, a, try h.liveOf(".pfile"), "EDITOR=vim", "EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".pfile"), "EMAIL=old@home.com", "EMAIL=new@home.com");
    try editLive(io, a, try h.liveOf(".pfile"), "NICK=oldnick", "NICK=newnick");
    try editLive(io, a, try h.liveOf(".rfile"), "EMAIL=old@home.com", "EMAIL=new@home.com");

    // .pfile: EDITOR to the private layer (fails), EMAIL and NICK to their
    // facts, both reverted in one round. .rfile reads only email.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "4\nf\nf\nd\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(facts_before, try read(io, a, try h.homePath(".config/mox/facts.toml")));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/.rfile: not committed: fact email was reverted because ~/.pfile was not committed; commit it on its own with 'mox commit ~/.rfile'\n", .{try h.liveOf(".pfile")}), res.err);
}

/// Two files renaming one token each, both coupled into ~/.tsigners, whose
/// own routed edit then leaves its recompose differing from live.
fn writeTwoRenamesIntoTargetFixture(io: Io, a: std.mem.Allocator, tmp: *std.testing.TmpDir, two: bool) !Harness {
    try writeRepo(io, tmp, "repo/src/.aenv", "note alphatoken1\n");
    try writeRepo(io, tmp, "repo/src/.benv", "note quokkatoken\n");
    try writeRepo(io, tmp, "repo/src/.tsigners", "alphatoken1 quokkatoken\nfoo=1\n");
    const h = try setup(a, io, tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    try editLive(io, a, try h.liveOf(".aenv"), "alphatoken1", "alphatoken2");
    if (two) try editLive(io, a, try h.liveOf(".benv"), "quokkatoken", "wombattoken");
    try editLive(io, a, try h.liveOf(".tsigners"), "foo=1", "foo=2");
    return h;
}

test "commit: two coupled updates into one failing target are one undone line and its only line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try writeTwoRenamesIntoTargetFixture(io, a, &tmp, true);

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("alphatoken1 quokkatoken\nfoo=1\n", try read(io, a, try h.srcOf(".tsigners")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(
        "mox commit: coupled update to ~/.tsigners undone: ~/.tsigners could not take it (its recomposed output differs from live); ~/.tsigners not committed\n",
        res.err,
    );
}

test "commit: a coupling target whose recompose differs from live is named only by its undone line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try writeTwoRenamesIntoTargetFixture(io, a, &tmp, false);

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.tsigners") == null);
    try std.testing.expectEqualStrings(
        "mox commit: coupled update to ~/.tsigners undone: ~/.tsigners could not take it (its recomposed output differs from live); ~/.tsigners not committed\n",
        res.err,
    );
}

test "commit: a generator leaf over a data source reached through a symlink and the data file's own edit are one write" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/entries.toml", "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\n");
    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value>\n# mox: end\n");
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.symLink(io, "../src/entries.toml", "repo/data/entries.toml", .{});
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The data file's live copy holds the leaf's row edit too, as a line
    // edit of its own, and one more line edit.
    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=99");
    try editLive(io, a, try h.liveOf("entries.toml"), "value = \"1\"", "value = \"99\"");
    try editLive(io, a, try h.liveOf("entries.toml"), "value = \"2\"", "value = \"7\"");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqualStrings(
        "[[entries]]\nslug = \"a\"\nvalue = \"99\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"7\"\n",
        try read(io, a, try h.srcOf("entries.toml")),
    );
    try std.testing.expect(isSymlink(io, try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.config/id-a.inc") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/entries.toml") != null);
}

test "commit: with MOX_REPO spelled through a symlink, a coupling rename and a row write into one data file are one write" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/abbrs.toml", "[[abbrs]]\nkey = \"ll\"\nnote = \"quokkanote\"\n");
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    try tmp.dir.symLink(io, "repo", "repolink", .{ .is_directory = true });
    const cwd = try std.process.currentPathAlloc(io, a);
    const link = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repolink" });
    const h = try setup(a, io, &tmp, .{ .extra_env = &.{.{ .name = "MOX_REPO", .value = link }} });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll", "abbr lll");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqualStrings("[[abbrs]]\nkey = \"lll\"\nnote = \"wombatnote\"\n", try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 1 coupled") != null);
}

test "commit: with MOX_REPO spelled through a symlink and a coupling graph under the real repo, a rename couples its target and not its origin" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkanote\n");
    try writeRepo(io, &tmp, "repo/src/.mysigners", "quokkanote signing\n");
    try tmp.dir.symLink(io, "repo", "repolink", .{ .is_directory = true });
    const cwd = try std.process.currentPathAlloc(io, a);
    const link = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repolink" });
    const h = try setup(a, io, &tmp, .{ .extra_env = &.{.{ .name = "MOX_REPO", .value = link }} });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    // The graph is keyed by the repo's real path; the commit walks the link.
    const real_env = try a.create(std.process.Environ.Map);
    real_env.* = try h.env.map.clone(a);
    try real_env.put("MOX_REPO", h.repo);
    var real = h;
    real.env = .{ .map = real_env };
    try std.testing.expectEqual(@as(u8, 0), (try real.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".myenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("note wombatnote\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expectEqualStrings("wombatnote signing\n", try read(io, a, try h.srcOf(".mysigners")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 1 coupled") != null);
}

test "commit: with MOX_REPO spelled through a symlink and a coupling graph under the real repo, a seed-once body is not coupled" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkanote\n");
    try writeRepo(io, &tmp, "repo/src/seed.local", "note quokkanote\n");
    try tmp.dir.symLink(io, "repo", "repolink", .{ .is_directory = true });
    const cwd = try std.process.currentPathAlloc(io, a);
    const link = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repolink" });
    const h = try setup(a, io, &tmp, .{ .extra_env = &.{.{ .name = "MOX_REPO", .value = link }} });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    // The graph, keyed by the repo's real path, indexes seed.local while it
    // is plain; it is marked seed-once afterwards.
    const real_env = try a.create(std.process.Environ.Map);
    real_env.* = try h.env.map.clone(a);
    try real_env.put("MOX_REPO", h.repo);
    var real = h;
    real.env = .{ .map = real_env };
    try std.testing.expectEqual(@as(u8, 0), (try real.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "[\"seed.local\"]\nseed_once = true\n");

    try editLive(io, a, try h.liveOf(".myenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("note wombatnote\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expectEqualStrings("note quokkanote\n", try read(io, a, try h.srcOf("seed.local")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "seed.local") == null);
}

test "commit: with MOX_REPO spelled through a symlink, a coupling decline recorded under the graph's real path applies" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkanote\n");
    try writeRepo(io, &tmp, "repo/src/.other", "quokkanote signing\n");
    try tmp.dir.symLink(io, "repo", "repolink", .{ .is_directory = true });
    const cwd = try std.process.currentPathAlloc(io, a);
    const link = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repolink" });
    const h = try setup(a, io, &tmp, .{ .extra_env = &.{.{ .name = "MOX_REPO", .value = link }} });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    const real_env = try a.create(std.process.Environ.Map);
    real_env.* = try h.env.map.clone(a);
    try real_env.put("MOX_REPO", h.repo);
    var real = h;
    real.env = .{ .map = real_env };
    try std.testing.expectEqual(@as(u8, 0), (try real.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    // Recorded with the target as the graph spells it, as older builds did.
    const coupling_dir = try std.fs.path.join(a, &.{ h.state, "coupling" });
    var declines = try mox.coupling.store.loadDeclines(a, io, coupling_dir);
    try declines.declinePair("quokkanote", try std.fs.path.join(a, &.{ link, "src", ".myenv" }), try h.srcOf(".other"));
    try mox.coupling.store.saveDeclines(a, io, coupling_dir, &declines);

    try editLive(io, a, try h.liveOf(".myenv"), "quokkanote", "wombatnote");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("quokkanote signing\n", try read(io, a, try h.srcOf(".other")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "Update?") == null);
}

test "commit: a coupled update into hard-linked bases is offered once" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.ha", "note quokkanote\n");
    try Io.Dir.hardLink(tmp.dir, "repo/src/.ha", tmp.dir, "repo/src/.hb", io, .{});
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("note wombatnote\n", try read(io, a, try h.srcOf(".ha")));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, res.out, "  update "));
    try std.testing.expect(std.mem.indexOf(u8, res.out, try std.fmt.allocPrint(a, "  update {s}: ", .{try h.srcOf(".ha")})) != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 1 coupled") != null);
}

test "commit: a coupling decline recorded for one hard-linked base applies to the file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.ha", "note quokkanote\n");
    try Io.Dir.hardLink(tmp.dir, "repo/src/.ha", tmp.dir, "repo/src/.hb", io, .{});
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    const coupling_dir = try std.fs.path.join(a, &.{ h.state, "coupling" });
    var declines = try mox.coupling.store.loadDeclines(a, io, coupling_dir);
    try declines.declinePair("quokkanote", try h.srcOf(".aenv"), try h.srcOf(".hb"));
    try mox.coupling.store.saveDeclines(a, io, coupling_dir, &declines);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("note quokkanote\n", try read(io, a, try h.srcOf(".ha")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "Update?") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
}

test "commit: a coupling rename that only touches a comment inside a routed row's multi-line array is applied" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/abbrs.toml", "[[abbrs]]\nkey = \"ll\"\ntags = [\n  \"x\",  # quokkanote\n  # quokkanote\n]\n");
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\" where entry.tags has \"x\"\nabbr <entry.key>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll", "abbr lll");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\nkey = \"lll\"\ntags = [\n  \"x\",  # wombatnote\n  # wombatnote\n]\n", try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 1 coupled") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a coupling rename into a base whose narrowing keeps the old token in its region block is dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zshrc = "export SHELL_OK=1\nset editor quokkanote\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.zshrc", zshrc);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");
    try editLive(io, a, try h.liveOf(".zshrc"), "editor quokkanote", "editor nano");

    // .aenv's rename routes; .zshrc's editor line narrows to this machine's
    // os, so the base keeps the original line in its region block.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n2\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "# mox: replace from \"os\"\nset editor quokkanote\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: an edit routed into {s} keeps \"quokkanote\"; not renaming it there\n", .{try h.srcOf(".zshrc")}), res.err);
}

test "commit: a coupled update into a routed target whose live copy keeps the old token is undone with the target's reason" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.config/t.toml", "quokkakey = 1\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkakey\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkakey", "wombatkey");
    try editLive(io, a, try h.liveOf(".config/t.toml"), "quokkakey = 1\n", "quokkakey = 1\nwombatkey = 2\n");

    // The target's own edit keeps quokkakey live, so with the rename its
    // recompose no longer matches live.
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("quokkakey = 1\n", try read(io, a, try h.srcOf(".config/t.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expectEqualStrings("mox commit: coupled update to ~/.config/t.toml undone: ~/.config/t.toml could not take it (its recomposed output differs from live); ~/.config/t.toml not committed\n", res.err);
}

test "commit: a coupled update its target's own edit already made is not undone when its origin is not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const myenv = "email = old@example.com\nexport SPACER=1\nexport EDITOR=vim\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.myenv", myenv);
    try writeRepo(io, &tmp, "repo/src/.mysigners", "old@example.com signing\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".myenv"), "old@example.com", "new@example.com");
    try editLive(io, a, try h.liveOf(".myenv"), "EDITOR=vim", "EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".mysigners"), "old@example.com", "new@example.com");

    // .myenv: the rename stays universal, the EDITOR line goes to the
    // private layer (no automatic route). .mysigners routes the same rename
    // by hand. Both coupled updates are accepted; each changes nothing its
    // target's own edit did not already write.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "1\n4\ny\ny\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(myenv, try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expectEqualStrings("new@example.com signing\n", try read(io, a, try h.srcOf(".mysigners")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.mysigners") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.myenv") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 1 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n", .{try h.liveOf(".myenv")}), res.err);
}

test "commit: a coupled update its target's own edit already made survives its origin's restore for another file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", shared_abbrs);
    const abbrs = "# mox: for entry in \"data/abbrs.toml\"\nkey: <entry.key>\n# mox: end\nset -g spacer 1\nnote quokkatok\n";
    try writeRepo(io, &tmp, "repo/src/.abbrs", abbrs);
    try writeRepo(io, &tmp, "repo/src/.onote", "note quokkatok\n");
    try writeRepo(io, &tmp, "repo/src/.zaliases", "# mox: for entry in \"data/abbrs.toml\"\nexpansion: <entry.expansion>\n# mox: end\nexport SPACER=1\nexport EDITOR=vim\n" ++ os_blocks);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "key: ll\n", "key: lll\n");
    try editLive(io, a, try h.liveOf(".abbrs"), "quokkatok", "wombattok");
    try editLive(io, a, try h.liveOf(".onote"), "quokkatok", "wombattok");
    try editLive(io, a, try h.liveOf(".zaliases"), "git status\n", "git status -sb\n");
    try editLive(io, a, try h.liveOf(".zaliases"), "EDITOR=vim", "EDITOR=nvim");

    // .zaliases sends its EDITOR line to the private layer and fails, so the
    // shared data file is restored and .abbrs, which routed a row into it,
    // is not committed. Both renames are accepted as coupled updates; each
    // changes nothing its target's own edit did not already write.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ny\ny\ny\n4\ny\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(abbrs, try read(io, a, try h.srcOf(".abbrs")));
    try std.testing.expectEqualStrings(shared_abbrs, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" })));
    try std.testing.expectEqualStrings("note wombattok\n", try read(io, a, try h.srcOf(".onote")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.onote") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 1 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/.abbrs: not committed: {s} was restored because ~/.zaliases was not committed; commit it on its own with 'mox commit ~/.abbrs'\n", .{
        try h.liveOf(".zaliases"),
        try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" }),
    }), res.err);
}

test "commit: a coupled update whose transient simulation write fails is undone before planning, not an abort" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "note quokkatoken\n");
    try writeRepo(io, &tmp, "repo/src/.tsigners", "quokkatoken signing\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".myenv"), "quokkatoken", "wombattoken");

    // The first write of .tsigners is the simulation's transient edit.
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreatesThrough(h, &vtable, try h.srcOf(".tsigners"), 1, 1);
    const res = try faulty.run(&.{ "mox", "commit", "--yes", "--color=never" });
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("quokkatoken signing\n", try read(io, a, try h.srcOf(".tsigners")));
    try std.testing.expectEqualStrings("note wombattoken\n", try read(io, a, try h.srcOf(".myenv")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.myenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings("mox commit: coupled update to ~/.tsigners undone: ~/.tsigners could not take it (AccessDenied)\n", res.err);
}

test "commit: a coupling rename of a routed row's key into a field the loop template reads is dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The template reads wombatnote, which the row does not hold yet: the
    // rename would make the row's quokkanote the field it renders.
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", "[[abbrs]]\nkey = \"ll\"\nquokkanote = \"listing\"\n");
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key> <entry.wombatnote | default \"x\">\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll x", "abbr lll x");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\nkey = \"lll\"\nquokkanote = \"listing\"\n", try read(io, a, try h.srcOf("abbrs.toml")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: an edit routed into {s} keeps \"quokkanote\"; not renaming it there\n", .{try h.srcOf("abbrs.toml")}), res.err);
}

test "commit: a file failed in a round that reverts a fact, by a restored path and no fact, prints its own diagnostic" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const email_line = "export EMAIL=<machine.email | default \"nobody@example.com\">\n";
    try writeRepo(io, &tmp, "repo/src/.pfile", "export SHELL_OK=1\nnote quokkanote\nexport SPACER=1\nexport EDITOR=vim\nexport SPACER2=1\n" ++ email_line ++ os_blocks);
    const loop = "# mox: for entry in \"data/t.toml\"\nkey: <entry.key>\n# mox: end\n";
    try writeRepo(io, &tmp, "repo/src/.tloop", "note wombatnote\n" ++ loop);
    try writeRepo(io, &tmp, "repo/data/t.toml", "[[t]]\nkey = \"a\"\n");
    const facts_before = "email = \"old@home.com\"\n";
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", facts_before);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    // Since the apply, the source went back to the token live still shows
    // renamed: only .pfile's coupled update makes .tloop match live again.
    const tloop_src = "note quokkanote\n" ++ loop;
    try writeRepo(io, &tmp, "repo/src/.tloop", tloop_src);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".pfile"), "quokkanote", "wombatnote");
    try editLive(io, a, try h.liveOf(".pfile"), "EDITOR=vim", "EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".pfile"), "EMAIL=old@home.com", "EMAIL=new@home.com");
    try editLive(io, a, try h.liveOf(".tloop"), "key: a", "key: b");

    // .pfile: the rename universal, EDITOR to the private layer (fails),
    // EMAIL to the fact. .tloop routes its row; the coupled update into it
    // is accepted. When .pfile fails, one round restores .tloop's source and
    // reverts the fact; .tloop reads no fact, so it names its own failure.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "1\n4\nf\ny\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(facts_before, try read(io, a, try h.homePath(".config/mox/facts.toml")));
    try std.testing.expectEqualStrings(tloop_src, try read(io, a, try h.srcOf(".tloop")));
    try std.testing.expectEqualStrings("[[t]]\nkey = \"a\"\n", try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "t.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  committed ") == null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: {s}: recomposed output still differs from live; not committed\n" ++
        "mox commit: coupled update to ~/.tloop undone: ~/.pfile was not committed\n", .{ try h.liveOf(".pfile"), try h.liveOf(".tloop") }), res.err);
}

test "commit: a coupled update that fails only together with the target's own routed edit is undone with the target's reason" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t_src = "export SHELL_OK=1\nexport A=1\n# mox: when os=linux\nnote quokkakey\n# mox: end\n";
    try writeRepo(io, &tmp, "repo/src/.tconf", t_src);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkakey\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkakey", "wombatkey");
    try editLive(io, a, try h.liveOf(".tconf"), "A=1", "A=2");

    // The rename changes only os=linux, where .tconf's own edit does not
    // reach. Alone it would pass, as a sync of every other configuration the
    // file has; beside the target's own edit, which chose this machine only,
    // os=linux changing is what the user did not choose.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n2\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(t_src, try read(io, a, try h.srcOf(".tconf")));
    try std.testing.expect(!exists(io, try h.srcOf(".tconf.d")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings("mox commit: coupled update to ~/.tconf undone: ~/.tconf could not take it (configuration os=linux would change); ~/.tconf not committed\n", res.err);
}

test "commit: with MOX_REPO spelled through a symlink under home, a fragment the run created is named under the repo" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const x_src = "export SHELL_OK=1\nexport PAGER=less\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.xfile", x_src);
    const z_src = "export KEEP=1\nexport SPACER=1\nexport MIDDLE=1\nexport EDITOR=vim\n" ++ os_blocks;
    try writeRepo(io, &tmp, "repo/src/.zfile", z_src);
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.symLink(io, "../repo", "home/dots", .{ .is_directory = true });
    const cwd = try std.process.currentPathAlloc(io, a);
    const link = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "home", "dots" });
    const h = try setup(a, io, &tmp, .{ .extra_env = &.{.{ .name = "MOX_REPO", .value = link }} });
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    try editLive(io, a, try h.liveOf(".xfile"), "PAGER=less", "PAGER=more");
    try editLive(io, a, try h.liveOf(".zfile"), "SPACER=1", "SPACER=2");
    try editLive(io, a, try h.liveOf(".zfile"), "EDITOR=vim", "EDITOR=nvim");

    // .xfile narrows its PAGER line to this machine's os, creating a
    // fragment under the repo as MOX_REPO spells it. .zfile fails for its
    // EDITOR line, and the restore of its base, its sixth write, fails.
    var vtable: Io.VTable = undefined;
    const faulty = try failingCreates(h, &vtable, try h.srcOf(".zfile"), 6);
    const res = try faulty.runWithInput(&.{ "mox", "commit", "--color=never" }, "2\n1\n4\n");
    restore_fail_target = "";
    try std.testing.expectEqual(@as(u8, 2), res.rc);

    const m_state = try mox.machine.state.capture(a, io, h.env, h.repo, "");
    try std.testing.expect(exists(io, try h.srcOf(try std.fmt.allocPrint(a, ".xfile.d/os/{s}", .{m_state.os}))));
    const dir = try recoveryDir(h);
    const x_copy = try std.fs.path.join(a, &.{ dir, "repo", "src", ".xfile" });
    const z_copy = try std.fs.path.join(a, &.{ dir, "repo", "src", ".zfile" });
    try std.testing.expectEqualStrings(x_src, try read(io, a, x_copy));
    try std.testing.expectEqualStrings(z_src, try read(io, a, z_copy));
    // Every path is named as MOX_REPO spells it, the fragment the run
    // created included: it is keyed under the canonical repo root.
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: could not restore ~/dots/src/.zfile (AccessDenied)\n" ++
        "mox commit: nothing was recorded; each path below still holds this run's edits\n" ++
        "mox commit: ~/dots/src/.xfile: its pre-run bytes are saved in {s}\n" ++
        "mox commit: ~/dots/src/.xfile.d/os/{s} did not exist before this commit; delete it to restore it\n" ++
        "mox commit: ~/dots/src/.zfile: its pre-run bytes are saved in {s}\n" ++
        "mox commit: 0 package row(s) already recorded\n", .{ try h.liveOf(".zfile"), x_copy, m_state.os, z_copy }), res.err);
}

test "commit: a coupling target failed by a restored data source it wrote is named by its own line, and its update as not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", shared_abbrs);
    const loop = "# mox: for entry in \"data/abbrs.toml\"\nkey: <entry.key>\n# mox: end\n";
    try writeRepo(io, &tmp, "repo/src/.tloop", "note wombatnote\n" ++ loop);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    try writeRepo(io, &tmp, "repo/src/.zaliases", "# mox: for entry in \"data/abbrs.toml\"\nexpansion: <entry.expansion>\n# mox: end\nexport SPACER=1\nexport EDITOR=vim\n" ++ os_blocks);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    // Since the apply, the source went back to the token live still shows
    // renamed: only .aenv's coupled update makes .tloop match live again.
    const tloop_src = "note quokkanote\n" ++ loop;
    try writeRepo(io, &tmp, "repo/src/.tloop", tloop_src);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");
    try editLive(io, a, try h.liveOf(".tloop"), "key: ll\n", "key: lll\n");
    try editLive(io, a, try h.liveOf(".zaliases"), "git status\n", "git status -sb\n");
    try editLive(io, a, try h.liveOf(".zaliases"), "EDITOR=vim", "EDITOR=nvim");

    // .zaliases sends its EDITOR line to the private layer and fails, so the
    // data file is restored and .tloop, which routed a row into it, is not
    // committed; its line says why, so its coupled update is undone as
    // not committed.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ny\ny\n4\ny\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(tloop_src, try read(io, a, try h.srcOf(".tloop")));
    try std.testing.expectEqualStrings("note wombatnote\n", try read(io, a, try h.srcOf(".aenv")));
    try std.testing.expectEqualStrings(shared_abbrs, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "1 routed, 0 coupled") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n" ++
        "mox commit: ~/.tloop: not committed: {s} was restored because ~/.zaliases was not committed; commit it on its own with 'mox commit ~/.tloop'\n" ++
        "mox commit: coupled update to ~/.tloop undone: ~/.tloop was not committed\n", .{
        try h.liveOf(".zaliases"),
        try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" }),
    }), res.err);
}

const email_facts = "email = \"old@home.com\"\n";
const held_email_line = "export EMAIL=<machine.email | default \"nobody@example.com\">\n";

/// Hold a hunk of `name`: its email line, a capture that `--yes` leaves
/// manual.
fn holdEmail(io: Io, a: std.mem.Allocator, h: Harness, name: []const u8) !void {
    try editLive(io, a, try h.liveOf(name), "EMAIL=old@home.com", "EMAIL=new@home.com");
}

const three_abbrs = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n\n[[abbrs]]\nkey = \"gd\"\nexpansion = \"git diff\"\n";

test "commit: a loop row edit whose data source gained a row above it since the last apply is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key> <entry.expansion>\n# mox: end\n" ++ held_email_line);
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", email_facts);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // A row pulled in since the apply shifts every row after it.
    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" });
    const pulled = "[[abbrs]]\nkey = \"zz\"\nexpansion = \"zoxide\"\n\n" ++ three_abbrs;
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", pulled);
    try editLive(io, a, try h.liveOf(".abbrs"), "abbr gs git status", "abbr gs git status -sb");
    try holdEmail(io, a, h, ".abbrs");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(pulled, try read(io, a, data_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:2 data row no longer matches what the last apply wrote\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 2 manual") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a loop row edit is manual when a row up to it rendered differently at the last apply" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key> <entry.expansion>\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The first row changed in the data since the apply; live still shows
    // what the apply wrote there.
    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" });
    try editLive(io, a, data_path, "ls -l", "ls -la");
    const data_before = try read(io, a, data_path);
    try editLive(io, a, try h.liveOf(".abbrs"), "abbr gs git status", "abbr gs git status -sb");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data_before, try read(io, a, data_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:2 data row no longer matches what the last apply wrote\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a loop row edit beside a row already committed into its source routes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key> <entry.expansion>\n# mox: end\nexport SPACER=1\n" ++ held_email_line);
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", email_facts);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The first row commits beside a held hunk, so the applied record stays
    // where the apply left it while the source and live both hold the edit.
    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll ls -l", "abbr ll ls -la");
    try holdEmail(io, a, h, ".abbrs");
    const first = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), first.rc);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) could not be routed and remain only in the live file; the routed edits were committed to the sources -- edit the rest in by hand, then run 'mox apply'\n", .{try h.liveOf(".abbrs")}), first.err);

    // The third row's edit routes: the first row already matches live. That
    // row's own hunk is re-offered against a source that moved on, so it
    // stays manual.
    try editLive(io, a, try h.liveOf(".abbrs"), "abbr gd git diff", "abbr gd git diff -w");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(
        "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -la\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n\n[[abbrs]]\nkey = \"gd\"\nexpansion = \"git diff -w\"\n",
        try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" })),
    );
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:1 data row no longer matches what the last apply wrote\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  update ") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 2 hunk(s) could not be routed and remain only in the live file; the routed edits were committed to the sources -- edit the rest in by hand, then run 'mox apply'\n", .{try h.liveOf(".abbrs")}), res.err);
}

test "commit: a loop row edit is manual when its line is not unique among the loop's rows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rows = "[[hosts]]\nname = \"a\"\nport = \"22\"\n\n[[hosts]]\nname = \"b\"\nport = \"22\"\n\n[[hosts]]\nname = \"c\"\nport = \"22\"\n";
    try writeRepo(io, &tmp, "repo/data/hosts.toml", rows);
    try writeRepo(io, &tmp, "repo/src/.ports", "# mox: for entry in \"data/hosts.toml\"\nport <entry.port>\n# mox: end\nexport SPACER=1\n" ++ held_email_line);
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", email_facts);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // A row rendering the same text arrived at the top since the apply:
    // every (row, text) up to the third row is unchanged.
    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "hosts.toml" });
    const pulled = "[[hosts]]\nname = \"z\"\nport = \"22\"\n\n" ++ rows;
    try writeRepo(io, &tmp, "repo/data/hosts.toml", pulled);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".ports"), .data = "port 22\nport 22\nport 2222\nexport SPACER=1\nexport EMAIL=new@home.com\n" });

    // No longest alignment fixes which of the equal rows was edited, so the
    // rows change as one block, and the held capture line with it.
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(pulled, try read(io, a, data_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.ports:1 may be an edited loop row\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.ports:5 held beside an edited loop row\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a generator leaf left alone while its data row changed since the last apply is not routed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenValueFixture(io, &tmp, &.{ .{ "a", "1" }, .{ "b", "2" } });
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" });
    try editLive(io, a, data_path, "value = \"1\"", "value = \"5\"");
    const data_before = try read(io, a, data_path);

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings(data_before, try read(io, a, data_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 0 manual") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: an edited generator leaf whose data row changed since the last apply is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenValueFixture(io, &tmp, &.{ .{ "a", "1" }, .{ "b", "2" } });
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" });
    try editLive(io, a, data_path, "value = \"1\"", "value = \"5\"");
    const data_before = try read(io, a, data_path);
    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=7");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data_before, try read(io, a, data_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.config/id-a.inc:1 data row no longer matches what the last apply wrote\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a row write beside a held edit, in its own managed data file, to a field the loop reads is not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n\n[meta]\nnote = \"<machine.email>\"\n";
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", email_facts);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The data file's own copy renames the row's key, which the loop reads,
    // and holds its capture line; the loop file edits the row's expansion.
    try editLive(io, a, try h.liveOf("abbrs.toml"), "key = \"gs\"", "key = \"gss\"");
    try editLive(io, a, try h.liveOf("abbrs.toml"), "note = \"old@home.com\"", "note = \"new@home.com\"");
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");

    // The planned row renders the renamed key, not the loop's live line, so
    // the plan refuses the data file for both files editing it.
    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    const data_path = try h.srcOf("abbrs.toml");
    try std.testing.expectEqualStrings(data, try read(io, a, data_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
    const want_err = try std.fmt.allocPrint(a, "mox commit: {s}: the planned edit to {s} does not render the edited line; not committed\n" ++
        "mox commit: {s}: the planned edit to {s} does not render the edited line; not committed\n", .{ try h.liveOf(".abbrs"), data_path, try h.liveOf("abbrs.toml"), data_path });
    try std.testing.expectEqualStrings(want_err, res.err);
    try std.testing.expectEqualStrings(want_err, dry.err);
}

test "commit: a loop row routes through a loop variable not named entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for h in \"data/abbrs.toml\"\nabbr <h.key>=\"<h.expansion>\"\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings(
        "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status -sb\"\n\n[[abbrs]]\nkey = \"gd\"\nexpansion = \"git diff\"\n",
        try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" })),
    );
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expectEqualStrings("", res.err);
}

/// A loop file `.abbrs` over data/abbrs.toml rendering `template` for each
/// row, applied, with `data` as the data file.
fn loopFixture(io: Io, a: std.mem.Allocator, tmp: *std.testing.TmpDir, data: []const u8, template: []const u8) !Harness {
    try writeRepo(io, tmp, "repo/data/abbrs.toml", data);
    try writeRepo(io, tmp, "repo/src/.abbrs", try std.fmt.allocPrint(a, "# mox: for entry in \"data/abbrs.toml\"\n{s}\n# mox: end\n", .{template}));
    try writeRepo(io, tmp, "home/.config/mox/facts.toml", email_facts);
    const h = try setup(a, io, tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    return h;
}

fn abbrsData(h: Harness) ![]const u8 {
    return read(h.io, h.a, try std.fs.path.join(h.a, &.{ h.repo, "data", "abbrs.toml" }));
}

test "commit: a row write ends at the next table header of any kind" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try loopFixture(io, a, &tmp, "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[meta]\nexpansion = \"keep\"\n", "abbr <entry.key>=\"<entry.expansion>\"");
    try editLive(io, a, try h.liveOf(".abbrs"), "ls -l", "ls -la");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -la\"\n\n[meta]\nexpansion = \"keep\"\n", try abbrsData(h));
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a row write never rewrites a line inside a multi-line value of its row" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try loopFixture(io, a, &tmp, "[[abbrs]]\nkey = \"ll\"\nnote = \"\"\"\nexpansion = inside\n\"\"\"\nexpansion = \"ls -l\"\n", "abbr <entry.key>=\"<entry.expansion>\"");
    try editLive(io, a, try h.liveOf(".abbrs"), "ls -l", "ls -la");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\nkey = \"ll\"\nnote = \"\"\"\nexpansion = inside\n\"\"\"\nexpansion = \"ls -la\"\n", try abbrsData(h));
    try std.testing.expectEqualStrings("", res.err);
}

const host_row = "[[abbrs]]\nname = \"ll\"   # the name\nport = 22\ndir = \"<machine.email>/bin\"\nshells = [\"fish\", \"zsh\"]\n";
const host_template = "host <entry.name> <entry.port> <entry.dir> <entry.shells>";

test "commit: a row write leaves the fields it did not change as they are" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try loopFixture(io, a, &tmp, host_row, host_template);
    try editLive(io, a, try h.liveOf(".abbrs"), "host ll ", "host lll ");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\nname = \"lll\"   # the name\nport = 22\ndir = \"<machine.email>/bin\"\nshells = [\"fish\", \"zsh\"]\n", try abbrsData(h));
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a changed integer field is written as an integer, and a new value it cannot hold is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try loopFixture(io, a, &tmp, host_row, host_template);
    try editLive(io, a, try h.liveOf(".abbrs"), " 22 ", " 2222 ");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\nname = \"ll\"   # the name\nport = 2222\ndir = \"<machine.email>/bin\"\nshells = [\"fish\", \"zsh\"]\n", try abbrsData(h));

    try editLive(io, a, try h.liveOf(".abbrs"), " 2222 ", " many ");
    const bad = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), bad.rc);
    try std.testing.expect(std.mem.indexOf(u8, bad.out, "  manual: ~/.abbrs:1 data value type\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, try abbrsData(h), "port = 2222\n") != null);
    try std.testing.expectEqualStrings("", bad.err);
}

test "commit: a changed field whose stored value holds a capture is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try loopFixture(io, a, &tmp, host_row, host_template);
    try editLive(io, a, try h.liveOf(".abbrs"), "old@home.com/bin", "old@home.com/sbin");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(host_row, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:1 data value holds a capture\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a changed array field is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try loopFixture(io, a, &tmp, host_row, host_template);
    try editLive(io, a, try h.liveOf(".abbrs"), "fish,zsh", "fish,zsh,bash");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(host_row, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:1 data value is an array\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a changed string field is written as a TOML string with its quotes and backslashes escaped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try loopFixture(io, a, &tmp, "[[abbrs]]\nkey = \"hi\"\nexpansion = 'echo hi'  # say it\n", "abbr <entry.key> <entry.expansion>");
    try editLive(io, a, try h.liveOf(".abbrs"), "echo hi", "echo \"hi\" \\ there");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\nkey = \"hi\"\nexpansion = \"echo \\\"hi\\\" \\\\ there\"  # say it\n", try abbrsData(h));
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "status" })).rc);
}

test "commit: a new string value that introduces a capture is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\nkey = \"hi\"\nexpansion = \"echo hi\"\n";
    const h = try loopFixture(io, a, &tmp, data, "abbr <key> <expansion>");
    try editLive(io, a, try h.liveOf(".abbrs"), "echo hi", "echo <machine.email>");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:1 new value holds a capture\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: an edit to the second line of a loop row spanning lines is manual, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\ntext = \"one\\ntwo\"\n\n[[abbrs]]\ntext = \"three\"\n";
    const h = try loopFixture(io, a, &tmp, data, "<entry.text>");
    try editLive(io, a, try h.liveOf(".abbrs"), "two\n", "TWO\n");

    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "  manual: ~/.abbrs:2 data row spans several lines\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would update") == null);
    try std.testing.expectEqualStrings("", dry.err);

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:2 data row spans several lines\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: an edit to a generator leaf whose row renders several lines is manual, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value>\n# mox: end\n");
    const data = "[[entries]]\nslug = \"a\"\nvalue = \"1\\n2\"\n";
    try writeRepo(io, &tmp, "repo/data/entries.toml", data);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=9");

    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "  manual: ~/.config/id-a.inc:1 data row spans several lines\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would update") == null);
    try std.testing.expectEqualStrings("", dry.err);

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.config/id-a.inc:1 data row spans several lines\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a row write lands on its row when a line edit to the data file adds a row above it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\nshell = \"fish\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\nshell = \"fish\"\n";
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\" where entry.shell = \"fish\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);

    // The data file's own copy gains a row the loop filters out, above the
    // row the loop file edits; each live copy carries the row edit.
    const added = "[[abbrs]]\nkey = \"zz\"\nexpansion = \"zoxide\"\nshell = \"zsh\"\n\n";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf("abbrs.toml"), .data = added ++ data });
    try editLive(io, a, try h.liveOf("abbrs.toml"), "git status", "git status -sb");
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings(
        added ++ "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\nshell = \"fish\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status -sb\"\nshell = \"fish\"\n",
        try read(io, a, try h.srcOf("abbrs.toml")),
    );
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/abbrs.toml") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a loop line that splits into row fields several ways writes the one field set the edit changed least" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try loopFixture(io, a, &tmp, "[[abbrs]]\na = \"1\"\nb = \"2\"\nc = \"3\"\n", "<entry.a>,<entry.b>,<entry.c>");
    try editLive(io, a, try h.liveOf(".abbrs"), "1,2,3", "1,x,y,3");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings("[[abbrs]]\na = \"1\"\nb = \"x,y\"\nc = \"3\"\n", try abbrsData(h));
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a loop line whose edit splits into row fields more than one way is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\na = \"p\"\nb = \"q\"\n";
    const h = try loopFixture(io, a, &tmp, data, "<entry.a> <entry.b>");
    try editLive(io, a, try h.liveOf(".abbrs"), "p q", "p  q");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:1 live line splits into row fields more than one way\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a loop line capturing one field twice, edited in one place, is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\na = \"p\"\n";
    const h = try loopFixture(io, a, &tmp, data, "<entry.a>:<a>");
    try editLive(io, a, try h.liveOf(".abbrs"), "p:p", "x:p");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:1 field captured twice with different values\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a coupling rename into a loop file's routed template is dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const abbrs_src = "# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key> quokkanote\n# mox: end\n" ++ held_email_line;
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.abbrs", abbrs_src);
    try writeRepo(io, &tmp, "repo/src/.aenv", "note quokkanote\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", email_facts);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll quokkanote", "abbr lll quokkanote");
    try holdEmail(io, a, h, ".abbrs");
    try editLive(io, a, try h.liveOf(".aenv"), "quokkanote", "wombatnote");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(abbrs_src, try read(io, a, try h.srcOf(".abbrs")));
    try std.testing.expect(std.mem.indexOf(u8, try abbrsData(h), "key = \"lll\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.aenv") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.abbrs") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled, 1 manual") != null);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: coupling: {s} holds \"quokkanote\" in a loop a row write was routed through; not renaming it there\n" ++
        "mox commit: {s}: 1 hunk(s) could not be routed and remain only in the live file; the routed edits were committed to the sources -- edit the rest in by hand, then run 'mox apply'\n", .{ try h.srcOf(".abbrs"), try h.liveOf(".abbrs") }), res.err);
}

test "commit: a row write the file's other loop over the data source renders unchanged is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.hosts", "# mox: for entry in \"data/abbrs.toml\"\nhost <entry.key>\n# mox: end\n# mox: for entry in \"data/abbrs.toml\"\nalias <entry.key>\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".hosts"), "host gs\n", "host gss\n");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(three_abbrs, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.hosts:2 data row also renders at line 5 without this edit\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a row write that makes the row appear in the file's other loop over the data source is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.hosts", "# mox: for entry in \"data/abbrs.toml\"\nhost <entry.key>\n# mox: end\n# mox: for entry in \"data/abbrs.toml\" where entry.key = \"gss\"\nalias <entry.key>\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".hosts"), "host gs\n", "host gss\n");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(three_abbrs, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.hosts:2 data row would render differently elsewhere in the file\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a row edited alike in both of a file's loops over the data source is one write" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.hosts", "# mox: for entry in \"data/abbrs.toml\"\nhost <entry.key>\n# mox: end\n# mox: for entry in \"data/abbrs.toml\"\nalias <entry.key>\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".hosts"), "host gs\n", "host gss\n");
    try editLive(io, a, try h.liveOf(".hosts"), "alias gs\n", "alias gss\n");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, try abbrsData(h), "key = \"gss\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~/.hosts") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a row write that filters the row out of its own loop is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\nkey = \"ll\"\non = \"yes\"\n\n[[abbrs]]\nkey = \"gs\"\non = \"yes\"\n";
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", data);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\" where entry.on = \"yes\"\nabbr <entry.key> <entry.on>\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".abbrs"), "abbr gs yes", "abbr gs no");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:2 the edited row is filtered out\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a leaf row write that moves the leaf is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.slug>\n# mox: end\n");
    const data = "[[entries]]\nslug = \"a\"\n";
    try writeRepo(io, &tmp, "repo/data/entries.toml", data);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=a", "key=z");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.config/id-a.inc:1 the edited row moves the leaf\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

/// A loop file `.abbrs` whose directive lines are `loop_src`, over
/// `data_rel`, and `.aenv` holding `token`; the row `ll` edited and `.aenv`
/// renaming `token` to `renamed`. `--dry-run` and `--yes` both drop the
/// rename into `.abbrs` with the directive warning.
fn expectDirectiveTokenDropped(loop_src: []const u8, data_rel: []const u8, token: []const u8, renamed: []const u8) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stem = std.fs.path.stem(data_rel);
    try writeRepo(io, &tmp, try std.fmt.allocPrint(a, "repo/{s}", .{data_rel}), try std.fmt.allocPrint(a, "[[{s}]]\nkey = \"ll\"\nkind = \"quokkanote\"\n\n[[{s}]]\nkey = \"gs\"\nkind = \"quokkanote\"\n", .{ stem, stem }));
    try writeRepo(io, &tmp, "repo/src/.abbrs", loop_src);
    try writeRepo(io, &tmp, "repo/src/.aenv", try std.fmt.allocPrint(a, "note {s}\n", .{token}));
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll\n", "abbr lll\n");
    try editLive(io, a, try h.liveOf(".aenv"), token, renamed);
    const warning = try std.fmt.allocPrint(a, "mox commit: coupling: {s} holds \"{s}\" in a loop a row write was routed through; not renaming it there\n", .{ try h.srcOf(".abbrs"), token });

    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would update") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "2 routable, 0 coupled, 0 manual") != null);
    try std.testing.expectEqualStrings(warning, dry.err);

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 0), res.rc);
    try std.testing.expectEqualStrings(loop_src, try read(io, a, try h.srcOf(".abbrs")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "2 routed, 0 coupled, 0 manual") != null);
    try std.testing.expectEqualStrings(warning, res.err);
}

test "commit: a coupling rename into a loop file whose where holds the token is dropped, and --dry-run predicts it" {
    try expectDirectiveTokenDropped("# mox: for entry in \"data/abbrs.toml\" where entry.kind = \"quokkanote\"\nabbr <entry.key>\n# mox: end\n", "data/abbrs.toml", "quokkanote", "wombatnote");
}

test "commit: a coupling rename into a loop file whose data source path is the token is dropped" {
    try expectDirectiveTokenDropped("# mox: for entry in \"data/quokkanote.toml\"\nabbr <entry.key>\n# mox: end\n", "data/quokkanote.toml", "data/quokkanote.toml", "data/wombatnote.toml");
}

test "commit: a coupling rename into a loop file whose enclosing gate holds the token is dropped" {
    try expectDirectiveTokenDropped("# mox: when not profile=\"quokkanote\"\n# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key>\n# mox: end\n# mox: end\n", "data/abbrs.toml", "quokkanote", "wombatnote");
}

test "commit: a loop line with two splits changing equally few fields is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[abbrs]]\na = \"x\"\nb = \"y\"\nc = \"z\"\n";
    const h = try loopFixture(io, a, &tmp, data, "<entry.a> <entry.b> <entry.c>");
    try editLive(io, a, try h.liveOf(".abbrs"), "x y z", "p y y q");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:1 live line splits into row fields more than one way\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a loop row write that does not render the edited line is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The second capture carries a default, so it is literal text of the
    // row as it stands; the write renders it changed too.
    const data = "[[abbrs]]\nkey = \"ll\"\n";
    const h = try loopFixture(io, a, &tmp, data, "abbr <entry.key> <entry.key | default \"x\">");
    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll ll", "abbr lll ll");
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:1 the edited row does not render the edited line\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a leaf row write that does not render the edited line is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value> <entry.value | default \"x\">\n# mox: end\n");
    const data = "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n";
    try writeRepo(io, &tmp, "repo/data/entries.toml", data);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1 1", "key=9 1");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(data, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "entries.toml" })));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.config/id-a.inc:1 the edited row does not render the edited line\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a loop row edit is manual when its line was not unique at the last apply" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try loopFixture(io, a, &tmp, "[[abbrs]]\nkey = \"ll\"\n\n[[abbrs]]\nkey = \"gs\"\n\n[[abbrs]]\nkey = \"ll\"\n", "abbr <entry.key>");
    // The duplicate row changed since the apply: only the recorded block
    // holds the edited row's text twice.
    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" });
    const now = "[[abbrs]]\nkey = \"ll\"\n\n[[abbrs]]\nkey = \"gs\"\n\n[[abbrs]]\nkey = \"gd\"\n";
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", now);
    try editLive(io, a, try h.liveOf(".abbrs"), "abbr ll\nabbr gs", "abbr lll\nabbr gs");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(now, try read(io, a, data_path));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.abbrs:1 data row is not unique in its loop\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a row write another loop over the data source renders without a row of its own is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.hosts", "# mox: for entry in \"data/abbrs.toml\"\nhost <entry.key>\n# mox: end\n" ++
        "# mox: for entry in \"data/abbrs.toml\"\n# mox: when os=darwin\n# alias <entry.key>\n# mox: end\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".hosts"), "host gs\n", "host gss\n");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(three_abbrs, try abbrsData(h));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.hosts:2 data row also renders elsewhere in the file without a position\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

const hosts_a = "[[hosts]]\nkey = \"a\"\n";
const hosts_ab = "[[hosts]]\nkey = \"a\"\n\n[[hosts]]\nkey = \"b\"\n";
const hosts_loop = "# mox: for entry in \"data/hosts.toml\"\nhost <entry.key>\n# mox: end\n";
const hosts_block_loop = "# mox: for entry in \"data/hosts.toml\"\nHost <entry.key>\n  Port 22\n# mox: end\n";

const RealignRun = struct { res: testutil.RunResult, src: []const u8, data: []const u8, now_src: []const u8, now_data: []const u8 };

/// Apply `.hosts` from `src` over `data/hosts.toml` holding `data` (and any
/// `extra` repo files), replace its live copy with `live`, and commit with
/// `--yes`, or interactively answering `stdin`.
fn realignCommit(io: Io, a: std.mem.Allocator, tmp: *std.testing.TmpDir, src: []const u8, data: []const u8, extra: []const [2][]const u8, live: []const u8, stdin: ?[]const u8) !RealignRun {
    try writeRepo(io, tmp, "repo/data/hosts.toml", data);
    try writeRepo(io, tmp, "repo/src/.hosts", src);
    for (extra) |e| try writeRepo(io, tmp, e[0], e[1]);
    const h = try setup(a, io, tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".hosts"), .data = live });
    const res = if (stdin) |s|
        try h.runWithInput(&.{ "mox", "commit", "--color=never" }, s)
    else
        try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    return .{
        .res = res,
        .src = src,
        .data = data,
        .now_src = try read(io, a, try h.srcOf(".hosts")),
        .now_data = try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "hosts.toml" })),
    };
}

/// Nothing routed: exit 1, each line in `manual` reported, no source
/// changed, and nothing on stderr.
fn expectAllManual(r: RealignRun, manual: []const []const u8) !void {
    try std.testing.expectEqualStrings(r.src, r.now_src);
    try std.testing.expectEqualStrings(r.data, r.now_data);
    try std.testing.expectEqual(@as(u8, 1), r.res.rc);
    for (manual) |line| {
        if (std.mem.indexOf(u8, r.res.out, line) == null) {
            std.debug.print("missing {s} in:\n{s}", .{ line, r.res.out });
            return error.TestExpectedManualLine;
        }
    }
    var summary: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&summary, "mox commit: 0 routed, 0 coupled, {d} manual\n", .{manual.len});
    try std.testing.expect(std.mem.indexOf(u8, r.res.out, want) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.res.out, "committed") == null);
    try std.testing.expectEqualStrings("", r.res.err);
}

test "commit: a loop row edited to equal a literal past the next row, diffed as a row deletion and a later insertion, is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Row a becomes "host b": the diff deletes row a and inserts "host b"
    // after the literal, a literal the next apply would render twice.
    const r = try realignCommit(io, a, &tmp, hosts_loop ++ "host b\n", hosts_ab, &.{}, "host b\nhost b\nhost b\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:1 may be an edited loop row\n"});
}

test "commit: two literals edited above a loop row, diffed as an insertion and a straddle of a literal and the row, are manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try realignCommit(io, a, &tmp, "host a\nhost a\n" ++ hosts_loop, hosts_a, &.{}, "port 22\nport 22\nhost a\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:1 may be an edited loop row\n"});
}

test "commit: two loop rows edited to equal the literal below them, diffed as a straddle of both rows, are manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try realignCommit(io, a, &tmp, hosts_loop ++ "port 22\n", hosts_ab, &.{}, "port 22\nport 22\nport 22\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:1 may be an edited loop row\n"});
}

test "commit: a row added above a multi-line template's rows is manual, never literal lines" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try realignCommit(io, a, &tmp, "# hosts\n" ++ hosts_block_loop, hosts_a, &.{}, "# hosts\nHost b\n  Port 22\nHost a\n  Port 22\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:2 may be an edited loop row\n"});
}

test "commit: a refused one-for-one row edit whose text also lands below a literal is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Row b becomes a: the second loop, which renders nothing, now renders
    // it, so the row write is refused; its "alias a" lands below the literal.
    const src = hosts_loop ++ "alias a\n# mox: for entry in \"data/hosts.toml\" where entry.key = \"a\"\nalias <entry.key>\n# mox: end\n";
    const r = try realignCommit(io, a, &tmp, src, "[[hosts]]\nkey = \"b\"\n", &.{}, "host a\nalias a\nalias a\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:1 may be an edited loop row\n"});
}

test "commit: an unequal straddle of a literal and a loop row is never offered a split" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Split, the straddle deleted "port 1" and left the row, while the
    // inserted lines went into the base above "host a".
    const r = try realignCommit(io, a, &tmp, "host a\nport 1\n" ++ hosts_loop, hosts_a, &.{}, "port 22\nport 22\nhost a\n", "y\nx\ny\ns\n");
    try expectAllManual(r, &.{"  manual: ~/.hosts:1 may be an edited loop row\n"});
    try std.testing.expect(std.mem.indexOf(u8, r.res.out, "split") == null);
}

test "commit: an equal straddle of a literal and a loop row is never offered a split" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Split, the straddle paired the literal "host a" with "host b", written
    // into the base, where the row was edited.
    const src = hosts_loop ++ "host a\n# mox: for entry in \"data/hosts.toml\"\nalias <entry.key>\n# mox: end\n";
    const r = try realignCommit(io, a, &tmp, src, hosts_a, &.{}, "host b\nhost a\nhost b\nalias b\n", "s\nx\ny\ns\n");
    try expectAllManual(r, &.{"  manual: ~/.hosts:1 may be an edited loop row\n"});
    try std.testing.expect(std.mem.indexOf(u8, r.res.out, "split") == null);
}

test "commit: a loop row edited to equal the literal just below it is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try realignCommit(io, a, &tmp, hosts_loop ++ "host c\n", hosts_ab, &.{}, "host a\nhost c\nhost c\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:2 may be an edited loop row\n"});
}

test "commit: a loop row edited to equal the literal just below it, the literal's neighbour edited too, is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try realignCommit(io, a, &tmp, hosts_loop ++ "host c\nport 22\n", hosts_ab, &.{}, "host a\nhost c\nhost c\nport 23\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:2 may be an edited loop row\n"});
}

test "commit: a loop row edit a run of equal literals shifts into a literal insertion and deletion is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The diff inserts "host b" above the loop and deletes the last literal:
    // both route into the base, the row keeps "a", and the file recomposes.
    const r = try realignCommit(io, a, &tmp, "host a\nhost a\n" ++ hosts_loop ++ "host a\nhost a\n", hosts_a, &.{}, "host a\nhost a\nhost b\nhost a\nhost a\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:1 may be an edited loop row\n"});
}

test "commit: a loop row edited to equal a second loop's row is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const others = "# mox: for entry in \"data/others.toml\"\nhost <entry.key>\n# mox: end\n";
    const r = try realignCommit(io, a, &tmp, hosts_loop ++ others ++ "host b\n", hosts_a, &.{.{ "repo/data/others.toml", "[[others]]\nkey = \"b\"\n" }}, "host b\nhost b\nhost b\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:1 may be an edited loop row\n"});
}

test "commit: an unequal straddle whose one-for-one piece would land on a loop row is never offered a split" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Split, the literal "host a" was deleted and the row paired with
    // "host b", while the realigned "port 22" went into the base.
    const r = try realignCommit(io, a, &tmp, "host a\n" ++ hosts_loop ++ "port 22\n", hosts_a, &.{}, "host b\nport 22\nport 22\n", "x\ny\ns\ny\n");
    try expectAllManual(r, &.{"  manual: ~/.hosts:1 may be an edited loop row\n"});
    try std.testing.expect(std.mem.indexOf(u8, r.res.out, "split") == null);
}

test "commit: a row added to an empty loop with a multi-line template is manual, never literal lines" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try realignCommit(io, a, &tmp, "# hosts\n" ++ hosts_block_loop, "hosts = []\n", &.{}, "# hosts\nHost a\n  Port 22\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:2 may be an edited loop row\n"});
}

test "commit: a literal edit beside a loop whose where filters out every row is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The diff inserts "host y" at the top and deletes the literal below the
    // loop, moving it above the loop's directive.
    const src = "host x\n# mox: for entry in \"data/hosts.toml\" where entry.key = \"z\"\nhost <entry.key>\n# mox: end\nhost x\n";
    const r = try realignCommit(io, a, &tmp, src, hosts_a, &.{}, "host y\nhost x\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:1 may be an edited loop row\n"});
}

test "commit: a base line edited beside an equal private-layer line is manual, and the private layer keeps its line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "export A=1\n# mox: replace from \"profile\"\nfallback\n# mox: end\n";
    const private = "export A=1\nexport B=1\n";
    try writeRepo(io, &tmp, "repo/src/.myrc", base);
    try writeRepo(io, &tmp, "state/private/.myrc", "top\n");
    try writeRepo(io, &tmp, "state/private/.myrc.d/profile/personal.myrc", private);
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "profile = \"personal\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    // The diff pairs the live "export A=1" with the base's line, so the
    // private layer's copy is deleted and the base keeps the text.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".myrc"), .data = "export A=2\nexport A=1\nexport B=1\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf(".myrc")));
    try std.testing.expectEqualStrings(private, try read(io, a, try std.fs.path.join(a, &.{ h.state, "private", ".myrc.d", "profile", "personal.myrc" })));
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.myrc:1 hunk straddles origins or is uncovered\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed, 0 coupled, 1 manual\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a base line edited beside an equal shared fragment line is manual, and the fragment keeps its line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "export A=1\n# mox: include \"extra.sh\"\n";
    const fragment = "export A=1\nexport B=1\n";
    try writeRepo(io, &tmp, "repo/src/.myrc", base);
    try writeRepo(io, &tmp, "repo/src/.myrc.d/extra.sh", fragment);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".myrc"), .data = "export A=2\nexport A=1\nexport B=1\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf(".myrc")));
    try std.testing.expectEqualStrings(fragment, try read(io, a, try h.srcOf(".myrc.d/extra.sh")));
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.myrc:1 hunk straddles origins or is uncovered\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed, 0 coupled, 1 manual\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a literal edit beside a change that may be an edited loop row is held, and a row write beside them routes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = hosts_loop ++ "sep 1\nport 22\nsep 2\nhost z\n";
    const r = try realignCommit(io, a, &tmp, src, hosts_ab, &.{}, "host a\nhost bb\nsep 1\nport 23\nsep 2\nhost y\n", null);
    try std.testing.expectEqualStrings(src, r.now_src);
    try std.testing.expectEqualStrings("[[hosts]]\nkey = \"a\"\n\n[[hosts]]\nkey = \"bb\"\n", r.now_data);
    try std.testing.expectEqual(@as(u8, 1), r.res.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.res.out, "  manual: ~/.hosts:4 held beside an edited loop row\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.res.out, "  manual: ~/.hosts:6 may be an edited loop row\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.res.out, "mox commit: 1 routed, 0 coupled, 2 manual\n") != null);
    const live = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "home", ".hosts" });
    const abs = try std.fs.path.resolve(a, &.{ try std.process.currentPathAlloc(io, a), live });
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: 2 hunk(s) could not be routed and remain only in the live file; the routed edits were committed to the sources -- edit the rest in by hand, then run 'mox apply'\n", .{abs}), r.res.err);
}

test "commit: a line removed from the repo while one is added to the private layer holds every line change of the file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "a\nb\n# mox: replace from \"profile\"\nfallback\n# mox: end\n";
    const private = "p1\np2\n";
    try writeRepo(io, &tmp, "repo/src/.myrc", base);
    try writeRepo(io, &tmp, "state/private/.myrc", "top\n");
    try writeRepo(io, &tmp, "state/private/.myrc.d/profile/personal.myrc", private);
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "profile = \"personal\"\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".myrc"), .data = "a\np1\np2\nb\n" });

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf(".myrc")));
    try std.testing.expectEqualStrings(private, try read(io, a, try std.fs.path.join(a, &.{ h.state, "private", ".myrc.d", "profile", "personal.myrc" })));
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.myrc:2 lines may move between the private layer and the repo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "  manual: ~/.myrc:5 lines may move between the private layer and the repo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "mox commit: 0 routed, 0 coupled, 2 manual\n") != null);
    try std.testing.expectEqualStrings("", res.err);
}

test "commit: a loop file too large to align its lines holds every change" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 4097 lines on each side: one cell past 2^24.
    var src: std.ArrayList(u8) = .empty;
    for (0..4096) |k| try src.print(a, "line {d}\n", .{k});
    try src.appendSlice(a, hosts_loop);
    var live: std.ArrayList(u8) = .empty;
    for (0..4096) |k| try live.print(a, "line {d}\n", .{if (k == 7) 70000 else k});
    try live.appendSlice(a, "host a\n");
    const r = try realignCommit(io, a, &tmp, src.items, hosts_a, &.{}, live.items, null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:8 file too large to align its lines\n"});
}

test "commit: --dry-run holds and realigns a file exactly as --yes does" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = hosts_loop ++ "sep 1\nport 22\nsep 2\nhost z\n";
    try writeRepo(io, &tmp, "repo/data/hosts.toml", hosts_ab);
    try writeRepo(io, &tmp, "repo/src/.hosts", src);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try h.liveOf(".hosts"), .data = "host a\nhost bb\nsep 1\nport 23\nsep 2\nhost y\n" });

    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "  manual: ~/.hosts:4 held beside an edited loop row\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "  manual: ~/.hosts:6 may be an edited loop row\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would update") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would edit") == null);
    try std.testing.expectEqualStrings(src, try read(io, a, try h.srcOf(".hosts")));
    try std.testing.expectEqualStrings(hosts_ab, try read(io, a, try std.fs.path.join(a, &.{ h.repo, "data", "hosts.toml" })));
}

test "commit: a literal edit in a file whose loop row renders a value over several lines is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Row b renders "host b" and "c": a line of any text may be a row's.
    const data = "[[hosts]]\nkey = \"a\"\n\n[[hosts]]\nkey = \"b\\nc\"\n";
    const r = try realignCommit(io, a, &tmp, hosts_loop ++ "sep\nport 1\n", data, &.{}, "host a\nhost b\nc\nsep\nport 2\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:5 may be an edited loop row\n"});
}

test "commit: a literal edit shaped like a row of a loop whose body holds a directive is manual" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "# mox: for entry in \"data/hosts.toml\"\n# mox: when os=darwin\nhost <entry.key>\n# mox: end\n# mox: end\nsep\nhost z\n";
    const r = try realignCommit(io, a, &tmp, src, hosts_a, &.{}, "host a\nsep\nport 1\n", null);
    try expectAllManual(r, &.{"  manual: ~/.hosts:3 may be an edited loop row\n"});
}

test "commit: a change whose removed lines alone are shaped like a loop row holds the file's other line changes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The row and the literal below it become one line that fits no loop.
    const r = try realignCommit(io, a, &tmp, hosts_loop ++ "port 1\nsep\nport 2\n", hosts_a, &.{}, "port 9\nsep\nport 3\n", null);
    try expectAllManual(r, &.{ "  manual: ~/.hosts:1 may be an edited loop row\n", "  manual: ~/.hosts:4 held beside an edited loop row\n" });
}

/// Run `mox commit --dry-run` and then `mox commit --yes` on the same tree:
/// both exit 1, print `manual` on stdout and `err` on stderr.
fn dryRunAgrees(h: Harness, manual: []const u8, err: []const u8) !testutil.RunResult {
    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, manual) != null);
    try std.testing.expectEqualStrings(err, dry.err);
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, manual) != null);
    try std.testing.expectEqualStrings(err, res.err);
    return res;
}

test "commit: overlapping line splices from two files into one source are refused at routing, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "export A=1\nexport B=1\nexport C=1\n";
    try writeRepo(io, &tmp, "repo/src/.a", src);
    try Io.Dir.hardLink(tmp.dir, "repo/src/.a", tmp.dir, "repo/src/.b", io, .{});
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".a"), "export B=1\nexport C=1\n", "export B=2\nexport C=2\n");
    try editLive(io, a, try h.liveOf(".b"), "export C=1\n", "export C=3\n");

    const manual = try std.fmt.allocPrint(a, "  manual: {s}:3 conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, ".b"), try shownLive(a, ".a"), try h.srcOf(".a") });
    const res = try dryRunAgrees(h, manual, "");
    try std.testing.expectEqualStrings("export A=1\nexport B=2\nexport C=2\n", try read(io, a, try h.srcOf(".a")));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~" ++ std.fs.path.sep_str ++ ".a\n") != null);
}

test "commit: a fragment included twice and edited differently in each place routes the first edit and refuses the second" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myrc", "# top\n# mox: include \"extra.sh\"\n# mid\n# mox: include \"extra.sh\"\n# bottom\n");
    try writeRepo(io, &tmp, "repo/src/.myrc.d/extra.sh", "alias x=1\nalias y=2\nalias z=3\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try h.liveOf(".myrc"),
        .data = "# top\nalias x=1\nalias y=5\nalias z=3\n# mid\nalias x=1\nalias y=6\nalias z=3\n# bottom\n",
    });

    const frag = try h.srcOf(".myrc.d/extra.sh");
    const manual = try std.fmt.allocPrint(a, "  manual: {s}:7 conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, ".myrc"), try shownLive(a, ".myrc"), frag });
    _ = try dryRunAgrees(h, manual, try std.fmt.allocPrint(a, "mox commit: {s}: 1 hunk(s) could not be routed and remain only in the live file; " ++
        "the routed edits were committed to the sources -- edit the rest in by hand, then run 'mox apply'\n", .{try h.liveOf(".myrc")}));
    try std.testing.expectEqualStrings("alias x=1\nalias y=5\nalias z=3\n", try read(io, a, frag));
}

test "commit: one data row edited differently through two loop files is refused at routing, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/data/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.a", "# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.b", "# mox: for entry in \"data/abbrs.toml\"\nalias <entry.key> '<entry.expansion>'\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".a"), "git status", "git status -sb");
    try editLive(io, a, try h.liveOf(".b"), "git status", "git status -s");

    const data_path = try std.fs.path.join(a, &.{ h.repo, "data", "abbrs.toml" });
    const manual = try std.fmt.allocPrint(a, "  manual: {s}:2 conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, ".b"), try shownLive(a, ".a"), data_path });
    const res = try dryRunAgrees(h, manual, "");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, data_path), "expansion = \"git status -sb\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~" ++ std.fs.path.sep_str ++ ".a\n") != null);
}

test "commit: a line edit beside a narrowing of the same source line is refused at routing, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSharedBaseFixture(io, &tmp);
    try Io.Dir.hardLink(tmp.dir, "repo/src/.zshrc", tmp.dir, "repo/src/.zshrc2", io, .{});
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".zshrc"), "export EDITOR=vim", "export EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".zshrc2"), "export EDITOR=vim", "export EDITOR=emacs");

    const manual = try std.fmt.allocPrint(a, "  manual: {s}:2 conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, ".zshrc2"), try shownLive(a, ".zshrc"), try h.srcOf(".zshrc") });
    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, manual) != null);

    // `.zshrc` narrows its line to this machine's os; `.zshrc2`'s edit of the
    // same line is manual before any prompt but the split one.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "2\ns\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "synthesize os=") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, manual) != null);
    const base = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, base, "export EDITOR=vim\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "emacs") == null);
}

test "commit: a narrowing of a source line another file's same edit was routed to is refused at routing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSharedBaseFixture(io, &tmp);
    try Io.Dir.hardLink(tmp.dir, "repo/src/.zshrc", tmp.dir, "repo/src/.zshrc2", io, .{});
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".zshrc"), "export EDITOR=vim", "export EDITOR=nvim");
    try editLive(io, a, try h.liveOf(".zshrc2"), "export EDITOR=vim", "export EDITOR=nvim");

    // `.zshrc` keeps its edit universal; `.zshrc2` makes the same edit but
    // narrows it, which rewrites the same line differently.
    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "1\n2\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    const manual = try std.fmt.allocPrint(a, "  manual: {s}:2 conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, ".zshrc2"), try shownLive(a, ".zshrc"), try h.srcOf(".zshrc") });
    try std.testing.expect(std.mem.indexOf(u8, res.out, manual) != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "synthesize") == null);
    const base = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, base, "export EDITOR=nvim\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "# mox: replace") == null);
}

test "commit: a row write and a line edit of its field to another value in the data file's own copy are refused at routing, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");
    try editLive(io, a, try h.liveOf("abbrs.toml"), "git status", "git st");

    const manual = try std.fmt.allocPrint(a, "  manual: {s}:7 conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, "abbrs.toml"), try shownLive(a, ".abbrs"), try h.srcOf("abbrs.toml") });
    const res = try dryRunAgrees(h, manual, "");
    try std.testing.expect(std.mem.indexOf(u8, try read(io, a, try h.srcOf("abbrs.toml")), "expansion = \"git status -sb\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed ~" ++ std.fs.path.sep_str ++ ".abbrs\n") != null);
}

test "commit: a row write and a key edit to its layered data file are refused at routing, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The row write and the key edit write different lines of the base.
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", three_abbrs ++ "\n[meta]\nnote = \"base\"\nother = \"x\"\n");
    try writeRepo(io, &tmp, "repo/src/abbrs.toml.d/os=darwin.toml", "[meta]\nnote = \"mac\"\n");
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");
    try editLive(io, a, try h.liveOf("abbrs.toml"), "other = \"x\"", "other = \"y\"");

    // The key is manual in both modes; `--yes` then also finds the held
    // file changed in a configuration by the row write, as for any held file.
    const manual = try std.fmt.allocPrint(a, "  manual: {s} meta.other: conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, "abbrs.toml"), try shownLive(a, ".abbrs"), try h.srcOf("abbrs.toml") });
    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, manual) != null);
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expect(std.mem.indexOf(u8, res.out, manual) != null);
    const now = try read(io, a, try h.srcOf("abbrs.toml"));
    try std.testing.expect(std.mem.indexOf(u8, now, "expansion = \"git status -sb\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, now, "other = \"x\"\n") != null);
}

fn shownFacts(a: std.mem.Allocator) ![]const u8 {
    return shownLive(a, try std.fs.path.join(a, &.{ ".config", "mox", "facts.toml" }));
}

const fact_line = "export EMAIL=<machine.email | default \"nobody@example.com\">\n";

/// `.a` and `.b` each render the email fact; each live copy edits it to its
/// own value, and an interactive commit answers `stdin`.
fn twoFactEdits(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, a_value: []const u8, b_value: []const u8, stdin: []const u8) !struct { h: Harness, res: testutil.RunResult } {
    try writeRepo(io, tmp, "repo/src/.a", fact_line);
    try writeRepo(io, tmp, "repo/src/.b", "# b\n" ++ fact_line);
    try writeRepo(io, tmp, "home/.config/mox/facts.toml", email_facts);
    const h = try setup(a, io, tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".a"), "old@home.com", a_value);
    try editLive(io, a, try h.liveOf(".b"), "old@home.com", b_value);
    return .{ .h = h, .res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, stdin) };
}

test "commit: two routes setting one fact to different values are refused at routing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try twoFactEdits(a, io, &tmp, "a@work.com", "b@work.com", "f\nf\n");
    try std.testing.expectEqual(@as(u8, 1), r.res.rc);
    try std.testing.expectEqualStrings("", r.res.err);
    const facts = try r.h.homePath(".config/mox/facts.toml");
    const manual = try std.fmt.allocPrint(a, "  manual: {s}:2 conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, ".b"), try shownLive(a, ".a"), try shownFacts(a) });
    try std.testing.expect(std.mem.indexOf(u8, r.res.out, manual) != null);
    try std.testing.expectEqualStrings("email = \"a@work.com\"\n", try read(io, a, facts));
}

test "commit: a fact set by one route and its default rewritten to another value by another are refused at routing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try twoFactEdits(a, io, &tmp, "a@work.com", "b@work.com", "f\nd\n");
    try std.testing.expectEqual(@as(u8, 1), r.res.rc);
    try std.testing.expectEqualStrings("", r.res.err);
    const manual = try std.fmt.allocPrint(a, "  manual: {s}:2 conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, ".b"), try shownLive(a, ".a"), try shownFacts(a) });
    try std.testing.expect(std.mem.indexOf(u8, r.res.out, manual) != null);
    try std.testing.expectEqualStrings("# b\n" ++ fact_line, try read(io, a, try r.h.srcOf(".b")));
}

test "commit: two routes setting one fact to the same value both commit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try twoFactEdits(a, io, &tmp, "a@work.com", "a@work.com", "f\nf\n");
    try std.testing.expectEqualStrings("", r.res.err);
    try std.testing.expectEqual(@as(u8, 0), r.res.rc);
    try std.testing.expectEqualStrings("email = \"a@work.com\"\n", try read(io, a, try r.h.homePath(".config/mox/facts.toml")));
}

test "commit: a fact write that would change another fact of the facts file is not committed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A line inside `note`'s multi-line value reads as an assignment of
    // `email`; writing the fact must not drop it.
    const facts_before = "note = \"\"\"\nemail = \"x\"\n\"\"\"\nemail = \"old@home.com\"\n";
    try writeRepo(io, &tmp, "repo/src/.a", fact_line);
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", facts_before);
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".a"), "old@home.com", "a@work.com");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "f\n");
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    const facts = try h.homePath(".config/mox/facts.toml");
    try std.testing.expectEqualStrings(facts_before, try read(io, a, facts));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mox commit: {s}: the planned edit to {s} changes it outside its keys; not committed\n", .{ try h.liveOf(".a"), try shownFacts(a) }), res.err);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
}

test "commit: two symlinks of one source retargeted differently are refused at routing, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/alink", "/tmp/mox-old\n");
    try Io.Dir.hardLink(tmp.dir, "repo/src/alink", tmp.dir, "repo/src/blink", io, .{});
    try writeRepo(io, &tmp, "repo/.mox/attributes.toml", "[\"alink\"]\nsymlink = true\n\n[\"blink\"]\nsymlink = true\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    for ([_][2][]const u8{ .{ "alink", "/tmp/mox-a" }, .{ "blink", "/tmp/mox-b" } }) |l| {
        const live = try h.liveOf(l[0]);
        try Io.Dir.cwd().deleteFile(io, live);
        try Io.Dir.cwd().symLink(io, l[1], live, .{});
    }

    const manual = try std.fmt.allocPrint(a, "  manual: {s}: conflicts with the edit routed from {s} to {s}\n", .{ try shownLive(a, "blink"), try shownLive(a, "alink"), try h.srcOf("alink") });
    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqualStrings("", dry.err);
    try std.testing.expect(std.mem.endsWith(u8, dry.out, try std.fmt.allocPrint(a, "{s}\nmox commit: 1 routable, 0 coupled, 1 manual (report only; run without --dry-run on a terminal to apply)\n", .{manual})));
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expect(std.mem.indexOf(u8, res.out, manual) != null);
    try std.testing.expect(std.mem.endsWith(u8, res.out, "\nmox commit: 1 routed, 0 coupled, 1 manual\n"));
    try std.testing.expectEqualStrings("/tmp/mox-a\n", try read(io, a, try h.srcOf("alink")));
}

test "commit: a key edit that changes an alias of its value outside its key path is refused by the plan, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = "base: &b hello\nother: *b\n";
    try writeRepo(io, &tmp, "repo/src/app.yaml", base);
    try writeRepo(io, &tmp, "repo/src/app.yaml.d/os=darwin.yaml", "other: x\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf("app.yaml"), "hello", "bye");

    const want = try std.fmt.allocPrint(a, "mox commit: {s}: the planned edit to {s} changes it outside its keys; not committed\n", .{ try h.liveOf("app.yaml"), try h.srcOf("app.yaml") });
    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(want, dry.err);
    try std.testing.expectEqualStrings(want, res.err);
    try std.testing.expectEqualStrings(base, try read(io, a, try h.srcOf("app.yaml")));
}

test "commit: a row write whose fields a table header inserted into its row takes away is refused by the plan, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/abbrs.toml", three_abbrs);
    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");
    // The data file's own copy opens a table between the row's header and its
    // fields, so the planned row holds no `expansion`.
    try editLive(io, a, try h.liveOf("abbrs.toml"), "[[abbrs]]\nkey = \"gs\"", "[[abbrs]]\n[x]\nkey = \"gs\"");

    const data = try h.srcOf("abbrs.toml");
    const want = try std.fmt.allocPrint(a, "mox commit: {s}: the planned edit to {s} does not hold expansion; not committed\n" ++
        "mox commit: {s}: the planned edit to {s} does not hold expansion; not committed\n", .{ try h.liveOf(".abbrs"), data, try h.liveOf("abbrs.toml"), data });
    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(want, dry.err);
    try std.testing.expectEqualStrings(want, res.err);
    try std.testing.expectEqualStrings(three_abbrs, try read(io, a, data));
}

test "commit: a leaf row write the plan refuses is not committed, and --dry-run agrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data = "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\n";
    try writeRepo(io, &tmp, "repo/src/entries.toml", data);
    try writeRepo(io, &tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"src/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value>\n# mox: end\n");
    const h = try setup(a, io, &tmp, .{});
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "apply" })).rc);
    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=7");
    try editLive(io, a, try h.liveOf("entries.toml"), "[[entries]]\nslug = \"a\"", "[[entries]]\n[x]\nslug = \"a\"");

    const src = try h.srcOf("entries.toml");
    const want = try std.fmt.allocPrint(a, "mox commit: {s}: the planned edit to {s} does not hold value; not committed\n" ++
        "mox commit: {s}: the planned edit to {s} does not hold value; not committed\n", .{
        try shownLive(a, try std.fs.path.join(a, &.{ ".config", "id-a.inc" })),
        src,
        try h.liveOf("entries.toml"),
        src,
    });
    const dry = try h.run(&.{ "mox", "commit", "--dry-run", "--color=never" });
    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    try std.testing.expectEqual(@as(u8, 1), dry.rc);
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    try std.testing.expectEqualStrings(want, dry.err);
    try std.testing.expectEqualStrings(want, res.err);
    try std.testing.expectEqualStrings(data, try read(io, a, src));
    try std.testing.expect(std.mem.indexOf(u8, res.out, "committed") == null);
}
