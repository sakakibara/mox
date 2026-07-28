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
    // Nothing here was routed at all (the only hunk is manual), so this
    // matches every other wholly-manual fallback test: only the report and
    // the untouched sources are asserted, not the exit code -- see the
    // sibling data-interpolated manual tests for the same rule.
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, res.out, "manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "0 routed, 0 coupled, 1 manual") != null);

    // The hunk is a first-contact one, never a silent keep-all: nothing is
    // written to source, and the live file is untouched too.
    try std.testing.expectEqualStrings("export C=3\n", try read(io, a, try h.srcOf(".bashrc")));
    try std.testing.expectEqualStrings("export C=3 \n", try read(io, a, live));
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

test "commit: a changed secret value is shown without its old resolved value, and never routed" {
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

test "commit: private-origin edit never touches repo src" {
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

test "commit: a coupling edit that would diverge an unaffected configuration aborts and restores" {
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
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);

    const gitconfig_src = try h.srcOf(".gitconfig");
    const b_before = try read(io, a, gitconfig_src);

    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "shared@old.example", "shared@new.example");

    // --yes accepts the coupling propagation into B. Verification must catch
    // that renaming the os=linux case changes a configuration the user never
    // chose to affect (the os=windows case is a sibling too, and does NOT
    // change, so this is a genuine subset): abort with a diagnostic and
    // restore B.
    const res = try h.run(&.{ "mox", "commit", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), res.rc);
    // The diagnostic names the configuration, never a machine id.
    try std.testing.expect(std.mem.indexOf(u8, res.err, "os=linux") != null);

    // B's source is byte-identical: the unsafe coupling edit was rolled back.
    try std.testing.expectEqualStrings(b_before, try read(io, a, gitconfig_src));
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
    // a choice at all.
    const res = try h.runWithInput(&.{ "mox", "commit" }, "3\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

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
    try std.testing.expect(std.mem.indexOf(u8, skip.out, "DRIFT") != null);

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
