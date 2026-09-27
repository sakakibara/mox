const std = @import("std");
const builtin = @import("builtin");
const mox = @import("mox");

const Io = std.Io;

const testutil = @import("testutil.zig");
const Harness = testutil.Harness;

const repo_exclusions = [_][]const u8{".git"};
const state_exclusions = [_][]const u8{"bin"};

fn setup(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !Harness {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    return testutil.setup(a, io, tmp, .{ .os = "darwin", .arch = "aarch64" });
}

fn setupEnv(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, extra_env: []const testutil.EnvPair) !Harness {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    return testutil.setup(a, io, tmp, .{ .os = "darwin", .arch = "aarch64", .extra_env = extra_env });
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

    fn apply(n: Normalizer, a: std.mem.Allocator, text: []const u8) ![]const u8 {
        var t = try std.mem.replaceOwned(u8, a, text, n.root, "<ROOT>");
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
    return out.items;
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.zshrc} 70e088a1db4236d1
        \\applied/{~/.zshrc} 69e42d218a01cb14
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.zshrc} 4d155492e3015560
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.abbrs} 759912bfca82a599
        \\applied/{~/.abbrs} f4890857d20b2cd7
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.abbrs} 5eabd410fa3bbe11
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
        \\  <ROOT>/home/.zshrc -- this edit changes every configuration. Keep it universal, or narrow it?
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.zshrc} 064a800582e89c33
        \\applied/{~/.zshrc} ae0e9db606093fde
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.zshrc} 1de5d3c3e80d7a65
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/config.toml} b97e05e77de1da85
        \\applied/{~/config.toml} 31077a808bd511f9
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/config.toml} 3a329ab3cd8f3b28
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
        \\applied-owned/
        \\applied-owned/{~/app.toml} c761451269f8dda9
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.zshrc} 1a57e47d5d6e8b1f
        \\applied/{~/.zshrc} 7aae12931c493924
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.zshrc} c3ef5a550ec34bce
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
        \\applied-symlink/
        \\applied-symlink/{~/mylink} f6c2be7f999ec9b8
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.config/id-a.inc} c9232dba09b77625
        \\applied-content/{~/.config/id-b.inc} c54aaff57e4c9a3a
        \\applied/{~/.config/id-a.inc} c8ac34fe54519858
        \\applied/{~/.config/id-b.inc} 5de07619e757b05b
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\generated/
        \\generated/{~/.config/gen.inc} dfe6c3a26a893576
        \\provenance/
        \\provenance/{~/.config/id-a.inc} 6eeb23a77115120c
        \\provenance/{~/.config/id-b.inc} 9abba5483ccaa232
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.myenv} 96306e5aea28e071
        \\applied-content/{~/.mysigners} 901706149d79baf5
        \\applied/{~/.myenv} b11f685e0eb53cf4
        \\applied/{~/.mysigners} 67a7204c65595a7e
        \\coupling/
        \\coupling/graph.json 9e9341024fa9f107
        \\provenance/
        \\provenance/{~/.myenv} 19605d5259d226c4
        \\provenance/{~/.mysigners} b5dcd9333215086a
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.bashrc} c41026694098dd79
        \\applied/{~/.bashrc} e7d8a2ad9c8928aa
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.bashrc} c2c96e0e4392555c
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
        \\mox commit: <ROOT>/home/.zshrc: 1 hunk(s) could not be routed and remain only in the live file; the routed edits were committed to the sources -- edit the rest in by hand, then run 'mox apply'
        \\--- repo
        \\src/
        \\== src/.zshrc
        \\export A=2
        \\export MIDDLE=1
        \\export HOST=<machine.hostname>
        \\--- state
        \\applied/
        \\applied-content/
        \\applied-content/{~/.zshrc} b7c91210a67218b5
        \\applied/{~/.zshrc} c9313a9d96988ea9
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.zshrc} 7308ebd4ad4d26f9
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.abbrs2} fb428ae02a4f2e1e
        \\applied-content/{~/.abbrs} 759912bfca82a599
        \\applied/{~/.abbrs2} 144730e9e3e50d2b
        \\applied/{~/.abbrs} f4890857d20b2cd7
        \\coupling/
        \\coupling/graph.json dd5d468c769ac4f0
        \\provenance/
        \\provenance/{~/.abbrs2} ac985625d9bb9bd2
        \\provenance/{~/.abbrs} 5eabd410fa3bbe11
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.mycontacts} b74ec336d15e1515
        \\applied-content/{~/.myenv} 96306e5aea28e071
        \\applied-content/{~/.mysigners} 2ce71af7eb434a42
        \\applied/{~/.mycontacts} 099efda36bc6f9f5
        \\applied/{~/.myenv} b11f685e0eb53cf4
        \\applied/{~/.mysigners} 81a226c8cd979d5a
        \\coupling/
        \\coupling/graph.json f5ece01951fbd549
        \\provenance/
        \\provenance/{~/.mycontacts} 2d69e2d15e8c0df4
        \\provenance/{~/.myenv} 19605d5259d226c4
        \\provenance/{~/.mysigners} b5dcd9333215086a
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.config/id-a.inc} 40ac730b26f0a164
        \\applied-content/{~/.config/id-b.inc} e6077e23d07bf6e5
        \\applied-content/{~/.zshrc} 3082dc99cc937277
        \\applied-symlink/
        \\applied-symlink/{~/mylink} f6c2be7f999ec9b8
        \\applied/{~/.config/id-a.inc} 36135f9617c038ac
        \\applied/{~/.config/id-b.inc} d641a2a0f4042c96
        \\applied/{~/.zshrc} 5a5b5014a9806bf9
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\generated/
        \\generated/{~/.config/gen.inc} dfe6c3a26a893576
        \\provenance/
        \\provenance/{~/.config/id-a.inc} 6eeb23a77115120c
        \\provenance/{~/.config/id-b.inc} 9abba5483ccaa232
        \\provenance/{~/.zshrc} c6c6603f72035924
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.abbr-expansions} 61e048bd9cc31695
        \\applied-content/{~/.abbr-keys} e1abcf61834df7ea
        \\applied/{~/.abbr-expansions} a63da4340b3f0c6e
        \\applied/{~/.abbr-keys} 980e1969e56691c7
        \\coupling/
        \\coupling/graph.json 143cfab9a5a5b964
        \\provenance/
        \\provenance/{~/.abbr-expansions} c24477fb6fb8a9f4
        \\provenance/{~/.abbr-keys} 88ce5a0792efbd57
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.abbrs} 759912bfca82a599
        \\applied-content/{~/abbrs.toml} 23e0d3c836d135f7
        \\applied/{~/.abbrs} f4890857d20b2cd7
        \\applied/{~/abbrs.toml} 5e2c104542aab929
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.abbrs} aebc15626befc541
        \\provenance/{~/abbrs.toml} 11c8f2ada989ca95
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
        \\applied-owned/
        \\applied-owned/{~/app.toml} c761451269f8dda9
        \\applied-symlink/
        \\applied-symlink/{~/mylink} f6c2be7f999ec9b8
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.tools} 599c3cd5917ae432
        \\applied/{~/.tools} f157d9a8036dc152
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.tools} 50f0c6bdcb6b589f
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.hosts} da58489fa57654f3
        \\applied/{~/.hosts} f4dfafc67243ea17
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.hosts} 0cb34f6197657b9c
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.abbrs} 759912bfca82a599
        \\applied/{~/.abbrs} f4890857d20b2cd7
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.abbrs} c7296b38c1ab9bf9
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
        \\applied/
        \\applied/{~/.exports} ce36490aaac724df
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.exports} aa1d0b2afb890e36
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.abbrs} 759912bfca82a599
        \\applied/{~/.abbrs} f4890857d20b2cd7
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.abbrs} 5eabd410fa3bbe11
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
        \\applied/
        \\applied/{~/.abbrs} b6a418e80f93d618
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.abbrs} 14389aecb957f8da
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.abbrs} 759912bfca82a599
        \\applied/{~/.abbrs} f4890857d20b2cd7
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.abbrs} 5eabd410fa3bbe11
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/.abbrs} 759912bfca82a599
        \\applied-content/{~/abbrs.toml} 42cac2fc684eb169
        \\applied/{~/.abbrs} f4890857d20b2cd7
        \\applied/{~/abbrs.toml} 70d2b9bda320cba8
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/.abbrs} aebc15626befc541
        \\provenance/{~/abbrs.toml} 8343e82e82d9e99b
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
        \\applied/
        \\applied-content/
        \\applied-content/{~/abbrs.toml} 6a401119d05ed878
        \\applied-content/{~/zabbrs} 10a0138cf5ed91f8
        \\applied/{~/abbrs.toml} 75b963759ca1ff24
        \\applied/{~/zabbrs} 546c045e7dc46a9b
        \\coupling/
        \\coupling/graph.json 353b9360c0adad2a
        \\provenance/
        \\provenance/{~/abbrs.toml} 8343e82e82d9e99b
        \\provenance/{~/zabbrs} 5aeed2fd66143c80
        \\
    ;
    try expectGolden(a, io, h, res, &.{}, want);
}
