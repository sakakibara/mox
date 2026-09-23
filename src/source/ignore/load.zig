const std = @import("std");
const Io = std.Io;
const mox = @import("../../root.zig");
const match = @import("match.zig");
const testing = std.testing;

const max_ignore_bytes: usize = 1 << 20;

fn readOptional(arena: std.mem.Allocator, io: Io, path: []const u8) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_ignore_bytes)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
}

/// Read an ignore file and resolve its axis-gated regions for this machine.
/// A plain pattern list (no `# mox:` directive) has no inferable comment
/// marker, so it is returned verbatim; a directive-bearing file composes as a
/// Category-B source (`#` inferred from the directive) so `# mox: when os=...`
/// regions gate per machine. A missing file yields null.
fn resolve(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    bindings: *const mox.dsl.resolver.Resolver,
    m_state: *const mox.machine.state.MachineState,
) !?[]u8 {
    const raw = (try readOptional(arena, io, path)) orelse return null;
    if (mox.dsl.comment.markerForFile(path, raw) == null) return raw;
    const file: mox.source.tree.ManagedFile = .{
        .source_base_path = path,
        .source_base_abs = path,
        .live_path = path,
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
    };
    return (try mox.compose.catB.compose(arena, io, file, bindings, m_state)) orelse "";
}

/// Load and merge the repo's ignore files into one RuleSet. `.mox/ignore`
/// contributes first, root `.moxignore` last (so its rules win ties under
/// last-match-wins). Each file's `# mox: when` regions are resolved for the
/// current machine before compiling. A missing file contributes nothing.
pub fn load(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    bindings: *const mox.dsl.resolver.Resolver,
    m_state: *const mox.machine.state.MachineState,
) !match.RuleSet {
    const namespaced = try std.fs.path.join(arena, &.{ repo_dir, ".mox", "ignore" });
    const root = try std.fs.path.join(arena, &.{ repo_dir, ".moxignore" });

    var buf: std.ArrayList(u8) = .empty;
    if (try resolve(arena, io, namespaced, bindings, m_state)) |t| {
        try buf.appendSlice(arena, t);
        try buf.append(arena, '\n');
    }
    if (try resolve(arena, io, root, bindings, m_state)) |t| {
        try buf.appendSlice(arena, t);
        try buf.append(arena, '\n');
    }
    return match.compile(arena, buf.items);
}

/// The lines of `text` that compose emits on every machine: those outside any
/// region, plus the body of a region that always emits it (`append`,
/// `prepend`, and a `replace` with neither `when` nor `from`), whose nested
/// directive lines compose also emits as literal text. Regions are found with
/// the marker and classification compose uses. A kept `#`-led line is harmless,
/// since `match.compile` treats it as a comment.
fn stripConditional(arena: std.mem.Allocator, path: []const u8, text: []const u8) ![]u8 {
    const marker = mox.dsl.comment.markerForFile(path, text) orelse return @constCast(text);
    const events = try mox.dsl.scanner.scan(arena, text, marker);
    var buf: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    var keep_body = false;
    for (events) |ev| {
        const line = switch (ev) {
            .content => |c| c.text,
            .directive => |d| blk: {
                switch (try mox.dsl.driver.classify(d.args)) {
                    .opener => {
                        if (depth == 0) {
                            const opener = try mox.dsl.parser.parseRegionOpener(arena, d.args, d.line_no, false);
                            keep_body = switch (opener.kind_tag) {
                                .append, .prepend => true,
                                .replace => opener.when == null and opener.from_dir == null,
                                .remove, .from, .when_gate, .for_loop => false,
                            };
                            depth = 1;
                            continue;
                        }
                        depth += 1;
                    },
                    .end => {
                        if (depth == 0) continue;
                        depth -= 1;
                        if (depth == 0) continue;
                    },
                    .other => {},
                }
                break :blk d.original_line;
            },
        };
        if (depth == 0 or keep_body) {
            try buf.appendSlice(arena, line);
            try buf.append(arena, '\n');
        }
    }
    return buf.toOwnedSlice(arena);
}

/// Load only the unconditional ignore rules -- those compose emits on every
/// machine (see `stripConditional`). Used by `doctor` to flag a file that
/// is ignored under EVERY configuration (a real contradiction), as opposed to
/// one ignored only on some machines via axis gating (intentional). Reads the
/// same two files as `load` but does not compose them: an unconditional rule
/// is axis-independent, so no bindings/machine state are needed.
pub fn loadUnconditional(arena: std.mem.Allocator, io: Io, repo_dir: []const u8) !match.RuleSet {
    const namespaced = try std.fs.path.join(arena, &.{ repo_dir, ".mox", "ignore" });
    const root = try std.fs.path.join(arena, &.{ repo_dir, ".moxignore" });

    var buf: std.ArrayList(u8) = .empty;
    if (try readOptional(arena, io, namespaced)) |t| {
        try buf.appendSlice(arena, try stripConditional(arena, namespaced, t));
        try buf.append(arena, '\n');
    }
    if (try readOptional(arena, io, root)) |t| {
        try buf.appendSlice(arena, try stripConditional(arena, root, t));
        try buf.append(arena, '\n');
    }
    return match.compile(arena, buf.items);
}

pub const scaffold_moxignore: []const u8 =
    \\# mox ignore file (gitignore syntax). Paths are relative to your home dir.
    \\# These keep credentials out of a synced dotfiles repo. Delete any line
    \\# you want tracked (e.g. if your repo is private and you want secrets in it).
    \\.claude/.credentials.json
    \\.claude/*-cache.json
    \\.claude/settings.local.json
    \\.claude/projects/
    \\.claude/file-history/
    \\.claude/*.jsonl
    \\.ssh/id_*
    \\!.ssh/id_*.pub
    \\*.pem
    \\
;

/// True when a basename looks like a secret, for the non-blocking
/// warn-on-add note. Deliberately conservative.
pub fn looksLikeSecret(basename: []const u8) bool {
    const exact = [_][]const u8{ ".credentials.json", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa" };
    for (exact) |e| if (std.mem.eql(u8, basename, e)) return true;
    const suffixes = [_][]const u8{ ".pem", ".key" };
    for (suffixes) |s| if (std.mem.endsWith(u8, basename, s)) return true;
    return false;
}

test "load: merges .mox/ignore and .moxignore, root wins ties" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = pathbuf[0..try tmp.dir.realPath(io, &pathbuf)];

    try tmp.dir.createDirPath(io, ".mox");
    try tmp.dir.writeFile(io, .{ .sub_path = ".mox/ignore", .data = "*.jsonl\n.secret\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".moxignore", .data = "!.secret\n" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const st = stateForOs("darwin");
    var bindings = try mox.machine.bindings.fromMachineState(a, st);
    var bindings_r: mox.dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    const set = try load(a, io, repo, &bindings_r, &st);
    try testing.expect(set.isIgnored("a/b.jsonl", false)); // from .mox/ignore
    try testing.expect(!set.isIgnored(".secret", false)); // root negation wins (last)
}

fn stateForOs(os: []const u8) mox.machine.state.MachineState {
    return .{
        .os = os,
        .arch = "aarch64",
        .hostname = "test",
        .username = "u",
        .home = "/h",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
}

test "load: axis-gated rules resolve for the current machine" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = pathbuf[0..try tmp.dir.realPath(io, &pathbuf)];

    try tmp.dir.writeFile(io, .{ .sub_path = ".moxignore", .data =
        \\always.txt
        \\# mox: when os=linux
        \\linux-only/
        \\# mox: end
        \\
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const darwin_state = stateForOs("darwin");
    var darwin_bindings = try mox.machine.bindings.fromMachineState(a, darwin_state);
    var darwin_bindings_r: mox.dsl.resolver.Resolver = .{ .live = &.{ .bindings = &darwin_bindings } };
    const darwin = try load(a, io, repo, &darwin_bindings_r, &darwin_state);
    try testing.expect(darwin.isIgnored("always.txt", false));
    try testing.expect(!darwin.isIgnored("linux-only", true));

    const linux_state = stateForOs("linux");
    var linux_bindings = try mox.machine.bindings.fromMachineState(a, linux_state);
    var linux_bindings_r: mox.dsl.resolver.Resolver = .{ .live = &.{ .bindings = &linux_bindings } };
    const linux = try load(a, io, repo, &linux_bindings_r, &linux_state);
    try testing.expect(linux.isIgnored("always.txt", false));
    try testing.expect(linux.isIgnored("linux-only", true));
}

test "loadUnconditional: keeps unconditional rules, drops when-gated ones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = pathbuf[0..try tmp.dir.realPath(io, &pathbuf)];

    try tmp.dir.writeFile(io, .{ .sub_path = ".moxignore", .data =
        \\always.txt
        \\# mox: when os=linux
        \\cond.txt
        \\# mox: end
        \\
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const set = try loadUnconditional(a, io, repo);
    try testing.expect(set.isIgnored("always.txt", false));
    try testing.expect(!set.isIgnored("cond.txt", false));
}

test "load: a gate spelled with a tab after the marker still gates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = pathbuf[0..try tmp.dir.realPath(io, &pathbuf)];

    try tmp.dir.writeFile(io, .{ .sub_path = ".moxignore", .data = "always.txt\n#\tmox: when os=linux\nlinux-only/\n#\tmox: end\n" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const darwin_state = stateForOs("darwin");
    var darwin_bindings = try mox.machine.bindings.fromMachineState(a, darwin_state);
    var darwin_bindings_r: mox.dsl.resolver.Resolver = .{ .live = &.{ .bindings = &darwin_bindings } };
    const darwin = try load(a, io, repo, &darwin_bindings_r, &darwin_state);
    try testing.expect(darwin.isIgnored("always.txt", false));
    try testing.expect(!darwin.isIgnored("linux-only", true));
}

test "loadUnconditional: drops rules under every spelling the scanner reads as a gate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = pathbuf[0..try tmp.dir.realPath(io, &pathbuf)];

    try tmp.dir.writeFile(io, .{ .sub_path = ".moxignore", .data = "always.txt\n# mox:when os=linux\na.txt\n# mox: end\n#\tmox: when os=linux\nb.txt\n#  mox: end\n# mox: when(os=linux)\nc.txt\n# mox: end\n# mox: for x in \"d.toml\"\nd.txt\n# mox: end\n" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const set = try loadUnconditional(a, io, repo);
    try testing.expect(set.isIgnored("always.txt", false));
    try testing.expect(!set.isIgnored("a.txt", false));
    try testing.expect(!set.isIgnored("b.txt", false));
    try testing.expect(!set.isIgnored("c.txt", false));
    try testing.expect(!set.isIgnored("d.txt", false));
}

test "loadUnconditional: keeps the body of a region that always emits it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = pathbuf[0..try tmp.dir.realPath(io, &pathbuf)];

    try tmp.dir.writeFile(io, .{ .sub_path = ".moxignore", .data = "# mox: replace \"r\"\nr.txt\n# mox: end\n" ++
        "# mox: append \"w\" when os=linux\nw.txt\n# mox: end\n" ++
        "# mox: prepend \"q\"\n# mox: when os=linux\ng.txt\n# mox: end\nq.txt\n# mox: end\n" ++
        "# mox: replace \"c\" when os=linux\nc.txt\n# mox: end\n" ++
        "# mox: remove when os=linux\nm.txt\n# mox: end\n" ++
        "# mox: replace from \"profile\"\nf.txt\n# mox: end\n" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const set = try loadUnconditional(a, io, repo);
    try testing.expect(set.isIgnored("r.txt", false));
    try testing.expect(set.isIgnored("w.txt", false));
    try testing.expect(set.isIgnored("q.txt", false));
    try testing.expect(set.isIgnored("g.txt", false));
    try testing.expect(!set.isIgnored("c.txt", false));
    try testing.expect(!set.isIgnored("m.txt", false));
    try testing.expect(!set.isIgnored("f.txt", false));
}

test "load: a gate under the doubled marker compose infers still gates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = pathbuf[0..try tmp.dir.realPath(io, &pathbuf)];

    try tmp.dir.writeFile(io, .{ .sub_path = ".moxignore", .data = "always.txt\n## mox: when os=linux\nlinux-only/\n## mox: end\n" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const darwin_state = stateForOs("darwin");
    var darwin_bindings = try mox.machine.bindings.fromMachineState(a, darwin_state);
    var darwin_bindings_r: mox.dsl.resolver.Resolver = .{ .live = &.{ .bindings = &darwin_bindings } };
    const darwin = try load(a, io, repo, &darwin_bindings_r, &darwin_state);
    try testing.expect(darwin.isIgnored("always.txt", false));
    try testing.expect(!darwin.isIgnored("linux-only", true));

    const set = try loadUnconditional(a, io, repo);
    try testing.expect(set.isIgnored("always.txt", false));
    try testing.expect(!set.isIgnored("linux-only", true));
}

test "load: missing files yield an empty (never-ignoring) set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = pathbuf[0..try tmp.dir.realPath(io, &pathbuf)];

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const st = stateForOs("darwin");
    var bindings = try mox.machine.bindings.fromMachineState(a, st);
    var bindings_r: mox.dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };
    const set = try load(a, io, repo, &bindings_r, &st);
    try testing.expect(!set.isIgnored("anything", false));
}
