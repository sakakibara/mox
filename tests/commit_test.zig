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
    try bindings.put(axis, value);
    for (tree.files) |f| {
        if (!std.mem.endsWith(u8, f.live_path, ".zshrc")) continue;
        return try mox.compose.composeFile(a, io, f, &bindings, null, null);
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

    const m_state = try mox.machine.state.capture(a, io, h.env);
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
    const m_state = try mox.machine.state.capture(a, io, h.env);
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
    const m_state = try mox.machine.state.capture(a, io, h.env);
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
    const m_state = try mox.machine.state.capture(a, io, h.env);
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
    const m_state = try mox.machine.state.capture(a, io, h.env);
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

    const m_state = try mox.machine.state.capture(a, io, h.env);
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

    const m_state = try mox.machine.state.capture(a, io, h.env);
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
    const m_state = try mox.machine.state.capture(a, io, h.env);
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

test "commit: narrowing to this machine commits, even where the hostname carries a dot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The `machine` value is this host's name, which on macOS always ends in
    // `.local`. A fragment is named for the value verbatim, so resolving it
    // must not mistake that tail for a file extension -- otherwise the region
    // never resolves, the recompose differs from live, and the machine-local
    // candidate mox offers in every prompt can never be chosen successfully.
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
    // a fragment named for this machine, dot and all.
    const src = try read(io, a, try h.srcOf(".zshrc"));
    try std.testing.expect(std.mem.indexOf(u8, src, "# mox: replace from \"machine\"") != null);
    const m_state = try mox.machine.state.capture(a, io, h.env);
    const frag = try h.srcOf(try std.fmt.allocPrint(a, ".zshrc.d/machine/{s}", .{m_state.hostname}));
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

    const m_state = try mox.machine.state.capture(a, io, h.env);
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
    const m_state = try mox.machine.state.capture(a, io, h.env);
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
    try std.testing.expect(std.mem.indexOf(u8, res.out, "[x] split") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, res.out, "split -- break this hunk into per-source pieces") != null);
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

test "commit: split on an already single-segment hunk is a no-op that just routes it" {
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

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "x\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);
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

    // Exactly one of the two keys made it into its source layer; the other
    // stays only in live.
    const overlay = try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml"));
    const base = try read(io, a, try h.srcOf("config.toml"));
    const theme_routed = std.mem.indexOf(u8, overlay, "solarized") != null;
    const font_routed = std.mem.indexOf(u8, base, "sans") != null;
    try std.testing.expect(theme_routed != font_routed);

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

    // [p] then candidate 1 (base).
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n1\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

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
    // Pick [2] (the os=darwin overlay, a middle layer).
    const res = try h.runWithInput(&.{ "mox", "commit" }, "p\n2\n");
    try std.testing.expectEqual(@as(u8, 0), res.rc);

    try std.testing.expectEqualStrings("theme = \"solarized\"\n", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
    // The more specific override was deleted so the middle placement surfaces.
    try std.testing.expectEqualStrings("", try read(io, a, try h.srcOf("config.toml.d/os=darwin+profile=work.toml")));
    try std.testing.expectEqualStrings("theme = \"light\"\n", try read(io, a, try h.srcOf("config.toml")));
}

test "SCRATCH: pick to base confirms only the fall-through sibling, never the one with its own override" {
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
    std.debug.print("RC={d}\nOUT=\n{s}\nERR=\n{s}\n", .{ res.rc, res.out, res.err });

    try std.testing.expectEqualStrings("theme = \"solarized\"\nfont = \"mono\"\n", try read(io, a, try h.srcOf("config.toml")));
    try std.testing.expectEqualStrings("", try read(io, a, try h.srcOf("config.toml.d/os=darwin.toml")));
    // The sibling with its own override must be byte-identical: untouched.
    try std.testing.expectEqualStrings("theme = \"linux-theme\"\n", try read(io, a, try h.srcOf("config.toml.d/os=linux.toml")));

    try std.testing.expect(std.mem.indexOf(u8, res.out, "os=windows") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "os=linux") == null);
}
