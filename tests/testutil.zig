//! Shared CLI-driving harness for mox's integration tests: builds an
//! isolated HOME/MOX_REPO/MOX_STATE_DIR under the test's tmp dir and runs
//! argv through mox's cli-zig dispatcher, capturing stdout/stderr/exit code.

const std = @import("std");
const mox = @import("mox");

const Io = std.Io;

pub const RunResult = struct { rc: u8, out: []const u8, err: []const u8 };

pub const Harness = struct {
    a: std.mem.Allocator,
    io: Io,
    env: mox.env.Env,
    root: []const u8,
    home: []const u8,
    repo: []const u8,
    state: []const u8,

    /// Runs `argv` (including the program name, e.g. `&.{"mox","apply"}`)
    /// through `mox.cli.app.run`. `loadContext` reads the process
    /// environment off a process-global singleton rather than a per-call
    /// parameter (see cli/app.zig), so `h.env` is installed there for the
    /// duration of this one call and restored after. Tests run
    /// single-threaded and sequentially, so this swap-and-restore is
    /// race-free.
    pub fn run(h: Harness, argv: []const []const u8) !RunResult {
        return h.runWithInput(argv, null);
    }

    /// `run`, with `stdin` (when non-null) scripting the command's interactive
    /// prompts: it stands in for the process's stdin and drives the command
    /// down its terminal path, so a prompt-only branch (choosing a
    /// non-default candidate) is reachable from a test.
    pub fn runWithInput(h: Harness, argv: []const []const u8, stdin: ?[]const u8) !RunResult {
        var out_aw: Io.Writer.Allocating = .init(h.a);
        var err_aw: Io.Writer.Allocating = .init(h.a);

        const saved = mox.cli.app.environ_override;
        mox.cli.app.environ_override = h.env;
        defer mox.cli.app.environ_override = saved;

        var reader: Io.Reader = if (stdin) |s| .fixed(s) else undefined;
        const saved_stdin = mox.cli.app.stdin_override;
        mox.cli.app.stdin_override = if (stdin == null) null else &reader;
        defer mox.cli.app.stdin_override = saved_stdin;

        const rc = try mox.cli.app.run(h.a, h.io, argv, &mox.cli.app.command_table, &out_aw.writer, &err_aw.writer);
        return .{ .rc = rc, .out = try out_aw.toOwnedSlice(), .err = try err_aw.toOwnedSlice() };
    }

    pub fn liveOf(h: Harness, name: []const u8) ![]u8 {
        return std.fs.path.join(h.a, &.{ h.home, name });
    }

    /// `rel` is a key (`.gitconfig.d/os=darwin`), so it joins natively rather
    /// than splicing a '/'-separated tail onto a '\'-separated root.
    pub fn srcOf(h: Harness, rel: []const u8) ![]u8 {
        const src_root = try std.fs.path.join(h.a, &.{ h.repo, "src" });
        return mox.source.path.joinKeyOnto(h.a, src_root, rel);
    }

    pub fn homePath(h: Harness, name: []const u8) ![]u8 {
        return mox.source.path.joinKeyOnto(h.a, h.home, name);
    }
};

/// True when any file under `root` contains `needle`, or any symlink under it
/// has `needle` in its target. Used to assert that nothing of a machine reaches
/// the shared repo -- git stores a symlink as a blob whose content is the raw
/// target string, so a target carries a value into a commit exactly as a file
/// body does. Targets are read, never resolved.
pub fn containsAnywhere(a: std.mem.Allocator, io: Io, root: []const u8, needle: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = dir.walk(a) catch return false;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        switch (entry.kind) {
            .file => {
                const content = dir.readFileAlloc(io, entry.path, a, .limited(1 << 20)) catch continue;
                if (std.mem.indexOf(u8, content, needle) != null) return true;
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = dir.readLink(io, entry.path, &buf) catch continue;
                if (std.mem.indexOf(u8, buf[0..n], needle) != null) return true;
            },
            else => {},
        }
    }
    return false;
}

pub const SetupOpts = struct {
    editor: ?[]const u8 = null,
    /// lifecycle_test.zig's fixtures assume `repo/src` exists up front;
    /// apply_test.zig/commit_test.zig create it themselves per-test (some
    /// exercise the "source tree not found" path), so this defaults off.
    create_repo_src: bool = false,
    /// Pins the machine's os/arch axis regardless of the build target, so a
    /// fixture that reasons about os-gated configurations is hermetic across
    /// runners. Null leaves the host's real value.
    os: ?[]const u8 = null,
    arch: ?[]const u8 = null,
};

pub fn setup(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, opts: SetupOpts) !Harness {
    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const home = try std.fs.path.join(a, &.{ root, "home" });
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    const state = try std.fs.path.join(a, &.{ root, "state" });
    try tmp.dir.createDirPath(io, "home");
    if (opts.create_repo_src) try tmp.dir.createDirPath(io, "repo/src");

    var map = std.process.Environ.Map.init(a);
    try map.put("HOME", home);
    try map.put("USER", "tester");
    try map.put("MOX_REPO", repo);
    try map.put("MOX_STATE_DIR", state);
    if (opts.editor) |e| try map.put("EDITOR", e);
    if (opts.os) |os| try map.put("MOX_OS", os);
    if (opts.arch) |arch| try map.put("MOX_ARCH", arch);
    // The Env borrows the map, so it must outlive this call.
    const map_ptr = try a.create(std.process.Environ.Map);
    map_ptr.* = map;

    return .{ .a = a, .io = io, .env = .{ .map = map_ptr }, .root = root, .home = home, .repo = repo, .state = state };
}

const testing = std.testing;

// Canaries: confirm the cli-zig-driven Harness.run reproduces the old
// dispatcher's command-body output byte-for-byte on a few representative
// paths (an env-sensitive read command, a not-found error, and an invalid-
// input error) before trusting it for the full apply/commit/lifecycle
// suites' 88 call sites.

test "canary: mox status against an empty isolated repo reports source-tree-not-found on stderr, rc 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const h = try setup(a, testing.io, &tmp, .{});
    const got = try h.run(&.{ "mox", "status" });
    try testing.expectEqual(@as(u8, 1), got.rc);
    try testing.expectEqualStrings("", got.out);
    const want_src_dir = try std.fs.path.join(a, &.{ h.repo, "src" });
    const want = try std.fmt.allocPrint(a, "mox status: source tree not found at {s}\n", .{want_src_dir});
    try testing.expectEqualStrings(want, got.err);
}

test "canary: mox add against a path that does not exist reports not-found on stderr, rc 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const h = try setup(a, testing.io, &tmp, .{});
    const missing = try h.homePath("nope.txt");
    const got = try h.run(&.{ "mox", "add", missing });
    try testing.expectEqual(@as(u8, 1), got.rc);
    try testing.expectEqualStrings("", got.out);
    const want = try std.fmt.allocPrint(a, "mox add: {s}: not found\n", .{missing});
    try testing.expectEqualStrings(want, got.err);
}

test "canary: mox secret with an invalid URI reports the parse error on stderr, rc 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const h = try setup(a, testing.io, &tmp, .{});
    const got = try h.run(&.{ "mox", "secret", "not-a-uri" });
    try testing.expectEqual(@as(u8, 1), got.rc);
    try testing.expectEqualStrings("", got.out);
    try testing.expect(std.mem.startsWith(u8, got.err, "mox secret: invalid URI: "));
}
