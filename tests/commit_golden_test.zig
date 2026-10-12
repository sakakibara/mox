const std = @import("std");
const builtin = @import("builtin");
const mox = @import("mox");

const Io = std.Io;

const testutil = @import("testutil.zig");
const Harness = testutil.Harness;

const repo_exclusions = [_][]const u8{".git"};
const state_exclusions = [_][]const u8{"bin"} ++ mox.state_dump.store_entries;

// A transcript holds what a capture renders and digests of state that
// records it, so the hostname is pinned like os and arch. Dotted, so the
// machine label is a different string from the hostname it comes from.
const hostname_env = [_]testutil.EnvPair{.{ .name = "MOX_HOSTNAME", .value = "golden-host.example.test" }};

fn setup(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !Harness {
    return setupEnv(a, io, tmp, &.{});
}

fn setupEnv(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, extra_env: []const testutil.EnvPair) !Harness {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const env = try std.mem.concat(a, testutil.EnvPair, &.{ &hostname_env, extra_env });
    return testutil.setup(a, io, tmp, .{ .os = "darwin", .arch = "aarch64", .extra_env = env });
}

fn writeRepo(io: Io, tmp: *std.testing.TmpDir, sub: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| try tmp.dir.createDirPath(io, parent);
    try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = content });
}

fn read(io: Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
}

fn editLive(io: Io, a: std.mem.Allocator, path: []const u8, from: []const u8, to: []const u8) !void {
    const c = try read(io, a, path);
    if (std.mem.indexOf(u8, c, from) == null) return error.FixtureEditMissed;
    const nc = try std.mem.replaceOwned(u8, a, c, from, to);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = nc });
}

fn relink(io: Io, h: Harness, name: []const u8, target: []const u8) !void {
    const live = try h.liveOf(name);
    try Io.Dir.cwd().deleteFile(io, live);
    try Io.Dir.cwd().symLink(io, target, live, .{});
}

const RecordName = struct { hex: []const u8, live: []const u8 };

const Normalizer = struct {
    root: []const u8,
    hostname: []const u8,
    machine: []const u8,
    records: []const RecordName,

    fn init(a: std.mem.Allocator, io: Io, h: Harness) !Normalizer {
        const m = try mox.machine.state.capture(a, io, h.env, h.repo, "");
        var records: std.ArrayList(RecordName) = .empty;
        const src = try std.fs.path.join(a, &.{ h.repo, "src" });
        const home_entries = try listTree(a, io, h.home, &.{});
        const src_entries = try listTree(a, io, src, &.{});
        for ([_][]const Entry{ home_entries, src_entries }) |list| for (list) |e| {
            var d: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(try std.fs.path.join(a, &.{ h.home, e.path }), &d, .{});
            const hex = std.fmt.bytesToHex(d, .lower);
            try records.append(a, .{ .hex = try a.dupe(u8, &hex), .live = try std.fmt.allocPrint(a, "{{~/{s}}}", .{e.path}) });
        };
        return .{ .root = h.root, .hostname = m.hostname, .machine = mox.machine.bindings.firstLabel(m.hostname), .records = records.items };
    }

    fn recordName(n: Normalizer, a: std.mem.Allocator, path: []const u8) ![]const u8 {
        var t = path;
        for (n.records) |r| t = try std.mem.replaceOwned(u8, a, t, r.hex, r.live);
        return t;
    }

    pub fn apply(n: Normalizer, a: std.mem.Allocator, text: []const u8) ![]const u8 {
        // A record names its repo percent-encoded.
        var t = try std.mem.replaceOwned(u8, a, text, try mox.apply.applied.pctEncode(a, n.root), "<ROOT>");
        t = try std.mem.replaceOwned(u8, a, t, n.root, "<ROOT>");
        if (n.hostname.len > 0) t = try std.mem.replaceOwned(u8, a, t, n.hostname, "<HOSTNAME>");
        if (n.machine.len > 0) t = try std.mem.replaceOwned(u8, a, t, n.machine, "<MACHINE>");
        return t;
    }
};

fn appendEscaped(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        if (c == '\n' or (c >= 0x20 and c < 0x7f)) {
            try out.append(a, c);
        } else {
            try out.print(a, "\\x{x:0>2}", .{c});
        }
    }
    if (text.len > 0 and text[text.len - 1] != '\n') try out.appendSlice(a, "\n\\ no newline\n");
}

fn appendStream(out: *std.ArrayList(u8), a: std.mem.Allocator, n: Normalizer, label: []const u8, text: []const u8) !void {
    try out.print(a, "--- {s}\n", .{label});
    try appendEscaped(out, a, try n.apply(a, text));
}

const Entry = struct { path: []const u8, name: []const u8, kind: Io.File.Kind };

fn excluded(path: []const u8, exclusions: []const []const u8) bool {
    for (exclusions) |x| {
        if (std.mem.eql(u8, path, x)) return true;
        if (path.len > x.len and std.mem.startsWith(u8, path, x) and path[x.len] == '/') return true;
    }
    return false;
}

fn listTree(a: std.mem.Allocator, io: Io, root: []const u8, exclusions: []const []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return entries.items,
        else => return e,
    };
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (excluded(e.path, exclusions)) continue;
        const path = try a.dupe(u8, e.path);
        try entries.append(a, .{ .path = path, .name = path, .kind = e.kind });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.lt);
    return entries.items;
}

fn appendTree(out: *std.ArrayList(u8), a: std.mem.Allocator, io: Io, n: Normalizer, root: []const u8, exclusions: []const []const u8, digest_only: bool) !void {
    var dir = Io.Dir.cwd().openDir(io, root, .{}) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close(io);
    const entries = try listTree(a, io, root, exclusions);
    if (digest_only) {
        for (entries) |*e| e.name = try n.recordName(a, e.path);
        std.mem.sort(Entry, entries, {}, struct {
            fn lt(_: void, x: Entry, y: Entry) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
    }
    for (entries) |e| {
        switch (e.kind) {
            .directory => try out.print(a, "{s}/\n", .{e.name}),
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const len = try dir.readLink(io, e.path, &buf);
                try out.print(a, "{s} -> {s}\n", .{ e.name, try n.apply(a, buf[0..len]) });
            },
            .file => {
                const content = try n.apply(a, try dir.readFileAlloc(io, e.path, a, .limited(1 << 24)));
                if (digest_only) {
                    var d: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(content, &d, .{});
                    try out.print(a, "{s} {x}\n", .{ e.name, d[0..8] });
                } else {
                    try out.print(a, "== {s}\n", .{e.name});
                    try appendEscaped(out, a, content);
                }
            },
            else => try out.print(a, "{s} ({t})\n", .{ e.name, e.kind }),
        }
    }
}

fn transcript(a: std.mem.Allocator, io: Io, h: Harness, res: testutil.RunResult, home_files: []const []const u8) ![]const u8 {
    const n = try Normalizer.init(a, io, h);
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "rc {d}\n", .{res.rc});
    try appendStream(&out, a, n, "stdout", res.out);
    try appendStream(&out, a, n, "stderr", res.err);
    try out.appendSlice(a, "--- repo\n");
    try appendTree(&out, a, io, n, h.repo, &repo_exclusions, false);
    for (home_files) |name| {
        try out.print(a, "--- home {s}\n", .{name});
        try appendEscaped(&out, a, try n.apply(a, try read(io, a, try h.homePath(name))));
    }
    try out.appendSlice(a, "--- state\n");
    try appendTree(&out, a, io, n, h.state, &state_exclusions, true);
    const dump = try mox.state_dump.load(a, io, .{ .state_dir = h.state, .parts = &.{.{ .repo = h.repo, .home = h.home }} });
    try out.appendSlice(a, try sortedBlocks(a, try n.recordName(a, try mox.state_dump.render(a, dump, n))));
    return out.items;
}

/// `text`'s blocks -- a line that does not start with a space, and the
/// indented lines under it -- in sorted order: the dump orders paths by the
/// hash of a live path, which moves with the test's temporary root.
fn sortedBlocks(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var blocks: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const end = (std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len - 1) + 1;
        if (i > start and text[i] != ' ') {
            try blocks.append(a, text[start..i]);
            start = i;
        }
        i = end;
    }
    if (start < text.len) try blocks.append(a, text[start..]);
    std.mem.sort([]const u8, blocks.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return std.mem.concat(a, u8, blocks.items);
}

fn expectGolden(a: std.mem.Allocator, io: Io, h: Harness, res: testutil.RunResult, home_files: []const []const u8, want: []const u8) !void {
    try std.testing.expectEqualStrings(want, try transcript(a, io, h, res, home_files));
}

fn applied(h: Harness) !void {
    const res = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqualStrings("", res.err);
    try std.testing.expectEqual(@as(u8, 0), res.rc);
}

const abbrs_data = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\n";
const abbrs_noted_data = "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\nnote = \"list\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\nnote = \"status\"\n";
const abbrs_loop = "# mox: for entry in \"data/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n";

fn writeGenFixture(io: Io, tmp: *std.testing.TmpDir) !void {
    try writeRepo(io, tmp, "repo/src/.config/gen.inc", "# mox: for entry in \"data/entries.toml\" into \"id-<entry.slug>.inc\"\nkey=<entry.value>\n# mox: end\n");
    try writeRepo(io, tmp, "repo/data/entries.toml", "[[entries]]\nslug = \"a\"\nvalue = \"1\"\n\n[[entries]]\nslug = \"b\"\nvalue = \"2\"\n\n");
}

fn writeSymlinkFixture(io: Io, tmp: *std.testing.TmpDir) !void {
    try writeRepo(io, tmp, "repo/src/mylink", "/tmp/mox-old-target\n");
    try writeRepo(io, tmp, "repo/.mox/attributes.toml", "[\"mylink\"]\nsymlink = true\n");
}

test "commit golden: a text line routed to its base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\nexport C=3\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".zshrc"), "export B=2", "export B=22");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  edit src/.zshrc:2
        \\  committed ~/.zshrc
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/.zshrc
        \\export A=1
        \\export B=22
        \\export C=3
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.zshrc}
        \\  file 70e088a1db4236d1ffe25a5b4781d2389068362128e418ba87b1b9a449163eb3 cache 70e088a1db4236d1ffe25a5b4781d2389068362128e418ba87b1b9a449163eb3
        \\  provenance 4d155492e30155600eed52231443a264d91226880ca3c2d8f7ad200341032c46
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a loop row string field routed to its data source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", abbrs_loop);
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", abbrs_data);
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/data/abbrs.toml row 1
        \\  committed ~/.abbrs
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status -sb"
        \\src/
        \\== src/.abbrs
        \\# mox: for entry in "data/abbrs.toml"
        \\abbr <entry.key>="<entry.expansion>"
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.abbrs}
        \\  file 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834 cache 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834
        \\  provenance 5eabd410fa3bbe111172fa70e837bb735f3790a8f79b3d74711dfa2e6044cf6e
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a shared base line narrowed to this os synthesizes a region" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export SHELL_OK=1\n" ++
        "export EDITOR=vim\n" ++
        "# mox: when os=darwin\n" ++
        "export BREW=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "export APT=1\n" ++
        "# mox: end\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".zshrc"), "export EDITOR=vim", "export EDITOR=nvim");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "2\n");
    const want =
        \\rc 0
        \\--- stdout
        \\.zshrc  hunk 1/1  ->  shared -- changes 2 configuration(s)
        \\  ~/.zshrc -- this edit changes every configuration. Keep it universal, or narrow it?
        \\    [1] universal
        \\    [2] os=darwin
        \\    [3] machine=<MACHINE> (only here)
        \\    [4] private
        \\    [m] manual  [s] skip  [q] quit  [?] help
        \\  choose>   synthesize os=darwin region in src/.zshrc:2
        \\    + # mox: replace from "os"
        \\    + fragment <ROOT>/repo/src/.zshrc.d/os/darwin
        \\  committed ~/.zshrc
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/.zshrc
        \\export SHELL_OK=1
        \\# mox: replace from "os"
        \\export EDITOR=vim
        \\# mox: end
        \\# mox: when os=darwin
        \\export BREW=1
        \\# mox: end
        \\# mox: when os=linux
        \\export APT=1
        \\# mox: end
        \\src/.zshrc.d/
        \\src/.zshrc.d/os/
        \\== src/.zshrc.d/os/darwin
        \\export EDITOR=nvim
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.zshrc}
        \\  file 064a800582e89c331d23282aa130ff910a2fdaa2d64838f8cbd8a2ad2b85b15f cache 064a800582e89c331d23282aa130ff910a2fdaa2d64838f8cbd8a2ad2b85b15f
        \\  provenance 1de5d3c3e80d7a65f50e4613603e11405305affc63e7f5480d231c9947e55ee9
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a structured key routed to the os overlay that wins it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/config.toml", "theme = \"light\"\nfont = \"mono\"\n");
    try writeRepo(io, &tmp, "repo/src/config.toml.d/os=darwin.toml", "theme = \"dark\"\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf("config.toml"), "\"dark\"", "\"solarized\"");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  write config.toml theme -> os=darwin.toml
        \\  committed ~/config.toml
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/config.toml
        \\theme = "light"
        \\font = "mono"
        \\src/config.toml.d/
        \\== src/config.toml.d/os=darwin.toml
        \\theme = "solarized"
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/config.toml}
        \\  file b97e05e77de1da850e955a278e66d4deb21b57216f2fc4a0fd88ca18764998c2 cache b97e05e77de1da850e955a278e66d4deb21b57216f2fc4a0fd88ca18764998c2
        \\  provenance 3a329ab3cd8f3b2854fb65c3ee92c7912a9d44130895b0ec9d629032e442b2ac
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: an owned key of a partial file routed to its base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"enter\"\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    const live = try h.liveOf("app.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "# program header\nmodel = \"gpt\"\n\n[tui.keymap.global]\nsubmit = \"enter\"\n\n[state]\ncount = 42\n" });
    try applied(h);
    try editLive(io, a, live, "submit = \"enter\"", "submit = \"ctrl-enter\"");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  write app.toml tui.keymap.global.submit -> src/app.toml
        \\  committed ~/app.toml
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/app.toml
        \\# mox: own tui.keymap.global
        \\[tui.keymap.global]
        \\submit = "ctrl-enter"
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/app.toml}
        \\  owned own tui.keymap.global secret
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a capture-derived line routed to the machine fact" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport EMAIL=<machine.email | default \"nobody@example.com\">\n");
    try writeRepo(io, &tmp, "home/.config/mox/facts.toml", "email = \"old@home.com\"\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".zshrc"), "export EMAIL=old@home.com", "export EMAIL=new@work.com");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "f\n");
    const want =
        \\rc 0
        \\--- stdout
        \\.zshrc  hunk 1/1  ->  interpolated -- machine.email
        \\    - export EMAIL=old@home.com
        \\    + export EMAIL=new@work.com
        \\  This value comes from machine.email.
        \\  [F]act  [d]efault  [s]kip  [q]uit  [?]help   set fact machine.email = "new@work.com"
        \\  committed ~/.zshrc
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/.zshrc
        \\export A=1
        \\export EMAIL=<machine.email | default "nobody@example.com">
        \\--- home .config/mox/facts.toml
        \\email = "new@work.com"
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.zshrc}
        \\  file 1a57e47d5d6e8b1f94150e7d3441aa020219170be74dcdc1339b887724e2c50e cache 1a57e47d5d6e8b1f94150e7d3441aa020219170be74dcdc1339b887724e2c50e
        \\  provenance c3ef5a550ec34bce5f161694a9a102174a9067314eac51460e5556f77d031644
        \\
    ;
    try expectGolden(a, io, h, res, &.{".config/mox/facts.toml"}, want);
}

test "commit golden: a symlink target synced to its source" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSymlinkFixture(io, &tmp);
    const h = try setup(a, io, &tmp);
    try applied(h);
    try relink(io, h, "mylink", "/tmp/mox-new-target");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  write src/mylink -> new symlink target /tmp/mox-new-target
        \\  committed ~/mylink
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\.mox/
        \\== .mox/attributes.toml
        \\["mylink"]
        \\symlink = true
        \\src/
        \\== src/mylink
        \\/tmp/mox-new-target
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/mylink}
        \\  link /tmp/mox-new-target
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a generator leaf row routed to its data source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeGenFixture(io, &tmp);
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".config/id-a.inc"), "key=1", "key=99");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/data/entries.toml row 0
        \\  committed ~/.config/id-a.inc
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/entries.toml
        \\[[entries]]
        \\slug = "a"
        \\value = "99"
        \\
        \\[[entries]]
        \\slug = "b"
        \\value = "2"
        \\
        \\src/
        \\src/.config/
        \\== src/.config/gen.inc
        \\# mox: for entry in "data/entries.toml" into "id-<entry.slug>.inc"
        \\key=<entry.value>
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\generator {~/.config/gen.inc}
        \\  produced %3CROOT%3E/home/.config/id-a.inc
        \\  produced %3CROOT%3E/home/.config/id-b.inc
        \\part 0 expects-private no
        \\path {~/.config/id-a.inc}
        \\  file c9232dba09b77625192b29437de8c466a066dde1247d566216f469e783bd6a3d cache c9232dba09b77625192b29437de8c466a066dde1247d566216f469e783bd6a3d
        \\  provenance 6eeb23a77115120c0b8a9580945f2203efac2f01285e3545e8be2cf12691166c
        \\path {~/.config/id-b.inc}
        \\  file c54aaff57e4c9a3aaebe367b797714af71a09cd1e34cd70624f3706d4e492813 cache c54aaff57e4c9a3aaebe367b797714af71a09cd1e34cd70624f3706d4e492813
        \\  provenance 9abba5483ccaa232cd8a09542174eaf96f128d0b936e8a8fd960a3f5e1a226db
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a token rename updates its coupled consumer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "email = old@example.com\n");
    try writeRepo(io, &tmp, "repo/src/.mysigners", "old@example.com signing\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    try editLive(io, a, try h.liveOf(".myenv"), "old@example.com", "new@example.com");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  edit src/.myenv:1
        \\  update <ROOT>/repo/src/.mysigners: "old@example.com" -> "new@example.com"
        \\  committed ~/.myenv
        \\
        \\mox commit: 1 routed, 1 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/.myenv
        \\email = new@example.com
        \\== src/.mysigners
        \\new@example.com signing
        \\--- state
        \\coupling/
        \\coupling/graph.json 9e9341024fa9f107
        \\part 0 expects-private no
        \\path {~/.myenv}
        \\  file 96306e5aea28e071fad1f4427eeb6c57530c9c275b78aafc9c4c96184dae8b10 cache 96306e5aea28e071fad1f4427eeb6c57530c9c275b78aafc9c4c96184dae8b10
        \\  provenance 19605d5259d226c4469afd29e3401c22a09193ba712b169d1bc15859af66c7a9
        \\path {~/.mysigners}
        \\  file 901706149d79baf51ee593771a9133a45d0e662f107c1d65f312a2c2e3808e5d cache 901706149d79baf51ee593771a9133a45d0e662f107c1d65f312a2c2e3808e5d
        \\  provenance b5dcd9333215086a11b4f3a625f2c321514f5a0a4d083837f47cec5d686e60ea
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a first-contact file confirmed at the prompt" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.bashrc", "export A=1\nexport PROFILE=<machine.profile | default \"work\">\nexport C=3\n");
    try writeRepo(io, &tmp, "home/.bashrc", "export A=11\nexport PROFILE=work\nexport C=3\n");
    const h = try setup(a, io, &tmp);

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    const want =
        \\rc 0
        \\--- stdout
        \\.bashrc  hunk 1/1  ->  src/.bashrc (base)
        \\    - export A=1
        \\    + export A=11
        \\  [Y]es  [s]kip  [q]uit  [?]help   committed ~/.bashrc
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/.bashrc
        \\export A=11
        \\export PROFILE=<machine.profile | default "work">
        \\export C=3
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.bashrc}
        \\  file c41026694098dd7919cf2ae9228fe7c57dd2ca33249ae9d0a18510d32d59c7e3 cache c41026694098dd7919cf2ae9228fe7c57dd2ca33249ae9d0a18510d32d59c7e3
        \\  provenance c2c96e0e4392555c65584aa68571923d694331b9c8ec96ea607e1afbbd72c5cf
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a routed hunk beside a manual hunk in one file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport MIDDLE=1\nexport HOST=<machine.hostname>\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    const live = try h.liveOf(".zshrc");
    try editLive(io, a, live, "export A=1", "export A=2");
    try editLive(io, a, live, "export HOST=", "export HOSTNAME=");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 1
        \\--- stdout
        \\  edit src/.zshrc:1
        \\  manual: ~/.zshrc:3 came from a capture
        \\  committed ~/.zshrc
        \\
        \\mox commit: 1 routed, 0 coupled, 1 manual
        \\--- stderr
        \\mox commit: ~/.zshrc: 1 hunk(s) could not be routed and remain only in the live file; the routed edits were committed to the sources -- edit the rest in by hand, then run 'mox apply'
        \\--- repo
        \\src/
        \\== src/.zshrc
        \\export A=2
        \\export MIDDLE=1
        \\export HOST=<machine.hostname>
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.zshrc}
        \\  file 887eaf5c1a01ca60566ad05565bf987fbcf7838714621d3d0a55f581c4c6ef11 cache 887eaf5c1a01ca60566ad05565bf987fbcf7838714621d3d0a55f581c4c6ef11
        \\  provenance 7308ebd4ad4d26f9a0b3c04dba73b2c6a09be8d628160f20d7d2c5a3d53b4cfd
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: one data row edited through two loop files, routed in one and declined in the other" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", abbrs_loop);
    try writeRepo(io, &tmp, "repo/src/.abbrs2", "# mox: for entry in \"data/abbrs.toml\"\nalias <entry.key>='<entry.expansion>'\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", abbrs_data);
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");
    try editLive(io, a, try h.liveOf(".abbrs2"), "git status", "git status -sb");

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\ns\n");
    const want =
        \\rc 0
        \\--- stdout
        \\.abbrs  hunk 1/1  ->  data source <ROOT>/repo/data/abbrs.toml (row 1)
        \\    - abbr gs="git status"
        \\    + abbr gs="git status -sb"
        \\  [Y]es  [s]kip  [q]uit  [?]help .abbrs2  hunk 1/1  ->  data source <ROOT>/repo/data/abbrs.toml (row 1)
        \\    - alias gs='git status'
        \\    + alias gs='git status -sb'
        \\  [Y]es  [s]kip  [q]uit  [?]help   committed ~/.abbrs
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status -sb"
        \\src/
        \\== src/.abbrs
        \\# mox: for entry in "data/abbrs.toml"
        \\abbr <entry.key>="<entry.expansion>"
        \\# mox: end
        \\== src/.abbrs2
        \\# mox: for entry in "data/abbrs.toml"
        \\alias <entry.key>='<entry.expansion>'
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json dd5d468c769ac4f0
        \\part 0 expects-private no
        \\path {~/.abbrs2}
        \\  file fb428ae02a4f2e1e4532618915488b30797598bb58b25beb15a3f148be11931a cache fb428ae02a4f2e1e4532618915488b30797598bb58b25beb15a3f148be11931a
        \\  provenance ac985625d9bb9bd2918fd7e695b1c3b89c5cb9e55985597abbab049b062f2fd8
        \\path {~/.abbrs}
        \\  file 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834 cache 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834
        \\  provenance 5eabd410fa3bbe111172fa70e837bb735f3790a8f79b3d74711dfa2e6044cf6e
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: one rename made in two files with a third sharing the token" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.myenv", "email = old@example.com\n");
    try writeRepo(io, &tmp, "repo/src/.mysigners", "old@example.com signing\n");
    try writeRepo(io, &tmp, "repo/src/.mycontacts", "me <old@example.com>\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    try testutil.gitTracked(io, a, h.repo);
    try std.testing.expectEqual(@as(u8, 0), (try h.run(&.{ "mox", "doctor", "--rebuild-coupling" })).rc);
    try editLive(io, a, try h.liveOf(".myenv"), "old@example.com", "new@example.com");
    try editLive(io, a, try h.liveOf(".mysigners"), "old@example.com", "new@example.com");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  edit src/.myenv:1
        \\  edit src/.mysigners:1
        \\  update <ROOT>/repo/src/.mycontacts: "old@example.com" -> "new@example.com"
        \\  update <ROOT>/repo/src/.mysigners: "old@example.com" -> "new@example.com"
        \\  update <ROOT>/repo/src/.mycontacts: "old@example.com" -> "new@example.com"
        \\  update <ROOT>/repo/src/.myenv: "old@example.com" -> "new@example.com"
        \\  committed ~/.myenv
        \\  committed ~/.mysigners
        \\
        \\mox commit: 2 routed, 4 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/.mycontacts
        \\me <new@example.com>
        \\== src/.myenv
        \\email = new@example.com
        \\== src/.mysigners
        \\new@example.com signing
        \\--- state
        \\coupling/
        \\coupling/graph.json f5ece01951fbd549
        \\part 0 expects-private no
        \\path {~/.mycontacts}
        \\  file b74ec336d15e151525c86d37f0485e4c55017ec9dea1fe2d911a92ddd1930c30 cache b74ec336d15e151525c86d37f0485e4c55017ec9dea1fe2d911a92ddd1930c30
        \\  provenance 2d69e2d15e8c0df4e2c1cde0c4f1b2e4511b70355a87e1f4c9bf8dae1c931ba2
        \\path {~/.myenv}
        \\  file 96306e5aea28e071fad1f4427eeb6c57530c9c275b78aafc9c4c96184dae8b10 cache 96306e5aea28e071fad1f4427eeb6c57530c9c275b78aafc9c4c96184dae8b10
        \\  provenance 19605d5259d226c4469afd29e3401c22a09193ba712b169d1bc15859af66c7a9
        \\path {~/.mysigners}
        \\  file 2ce71af7eb434a428effb3ea691a717c78878e8f4a82b771466d55c6f84a5d0e cache 2ce71af7eb434a428effb3ea691a717c78878e8f4a82b771466d55c6f84a5d0e
        \\  provenance b5dcd9333215086a11b4f3a625f2c321514f5a0a4d083837f47cec5d686e60ea
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a symlink, a generator leaf and a text file committed in one run" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSymlinkFixture(io, &tmp);
    try writeGenFixture(io, &tmp);
    try writeRepo(io, &tmp, "repo/src/.zshrc", "export A=1\nexport B=2\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    try relink(io, h, "mylink", "/tmp/mox-new-target");
    try editLive(io, a, try h.liveOf(".config/id-b.inc"), "key=2", "key=42");
    try editLive(io, a, try h.liveOf(".zshrc"), "export B=2", "export B=3");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/data/entries.toml row 1
        \\  edit src/.zshrc:2
        \\  write src/mylink -> new symlink target /tmp/mox-new-target
        \\  committed ~/mylink
        \\  committed ~/.config/id-b.inc
        \\  committed ~/.zshrc
        \\
        \\mox commit: 3 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\.mox/
        \\== .mox/attributes.toml
        \\["mylink"]
        \\symlink = true
        \\data/
        \\== data/entries.toml
        \\[[entries]]
        \\slug = "a"
        \\value = "1"
        \\
        \\[[entries]]
        \\slug = "b"
        \\value = "42"
        \\
        \\src/
        \\src/.config/
        \\== src/.config/gen.inc
        \\# mox: for entry in "data/entries.toml" into "id-<entry.slug>.inc"
        \\key=<entry.value>
        \\# mox: end
        \\== src/.zshrc
        \\export A=1
        \\export B=3
        \\== src/mylink
        \\/tmp/mox-new-target
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\generator {~/.config/gen.inc}
        \\  produced %3CROOT%3E/home/.config/id-a.inc
        \\  produced %3CROOT%3E/home/.config/id-b.inc
        \\part 0 expects-private no
        \\path {~/.config/id-a.inc}
        \\  file 40ac730b26f0a164a78eff3478a4e8ef0f1e48470e84535d7987fe3483588ce5 cache 40ac730b26f0a164a78eff3478a4e8ef0f1e48470e84535d7987fe3483588ce5
        \\  provenance 6eeb23a77115120c0b8a9580945f2203efac2f01285e3545e8be2cf12691166c
        \\path {~/.config/id-b.inc}
        \\  file e6077e23d07bf6e5b11d8eb3d54e61a80532b10c0c87d3c7735caac83c08f0cf cache e6077e23d07bf6e5b11d8eb3d54e61a80532b10c0c87d3c7735caac83c08f0cf
        \\  provenance 9abba5483ccaa232cd8a09542174eaf96f128d0b936e8a8fd960a3f5e1a226db
        \\path {~/.zshrc}
        \\  file 3082dc99cc937277c19a139865ea640ff58cea0e750c5b28f73ce920d77e0eca cache 3082dc99cc937277c19a139865ea640ff58cea0e750c5b28f73ce920d77e0eca
        \\  provenance c6c6603f72035924e7b6257a64fe82372caa93f7366bbccdc3f3c62bb8451344
        \\path {~/mylink}
        \\  link /tmp/mox-new-target
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: two loop files edit different fields of one data row" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbr-keys", "# mox: for entry in \"data/abbrs.toml\"\nkey: <entry.key>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/.abbr-expansions", "# mox: for entry in \"data/abbrs.toml\"\nexpansion: <entry.expansion>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", abbrs_data);
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".abbr-keys"), "key: gs\n", "key: gst\n");
    try editLive(io, a, try h.liveOf(".abbr-expansions"), "expansion: git status\n", "expansion: git status -sb\n");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/data/abbrs.toml row 1
        \\  update <ROOT>/repo/data/abbrs.toml row 1
        \\  committed ~/.abbr-expansions
        \\  committed ~/.abbr-keys
        \\
        \\mox commit: 2 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbrs]]
        \\key = "gst"
        \\expansion = "git status -sb"
        \\src/
        \\== src/.abbr-expansions
        \\# mox: for entry in "data/abbrs.toml"
        \\expansion: <entry.expansion>
        \\# mox: end
        \\== src/.abbr-keys
        \\# mox: for entry in "data/abbrs.toml"
        \\key: <entry.key>
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 143cfab9a5a5b964
        \\part 0 expects-private no
        \\path {~/.abbr-expansions}
        \\  file 61e048bd9cc31695a3029a8606abc8423aba2981290df6881315b3e157aa3e97 cache 61e048bd9cc31695a3029a8606abc8423aba2981290df6881315b3e157aa3e97
        \\  provenance c24477fb6fb8a9f42bd597fdffa5a1f009d13d17e2da31998ce9436f8698457a
        \\path {~/.abbr-keys}
        \\  file e1abcf61834df7eae9f6d6289ade7ac4be24f140953420bd3a7ec39d392ed0eb cache e1abcf61834df7eae9f6d6289ade7ac4be24f140953420bd3a7ec39d392ed0eb
        \\  provenance 88ce5a0792efbd57ea9a9c37aa7a65b045f295ebd52120e96443700bde916b1c
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a managed data file row edited through its loop and directly to the same value" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", abbrs_data);
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");
    try editLive(io, a, try h.liveOf("abbrs.toml"), "\"git status\"", "\"git status -sb\"");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/src/abbrs.toml row 1
        \\  edit src/abbrs.toml:7
        \\  committed ~/.abbrs
        \\  committed ~/abbrs.toml
        \\
        \\mox commit: 2 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/.abbrs
        \\# mox: for entry in "src/abbrs.toml"
        \\abbr <entry.key>="<entry.expansion>"
        \\# mox: end
        \\== src/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status -sb"
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.abbrs}
        \\  file 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834 cache 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834
        \\  provenance aebc15626befc541b68c955798a436bb62017e7837d45eedb72d289dbd65c345
        \\path {~/abbrs.toml}
        \\  file 23e0d3c836d135f789847f4dc5a60aea389a81c9b48e345f45c401a83b0ee83c cache 23e0d3c836d135f789847f4dc5a60aea389a81c9b48e345f45c401a83b0ee83c
        \\  provenance 11c8f2ada989ca956846cffeebf41f2ccf2890ee0f840f8c7baba874dc06ac61
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a partial file and a symlink committed in one run" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeSymlinkFixture(io, &tmp);
    try writeRepo(io, &tmp, "repo/src/app.toml", "# mox: own tui.keymap.global\n[tui.keymap.global]\nsubmit = \"enter\"\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    const live = try h.liveOf("app.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = live, .data = "# program header\nmodel = \"gpt\"\n\n[tui.keymap.global]\nsubmit = \"enter\"\n\n[state]\ncount = 42\n" });
    try applied(h);
    try editLive(io, a, live, "submit = \"enter\"", "submit = \"ctrl-enter\"");
    try relink(io, h, "mylink", "/tmp/mox-new-target");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  write app.toml tui.keymap.global.submit -> src/app.toml
        \\  write src/mylink -> new symlink target /tmp/mox-new-target
        \\  committed ~/mylink
        \\  committed ~/app.toml
        \\
        \\mox commit: 2 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\.mox/
        \\== .mox/attributes.toml
        \\["mylink"]
        \\symlink = true
        \\src/
        \\== src/app.toml
        \\# mox: own tui.keymap.global
        \\[tui.keymap.global]
        \\submit = "ctrl-enter"
        \\== src/mylink
        \\/tmp/mox-new-target
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/app.toml}
        \\  owned own tui.keymap.global secret
        \\path {~/mylink}
        \\  link /tmp/mox-new-target
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a loop row field edited beside a multi-line string holding a bracketed line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.tools", "# mox: for entry in \"data/tools.toml\"\ntool <entry.name>=\"<entry.cmd>\"\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/tools.toml", "[[tools]]\nname = \"rg\"\ndesc = \"\"\"\n[docs](https://x) see\n\"\"\"\ncmd = \"rg --smart-case\"\n\n[[tools]]\nname = \"fd\"\ncmd = \"fd --hidden\"\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".tools"), "rg --smart-case", "rg --smart-case --hidden");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/data/tools.toml row 0
        \\  committed ~/.tools
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/tools.toml
        \\[[tools]]
        \\name = "rg"
        \\desc = """
        \\[docs](https://x) see
        \\"""
        \\cmd = "rg --smart-case --hidden"
        \\
        \\[[tools]]
        \\name = "fd"
        \\cmd = "fd --hidden"
        \\src/
        \\== src/.tools
        \\# mox: for entry in "data/tools.toml"
        \\tool <entry.name>="<entry.cmd>"
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.tools}
        \\  file 599c3cd5917ae432374bd465262015cd245482207ce06e56f52019e05b4d1241 cache 599c3cd5917ae432374bd465262015cd245482207ce06e56f52019e05b4d1241
        \\  provenance 50f0c6bdcb6b589f84e88ac27832394d4a3046d29ecaaceaaccbe76297235a9f
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: one file with two loops over one data source, one loop line edited" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.hosts", "# mox: for entry in \"data/abbrs.toml\"\nhost <entry.key>\n# mox: end\n# mox: for entry in \"data/abbrs.toml\"\nalias <entry.expansion>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", abbrs_data);
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".hosts"), "alias git status\n", "alias git status -sb\n");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/data/abbrs.toml row 1
        \\  committed ~/.hosts
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status -sb"
        \\src/
        \\== src/.hosts
        \\# mox: for entry in "data/abbrs.toml"
        \\host <entry.key>
        \\# mox: end
        \\# mox: for entry in "data/abbrs.toml"
        \\alias <entry.expansion>
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.hosts}
        \\  file da58489fa57654f3b78de31ab82ebf364d8b8d74df702e828d6875114ce49a07 cache da58489fa57654f3b78de31ab82ebf364d8b8d74df702e828d6875114ce49a07
        \\  provenance 0cb34f6197657b9c37b2486d32e153cba7c0b03fa9a238dcaa2de019a3da327c
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a bare field capture under a loop variable not named entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for h in \"data/abbrs.toml\"\nabbr <key>=\"<expansion>\"\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", abbrs_data);
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/data/abbrs.toml row 1
        \\  committed ~/.abbrs
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status -sb"
        \\src/
        \\== src/.abbrs
        \\# mox: for h in "data/abbrs.toml"
        \\abbr <key>="<expansion>"
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.abbrs}
        \\  file 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834 cache 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834
        \\  provenance c7296b38c1ab9bf92d449e676e443c9f428707c26d49c988bf655c14001417bc
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a loop row edited beside a row whose data value resolves a secret" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.exports", "# mox: for entry in \"data/exports.toml\"\nexport <entry.name>=<entry.value>\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/exports.toml", "[[exports]]\nname = \"TOKEN\"\nvalue = \"<secret:env:MOX_GOLDEN_TOKEN>\"\n\n[[exports]]\nname = \"EDITOR\"\nvalue = \"vim\"\n");
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_GOLDEN_TOKEN", .value = "golden-s3cr3t-5e7a" }});
    try applied(h);
    try editLive(io, a, try h.liveOf(".exports"), "export EDITOR=vim", "export EDITOR=nvim");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/data/exports.toml row 1
        \\  committed ~/.exports
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/exports.toml
        \\[[exports]]
        \\name = "TOKEN"
        \\value = "<secret:env:MOX_GOLDEN_TOKEN>"
        \\
        \\[[exports]]
        \\name = "EDITOR"
        \\value = "nvim"
        \\src/
        \\== src/.exports
        \\# mox: for entry in "data/exports.toml"
        \\export <entry.name>=<entry.value>
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.exports}
        \\  file 7128997af61f937c0e69ef1d0627e5ce9c27596971727bab41cce7ba6609eec7 cache none
        \\  provenance aa1d0b2afb890e362f6cb79a18416eab8625b826210e6d215ec4c59528a0b1ef
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a first-contact loop file confirmed at the prompt with a row edit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", abbrs_loop);
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", abbrs_data);
    try writeRepo(io, &tmp, "home/.abbrs", "abbr ll=\"ls -l\"\nabbr gs=\"git status -sb\"\n");
    const h = try setup(a, io, &tmp);

    const res = try h.runWithInput(&.{ "mox", "commit", "--color=never" }, "y\n");
    const want =
        \\rc 0
        \\--- stdout
        \\.abbrs  hunk 1/1  ->  data source <ROOT>/repo/data/abbrs.toml (row 1)
        \\    - abbr gs="git status"
        \\    + abbr gs="git status -sb"
        \\  [Y]es  [s]kip  [q]uit  [?]help   committed ~/.abbrs
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status -sb"
        \\src/
        \\== src/.abbrs
        \\# mox: for entry in "data/abbrs.toml"
        \\abbr <entry.key>="<entry.expansion>"
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.abbrs}
        \\  file 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834 cache 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834
        \\  provenance 5eabd410fa3bbe111172fa70e837bb735f3790a8f79b3d74711dfa2e6044cf6e
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a loop row edited in a file that resolves a secret" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", "export TOKEN=<secret:env:MOX_GOLDEN_TOKEN>\n" ++ abbrs_loop);
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", abbrs_data);
    const h = try setupEnv(a, io, &tmp, &.{.{ .name = "MOX_GOLDEN_TOKEN", .value = "golden-s3cr3t-5e7a" }});
    try applied(h);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/data/abbrs.toml row 1
        \\  committed ~/.abbrs
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status -sb"
        \\src/
        \\== src/.abbrs
        \\export TOKEN=<secret:env:MOX_GOLDEN_TOKEN>
        \\# mox: for entry in "data/abbrs.toml"
        \\abbr <entry.key>="<entry.expansion>"
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.abbrs}
        \\  file 4f0c77cb7fa7df587c833d082580d74d7ef38d52bfa651e4f52aed83bc2f8af1 cache none
        \\  provenance 14389aecb957f8da35d81b1f160ea7c8291c4b422dfe39ca6703f034409e1dba
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: two loops over one data source with disjoint where filters, a row of the second edited" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"data/abbrs.toml\" where entry.shell = \"fish\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n# mox: for entry in \"data/abbrs.toml\" where entry.shell = \"zsh\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/data/abbrs.toml", "[[abbrs]]\nkey = \"ll\"\nexpansion = \"ls -l\"\nshell = \"fish\"\n\n[[abbrs]]\nkey = \"gs\"\nexpansion = \"git status\"\nshell = \"zsh\"\n");
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/data/abbrs.toml row 1
        \\  committed ~/.abbrs
        \\
        \\mox commit: 1 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\data/
        \\== data/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\shell = "fish"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status -sb"
        \\shell = "zsh"
        \\src/
        \\== src/.abbrs
        \\# mox: for entry in "data/abbrs.toml" where entry.shell = "fish"
        \\abbr <entry.key>="<entry.expansion>"
        \\# mox: end
        \\# mox: for entry in "data/abbrs.toml" where entry.shell = "zsh"
        \\abbr <entry.key>="<entry.expansion>"
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.abbrs}
        \\  file 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834 cache 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834
        \\  provenance 5eabd410fa3bbe111172fa70e837bb735f3790a8f79b3d74711dfa2e6044cf6e
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a managed data file row edited through its loop, another row's unread field edited in the data file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/.abbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", abbrs_noted_data);
    const h = try setup(a, io, &tmp);
    try applied(h);
    try editLive(io, a, try h.liveOf(".abbrs"), "git status", "git status -sb");
    const data_live = try h.liveOf("abbrs.toml");
    try editLive(io, a, data_live, "\"git status\"", "\"git status -sb\"");
    try editLive(io, a, data_live, "note = \"list\"", "note = \"long list\"");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  update <ROOT>/repo/src/abbrs.toml row 1
        \\  edit src/abbrs.toml:4
        \\  edit src/abbrs.toml:8
        \\  committed ~/.abbrs
        \\  committed ~/abbrs.toml
        \\
        \\mox commit: 2 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/.abbrs
        \\# mox: for entry in "src/abbrs.toml"
        \\abbr <entry.key>="<entry.expansion>"
        \\# mox: end
        \\== src/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -l"
        \\note = "long list"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status -sb"
        \\note = "status"
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/.abbrs}
        \\  file 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834 cache 759912bfca82a5992eacefbf095bc264282830afe3c69f7b38251312a82a2834
        \\  provenance aebc15626befc541b68c955798a436bb62017e7837d45eedb72d289dbd65c345
        \\path {~/abbrs.toml}
        \\  file 42cac2fc684eb169b9b9525b97a0e24e5911922bfb44bd6c79a7037cc4c96e15 cache 42cac2fc684eb169b9b9525b97a0e24e5911922bfb44bd6c79a7037cc4c96e15
        \\  provenance 8343e82e82d9e99b9aef3b4a646ac137b73b5062429b933958a9f24b711fc087
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}

test "commit golden: a managed data file committed before its loop file, each editing a different row" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeRepo(io, &tmp, "repo/src/zabbrs", "# mox: for entry in \"src/abbrs.toml\"\nabbr <entry.key>=\"<entry.expansion>\"\n# mox: end\n");
    try writeRepo(io, &tmp, "repo/src/abbrs.toml", abbrs_noted_data);
    const h = try setup(a, io, &tmp);
    try applied(h);
    const data_live = try h.liveOf("abbrs.toml");
    try editLive(io, a, data_live, "note = \"status\"", "note = \"short status\"");
    try editLive(io, a, data_live, "\"ls -l\"", "\"ls -la\"");
    try editLive(io, a, try h.liveOf("zabbrs"), "ls -l\"", "ls -la\"");

    const res = try h.run(&.{ "mox", "commit", "--yes", "--color=never" });
    const want =
        \\rc 0
        \\--- stdout
        \\  edit src/abbrs.toml:3
        \\  edit src/abbrs.toml:9
        \\  update <ROOT>/repo/src/abbrs.toml row 0
        \\  committed ~/abbrs.toml
        \\  committed ~/zabbrs
        \\
        \\mox commit: 2 routed, 0 coupled, 0 manual
        \\--- stderr
        \\--- repo
        \\src/
        \\== src/abbrs.toml
        \\[[abbrs]]
        \\key = "ll"
        \\expansion = "ls -la"
        \\note = "list"
        \\
        \\[[abbrs]]
        \\key = "gs"
        \\expansion = "git status"
        \\note = "short status"
        \\== src/zabbrs
        \\# mox: for entry in "src/abbrs.toml"
        \\abbr <entry.key>="<entry.expansion>"
        \\# mox: end
        \\--- state
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\part 0 expects-private no
        \\path {~/abbrs.toml}
        \\  file 6a401119d05ed87855bdbf980753d77f1117571ec6ad5919c0e551681d64a36c cache 6a401119d05ed87855bdbf980753d77f1117571ec6ad5919c0e551681d64a36c
        \\  provenance 8343e82e82d9e99b9aef3b4a646ac137b73b5062429b933958a9f24b711fc087
        \\path {~/zabbrs}
        \\  file 10a0138cf5ed91f84655c728bbb1455fe1b8a2dde3c8110865596db052ceb3b3 cache 10a0138cf5ed91f84655c728bbb1455fe1b8a2dde3c8110865596db052ceb3b3
        \\  provenance 5aeed2fd66143c801e0404d2ce67f19376d816b00debdf868698b2f0d137fc98
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}
